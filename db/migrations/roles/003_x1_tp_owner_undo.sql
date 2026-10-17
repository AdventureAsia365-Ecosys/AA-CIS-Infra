-- Migration rl-003: AA-852 (X1 plan S7 rollback) — UNDO of TripPlanner tp-013: schema tripplanner and its 16
-- objects back to the RDS master aa_cis_admin, default privileges back to the FOR ROLE aa_cis_admin rows.
-- migrate: lock_timeout=5s
--
-- PREPARED, NOT MERGED (branch feat/x1-s7-tp013-undo). Open a PR for it only if tp-013 has to be rolled back.
-- Key: rl-003 (rl-001 = role bootstrap X1 S3, rl-002 = reserved for X1 S20 cis_owner / db_migrator). If 003 is
-- taken by then, rename the file to the next free roles/ number and change the key below to match. Never
-- tp-014: that key is the X1 S9 SET ROLE probe.
--
-- Why a roles/ file. Once tp-013 commits, DB Migrate runs every tripplanner/ file as tp_owner (live-owner
-- switch, XD8), and tp_owner is not a member of aa_cis_admin, so no tripplanner/ file can give the objects
-- back. roles/ files always run as the master (DB Migrate refuses them under any other login); the master
-- is a member of tp_owner (rl-001), which ALTER ... OWNER and ALTER DEFAULT PRIVILEGES FOR ROLE tp_owner
-- need. When this file commits the schema owner is aa_cis_admin again, so the runner runs the next
-- tripplanner/ file as the master, automatically.
--
-- Valid only before any object created by tp-014 or later exists (the S9 probe tp-014 creates none). If
-- a later file created objects, add their ALTER ... OWNER TO aa_cis_admin below (guard 2 names every
-- object not owned by aa_cis_admin, of every kind the DB Migrate ownership post-check scans, and rolls
-- back).
--
-- What (the mirror of tp-013, explicit statements, no dynamic SQL, MIG-4):
--   1. default privileges FOR ROLE aa_cis_admin IN SCHEMA tripplanner restored (tables SELECT, INSERT,
--      UPDATE, DELETE and sequences USAGE, SELECT to tripplanner, the rows live before tp-013);
--   2. the FOR ROLE tp_owner rows revoked;
--   3. ALTER SCHEMA tripplanner OWNER TO aa_cis_admin, the 15 tables (owned BIGSERIAL sequences, indexes, row
--      types and TOAST tables follow), view v_inquiry_outbox (booking keeps its SELECT: ACLs are rewritten).
--
-- Guards (same shape as tp-013's):
--   1. before: the session is the master; tp_owner exists and the master is a member; roles tripplanner and
--      booking exist; tp-013 is registered; the schema is owned by tp_owner (or already by the master, a
--      re-run); no object in tripplanner is owned by anyone but tp_owner or aa_cis_admin (a third owner
--      means something this file does not know about happened: stop);
--   2. after: no object of any kind in tripplanner is owned by anyone but aa_cis_admin; the raw ACLs
--      (aclexplode of nspacl, relacl / acldefault, attacl; any grantee incl. PUBLIC) equal the snapshot
--      with tp_owner read as aa_cis_admin; has_*_privilege of tripplanner and booking unchanged; the
--      schema's default privileges are exactly the six FOR ROLE aa_cis_admin rows (none FOR ROLE tp_owner).
--
-- After an apply (all by hand, in the same session): tp-013 stays registered (history; a later
-- re-transfer is a new tp-NNN); the S2 isolation-probe cell "tripplanner owned by tp_owner" is keyed on
-- tp-013 and turns red — re-key or waive it; db/owners.yaml owner_role_today for tripplanner back to
-- aa_cis_admin; TripPlanner migrations/tests/migration_lint.py migration_role() back to aa_cis_admin for
-- the next file, and its CONTEXT.md DB-roles paragraph. CIS 243's grants to tp_owner stay (harmless).
--
-- Locks: ACCESS EXCLUSIVE per object for milliseconds (catalog update, no rewrite), lock_timeout 5s (header
-- above); TripPlanner has no job table, the Lambdas' transactions are short. Not destructive.

BEGIN;

-- ── Guard 1: preconditions ───────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    schema_owner text;
    foreign_owned text;
BEGIN
    IF session_user <> 'aa_cis_admin' OR current_user <> 'aa_cis_admin' THEN
        RAISE EXCEPTION 'rl-003: runs only as the RDS master aa_cis_admin (session %, current %)',
            session_user, current_user;
    END IF;
    IF to_regrole('tp_owner') IS NULL OR NOT pg_has_role('aa_cis_admin', 'tp_owner', 'MEMBER') THEN
        RAISE EXCEPTION 'rl-003: role tp_owner missing or aa_cis_admin not a member of it (rl-001)';
    END IF;
    IF to_regrole('tripplanner') IS NULL OR to_regrole('booking') IS NULL THEN
        RAISE EXCEPTION 'rl-003: role tripplanner or booking does not exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'tp-013') THEN
        RAISE EXCEPTION 'rl-003: tp-013 is not registered: there is no owner transfer to undo';
    END IF;
    SELECT pg_get_userbyid(n.nspowner)::text INTO schema_owner FROM pg_namespace n WHERE n.nspname = 'tripplanner';
    IF schema_owner IS NULL OR schema_owner NOT IN ('tp_owner', 'aa_cis_admin') THEN
        RAISE EXCEPTION 'rl-003: schema tripplanner is owned by %, expected tp_owner (or aa_cis_admin, a re-run)',
            COALESCE(schema_owner, '(no schema)');
    END IF;

    SELECT string_agg(o.kind || ' ' || o.name || ' (owner ' || o.owner || ')', ', ' ORDER BY o.kind, o.name)
      INTO foreign_owned
      FROM (SELECT 'relation' AS kind, c.oid::regclass::text AS name, pg_get_userbyid(c.relowner)::text AS owner
              FROM pg_class c WHERE c.relnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'function', p.oid::regprocedure::text, pg_get_userbyid(p.proowner)::text
              FROM pg_proc p WHERE p.pronamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'type', t.oid::regtype::text, pg_get_userbyid(t.typowner)::text
              FROM pg_type t WHERE t.typnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'statistics', 'tripplanner.' || x.stxname, pg_get_userbyid(x.stxowner)::text
              FROM pg_statistic_ext x WHERE x.stxnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'collation', 'tripplanner.' || x.collname, pg_get_userbyid(x.collowner)::text
              FROM pg_collation x WHERE x.collnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'operator', x.oid::regoperator::text, pg_get_userbyid(x.oprowner)::text
              FROM pg_operator x WHERE x.oprnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'operator class', 'tripplanner.' || x.opcname, pg_get_userbyid(x.opcowner)::text
              FROM pg_opclass x WHERE x.opcnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'operator family', 'tripplanner.' || x.opfname, pg_get_userbyid(x.opfowner)::text
              FROM pg_opfamily x WHERE x.opfnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'text search configuration', 'tripplanner.' || x.cfgname, pg_get_userbyid(x.cfgowner)::text
              FROM pg_ts_config x WHERE x.cfgnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'text search dictionary', 'tripplanner.' || x.dictname, pg_get_userbyid(x.dictowner)::text
              FROM pg_ts_dict x WHERE x.dictnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'conversion', 'tripplanner.' || x.conname, pg_get_userbyid(x.conowner)::text
              FROM pg_conversion x WHERE x.connamespace = 'tripplanner'::regnamespace) o
     WHERE o.owner NOT IN ('tp_owner', 'aa_cis_admin');
    IF foreign_owned IS NOT NULL THEN
        RAISE EXCEPTION 'rl-003: objects in tripplanner owned by a role other than tp_owner / aa_cis_admin: % '
                        '(not a state this undo knows: stop and look)', foreign_owned;
    END IF;
END $$;

-- ── Snapshot 1: raw ACLs of the schema, every relation and every column, any grantee ─────────────
CREATE OR REPLACE TEMP VIEW rl003_acl AS
SELECT 'schema tripplanner' AS object, '' AS col,
       CASE WHEN x.grantor = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantor)::text END AS grantor,
       CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee)::text END AS grantee,
       x.privilege_type AS privilege, x.is_grantable AS grantable
  FROM pg_namespace n
 CROSS JOIN LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) x
 WHERE n.nspname = 'tripplanner'
