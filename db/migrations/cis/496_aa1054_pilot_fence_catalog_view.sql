-- Migration 496: AA-1054 (S297; tech lead decision S295 sec-Q11) — the contract view catalog.v_pilot_fence_v1: the pilot
-- fence switch in force (CIS 495, cis.platform.pilot_e2e_fence), as AA-Booking reads it.
--
-- Why. The pilot fence is ONE switch for CIS and Booking: an administrator turns it on on Platform › Settings (audited,
-- maker-checker) and both APIs refuse every Dev-only E2E staff identity from then on. Booking reads the CIS control
-- plane only through catalog contract views (role booking has USAGE on schema catalog, never on shared; CIS 323
-- decision 13), so it gets the value in force through this read-only view and holds no grant on the settings tables:
-- no app writes another app's data.
--
-- What:
--   1. Column-level SELECT for catalog_owner on shared.setting_definition (key, app, default_value, created_at) and
--      shared.setting_value (key, tenant_id, value, version, status, effective_from), the same columns CIS 415 grants
--      (re-runnable): no reason, proposer, approver or note.
--   2. Row-level read for catalog_owner of this one key (both tables have FORCE ROW LEVEL SECURITY, CIS 407): policies
--      setting_definition_pilot_fence_read and setting_value_pilot_fence_read (FOR SELECT TO catalog_owner, key =
--      'cis.platform.pilot_e2e_fence'; the value policy also tenant_id IS NULL). Permissive, so they add exactly this key
--      to what CIS 415's TripPlanner policies show catalog_owner; no other CIS, Booking or CRM row becomes readable.
--      (The policy names leave out "catalog_owner" on purpose: CIS 415's closing check lists that name pattern.)
--   3. catalog.v_pilot_fence_v1 (security_barrier, owner catalog_owner): fence_on (boolean), version (integer),
--      effective_from (timestamptz). One row while 495's definition exists: the approved platform value in force
--      (status approved, effective_from <= now(), the latest by effective_from then version), else the definition's
--      default as version 0 with effective_from = the definition's created_at. A stored value that is not a JSON
--      boolean reads as fence_on TRUE (fail closed; the CIS 407 value guard refuses such a value anyway). No row when
--      the definition is missing: Booking then treats the fence as unknown and refuses the E2E identities. SELECT to
--      booking only. Contract v1: columns are only appended.
--   4. Register 496.
--
-- Behaviour on apply. None for running code: nothing reads the view until the AA-Booking pilot fence reader is deployed
-- (MIG-4 chain: cis/496 applied before the Booking code PR).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): column GRANTs and policies on existing tables
-- and a view in the catalog schema under the catalog.* recipe (role switch, GRANT / REVOKE CREATE). MIG-4: migration-only
-- PR with 495 (batch cis 495-496); applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a).
-- DM-6.1: no personal data. DM-7.1: a view, no new table.
--
-- Guards (RAISE rolls the whole file back): before — 407 and 495 registered, schema catalog owned by cis_owner.
-- After, as catalog_owner — the view answers exactly one row. After, as cis_owner — the exact columns, owner
-- catalog_owner, security_barrier, booking can read it and tripplanner / aa_app_user / cis_app / crm_app cannot, booking
-- holds no privilege on the two tables, catalog_owner has no write on them, the two new policies are FOR SELECT TO
-- catalog_owner only, and catalog_owner has no CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 357 / 415): the grants and policies as cis_owner, then GRANT CREATE ON SCHEMA
-- catalog TO catalog_owner; SET LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE.
-- Migration Apply / DB Migrate runs the file as cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER,
-- no role DDL, no dynamic SQL. The conftest replay skips this file (catalog recipe, 245's owners);
-- tests/integration/test_aa1054_migration_496.py applies it the DB Migrate way and undoes it.
--
-- Number. 495 + 1, in the same PR. If the owner main max + 1 differs at merge, renumber both (see 495).
--
-- Locks. Column GRANTs and two CREATE POLICY on two small tables (ACCESS EXCLUSIVE for a moment), one CREATE OR REPLACE
-- VIEW. lock_timeout 5s, statement_timeout 1min. Idempotent (policies dropped and re-created, CREATE OR REPLACE with the
-- same column list, re-runnable grants), one transaction, self-registering.
--
-- Rollback (a new forward migration under the same recipe, after the Booking reader is reverted): DROP VIEW
-- catalog.v_pilot_fence_v1; DROP the two pilot_fence policies (keep 415's column grants: its view needs them).

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '407')
       OR to_regclass('shared.setting_definition') IS NULL OR to_regclass('shared.setting_value') IS NULL THEN
        RAISE EXCEPTION 'migration 496: apply 407 (the settings registry tables) first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '495')
       OR NOT EXISTS (SELECT 1 FROM shared.setting_definition WHERE key = 'cis.platform.pilot_e2e_fence') THEN
        RAISE EXCEPTION 'migration 496: apply 495 (the pilot fence setting) first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 496: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read (columns only, the CIS 415 set, re-runnable) ─────────────────────────────────
GRANT SELECT (key, app, default_value, created_at) ON shared.setting_definition TO catalog_owner;
GRANT SELECT (key, tenant_id, value, version, status, effective_from) ON shared.setting_value TO catalog_owner;

-- ── 2. Which rows catalog_owner may read: this one key (FORCE RLS on both tables, CIS 407) ───────────────────────
DROP POLICY IF EXISTS setting_definition_pilot_fence_read ON shared.setting_definition;
CREATE POLICY setting_definition_pilot_fence_read ON shared.setting_definition AS PERMISSIVE FOR SELECT
    TO catalog_owner USING (key = 'cis.platform.pilot_e2e_fence');
DROP POLICY IF EXISTS setting_value_pilot_fence_read ON shared.setting_value;
CREATE POLICY setting_value_pilot_fence_read ON shared.setting_value AS PERMISSIVE FOR SELECT
    TO catalog_owner USING (key = 'cis.platform.pilot_e2e_fence' AND tenant_id IS NULL);
COMMENT ON POLICY setting_definition_pilot_fence_read ON shared.setting_definition IS
    'AA-1054 (496): catalog.v_pilot_fence_v1 reads the pilot fence definition only.';
COMMENT ON POLICY setting_value_pilot_fence_read ON shared.setting_value IS
    'AA-1054 (496): catalog.v_pilot_fence_v1 reads the pilot fence platform values only.';

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 3. The view: one row, the switch in force ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_pilot_fence_v1 WITH (security_barrier = true) AS
SELECT CASE WHEN jsonb_typeof(coalesce(p.value, d.default_value)) = 'boolean'
            THEN (coalesce(p.value, d.default_value) #>> '{}')::boolean
            ELSE true END AS fence_on,
       coalesce(p.version, 0) AS version,
       coalesce(p.effective_from, d.created_at) AS effective_from
  FROM shared.setting_definition d
  LEFT JOIN LATERAL (
        SELECT v.value, v.version, v.effective_from
          FROM shared.setting_value v
         WHERE v.key = d.key AND v.tenant_id IS NULL AND v.status = 'approved' AND v.effective_from <= now()
         ORDER BY v.effective_from DESC, v.version DESC
         LIMIT 1
       ) p ON true
 WHERE d.key = 'cis.platform.pilot_e2e_fence';

COMMENT ON VIEW catalog.v_pilot_fence_v1 IS
    'AA-1054 (496, root ADR 0006a pilot fence): the pilot fence switch in force (shared.setting_definition / '
    'setting_value key cis.platform.pilot_e2e_fence, CIS 495; edited on admin Platform > Settings). One row: fence_on '
    '(a stored value that is not a boolean reads TRUE), the approved version in force (0 = the default) and since when. '
    'No row = the definition is missing: the reader treats the fence as unknown and refuses the Dev-only E2E staff '
    'identities. Booking only. Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_pilot_fence_v1 TO booking;

-- ── Closing check as catalog_owner: the view answers exactly one row ─────────────────────────────────────────────
DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM catalog.v_pilot_fence_v1;
    IF n <> 1 THEN
        RAISE EXCEPTION 'migration 496: as catalog_owner, catalog.v_pilot_fence_v1 answers % rows (1 expected)', n;
    END IF;
    RAISE NOTICE 'migration 496: pilot fence on = %', (SELECT fence_on FROM catalog.v_pilot_fence_v1);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner ───────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_pilot_fence_v1';
    r text;
    t text;
    cols text;
    pols text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 496: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 496: % is not security_barrier', v;
    END IF;
    IF NOT pg_catalog.has_table_privilege('booking', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 496: booking cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 496: % can read % (booking only)', r, v;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'fence_on boolean, version integer, effective_from timestamp with time zone' THEN
        RAISE EXCEPTION 'migration 496: % columns are %', v, cols;
    END IF;
    FOREACH t IN ARRAY ARRAY['shared.setting_definition', 'shared.setting_value'] LOOP
        IF pg_catalog.has_any_column_privilege('booking', t, 'SELECT')
           OR pg_catalog.has_any_column_privilege('booking', t, 'INSERT')
           OR pg_catalog.has_any_column_privilege('booking', t, 'UPDATE') THEN
            RAISE EXCEPTION 'migration 496: booking can read or change % directly', t;
        END IF;
        IF pg_catalog.has_table_privilege('catalog_owner', t, 'SELECT')
           OR pg_catalog.has_any_column_privilege('catalog_owner', t, 'INSERT')
           OR pg_catalog.has_any_column_privilege('catalog_owner', t, 'UPDATE')
           OR pg_catalog.has_table_privilege('catalog_owner', t, 'DELETE') THEN
            RAISE EXCEPTION 'migration 496: catalog_owner has more than column SELECT on %', t;
        END IF;
    END LOOP;
    SELECT string_agg(p.polname || ':' || p.polcmd::text || ':' || pg_get_userbyid(p.polroles[1])
                      || ':' || array_length(p.polroles, 1)::text, ',' ORDER BY p.polname)
      INTO pols
      FROM pg_policy p
     WHERE p.polrelid IN ('shared.setting_definition'::regclass, 'shared.setting_value'::regclass)
       AND p.polname LIKE '%pilot_fence%';
    IF pols IS DISTINCT FROM 'setting_definition_pilot_fence_read:r:catalog_owner:1,'
                             'setting_value_pilot_fence_read:r:catalog_owner:1' THEN
        RAISE EXCEPTION 'migration 496: pilot fence policies are %', pols;
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 496: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('496', now(), 'AA-1054: catalog.v_pilot_fence_v1 (the pilot fence switch in force, read by Booking)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
