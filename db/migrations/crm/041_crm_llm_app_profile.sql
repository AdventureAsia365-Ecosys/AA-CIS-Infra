-- Migration crm-041: AA-1025 (S263 gateway plan, slice H1c; root ADR 0009 decision 4, root ADR 0008a §6) — the CRM's
-- app profile in schema crm: the app-wide AI switch, bulk pause, default daily AI budget and degrade mode.
--
-- Owner: AA-Partner (api/migrations/041_crm_llm_app_profile.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-041: crm-040 (AA-1027 F3, crm.ai_draft) is the highest on main.
--
-- Why: root ADR 0009 §4 gives every app a profile (AI on / off, bulk paused, default budgets, degrade mode); CIS holds
-- one row per app in shared.llm_app_profile (CIS 345) and the CIS admin edits them. ADR 0008a §6 keeps the CRM off
-- every shared.llm_* table, so the CRM's profile lives here, with the same shape, and the CIS admin writes it over
-- crm.ops.v1 (PUT /llm/app-profile, the staff member's own WORKFORCE token, crm-platform-admin) when it edits the 'crm'
-- row. The CRM gateway reads it on every call (app.llm.app_profile): AI off = every call refused 'app_disabled' with a
-- 0 USD row, before the stage profile, the scrub or any model call; the daily budget caps the spend of every agency
-- together (crm.llm_usage_daily) on top of each agency's own monthly budget.
--
-- What:
--   1. crm.llm_app_profile (platform table: AA's configuration, no tenant column, no personal data), at most one row
--      (app = 'crm', the primary key): ai_enabled, bulk_paused (stored and shown; the CRM has no bulk AI work yet),
--      default_daily_budget_usd (NULL = none; 0..100000, numeric(12,4) like CIS 345), degrade_mode
--      (manual_reply_needed, the CRM's only mode), disabled_reason (<= 500 chars), updated_at, updated_by
--      (platform:<staff sub> or 'migration'). No seed row: no row = AI on, no daily budget (the gateway's default),
--      the first PUT inserts it.
--   2. Grants: REVOKE ALL from crm_app first (the schema's default privileges, crm-001, give it SELECT, INSERT, UPDATE,
--      DELETE on every new table), then SELECT, INSERT, UPDATE only: a DELETE of the row would silently switch AI
--      back on (the CIS 345 review point). No reader grant. No RLS: no tenant rows (listed in the platform tables of the
--      catalogue guard).
--   3. Register crm-041.
--
-- Class: contract (root ADR 0017 d3): the REVOKE of step 2 is refused by the expand lint. So no "-- migrate: expand"
-- header: MIG-4 order, this migration-only PR first, the Infra copy (Migration Sync bot; the root DM-7.1 retention row
-- for the new table merges before it), Infra Migration Apply once every job table is idle (root ADR 0017a), the
-- bot/db-schema-reference PR, then the code PR (adds crm-041 to REQUIRED_SCHEMA_VERSIONS). Nothing reads the table
-- before the code PR.
--
-- Order: after crm-040. Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent
-- (IF NOT EXISTS, re-runnable REVOKE / GRANT, ON CONFLICT DO NOTHING).
-- Rollback: a forward crm- file (MIG-14) after the code that reads it is reverted: DROP TABLE crm.llm_app_profile (a
-- destructive file, DRY RUN).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ── Guard 0: runs as the owner, after crm-040 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-041: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-040') THEN
        RAISE EXCEPTION 'crm-041: crm-040 (AA-1027 F3 crm.ai_draft) lands first';
    END IF;
END $$;

-- ── 1. crm.llm_app_profile ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.llm_app_profile (
    app                      TEXT PRIMARY KEY,
    ai_enabled               BOOLEAN NOT NULL DEFAULT true,
    bulk_paused              BOOLEAN NOT NULL DEFAULT false,
    default_daily_budget_usd NUMERIC(12, 4),
    degrade_mode             TEXT NOT NULL DEFAULT 'manual_reply_needed',
    disabled_reason          TEXT,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by               TEXT NOT NULL DEFAULT 'migration',
    CONSTRAINT llm_app_profile_app_chk CHECK (app = 'crm'),
    CONSTRAINT llm_app_profile_budget_chk CHECK (
        default_daily_budget_usd IS NULL OR (default_daily_budget_usd >= 0 AND default_daily_budget_usd <= 100000)),
    CONSTRAINT llm_app_profile_degrade_chk CHECK (degrade_mode IN ('manual_reply_needed')),
    CONSTRAINT llm_app_profile_reason_chk CHECK (disabled_reason IS NULL OR length(disabled_reason) <= 500),
    CONSTRAINT llm_app_profile_by_chk CHECK (updated_by ~ '^[A-Za-z0-9._:@-]{1,120}$')
);
REVOKE ALL ON crm.llm_app_profile FROM crm_app;
GRANT SELECT, INSERT, UPDATE ON crm.llm_app_profile TO crm_app;
COMMENT ON TABLE crm.llm_app_profile IS 'AA-1025 H1c (crm-041, root ADR 0009 §4): the CRM app profile, at most one row (app = crm): AI on / off, bulk paused, default daily AI budget (every agency together), degrade mode. Written by the CIS admin over crm.ops.v1 PUT /llm/app-profile; no row = AI on, no daily budget. Platform configuration, no tenant column, no PII. crm_app SELECT, INSERT, UPDATE (no DELETE).';
COMMENT ON COLUMN crm.llm_app_profile.ai_enabled IS 'AA-1025 H1c (crm-041): false = every CRM AI call is refused app_disabled (a 0 USD ledger row), before the stage profile, the scrub or any model call.';
COMMENT ON COLUMN crm.llm_app_profile.default_daily_budget_usd IS 'AA-1025 H1c (crm-041): the daily (UTC) AI spend of every agency together (crm.llm_usage_daily); at 100 % calls are refused app_budget_exhausted. NULL = none.';
COMMENT ON COLUMN crm.llm_app_profile.bulk_paused IS 'AA-1025 H1c (crm-041): stored and shown (CIS 345 shape); the CRM has no bulk AI work yet.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-041', now(), 'AA-1025 H1c: crm.llm_app_profile (the CRM app profile: AI switch, bulk pause, default daily AI budget, degrade mode), crm_app SELECT, INSERT, UPDATE')
ON CONFLICT (version) DO NOTHING;

COMMIT;
