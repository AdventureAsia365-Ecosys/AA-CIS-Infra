-- Migration tp-030: AA-1093 (lane L4, the TripPlanner part of the tenant offboarding saga) — the erasure log, the
-- erase function and the report view CIS reads.
--
-- Class: contract (root ADR 0017 / 0017a). The file has no directive line on purpose: its policies and function are
-- created through re-runnable DO blocks / CREATE OR REPLACE (test_replay_twice_pg.py runs every file twice), which the
-- expand lint refuses, and it REVOKEs the default write grants on the new objects. Merge order MIG-4: this
-- migration-only PR first; the TripPlanner code PR (jobs tp_tenant_erase, tp_tenant_backup, tp_tenant_restore_drill)
-- follows once this file is applied on Dev. On Dev, AA-CIS-Infra Migration Apply runs it in contract mode once every
-- job table is idle (byte-identical copy db/migrations/tripplanner/030_tenant_erasure.sql), as tp_owner, the live
-- owner of schema tripplanner since tp-013 (XD8). Never run it from a laptop.
--
-- Why (plan docs/audits/2026-11-13-S279-session/aa1093-plan.md in the root repo, Part 2; decision D4): when CIS
-- offboards a tenant, TripPlanner deletes every row of that tenant and merges its AI spend rows into the app scope.
-- Like every app of the saga it first computes a DRY RUN plan hash (per table: action, row count and a fingerprint of
-- the rows, never a row value); the tech lead approves the combined fingerprint once; the apply recomputes the hash
-- and refuses when it changed (plan_changed). TripPlanner had no tenant erasure (S278 system audit, M31).
--
-- What:
--   1. guards: the file runs as tp_owner; tp-028 forced the four tenant tables; tp-029's ai_spend_month exists.
--   2. tripplanner.tenant_erasure_log: one row per (request_id, mode); mode dry_run | apply | verify; the plan hash
--      (64 hex), per-table counts and fingerprints (jsonb object, ids / counts / hashes only), status, a refusal
--      reason code, the job that wrote it. No personal data. Row-level security ENABLE + FORCE (the table carries a
--      tenant_id): <log>_system FOR ALL TO tripplanner, tp_owner (the jobs Lambda's system scope, as tp-028) and
--      <log>_owner_read FOR SELECT TO tp_owner (the report view, read by cis_app, which binds no TripPlanner tenant,
--      keeps every row). The runtime role gets SELECT, INSERT, UPDATE; the default DELETE is revoked (an erasure
--      record is never deleted by the app; its retention is data standards DM-7.1 row tripplanner.tenant_erasure_log).
--   3. tripplanner.erase_tenant(tenant uuid, dry_run boolean, expect_plan text DEFAULT NULL) RETURNS jsonb,
--      SECURITY INVOKER (MIG-6: no SECURITY DEFINER in this repo), search_path pinned. It runs only under the jobs
--      Lambda's system scope (app.tenant_scope = 'system') and with no tenant bound, else it raises 42501: the
--      assembly Lambda never opens that scope (backend/tests/test_aa1038_force_rls.py), so a request path cannot
--      erase, and row-level security keeps every other caller at zero rows anyway.
--        plan, per table (keys sorted): tripplanner.sessions / trip_drafts / trip_events / outbox  action delete;
--          tripplanner.ai_spend_month (scope 'tenant:<id>')  action merge_into_app; tripplanner.customers linked
--          through the tenant's sessions and through no session of another tenant  action delete (personal data that
--          would otherwise be left without any session: the only FK to customers is sessions.customer_id, so the
--          delete is FK-safe once the sessions are gone; a customer another tenant's session still links is not
--          touched); tripplanner.traveller_accounts linked through the tenant's sessions  action keep (count only:
--          global sign-in accounts, outside the tenant scope, a traveller's own erasure is the DSAR runbook).
--          fingerprint = sha256 hex of the comma-joined md5 of every row's text, in key order (empty = sha256 of '').
--          The row text depends on the session's TimeZone / DateStyle / IntervalStyle / extra_float_digits /
--          bytea_output, so the function pins all five (SET clauses): a DRY RUN and the apply hash the same rows
--          the same way whatever the caller's session settings are.
--          plan_hash = sha256 hex of 'tp-tenant-erase/1|<tenant>|' and every 'key|action|rows|fingerprint' line.
--        dry_run true: returns the plan, writes nothing.
--        dry_run false: expect_plan (64 hex) is required (22023); the six tables are locked IN EXCLUSIVE MODE (reads
--          go on, writes wait) so the plan cannot move between the hash and the deletes; a hash other than
--          expect_plan returns status refused, reason plan_changed, nothing deleted; else the deletes run children
--          first (trip_events, trip_drafts, outbox, sessions, then the planned customers: trip_events.session_id and
--          trip_drafts.session_id reference sessions.id, sessions.customer_id references customers.id; outbox has no
--          FK) and each must remove exactly the planned count (else the statement raises and the caller's
--          transaction rolls back); the spend rows are
--          merged: an app row of the same stage and month is inserted only when none exists (the app row already
--          counts every tenant's spend, backend/shared/monthly_spend.py charge()), then the tenant rows go.
--        The log row is the caller's (same transaction): the function never writes the log.
--   4. tripplanner.v_tenant_erasure_report_v1 (request_id, tenant_id, mode, status, reason, plan_hash, counts, job_id,
--      created_at, updated_at) over the log: an owner view (no security_invoker), SELECT to cis_app only (the CIS
--      saga reads each app's report, contract tenant.erasure.v1); every default privilege of the runtime role on it
--      is revoked, SELECT included (the view bypasses the log's row-level security as its owner, so the runtime role
--      reads the log itself, under its system policy).
--   5. comments, guards, registration.
--
-- Locks: none on existing tables (new objects only; the function's locks are taken when it runs, in apply mode only).
-- Re-runnable (test_replay_twice_pg.py): IF NOT EXISTS on the table and the index, policies created only when
-- missing, CREATE OR REPLACE on the function (same signature) and the view (same columns), repeated grants / revokes /
-- comments, ON CONFLICT DO NOTHING.
-- Undo: a later tp- file: DROP VIEW tripplanner.v_tenant_erasure_report_v1 and DROP FUNCTION tripplanner.erase_tenant
-- (contract), then DROP TABLE tripplanner.tenant_erasure_log with `-- migrate: destructive` (DRY RUN first), after the
-- jobs code and the CIS reader are gone.

BEGIN;

-- 1. guards before any change

DO $$
DECLARE
    bad text;
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-030: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
    SELECT string_agg(c.relname::text, ', ' ORDER BY c.relname) INTO bad
      FROM pg_class c
     WHERE c.relnamespace = 'tripplanner'::regnamespace
       AND c.relname IN ('sessions', 'trip_drafts', 'trip_events', 'outbox')
       AND NOT (c.relrowsecurity AND c.relforcerowsecurity);
    IF bad IS NOT NULL OR (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'tripplanner'::regnamespace
                             AND c.relname IN ('sessions', 'trip_drafts', 'trip_events', 'outbox')) <> 4 THEN
        RAISE EXCEPTION 'tp-030: tp-028 (FORCE row-level security on the four tenant tables) is not applied: %',
            coalesce(bad, 'a table is missing');
    END IF;
    IF to_regclass('tripplanner.ai_spend_month') IS NULL THEN
        RAISE EXCEPTION 'tp-030: tripplanner.ai_spend_month (tp-029) is missing';
    END IF;
END $$;

-- 2. the erasure log

CREATE TABLE IF NOT EXISTS tripplanner.tenant_erasure_log (
    request_id uuid        NOT NULL,
    tenant_id  uuid        NOT NULL,
    mode       text        NOT NULL,
    plan_hash  text,
    counts     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    status     text        NOT NULL,
    reason     text,
    job_id     uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tenant_erasure_log_pkey PRIMARY KEY (request_id, mode),
    CONSTRAINT tenant_erasure_log_mode_chk CHECK (mode IN ('dry_run', 'apply', 'verify')),
    CONSTRAINT tenant_erasure_log_status_chk CHECK (
        (mode = 'dry_run' AND status IN ('planned', 'refused'))
        OR (mode = 'apply' AND status IN ('applied', 'refused'))
        OR (mode = 'verify' AND status IN ('verified', 'residue', 'refused'))),
    CONSTRAINT tenant_erasure_log_reason_chk CHECK (
        (status = 'refused') = (reason IS NOT NULL) OR (status = 'residue' AND reason IS NOT NULL)),
    CONSTRAINT tenant_erasure_log_reason_shape_chk CHECK (reason IS NULL OR reason ~ '^[a-z][a-z0-9_]{0,63}$'),
    CONSTRAINT tenant_erasure_log_plan_hash_chk CHECK (plan_hash IS NULL OR plan_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT tenant_erasure_log_counts_chk CHECK (jsonb_typeof(counts) = 'object')
);

CREATE INDEX IF NOT EXISTS tenant_erasure_log_tenant_idx ON tripplanner.tenant_erasure_log (tenant_id, created_at);

ALTER TABLE tripplanner.tenant_erasure_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE tripplanner.tenant_erasure_log FORCE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tripplanner' AND tablename = 'tenant_erasure_log'
                                               AND policyname = 'tenant_erasure_log_system') THEN
        CREATE POLICY tenant_erasure_log_system ON tripplanner.tenant_erasure_log AS PERMISSIVE FOR ALL
            TO tripplanner, tp_owner
            USING (NULLIF(current_setting('app.tenant_scope', true), '') = 'system')
            WITH CHECK (NULLIF(current_setting('app.tenant_scope', true), '') = 'system');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tripplanner' AND tablename = 'tenant_erasure_log'
                                               AND policyname = 'tenant_erasure_log_owner_read') THEN
        CREATE POLICY tenant_erasure_log_owner_read ON tripplanner.tenant_erasure_log AS PERMISSIVE FOR SELECT
            TO tp_owner
            USING (NULLIF(current_setting('app.tenant_id', true), '') IS NULL
                   OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
    END IF;
END $$;

GRANT SELECT, INSERT, UPDATE ON tripplanner.tenant_erasure_log TO tripplanner;
REVOKE DELETE, TRUNCATE ON tripplanner.tenant_erasure_log FROM tripplanner;

-- 3. the erase function

CREATE OR REPLACE FUNCTION tripplanner.erase_tenant(p_tenant uuid, p_dry_run boolean, p_expect_plan text DEFAULT NULL)
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
    v_scope    text := 'tenant:' || p_tenant::text;
    v_tables   jsonb := '{}'::jsonb;
    v_deleted  jsonb := '{}'::jsonb;
    v_plan     text;
    v_n        bigint;
    v_fp       text;
    v_done     bigint;
    v_app_rows bigint := 0;
    v_customers uuid[];
BEGIN
    IF p_tenant IS NULL OR p_dry_run IS NULL THEN
        RAISE EXCEPTION 'tp-030 erase_tenant: tenant and dry_run are required' USING ERRCODE = '22004';
    END IF;
    IF NULLIF(current_setting('app.tenant_scope', true), '') IS DISTINCT FROM 'system'
       OR NULLIF(current_setting('app.tenant_id', true), '') IS NOT NULL THEN
        RAISE EXCEPTION 'tp-030 erase_tenant: runs only under the jobs system scope, with no tenant bound'
            USING ERRCODE = '42501';
    END IF;
    IF NOT p_dry_run THEN
        IF p_expect_plan IS NULL OR p_expect_plan !~ '^[0-9a-f]{64}$' THEN
            RAISE EXCEPTION 'tp-030 erase_tenant: an apply needs the approved plan hash (64 hex)' USING ERRCODE = '22023';
        END IF;
        LOCK TABLE tripplanner.trip_events, tripplanner.trip_drafts, tripplanner.outbox, tripplanner.sessions,
                   tripplanner.customers, tripplanner.ai_spend_month IN EXCLUSIVE MODE;
    END IF;

    -- the plan: per table the action, the row count and a fingerprint of the rows (never a row value)
    SELECT count(*), encode(sha256(convert_to(coalesce(string_agg(md5(t::text), ',' ORDER BY t.id), ''), 'UTF8')), 'hex')
      INTO v_n, v_fp FROM tripplanner.sessions t WHERE t.tenant_id = p_tenant;
    v_tables := v_tables || jsonb_build_object('tripplanner.sessions',
                                               jsonb_build_object('action', 'delete', 'rows', v_n, 'fingerprint', v_fp));
    SELECT count(*), encode(sha256(convert_to(coalesce(string_agg(md5(t::text), ',' ORDER BY t.id), ''), 'UTF8')), 'hex')
      INTO v_n, v_fp FROM tripplanner.trip_drafts t WHERE t.tenant_id = p_tenant;
    v_tables := v_tables || jsonb_build_object('tripplanner.trip_drafts',
                                               jsonb_build_object('action', 'delete', 'rows', v_n, 'fingerprint', v_fp));
    SELECT count(*), encode(sha256(convert_to(coalesce(string_agg(md5(t::text), ',' ORDER BY t.id), ''), 'UTF8')), 'hex')
      INTO v_n, v_fp FROM tripplanner.trip_events t WHERE t.tenant_id = p_tenant;
    v_tables := v_tables || jsonb_build_object('tripplanner.trip_events',
                                               jsonb_build_object('action', 'delete', 'rows', v_n, 'fingerprint', v_fp));
    SELECT count(*), encode(sha256(convert_to(coalesce(string_agg(md5(t::text), ',' ORDER BY t.id), ''), 'UTF8')), 'hex')
      INTO v_n, v_fp FROM tripplanner.outbox t WHERE t.tenant_id = p_tenant;
    v_tables := v_tables || jsonb_build_object('tripplanner.outbox',
                                               jsonb_build_object('action', 'delete', 'rows', v_n, 'fingerprint', v_fp));
    SELECT count(*), encode(sha256(convert_to(coalesce(string_agg(md5(t::text), ',' ORDER BY t.stage, t.month), ''),
                                              'UTF8')), 'hex')
      INTO v_n, v_fp FROM tripplanner.ai_spend_month t WHERE t.scope = v_scope;
    v_tables := v_tables || jsonb_build_object('tripplanner.ai_spend_month',
                                               jsonb_build_object('action', 'merge_into_app', 'rows', v_n,
                                                                  'fingerprint', v_fp));
    -- customers only this tenant's sessions link (no session of another tenant): deleted after the sessions
    SELECT coalesce(array_agg(c.id ORDER BY c.id), '{}'::uuid[]), count(*),
           encode(sha256(convert_to(coalesce(string_agg(md5(c::text), ',' ORDER BY c.id), ''), 'UTF8')), 'hex')
      INTO v_customers, v_n, v_fp
      FROM tripplanner.customers c
     WHERE c.id IN (SELECT s.customer_id FROM tripplanner.sessions s WHERE s.tenant_id = p_tenant)
       AND NOT EXISTS (SELECT 1 FROM tripplanner.sessions o WHERE o.customer_id = c.id AND o.tenant_id <> p_tenant);
    v_tables := v_tables || jsonb_build_object('tripplanner.customers',
                                               jsonb_build_object('action', 'delete', 'rows', v_n, 'fingerprint', v_fp));
    SELECT count(*) INTO v_n FROM tripplanner.traveller_accounts a
     WHERE a.id IN (SELECT s.account_id FROM tripplanner.sessions s WHERE s.tenant_id = p_tenant);
    v_tables := v_tables || jsonb_build_object('tripplanner.traveller_accounts',
                                               jsonb_build_object('action', 'keep', 'rows', v_n, 'fingerprint', NULL));

    SELECT encode(sha256(convert_to('tp-tenant-erase/1|' || p_tenant::text || '|'
                                    || string_agg(e.key || '|' || (e.value ->> 'action') || '|' || (e.value ->> 'rows')
                                                  || '|' || coalesce(e.value ->> 'fingerprint', '-'), E'\n' ORDER BY e.key),
                                    'UTF8')), 'hex')
      INTO v_plan FROM jsonb_each(v_tables) e;

    IF p_dry_run THEN
        RETURN jsonb_build_object('format', 'tp-tenant-erase/1', 'tenant_id', p_tenant, 'dry_run', true,
                                  'status', 'planned', 'reason', NULL, 'plan_hash', v_plan, 'tables', v_tables,
                                  'deleted', '{}'::jsonb, 'app_rows_added', 0);
    END IF;
    IF v_plan <> p_expect_plan THEN
        RETURN jsonb_build_object('format', 'tp-tenant-erase/1', 'tenant_id', p_tenant, 'dry_run', false,
                                  'status', 'refused', 'reason', 'plan_changed', 'plan_hash', v_plan,
                                  'tables', v_tables, 'deleted', '{}'::jsonb, 'app_rows_added', 0);
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

    IF EXISTS (SELECT 1 FROM jsonb_each(v_deleted) d
                WHERE (d.value)::bigint <> ((v_tables -> d.key) ->> 'rows')::bigint) THEN
        RAISE EXCEPTION 'tp-030 erase_tenant: deleted counts differ from the plan (rolled back)' USING ERRCODE = '40001';
    END IF;

    RETURN jsonb_build_object('format', 'tp-tenant-erase/1', 'tenant_id', p_tenant, 'dry_run', false,
                              'status', 'applied', 'reason', NULL, 'plan_hash', v_plan, 'tables', v_tables,
                              'deleted', v_deleted, 'app_rows_added', v_app_rows);
END
$fn$;

REVOKE ALL ON FUNCTION tripplanner.erase_tenant(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tripplanner.erase_tenant(uuid, boolean, text) TO tripplanner;

-- 4. the report view CIS reads (ids, counts and hashes only)

CREATE OR REPLACE VIEW tripplanner.v_tenant_erasure_report_v1 AS
SELECT l.request_id, l.tenant_id, l.mode, l.status, l.reason, l.plan_hash, l.counts, l.job_id, l.created_at,
       l.updated_at
  FROM tripplanner.tenant_erasure_log l;

REVOKE ALL ON tripplanner.v_tenant_erasure_report_v1 FROM tripplanner;
GRANT SELECT ON tripplanner.v_tenant_erasure_report_v1 TO cis_app;

-- 5. comments

COMMENT ON TABLE tripplanner.tenant_erasure_log IS
    'tp-030 (AA-1093): one row per tenant erasure request and mode (dry_run | apply | verify) of the TripPlanner part of the offboarding saga: plan hash, per-table counts and fingerprints, status, refusal reason. Ids, counts and hashes only, no personal data. Written by the jobs Lambda (tp_tenant_erase) under the system scope; never deleted by the app (retention: data standards DM-7.1).';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.request_id IS
    'tp-030: the erasure request (CIS catalog.v_tenant_erasure_v1 request id, or the job id of an operator drill).';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.tenant_id IS
    'tp-030: the erased tenant, soft key to shared.tenants.tenant_id (no FK, another owner). Not personal data.';
COMMENT ON COLUMN tripplanner.tenant_erasure_log.counts IS
    'tp-030: the plan / result of tripplanner.erase_tenant: per table action, rows and fingerprint (sha256 of row md5s), deleted counts. No row value.';
COMMENT ON FUNCTION tripplanner.erase_tenant(uuid, boolean, text) IS
    'tp-030 (AA-1093): DRY RUN plan (dry_run true) or apply (dry_run false, expect_plan = the approved plan hash; another hash = refused plan_changed) of a tenant erasure: deletes the tenant''s sessions, trip_drafts, trip_events, outbox rows and the customers no other tenant''s session links, and merges its ai_spend_month rows into the app scope. SECURITY INVOKER; session settings that shape row text pinned (UTC, ISO dates); only under the jobs system scope with no tenant bound (else 42501).';
COMMENT ON VIEW tripplanner.v_tenant_erasure_report_v1 IS
    'tp-030 (AA-1093): the TripPlanner erasure report the CIS saga reads (contract tenant.erasure.v1): request, tenant, mode, status, reason, plan hash, counts. Ids, counts and hashes only. SELECT to cis_app only (not the runtime role).';

DO $$
BEGIN
    EXECUTE format('COMMENT ON POLICY %I ON tripplanner.tenant_erasure_log IS %L', 'tenant_erasure_log_system',
                   'tp-030 (AA-1093): every row while app.tenant_scope = system (the jobs Lambda, tp_tenant_erase).');
    EXECUTE format('COMMENT ON POLICY %I ON tripplanner.tenant_erasure_log IS %L', 'tenant_erasure_log_owner_read',
                   'tp-030 (AA-1093): the report view (owner view, read by cis_app) sees every row without a bound '
                   'tenant, the bound tenant''s rows with one.');
END $$;

-- 6. guards

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = 'tripplanner.tenant_erasure_log'::regclass
                                             AND c.relrowsecurity AND c.relforcerowsecurity) THEN
        RAISE EXCEPTION 'tp-030: row-level security is not enabled and forced on tripplanner.tenant_erasure_log';
    END IF;
    IF (SELECT array_agg(p.policyname::text ORDER BY p.policyname) FROM pg_policies p
         WHERE p.schemaname = 'tripplanner' AND p.tablename = 'tenant_erasure_log')
       IS DISTINCT FROM ARRAY['tenant_erasure_log_owner_read', 'tenant_erasure_log_system'] THEN
        RAISE EXCEPTION 'tp-030: expected exactly tenant_erasure_log_owner_read and tenant_erasure_log_system';
    END IF;
    IF has_table_privilege('tripplanner', 'tripplanner.tenant_erasure_log', 'DELETE')
       OR NOT has_table_privilege('tripplanner', 'tripplanner.tenant_erasure_log', 'INSERT')
       OR has_table_privilege('tripplanner', 'tripplanner.v_tenant_erasure_report_v1', 'INSERT')
       OR has_table_privilege('tripplanner', 'tripplanner.v_tenant_erasure_report_v1', 'SELECT')
       OR NOT has_table_privilege('cis_app', 'tripplanner.v_tenant_erasure_report_v1', 'SELECT')
       OR has_table_privilege('cis_app', 'tripplanner.tenant_erasure_log', 'SELECT') THEN
        RAISE EXCEPTION 'tp-030: unexpected grants on the erasure log or its report view';
    END IF;
    IF NOT has_function_privilege('tripplanner', 'tripplanner.erase_tenant(uuid, boolean, text)', 'EXECUTE')
       OR has_function_privilege('cis_app', 'tripplanner.erase_tenant(uuid, boolean, text)', 'EXECUTE')
       OR (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = 'tripplanner.erase_tenant(uuid, boolean, text)'::regprocedure) THEN
        RAISE EXCEPTION 'tp-030: tripplanner.erase_tenant must be SECURITY INVOKER and executable by tripplanner only';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-030', now(), 'AA-1093: tripplanner.tenant_erasure_log, erase_tenant(), v_tenant_erasure_report_v1 '
                         '(the TripPlanner part of the tenant offboarding saga)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
