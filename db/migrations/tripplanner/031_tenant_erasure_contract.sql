-- Migration tp-031: AA-1093 (lane L4 follow-up) — the TripPlanner erasure log, erase function and report view brought
-- to the contract tenant.erasure.v1 (root docs/contracts/tenant.erasure.v1.openapi.yaml, ErasureReportRow).
--
-- Class: contract (root ADR 0017 / 0017a). No directive line on purpose: it reshapes an existing table (renames,
-- constraints, primary key) inside a re-runnable DO block, replaces a function with a new signature and a view with
-- new columns, and changes grants. Merge order MIG-4: this migration-only PR first; the TripPlanner code PR (jobs
-- tp_tenant_erase speaking the contract) follows once this file is applied on Dev. On Dev, AA-CIS-Infra Migration
-- Apply runs it in contract mode once every job table is idle (byte-identical copy
-- db/migrations/tripplanner/031_tenant_erasure_contract.sql), as tp_owner, the live owner of schema tripplanner since
-- tp-013 (XD8). Never run it from a laptop.
--
-- Why: tp-030 (applied on Dev) and the jobs code were built before the contract landed on the root repo. tp-030 keeps
-- one upserted row per (request_id, mode) with statuses planned | applied | verified | residue | refused and a counts
-- object; the contract wants an APPEND-ONLY log, one row per report (CIS keeps the newest per (app, round, mode)),
-- statuses ok | blocked | refused | failed with an error code, a round, the plan hash of the contract formula, tables as
-- a list of {table, action, rows, digest}, blockers and a verify census. Booking's bk-057 is the same shape.
--
-- What:
--   1. guards: runs as tp_owner; tp-030's log, function and view exist; the log holds no row of an erasure that ran
--      (tp-030 status applied, verified or residue): such a row would have to be carried over by hand, so the file
--      refuses (and nothing changes) rather than guessing.
--   2. tripplanner.tenant_erasure_log reshaped IN PLACE (no DROP TABLE, no DELETE: contract, not destructive), only
--      while it still has the tp-030 shape (column counts), so a re-run changes nothing:
--        - primary key (request_id, mode) -> report_id uuid DEFAULT gen_random_uuid();
--        - renames: reason -> error_code, counts -> tables, created_at -> reported_at (DEFAULT clock_timestamp()),
--          updated_at -> legacy_updated_at (nullable, no default: the upsert time of a tp-030 row, NULL on every report
--          written since; a later destructive file drops it once the tp-030 rows are reviewed);
--        - new: app ('tripplanner'), round (>= 1), blockers (jsonb array), census (jsonb, verify only), source
--          (cis = a request of catalog.v_tenant_erasure_v1, operator = an operator's enqueue / drill, tp030 = a row
--          written before this file);
--        - the tp-030 rows (only DRY RUNs and refusals, guard 1) are carried over, never deleted: report_id new,
--          round 1, source tp030, status planned -> ok (refused stays, its reason becomes the error code), the counts
--          object -> a tables list (digest NULL: tp-030 kept sha256 fingerprints, not the contract md5 digests; action
--          merge_into_app -> merge), plan_hash kept on a DRY RUN (the tp-030 formula), NULL on a verification;
--        - CHECKs as the contract (and bk-057): app, round, mode, status, error_code NULL exactly when ok and shaped
--          like a code, plan_hash 64 hex / NULL on verify / set on an ok DRY RUN or apply, tables and blockers arrays
--          (at most 500 / 50), census only on verify and set on an ok one, source.
--      Row-level security ENABLE + FORCE and its two tp-030 policies stay as they are. The runtime role keeps SELECT
--      and INSERT; UPDATE is revoked (append-only; DELETE was never granted). Index (request_id, round, mode,
--      reported_at DESC) for the newest report of a request and round.
--   3. tripplanner.erase_tenant(p_tenant uuid, p_round integer, p_dry_run boolean, p_expect_plan text DEFAULT NULL)
--      replaces tp-030's (uuid, boolean, text): DROP FUNCTION IF EXISTS of the old signature, then CREATE OR REPLACE.
--      Unchanged from tp-030: SECURITY INVOKER (MIG-6), search_path and the five session settings pinned, only under
--      the jobs system scope with no tenant bound (else 42501), an apply needs the expected plan (22023) and locks the
--      six tables IN EXCLUSIVE MODE, plan_changed when the recomputed hash differs (nothing deleted), deletes children
--      first, each must remove exactly the planned rows (else 40001, rolled back), the customers only this tenant's
--      sessions link are deleted, the spend rows are merged into the app scope. Changed to the contract:
--        tables: a list sorted by table of {table, action, rows, digest}; actions delete (sessions, trip_drafts,
--          trip_events, outbox, customers), merge (ai_spend_month scope 'tenant:<id>') and keep (traveller_accounts,
--          count only, digest NULL);
--        digest: md5 hex of the sorted (COLLATE "C") lines '<primary key>|<row version>' joined by a newline; row
--          version = updated_at as UTC ISO 8601 with microseconds ('YYYY-MM-DD"T"HH24:MI:SS.US"Z"', as bk-057), empty
--          for a table without updated_at (sessions, trip_events, outbox, customers); the primary key of
--          ai_spend_month is 'stage,scope,month' (month as YYYY-MM-DD); md5('') for no row;
--        plan_hash: sha256 hex of 'tenant.erasure.v1|<tenant>|<round>' followed by one line per entry
--          '<table>|<action>|<rows>|<digest or empty>' sorted (COLLATE "C"), all joined by a newline, so a plan binds
--          the tenant and the round;
--        returns {format, tenant_id, round, dry_run, status ok | refused, error_code NULL | plan_changed, plan_hash,
--          tables, app_rows_added}; on an apply ok the rows of each delete / merge entry are the rows it removed.
--      EXECUTE to tripplanner only (PUBLIC revoked). The log row is the caller's (same transaction).
--   4. tripplanner.v_tenant_erasure_report_v1 recreated with the exact contract column order: report_id, request_id,
--      tenant_id, app, round, mode, status, error_code, plan_hash, tables, blockers, census, job_id, reported_at, over
--      the log rows of source cis and operator (the tp030 rows are not contract reports). The old view is dropped
--      first only while its columns are not these (CREATE OR REPLACE cannot rename columns), so a re-run changes
--      nothing. Owner view (no security_invoker: the log's FORCE RLS keeps cis_app, which binds no TripPlanner
--      tenant, at every row through the owner policy); SELECT to cis_app only, ALL revoked from tripplanner.
--   5. comments; post-checks (view columns in contract order, grants, function, constraints, policies); registration.
--
-- Deployed code between this apply and the code PR's deploy: the jobs code of tp-030 calls the old function and
-- writes the old columns. Its daily tick answers no_feed while catalog.v_tenant_erasure_v1 does not exist (the CIS
-- saga migration), so nothing calls them; an operator erase drill in that window fails (no data is touched).
-- Locks: ACCESS EXCLUSIVE on tripplanner.tenant_erasure_log for the reshape (a handful of rows, an instant); none on
-- the tenant tables (the function's locks are taken when it runs, in apply mode only). lock_timeout 5s.
-- Re-runnable (test_replay_twice_pg.py): the reshape runs only on the tp-030 shape, constraints and the index are
-- created only when missing, the view is dropped only when its columns differ, CREATE OR REPLACE on the function,
-- repeated grants / revokes / comments, ON CONFLICT DO NOTHING. tp-030 itself can no longer be re-run on this state
-- (its view names tp-030 columns): test_replay_twice_pg.py lists it in SUPERSEDED_BY_DROP.
-- Undo: a later tp- file, after the code PR is reverted: the tp-030 function and view back (contract); the log keeps
-- its rows (erasure evidence, data standards DM-7.1 row tripplanner.tenant_erasure_log).

BEGIN;

SET LOCAL lock_timeout = '5s';

-- 1. guards before any change

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-031: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
    IF to_regclass('tripplanner.tenant_erasure_log') IS NULL
       OR to_regclass('tripplanner.v_tenant_erasure_report_v1') IS NULL THEN
        RAISE EXCEPTION 'tp-031: tp-030 (tripplanner.tenant_erasure_log and its report view) is not applied';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'tripplanner.tenant_erasure_log'::regclass
                                            AND attname = 'counts' AND NOT attisdropped) THEN
        IF EXISTS (SELECT 1 FROM tripplanner.tenant_erasure_log WHERE status IN ('applied', 'verified', 'residue')) THEN
            RAISE EXCEPTION 'tp-031: tripplanner.tenant_erasure_log holds a tp-030 row of an erasure that ran (status '
                            'applied, verified or residue): carry it over by hand before this file, it is never guessed';
        END IF;
    END IF;
