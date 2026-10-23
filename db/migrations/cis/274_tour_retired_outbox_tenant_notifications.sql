-- Migration 274: AA-986 L3 + L4 — the tenant reads its own tour notifications (shared.notifications under RLS), and
-- the catalog contract views of the tour lifecycle: catalog.v_tour_retired (the tombstone) and
-- catalog.v_tour_lifecycle_outbox (the change events), contract catalog.tour.v1.3.
--
-- Why. Root ADR 0015 (Accepted S248), decisions 4 and 5. Since CIS 272 / the L2 service, every change of a tour's
-- served state writes gold_aa_internal.tour_lifecycle_event and a tour.discontinued / tour.reinstated row in
-- shared.notifications for every tenant with a derivative. Two readers are missing:
--   * the tenant: shared.notifications has no RLS and only cis_app may read it (schema reference 23/10/2026), so the
--     warning never reaches the tenant (audit S248 section 1 point 5). The tenant-scoped GET /v1/notifications (code
--     PR, tenant pool behind aa986:tenant_notifications_pool) needs the 229 RLS template on this table;
--   * the other apps: a tour that leaves catalog.v_tour is simply absent; Booking, TripPlanner and AA-Partner cannot
--     tell 410 (retired) from a temporary absence (paused) or 404 (never served), nor learn that a tour came back.
--
-- What.
--   Part A (cis_owner, the table owner) — shared.notifications on the 229 RLS template:
--     1. ENABLE ROW LEVEL SECURITY (no FORCE: the owner cis_owner stays exempt, 229 decision D2).
--     2. POLICY tenant_isolation AS PERMISSIVE FOR ALL TO aa_app_user, USING and WITH CHECK
--        tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid ('' = no tenant, 0 rows, no error).
--     3. POLICY notifications_tenant_audience AS RESTRICTIVE FOR ALL TO aa_app_user, USING and WITH CHECK
--        target_roles @> ARRAY['tenant']: a tenant reads only the rows written FOR tenants (tour.discontinued /
--        tour.reinstated, services/notifications.py _DEFAULT_ROLES), never an admin row that carries its tenant id
--        (tenant.cta.review_claim is "admin-only: the tenant sees a warning in the portal, never this row").
--     4. POLICY notifications_cis_app_all AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true), the X1
--        parity policy (CIS 244): the staff bell, the lifecycle service, the retention / erasure jobs and every other
--        writer log in as cis_app (not the owner) and would read 0 rows the moment RLS is on.
--     5. aa_app_user: SELECT, UPDATE (is_read) only (the bell's "mark read"). No INSERT / DELETE: the tenant never
--        writes a notification, and no other column can change (a row cannot be handed to another tenant or audience).
--   Part B (catalog_owner, the X1 S22 catalog recipe) — two contract views, owner catalog_owner, security_barrier,
--   SELECT to booking, tripplanner and aa_app_user (225 / 257 pattern, unguarded: contracts README rule 5):
--     6. catalog.v_tour_retired: one row per catalog key that is not served now (from gold_aa_internal.
--        v_tour_liveness, the derived state of ADR 0015 decision 1: state retired | paused with its reason) or that is
--        served again after a change (the latest lifecycle event of a served key is `restored`: state restored, the
--        event's reason). Columns: source_system, source_id (= raw_tours.source_key), tour_id (the live version, else
--        the newest), state, reason, changed_at. A key never served has no row (404 for consumers). Built on the
--        derived state, so the tombstone can never disagree with catalog.v_tour (guard 7), even for a key retired
--        before L2 wrote events.
--     7. catalog.v_tour_lifecycle_outbox: every row of gold_aa_internal.tour_lifecycle_event, without the internal
--        columns (action, actor, details): event_id (the cursor), source_system, source_id, tour_id, event
--        (retired | paused | restored | superseded), reason, replaced_by_tour_id, occurred_at, idempotency_key.
--        Consumers read `WHERE event_id > :cursor ORDER BY event_id` with a lag window (contracts README rule 4).
--   8. Register 274.
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before, part A: roles cis_app, aa_app_user exist; aa_app_user is not superuser / BYPASSRLS; the table has
--      tenant_id uuid NOT NULL, target_roles text[] NOT NULL, is_read boolean; the runner may alter it (owns it or is
--      a member of its owner); it is not FORCEd; its policies are a subset of this file's three; no PUBLIC grant; no
--      other grantee that logs in or has members (it would read 0 rows once RLS is on), apart from the owner, cis_app
--      and aa_app_user.
--   2. after, part A: RLS on and not forced; exactly the three policies with this file's commands, roles and
--      expressions; aa_app_user holds exactly SELECT (table) and UPDATE (is_read) (column); cis_app's privileges are
--      unchanged (DML on Dev; none in the CI replay);
--      the runner still counts every row under a foreign GUC.
--   3. before, part B: 272 and 273 registered; the source objects exist; schema catalog owned by cis_owner; roles
--      catalog_owner, booking, tripplanner exist; catalog_owner has USAGE on gold_aa_internal and SELECT on
--      v_tour_liveness and tour_lifecycle_event; a view of this file that exists already is catalog_owner's (re-run).
--   4. after, part B (as catalog_owner, GUC set to an unknown tenant): both views catalog_owner's, security_barrier,
--      columns exactly as above; grants exactly SELECT to aa_app_user, booking, tripplanner (no PUBLIC, no column
--      grants); catalog_owner has no CREATE on catalog any more.
--   5. behaviour: v_tour_retired has one row per key; known states and reasons; its retired / paused rows are exactly
--      the not-served keys of v_tour_liveness; no retired / paused key is in catalog.v_tour; the outbox has every
--      event row.
--   6. the AA-859 invariant v3 (272 guard 4, NO_PRIVILEGE_WITHOUT_RLS_SQL_V3): no aa_app_user privilege on a relation
--      without RLS outside the allowlists (shared.notifications has RLS from part A; the catalog views are the
--      catalog exception).
--   aa_app_user's isolation by behaviour cannot run here (the role lint allows no SET ROLE aa_app_user in a cis/ file):
--   tests/integration/test_aa817_rls_tenant_isolation.py (TENANT_TABLES) and test_aa986_migration_274.py prove it in
--   CI, the nightly isolation probe on Dev (cell tenant.aa_app_user_isolation covers every RLS table).
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: rls false, policies 0, aa_app_user
-- grants none, tenant rows = the tour.discontinued / reinstated rows so far, lifecycle events = what L2 wrote):
--   SELECT (SELECT relrowsecurity FROM pg_class WHERE oid = 'shared.notifications'::regclass) AS rls,
--          (SELECT count(*) FROM pg_policy WHERE polrelid = 'shared.notifications'::regclass) AS policies,
--          has_table_privilege('aa_app_user', 'shared.notifications', 'SELECT') AS aa_app_user_select,
--          (SELECT count(*) FROM shared.notifications WHERE target_roles @> ARRAY['tenant']) AS tenant_rows,
--          (SELECT count(*) FROM gold_aa_internal.tour_lifecycle_event) AS lifecycle_events,
--          (SELECT count(*) FROM gold_aa_internal.v_tour_liveness WHERE state <> 'served') AS not_served_keys;
--
-- Locks. ENABLE ROW LEVEL SECURITY and CREATE POLICY take ACCESS EXCLUSIVE on shared.notifications (Dev: ~20 rows)
-- for milliseconds; the two CREATE VIEW are catalog-only. lock_timeout 5s. Apply through AA-CIS-Infra DB Migrate (byte
-- copy in db/migrations/cis/) with shared.job and booking.job idle (DM-11.4). Re-running is a no-op apart from the
-- guards (DROP POLICY IF EXISTS + CREATE, CREATE OR REPLACE VIEW, grants from nothing).
--
-- Order with the code. Apply this file BEFORE the CIS code PR that adds GET /v1/notifications (it reads the table on
-- the tenant pool: without part A aa_app_user gets 42501, a 500). Nothing else changes for current code: cis_app keeps
-- every row through its parity policy.
--
-- Recipe / X1. One BEGIN … COMMIT, run by DB Migrate as cis_owner (login db_migrator). Part A runs as cis_owner (owner
-- of shared.notifications since 245). Part B uses the X1 S22 catalog recipe (CONTEXT.md, as 253 / 256 / 257 / 258 /
-- 273): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE catalog_owner; the views and their grants;
-- SET LOCAL ROLE cis_owner; REVOKE CREATE. Never RESET ROLE. The conftest replay applies only part A (the replay skips
-- 253-258, so part B cannot run there); tests/integration/test_aa986_migration_274.py applies the whole file the
-- DB Migrate way on the RDS-like state and rolls back.
--
-- Rollback (a NEW forward migration, after reverting the code that reads them; set the Redis flag
-- aa986:tenant_notifications_pool false first and list it in TENANT_POOL_FORCE_ADMIN_FLAGS):
--   REVOKE ALL ON shared.notifications FROM aa_app_user;     -- before DISABLE (241 invariant)
--   DROP POLICY IF EXISTS tenant_isolation ON shared.notifications;
--   DROP POLICY IF EXISTS notifications_tenant_audience ON shared.notifications;
--   DROP POLICY IF EXISTS notifications_cis_app_all ON shared.notifications;
--   ALTER TABLE shared.notifications DISABLE ROW LEVEL SECURITY;
--   and, under the catalog recipe: DROP VIEW catalog.v_tour_lifecycle_outbox; DROP VIEW catalog.v_tour_retired;
--   (only after Booking / TripPlanner stop reading them: contract catalog.tour.v1.3).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── Part A: shared.notifications, the tenant's own tenant-facing rows ──────────────────────────────────────────────
DO $$
DECLARE
    tbl    oid := to_regclass('shared.notifications');
    owner_ name;
    bad    text;
