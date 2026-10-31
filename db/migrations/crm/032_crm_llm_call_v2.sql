-- Migration crm-032: AA-964 CRM-33a (design v3 M14, R5, R39; root ADR 0009 §8, root ADR 0008a §5-6) — crm.llm_call
-- follows the ledger v2 column contract of the shared ledger (app = 'crm'), the guardrail call gets its own ledger row
-- (role guard), and the agency's AI budget alerts (75 / 90 / 100 %) fire once per month.
--
-- Owner: AA-Partner (api/migrations/032_crm_llm_call_v2.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-032.
--
-- Why: root ADR 0009 §8 puts every external call of every app under one ledger contract (app, stage, provider kind,
-- connection, deployment, family, tenant, job, request id, attempt, outcome, error class, latency, units, cost,
-- pricing mode, prompt version and hash, shadow / experiment flags), and root ADR 0008a §6 keeps crm.llm_call as the
-- CRM's own second ledger under that contract, fed to CIS only through crm.ops.v1. crm.llm_call (crm-005) had the
-- stage, model, tokens, cost, outcome and receipt only. The F3 Bedrock Guardrails pass (crm-009) is a paid call too and
-- had no row at all, and the R5 alerts had nowhere to remember that this month's 75 % alert was already raised.
--
-- What:
--   1. crm.llm_call, new columns (none holds text a person wrote; ids, codes and numbers only):
--      app text NOT NULL DEFAULT 'crm' (CHECK = 'crm': the CRM writes only its own rows), attempt_no (>= 1),
--      request_id (the provider's request id), job_id (the crm.job the call ran in; no FK: job rows are purged by
--      crm_job_retention), connection_key, deployment_wire_id (the model id sent on the wire), family,
--      cache_read_tokens / cache_write_tokens (>= 0), units / unit_kind (billed units that are not tokens, e.g. the
--      guardrail's text units; both or neither), pricing_mode (the CIS ledger's vocabulary), prompt_hash (sha256 hex
--      of the prompt as sent, i.e. scrubbed; never the prompt), prompt_version, is_shadow / is_experiment
--      (NOT NULL DEFAULT false). Constant defaults only: no table rewrite.
--   2. crm.llm_call role CHECK gains 'guard' (root ADR 0009 §9 seam "guard": Bedrock ApplyGuardrail). The stage CHECK
--      (crm_*) already admits the guardrail's stage crm_scrub.
--   3. crm.tenant_settings: ai_alert_month (the UTC month of the last budget alert) and ai_alert_pct (75 / 90 / 100,
--      the highest level raised in that month), both or neither. Written by the gateway in the call's transaction.
--   Unchanged: the append-only trigger (crm.erasable_append_only), FORCE RLS and tenant_isolation, crm_app INSERT +
--   SELECT on crm.llm_call (table-level grants cover the new columns), the receipt CHECKs, crm.llm_usage_daily.
--
-- Class: contract (root ADR 0017 d3): new CHECK constraints and a replaced one on existing tables, ADD COLUMN on a
-- ledger (a hot table in owners.yaml). So no "-- migrate: expand" header: MIG-4 order, this migration-only PR first,
-- the Infra copy (Migration Sync bot), a manual DB Migrate apply, the bot/db-schema-reference PR, then the AA-964 code
-- PR (adds crm-032 to REQUIRED_SCHEMA_VERSIONS). The code before AA-964 names its INSERT columns, so it keeps working on
-- this schema (every new column has a default or is nullable; role 'guard' is only added).
--
-- Order: after crm-031 (AA-966). Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.
-- Idempotent (ADD COLUMN IF NOT EXISTS, DROP CONSTRAINT IF EXISTS before each ADD CONSTRAINT, ON CONFLICT DO NOTHING):
-- crm.llm_call holds a handful of rows per agency (180-day retention), so re-adding its CHECKs is cheap.
-- Rollback: a forward crm- file (MIG-14), after the code that writes these columns is reverted; restoring the old role
-- CHECK needs no 'guard' row left (crm_lifecycle purges rows after 180 days, or the purge of a test agency).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ── Guard 0: runs as the owner, after crm-031 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-032: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-031') THEN
        RAISE EXCEPTION 'crm-032: crm-031 (AA-966 insight trip fact) lands first';
    END IF;
    IF to_regclass('crm.llm_call') IS NULL OR to_regclass('crm.tenant_settings') IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgrelid = 'crm.llm_call'::regclass
                        AND tgname = 'llm_call_append_only') THEN
        RAISE EXCEPTION 'crm-032: crm.llm_call (crm-005, with its append-only trigger) or crm.tenant_settings missing';
    END IF;
