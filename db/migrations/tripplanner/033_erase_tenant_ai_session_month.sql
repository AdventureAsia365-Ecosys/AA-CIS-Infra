-- Migration tp-033: AA-1116 (option B, review fix) — the tenant offboarding erase (tripplanner.erase_tenant, contract
-- tenant.erasure.v1, tp-031) also deletes the tenant's rows of tripplanner.ai_session_month (tp-032, the monthly AI
-- sessions quota), so no tenant-scoped row of TripPlanner stays behind an erasure.
--
-- Class: contract (root ADR 0017 / 0017a). No directive line on purpose: it replaces an existing function (same
-- signature, CREATE OR REPLACE) and grants DELETE on a table to the runtime role. Merge order MIG-4: this file ships
-- in the AA-1116 migration-only PR with tp-032 (one batch, tp-032 first); the TripPlanner code PR (the sessions quota,
-- and the jobs census naming the table) follows once both are applied on Dev. On Dev, AA-CIS-Infra Migration Apply
-- runs it in contract mode once every job table is idle (byte-identical copy
-- db/migrations/tripplanner/033_erase_tenant_ai_session_month.sql), as tp_owner, the live owner of schema tripplanner
-- since tp-013 (XD8). Never run it from a laptop.
--
-- Why: tp-032 adds a table keyed by scope 'tenant:<uuid>' (the tp-029 spelling, no tenant_id column). tp-031's
-- erase_tenant plans and applies sessions, trip_drafts, trip_events, outbox, customers (delete), ai_spend_month (merge
-- into the app scope) and traveller_accounts (keep); without this file an erased tenant would leave its
-- ai_session_month rows (its uuid in the scope, session ids, times) while the verification reports ok.
--
-- What (everything else of the function is tp-031's, unchanged):
--   1. guards: runs as tp_owner; tp-031 (the contract function) and tp-032 (the table) are applied.
--   2. tripplanner.erase_tenant(uuid, integer, boolean, text) replaced with one more plan entry
--        {table: tripplanner.ai_session_month, action: delete, rows, digest}: the rows of scope 'tenant:<id>', digest
--        md5 of the sorted (COLLATE "C") lines '<scope>,<month YYYY-MM-DD>,<session_id>|' (primary key, no updated_at:
--        empty row version, the contract rule); the apply locks the table IN EXCLUSIVE MODE with the six others and
--        deletes exactly the planned rows (else 40001, rolled back). Not merged into the app scope: the count is a
--        per-tenant quota, the app has none (the table's CHECK allows only tenant scopes).
--      A plan computed before this file has no ai_session_month entry, so its hash no longer matches: an approved
--      apply of such a plan is refused plan_changed (nothing deleted) and the saga plans again (a new DRY RUN).
--   3. GRANT DELETE ON tripplanner.ai_session_month TO tripplanner (the function is SECURITY INVOKER; the tp_owner
--      default privileges of tp-013 grant it already, stated here so the erase never depends on them); EXECUTE
--      stays tripplanner only (PUBLIC revoked).
--   4. the function comment; post-checks (SECURITY INVOKER, grants); registration.
--
-- Deployed code: the jobs Lambda (tp_tenant_erase) reads the function's tables list as data (verify sums the rows of
-- every non-keep entry), so the deployed code handles the new entry without a change; the code PR only names the table
-- in the census list. ai_session_month has no pii: column.
-- Locks: none at apply time beyond the function catalog row (the function's table locks are taken when it runs, in
-- apply mode only). lock_timeout 5s.
-- Re-runnable (test_replay_twice_pg.py): CREATE OR REPLACE, repeated grants / revokes / comment, ON CONFLICT DO NOTHING.
-- Undo: a later tp- file restating tp-031's function body (contract), after the readers no longer expect the entry.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- 1. guards before any change

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-033: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
    IF to_regprocedure('tripplanner.erase_tenant(uuid, integer, boolean, text)') IS NULL THEN
        RAISE EXCEPTION 'tp-033: tp-031 (tripplanner.erase_tenant(uuid, integer, boolean, text)) is not applied';
    END IF;
    IF to_regclass('tripplanner.ai_session_month') IS NULL THEN
        RAISE EXCEPTION 'tp-033: tp-032 (tripplanner.ai_session_month) is not applied';
    END IF;
END $$;

-- 2. the erase function: tp-031's, plus the ai_session_month entry

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
        RAISE EXCEPTION 'tp-033 erase_tenant: tenant, round and dry_run are required' USING ERRCODE = '22004';
    END IF;
    IF p_round < 1 THEN
        RAISE EXCEPTION 'tp-033 erase_tenant: the round starts at 1' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(current_setting('app.tenant_scope', true), '') IS DISTINCT FROM 'system'
       OR NULLIF(current_setting('app.tenant_id', true), '') IS NOT NULL THEN
        RAISE EXCEPTION 'tp-033 erase_tenant: runs only under the jobs system scope, with no tenant bound'
            USING ERRCODE = '42501';
    END IF;
    IF NOT p_dry_run THEN
        IF p_expect_plan IS NULL OR p_expect_plan !~ '^[0-9a-f]{64}$' THEN
            RAISE EXCEPTION 'tp-033 erase_tenant: an apply needs the approved plan hash (64 hex)' USING ERRCODE = '22023';
        END IF;
        LOCK TABLE tripplanner.trip_events, tripplanner.trip_drafts, tripplanner.outbox, tripplanner.sessions,
                   tripplanner.customers, tripplanner.ai_spend_month, tripplanner.ai_session_month IN EXCLUSIVE MODE;
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
    -- tp-033: the tenant's AI sessions of each month (tp-032), deleted; primary key 'scope,month,session_id', no
    -- updated_at (row version empty)
    SELECT count(*),
           md5(coalesce(string_agg(t.scope || ',' || to_char(t.month, 'YYYY-MM-DD') || ',' || t.session_id::text || '|',
                                   E'\n' ORDER BY t.scope || ',' || to_char(t.month, 'YYYY-MM-DD') || ','
                                                  || t.session_id::text || '|' COLLATE "C"),
                        ''))
      INTO v_n, v_digest FROM tripplanner.ai_session_month t WHERE t.scope = v_scope;
    v_tables := v_tables || jsonb_build_object('table', 'tripplanner.ai_session_month', 'action', 'delete', 'rows', v_n,
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

    DELETE FROM tripplanner.ai_session_month t WHERE t.scope = v_scope;
    GET DIAGNOSTICS v_done = ROW_COUNT;
    v_deleted := v_deleted || jsonb_build_object('tripplanner.ai_session_month', v_done);

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
        RAISE EXCEPTION 'tp-033 erase_tenant: deleted counts differ from the plan (rolled back)' USING ERRCODE = '40001';
    END IF;

    RETURN jsonb_build_object('format', 'tenant.erasure.v1', 'tenant_id', p_tenant, 'round', p_round,
                              'dry_run', false, 'status', 'ok', 'error_code', NULL, 'plan_hash', v_plan,
                              'tables', v_tables, 'app_rows_added', v_app_rows);
END
$fn$;

-- 3. grants

REVOKE ALL ON FUNCTION tripplanner.erase_tenant(uuid, integer, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tripplanner.erase_tenant(uuid, integer, boolean, text) TO tripplanner;

GRANT DELETE ON tripplanner.ai_session_month TO tripplanner;

-- 4. comment, post-checks, registration

COMMENT ON FUNCTION tripplanner.erase_tenant(uuid, integer, boolean, text) IS
    'tp-031, tp-033 (AA-1093, AA-1116, contract tenant.erasure.v1): DRY RUN plan (dry_run true) or apply (dry_run false, expect_plan = the approved plan hash of this round; another hash = refused plan_changed) of a tenant erasure: deletes the tenant''s sessions, trip_drafts, trip_events, outbox, ai_session_month rows and the customers no other tenant''s session links, and merges its ai_spend_month rows into the app scope. Tables as contract entries (md5 digests), plan hash bound to the tenant and the round. SECURITY INVOKER; session settings pinned; only under the jobs system scope with no tenant bound (else 42501).';

DO $$
BEGIN
    IF NOT has_function_privilege('tripplanner', 'tripplanner.erase_tenant(uuid, integer, boolean, text)', 'EXECUTE')
       OR has_function_privilege('cis_app', 'tripplanner.erase_tenant(uuid, integer, boolean, text)', 'EXECUTE')
       OR (SELECT p.prosecdef FROM pg_proc p
            WHERE p.oid = 'tripplanner.erase_tenant(uuid, integer, boolean, text)'::regprocedure) THEN
        RAISE EXCEPTION 'tp-033: tripplanner.erase_tenant must be SECURITY INVOKER and executable by tripplanner only';
    END IF;
    IF NOT has_table_privilege('tripplanner', 'tripplanner.ai_session_month', 'DELETE') THEN
        RAISE EXCEPTION 'tp-033: the runtime role has no DELETE grant on tripplanner.ai_session_month';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-033', now(), 'AA-1116: tripplanner.erase_tenant deletes the tenant''s tripplanner.ai_session_month rows '
                         '(tenant.erasure.v1 plan entry)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
