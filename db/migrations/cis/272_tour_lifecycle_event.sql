-- Migration 272: AA-986 L2 — the tour lifecycle record (append-only), the reason a Master Content row is switched
-- off, and the one CIS read view of the served state.
--
-- Why. ADR 0015 (root docs/adr/0015-tour-liveness-and-retirement-propagation.md, Accepted S248): every change to a
-- tour's served state goes through one CIS write service (services/tour_lifecycle, slice L2), which records why it
-- changed a Master (so `restore` re-enables only the Masters the service itself switched off, not one staff
-- deactivated on purpose: the restore bug of audit S248 section 2.1) and writes an append-only record of each served-
-- state change per catalog key (decision 4). CIS reads the derived state from one view (decision 3).
--
-- What.
--   1. gold_aa_internal.published_tours.master_status_reason text NULL + CHECK: why the Master is not active.
--        staff_deactivated  staff set it inactive (Master Content "Set Inactive", or restored from trash: inactive)
--        staff_trashed      staff trashed the Master
--        source_deleted     the service switched it off because its source version was deleted at S0/A0
--        superseded         the service switched it off because a newer version of the tour replaced its source
--      NULL = active, or a row switched off before L2 (Dev 23/10/2026: every Master is active, probe S248; the NOTICE
--      prints the count). No backfill: a NULL reason is never re-enabled by `restore` (the safe side).
--   2. gold_aa_internal.tour_lifecycle_event: one row per served-state change of a catalog key
--      (source_system 'cis', source_id = raw_tours.source_key), written only by the service, in the transaction of
--      the change. Append-only: cis_app INSERT + SELECT (UPDATE / DELETE / TRUNCATE revoked, also from the Dev default
--      ACL of cis_owner), a BEFORE UPDATE OR DELETE trigger refuses every change, catalog_owner SELECT (for the L4
--      catalog views). No tenant column, no personal data (actor = 'admin' / a staff uuid / 'pipeline'), so no RLS.
--   3. gold_aa_internal.v_tour_liveness: the served state per catalog key that was ever served (some version of the key
--      has a Master Content row): source_system, source_id, tour_id, state, reason, changed_at.
--        served   the live version (source active, not deleted) has a live Master (active, not deleted)
--        paused   the live version's Master is inactive (master_inactive, Q1), or the live version has no Master yet
--                 while an older version had one (superseded_pending, Q11)
--        retired  the live version's Master is trashed (master_trashed); no live version and a version was deleted at
--                 S0/A0 (source_deleted); no live version, none deleted (superseded_orphan)
--      The key is COALESCE(source_group_id, tour_id)::text, the expression of raw_tours.source_key (258), written out so
--      the view does not depend on the stored column. tour_id = the live version, else the newest version. changed_at = the latest lifecycle event of the key, else the
--      best column date. A key never served has no row (consumers answer 404, ADR 0015 decision 1). Owner-rights view
--      (not security_invoker, like the catalog views): its owner reads raw_tours / published_tours through their
--      <t>_cis_owner_all policies. AA master tenant only, the catalog._live_tour rule (258) for `served`; guard 3
--      checks the two agree. SELECT to cis_app, aa_app_user (the tenant pool, slice L3: it carries no tenant data, the
--      state of AA's catalog keys) and catalog_owner.
--   4. AA-859 invariant v3 (guard 4): v2 (265 / 266) plus the one new exception, SELECT on
--      gold_aa_internal.v_tour_liveness. tests/integration/_rls_fixture_helpers.py NO_PRIVILEGE_WITHOUT_RLS_SQL_V3
--      carries the same text.
--   5. Register 272.
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before: the roles cis_app, aa_app_user, catalog_owner exist; the runner may alter published_tours (owns it or is
--      a member of its owner) and create in gold_aa_internal; master_status_reason, if present, is a nullable text
--      column (re-run); tour_lifecycle_event, if present, has exactly this file's columns (re-run);
--   2. after: the column, its CHECK, the table, its columns, its trigger; privileges exactly: cis_app {INSERT, SELECT}
--      on the table and {SELECT} on the view, catalog_owner {SELECT} on both, aa_app_user none on the table and
--      {SELECT} on the view, PUBLIC none on either; the view's columns are the six above;
--   3. behaviour: the view's served keys = the keys of the catalog._live_tour rule (258 predicates, inline: the runner
--      cis_owner has no SELECT on catalog_owner's views), every state / reason is a known value, one row per key;
--   4. AA-859 invariant v3 (no aa_app_user privilege on a relation without RLS outside the allowlists).
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: column absent, table absent,
-- non_active_masters 0, ever_served_keys ~ 890+, served_keys = live catalog keys):
--   SELECT (SELECT count(*) FROM pg_attribute WHERE attrelid = 'gold_aa_internal.published_tours'::regclass
--            AND attname = 'master_status_reason' AND NOT attisdropped) AS column_present,
--          to_regclass('gold_aa_internal.tour_lifecycle_event') AS table_present,
--          (SELECT count(*) FROM gold_aa_internal.published_tours WHERE master_status <> 'active') AS non_active_masters,
--          (SELECT count(DISTINCT rt.source_key) FROM silver_aa_internal.raw_tours rt
--             JOIN gold_aa_internal.published_tours pt ON pt.tour_id = rt.tour_id) AS ever_served_keys;
--
-- Locks. ALTER TABLE published_tours ADD COLUMN (nullable, no default: catalog-only) and ADD CONSTRAINT (a scan of
-- ~900 rows) take ACCESS EXCLUSIVE on published_tours for milliseconds; lock_timeout 5s gives up instead of queueing
-- the readers. Apply through AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/) with shared.job and booking.job
-- idle (DM-11.4). Re-running is a no-op apart from the guards.
--
-- Order with the code. Nothing reads these objects until the L2 code PR (services/tour_lifecycle) deploys, and that
-- code needs them: merge this file's PR, copy to Infra, DB Migrate check → apply, then merge the code PR.
--
-- Undo (a NEW forward migration; only before the L2 code is deployed): DROP VIEW gold_aa_internal.v_tour_liveness;
-- DROP TABLE gold_aa_internal.tour_lifecycle_event; DROP FUNCTION gold_aa_internal.tour_lifecycle_event_append_only();
-- ALTER TABLE gold_aa_internal.published_tours DROP COLUMN master_status_reason.
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243). DB Migrate runs cis/ files as cis_owner, the owner
-- of gold_aa_internal and of published_tours (245).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── Guard 1: roles, runner rights, re-run shape ────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    owner_pt   name;
    owner_ns   name;
    col_type   text;
    col_nn     boolean;
    ev_cols    text;
    ev_expect  text := 'id bigint, source_system text, source_id text, tour_id uuid, event text, reason text, '
                       'replaced_by_tour_id uuid, action text, actor text, details jsonb, '
                       'occurred_at timestamp with time zone, idempotency_key text';
    n          bigint;