UNION ALL
SELECT c.oid::regclass::text, '',
       CASE WHEN x.grantor = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantor)::text END,
       CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee)::text END,
       x.privilege_type, x.is_grantable
  FROM pg_class c
 CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl,
                                        acldefault(CASE WHEN c.relkind = 'S' THEN 's' ELSE 'r' END::"char",
                                                   c.relowner))) x
 WHERE c.relnamespace = 'tripplanner'::regnamespace
UNION ALL
SELECT c.oid::regclass::text, a.attname::text,
       CASE WHEN x.grantor = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantor)::text END,
       CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee)::text END,
       x.privilege_type, x.is_grantable
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid AND c.relnamespace = 'tripplanner'::regnamespace
 CROSS JOIN LATERAL aclexplode(a.attacl) x
 WHERE a.attacl IS NOT NULL AND NOT a.attisdropped;

-- Expected after the undo: tp_owner becomes aa_cis_admin wherever it appears.
CREATE TEMP TABLE rl003_acl_before ON COMMIT DROP AS
SELECT object, col,
       CASE grantor WHEN 'tp_owner' THEN 'aa_cis_admin' ELSE grantor END AS grantor,
       CASE grantee WHEN 'tp_owner' THEN 'aa_cis_admin' ELSE grantee END AS grantee,
       privilege, grantable
  FROM rl003_acl;