BEGIN
    IF to_regrole('cis_app') IS NULL OR to_regrole('aa_app_user') IS NULL THEN
        RAISE EXCEPTION 'migration 274: roles cis_app and aa_app_user must exist';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aa_app_user' AND (rolsuper OR rolbypassrls)) THEN
        RAISE EXCEPTION 'migration 274: aa_app_user is superuser or BYPASSRLS: RLS would not apply to it';
    END IF;
    IF tbl IS NULL THEN
        RAISE EXCEPTION 'migration 274: shared.notifications is missing (053)';
    END IF;
    IF (SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod) || CASE WHEN a.attnotnull
                                                                                       THEN ' nn' ELSE '' END,
                          ', ' ORDER BY a.attname)
          FROM pg_attribute a
         WHERE a.attrelid = tbl AND a.attname IN ('tenant_id', 'target_roles', 'is_read') AND NOT a.attisdropped)
       IS DISTINCT FROM 'is_read boolean nn, target_roles text[] nn, tenant_id uuid nn' THEN
        RAISE EXCEPTION 'migration 274: shared.notifications lacks tenant_id uuid / target_roles text[] / is_read '
                        'boolean NOT NULL';
    END IF;
    SELECT pg_get_userbyid(relowner) INTO owner_ FROM pg_class WHERE oid = tbl;
    IF NOT pg_has_role(current_user, owner_, 'USAGE') THEN
        RAISE EXCEPTION 'migration 274: % may not alter shared.notifications (owner %); run it through DB Migrate',
            current_user, owner_;
    END IF;
    IF (SELECT relforcerowsecurity FROM pg_class WHERE oid = tbl) THEN
        RAISE EXCEPTION 'migration 274: shared.notifications has FORCE ROW LEVEL SECURITY: the owner would be filtered';
    END IF;
    SELECT string_agg(polname, ', ') INTO bad FROM pg_policy
     WHERE polrelid = tbl
       AND polname NOT IN ('tenant_isolation', 'notifications_tenant_audience', 'notifications_cis_app_all');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 274: shared.notifications has other policies: %', bad;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
                WHERE c.oid = tbl AND a.grantee = 0) THEN
        RAISE EXCEPTION 'migration 274: shared.notifications is granted to PUBLIC';
    END IF;
    -- a reader the new policies do not name would see 0 rows, silently
    SELECT string_agg(DISTINCT r.rolname, ', ') INTO bad
      FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
      JOIN pg_roles r ON r.oid = a.grantee
     WHERE c.oid = tbl
       AND r.rolname NOT IN ('cis_app', 'aa_app_user')
       AND NOT pg_has_role(r.oid, c.relowner, 'USAGE')
       AND (r.rolcanlogin OR EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.roleid = r.oid));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 274: shared.notifications is readable by % (no policy would admit it)', bad;
    END IF;
    PERFORM set_config('aa986.notif_rows', (SELECT count(*) FROM shared.notifications)::text, true);
    PERFORM set_config('aa986.cis_app_privs',
                       COALESCE((SELECT string_agg(p, ',' ORDER BY p)
                                   FROM unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
                                  WHERE has_table_privilege('cis_app', tbl, p)), ''), true);