BEGIN
    IF to_regrole('cis_app') IS NULL OR to_regrole('aa_app_user') IS NULL OR to_regrole('catalog_owner') IS NULL THEN
        RAISE EXCEPTION 'migration 272: roles cis_app, aa_app_user and catalog_owner must exist';
    END IF;
    SELECT pg_get_userbyid(c.relowner) INTO owner_pt FROM pg_class c
     WHERE c.oid = 'gold_aa_internal.published_tours'::regclass;
    IF NOT pg_has_role(current_user, owner_pt, 'USAGE') THEN
        RAISE EXCEPTION 'migration 272: % may not alter gold_aa_internal.published_tours (owner %); run it through '
                        'DB Migrate (cis_owner)', current_user, owner_pt;
    END IF;
    SELECT pg_get_userbyid(n2.nspowner) INTO owner_ns FROM pg_namespace n2 WHERE n2.nspname = 'gold_aa_internal';
    IF NOT has_schema_privilege(current_user, 'gold_aa_internal', 'CREATE') THEN
        RAISE EXCEPTION 'migration 272: % may not create in gold_aa_internal (owner %)', current_user, owner_ns;
    END IF;

    SELECT format_type(a.atttypid, a.atttypmod), a.attnotnull INTO col_type, col_nn
      FROM pg_attribute a
     WHERE a.attrelid = 'gold_aa_internal.published_tours'::regclass AND a.attname = 'master_status_reason'
       AND NOT a.attisdropped;
    IF FOUND AND (col_type <> 'text' OR col_nn) THEN
        RAISE EXCEPTION 'migration 272: published_tours.master_status_reason exists as % (not null %), not this '
                        'file''s nullable text', col_type, col_nn;
    END IF;

    IF to_regclass('gold_aa_internal.tour_lifecycle_event') IS NOT NULL THEN
        SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
          INTO ev_cols
          FROM pg_attribute a
         WHERE a.attrelid = 'gold_aa_internal.tour_lifecycle_event'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
        IF ev_cols IS DISTINCT FROM ev_expect THEN
            RAISE EXCEPTION 'migration 272: gold_aa_internal.tour_lifecycle_event exists with other columns: %', ev_cols;
        END IF;
    END IF;

    SELECT count(*) INTO n FROM gold_aa_internal.published_tours WHERE master_status <> 'active';
    RAISE NOTICE 'migration 272: Master rows not active before the file: % (their reason stays NULL)', n;