END $$;

-- ── 1. crm.llm_call: the ledger v2 columns ───────────────────────────────────────────────────────
ALTER TABLE crm.llm_call
    ADD COLUMN IF NOT EXISTS app                text    NOT NULL DEFAULT 'crm',
    ADD COLUMN IF NOT EXISTS attempt_no         integer,
    ADD COLUMN IF NOT EXISTS request_id         text,
    ADD COLUMN IF NOT EXISTS job_id             uuid,
    ADD COLUMN IF NOT EXISTS connection_key     text,
    ADD COLUMN IF NOT EXISTS deployment_wire_id text,
    ADD COLUMN IF NOT EXISTS family             text,
    ADD COLUMN IF NOT EXISTS cache_read_tokens  integer,
    ADD COLUMN IF NOT EXISTS cache_write_tokens integer,
    ADD COLUMN IF NOT EXISTS units              integer,
    ADD COLUMN IF NOT EXISTS unit_kind          text,
    ADD COLUMN IF NOT EXISTS pricing_mode       text,
    ADD COLUMN IF NOT EXISTS prompt_hash        text,
    ADD COLUMN IF NOT EXISTS prompt_version     text,
    ADD COLUMN IF NOT EXISTS is_shadow          boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS is_experiment      boolean NOT NULL DEFAULT false;

ALTER TABLE crm.llm_call DROP CONSTRAINT IF EXISTS llm_call_app_chk;
ALTER TABLE crm.llm_call ADD CONSTRAINT llm_call_app_chk CHECK (app = 'crm');
ALTER TABLE crm.llm_call DROP CONSTRAINT IF EXISTS llm_call_v2_ids_chk;
ALTER TABLE crm.llm_call ADD CONSTRAINT llm_call_v2_ids_chk CHECK (
    (attempt_no IS NULL OR attempt_no >= 1)
    AND (request_id IS NULL OR request_id ~ '^[A-Za-z0-9._:-]{1,128}$')
    AND (connection_key IS NULL OR connection_key ~ '^[a-z][a-z0-9_-]{0,63}$')
    AND (deployment_wire_id IS NULL OR deployment_wire_id ~ '^[A-Za-z0-9._:/-]{1,160}$')
    AND (family IS NULL OR family ~ '^[a-z][a-z0-9_.-]{0,40}$')
    AND (prompt_hash IS NULL OR prompt_hash ~ '^[0-9a-f]{64}$')
    AND (prompt_version IS NULL OR prompt_version ~ '^[A-Za-z0-9._-]{1,40}$'));
ALTER TABLE crm.llm_call DROP CONSTRAINT IF EXISTS llm_call_v2_units_chk;
ALTER TABLE crm.llm_call ADD CONSTRAINT llm_call_v2_units_chk CHECK (
    (cache_read_tokens IS NULL OR cache_read_tokens >= 0)
    AND (cache_write_tokens IS NULL OR cache_write_tokens >= 0)
    AND ((units IS NULL) = (unit_kind IS NULL))
    AND (units IS NULL OR units >= 0)
    AND (unit_kind IS NULL OR unit_kind ~ '^[a-z][a-z_]{0,30}$')
    AND (pricing_mode IS NULL OR pricing_mode ~ '^(override|catalog|code_table|estimate)(\+batch)?(\+geo_us)?$'));

-- ── 2. role CHECK + guard ────────────────────────────────────────────────────────────────────────
ALTER TABLE crm.llm_call DROP CONSTRAINT IF EXISTS llm_call_role_chk;
ALTER TABLE crm.llm_call ADD CONSTRAINT llm_call_role_chk CHECK (role IN ('writer', 'judge', 'validate', 'guard'));