END $$;

ALTER TABLE shared.notifications ENABLE ROW LEVEL SECURITY;
-- deliberately NO "FORCE ROW LEVEL SECURITY" (229 decision D2: the owner stays exempt)

DROP POLICY IF EXISTS tenant_isolation ON shared.notifications;
CREATE POLICY tenant_isolation ON shared.notifications AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.notifications IS
    'AA-986 L3 (CIS 274): the tenant pool reads and marks read its own rows only (229 template). Owner exempt (no '
    'FORCE).';

DROP POLICY IF EXISTS notifications_tenant_audience ON shared.notifications;
CREATE POLICY notifications_tenant_audience ON shared.notifications AS RESTRICTIVE FOR ALL TO aa_app_user
    USING (target_roles @> ARRAY['tenant']::text[])
    WITH CHECK (target_roles @> ARRAY['tenant']::text[]);
COMMENT ON POLICY notifications_tenant_audience ON shared.notifications IS
    'AA-986 L3 (CIS 274): of its own rows, a tenant sees only those written for tenants (target_roles contains '
    'tenant: tour.discontinued / tour.reinstated), never a staff row that carries its tenant id.';

DROP POLICY IF EXISTS notifications_cis_app_all ON shared.notifications;
CREATE POLICY notifications_cis_app_all ON shared.notifications AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);

