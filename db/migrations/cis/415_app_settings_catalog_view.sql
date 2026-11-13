-- Migration 415: S279 thresholds lane L5 (AA-1096) — the contract view catalog.v_app_settings_v1: the settings in
-- force of an app, as that app reads them (TripPlanner today: its 17 keys of CIS 414).
--
-- Why. TripPlanner reads the CIS control plane only through catalog contract views (role tripplanner has USAGE on
-- schema catalog, never on shared; CIS 323 decision 13). Its settings live in shared.setting_definition /
-- shared.setting_value (CIS 407, app 'tripplanner'), edited on admin Platform › Settings, so the values in force have
-- to be served by a view, like the app profile (347) and the tenant AI budget (390).
--
-- What:
--   1. Column-level SELECT for catalog_owner on shared.setting_definition (key, app, default_value, created_at) and
--      shared.setting_value (key, tenant_id, value, version, status, effective_from): no reason, proposer, approver or
--      note (staff free text and actor ids).
--   2. Row-level read for catalog_owner (both tables have FORCE ROW LEVEL SECURITY, CIS 407): policies
--      setting_definition_catalog_owner_read (FOR SELECT, app = 'tripplanner') and setting_value_catalog_owner_read
--      (FOR SELECT, key LIKE 'tripplanner.%'). catalog_owner never sees a CIS, Booking or CRM row, whatever a later
--      view says.
--   3. catalog.v_app_settings_v1 (security_barrier, owner catalog_owner): app, key, value (jsonb), version, tenant_id,
--      effective_from. Per key, one platform row (tenant_id NULL): the approved platform value in force (status
--      approved, effective_from <= now(), the latest by effective_from then version), else the definition's default
--      as version 0 with effective_from = the definition's created_at; plus one row per tenant that has an approved
--      value in force (scope platform+tenant; the trigger of 407 refuses a tenant row of a platform key). A consumer
--      sees only the rows of its own app: app 'tripplanner' rows only to a member of role tripplanner
--      (pg_has_role(current_user, 'tripplanner', 'USAGE'); current_user is the reader, not the view owner). SELECT to
--      tripplanner only. Contract v1: columns are only appended; another app is added by a new migration (its RLS
--      predicate and the view's role mapping together).
--   4. Register 415.
--
-- Behaviour on apply. None for running code: nothing reads the view until the TripPlanner reader of lane L5 is
-- deployed, and that reader feature-detects it (SQLSTATE 42P01 / 42501: it keeps its env values and code defaults).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no '-- migrate:' directive): column GRANTs and policies on existing tables
-- and a view in the catalog schema under the catalog.* recipe (role switch, GRANT / REVOKE CREATE). MIG-4:
-- migration-only PR with 414 (batch cis 414-415); applied on Dev by Infra Migration Apply when the job tables are idle
-- (ADR 0017a). DM-7.1: a view, no new table.
--
-- Guards (RAISE rolls the whole file back): before — 407 and 414 registered, schema catalog owned by cis_owner. After,
-- as catalog_owner — the view answers. After, as cis_owner — the exact columns, owner catalog_owner, security_barrier,
-- tripplanner can read it and booking / aa_app_user / cis_app / crm_app cannot, tripplanner holds no privilege on the
-- two tables, catalog_owner reads exactly the granted columns and has no write on them, the two policies are FOR SELECT
-- TO catalog_owner only, and catalog_owner has no CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 347 / 390 / 410): the grants and policies as cis_owner, then GRANT CREATE ON
-- SCHEMA catalog TO catalog_owner; SET LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE
-- CREATE. Migration Apply / DB Migrate runs the file as cis_owner (login db_migrator). Never RESET ROLE, no SECURITY
-- DEFINER, no role DDL, no dynamic SQL. The conftest replay skips this file (catalog recipe, 245's owners);
-- tests/integration/test_aa1096_migration_415.py applies it the DB Migrate way and undoes it.
--
-- Number. 414 is this lane's first file (413 is the highest on main); if the owner main max + 1 differs at
-- merge, renumber (git grep '415_' and '415' here, in the test and conftest).
--
-- Locks. Column GRANTs and two CREATE POLICY on two small tables (ACCESS EXCLUSIVE for a moment), one CREATE OR REPLACE
-- VIEW. lock_timeout 5s, statement_timeout 1min. Idempotent (policies dropped and re-created, CREATE OR REPLACE with
-- the same column list, re-runnable grants), one transaction, self-registering.
--
-- Rollback (a new forward migration under the same recipe, after the TripPlanner reader is reverted): DROP VIEW
-- catalog.v_app_settings_v1; DROP the two catalog_owner policies; REVOKE the column grants.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '407')
       OR to_regclass('shared.setting_definition') IS NULL OR to_regclass('shared.setting_value') IS NULL THEN
        RAISE EXCEPTION 'migration 415: apply 407 (the settings registry tables) first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '414') THEN
        RAISE EXCEPTION 'migration 415: apply 414 (the TripPlanner settings) first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 415: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read (columns only, re-runnable) ───────────────────────────────────────────────────