COMMENT ON COLUMN crm.llm_call.app IS 'AA-964 (crm-032): the app of the row under the root ADR 0009 ledger contract; always crm.';
COMMENT ON COLUMN crm.llm_call.attempt_no IS 'AA-964 (crm-032): 1-based attempt of one gateway request (the CRM makes one attempt today).';
COMMENT ON COLUMN crm.llm_call.request_id IS 'AA-964 (crm-032): the provider''s request id (Bedrock RequestId), when it gave one.';
COMMENT ON COLUMN crm.llm_call.job_id IS 'AA-964 (crm-032): the crm.job the call ran in (no FK: crm_job_retention purges job rows).';
COMMENT ON COLUMN crm.llm_call.connection_key IS 'AA-964 (crm-032): the CRM provider connection (stub, bedrock, bedrock_role, bedrock_guardrails), never an account id.';
COMMENT ON COLUMN crm.llm_call.deployment_wire_id IS 'AA-964 (crm-032): the model or operation id sent on the wire (inference profile id, apply_guardrail).';
COMMENT ON COLUMN crm.llm_call.family IS 'AA-964 (crm-032): the model family (claude-haiku, guardrails, stub).';
COMMENT ON COLUMN crm.llm_call.cache_read_tokens IS 'AA-964 (crm-032): prompt-cache tokens read, as the provider reported them.';
COMMENT ON COLUMN crm.llm_call.cache_write_tokens IS 'AA-964 (crm-032): prompt-cache tokens written, as the provider reported them.';
COMMENT ON COLUMN crm.llm_call.units IS 'AA-964 (crm-032): billed units that are not tokens (the guardrail''s text units), with unit_kind.';
COMMENT ON COLUMN crm.llm_call.unit_kind IS 'AA-964 (crm-032): what units counts (text_unit = up to 1000 characters, Bedrock Guardrails).';
COMMENT ON COLUMN crm.llm_call.pricing_mode IS 'AA-964 (crm-032): how cost_usd_est was priced (code_table, estimate, ...; the CIS ledger vocabulary).';
COMMENT ON COLUMN crm.llm_call.prompt_hash IS 'AA-964 (crm-032): sha256 hex of the scrubbed prompt as sent (never the prompt).';
COMMENT ON COLUMN crm.llm_call.prompt_version IS 'AA-964 (crm-032): the version of the CRM prompt template used.';
COMMENT ON COLUMN crm.llm_call.is_shadow IS 'AA-964 (crm-032): an A/B shadow call (none today).';
COMMENT ON COLUMN crm.llm_call.is_experiment IS 'AA-964 (crm-032): an eval or experiment run, not agency traffic (none today).';

-- ── 3. crm.tenant_settings: the month's budget alert ─────────────────────────────────────────────
ALTER TABLE crm.tenant_settings
    ADD COLUMN IF NOT EXISTS ai_alert_month date,
    ADD COLUMN IF NOT EXISTS ai_alert_pct   smallint;
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_ai_alert_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_ai_alert_chk CHECK (
    ((ai_alert_month IS NULL) = (ai_alert_pct IS NULL))
    AND (ai_alert_pct IS NULL OR ai_alert_pct IN (75, 90, 100))
    AND (ai_alert_month IS NULL OR ai_alert_month = date_trunc('month', ai_alert_month::timestamp)::date));
COMMENT ON COLUMN crm.tenant_settings.ai_alert_month IS 'AA-964 (crm-032): the UTC month of the last AI budget alert (first day of the month).';
COMMENT ON COLUMN crm.tenant_settings.ai_alert_pct IS 'AA-964 (crm-032): the highest AI budget alert raised in ai_alert_month: 75, 90 or 100 (R5).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-032', now(), 'AA-964 CRM-33a: crm.llm_call ledger v2 columns (app crm, attempt, request id, job, connection, deployment, family, cache tokens, units, pricing mode, prompt hash and version, shadow / experiment), role guard for the guardrail row; tenant_settings ai_alert_month / ai_alert_pct for the 75 / 90 / 100 % alerts')
ON CONFLICT (version) DO NOTHING;

COMMIT;
