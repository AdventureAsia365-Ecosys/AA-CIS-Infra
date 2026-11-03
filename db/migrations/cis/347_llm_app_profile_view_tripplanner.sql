-- Migration 347: AA-1025 (S263 gateway plan, slice H1b) — TripPlanner's read of its own app profile: the contract
-- view catalog.v_llm_app_profile_v1 over shared.llm_app_profile (migration 345), row app = 'tripplanner' only.
--
-- Why. Root ADR 0009 decision 4: an app profile holds the app-wide switches (AI on / off, bulk paused, the default
-- daily AI budget, the degrade mode). 345 (H1a) made the table, the CIS gateway acts on the 'cis' row and the CIS
-- admin edits every row (AI providers › Providers › App profiles). TripPlanner (AA-TripPlanner-Web
-- backend/shared/app_profile.py, slice H1b) must act on the 'tripplanner' row: AI off = every TripPlanner model call
-- refused (one 0 USD 'refused' / 'disabled' ledger row, the planner degrades to the basic narration and the keyword
-- search), and its daily cap comes from default_daily_budget_usd (every tp_* stage, online and offline). The
-- tripplanner role reads the CIS control plane only through catalog contract views (decision 13, CIS 323), never
-- shared.llm_* itself, so the row is served by a view, like 323's route and spend views. The CRM does not read it
-- (root ADR 0008a §6: the CRM reads no shared.llm_* table; its profile is relayed over crm.ops.v1, slice H1c).
--
-- What:
--   1. Column-level SELECT for catalog_owner (the NOLOGIN owner of every catalog.* view) on shared.llm_app_profile:
--      app, ai_enabled, bulk_paused, default_daily_budget_usd, degrade_mode, updated_at. Not disabled_reason (the
--      admin's free text: TripPlanner does not need it) and not updated_by (a staff id).
--   2. catalog.v_llm_app_profile_v1 (security_barrier, owner catalog_owner): those six columns of the row
--      app = 'tripplanner' (zero rows when the row is missing: TripPlanner then counts AI as on, the CIS rule "no row
--      = AI on"). SELECT to tripplanner only. Contract v1: columns are only appended; a change of meaning is a _v2.
--   3. Register 347.
--
-- Behaviour. None on apply: nothing reads the view until the TripPlanner code of H1b is deployed, and that code reads
-- the view tolerantly (SQLSTATE 42P01 / 42501 before this file is applied: AI on, the cap from its env as today).
-- Nothing in CIS reads the view.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no expand header): a column GRANT on an existing table, a DO guard and
-- the catalog.* recipe (role switch, GRANT / REVOKE CREATE). MIG-4: this migration-only PR, the byte copy in
-- AA-CIS-Infra db/migrations/cis/, Infra Migration Apply once every job table is idle (root ADR 0017a), then the
-- TripPlanner PR (works before and after, see Behaviour). DM-7.1: a view, no new table.
--
-- Guards (RAISE rolls the whole file back): before — 345 registered (the table exists), 323 registered (the catalog
-- contract views and their recipe are in place), schema catalog owned by cis_owner. After, as catalog_owner — the
-- view answers. After, as cis_owner — the view's exact columns, owner catalog_owner, security_barrier, tripplanner can
-- read it, booking, aa_app_user, cis_app and crm_app cannot, tripplanner still has no privilege on
-- shared.llm_app_profile, catalog_owner reads no other column of it and has no other privilege on it, catalog_owner
-- has no CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 323 / 329 / 341): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL
-- ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as cis_owner
-- (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL, no dynamic SQL. The conftest replay skips
-- this file (catalog recipe, 245's owners); tests/integration/test_aa1025_migration_347.py applies it the DB Migrate
-- way and undoes it. A later re-run of 345 (never done by DB Migrate: a registered version is not re-run) would
-- REVOKE the column grant of step 1.
--
-- Number. 346 is the highest on main (03/11). If another lane lands 347 first, renumber to the owner main max + 1
-- (git grep '347_' and '347' in this file, the test and conftest); never the migration:out-of-order label.
--
-- Locks. One column GRANT (no lock that blocks readers or writers of the table) and one CREATE VIEW. lock_timeout 5s,
-- statement_timeout 1min. Idempotent (CREATE OR REPLACE with the same column list, re-runnable grants, ON CONFLICT DO
-- NOTHING), one transaction, self-registering. After apply the DB Schema Dump workflow regenerates
-- docs/architecture/db-schema-reference.md.
--
-- Rollback (a NEW forward migration under the same recipe): DROP VIEW catalog.v_llm_app_profile_v1 (TripPlanner then
-- reads no profile: AI on, cap from its env); REVOKE SELECT (the columns above) ON shared.llm_app_profile FROM
-- catalog_owner.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '345')
       OR to_regclass('shared.llm_app_profile') IS NULL THEN
        RAISE EXCEPTION 'migration 347: apply 345 (shared.llm_app_profile) first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '323') THEN
        RAISE EXCEPTION 'migration 347: apply 323 (the TripPlanner gateway contract views) first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 347: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read (columns only) ────────────────────────────────────────────────────────────────
GRANT SELECT (app, ai_enabled, bulk_paused, default_daily_budget_usd, degrade_mode, updated_at)
    ON shared.llm_app_profile TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 2. The view: TripPlanner's own row ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_llm_app_profile_v1 WITH (security_barrier = true) AS
SELECT p.app,
       p.ai_enabled,
       p.bulk_paused,
       p.default_daily_budget_usd,
       p.degrade_mode,
       p.updated_at
  FROM shared.llm_app_profile p
 WHERE p.app = 'tripplanner';

COMMENT ON VIEW catalog.v_llm_app_profile_v1 IS
    'AA-1025 H1b (347, root ADR 0009 d4 / d13): the app profile row of TripPlanner (shared.llm_app_profile, 345): '
    'ai_enabled false = every TripPlanner model call refused (0 USD refused row, basic narration / keyword search); '
    'default_daily_budget_usd = its daily cap over every tp_* stage. No row = AI on. TripPlanner only. Contract v1: '
    'columns are only appended; a change of meaning is a _v2 view.';

GRANT SELECT ON catalog.v_llm_app_profile_v1 TO tripplanner;

-- ── Closing check as catalog_owner: the view answers ─────────────────────────────────────────────────────────────
DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM catalog.v_llm_app_profile_v1;
    IF n > 1 THEN
        RAISE EXCEPTION 'migration 347: catalog.v_llm_app_profile_v1 shows % rows (at most the tripplanner row)', n;
    END IF;
    RAISE NOTICE 'migration 347: as catalog_owner, % app profile row(s)', n;
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner: columns, owner, barrier, exact consumer grant, column grants ─────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_llm_app_profile_v1';
    r text;
    cols text;
    extra text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 347: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 347: % is not security_barrier', v;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'tripplanner')
       AND NOT pg_catalog.has_table_privilege('tripplanner', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 347: tripplanner cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 347: % can read % (tripplanner only)', r, v;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'app,ai_enabled,bulk_paused,default_daily_budget_usd,degrade_mode,updated_at' THEN
        RAISE EXCEPTION 'migration 347: % columns are %', v, cols;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'tripplanner')
       AND (pg_catalog.has_any_column_privilege('tripplanner', 'shared.llm_app_profile', 'SELECT')
            OR pg_catalog.has_any_column_privilege('tripplanner', 'shared.llm_app_profile', 'UPDATE')) THEN
        RAISE EXCEPTION 'migration 347: tripplanner can read or change shared.llm_app_profile directly';
    END IF;
    SELECT string_agg(a.attname, ', ' ORDER BY a.attname) INTO extra
      FROM pg_attribute a
     WHERE a.attrelid = 'shared.llm_app_profile'::regclass AND a.attnum > 0 AND NOT a.attisdropped
       AND a.attname IN ('disabled_reason', 'updated_by')
       AND pg_catalog.has_column_privilege('catalog_owner', a.attrelid, a.attnum, 'SELECT');
    IF extra IS NOT NULL THEN
        RAISE EXCEPTION 'migration 347: catalog_owner can read shared.llm_app_profile.%', extra;
    END IF;
    IF pg_catalog.has_table_privilege('catalog_owner', 'shared.llm_app_profile', 'SELECT')
       OR pg_catalog.has_any_column_privilege('catalog_owner', 'shared.llm_app_profile', 'INSERT')
       OR pg_catalog.has_any_column_privilege('catalog_owner', 'shared.llm_app_profile', 'UPDATE')
       OR pg_catalog.has_table_privilege('catalog_owner', 'shared.llm_app_profile', 'DELETE') THEN
        RAISE EXCEPTION 'migration 347: catalog_owner has more than column SELECT on shared.llm_app_profile';
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 347: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('347', now(), 'AA-1025 H1b: catalog.v_llm_app_profile_v1 (the tripplanner row of shared.llm_app_profile) for '
                      'TripPlanner; column SELECT for catalog_owner on shared.llm_app_profile')
ON CONFLICT (version) DO NOTHING;

COMMIT;
