-- Migration 321: AA-1016 (per-tenant AI budget) + AA-900 (prompt registry) — two empty tables for the AI gateway v2.
--
-- Why. A Content studio tenant had rewrite quotas and an HTTP rate limit but no AI spend budget in USD, so one tenant
-- could use a large share of the shared model quota with no alert (capacity plan S261 §2.4, AA-1016). A prompt change
-- had no register: the ledger could not say which version of a stage's prompt a call ran (AA-900; ledger v2,
-- migration 319, added llm_call_log.prompt_hash / prompt_version, and needs a table to resolve a version from).
--
-- What.
--   1. shared.tenant_ai_budget (tenant_id PK FK -> shared.tenants ON DELETE CASCADE, monthly_usd, alert_pct,
--      approval_pct, hard_stop, notes, audit columns). NO ROWS: a tenant without a row has no AI budget (unlimited,
--      today's behaviour). monthly_usd NULL = unlimited. alert_pct (default 100) = the bell; approval_pct (default
--      150) = from there new T-stage jobs wait for staff approval when hard_stop is on (AA-1016: no silent cut-off).
--      Written by the admin (cis_app SELECT / INSERT / UPDATE / DELETE: the budget PUT of AA-1016 UI and the tenant
--      erasure); read by the gateway's tenant budget check (AA-1016 enforcement, a later code slice).
--   2. shared.prompt_version (stage, version) PK, prompt_sha256, source_path, notes, created_at, created_by; UNIQUE
--      (stage, prompt_sha256). Stores NO prompt text: only the sha256 of the prompt file and its repository path.
--      NO ROWS (the CI prompt-registry gate of AA-900 registers them). cis_app SELECT only: rows come by migration.
--   3. Register 321.
--   tripplanner and the tenant pool (aa_app_user) get nothing. Each table's grants start with REVOKE ALL from PUBLIC,
--   cis_app, aa_app_user and catalog_owner: on Dev DB Migrate creates the tables as cis_owner, whose default privileges
--   in shared (CIS 245) would otherwise leave cis_app INSERT / UPDATE / DELETE on prompt_version.
--
-- Behaviour. None on apply: two new empty tables, nothing reads them yet.
--
-- Class: contract (root ADR 0017 d3) like the other files of this PR (320); the content is additive only (two new
-- tables, an FK to shared.tenants from the new table). Applied with 320 and 322 in one DB Migrate run.
-- Order (ADR 0017 d1, MIG-4): (1) this migration-only PR (320 + 321) merges to AA-CIS-App main; (2) the byte copy in
-- AA-CIS-Infra db/migrations/cis/ merges; (3) a manual DB Migrate apply; (4) the bot/db-schema-reference PR merges.
-- DM-7.1: both tables have their retention row in the root repo (docs/architecture/data-standards/
-- 02-data-management.md), merged before the Infra copy.
--
-- Rollback (a NEW forward migration, after the code that reads them is reverted):
--   DROP TABLE shared.prompt_version; DROP TABLE shared.tenant_ai_budget;                          (a destructive file)
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared's
-- tables (shared.tenants included).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.tenants') IS NULL THEN
        RAISE EXCEPTION 'migration 321: shared.tenants is missing';
    END IF;
END $$;

-- ── 1. shared.tenant_ai_budget ───────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS shared.tenant_ai_budget (
    tenant_id     uuid          PRIMARY KEY REFERENCES shared.tenants (tenant_id) ON DELETE CASCADE,
    monthly_usd   numeric(10,2),
    alert_pct     smallint      NOT NULL DEFAULT 100,
    approval_pct  smallint      NOT NULL DEFAULT 150,
    hard_stop     boolean       NOT NULL DEFAULT false,
    notes         text,
    created_at    timestamptz   NOT NULL DEFAULT now(),
    updated_at    timestamptz   NOT NULL DEFAULT now(),
    updated_by    text          NOT NULL,
    CONSTRAINT tenant_ai_budget_monthly_check CHECK (monthly_usd IS NULL OR monthly_usd >= 0),
    CONSTRAINT tenant_ai_budget_alert_pct_check CHECK (alert_pct BETWEEN 1 AND 1000),
    CONSTRAINT tenant_ai_budget_approval_pct_check CHECK (approval_pct BETWEEN 1 AND 1000 AND approval_pct >= alert_pct),
    CONSTRAINT tenant_ai_budget_notes_check CHECK (notes IS NULL OR length(notes) <= 2000)
);

COMMENT ON TABLE shared.tenant_ai_budget IS
    'AA-1016: the monthly AI spend budget of a Content studio tenant (USD, from llm_call_log rows of that tenant). '
    'No row = no budget (unlimited). alert_pct = bell; approval_pct = new T-stage jobs wait for staff approval when '
    'hard_stop. Admin-written, erased with the tenant.';

REVOKE ALL ON shared.tenant_ai_budget FROM PUBLIC;
REVOKE ALL ON shared.tenant_ai_budget FROM cis_app, aa_app_user, catalog_owner;   -- cis_owner's default privileges
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.tenant_ai_budget TO cis_app;

-- ── 2. shared.prompt_version (no prompt text) ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS shared.prompt_version (
    stage          text         NOT NULL,
    version        text         NOT NULL,
    prompt_sha256  text         NOT NULL,
    source_path    text         NOT NULL,
    notes          text,
    created_at     timestamptz  NOT NULL DEFAULT now(),
    created_by     text         NOT NULL,
    PRIMARY KEY (stage, version),
    CONSTRAINT prompt_version_stage_check CHECK (stage ~ '^[a-z0-9][a-z0-9_]{0,62}$'),
    CONSTRAINT prompt_version_version_check CHECK (version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'),
    CONSTRAINT prompt_version_sha_check CHECK (prompt_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT prompt_version_path_check CHECK (
        length(source_path) <= 300 AND source_path ~ '^[A-Za-z0-9_][A-Za-z0-9_./-]*$'
        AND position('..' IN source_path) = 0),
    CONSTRAINT prompt_version_notes_check CHECK (notes IS NULL OR length(notes) <= 500)
);

CREATE UNIQUE INDEX IF NOT EXISTS prompt_version_stage_sha_uq ON shared.prompt_version (stage, prompt_sha256);

COMMENT ON TABLE shared.prompt_version IS
    'AA-900: the prompt register. One row per (stage, version): the sha256 of the prompt file and its path in the '
    'repository. Never the prompt text. Resolves llm_call_log.prompt_version from a prompt hash. Changed by migration.';

REVOKE ALL ON shared.prompt_version FROM PUBLIC;
REVOKE ALL ON shared.prompt_version FROM cis_app, aa_app_user, catalog_owner;   -- cis_owner's default privileges
GRANT SELECT ON shared.prompt_version TO cis_app;

-- ── 3. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('321', now(), 'AA-1016 shared.tenant_ai_budget (no rows) + AA-900 shared.prompt_version (no prompt text)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