GRANT SELECT (key, app, default_value, created_at) ON shared.setting_definition TO catalog_owner;
GRANT SELECT (key, tenant_id, value, version, status, effective_from) ON shared.setting_value TO catalog_owner;

-- ── 2. Which rows catalog_owner may read (FORCE RLS on both tables, CIS 407) ─────────────────────────────────────
DROP POLICY IF EXISTS setting_definition_catalog_owner_read ON shared.setting_definition;
CREATE POLICY setting_definition_catalog_owner_read ON shared.setting_definition AS PERMISSIVE FOR SELECT
    TO catalog_owner USING (app = 'tripplanner');
DROP POLICY IF EXISTS setting_value_catalog_owner_read ON shared.setting_value;
CREATE POLICY setting_value_catalog_owner_read ON shared.setting_value AS PERMISSIVE FOR SELECT
    TO catalog_owner USING (key LIKE 'tripplanner.%');
COMMENT ON POLICY setting_definition_catalog_owner_read ON shared.setting_definition IS
    'S279 L5 (415): catalog.v_app_settings_v1 reads the TripPlanner definitions only.';
COMMENT ON POLICY setting_value_catalog_owner_read ON shared.setting_value IS
    'S279 L5 (415): catalog.v_app_settings_v1 reads the TripPlanner values only.';

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 3. The view ──────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_app_settings_v1 WITH (security_barrier = true) AS
SELECT d.app,
       d.key,
       coalesce(p.value, d.default_value) AS value,
       coalesce(p.version, 0) AS version,
       NULL::uuid AS tenant_id,
       coalesce(p.effective_from, d.created_at) AS effective_from
  FROM shared.setting_definition d
  LEFT JOIN LATERAL (
        SELECT v.value, v.version, v.effective_from
          FROM shared.setting_value v
         WHERE v.key = d.key AND v.tenant_id IS NULL AND v.status = 'approved' AND v.effective_from <= now()
         ORDER BY v.effective_from DESC, v.version DESC
         LIMIT 1
       ) p ON true
 WHERE d.app = 'tripplanner' AND pg_has_role(current_user, 'tripplanner', 'USAGE')
UNION ALL
SELECT d.app,
       d.key,
       t.value,
       t.version,
       t.tenant_id,
       t.effective_from
  FROM shared.setting_definition d
  JOIN LATERAL (
        SELECT DISTINCT ON (v.tenant_id) v.tenant_id, v.value, v.version, v.effective_from
          FROM shared.setting_value v
         WHERE v.key = d.key AND v.tenant_id IS NOT NULL AND v.status = 'approved' AND v.effective_from <= now()
         ORDER BY v.tenant_id, v.effective_from DESC, v.version DESC
       ) t ON true
 WHERE d.app = 'tripplanner' AND pg_has_role(current_user, 'tripplanner', 'USAGE');