END $$;

-- 2. the log, reshaped in place while it still has the tp-030 shape

DO $$
DECLARE
    v_scope text;
    v_rows  bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'tripplanner.tenant_erasure_log'::regclass
                                                AND attname = 'counts' AND NOT attisdropped) THEN
        RETURN;                                   -- already reshaped (a re-run)
    END IF;

    ALTER TABLE tripplanner.tenant_erasure_log DROP CONSTRAINT tenant_erasure_log_pkey;
    ALTER TABLE tripplanner.tenant_erasure_log DROP CONSTRAINT IF EXISTS tenant_erasure_log_status_chk;
    ALTER TABLE tripplanner.tenant_erasure_log DROP CONSTRAINT IF EXISTS tenant_erasure_log_reason_chk;
    ALTER TABLE tripplanner.tenant_erasure_log DROP CONSTRAINT IF EXISTS tenant_erasure_log_reason_shape_chk;
    ALTER TABLE tripplanner.tenant_erasure_log DROP CONSTRAINT IF EXISTS tenant_erasure_log_plan_hash_chk;
    ALTER TABLE tripplanner.tenant_erasure_log DROP CONSTRAINT IF EXISTS tenant_erasure_log_counts_chk;

    ALTER TABLE tripplanner.tenant_erasure_log RENAME COLUMN reason TO error_code;
    ALTER TABLE tripplanner.tenant_erasure_log RENAME COLUMN counts TO tables;
    ALTER TABLE tripplanner.tenant_erasure_log RENAME COLUMN created_at TO reported_at;
    ALTER TABLE tripplanner.tenant_erasure_log RENAME COLUMN updated_at TO legacy_updated_at;

    ALTER TABLE tripplanner.tenant_erasure_log
        ADD COLUMN report_id uuid,
        ADD COLUMN app       text,
        ADD COLUMN round     integer,
        ADD COLUMN blockers  jsonb,
        ADD COLUMN census    jsonb,
        ADD COLUMN source    text;

    -- the tp-030 rows (DRY RUNs and refusals only, guard 1): carried over, never deleted. FORCE row-level security
    -- applies to tp_owner too: its write policy (tenant_erasure_log_system) needs the system scope, opened for this
    -- statement only and closed again right after (the previous value restored).
    v_scope := current_setting('app.tenant_scope', true);
    PERFORM set_config('app.tenant_scope', 'system', true);
    UPDATE tripplanner.tenant_erasure_log l
       SET report_id = gen_random_uuid(),
           app       = 'tripplanner',
           round     = 1,
           source    = 'tp030',
           status    = CASE WHEN l.status = 'planned' THEN 'ok' ELSE l.status END,
           plan_hash = CASE WHEN l.mode = 'verify' THEN NULL ELSE l.plan_hash END,
           blockers  = '[]'::jsonb,
           tables    = coalesce((
               SELECT jsonb_agg(jsonb_build_object(
                          'table', e.key,
                          'action', CASE WHEN e.value ->> 'action' = 'merge_into_app' THEN 'merge'
                                         ELSE e.value ->> 'action' END,
                          'rows', coalesce((e.value ->> 'rows')::bigint, 0),
                          'digest', NULL) ORDER BY e.key)
                 FROM jsonb_each(CASE WHEN jsonb_typeof(l.tables -> 'tables') = 'object' THEN l.tables -> 'tables'
                                      ELSE '{}'::jsonb END) e), '[]'::jsonb);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM set_config('app.tenant_scope', coalesce(v_scope, ''), true);
    IF v_rows <> (SELECT count(*) FROM tripplanner.tenant_erasure_log) THEN
        RAISE EXCEPTION 'tp-031: % of % tp-030 rows carried over', v_rows, (SELECT count(*) FROM tripplanner.tenant_erasure_log);
    END IF;

    ALTER TABLE tripplanner.tenant_erasure_log
        ALTER COLUMN report_id SET DEFAULT gen_random_uuid(),
        ALTER COLUMN report_id SET NOT NULL,
        ALTER COLUMN app SET DEFAULT 'tripplanner',
        ALTER COLUMN app SET NOT NULL,
        ALTER COLUMN round SET NOT NULL,
        ALTER COLUMN blockers SET DEFAULT '[]'::jsonb,
        ALTER COLUMN blockers SET NOT NULL,
        ALTER COLUMN tables SET DEFAULT '[]'::jsonb,
        ALTER COLUMN source SET NOT NULL,
        ALTER COLUMN reported_at SET DEFAULT clock_timestamp(),
        ALTER COLUMN legacy_updated_at DROP DEFAULT,
        ALTER COLUMN legacy_updated_at DROP NOT NULL;

    ALTER TABLE tripplanner.tenant_erasure_log ADD CONSTRAINT tenant_erasure_log_pkey PRIMARY KEY (report_id);
    ALTER TABLE tripplanner.tenant_erasure_log
        ADD CONSTRAINT tenant_erasure_log_app_chk CHECK (app = 'tripplanner'),
        ADD CONSTRAINT tenant_erasure_log_round_chk CHECK (round >= 1),
        ADD CONSTRAINT tenant_erasure_log_status_chk CHECK (status IN ('ok', 'blocked', 'refused', 'failed')),
        ADD CONSTRAINT tenant_erasure_log_code_chk CHECK (
            (status = 'ok') = (error_code IS NULL)
            AND (error_code IS NULL OR error_code ~ '^[a-z][a-z0-9_]{1,63}$')),
        ADD CONSTRAINT tenant_erasure_log_hash_chk CHECK (
            (plan_hash IS NULL OR plan_hash ~ '^[0-9a-f]{64}$')
            AND (mode <> 'verify' OR plan_hash IS NULL)
            AND (mode = 'verify' OR status <> 'ok' OR plan_hash IS NOT NULL)),
        ADD CONSTRAINT tenant_erasure_log_json_chk CHECK (
            jsonb_typeof(tables) = 'array' AND jsonb_typeof(blockers) = 'array'
            AND jsonb_array_length(tables) <= 500 AND jsonb_array_length(blockers) <= 50),
        ADD CONSTRAINT tenant_erasure_log_census_chk CHECK (
            (census IS NULL OR (mode = 'verify' AND jsonb_typeof(census) = 'object'))
            AND (mode <> 'verify' OR status <> 'ok' OR census IS NOT NULL)),
        ADD CONSTRAINT tenant_erasure_log_source_chk CHECK (source IN ('cis', 'operator', 'tp030'));