END $$;

-- ── 1. Why a Master is not active ──────────────────────────────────────────────────────────────────────────────────
ALTER TABLE gold_aa_internal.published_tours ADD COLUMN IF NOT EXISTS master_status_reason text;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'gold_aa_internal.published_tours'::regclass
                      AND conname = 'published_tours_master_status_reason_check') THEN
        ALTER TABLE gold_aa_internal.published_tours
            ADD CONSTRAINT published_tours_master_status_reason_check
            CHECK (master_status_reason IS NULL
                   OR master_status_reason IN ('staff_deactivated', 'staff_trashed', 'source_deleted', 'superseded'));
    END IF;
END $$;

COMMENT ON COLUMN gold_aa_internal.published_tours.master_status_reason IS
    'AA-986 L2 (ADR 0015): why this Master is not active. staff_deactivated / staff_trashed = a staff action; '
    'source_deleted / superseded = the tour lifecycle service switched it off (only those come back on restore / '
    'set-active). NULL = active, or switched off before CIS 272. Written only by services/tour_lifecycle.';

-- ── 2. The lifecycle record (append-only) ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS gold_aa_internal.tour_lifecycle_event (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_system       text NOT NULL DEFAULT 'cis',
    source_id           text NOT NULL,
    tour_id             uuid NOT NULL,
    event               text NOT NULL,
    reason              text NOT NULL,
    replaced_by_tour_id uuid,
    action              text NOT NULL,
    actor               text,
    details             jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at         timestamp with time zone NOT NULL DEFAULT now(),
    idempotency_key     text NOT NULL,
    CONSTRAINT tour_lifecycle_event_source_system_check CHECK (source_system = 'cis'),
    CONSTRAINT tour_lifecycle_event_event_check
        CHECK (event IN ('retired', 'paused', 'restored', 'superseded')),
    CONSTRAINT tour_lifecycle_event_reason_check
        CHECK (reason IN ('source_deleted', 'master_trashed', 'superseded_orphan', 'master_inactive',
                          'superseded_pending', 'replaced', 'restore', 'publish', 'activate', 'set_active')),
    CONSTRAINT tour_lifecycle_event_successor_check
        CHECK ((event = 'superseded') = (replaced_by_tour_id IS NOT NULL)),
    CONSTRAINT tour_lifecycle_event_idempotency_key_key UNIQUE (idempotency_key)
);

