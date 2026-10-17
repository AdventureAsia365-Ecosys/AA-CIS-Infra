-- Migration tp-013: AA-852 — X1 S7: the tripplanner schema and its 16 objects owned by the NOLOGIN owner
-- role tp_owner instead of the RDS master aa_cis_admin; default privileges restated FOR ROLE tp_owner.
-- migrate: lock_timeout=5s
--
-- Why. ADR 0008 decision 6, data standards DM-8.1 / SEC-1: an app's objects belong to its own NOLOGIN
-- <app>_owner, never to a login role. Today the schema and every object in it are owned by aa_cis_admin
-- (schema reference of 16/10, tp-012), the login the CIS runtime also uses, so ownership does not say who
-- may change TripPlanner's tables. X1 plan: AA-Ecosys docs/audits/2026-10-17-S241-x1/x1-plan.md §5 S7.
--
-- Preconditions (applied before this file in the X1 S8 train; guard 1 raises when one is missing):
--   * AA-CIS-Infra roles/001 (rl-001): role tp_owner NOLOGIN and GRANT tp_owner TO aa_cis_admin
--     (ALTER ... OWNER TO needs the runner to be a member of the new owner);
--   * CIS 243: USAGE on schema shared + SELECT, INSERT on shared.schema_versions to tp_owner (the next
--     tripplanner/ file runs as tp_owner and registers itself as tp_owner).
--
-- What (explicit statements from the schema reference + tp-001..012; no dynamic SQL, MIG-4):
--   1. ALTER SCHEMA tripplanner OWNER TO tp_owner, first (a file run as tp_owner needs CREATE on it);
--   2. ALTER TABLE ... OWNER TO tp_owner for the 15 tables, the frozen place read models included
--      (itinerary_components, tour_day, tour_stop, tour_graph_build/_edge/_node, tour_leg, tour_junction).
--      Indexes, row types, TOAST tables and the two BIGSERIAL sequences (trip_events_id_seq,
--      outbox_id_seq, owned by their column) follow the table. There is no standalone sequence, no
--      function and no free-standing type in the schema (guard 2 proves nothing was left behind);
--   3. ALTER VIEW tripplanner.v_inquiry_outbox OWNER TO tp_owner. The view then reads tripplanner.outbox
--      with tp_owner's rights (its owner, which now owns the table too); role booking keeps SELECT on the
--      view only (tp-009);
--   4. default privileges: FOR ROLE tp_owner IN SCHEMA tripplanner GRANT SELECT, INSERT, UPDATE, DELETE ON
--      TABLES and USAGE, SELECT ON SEQUENCES TO tripplanner (the rows that exist FOR ROLE aa_cis_admin,
--      restated), then REVOKE the FOR ROLE aa_cis_admin rows (they would cover nothing from now on).
--   PostgreSQL rewrites every ACL to the new owner (grantor and the owner's own entry), so no grant to any
--   role changes; guard 2 compares the raw ACLs with a snapshot taken before step 1.
--
-- After this file DB Migrate runs every later tripplanner/ file as tp_owner (live-owner switch, XD8): the
-- objects created from tp-014 on belong to tp_owner and the restated default privileges cover them, with
-- no gap. From tp-014, ALTER DEFAULT PRIVILEGES must read FOR ROLE tp_owner and ALTER ... OWNER TO is not
-- needed any more (migrations/tests/test_migration_lint.py).
--
-- Guards.
--   1. before: tp_owner exists, is NOLOGIN, the runner is a member; tp_owner has USAGE on schema shared,
--      SELECT and INSERT on shared.schema_versions (each checked on its own: a privilege list is true when
--      ANY of them is held, and has_table_privilege ignores schema USAGE); roles tripplanner and booking
--      exist; the schema is owned by the runner (or already by tp_owner, a re-run);
--   2. after: no object in tripplanner is owned by anyone but tp_owner (else an object was added after this
--      file was written: add its ALTER ... OWNER TO and re-run). The kinds are the ones the DB Migrate
--      ownership post-check scans (run_migration.py OBJECTS_SQL): schema, relation, function, type, and the
--      kinds ALTER TABLE ... OWNER does not carry: extended statistics (stxowner stays), collation,
--      operator, operator class / family, text search configuration / dictionary, conversion. None exists
--      in tripplanner (tp-001..012 create none); if one appears on Dev the file rolls back here instead of
--      the S9 probe tp-014 failing with exit 9 later. The ACLs equal the snapshot exactly: every
--      aclexplode() row of the schema (nspacl), every relation (relacl, NULL read as acldefault) and every
--      column (attacl), any grantee incl. PUBLIC, with aa_cis_admin read as tp_owner in the snapshot
--      (grantor and grantee); has_*_privilege of tripplanner and booking is compared as well (readable
--      message). The default privileges of the schema are exactly the restated rows (none FOR ROLE
--      aa_cis_admin).
--   The behaviour (tripplanner DML, the BIGSERIAL inserts, booking reading the view but not the table, a
--   later file run as tp_owner) is replayed in migrations/tests/test_tp013_pg.py on a throwaway Postgres;
--   after apply it is verified live (X1 plan S7 Verify).
--
-- Locks. Each ALTER ... OWNER takes a short ACCESS EXCLUSIVE lock (catalog update, no rewrite), under the
-- runner's lock_timeout 5s (stated above). TripPlanner has no job table; the Lambdas' transactions are
-- short, and a lock timeout fails the whole file with nothing changed (retry). Not destructive.
--
-- Rollback: the prepared, unmerged AA-CIS-Infra roles/ undo file db/migrations/roles/003_x1_tp_owner_undo.sql
-- (branch feat/x1-s7-tp013-undo; key rl-003, renumbered to the next free rl- key if 003 is taken when it is
-- needed), run as the master. Not a tripplanner/ file: once this file commits, tripplanner/ files run as
-- tp_owner, which cannot give objects back to aa_cis_admin. tp-014 is reserved for the X1 S9 SET ROLE probe.
-- Re-running as the master is a no-op (DB Migrate never re-runs a registered version).

BEGIN;

-- ── Guard 1: preconditions ───────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    schema_owner text;
BEGIN
    IF to_regrole('tp_owner') IS NULL THEN
        RAISE EXCEPTION 'tp-013: role tp_owner does not exist: apply AA-CIS-Infra roles/001 (rl-001) first';
    END IF;
    IF (SELECT r.rolcanlogin FROM pg_roles r WHERE r.rolname = 'tp_owner') THEN
        RAISE EXCEPTION 'tp-013: tp_owner can log in; an owner role must be NOLOGIN (rl-001)';
    END IF;
    IF NOT pg_has_role(current_user, 'tp_owner', 'MEMBER') THEN
        RAISE EXCEPTION 'tp-013: % is not a member of tp_owner (rl-001 grants it); ALTER ... OWNER TO needs it',
            current_user;
    END IF;
    IF NOT has_schema_privilege('tp_owner', 'shared', 'USAGE')
       OR NOT has_table_privilege('tp_owner', 'shared.schema_versions', 'SELECT')
       OR NOT has_table_privilege('tp_owner', 'shared.schema_versions', 'INSERT') THEN
        RAISE EXCEPTION 'tp-013: tp_owner lacks USAGE on schema shared or SELECT / INSERT on shared.schema_versions: '
                        'apply CIS 243 first (the next tripplanner/ file runs as tp_owner and registers itself)';
    END IF;
    IF to_regrole('tripplanner') IS NULL OR to_regrole('booking') IS NULL THEN
        RAISE EXCEPTION 'tp-013: role tripplanner or booking does not exist';
    END IF;
    SELECT pg_get_userbyid(n.nspowner)::text INTO schema_owner FROM pg_namespace n WHERE n.nspname = 'tripplanner';
    IF schema_owner IS NULL THEN
        RAISE EXCEPTION 'tp-013: schema tripplanner does not exist';
    END IF;
    IF schema_owner NOT IN (current_user::text, 'tp_owner') THEN
        RAISE EXCEPTION 'tp-013: schema tripplanner is owned by %, expected % (the runner) or tp_owner',
            schema_owner, current_user;
    END IF;
END $$;

-- ── Snapshot 1: the raw ACLs of the schema, every relation and every column, any grantee ─────────
-- aclexplode() of nspacl / relacl / attacl; a NULL ACL is read as acldefault() (the owner's implicit
-- rights), so the owner's own entry is compared too. Role oids as names, 0 = PUBLIC.
CREATE OR REPLACE TEMP VIEW tp013_acl AS
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

-- The expected ACLs after the transfer: the old owner aa_cis_admin becomes tp_owner wherever it appears.
CREATE TEMP TABLE tp013_acl_before ON COMMIT DROP AS
SELECT object, col,
       CASE grantor WHEN 'aa_cis_admin' THEN 'tp_owner' ELSE grantor END AS grantor,
       CASE grantee WHEN 'aa_cis_admin' THEN 'tp_owner' ELSE grantee END AS grantee,
       privilege, grantable
  FROM tp013_acl;

-- ── Snapshot 2 (readable second assertion): what tripplanner and booking may do ──────────────────
CREATE OR REPLACE TEMP VIEW tp013_privileges AS
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

CREATE TEMP TABLE tp013_privileges_before ON COMMIT DROP AS SELECT * FROM tp013_privileges;

-- ── 1. Schema ────────────────────────────────────────────────────────────────────────────────────
ALTER SCHEMA tripplanner OWNER TO tp_owner;

-- ── 2. Tables (owned sequences, indexes, row types and TOAST tables follow) ────────────────────────
ALTER TABLE tripplanner.customers            OWNER TO tp_owner;
ALTER TABLE tripplanner.itinerary_components OWNER TO tp_owner;
ALTER TABLE tripplanner.llm_spend_daily      OWNER TO tp_owner;
ALTER TABLE tripplanner.narration_cache      OWNER TO tp_owner;
ALTER TABLE tripplanner.outbox               OWNER TO tp_owner;
ALTER TABLE tripplanner.sessions             OWNER TO tp_owner;
ALTER TABLE tripplanner.tour_day             OWNER TO tp_owner;
ALTER TABLE tripplanner.tour_graph_build     OWNER TO tp_owner;
ALTER TABLE tripplanner.tour_graph_edge      OWNER TO tp_owner;
ALTER TABLE tripplanner.tour_graph_node      OWNER TO tp_owner;
ALTER TABLE tripplanner.tour_junction        OWNER TO tp_owner;
ALTER TABLE tripplanner.tour_leg             OWNER TO tp_owner;
ALTER TABLE tripplanner.tour_stop            OWNER TO tp_owner;
ALTER TABLE tripplanner.trip_drafts          OWNER TO tp_owner;
ALTER TABLE tripplanner.trip_events          OWNER TO tp_owner;

-- ── 3. View ──────────────────────────────────────────────────────────────────────────────────────
ALTER VIEW tripplanner.v_inquiry_outbox OWNER TO tp_owner;

-- ── 4. Default privileges: restated for tp_owner, the aa_cis_admin rows revoked ───────────────────
ALTER DEFAULT PRIVILEGES FOR ROLE tp_owner IN SCHEMA tripplanner
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO tripplanner;
ALTER DEFAULT PRIVILEGES FOR ROLE tp_owner IN SCHEMA tripplanner
    GRANT USAGE, SELECT ON SEQUENCES TO tripplanner;
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA tripplanner
    REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM tripplanner;
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA tripplanner
    REVOKE USAGE, SELECT ON SEQUENCES FROM tripplanner;

-- ── Guard 2: owners, privileges and default privileges after the transfer ────────────────────────
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
     WHERE o.owner <> 'tp_owner';
    IF stray IS NOT NULL THEN
        RAISE EXCEPTION 'tp-013: not owned by tp_owner after the transfer: % (an object was added after this '
                        'file was written, or is of a kind ALTER TABLE ... OWNER does not carry: add its '
                        'ALTER ... OWNER TO tp_owner and re-run)', stray;
    END IF;

    SELECT string_agg(format('%s %s%s: %s %s by %s%s', d.what, d.object,
                             CASE WHEN d.col = '' THEN '' ELSE '.' || d.col END, d.grantee, d.privilege,
                             d.grantor, CASE WHEN d.grantable THEN ' WITH GRANT OPTION' ELSE '' END),
                      '; ' ORDER BY d.object, d.col, d.grantee, d.privilege, d.what)
      INTO acl_diff
      FROM ((SELECT 'lost' AS what, * FROM tp013_acl_before EXCEPT SELECT 'lost', * FROM tp013_acl)
            UNION ALL
            (SELECT 'gained', * FROM tp013_acl EXCEPT SELECT 'gained', * FROM tp013_acl_before)) d;
    IF acl_diff IS NOT NULL THEN
        RAISE EXCEPTION 'tp-013: ACLs in schema tripplanner changed by the owner transfer (expected: the same '
                        'entries with aa_cis_admin read as tp_owner): %', acl_diff;
    END IF;

    SELECT string_agg(format('%s %s on %s: %s -> %s', COALESCE(b.grantee, a.grantee), COALESCE(b.privilege, a.privilege),
                             COALESCE(b.object, a.object), COALESCE(b.held::text, 'absent'), COALESCE(a.held::text, 'absent')),
                      '; ')
      INTO changed
      FROM tp013_privileges_before b
      FULL JOIN tp013_privileges a
        ON a.grantee = b.grantee AND a.object = b.object AND a.privilege = b.privilege
     WHERE a.held IS DISTINCT FROM b.held;
    IF changed IS NOT NULL THEN
        RAISE EXCEPTION 'tp-013: privileges of tripplanner / booking changed by the owner transfer: %', changed;
    END IF;

    WITH actual AS (
        SELECT pg_get_userbyid(d.defaclrole)::text AS role, d.defaclobjtype::text AS objtype,
               CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee)::text END AS grantee,
               x.privilege_type AS privilege
          FROM pg_default_acl d
         CROSS JOIN LATERAL aclexplode(d.defaclacl) x
         WHERE d.defaclnamespace = 'tripplanner'::regnamespace),
    expected (role, objtype, grantee, privilege) AS (
        VALUES ('tp_owner', 'r', 'tripplanner', 'SELECT'), ('tp_owner', 'r', 'tripplanner', 'INSERT'),
               ('tp_owner', 'r', 'tripplanner', 'UPDATE'), ('tp_owner', 'r', 'tripplanner', 'DELETE'),
               ('tp_owner', 'S', 'tripplanner', 'USAGE'),  ('tp_owner', 'S', 'tripplanner', 'SELECT')),
    diff AS ((SELECT 'unexpected' AS what, * FROM actual EXCEPT SELECT 'unexpected', * FROM expected)
             UNION ALL
             (SELECT 'missing', * FROM expected EXCEPT SELECT 'missing', * FROM actual))
    SELECT string_agg(format('%s FOR ROLE %s %s %s TO %s', what, role, objtype, privilege, grantee), '; '
                      ORDER BY what, role, objtype, privilege)
      INTO defaults
      FROM diff;
    IF defaults IS NOT NULL THEN
        RAISE EXCEPTION 'tp-013: default privileges in schema tripplanner are not the restated tp_owner rows: %', defaults;
    END IF;
END $$;

DROP VIEW tp013_privileges;
DROP VIEW tp013_acl;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-013', now(), 'AA-852 X1 S7: schema tripplanner + its 16 objects owned by tp_owner (was aa_cis_admin); default privileges FOR ROLE tp_owner to tripplanner, FOR ROLE aa_cis_admin rows revoked')
ON CONFLICT (version) DO NOTHING;

COMMIT;