-- ── Snapshot 2 (readable second assertion): what tripplanner and booking may do ──────────────────
CREATE OR REPLACE TEMP VIEW rl003_privileges AS
SELECT g.grantee::text AS grantee, c.oid::regclass::text AS object, p.privilege,
       CASE WHEN c.relkind = 'S' THEN has_sequence_privilege(g.grantee, c.oid, p.privilege)
            ELSE has_table_privilege(g.grantee, c.oid, p.privilege) END AS held
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'tripplanner'
 CROSS JOIN (VALUES ('tripplanner'::name), ('booking'::name)) AS g(grantee)
 CROSS JOIN LATERAL unnest(CASE WHEN c.relkind = 'S' THEN ARRAY['USAGE', 'SELECT', 'UPDATE']
                                ELSE ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']
                           END) AS p(privilege)
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
UNION ALL
SELECT g.grantee::text, 'schema ' || n.nspname, p.privilege, has_schema_privilege(g.grantee, n.oid, p.privilege)
  FROM pg_namespace n
 CROSS JOIN (VALUES ('tripplanner'::name), ('booking'::name)) AS g(grantee)
 CROSS JOIN unnest(ARRAY['USAGE', 'CREATE']) AS p(privilege)
 WHERE n.nspname = 'tripplanner';

CREATE TEMP TABLE rl003_privileges_before ON COMMIT DROP AS SELECT * FROM rl003_privileges;

-- ── 1. Default privileges FOR ROLE aa_cis_admin restored (the rows live before tp-013) ───────────
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA tripplanner
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO tripplanner;
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA tripplanner
    GRANT USAGE, SELECT ON SEQUENCES TO tripplanner;

-- ── 2. The FOR ROLE tp_owner rows revoked ────────────────────────────────────────────────────────
ALTER DEFAULT PRIVILEGES FOR ROLE tp_owner IN SCHEMA tripplanner
    REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM tripplanner;
ALTER DEFAULT PRIVILEGES FOR ROLE tp_owner IN SCHEMA tripplanner
    REVOKE USAGE, SELECT ON SEQUENCES FROM tripplanner;

-- ── 3. Ownership back to the master: schema, 15 tables, 1 view ───────────────────────────────────
ALTER SCHEMA tripplanner OWNER TO aa_cis_admin;

ALTER TABLE tripplanner.customers            OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.itinerary_components OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.llm_spend_daily      OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.narration_cache      OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.outbox               OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.sessions             OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.tour_day             OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.tour_graph_build     OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.tour_graph_edge      OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.tour_graph_node      OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.tour_junction        OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.tour_leg             OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.tour_stop            OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.trip_drafts          OWNER TO aa_cis_admin;
ALTER TABLE tripplanner.trip_events          OWNER TO aa_cis_admin;

ALTER VIEW tripplanner.v_inquiry_outbox OWNER TO aa_cis_admin;

-- ── Guard 2: owners, ACLs, privileges and default privileges after the undo ──────────────────────
DO $$
DECLARE
    stray text;
    acl_diff text;
    changed text;
    defaults text;
