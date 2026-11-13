-- Migration 410: AA-1093 lane L2 — the contract view catalog.v_tenant_erasure_v1 (contract tenant.erasure.v1 1.0):
-- the tenant erasure requests, as AA-Booking and TripPlanner pull them.
--
-- Why. CIS runs the offboarding erasure saga (CIS 408). Booking and TripPlanner read CIS only through catalog contract
-- views (roles booking / tripplanner have USAGE on schema catalog, never on shared), so they learn of a request, its
-- phase, their own earliest date and the plan hash the tech lead approved here. They answer through their own report
-- views (booking.v_tenant_erasure_report_v1, tripplanner.v_tenant_erasure_report_v1, owned by those apps). The partner
-- CRM reads the same requests over HTTP (GET /tenant/v1/erasure-requests).
--
-- What:
--   1. Column-level SELECT for catalog_owner on shared.tenant_erasure_request (request_id, tenant_id, phase, round,
--      opened_at, approval_expires_at, is_pilot, is_synthetic, not_before_booking, not_before_tripplanner, round_apps,
--      done_apps, updated_at) and shared.tenant_erasure_step (request_id, round, app, mode, status,
--      approved_plan_hash): no approver, snapshot, blocker, receipt, fingerprint or report column.
--   2. catalog.v_tenant_erasure_v1 (security_barrier, owner catalog_owner): the contract's ErasureRequestRow, one row
--      per request and consuming app (booking, tripplanner): request_id, tenant_id, phase, round, opened_at,
--      approval_expires_at, is_pilot, is_synthetic, app, step_status, not_before (the app's own earliest date),
--      approved_plan_hash (the app's DRY RUN plan hash of the current round once the combined fingerprint is approved,
--      else NULL), updated_at. step_status: done (the app's erasure is verified), failed (active and its report of the
--      current round is blocked, refused or failed), active (part of the current round), waiting (not yet: its
--      not_before has not passed or an earlier stage still runs). Ids, codes, hashes and timestamps only; no personal
--      data. SELECT to booking and tripplanner. Contract v1: columns are only appended.
--      What an app does (tenant.erasure.v1): step active and phase dry_run = compute the plan and report it (mode
--      dry_run); active and phase apply = before approval_expires_at, recompute, match approved_plan_hash, apply,
--      report (mode apply; refused with error_code plan_changed when the hash differs); active and phase verify =
--      report the census of its pii: columns for the tenant (mode verify); otherwise nothing.
--   3. Register 410.
--
-- Behaviour on apply. None: the tables are empty until the saga code ships, and nothing reads the view until the
-- Booking / TripPlanner erasure code is deployed (each feature-detects it: 42P01 / 42501 = not served yet).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no '-- migrate:' directive): a view in the catalog schema under the
-- catalog.* recipe (role switch, GRANT / REVOKE CREATE ON SCHEMA catalog). MIG-4: migration-only PR with 408 / 409;
-- applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a). DM-7.1: a view, no new table.
--
-- Guards (RAISE rolls the whole file back): before — 408 registered, schema catalog owned by cis_owner. After, as
-- catalog_owner — the view answers. After, as cis_owner — the exact columns, owner catalog_owner, security_barrier,
-- booking and tripplanner can read it, aa_app_user / cis_app / crm_app cannot, catalog_owner has no table-level SELECT
-- and no write on the two tables, and no CREATE on schema catalog.
--
-- Recipe. The X1 S22 catalog recipe (as 357 / 377 / 401): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL
-- ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate / Migration Apply runs the file
-- as cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL, no dynamic SQL. The conftest
-- replay skips this file (catalog recipe, 245's owners); tests/integration/test_aa1093_migration_408_410.py applies it
-- the DB Migrate way and undoes it.
--
-- Number. 408 is this wave's first file; if the owner main max + 1 differs at merge, renumber (git grep '410_' and
-- '410' here, in the test and conftest).
--
-- Locks. Column GRANTs on two empty tables and one CREATE OR REPLACE VIEW. lock_timeout 5s, statement_timeout 1min.
-- Idempotent, one transaction, self-registering.
--
-- Rollback (a new forward migration under the same recipe, after the consumers stop reading it): DROP VIEW
-- catalog.v_tenant_erasure_v1, then REVOKE the column grants from catalog_owner.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '408') THEN
        RAISE EXCEPTION 'migration 410: apply 408 (shared.tenant_erasure_request / _step) first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 410: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read ───────────────────────────────────────────────────────────────────────────────
