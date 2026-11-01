-- Migration crm-037: AA-964 (S263 gateway plan F1 + F2; root ADR 0009 decisions 4, 5 and 8, root ADR 0008a §5-6) —
-- CRM stage profiles in schema crm (route, attempts, deadline, kill switch) and the ledger v2 status values on
-- crm.llm_call.
--
-- Owner: AA-Partner (api/migrations/037_crm_llm_stage_profile.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-037: crm-036 is AA-958's (CRM-28 messaging), which merges first.
--
-- Why: root ADR 0009 §4 gives every stage a profile (route + parameters + budget + kill switch) and keeps the CRM's
-- profiles in schema crm with the same shape (ADR 0008a §6: the CRM reads no shared.llm_* table and holds no grant
-- outside crm). The CRM gateway had one model from the environment, one attempt and no way to switch one stage off.
-- ADR 0009 §5 also says a reply cut at its token limit is the class 'truncated', never a success, and ADR 0009 §8 gives
-- the ledger the statuses ok | refused | error | billed_unusable | truncated; crm.llm_call allowed ok | refused | error
-- only, so a truncated or billed-but-unusable answer had no honest outcome.
--
-- What:
--   1. crm.llm_stage_profile (platform table: AA's configuration, no tenant column, no personal data): one row per CRM
--      stage (crm_*, never the guardrail's own crm_scrub): role (writer / judge / validate), is_active (the stage kill
--      switch: false = every call is refused 'stage_disabled' with a 0 USD row, before any scrub or model call),
--      max_attempts (1..6, the route attempts of one request), route_deadline_s (1..120, no new attempt starts after
--      it), degrade_mode (what the product shows without AI: manual_reply_needed, the only CRM mode), updated_at / _by.
--   2. crm.llm_stage_route (platform table): the stage's route in order (position 0 = primary, then fallbacks, at most
--      6), provider (bedrock only, ADR 0008a §5), model (the inference profile id sent on the wire), family (the maker,
--      ADR 0009 §3), the catalog prices per million input / output tokens copied from the CIS model catalog when the
--      row is written (both or neither; NULL = the gateway prices from the shared core's table or its high estimate,
--      never 0), is_enabled.
--      Seed: crm_draft_reply (writer, active, 2 attempts, 30 s): Claude Haiku 4.5 then Claude Sonnet 4.5 (us. inference
--      profiles, the vendored core's known ids and list prices 1 / 5 and 3 / 15 USD per million tokens).
--   3. crm.llm_call outcome CHECK: + billed_unusable, + truncated (the ledger v2 statuses of the shared core).
--   crm_app: SELECT on both new tables (the gateway reads them in the call's transaction); nothing else. A stage is
--   switched off or rerouted by a forward migration or a DB Migrate run-script as the owner (a crm.ops.v1 write route
--   is a later slice). No reader grant. No RLS: no tenant rows (listed in the platform tables of the catalogue guard).
--
-- Class: contract (root ADR 0017 d3): a replaced CHECK on an existing table (crm.llm_call, a ledger). So no
-- "-- migrate: expand" header: MIG-4 order, this migration-only PR first, the Infra copy (Migration Sync bot; the root
-- DM-7.1 retention rows for the two new tables merge before it), a manual DB Migrate apply, the bot/db-schema-reference
-- PR, then the code PR (adds crm-037 to REQUIRED_SCHEMA_VERSIONS). The code before it never reads the new tables and
-- writes only ok / refused / error, so it keeps working on this schema.
--
-- Order: after crm-035 (AA-957). Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.
-- Idempotent (IF NOT EXISTS, DROP CONSTRAINT IF EXISTS before the ADD, ON CONFLICT DO NOTHING): crm.llm_call holds a
-- handful of rows per agency (180-day retention), so re-adding its outcome CHECK is cheap.
-- Rollback: a forward crm- file (MIG-14), after the code that reads the profiles is reverted; restoring the old
-- outcome CHECK needs no truncated / billed_unusable row left (crm_lifecycle purges rows after 180 days).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ── Guard 0: runs as the owner, after crm-035 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-037: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-035') THEN
        RAISE EXCEPTION 'crm-037: crm-035 (AA-957 commission and cancel) lands first';
    END IF;
    IF to_regclass('crm.llm_call') IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid = 'crm.llm_call'::regclass
                        AND conname = 'llm_call_refusal_chk') THEN
        RAISE EXCEPTION 'crm-037: crm.llm_call (crm-005) with its refusal CHECK missing';
    END IF;
END $$;

-- ── 1. crm.llm_stage_profile ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.llm_stage_profile (
    stage            TEXT PRIMARY KEY,
    role             TEXT NOT NULL,
    is_active        BOOLEAN NOT NULL DEFAULT true,
    max_attempts     SMALLINT NOT NULL DEFAULT 1,
    route_deadline_s SMALLINT NOT NULL DEFAULT 30,
    degrade_mode     TEXT NOT NULL DEFAULT 'manual_reply_needed',
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by       TEXT NOT NULL DEFAULT 'migration',
    CONSTRAINT llm_stage_profile_stage_chk CHECK (stage ~ '^crm_[a-z0-9_]{1,40}$' AND stage <> 'crm_scrub'),
    CONSTRAINT llm_stage_profile_role_chk CHECK (role IN ('writer', 'judge', 'validate')),
    CONSTRAINT llm_stage_profile_attempts_chk CHECK (max_attempts BETWEEN 1 AND 6),
    CONSTRAINT llm_stage_profile_deadline_chk CHECK (route_deadline_s BETWEEN 1 AND 120),
    CONSTRAINT llm_stage_profile_degrade_chk CHECK (degrade_mode IN ('manual_reply_needed')),
    CONSTRAINT llm_stage_profile_by_chk CHECK (updated_by ~ '^[A-Za-z0-9._:@-]{1,120}$')
);
REVOKE ALL ON crm.llm_stage_profile FROM crm_app;
GRANT SELECT ON crm.llm_stage_profile TO crm_app;
COMMENT ON TABLE crm.llm_stage_profile IS 'AA-964 (crm-037, root ADR 0009 §4): one AI stage profile of the CRM gateway: role, kill switch (is_active), attempts, route deadline, degrade mode. Platform configuration, no tenant column, no PII. crm_app SELECT.';
COMMENT ON COLUMN crm.llm_stage_profile.is_active IS 'AA-964 (crm-037): the stage kill switch; false = every call is refused stage_disabled (a 0 USD ledger row), nothing scrubbed or sent.';
COMMENT ON COLUMN crm.llm_stage_profile.max_attempts IS 'AA-964 (crm-037): at most this many route attempts per request (1..6, root ADR 0009 §5).';
COMMENT ON COLUMN crm.llm_stage_profile.route_deadline_s IS 'AA-964 (crm-037): no new attempt starts after this many seconds of one request.';
COMMENT ON COLUMN crm.llm_stage_profile.degrade_mode IS 'AA-964 (crm-037): what the product shows without AI (manual_reply_needed: "reply by hand").';

-- ── 2. crm.llm_stage_route ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.llm_stage_route (
    stage              TEXT NOT NULL REFERENCES crm.llm_stage_profile (stage) ON DELETE CASCADE,
    position           SMALLINT NOT NULL,
    provider           TEXT NOT NULL DEFAULT 'bedrock',
    model              TEXT NOT NULL,
    family             TEXT,
    price_in_per_mtok  NUMERIC(10, 4),
    price_out_per_mtok NUMERIC(10, 4),
    is_enabled         BOOLEAN NOT NULL DEFAULT true,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by         TEXT NOT NULL DEFAULT 'migration',
    PRIMARY KEY (stage, position),
    CONSTRAINT llm_stage_route_position_chk CHECK (position BETWEEN 0 AND 5),
    CONSTRAINT llm_stage_route_provider_chk CHECK (provider = 'bedrock'),
    CONSTRAINT llm_stage_route_model_chk CHECK (model ~ '^[A-Za-z0-9._:/-]{1,120}$'),
    CONSTRAINT llm_stage_route_family_chk CHECK (family IS NULL OR family ~ '^[a-z][a-z0-9_.-]{0,40}$'),
    CONSTRAINT llm_stage_route_price_chk CHECK (
        ((price_in_per_mtok IS NULL) = (price_out_per_mtok IS NULL))
        AND (price_in_per_mtok IS NULL OR (price_in_per_mtok > 0 AND price_out_per_mtok > 0))),
    CONSTRAINT llm_stage_route_by_chk CHECK (updated_by ~ '^[A-Za-z0-9._:@-]{1,120}$')
);
REVOKE ALL ON crm.llm_stage_route FROM crm_app;
GRANT SELECT ON crm.llm_stage_route TO crm_app;
COMMENT ON TABLE crm.llm_stage_route IS 'AA-964 (crm-037, root ADR 0009 §5): the route of a CRM AI stage in order (position 0 = primary): Bedrock model id, family (maker), catalog prices per million tokens (both or neither), enabled. Platform configuration, no tenant column, no PII. crm_app SELECT.';
COMMENT ON COLUMN crm.llm_stage_route.price_in_per_mtok IS 'AA-964 (crm-037): USD per million input tokens, copied from the CIS model catalog (pricing_mode catalog); NULL = the shared core prices it (code_table or a high estimate, never 0).';
COMMENT ON COLUMN crm.llm_stage_route.family IS 'AA-964 (crm-037): the model family = its maker (anthropic, amazon, ...; root ADR 0009 §3).';

INSERT INTO crm.llm_stage_profile (stage, role, is_active, max_attempts, route_deadline_s)
VALUES ('crm_draft_reply', 'writer', true, 2, 30)
ON CONFLICT (stage) DO NOTHING;
INSERT INTO crm.llm_stage_route (stage, position, model, family, price_in_per_mtok, price_out_per_mtok)
VALUES ('crm_draft_reply', 0, 'us.anthropic.claude-haiku-4-5-20251001-v1:0', 'anthropic', 1, 5),
       ('crm_draft_reply', 1, 'us.anthropic.claude-sonnet-4-5-20250929-v1:0', 'anthropic', 3, 15)
ON CONFLICT (stage, position) DO NOTHING;

-- ── 3. crm.llm_call: the ledger v2 statuses ──────────────────────────────────────────────────────
ALTER TABLE crm.llm_call DROP CONSTRAINT IF EXISTS llm_call_outcome_chk;
ALTER TABLE crm.llm_call ADD CONSTRAINT llm_call_outcome_chk
    CHECK (outcome IN ('ok', 'refused', 'error', 'billed_unusable', 'truncated'));
COMMENT ON COLUMN crm.llm_call.outcome IS 'AA-964 (crm-005, crm-037): the ledger v2 status of the attempt: ok, refused (with refusal_code), error, billed_unusable (billed, no usable answer), truncated (cut at its token limit; never ok).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-037', now(), 'AA-964 S263 F1/F2: crm.llm_stage_profile (role, kill switch, attempts, route deadline, degrade mode) and crm.llm_stage_route (Bedrock route in order with family and catalog prices), seed crm_draft_reply; crm.llm_call outcome + billed_unusable, truncated')
ON CONFLICT (version) DO NOTHING;

COMMIT;