GRANT USAGE ON SCHEMA shared TO aa_app_user;
REVOKE ALL ON shared.notifications FROM aa_app_user;          -- also the column grants: start from nothing
GRANT SELECT ON shared.notifications TO aa_app_user;
GRANT UPDATE (is_read) ON shared.notifications TO aa_app_user;

DO $$
DECLARE
    tbl     oid := 'shared.notifications'::regclass;
    pols    text;
    privs   text;
    cprivs  text;
    n       bigint;
BEGIN
    IF NOT (SELECT relrowsecurity AND NOT relforcerowsecurity FROM pg_class WHERE oid = tbl) THEN
        RAISE EXCEPTION 'migration 274: shared.notifications RLS is not on, or is forced';
    END IF;
    SELECT string_agg(p.polname || ':' || CASE WHEN p.polpermissive THEN 'permissive' ELSE 'restrictive' END || ':'
                      || p.polcmd::text || ':' || array_to_string(ARRAY(SELECT pg_get_userbyid(r) FROM unnest(p.polroles) r
                                                                    ORDER BY 1), ',')
                      || ':' || pg_get_expr(p.polqual, p.polrelid) || ':' || pg_get_expr(p.polwithcheck, p.polrelid),
                      ' | ' ORDER BY p.polname)
      INTO pols FROM pg_policy p WHERE p.polrelid = tbl;
    IF pols IS DISTINCT FROM
         'notifications_cis_app_all:permissive:*:cis_app:true:true'
         || ' | notifications_tenant_audience:restrictive:*:aa_app_user:(target_roles @> ARRAY[''tenant''::text])'
         || ':(target_roles @> ARRAY[''tenant''::text])'
         || ' | tenant_isolation:permissive:*:aa_app_user:'
         || '(tenant_id = (NULLIF(current_setting(''app.tenant_id''::text, true), ''''::text))::uuid):'
         || '(tenant_id = (NULLIF(current_setting(''app.tenant_id''::text, true), ''''::text))::uuid)' THEN
        RAISE EXCEPTION 'migration 274: unexpected policies on shared.notifications: %', pols;
    END IF;
    SELECT string_agg(a.privilege_type, ',' ORDER BY a.privilege_type) INTO privs
      FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
     WHERE c.oid = tbl AND a.grantee = 'aa_app_user'::regrole;
    SELECT string_agg(att.attname || ':' || a.privilege_type, ',' ORDER BY att.attname, a.privilege_type) INTO cprivs
      FROM pg_attribute att CROSS JOIN LATERAL aclexplode(att.attacl) a
     WHERE att.attrelid = tbl AND att.attacl IS NOT NULL AND a.grantee = 'aa_app_user'::regrole;
    IF privs IS DISTINCT FROM 'SELECT' OR cprivs IS DISTINCT FROM 'is_read:UPDATE' THEN
        RAISE EXCEPTION 'migration 274: aa_app_user on shared.notifications holds % / columns %', privs, cprivs;
    END IF;
    IF (SELECT string_agg(p, ',' ORDER BY p) FROM unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
         WHERE has_table_privilege('cis_app', tbl, p)) IS DISTINCT FROM NULLIF(current_setting('aa986.cis_app_privs'), '')
    THEN
        RAISE EXCEPTION 'migration 274: cis_app''s privileges on shared.notifications changed';
    END IF;
    -- the runner (the owner, exempt) still counts every row, also under a foreign GUC
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    SELECT count(*) INTO n FROM shared.notifications;
    PERFORM set_config('app.tenant_id', '', true);
    IF n::text IS DISTINCT FROM current_setting('aa986.notif_rows') THEN
        RAISE EXCEPTION 'migration 274: the runner counts % notification rows, % before RLS', n,
            current_setting('aa986.notif_rows');
    END IF;
    RAISE NOTICE 'migration 274: shared.notifications under RLS, % rows, % tenant-facing', n,
        (SELECT count(*) FROM shared.notifications WHERE target_roles @> ARRAY['tenant']::text[]);