CREATE INDEX IF NOT EXISTS tour_lifecycle_event_key_idx
    ON gold_aa_internal.tour_lifecycle_event (source_id, occurred_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS tour_lifecycle_event_tour_idx
    ON gold_aa_internal.tour_lifecycle_event (tour_id);

COMMENT ON TABLE gold_aa_internal.tour_lifecycle_event IS
    'AA-986 L2 (ADR 0015 decision 4): append-only record of served-state changes per catalog key '
    '(source_system, source_id = raw_tours.source_key). Written only by services/tour_lifecycle in the transaction of '
    'the change; the derived state (gold_aa_internal.v_tour_liveness) stays the truth. Read by the L4 catalog views.';
COMMENT ON COLUMN gold_aa_internal.tour_lifecycle_event.actor IS
    'Who asked: admin, a staff user id, or pipeline. A label, not a person''s name or e-mail.';

CREATE OR REPLACE FUNCTION gold_aa_internal.tour_lifecycle_event_append_only() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'gold_aa_internal.tour_lifecycle_event is append-only (AA-986, ADR 0015 decision 4)';
END
$fn$;

DROP TRIGGER IF EXISTS tour_lifecycle_event_append_only ON gold_aa_internal.tour_lifecycle_event;
CREATE TRIGGER tour_lifecycle_event_append_only
    BEFORE UPDATE OR DELETE ON gold_aa_internal.tour_lifecycle_event
    FOR EACH ROW EXECUTE FUNCTION gold_aa_internal.tour_lifecycle_event_append_only();

REVOKE ALL ON gold_aa_internal.tour_lifecycle_event FROM PUBLIC;
REVOKE ALL ON gold_aa_internal.tour_lifecycle_event FROM cis_app, aa_app_user, catalog_owner;
GRANT INSERT, SELECT ON gold_aa_internal.tour_lifecycle_event TO cis_app;
GRANT SELECT ON gold_aa_internal.tour_lifecycle_event TO catalog_owner;

-- ── 3. The served state per catalog key ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW gold_aa_internal.v_tour_liveness AS
SELECT 'cis'::text AS source_system,
       g.source_key AS source_id,
       g.tour_id,
       d.state,
       d.reason,
       COALESCE(ev.occurred_at, g.cur_master_deleted_at, g.last_source_deleted_at, g.last_published_at,
                g.last_ingest_at) AS changed_at
  FROM (
        SELECT (COALESCE(rt.source_group_id, rt.tour_id))::text AS source_key,
               bool_or(pt.tour_id IS NOT NULL) AS ever_master,
               bool_or(rt.source_status = 'active' AND rt.deleted_at IS NULL) AS has_live,
               bool_or(rt.source_status = 'trashed' OR rt.deleted_at IS NOT NULL) AS any_deleted,
               (array_agg(rt.tour_id
                          ORDER BY (rt.source_status = 'active' AND rt.deleted_at IS NULL) DESC,
                                   rt.source_version DESC, rt.ingest_at DESC, rt.tour_id))[1] AS tour_id,
               (array_agg(pt.tour_id IS NOT NULL
                          ORDER BY (rt.source_status = 'active' AND rt.deleted_at IS NULL) DESC,
                                   rt.source_version DESC, rt.ingest_at DESC, rt.tour_id))[1] AS cur_has_master,
               (array_agg(pt.master_status::text
                          ORDER BY (rt.source_status = 'active' AND rt.deleted_at IS NULL) DESC,
                                   rt.source_version DESC, rt.ingest_at DESC, rt.tour_id))[1] AS cur_master_status,
               (array_agg(pt.deleted_at
                          ORDER BY (rt.source_status = 'active' AND rt.deleted_at IS NULL) DESC,
                                   rt.source_version DESC, rt.ingest_at DESC, rt.tour_id))[1] AS cur_master_deleted_at,
               max(rt.deleted_at) AS last_source_deleted_at,
               max(pt.published_at) AS last_published_at,
               max(rt.ingest_at) AS last_ingest_at
          FROM silver_aa_internal.raw_tours rt
          LEFT JOIN gold_aa_internal.published_tours pt
            ON pt.tour_id = rt.tour_id
           AND pt.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
         WHERE rt.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
         GROUP BY (COALESCE(rt.source_group_id, rt.tour_id))::text
       ) g
 CROSS JOIN LATERAL (
        SELECT CASE
                 WHEN g.has_live AND g.cur_has_master AND g.cur_master_status = 'active'
                      AND g.cur_master_deleted_at IS NULL                                    THEN 'served'
                 WHEN g.has_live AND g.cur_has_master
                      AND (g.cur_master_status = 'trashed' OR g.cur_master_deleted_at IS NOT NULL) THEN 'retired'
                 WHEN g.has_live                                                             THEN 'paused'
                 ELSE 'retired'
               END AS state,
               CASE
                 WHEN g.has_live AND g.cur_has_master AND g.cur_master_status = 'active'
                      AND g.cur_master_deleted_at IS NULL                                    THEN NULL
                 WHEN g.has_live AND g.cur_has_master
                      AND (g.cur_master_status = 'trashed' OR g.cur_master_deleted_at IS NOT NULL) THEN 'master_trashed'
                 WHEN g.has_live AND g.cur_has_master                                        THEN 'master_inactive'
                 WHEN g.has_live                                                             THEN 'superseded_pending'
                 WHEN g.any_deleted                                                          THEN 'source_deleted'
                 ELSE 'superseded_orphan'
               END AS reason
       ) d
  LEFT JOIN LATERAL (
        SELECT e.occurred_at
          FROM gold_aa_internal.tour_lifecycle_event e
         WHERE e.source_id = g.source_key
         ORDER BY e.occurred_at DESC, e.id DESC
         LIMIT 1
       ) ev ON true
 WHERE g.ever_master;

COMMENT ON VIEW gold_aa_internal.v_tour_liveness IS
    'AA-986 L2 (ADR 0015 decision 3): the served state of each CIS catalog key that was ever served '
    '(served | paused | retired, with the reason). Derived from raw_tours + published_tours (the catalog._live_tour rule '
    'for served), never stored. The one read of "is this tour served?" inside CIS; owner-rights view.';

REVOKE ALL ON gold_aa_internal.v_tour_liveness FROM PUBLIC;
REVOKE ALL ON gold_aa_internal.v_tour_liveness FROM cis_app, aa_app_user, catalog_owner;
GRANT SELECT ON gold_aa_internal.v_tour_liveness TO cis_app, aa_app_user, catalog_owner;

-- ── Guards 2 + 3 + 4 ───────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    t_oid   oid := 'gold_aa_internal.tour_lifecycle_event'::regclass;
    v_oid   oid := 'gold_aa_internal.v_tour_liveness'::regclass;
    cols    text;
    privs   text;
    bad     text;
    n       bigint;
    m       bigint;
BEGIN
    -- 2. shape
    IF NOT EXISTS (SELECT 1 FROM pg_attribute a
                    WHERE a.attrelid = 'gold_aa_internal.published_tours'::regclass
                      AND a.attname = 'master_status_reason' AND NOT a.attisdropped
                      AND format_type(a.atttypid, a.atttypmod) = 'text' AND NOT a.attnotnull) THEN
        RAISE EXCEPTION 'migration 272: published_tours.master_status_reason missing or not a nullable text';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'gold_aa_internal.published_tours'::regclass
                      AND conname = 'published_tours_master_status_reason_check' AND convalidated) THEN
        RAISE EXCEPTION 'migration 272: published_tours_master_status_reason_check missing or not validated';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgrelid = t_oid AND tgname = 'tour_lifecycle_event_append_only' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'migration 272: the append-only trigger is missing';
    END IF;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
      INTO cols
      FROM pg_attribute a WHERE a.attrelid = v_oid AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'source_system text, source_id text, tour_id uuid, state text, reason text, '
                             'changed_at timestamp with time zone' THEN
        RAISE EXCEPTION 'migration 272: v_tour_liveness has unexpected columns: %', cols;
    END IF;

    -- 2. privileges of the four roles that matter, table level (no column grants on either object)
    SELECT string_agg(r || ':' || o || ':' || p, ', ' ORDER BY r, o, p) INTO privs FROM (
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r,
               CASE WHEN c.oid = t_oid THEN 'event' ELSE 'view' END AS o,
               a.privilege_type AS p
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid IN (t_oid, v_oid)
           AND (a.grantee = 0 OR a.grantee IN ('cis_app'::regrole, 'aa_app_user'::regrole,
                                               'catalog_owner'::regrole))) x;
    IF privs IS DISTINCT FROM 'aa_app_user:view:SELECT, catalog_owner:event:SELECT, catalog_owner:view:SELECT, '
                              'cis_app:event:INSERT, cis_app:event:SELECT, cis_app:view:SELECT' THEN
        RAISE EXCEPTION 'migration 272: unexpected privileges on the event table / view: %', privs;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid IN (t_oid, v_oid) AND a.attacl IS NOT NULL) THEN
        RAISE EXCEPTION 'migration 272: column-level grants on the event table / view';
    END IF;

    -- 3. behaviour: served keys = the catalog._live_tour rule (258 predicates), known values, one row per key
    SELECT count(*) INTO n FROM (
        SELECT source_id FROM gold_aa_internal.v_tour_liveness WHERE state = 'served'
        EXCEPT
        SELECT DISTINCT (COALESCE(rt.source_group_id, rt.tour_id))::text
          FROM gold_aa_internal.published_tours pt
          JOIN silver_aa_internal.raw_tours rt ON rt.tour_id = pt.tour_id
         WHERE pt.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
           AND pt.master_status = 'active' AND pt.deleted_at IS NULL
           AND rt.source_status = 'active' AND rt.deleted_at IS NULL) x;
    SELECT count(*) INTO m FROM (
        SELECT DISTINCT (COALESCE(rt.source_group_id, rt.tour_id))::text
          FROM gold_aa_internal.published_tours pt
          JOIN silver_aa_internal.raw_tours rt ON rt.tour_id = pt.tour_id
         WHERE pt.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
           AND pt.master_status = 'active' AND pt.deleted_at IS NULL
           AND rt.source_status = 'active' AND rt.deleted_at IS NULL
        EXCEPT
        SELECT source_id FROM gold_aa_internal.v_tour_liveness WHERE state = 'served') y;
    IF n <> 0 OR m <> 0 THEN
        RAISE EXCEPTION 'migration 272: v_tour_liveness served keys differ from the catalog rule (% extra, % missing)',
            n, m;
    END IF;
    IF EXISTS (SELECT 1 FROM gold_aa_internal.v_tour_liveness
                WHERE state NOT IN ('served', 'paused', 'retired')
                   OR (state = 'served') <> (reason IS NULL)
                   OR reason NOT IN ('master_inactive', 'superseded_pending', 'master_trashed', 'source_deleted',
                                     'superseded_orphan')) THEN
        RAISE EXCEPTION 'migration 272: v_tour_liveness has an unknown state / reason';
    END IF;
    SELECT count(*) - count(DISTINCT source_id) INTO n FROM gold_aa_internal.v_tour_liveness;
    IF n <> 0 THEN
        RAISE EXCEPTION 'migration 272: v_tour_liveness has % duplicate key rows', n;
    END IF;

    -- 4. the AA-859 invariant, version 3 (same text as NO_PRIVILEGE_WITHOUT_RLS_SQL_V3)
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
        RAISE EXCEPTION 'migration 272: aa_app_user holds privileges on relations without RLS: % (AA-859 invariant v3)',
            bad;
    END IF;

    SELECT count(*), count(*) FILTER (WHERE state = 'served') INTO n, m FROM gold_aa_internal.v_tour_liveness;
    RAISE NOTICE 'migration 272: v_tour_liveness keys %, served %, not served %', n, m, n - m;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('272', now(), 'AA-986 L2: tour lifecycle record, Master status reason, v_tour_liveness')
ON CONFLICT (version) DO NOTHING;

COMMIT;
