-- Migration 455: AA-1143 (tech lead decision G3, S285 19/11/2026; root ADR 0009 decision 6) — one budget per LLM
-- connection as rows: the connection's total (its provider budget) and one fixed-USD share row per app, CIS taking the
-- remainder. The table and its rules; CIS 456 (same PR) seeds it from today's values and publishes it to TripPlanner.
--
-- Why. A connection's monthly budget lived in three places kept in sum by hand: the provider budget (setting
-- cis.spend.connection_provider_budget_usd, CIS 453), the CIS share (shared.llm_provider_connection.monthly_budget_usd)
-- and the CRM share (CRM setting crm.ai.connection_monthly_cap_usd, crm-077). Giving the CRM 5 USD on acc1 meant a
-- second, manual edit of the CIS share on another page (100 -> 95). TripPlanner had no share at all (counted inside the
-- CIS share) and Booking none. Decision G3: budgets are rows (app, connection_key); an app's share is a row, CIS gets
-- the remainder automatically, so adding a share for one app never needs an edit elsewhere.
--
-- What:
--   1. shared.llm_connection_budget, append-only and versioned like Settings (every change is a new row; the row with
--      the highest version of a (connection_key, app) pair is in force; rows are never updated or deleted):
--        id              bigint identity
--        connection_key  the registry connection (FK shared.llm_provider_connection)
--        app             NULL = the connection's total (its provider budget); else an app of shared.llm_app_profile
--                        (FK) other than cis: CIS has no row, its share is the remainder
--        budget_usd      USD per calendar month (UTC), 0..1000000 (the bound of monthly_budget_usd and of the CIS 453
--                        setting); NULL on an app row = that app's share is removed (a total is never removed)
--        version         1, 2, ... per (connection_key, app); UNIQUE NULLS NOT DISTINCT
--        reason          why, 20..500 characters (the Settings rule); actor (staff id, migration:<n>), valid_from
--   2. shared.llm_connection_budget_current (view): the row in force per (connection_key, app), removed shares left out.
--   3. Two triggers:
--        - llm_connection_budget_append_only (BEFORE UPDATE / DELETE, and BEFORE TRUNCATE): refuses both;
--        - llm_connection_budget_apply (AFTER INSERT, FOR EACH STATEMENT with the transition table, so it runs once on
--          the rows in force after the whole statement; not deferred: X1 forbids trigger work after the role switch's
--          post-check): refuses a statement that leaves a connection's app shares adding up to more than its total (no
--          over-allocation is ever stored), and sets the connection's
--          shared.llm_provider_connection.monthly_budget_usd to the CIS remainder (total minus the other apps' shares).
--          monthly_budget_usd stays the number the CIS gateway enforces (shared/llm_client/connection_budget.py, the
--          registry cache: no new read on the call path), so the remainder follows any share in the same transaction;
--          the CIS admin API refuses a direct edit of it for a connection that has a total (AA-CIS-App code PR).
--   4. Grants: cis_app SELECT, INSERT on the table (an identity column needs no sequence grant), SELECT on the view. No other role:
--      TripPlanner reads through the catalog view of CIS 456, the CRM through its own copy (crm.ops.v1, root ADR
--      0008a: no grant either way).
--   5. Register 455.
--
-- Behaviour on apply. None: the table is empty until CIS 456 seeds it; no running code reads it (the code PR feature-
-- detects it, SQLSTATE 42P01 keeps today's reads).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): new objects only (table, view, functions,
-- triggers, grants on them), but written with re-runnable DDL (CREATE OR REPLACE, DROP TRIGGER IF EXISTS) and guard
-- blocks, which the expand lint does not take; it ships in one migration-only PR with the contract file 456 (batch cis
-- 455-456) anyway, applied together by Infra Migration Apply. DM-6.1: no personal data (actor is a staff id, as in Settings). DM-7.1:
-- one new table, its retention row is in root docs/architecture/data-standards/02-data-management.md (kept: a config
-- audit trail of a few rows a month). MIG-6: no SECURITY DEFINER routine (the apply trigger runs as the writer: cis_app
-- holds UPDATE on monthly_budget_usd, updated_at, updated_by since 310).
--
-- Number. 454 is the newest CIS migration on main. If the owner main max + 1 differs at merge, renumber 455 and 456
-- together (git grep '455_' and '456_', 'CIS 455', 'CIS 456' here, in tests/integration/test_aa1143_migration_455_456.py,
-- tests/integration/conftest.py, shared/settings/compiled_defaults.json and docs/implementation-notes/AA-1143.md; the
-- AA-TripPlanner-Web and AA-Partner code name them too).
--
-- Locks. CREATE TABLE / VIEW / FUNCTION / TRIGGER on new objects; the two FKs take a SHARE ROW EXCLUSIVE lock on the
-- referenced tables (eleven and four rows) for milliseconds. lock_timeout 5s. Idempotent (IF NOT EXISTS, CREATE OR
-- REPLACE, DROP TRIGGER IF EXISTS before CREATE TRIGGER, ON CONFLICT DO NOTHING), one transaction, self-registering.
--
-- Rollback (a new forward migration, after the code PRs are reverted and CIS 456's view dropped): DROP VIEW
-- shared.llm_connection_budget_current; DROP TABLE shared.llm_connection_budget; DROP FUNCTION
-- shared.llm_connection_budget_append_only(), shared.llm_connection_budget_apply(). monthly_budget_usd keeps the last
-- remainder, which the CIS gateway keeps enforcing.

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.llm_provider_connection') IS NULL THEN
        RAISE EXCEPTION 'migration 455: shared.llm_provider_connection missing (apply 304 first)';
    END IF;
    IF to_regclass('shared.llm_app_profile') IS NULL THEN
        RAISE EXCEPTION 'migration 455: shared.llm_app_profile missing (apply 345 first)';
    END IF;
END $$;

-- ── 1. The table ─────────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.llm_connection_budget (
    id              bigint       GENERATED ALWAYS AS IDENTITY,
    connection_key  text         NOT NULL,
    app             text,
    budget_usd      numeric(10,2),
    version         integer      NOT NULL,
    reason          text         NOT NULL,
    actor           text         NOT NULL,
    valid_from      timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT llm_connection_budget_pkey PRIMARY KEY (id),
    CONSTRAINT llm_connection_budget_connection_fkey FOREIGN KEY (connection_key)
        REFERENCES shared.llm_provider_connection (connection_key),
    CONSTRAINT llm_connection_budget_app_fkey FOREIGN KEY (app) REFERENCES shared.llm_app_profile (app),
    CONSTRAINT llm_connection_budget_version_key UNIQUE NULLS NOT DISTINCT (connection_key, app, version),
    CONSTRAINT llm_connection_budget_cis_check CHECK (app IS DISTINCT FROM 'cis'),
    CONSTRAINT llm_connection_budget_usd_check CHECK (budget_usd IS NULL OR (budget_usd >= 0 AND budget_usd <= 1000000)),
    CONSTRAINT llm_connection_budget_total_check CHECK (app IS NOT NULL OR budget_usd IS NOT NULL),
    CONSTRAINT llm_connection_budget_version_check CHECK (version >= 1),
    CONSTRAINT llm_connection_budget_reason_check CHECK (char_length(btrim(reason)) BETWEEN 20 AND 500),
    CONSTRAINT llm_connection_budget_actor_check CHECK (char_length(actor) BETWEEN 1 AND 128)
);

COMMENT ON TABLE shared.llm_connection_budget IS
    'AA-1143 (CIS 455, decision G3): the monthly budget of each LLM connection as versioned rows: app NULL = the '
    'connection''s total (its provider budget), else one app''s fixed-USD share; CIS has no row, it takes the remainder '
    '(total minus the other apps'' shares), written to llm_provider_connection.monthly_budget_usd at commit. '
    'Append-only: a change is a new version; the highest version of a (connection_key, app) pair is in force '
    '(shared.llm_connection_budget_current). Edited on CIS AI gateway > Budgets.';
COMMENT ON COLUMN shared.llm_connection_budget.app IS
    'AA-1143 (455): NULL = the connection''s total; else an app of shared.llm_app_profile other than cis.';
COMMENT ON COLUMN shared.llm_connection_budget.budget_usd IS
    'AA-1143 (455): USD per UTC calendar month; NULL on an app row = the share is removed (that app has no share).';

-- ── 2. The rows in force ─────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW shared.llm_connection_budget_current AS
SELECT c.connection_key, c.app, c.budget_usd, c.version, c.reason, c.actor, c.valid_from
  FROM (SELECT DISTINCT ON (b.connection_key, b.app)
               b.connection_key, b.app, b.budget_usd, b.version, b.reason, b.actor, b.valid_from
          FROM shared.llm_connection_budget b
         ORDER BY b.connection_key, b.app, b.version DESC) c
 WHERE c.budget_usd IS NOT NULL;

COMMENT ON VIEW shared.llm_connection_budget_current IS
    'AA-1143 (CIS 455): the row in force per (connection_key, app) of shared.llm_connection_budget (app NULL = the '
    'total); a removed share has no row.';

-- ── 3. The rules ─────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION shared.llm_connection_budget_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'shared.llm_connection_budget is append-only: write a new version instead (%)', TG_OP
        USING ERRCODE = 'check_violation';
END
$fn$;

CREATE OR REPLACE FUNCTION shared.llm_connection_budget_apply() RETURNS trigger
    LANGUAGE plpgsql AS $fn$
DECLARE
    r        record;
    v_total  numeric;
    v_shares numeric;
    v_cis    numeric;
BEGIN
    -- One pass per connection the statement wrote, on the rows in force after the whole statement.
    FOR r IN
        SELECT n.connection_key, (array_agg(n.actor ORDER BY n.id DESC))[1] AS actor
          FROM new_rows n
         GROUP BY n.connection_key
    LOOP
        SELECT budget_usd INTO v_total
          FROM shared.llm_connection_budget_current
         WHERE connection_key = r.connection_key AND app IS NULL;
        IF v_total IS NULL THEN
            RAISE EXCEPTION 'connection %: an app share needs the connection''s total first', r.connection_key
                USING ERRCODE = 'check_violation';
        END IF;
        SELECT coalesce(sum(budget_usd), 0) INTO v_shares
          FROM shared.llm_connection_budget_current
         WHERE connection_key = r.connection_key AND app IS NOT NULL;
        IF v_shares > v_total THEN
            RAISE EXCEPTION 'connection %: the app shares (% USD) add up to more than the total (% USD)',
                r.connection_key, v_shares, v_total USING ERRCODE = 'check_violation';
        END IF;
        v_cis := v_total - v_shares;
        UPDATE shared.llm_provider_connection
           SET monthly_budget_usd = v_cis, updated_at = now(), updated_by = left(r.actor, 128)
         WHERE connection_key = r.connection_key
           AND monthly_budget_usd IS DISTINCT FROM v_cis;
    END LOOP;
    RETURN NULL;
END
$fn$;

COMMENT ON FUNCTION shared.llm_connection_budget_apply() IS
    'AA-1143 (CIS 455): after each INSERT statement, refuses app shares above the connection''s total and sets '
    'llm_provider_connection.monthly_budget_usd to the CIS remainder (what the CIS gateway enforces).';

DROP TRIGGER IF EXISTS llm_connection_budget_append_only ON shared.llm_connection_budget;
CREATE TRIGGER llm_connection_budget_append_only
    BEFORE UPDATE OR DELETE ON shared.llm_connection_budget
    FOR EACH ROW EXECUTE FUNCTION shared.llm_connection_budget_append_only();
DROP TRIGGER IF EXISTS llm_connection_budget_append_only_truncate ON shared.llm_connection_budget;
CREATE TRIGGER llm_connection_budget_append_only_truncate
    BEFORE TRUNCATE ON shared.llm_connection_budget
    FOR EACH STATEMENT EXECUTE FUNCTION shared.llm_connection_budget_append_only();
DROP TRIGGER IF EXISTS llm_connection_budget_apply ON shared.llm_connection_budget;
CREATE TRIGGER llm_connection_budget_apply
    AFTER INSERT ON shared.llm_connection_budget
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION shared.llm_connection_budget_apply();

-- ── 4. Grants ────────────────────────────────────────────────────────────────────────────────────────────────────
GRANT SELECT, INSERT ON shared.llm_connection_budget TO cis_app;
GRANT SELECT ON shared.llm_connection_budget_current TO cis_app;

-- ── 5. Register ──────────────────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('455', now(), 'AA-1143: shared.llm_connection_budget (connection total + per-app shares, CIS takes the remainder)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