END $$;

-- ── Part B: catalog contract views of the tour lifecycle (X1 S22 catalog recipe) ────────────────────────────────────
DO $$
DECLARE
    v text;
BEGIN
    IF (SELECT count(*) FROM shared.schema_versions WHERE version IN ('272', '273')) <> 2 THEN
        RAISE EXCEPTION 'migration 274: apply 272 and 273 first';
    END IF;
    IF to_regclass('gold_aa_internal.v_tour_liveness') IS NULL
       OR to_regclass('gold_aa_internal.tour_lifecycle_event') IS NULL OR to_regclass('catalog.v_tour') IS NULL THEN
        RAISE EXCEPTION 'migration 274: v_tour_liveness / tour_lifecycle_event (272) or catalog.v_tour (253) missing';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 274: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    IF to_regrole('catalog_owner') IS NULL OR to_regrole('booking') IS NULL OR to_regrole('tripplanner') IS NULL THEN
        RAISE EXCEPTION 'migration 274: roles catalog_owner, booking and tripplanner must exist (contracts rule 5)';
    END IF;
    IF NOT has_schema_privilege('catalog_owner', 'gold_aa_internal', 'USAGE')
       OR NOT has_table_privilege('catalog_owner', 'gold_aa_internal.v_tour_liveness', 'SELECT')
       OR NOT has_table_privilege('catalog_owner', 'gold_aa_internal.tour_lifecycle_event', 'SELECT') THEN
        RAISE EXCEPTION 'migration 274: catalog_owner cannot read gold_aa_internal (USAGE %, v_tour_liveness %, '
                        'tour_lifecycle_event %: 272 grants)',
            has_schema_privilege('catalog_owner', 'gold_aa_internal', 'USAGE'),
            has_table_privilege('catalog_owner', 'gold_aa_internal.v_tour_liveness', 'SELECT'),
            has_table_privilege('catalog_owner', 'gold_aa_internal.tour_lifecycle_event', 'SELECT');
    END IF;
    FOREACH v IN ARRAY ARRAY['catalog.v_tour_retired', 'catalog.v_tour_lifecycle_outbox'] LOOP
        IF to_regclass(v) IS NOT NULL
           AND (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = to_regclass(v)) <> 'catalog_owner' THEN
            RAISE EXCEPTION 'migration 274: % exists and is not catalog_owner''s', v;
        END IF;
    END LOOP;