END $$;

CREATE INDEX IF NOT EXISTS tenant_erasure_log_request_idx
    ON tripplanner.tenant_erasure_log (request_id, round, mode, reported_at DESC);

REVOKE UPDATE, DELETE, TRUNCATE ON tripplanner.tenant_erasure_log FROM tripplanner;
GRANT SELECT, INSERT ON tripplanner.tenant_erasure_log TO tripplanner;

-- 3. the erase function, contract shaped

DROP FUNCTION IF EXISTS tripplanner.erase_tenant(uuid, boolean, text);

CREATE OR REPLACE FUNCTION tripplanner.erase_tenant(p_tenant uuid, p_round integer, p_dry_run boolean,
                                                    p_expect_plan text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'UTC'
SET DateStyle = 'ISO, YMD'
SET IntervalStyle = 'postgres'
SET extra_float_digits = 3
SET bytea_output = 'hex'
AS $fn$
DECLARE
    v_scope     text := 'tenant:' || p_tenant::text;
    v_ts        constant text := 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"';
    v_tables    jsonb := '[]'::jsonb;
    v_plan      text;
    v_n         bigint;
    v_digest    text;
    v_done      bigint;
    v_app_rows  bigint := 0;
    v_deleted   jsonb := '{}'::jsonb;
    v_customers uuid[];
BEGIN
    IF p_tenant IS NULL OR p_round IS NULL OR p_dry_run IS NULL THEN
        RAISE EXCEPTION 'tp-031 erase_tenant: tenant, round and dry_run are required' USING ERRCODE = '22004';
    END IF;
    IF p_round < 1 THEN
        RAISE EXCEPTION 'tp-031 erase_tenant: the round starts at 1' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(current_setting('app.tenant_scope', true), '') IS DISTINCT FROM 'system'
       OR NULLIF(current_setting('app.tenant_id', true), '') IS NOT NULL THEN
        RAISE EXCEPTION 'tp-031 erase_tenant: runs only under the jobs system scope, with no tenant bound'
            USING ERRCODE = '42501';
    END IF;
    IF NOT p_dry_run THEN
        IF p_expect_plan IS NULL OR p_expect_plan !~ '^[0-9a-f]{64}$' THEN
            RAISE EXCEPTION 'tp-031 erase_tenant: an apply needs the approved plan hash (64 hex)' USING ERRCODE = '22023';
        END IF;
        LOCK TABLE tripplanner.trip_events, tripplanner.trip_drafts, tripplanner.outbox, tripplanner.sessions,
                   tripplanner.customers, tripplanner.ai_spend_month IN EXCLUSIVE MODE;
    END IF;

    -- the plan: per table the action, the row count and the contract digest (never a row value)
    SELECT count(*), md5(coalesce(string_agg(t.id::text || '|', E'\n' ORDER BY t.id::text || '|' COLLATE "C"), ''))
      INTO v_n, v_digest FROM tripplanner.sessions t WHERE t.tenant_id = p_tenant;
    v_tables := v_tables || jsonb_build_object('table', 'tripplanner.sessions', 'action', 'delete', 'rows', v_n,
                                               'digest', v_digest);
    SELECT count(*), md5(coalesce(string_agg(t.id::text || '|' || to_char(t.updated_at AT TIME ZONE 'UTC', v_ts),
                                             E'\n' ORDER BY t.id::text || '|' || to_char(t.updated_at AT TIME ZONE 'UTC',
                                                                                         v_ts) COLLATE "C"), ''))
      INTO v_n, v_digest FROM tripplanner.trip_drafts t WHERE t.tenant_id = p_tenant;
    v_tables := v_tables || jsonb_build_object('table', 'tripplanner.trip_drafts', 'action', 'delete', 'rows', v_n,
                                               'digest', v_digest);
    SELECT count(*), md5(coalesce(string_agg(t.id::text || '|', E'\n' ORDER BY t.id::text || '|' COLLATE "C"), ''))
      INTO v_n, v_digest FROM tripplanner.trip_events t WHERE t.tenant_id = p_tenant;
    v_tables := v_tables || jsonb_build_object('table', 'tripplanner.trip_events', 'action', 'delete', 'rows', v_n,
                                               'digest', v_digest);
    SELECT count(*), md5(coalesce(string_agg(t.id::text || '|', E'\n' ORDER BY t.id::text || '|' COLLATE "C"), ''))
      INTO v_n, v_digest FROM tripplanner.outbox t WHERE t.tenant_id = p_tenant;
    v_tables := v_tables || jsonb_build_object('table', 'tripplanner.outbox', 'action', 'delete', 'rows', v_n,
                                               'digest', v_digest);
    SELECT count(*),
           md5(coalesce(string_agg(t.stage || ',' || t.scope || ',' || to_char(t.month, 'YYYY-MM-DD') || '|'
                                   || to_char(t.updated_at AT TIME ZONE 'UTC', v_ts),
                                   E'\n' ORDER BY t.stage || ',' || t.scope || ',' || to_char(t.month, 'YYYY-MM-DD')
                                                  || '|' || to_char(t.updated_at AT TIME ZONE 'UTC', v_ts) COLLATE "C"),
                        ''))
      INTO v_n, v_digest FROM tripplanner.ai_spend_month t WHERE t.scope = v_scope;
    v_tables := v_tables || jsonb_build_object('table', 'tripplanner.ai_spend_month', 'action', 'merge', 'rows', v_n,
                                               'digest', v_digest);
    -- customers only this tenant's sessions link (no session of another tenant): deleted after the sessions
    SELECT coalesce(array_agg(c.id ORDER BY c.id), '{}'::uuid[]), count(*),
           md5(coalesce(string_agg(c.id::text || '|', E'\n' ORDER BY c.id::text || '|' COLLATE "C"), ''))
      INTO v_customers, v_n, v_digest
      FROM tripplanner.customers c
     WHERE c.id IN (SELECT s.customer_id FROM tripplanner.sessions s WHERE s.tenant_id = p_tenant)
       AND NOT EXISTS (SELECT 1 FROM tripplanner.sessions o WHERE o.customer_id = c.id AND o.tenant_id <> p_tenant);
    v_tables := v_tables || jsonb_build_object('table', 'tripplanner.customers', 'action', 'delete', 'rows', v_n,
                                               'digest', v_digest);
    SELECT count(*) INTO v_n FROM tripplanner.traveller_accounts a
     WHERE a.id IN (SELECT s.account_id FROM tripplanner.sessions s WHERE s.tenant_id = p_tenant);
    v_tables := v_tables || jsonb_build_object('table', 'tripplanner.traveller_accounts', 'action', 'keep', 'rows', v_n,
                                               'digest', NULL);

    SELECT jsonb_agg(e.value ORDER BY e.value ->> 'table' COLLATE "C") INTO v_tables
      FROM jsonb_array_elements(v_tables) e;
    SELECT encode(sha256(convert_to(
               'tenant.erasure.v1|' || p_tenant::text || '|' || p_round::text || E'\n'
               || string_agg((e.value ->> 'table') || '|' || (e.value ->> 'action') || '|' || (e.value ->> 'rows') || '|'
                             || coalesce(e.value ->> 'digest', ''),
                             E'\n' ORDER BY (e.value ->> 'table') || '|' || (e.value ->> 'action') || '|'
                                            || (e.value ->> 'rows') || '|' || coalesce(e.value ->> 'digest', '')
                                            COLLATE "C"),
               'UTF8')), 'hex')
      INTO v_plan FROM jsonb_array_elements(v_tables) e;

    IF p_dry_run THEN
        RETURN jsonb_build_object('format', 'tenant.erasure.v1', 'tenant_id', p_tenant, 'round', p_round,
                                  'dry_run', true, 'status', 'ok', 'error_code', NULL, 'plan_hash', v_plan,
                                  'tables', v_tables, 'app_rows_added', 0);
    END IF;
    IF v_plan <> p_expect_plan THEN
        RETURN jsonb_build_object('format', 'tenant.erasure.v1', 'tenant_id', p_tenant, 'round', p_round,
                                  'dry_run', false, 'status', 'refused', 'error_code', 'plan_changed',
                                  'plan_hash', v_plan, 'tables', v_tables, 'app_rows_added', 0);
    END IF;

    -- the apply: children first, each delete must remove exactly the planned rows (the tables are locked)
    DELETE FROM tripplanner.trip_events t WHERE t.tenant_id = p_tenant;
    GET DIAGNOSTICS v_done = ROW_COUNT;
    v_deleted := v_deleted || jsonb_build_object('tripplanner.trip_events', v_done);
    DELETE FROM tripplanner.trip_drafts t WHERE t.tenant_id = p_tenant;
    GET DIAGNOSTICS v_done = ROW_COUNT;
    v_deleted := v_deleted || jsonb_build_object('tripplanner.trip_drafts', v_done);
    DELETE FROM tripplanner.outbox t WHERE t.tenant_id = p_tenant;
    GET DIAGNOSTICS v_done = ROW_COUNT;
    v_deleted := v_deleted || jsonb_build_object('tripplanner.outbox', v_done);
    DELETE FROM tripplanner.sessions t WHERE t.tenant_id = p_tenant;
    GET DIAGNOSTICS v_done = ROW_COUNT;
    v_deleted := v_deleted || jsonb_build_object('tripplanner.sessions', v_done);
    DELETE FROM tripplanner.customers c WHERE c.id = ANY (v_customers);
    GET DIAGNOSTICS v_done = ROW_COUNT;
    v_deleted := v_deleted || jsonb_build_object('tripplanner.customers', v_done);

    INSERT INTO tripplanner.ai_spend_month (stage, scope, month, cost_usd, calls, updated_at)
    SELECT t.stage, 'app', t.month, t.cost_usd, t.calls, now()
      FROM tripplanner.ai_spend_month t WHERE t.scope = v_scope
    ON CONFLICT (stage, scope, month) DO NOTHING;
    GET DIAGNOSTICS v_app_rows = ROW_COUNT;
    DELETE FROM tripplanner.ai_spend_month t WHERE t.scope = v_scope;
    GET DIAGNOSTICS v_done = ROW_COUNT;
    v_deleted := v_deleted || jsonb_build_object('tripplanner.ai_spend_month', v_done);

    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_tables) e
                WHERE v_deleted ? (e.value ->> 'table')
                  AND (v_deleted ->> (e.value ->> 'table'))::bigint <> (e.value ->> 'rows')::bigint) THEN
        RAISE EXCEPTION 'tp-031 erase_tenant: deleted counts differ from the plan (rolled back)' USING ERRCODE = '40001';
    END IF;

    RETURN jsonb_build_object('format', 'tenant.erasure.v1', 'tenant_id', p_tenant, 'round', p_round,
                              'dry_run', false, 'status', 'ok', 'error_code', NULL, 'plan_hash', v_plan,
                              'tables', v_tables, 'app_rows_added', v_app_rows);