BEGIN
    SELECT string_agg(o.kind || ' ' || o.name || ' (owner ' || o.owner || ')', ', ' ORDER BY o.kind, o.name)
      INTO stray
      FROM (SELECT 'schema' AS kind, n.nspname::text AS name, pg_get_userbyid(n.nspowner)::text AS owner
              FROM pg_namespace n WHERE n.nspname = 'tripplanner'
            UNION ALL
            SELECT 'relation', c.oid::regclass::text, pg_get_userbyid(c.relowner)::text
              FROM pg_class c WHERE c.relnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'function', p.oid::regprocedure::text, pg_get_userbyid(p.proowner)::text
              FROM pg_proc p WHERE p.pronamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'type', t.oid::regtype::text, pg_get_userbyid(t.typowner)::text
              FROM pg_type t WHERE t.typnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'statistics', 'tripplanner.' || x.stxname, pg_get_userbyid(x.stxowner)::text
              FROM pg_statistic_ext x WHERE x.stxnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'collation', 'tripplanner.' || x.collname, pg_get_userbyid(x.collowner)::text
              FROM pg_collation x WHERE x.collnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'operator', x.oid::regoperator::text, pg_get_userbyid(x.oprowner)::text
              FROM pg_operator x WHERE x.oprnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'operator class', 'tripplanner.' || x.opcname, pg_get_userbyid(x.opcowner)::text
              FROM pg_opclass x WHERE x.opcnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'operator family', 'tripplanner.' || x.opfname, pg_get_userbyid(x.opfowner)::text
              FROM pg_opfamily x WHERE x.opfnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'text search configuration', 'tripplanner.' || x.cfgname, pg_get_userbyid(x.cfgowner)::text
              FROM pg_ts_config x WHERE x.cfgnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'text search dictionary', 'tripplanner.' || x.dictname, pg_get_userbyid(x.dictowner)::text
              FROM pg_ts_dict x WHERE x.dictnamespace = 'tripplanner'::regnamespace
            UNION ALL
            SELECT 'conversion', 'tripplanner.' || x.conname, pg_get_userbyid(x.conowner)::text
              FROM pg_conversion x WHERE x.connamespace = 'tripplanner'::regnamespace) o
     WHERE o.owner <> 'aa_cis_admin';
    IF stray IS NOT NULL THEN
        RAISE EXCEPTION 'rl-003: not owned by aa_cis_admin after the undo: % (created by tp-014 or later, or of '
                        'a kind ALTER TABLE ... OWNER does not carry: add its ALTER ... OWNER TO aa_cis_admin '
                        'and re-run)', stray;
    END IF;

    SELECT string_agg(format('%s %s%s: %s %s by %s%s', d.what, d.object,
                             CASE WHEN d.col = '' THEN '' ELSE '.' || d.col END, d.grantee, d.privilege,
                             d.grantor, CASE WHEN d.grantable THEN ' WITH GRANT OPTION' ELSE '' END),
                      '; ' ORDER BY d.object, d.col, d.grantee, d.privilege, d.what)
      INTO acl_diff
      FROM ((SELECT 'lost' AS what, * FROM rl003_acl_before EXCEPT SELECT 'lost', * FROM rl003_acl)
            UNION ALL
            (SELECT 'gained', * FROM rl003_acl EXCEPT SELECT 'gained', * FROM rl003_acl_before)) d;
    IF acl_diff IS NOT NULL THEN
        RAISE EXCEPTION 'rl-003: ACLs in schema tripplanner changed by the undo (expected: the same entries with '
                        'tp_owner read as aa_cis_admin): %', acl_diff;
    END IF;

    SELECT string_agg(format('%s %s on %s: %s -> %s', COALESCE(b.grantee, a.grantee), COALESCE(b.privilege, a.privilege),
                             COALESCE(b.object, a.object), COALESCE(b.held::text, 'absent'), COALESCE(a.held::text, 'absent')),
                      '; ')
      INTO changed
      FROM rl003_privileges_before b
      FULL JOIN rl003_privileges a
        ON a.grantee = b.grantee AND a.object = b.object AND a.privilege = b.privilege
     WHERE a.held IS DISTINCT FROM b.held;
    IF changed IS NOT NULL THEN
        RAISE EXCEPTION 'rl-003: privileges of tripplanner / booking changed by the undo: %', changed;
    END IF;

    WITH actual AS (
        SELECT pg_get_userbyid(d.defaclrole)::text AS role, d.defaclobjtype::text AS objtype,
               CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee)::text END AS grantee,
               x.privilege_type AS privilege
          FROM pg_default_acl d
         CROSS JOIN LATERAL aclexplode(d.defaclacl) x
         WHERE d.defaclnamespace = 'tripplanner'::regnamespace),
    expected (role, objtype, grantee, privilege) AS (
        VALUES ('aa_cis_admin', 'r', 'tripplanner', 'SELECT'), ('aa_cis_admin', 'r', 'tripplanner', 'INSERT'),
               ('aa_cis_admin', 'r', 'tripplanner', 'UPDATE'), ('aa_cis_admin', 'r', 'tripplanner', 'DELETE'),
               ('aa_cis_admin', 'S', 'tripplanner', 'USAGE'),  ('aa_cis_admin', 'S', 'tripplanner', 'SELECT')),
    diff AS ((SELECT 'unexpected' AS what, * FROM actual EXCEPT SELECT 'unexpected', * FROM expected)
             UNION ALL
             (SELECT 'missing', * FROM expected EXCEPT SELECT 'missing', * FROM actual))
    SELECT string_agg(format('%s FOR ROLE %s %s %s TO %s', what, role, objtype, privilege, grantee), '; '
                      ORDER BY what, role, objtype, privilege)
      INTO defaults
      FROM diff;
    IF defaults IS NOT NULL THEN
        RAISE EXCEPTION 'rl-003: default privileges in schema tripplanner are not the restored aa_cis_admin rows: %',
            defaults;
    END IF;
END $$;

DROP VIEW rl003_privileges;
DROP VIEW rl003_acl;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('rl-003', now(), 'AA-852 (X1 S7 rollback): undo tp-013, schema tripplanner + its 16 objects back to aa_cis_admin, default privileges FOR ROLE aa_cis_admin restored, FOR ROLE tp_owner rows revoked')
ON CONFLICT (version) DO NOTHING;

COMMIT;