END $$;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

CREATE OR REPLACE VIEW catalog.v_tour_retired WITH (security_barrier = true) AS
SELECT l.source_system,
       l.source_id,
       l.tour_id,
       l.state,
       l.reason,
       l.changed_at
  FROM gold_aa_internal.v_tour_liveness l
 WHERE l.state IN ('retired', 'paused')
UNION ALL
SELECT l.source_system,
       l.source_id,
       l.tour_id,
       'restored'::text AS state,
       e.reason,
       e.occurred_at AS changed_at
  FROM gold_aa_internal.v_tour_liveness l
  JOIN LATERAL (
        SELECT ev.event, ev.reason, ev.occurred_at
          FROM gold_aa_internal.tour_lifecycle_event ev
         WHERE ev.source_id = l.source_id
         ORDER BY ev.occurred_at DESC, ev.id DESC
         LIMIT 1
       ) e ON true
 WHERE l.state = 'served'
   AND e.event = 'restored';

COMMENT ON VIEW catalog.v_tour_retired IS
    'AA-986 L4 (CIS 274, contract catalog.tour.v1.3, root ADR 0015 decision 4): the tombstone of the CIS catalog. One '
    'row per catalog key (source_system, source_id) that AA does not serve now (state retired: answer 410, list as '
    'withdrawn; state paused: temporarily absent, answer 404 and keep the URL) or that is served again after a change '
    '(state restored: undo what was done on retired / paused). Derived from the served state (gold_aa_internal.'
    'v_tour_liveness), so it never disagrees with catalog.v_tour. A key never served has no row.';

CREATE OR REPLACE VIEW catalog.v_tour_lifecycle_outbox WITH (security_barrier = true) AS
SELECT e.id AS event_id,
       e.source_system,
       e.source_id,
       e.tour_id,
       e.event,
       e.reason,
       e.replaced_by_tour_id,
       e.occurred_at,
       e.idempotency_key
  FROM gold_aa_internal.tour_lifecycle_event e;

COMMENT ON VIEW catalog.v_tour_lifecycle_outbox IS
    'AA-986 L4 (CIS 274, contract catalog.tour.v1.3, root ADR 0015 decision 4): the served-state changes of CIS catalog '
    'keys, append-only. Pull with WHERE event_id > :cursor ORDER BY event_id and a lag window (an id can commit after '
    'a higher one), process each idempotency_key once (contracts README rules 3-4). event: retired | paused | '
    'restored | superseded (replaced_by_tour_id = the new version, same source_id).';

