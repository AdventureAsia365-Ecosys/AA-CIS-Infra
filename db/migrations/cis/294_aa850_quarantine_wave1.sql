-- Migration 294: AA-850 (data standards DM-3.8 / DM-3.9) — Dead Table Registry wave 1: quarantine 8 dead CIS tables
-- and 2 dead CIS views in the new schema `retired`. Reversible: nothing is dropped, no row changes.
--
-- Why. DM-3.9: retirement goes candidate → quarantine (ALTER … SET SCHEMA retired) → drop after >= 14 days. The
-- AA-850 audit (AA-Ecosys docs/audits/2026-10-28-S255-aa850-dead-tables/registry.md + wave1-quarantine-plan.md) grepped
-- every repo that reads the shared RDS (CIS, Booking, TripPlanner, Partner, Infra; origin/main 28/10/2026) for every
-- table name and found no runtime reader or writer for these ten objects:
--   acp_contract.atom_decompose_jobs      AA-302 Bedrock Batch tracker (081/082); the batch path is gone
--   acp_contract.s1_from_atom_runs        AA-289 S1-from-atom run log (088); never written by the live S1
--   acp_contract.route_pick               writer create_route_pick() retired with the route hub (AA-859 wave 4)
--   acp_shared.marketplace_portfolios     pre-tenant portfolio drafts (097); flow removed (119, ADR-2026-038)
--   acp_shared.tenant_atom_state          N1 seeding state (098); not part of onboarding since AA-472
--   shared.acp_runs                       legacy run table (009); 0 rows ever written (AA-492)
--   shared.tenant_brand_rule_versions     AA-82 brand-rule history (019); no writer, no reader
--   shared.tenant_brand_rules_deleted_aa404  AA-404 backup of 6 mis-attached demo rows (104); no reader
--   shared.v_batch_stats                  pre-ACP admin view (003); no reader
--   shared.v_pipeline_summary             pre-ACP admin view (003, retyped by 281); no reader
-- The DRY RUN (AA-CIS-Infra db/scripts/aa850_dead_table_dry_run.py, DB Migrate run-script) gives the row counts written
-- into `w` below and must report no dependent view, inbound foreign key, function body or app statement
-- (pg_stat_statements) on any of them, and no row of a non-platform tenant (verdict quarantine_ready=true).
--
-- DRY RUN T0 (DB Migrate run-script, login aa_cis_admin, 28/10/2026 07:52 UTC): verdict quarantine_ready=true; rows
-- atom_decompose_jobs 0, s1_from_atom_runs 0, route_pick 0, marketplace_portfolios 11 (last write 24/08/2026),
-- tenant_atom_state 0, acp_runs 0, tenant_brand_rule_versions 0, tenant_brand_rules_deleted_aa404 6 (platform tenant
-- only, last write 15/08/2026); no dependent view, no inbound FK, statements by the master only; grants cis_app
-- DELETE, INSERT, SELECT, UPDATE on each of the ten. The guard below refuses a live count that differs from the DRY RUN
-- one (someone wrote to the table since the DRY RUN), except 0: a migration replay into a fresh database (CIS CI,
-- the Infra nightly drift replay) has empty tables and must apply this file as committed. A -1 would mean "not
-- filled in" and is refused too. The rows of
-- marketplace_portfolios and tenant_brand_rules_deleted_aa404 are archived before the drop (step 2).
--
-- What (one transaction, run by DB Migrate as the owner of the CIS schemas, cis_owner since X1 S20/S21):
--   1. Guard: each object is in its source schema (or already in `retired`: a re-run is a no-op), its exact row count
--      equals the DRY RUN value (or is 0: a fresh replay), and nothing outside the ten depends on it (view, inbound FK). Outbound FKs (to
--      shared.tenants, silver_aa_internal.raw_tours, shared.pipeline_runs) stay: a FK follows the table by OID, so the
--      quarantined rows keep their integrity and the parents' deletes are still checked (NO ACTION: a delete of a
--      referenced parent fails loudly; the tenant erasure treats `retired` children as quarantined, AA-850 code).
--   2. CREATE SCHEMA retired (owner = the runner, cis_owner on Dev; CREATE ON DATABASE from rl-002), no privilege for
--      anyone but the owner.
--   3. ALTER TABLE / VIEW … SET SCHEMA retired. Indexes, constraints, owned sequences, policies and triggers move with
--      the table. The object's comment gets the prefix `[AA-850 quarantine <date> from <schema>; drop not before
--      <date + 14>]` so the restore path is in the catalog.
--   4. Every privilege on `retired` and on its relations (tables, views, sequences, columns) is revoked from every
--      grantee except the object's owner, PUBLIC included: any forgotten reader now fails loudly (42501) instead of
--      reading stale rows. The owner keeps its rights (the RDS master reaches them as a member of cis_owner, for the
--      archive before the drop).
--   5. Post-check: all ten in `retired`, no ACL entry other than the owner's on the schema, the relations or their
--      columns, and no app role (membership included) with USAGE on the schema or a privilege on an object.
--
-- Order with the code (one CIS PR, ADR 0017 / D8, this file in its own commit first): tests/integration/
-- rls_catalogue_rules.py (SCHEMA_OWNERS gains "retired": "cis"; the rule-a allowlist names retired.<table>),
-- services/erasure/inventory.py (the five tenant-keyed entries removed; QUARANTINE_SCHEMAS) + plan.py (an FK child in
-- `retired` is reported as quarantined, not as an unreadable blocker), the integration tests that name the moved
-- tables. AA-CIS-Infra PR first or together: db/owners.yaml cis.schemas += retired (NOT runtime_privileges), its
-- mirrors run_migration.OWNER_DIRS and isolation_probe.OWNERS, db/rls_catalogue_rules.py byte copy — without it the
-- migration ownership lint refuses `retired` ("no owner in db/owners.yaml"). Apply through DB Migrate (check, then
-- apply) while the job tables are idle. No REQUIRED_CIS_SCHEMA bump: no code needs this file.
--
-- Restore (a NEW forward migration, per object):
--   ALTER TABLE retired.<name> SET SCHEMA <from>;  then re-grant what the DRY RUN listed (wave1_grant lines; on Dev
--   cis_app DELETE, INSERT, SELECT, UPDATE on each table) and strip the comment prefix.
-- Drop: step 2 of DM-3.9 (AA-Ecosys docs/audits/2026-10-28-S255-aa850-dead-tables/migrations/cis_NNN_aa850_drop_wave1.sql),
-- a later migration, not before the date in the comments, after a second DRY RUN and the archive of the rows.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- 1. Guard ---------------------------------------------------------------------------------------------------------
DO $$
DECLARE
    -- rows: exact count from the approved DRY RUN (T0, 28/10/2026). -1 = not filled in (refused).
    w jsonb := '[
      {"from": "acp_contract", "name": "atom_decompose_jobs",              "kind": "r", "rows": 0},
      {"from": "acp_contract", "name": "s1_from_atom_runs",                "kind": "r", "rows": 0},
      {"from": "acp_contract", "name": "route_pick",                       "kind": "r", "rows": 0},
      {"from": "acp_shared",   "name": "marketplace_portfolios",           "kind": "r", "rows": 11},
      {"from": "acp_shared",   "name": "tenant_atom_state",                "kind": "r", "rows": 0},
      {"from": "shared",       "name": "acp_runs",                         "kind": "r", "rows": 0},
      {"from": "shared",       "name": "tenant_brand_rule_versions",       "kind": "r", "rows": 0},
      {"from": "shared",       "name": "tenant_brand_rules_deleted_aa404", "kind": "r", "rows": 6},
      {"from": "shared",       "name": "v_batch_stats",                    "kind": "v", "rows": null},
      {"from": "shared",       "name": "v_pipeline_summary",               "kind": "v", "rows": null}
    ]';
    e       jsonb;
    src     regclass;
    wave    oid[] := '{}';
    n       bigint;
    dep     text;
BEGIN
    -- the OIDs of the set, so dependencies inside the set are allowed
    FOR e IN SELECT * FROM jsonb_array_elements(w) LOOP
        src := coalesce(to_regclass(format('%I.%I', e->>'from', e->>'name')),
                        to_regclass(format('retired.%I', e->>'name')));
        IF src IS NULL THEN
            RAISE EXCEPTION 'migration 294: %.% is missing (neither in its schema nor in retired)', e->>'from', e->>'name';
        END IF;
        wave := wave || src::oid;
    END LOOP;

    FOR e IN SELECT * FROM jsonb_array_elements(w) LOOP
        src := to_regclass(format('%I.%I', e->>'from', e->>'name'));
        CONTINUE WHEN src IS NULL;                                   -- already in retired (re-run)
        IF (SELECT relkind FROM pg_class WHERE oid = src) <> (e->>'kind') THEN
            RAISE EXCEPTION 'migration 294: % is not of kind %', src, e->>'kind';
        END IF;
        IF e->>'kind' = 'r' THEN
            IF (e->>'rows')::bigint < 0 THEN
                RAISE EXCEPTION 'migration 294: % has no DRY RUN row count (fill in "rows" from the approved DRY RUN)', src;
            END IF;
            EXECUTE format('SELECT count(*) FROM %s', src) INTO n;
            -- n = 0 passes too: a fresh database (the CIS CI replay, the AA-CIS-Infra drift replay of DB Schema Dump)
            -- holds none of Dev's rows, and an empty table has nothing to protect. Any other count is refused.
            IF n <> (e->>'rows')::bigint AND n <> 0 THEN
                RAISE EXCEPTION 'migration 294: % has % rows, the approved DRY RUN counted % (someone wrote to it: '
                                'stop and re-check)', src, n, e->>'rows';
            END IF;
        END IF;
        SELECT string_agg(DISTINCT v.oid::regclass::text, ', ') INTO dep
          FROM pg_depend d
          JOIN pg_rewrite r ON r.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
          JOIN pg_class v ON v.oid = r.ev_class
         WHERE d.refobjid = src AND v.oid <> src AND NOT v.oid = ANY(wave);
        IF dep IS NOT NULL THEN
            RAISE EXCEPTION 'migration 294: view(s) % depend on % (not in wave 1)', dep, src;
        END IF;
        SELECT string_agg(c.conrelid::regclass::text || '.' || c.conname, ', ') INTO dep
          FROM pg_constraint c
         WHERE c.contype = 'f' AND c.confrelid = src AND c.conrelid <> src AND NOT c.conrelid = ANY(wave);
        IF dep IS NOT NULL THEN
            RAISE EXCEPTION 'migration 294: foreign key(s) % reference % from outside wave 1', dep, src;
        END IF;
    END LOOP;
END $$;

-- 2. The quarantine schema -----------------------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS retired;
COMMENT ON SCHEMA retired IS
    'Quarantine of retired objects (data standards DM-3.9): ALTER … SET SCHEMA retired, no grant to any app role, '
    'drop after >= 14 days by a migration of the owner. One row per object in AA-Ecosys '
    'docs/architecture/dead-table-registry.md. Owner cis_owner (AA-850).';
REVOKE ALL ON SCHEMA retired FROM PUBLIC;

-- 3. Move ----------------------------------------------------------------------------------------------------------
ALTER TABLE IF EXISTS acp_contract.atom_decompose_jobs              SET SCHEMA retired;
ALTER TABLE IF EXISTS acp_contract.s1_from_atom_runs                SET SCHEMA retired;
ALTER TABLE IF EXISTS acp_contract.route_pick                       SET SCHEMA retired;
ALTER TABLE IF EXISTS acp_shared.marketplace_portfolios             SET SCHEMA retired;
ALTER TABLE IF EXISTS acp_shared.tenant_atom_state                  SET SCHEMA retired;
ALTER TABLE IF EXISTS shared.acp_runs                               SET SCHEMA retired;
ALTER TABLE IF EXISTS shared.tenant_brand_rule_versions             SET SCHEMA retired;
ALTER TABLE IF EXISTS shared.tenant_brand_rules_deleted_aa404       SET SCHEMA retired;
ALTER VIEW  IF EXISTS shared.v_batch_stats                          SET SCHEMA retired;
ALTER VIEW  IF EXISTS shared.v_pipeline_summary                     SET SCHEMA retired;

-- Comment prefix with the way back (dynamic SQL: reported as a warning by the ownership lint; the object is in
-- retired, a CIS schema once owners.yaml lists it).
DO $$
DECLARE
    m  jsonb := '{"atom_decompose_jobs": "acp_contract", "s1_from_atom_runs": "acp_contract",
                  "route_pick": "acp_contract", "marketplace_portfolios": "acp_shared",
                  "tenant_atom_state": "acp_shared", "acp_runs": "shared", "tenant_brand_rule_versions": "shared",
                  "tenant_brand_rules_deleted_aa404": "shared", "v_batch_stats": "shared",
                  "v_pipeline_summary": "shared"}';
    k  text;
    o  regclass;
    old text;
    tag text;
BEGIN
    FOR k IN SELECT jsonb_object_keys(m) LOOP
        o := to_regclass(format('retired.%I', k));
        old := obj_description(o, 'pg_class');
        CONTINUE WHEN old LIKE '[AA-850 quarantine%';                -- re-run
        tag := format('[AA-850 quarantine %s from %s; drop not before %s] ', current_date, m->>k, current_date + 14);
        EXECUTE format('COMMENT ON %s %s IS %L',
                       CASE (SELECT relkind FROM pg_class WHERE oid = o) WHEN 'v' THEN 'VIEW' ELSE 'TABLE' END,
                       o, tag || coalesce(old, ''));
    END LOOP;
END $$;

-- 4. No role but the owner keeps a way in --------------------------------------------------------------------------
-- Every grantee in the ACLs (PUBLIC = grantee 0), whatever its name: on Dev cis_app (DELETE, INSERT, SELECT, UPDATE on
-- each table), in the CI replay also the legacy roles of the early migrations. REVOKE ALL on a table also revokes its
-- column privileges.
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT DISTINCT c.oid::regclass AS obj, c.relkind,
               CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END AS grantee
          FROM pg_class c
          JOIN pg_namespace ns ON ns.oid = c.relnamespace
          CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE ns.nspname = 'retired' AND a.grantee <> c.relowner
        UNION
        SELECT DISTINCT c.oid::regclass, c.relkind,
               CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END
          FROM pg_attribute att
          JOIN pg_class c ON c.oid = att.attrelid
          JOIN pg_namespace ns ON ns.oid = c.relnamespace
          CROSS JOIN LATERAL aclexplode(att.attacl) a
         WHERE ns.nspname = 'retired' AND att.attnum > 0 AND a.grantee <> c.relowner
    LOOP
        EXECUTE format('REVOKE ALL ON %s %s FROM %s',
                       CASE WHEN r.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, r.obj, r.grantee);
    END LOOP;
    FOR r IN
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END AS grantee
          FROM pg_namespace ns CROSS JOIN LATERAL aclexplode(ns.nspacl) a
         WHERE ns.nspname = 'retired' AND a.grantee <> ns.nspowner
    LOOP
        EXECUTE format('REVOKE ALL ON SCHEMA retired FROM %s', r.grantee);
    END LOOP;
END $$;

-- 5. Post-check ----------------------------------------------------------------------------------------------------
DO $$
DECLARE
    names text[] := ARRAY['atom_decompose_jobs', 's1_from_atom_runs', 'route_pick', 'marketplace_portfolios',
                          'tenant_atom_state', 'acp_runs', 'tenant_brand_rule_versions',
                          'tenant_brand_rules_deleted_aa404', 'v_batch_stats', 'v_pipeline_summary'];
    app_roles text[] := ARRAY['cis_app', 'aa_app_user', 'catalog_owner', 'booking', 'tripplanner', 'crm_app'];
    k  text;
    r  text;
    o  regclass;
    left_over text;
BEGIN
    FOREACH k IN ARRAY names LOOP
        o := to_regclass(format('retired.%I', k));
        IF o IS NULL THEN
            RAISE EXCEPTION 'migration 294: post-check: retired.% missing', k;
        END IF;
        FOREACH r IN ARRAY app_roles LOOP
            CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r);
            IF has_table_privilege(r, o, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
               OR has_any_column_privilege(r, o, 'SELECT, INSERT, UPDATE, REFERENCES') THEN
                RAISE EXCEPTION 'migration 294: post-check: % still has a privilege on %', r, o;
            END IF;
        END LOOP;
    END LOOP;
    FOREACH r IN ARRAY app_roles LOOP
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r);
        IF has_schema_privilege(r, 'retired', 'USAGE') THEN
            RAISE EXCEPTION 'migration 294: post-check: % has USAGE on schema retired', r;
        END IF;
    END LOOP;
    SELECT string_agg(DISTINCT x, ', ') INTO left_over FROM (
        SELECT c.oid::regclass::text || ':' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END
          FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE ns.nspname = 'retired' AND a.grantee <> c.relowner
        UNION ALL
        SELECT c.oid::regclass::text || '.' || att.attname || ':'
               || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END
          FROM pg_attribute att JOIN pg_class c ON c.oid = att.attrelid
          JOIN pg_namespace ns ON ns.oid = c.relnamespace CROSS JOIN LATERAL aclexplode(att.attacl) a
         WHERE ns.nspname = 'retired' AND att.attnum > 0 AND a.grantee <> c.relowner
        UNION ALL
        SELECT 'schema retired:' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END
          FROM pg_namespace ns CROSS JOIN LATERAL aclexplode(ns.nspacl) a
         WHERE ns.nspname = 'retired' AND a.grantee <> ns.nspowner
    ) s(x);
    IF left_over IS NOT NULL THEN
        RAISE EXCEPTION 'migration 294: post-check: privileges left in retired: %', left_over;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('294', now(),
        'AA-850 wave 1 (DM-3.9): quarantine 8 dead CIS tables and 2 dead views in schema retired (no grants); '
        'drop after >= 14 days')
ON CONFLICT (version) DO NOTHING;

COMMIT;