GRANT SELECT (request_id, tenant_id, phase, round, opened_at, approval_expires_at, is_pilot, is_synthetic,
              not_before_booking, not_before_tripplanner, round_apps, done_apps, updated_at)
    ON shared.tenant_erasure_request TO catalog_owner;
GRANT SELECT (request_id, round, app, mode, status, approved_plan_hash) ON shared.tenant_erasure_step TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 2. The view ──────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tenant_erasure_v1 WITH (security_barrier = true) AS
SELECT r.request_id,
       r.tenant_id,
       r.phase,
       r.round,
       r.opened_at,
       r.approval_expires_at,
       r.is_pilot,
       r.is_synthetic,
       a.app,
       CASE
           WHEN a.app = ANY (r.done_apps) THEN 'done'
           WHEN a.app = ANY (r.round_apps) AND EXISTS (
                    SELECT 1 FROM shared.tenant_erasure_step f
                     WHERE f.request_id = r.request_id AND f.round = r.round AND f.app = a.app
                       AND f.status IN ('blocked', 'refused', 'failed')) THEN 'failed'
           WHEN a.app = ANY (r.round_apps) THEN 'active'
           ELSE 'waiting'
       END AS step_status,
       CASE a.app WHEN 'booking' THEN r.not_before_booking ELSE r.not_before_tripplanner END AS not_before,
       CASE WHEN r.phase IN ('apply', 'verify') THEN s.approved_plan_hash END AS approved_plan_hash,
       r.updated_at
  FROM shared.tenant_erasure_request r
 CROSS JOIN (VALUES ('booking'::text), ('tripplanner'::text)) AS a(app)
  LEFT JOIN shared.tenant_erasure_step s
         ON s.request_id = r.request_id AND s.round = r.round AND s.app = a.app AND s.mode = 'dry_run';

COMMENT ON VIEW catalog.v_tenant_erasure_v1 IS
    'AA-1093 (410, contract tenant.erasure.v1 1.0, root ADR 0019 d1): the tenant erasure requests of the CIS offboarding '
    'saga (ErasureRequestRow), one row per request and consuming app (booking, tripplanner): phase, round, T0, the '
    'approval expiry, is_pilot / is_synthetic as copied at T0, the app''s step status and not_before, its approved plan '
    'hash (current round, phase apply / verify). No personal data. Booking and TripPlanner only. Contract v1: columns '
    'are only appended.';

GRANT SELECT ON catalog.v_tenant_erasure_v1 TO booking, tripplanner;

-- ── Closing check as catalog_owner: the view answers ─────────────────────────────────────────────────────────────
DO $$
BEGIN
    RAISE NOTICE 'migration 410: as catalog_owner, % request row(s)', (SELECT count(*) FROM catalog.v_tenant_erasure_v1);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner ───────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_tenant_erasure_v1';
    r text;
    t text;
    cols text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 410: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 410: % is not security_barrier', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['booking', 'tripplanner'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND NOT pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 410: % cannot read %', r, v;
        END IF;
    END LOOP;
    FOREACH r IN ARRAY ARRAY['aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 410: % can read % (booking and tripplanner only)', r, v;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM
       'request_id,tenant_id,phase,round,opened_at,approval_expires_at,is_pilot,is_synthetic,app,step_status,'
       'not_before,approved_plan_hash,updated_at'
    THEN
        RAISE EXCEPTION 'migration 410: % columns are %', v, cols;
    END IF;
    FOREACH t IN ARRAY ARRAY['shared.tenant_erasure_request', 'shared.tenant_erasure_step'] LOOP
        IF pg_catalog.has_table_privilege('catalog_owner', t, 'SELECT')
           OR pg_catalog.has_any_column_privilege('catalog_owner', t, 'INSERT')
           OR pg_catalog.has_any_column_privilege('catalog_owner', t, 'UPDATE') THEN
            RAISE EXCEPTION 'migration 410: catalog_owner holds more than column SELECT on %', t;
        END IF;
    END LOOP;
    IF pg_catalog.has_column_privilege('catalog_owner', 'shared.tenant_erasure_request', 'approved_by', 'SELECT') THEN
        RAISE EXCEPTION 'migration 410: catalog_owner reads the approver';
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 410: catalog_owner kept CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('410', now(), 'AA-1093: catalog.v_tenant_erasure_v1 (contract tenant.erasure.v1, Booking + TripPlanner)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