REVOKE ALL ON catalog.v_tour_retired, catalog.v_tour_lifecycle_outbox FROM PUBLIC;
GRANT SELECT ON catalog.v_tour_retired, catalog.v_tour_lifecycle_outbox TO booking, tripplanner, aa_app_user;

-- ── Closing checks as catalog_owner (its view rights, a foreign GUC: only its own policies admit rows) ─────────────
DO $$
DECLARE
    cols text;
    n    bigint;
    m    bigint;
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_tour_retired'::regclass AND a.attnum > 0
       AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'source_system text, source_id text, tour_id uuid, state text, reason text, '
                             'changed_at timestamp with time zone' THEN
        RAISE EXCEPTION 'migration 274: catalog.v_tour_retired has unexpected columns: %', cols;
    END IF;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_tour_lifecycle_outbox'::regclass AND a.attnum > 0
       AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'event_id bigint, source_system text, source_id text, tour_id uuid, event text, '
                             'reason text, replaced_by_tour_id uuid, occurred_at timestamp with time zone, '
                             'idempotency_key text' THEN
        RAISE EXCEPTION 'migration 274: catalog.v_tour_lifecycle_outbox has unexpected columns: %', cols;
    END IF;

    -- behaviour: one row per key, known values, the not-served keys exactly, none of them live in the catalog
    SELECT count(*) - count(DISTINCT source_id) INTO n FROM catalog.v_tour_retired;
    IF n <> 0 THEN
        RAISE EXCEPTION 'migration 274: catalog.v_tour_retired has % duplicate keys', n;
    END IF;
    IF EXISTS (SELECT 1 FROM catalog.v_tour_retired
                WHERE NOT ((state = 'retired' AND reason IN ('source_deleted', 'master_trashed', 'superseded_orphan'))
                        OR (state = 'paused' AND reason IN ('master_inactive', 'superseded_pending'))
                        OR (state = 'restored' AND reason IN ('restore', 'publish', 'activate', 'set_active')))) THEN
        RAISE EXCEPTION 'migration 274: catalog.v_tour_retired has an unknown state / reason pair';
    END IF;
    SELECT count(*) INTO n FROM catalog.v_tour_retired WHERE state IN ('retired', 'paused');
    SELECT count(*) INTO m FROM gold_aa_internal.v_tour_liveness WHERE state <> 'served';
    IF n <> m THEN
        RAISE EXCEPTION 'migration 274: % retired / paused rows, % not-served keys in v_tour_liveness', n, m;
    END IF;
    SELECT count(*) INTO n FROM catalog.v_tour_retired r JOIN catalog.v_tour t ON t.source_id = r.source_id
     WHERE r.state IN ('retired', 'paused');
    IF n <> 0 THEN
        RAISE EXCEPTION 'migration 274: % retired / paused keys are live in catalog.v_tour', n;
    END IF;
    SELECT count(*) INTO n FROM catalog.v_tour_lifecycle_outbox;
    SELECT count(*) INTO m FROM gold_aa_internal.tour_lifecycle_event;
    IF n <> m THEN
        RAISE EXCEPTION 'migration 274: the outbox shows % of % lifecycle events', n, m;
    END IF;
    RAISE NOTICE 'migration 274: v_tour_retired % rows (retired %, paused %, restored %), outbox % events',
        (SELECT count(*) FROM catalog.v_tour_retired),
        (SELECT count(*) FROM catalog.v_tour_retired WHERE state = 'retired'),
        (SELECT count(*) FROM catalog.v_tour_retired WHERE state = 'paused'),
        (SELECT count(*) FROM catalog.v_tour_retired WHERE state = 'restored'), m;
    PERFORM set_config('app.tenant_id', '', true);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Guards on the result (as cis_owner) ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    privs text;
    bad   text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class
                WHERE oid IN ('catalog.v_tour_retired'::regclass, 'catalog.v_tour_lifecycle_outbox'::regclass)
                  AND (pg_get_userbyid(relowner) <> 'catalog_owner'
                       OR NOT COALESCE(reloptions, '{}') @> ARRAY['security_barrier=true'])) THEN
        RAISE EXCEPTION 'migration 274: the two views must be catalog_owner''s and security_barrier';
    END IF;
    SELECT string_agg(r || ':' || o || ':' || p, ', ' ORDER BY r, o, p) INTO privs FROM (
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r,
               c.relname::text AS o, a.privilege_type AS p
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid IN ('catalog.v_tour_retired'::regclass, 'catalog.v_tour_lifecycle_outbox'::regclass)
           AND a.grantee <> c.relowner) x;
    IF privs IS DISTINCT FROM
         'aa_app_user:v_tour_lifecycle_outbox:SELECT, aa_app_user:v_tour_retired:SELECT, '
         'booking:v_tour_lifecycle_outbox:SELECT, booking:v_tour_retired:SELECT, '
         'tripplanner:v_tour_lifecycle_outbox:SELECT, tripplanner:v_tour_retired:SELECT' THEN
        RAISE EXCEPTION 'migration 274: unexpected grants on the two catalog views: %', privs;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attacl IS NOT NULL
                AND attrelid IN ('catalog.v_tour_retired'::regclass, 'catalog.v_tour_lifecycle_outbox'::regclass)) THEN
        RAISE EXCEPTION 'migration 274: column grants on the two catalog views';
    END IF;
    IF has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 274: catalog_owner still has CREATE on schema catalog';
    END IF;

    -- the AA-859 invariant, version 3 (same text as 272 guard 4 / NO_PRIVILEGE_WITHOUT_RLS_SQL_V3)
    SELECT string_agg(rel || ' ' || privilege_type || COALESCE('(' || column_name || ')', ''), ', ') INTO bad FROM (
SELECT c.oid::regclass::text AS rel, a.privilege_type, NULL::text AS column_name
  FROM pg_class c
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
 CROSS JOIN LATERAL aclexplode(c.relacl) a
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND NOT c.relrowsecurity
   AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
   AND ns.nspname NOT LIKE 'pg_toast%'
   AND a.grantee = 'aa_app_user'::regrole
   AND NOT (ns.nspname = 'catalog'
            AND c.relowner IS NOT DISTINCT FROM to_regrole('catalog_owner')
            AND a.privilege_type = 'SELECT')
   AND NOT (ns.nspname || '.' || c.relname = ANY (ARRAY['acp_contract.route', 'acp_contract.atom_segment',
                                                        'acp_contract.atom_segment_member',
                                                        'acp_contract.atom_segment_alias',
                                                        'acp_shared.place_card_alias', 'acp_shared.atom_place_card',
                                                        'gold_aa_internal.v_tour_liveness'])
            AND a.privilege_type = 'SELECT')
UNION ALL
SELECT c.oid::regclass::text, a.privilege_type, att.attname::text
  FROM pg_class c
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
  JOIN pg_attribute att ON att.attrelid = c.oid AND att.attacl IS NOT NULL AND NOT att.attisdropped
 CROSS JOIN LATERAL aclexplode(att.attacl) a
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND NOT c.relrowsecurity
   AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
   AND ns.nspname NOT LIKE 'pg_toast%'
   AND a.grantee = 'aa_app_user'::regrole
   AND NOT (ns.nspname || '.' || c.relname = 'acp_shared.place_card'
            AND att.attname IN ('card_id', 'status')
            AND a.privilege_type = 'SELECT')
ORDER BY 1, 3, 2
    ) v;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 274: aa_app_user holds privileges on relations without RLS: % (AA-859 invariant v3)',
            bad;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('274', now(), 'AA-986 L3/L4: shared.notifications under RLS (tenant reads its own tenant-facing rows); '
                      'catalog.v_tour_retired + catalog.v_tour_lifecycle_outbox (contract catalog.tour.v1.3)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