END
$fn$;

REVOKE ALL ON FUNCTION tripplanner.erase_tenant(uuid, integer, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tripplanner.erase_tenant(uuid, integer, boolean, text) TO tripplanner;

-- 4. the report view CIS reads, in the contract column order (ids, codes, counts and hashes only)

DO $$
BEGIN
    IF (SELECT array_agg(a.attname::text ORDER BY a.attnum) FROM pg_attribute a
         WHERE a.attrelid = 'tripplanner.v_tenant_erasure_report_v1'::regclass AND a.attnum > 0 AND NOT a.attisdropped)
       IS DISTINCT FROM ARRAY['report_id', 'request_id', 'tenant_id', 'app', 'round', 'mode', 'status', 'error_code',
                              'plan_hash', 'tables', 'blockers', 'census', 'job_id', 'reported_at'] THEN
        DROP VIEW tripplanner.v_tenant_erasure_report_v1;    -- tp-030's columns: CREATE OR REPLACE cannot rename them
    END IF;
END $$;

CREATE OR REPLACE VIEW tripplanner.v_tenant_erasure_report_v1 AS
SELECT l.report_id, l.request_id, l.tenant_id, l.app, l.round, l.mode, l.status, l.error_code, l.plan_hash, l.tables,
       l.blockers, l.census, l.job_id, l.reported_at
  FROM tripplanner.tenant_erasure_log l
 WHERE l.source <> 'tp030';

REVOKE ALL ON tripplanner.v_tenant_erasure_report_v1 FROM tripplanner;
GRANT SELECT ON tripplanner.v_tenant_erasure_report_v1 TO cis_app;

-- 5. comments

COMMENT ON TABLE tripplanner.tenant_erasure_log IS
    'tp-031 (AA-1093, contract tenant.erasure.v1 ErasureReportRow): APPEND-ONLY, one row per DRY RUN, apply or verification of the TripPlanner part of the tenant offboarding saga (job tp_tenant_erase): round, mode, status ok | blocked | refused | failed, error code, plan hash, tables {table, action, rows, digest}, blockers, census. Ids, codes, counts and hashes only, no personal data. Written by the jobs Lambda under the system scope; the runtime role inserts and reads, never updates or deletes (retention: data standards DM-7.1).';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.report_id IS
    'tp-031: the report id (contract ErasureReport.report_id, unique per app).';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.request_id IS
    'tp-030: the erasure request (CIS catalog.v_tenant_erasure_v1 request id, or a UUIDv5 of the tenant for an operator run).';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.tenant_id IS
    'tp-030: the erased tenant, soft key to shared.tenants.tenant_id (no FK, another owner). Not personal data.';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.round IS
    'tp-031: the saga round the report answers (CIS ignores a report of an older round).';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.error_code IS
    'tp-031: a code (plan_changed, approval_expired, approval_missing, dry_run_missing, pilot_refused, aa_hosted_refused, not_synthetic, apply_disabled, tenant_markers_unknown, census_not_zero, census_incomplete, internal_error, ...), never free text; NULL exactly when the status is ok.';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.plan_hash IS
    'tp-031: sha256 hex of ''tenant.erasure.v1|<tenant>|<round>'' and the sorted ''<table>|<action>|<rows>|<digest>'' lines (contract tenant.erasure.v1); NULL on verify. A tp030 row keeps the tp-030 formula.';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.tables IS
    'tp-031: contract TableEntry list {table, action, rows, digest}; digest = md5 of the sorted ''<primary key>|<updated_at UTC or empty>'' lines. No row value.';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.blockers IS
    'tp-031: contract Blocker list {code, count}.';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.census IS
    'tp-031: verify only, contract Census {pii_columns_checked, pii_rows_found}.';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.source IS
    'tp-031: cis = a request of catalog.v_tenant_erasure_v1; operator = an operator enqueue (drill); tp030 = a row written before tp-031 (not a contract report, left out of the report view).';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.reported_at IS
    'tp-031: when the report was written (contract ErasureReport.reported_at).';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.legacy_updated_at IS
    'tp-031: the upsert time of a tp030 row; NULL on every report since tp-031. Dropped by a later destructive file.';
COMMENT ON FUNCTION tripplanner.erase_tenant(uuid, integer, boolean, text) IS
    'tp-031 (AA-1093, contract tenant.erasure.v1): DRY RUN plan (dry_run true) or apply (dry_run false, expect_plan = the approved plan hash of this round; another hash = refused plan_changed) of a tenant erasure: deletes the tenant''s sessions, trip_drafts, trip_events, outbox rows and the customers no other tenant''s session links, and merges its ai_spend_month rows into the app scope. Tables as contract entries (md5 digests), plan hash bound to the tenant and the round. SECURITY INVOKER; session settings pinned; only under the jobs system scope with no tenant bound (else 42501).';
COMMENT ON VIEW tripplanner.v_tenant_erasure_report_v1 IS
    'tp-031 (AA-1093, contract tenant.erasure.v1 ErasureReportRow, exact column order): the TripPlanner erasure reports for the CIS tenant_erasure_saga, one row per report (append-only log); CIS keeps the newest of each (app, round, mode). Ids, codes, counts and hashes only. SELECT to cis_app only. Columns are only appended.';

-- 6. post-checks

DO $$
BEGIN
    IF (SELECT array_agg(a.attname::text ORDER BY a.attnum) FROM pg_attribute a
         WHERE a.attrelid = 'tripplanner.v_tenant_erasure_report_v1'::regclass AND a.attnum > 0 AND NOT a.attisdropped)
       IS DISTINCT FROM ARRAY['report_id', 'request_id', 'tenant_id', 'app', 'round', 'mode', 'status', 'error_code',
                              'plan_hash', 'tables', 'blockers', 'census', 'job_id', 'reported_at'] THEN
        RAISE EXCEPTION 'tp-031: tripplanner.v_tenant_erasure_report_v1 columns are not the contract ErasureReportRow order';
    END IF;
    IF (SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
         WHERE c.conrelid = 'tripplanner.tenant_erasure_log'::regclass AND c.conname = 'tenant_erasure_log_pkey')
       IS DISTINCT FROM 'PRIMARY KEY (report_id)' THEN
        RAISE EXCEPTION 'tp-031: tripplanner.tenant_erasure_log must be keyed by report_id';
    END IF;
    IF (SELECT count(*) FROM pg_constraint c WHERE c.conrelid = 'tripplanner.tenant_erasure_log'::regclass
          AND c.conname IN ('tenant_erasure_log_app_chk', 'tenant_erasure_log_round_chk', 'tenant_erasure_log_mode_chk',
                            'tenant_erasure_log_status_chk', 'tenant_erasure_log_code_chk', 'tenant_erasure_log_hash_chk',
                            'tenant_erasure_log_json_chk', 'tenant_erasure_log_census_chk',
                            'tenant_erasure_log_source_chk')) <> 9 THEN
        RAISE EXCEPTION 'tp-031: a contract CHECK of tripplanner.tenant_erasure_log is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = 'tripplanner.tenant_erasure_log'::regclass
                                             AND c.relrowsecurity AND c.relforcerowsecurity)
       OR (SELECT array_agg(p.policyname::text ORDER BY p.policyname) FROM pg_policies p
            WHERE p.schemaname = 'tripplanner' AND p.tablename = 'tenant_erasure_log')
          IS DISTINCT FROM ARRAY['tenant_erasure_log_owner_read', 'tenant_erasure_log_system'] THEN
        RAISE EXCEPTION 'tp-031: row-level security of tripplanner.tenant_erasure_log is not as tp-030 left it';
    END IF;
    IF has_table_privilege('tripplanner', 'tripplanner.tenant_erasure_log', 'UPDATE')
       OR has_table_privilege('tripplanner', 'tripplanner.tenant_erasure_log', 'DELETE')
       OR NOT has_table_privilege('tripplanner', 'tripplanner.tenant_erasure_log', 'INSERT')
       OR NOT has_table_privilege('tripplanner', 'tripplanner.tenant_erasure_log', 'SELECT')
       OR has_table_privilege('tripplanner', 'tripplanner.v_tenant_erasure_report_v1', 'SELECT')
       OR NOT has_table_privilege('cis_app', 'tripplanner.v_tenant_erasure_report_v1', 'SELECT')
       OR has_table_privilege('cis_app', 'tripplanner.tenant_erasure_log', 'SELECT') THEN
        RAISE EXCEPTION 'tp-031: unexpected grants on the erasure log or its report view';
    END IF;
    IF to_regprocedure('tripplanner.erase_tenant(uuid, boolean, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'tp-031: the tp-030 signature of tripplanner.erase_tenant is still there';
    END IF;
    IF NOT has_function_privilege('tripplanner', 'tripplanner.erase_tenant(uuid, integer, boolean, text)', 'EXECUTE')
       OR has_function_privilege('cis_app', 'tripplanner.erase_tenant(uuid, integer, boolean, text)', 'EXECUTE')
       OR (SELECT p.prosecdef FROM pg_proc p
            WHERE p.oid = 'tripplanner.erase_tenant(uuid, integer, boolean, text)'::regprocedure) THEN
        RAISE EXCEPTION 'tp-031: tripplanner.erase_tenant must be SECURITY INVOKER and executable by tripplanner only';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-031', now(), 'AA-1093: tripplanner.tenant_erasure_log append-only report shape, erase_tenant(tenant, round, '
                         'dry_run, expect_plan), v_tenant_erasure_report_v1 in the tenant.erasure.v1 column order')
ON CONFLICT (version) DO NOTHING;

COMMIT;