COMMENT ON VIEW catalog.v_app_settings_v1 IS
    'S279 thresholds L5 (415, AA-1096): the settings in force of an app (shared.setting_definition / setting_value, '
    'CIS 407; edited on admin Platform > Settings). Per key one platform row (tenant_id NULL: the approved value in '
    'force, else the default as version 0) and one row per tenant with an approved override in force. A reader sees '
    'only its own app''s rows (tripplanner today). Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_app_settings_v1 TO tripplanner;

-- ── Closing check as catalog_owner: the view answers (no row: catalog_owner is not a TripPlanner reader) ─────────
DO $$
BEGIN
    RAISE NOTICE 'migration 415: as catalog_owner, % row(s) visible (0 expected)',
        (SELECT count(*) FROM catalog.v_app_settings_v1);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner ───────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    r text;
    t text;
    cols text;
    granted text;
    pols text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'catalog.v_app_settings_v1'::regclass)
       <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 415: catalog.v_app_settings_v1 is not catalog_owner''s';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'catalog.v_app_settings_v1'::regclass
                    AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 415: catalog.v_app_settings_v1 is not security_barrier';
    END IF;
    IF NOT pg_catalog.has_table_privilege('tripplanner', 'catalog.v_app_settings_v1', 'SELECT') THEN
        RAISE EXCEPTION 'migration 415: tripplanner cannot read catalog.v_app_settings_v1';
    END IF;
    FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, 'catalog.v_app_settings_v1', 'SELECT') THEN
            RAISE EXCEPTION 'migration 415: % can read catalog.v_app_settings_v1 (tripplanner only)', r;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a
     WHERE a.attrelid = 'catalog.v_app_settings_v1'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'app text, key text, value jsonb, version integer, tenant_id uuid, '
                             'effective_from timestamp with time zone' THEN
        RAISE EXCEPTION 'migration 415: catalog.v_app_settings_v1 columns are %', cols;
    END IF;
    FOREACH t IN ARRAY ARRAY['shared.setting_definition', 'shared.setting_value'] LOOP
        IF pg_catalog.has_any_column_privilege('tripplanner', t, 'SELECT')
           OR pg_catalog.has_any_column_privilege('tripplanner', t, 'INSERT')
           OR pg_catalog.has_any_column_privilege('tripplanner', t, 'UPDATE') THEN
            RAISE EXCEPTION 'migration 415: tripplanner can read or change % directly', t;
        END IF;
        IF pg_catalog.has_table_privilege('catalog_owner', t, 'SELECT')
           OR pg_catalog.has_any_column_privilege('catalog_owner', t, 'INSERT')
           OR pg_catalog.has_any_column_privilege('catalog_owner', t, 'UPDATE')
           OR pg_catalog.has_table_privilege('catalog_owner', t, 'DELETE') THEN
            RAISE EXCEPTION 'migration 415: catalog_owner has more than column SELECT on %', t;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname, ',' ORDER BY a.attname) INTO granted
      FROM pg_attribute a
     WHERE a.attrelid = 'shared.setting_value'::regclass AND a.attnum > 0 AND NOT a.attisdropped
       AND pg_catalog.has_column_privilege('catalog_owner', a.attrelid, a.attnum, 'SELECT');
    IF granted IS DISTINCT FROM 'effective_from,key,status,tenant_id,value,version' THEN
        RAISE EXCEPTION 'migration 415: catalog_owner reads shared.setting_value columns %', granted;
    END IF;
    SELECT string_agg(p.polname || ':' || p.polcmd::text || ':' || pg_get_userbyid(p.polroles[1]), ','
                      ORDER BY p.polname)
      INTO pols
      FROM pg_policy p
     WHERE p.polrelid IN ('shared.setting_definition'::regclass, 'shared.setting_value'::regclass)
       AND p.polname LIKE '%catalog_owner%';
    IF pols IS DISTINCT FROM 'setting_definition_catalog_owner_read:r:catalog_owner,'
                             'setting_value_catalog_owner_read:r:catalog_owner' THEN
        RAISE EXCEPTION 'migration 415: catalog_owner policies are %', pols;
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 415: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('415', now(), 'S279 thresholds L5: catalog.v_app_settings_v1 (the TripPlanner settings in force)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
