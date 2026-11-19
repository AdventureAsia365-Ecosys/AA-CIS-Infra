-- Migration crm-079: AA-1143 (tech lead decision G3, S285 19/11/2026; root ADR 0009 decision 6, root ADR 0008a §6) —
-- the CRM's copy of its monthly share of each LLM connection's budget, sent by CIS over crm.ops.v1.
--
-- Owner: AA-Partner (api/migrations/079_crm_llm_connection_share.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy DB Migrate applies (Migration Copy Guard). Key crm-079 follows crm-078 (the CRM draft route on acc1, already on
-- main).
--
-- Why: decision G3 makes a connection's budget one set of rows in CIS (shared.llm_connection_budget, CIS 455 / 456):
-- the connection's total and one fixed-USD share per app, CIS taking the remainder, edited on one screen (CIS AI
-- gateway > Budgets). The CRM reads no CIS table (ADR 0008a §6), so, as with its app profile (crm-041), CIS sends the
-- CRM its own part: PUT /crm/ops/v1/llm/connection-shares (crm.ops.v1 1.16, the staff member's own WORKFORCE token,
-- crm-platform-admin) replaces the whole copy: every CIS connection that has a total, with the CRM's share or 0. The
-- CRM gateway reads its cap per connection from here (app.llm.connection_share), and for one release falls back to
-- the setting crm.ai.connection_monthly_cap_usd (crm-077) for a connection the copy does not name. The setting is
-- retired in a later contract step.
--
-- What:
--   1. crm.llm_connection_share (platform table: AA's configuration, no tenant column, no personal data), one row per
--      CIS connection key (the CIS registry's key shape ^[a-z0-9][a-z0-9-]{1,62}$, the primary key): share_usd (USD per
--      UTC calendar month, 0..1000000, numeric(10,2) like CIS 455; 0 = the CRM may not spend there), reason (the CIS
--      save's reason, 20..500 characters), updated_at, updated_by (platform:<staff sub>). No seed row: an empty table =
--      no copy yet, the old setting applies.
--   2. Grants: REVOKE ALL from crm_app first (crm-001's default privileges), then SELECT, INSERT, UPDATE, DELETE (a PUT
--      replaces the whole copy). No reader grant. No RLS: no tenant rows (listed in the platform tables of the
--      catalogue guard, api/tests/integration/test_crm002_tenancy.py).
--   3. Register crm-079.
--
-- Class: contract (root ADR 0017 d3): the REVOKE of step 2 is refused by the expand lint (as crm-041). No "-- migrate:"
-- line: MIG-4 order, this migration-only PR (with crm-078), the Infra copy (the root DM-7.1 retention row for the new
-- table merges before it), Infra Migration Apply once every job table is idle (root ADR 0017a), then the code PR. The
-- code reads the table only after a to_regclass check (no readiness raise needed).
--
-- Order: after crm-078. Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent
-- (IF NOT EXISTS, re-runnable REVOKE / GRANT, ON CONFLICT DO NOTHING).
-- Rollback: a forward crm- file (MIG-14) after the code that reads it is reverted: DROP TABLE crm.llm_connection_share
-- (a destructive file, DRY RUN).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ── Guard 0: runs as the owner, after crm-078 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-079: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-078') THEN
        RAISE EXCEPTION 'crm-079: crm-078 (AA-1138, the CRM draft route) lands first';
    END IF;
END $$;

-- ── 1. crm.llm_connection_share ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.llm_connection_share (
    connection_key TEXT PRIMARY KEY,
    share_usd      NUMERIC(10, 2) NOT NULL,
    reason         TEXT NOT NULL,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by     TEXT NOT NULL,
    CONSTRAINT llm_connection_share_key_chk CHECK (connection_key ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
    CONSTRAINT llm_connection_share_usd_chk CHECK (share_usd >= 0 AND share_usd <= 1000000),
    CONSTRAINT llm_connection_share_reason_chk CHECK (char_length(btrim(reason)) BETWEEN 20 AND 500),
    CONSTRAINT llm_connection_share_by_chk CHECK (updated_by ~ '^[A-Za-z0-9._:@-]{1,120}$')
);
REVOKE ALL ON crm.llm_connection_share FROM crm_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON crm.llm_connection_share TO crm_app;
COMMENT ON TABLE crm.llm_connection_share IS 'AA-1143 (crm-079, decision G3): the CRM''s copy of its monthly share of each LLM connection''s budget (CIS shared.llm_connection_budget), one row per CIS connection key, written whole by the CIS admin over crm.ops.v1 PUT /llm/connection-shares. The CRM gateway''s cap per connection; 0 = no spend there. Empty = no copy yet (the setting crm.ai.connection_monthly_cap_usd applies for one release). Platform configuration, no tenant column, no PII.';
COMMENT ON COLUMN crm.llm_connection_share.share_usd IS 'AA-1143 (crm-079): USD per UTC calendar month the CRM may spend on the connection (every agency together, crm.llm_usage_daily).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-079', now(), 'AA-1143: crm.llm_connection_share (the CRM copy of its connection budget shares, sent by CIS), crm_app SELECT, INSERT, UPDATE, DELETE')
ON CONFLICT (version) DO NOTHING;

COMMIT;
