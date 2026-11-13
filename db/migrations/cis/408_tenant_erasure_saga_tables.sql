-- Migration 408: AA-1093 lane L2 (plan Part 2, decisions D1 / D2 / D7 / D8) — the tenant offboarding erasure saga:
-- shared.tenant_erasure_request (one request per offboarded tenant) and shared.tenant_erasure_step (what each app
-- reported for each phase of a request).
--
-- Why. An offboarded tenant's data lives in four apps (CIS, AA-Booking, TripPlanner, the partner CRM) and only CIS
-- could erase its part (AA-839 data_erasure job, CIS only). CIS is the master of the tenant account (root ADR 0019 d1),
-- so it runs the saga (contract tenant.erasure.v1, root PR #747): at the offboard (T0) it records a request with a
-- per-app earliest date (not_before: the CRM T0 + 90 days, the others T0 + the CIS retention window, 30 days today).
-- Each stage (the apps whose not_before has passed: stage 1 CIS, Booking, TripPlanner at T0 + 30 days; stage 2 the CRM
-- at T0 + 90 days) is one round: every active app reports a DRY RUN plan hash, the tech lead approves ONE combined
-- fingerprint, the apps apply (CIS last within its stage), every app reports a census of its personal-data columns.
--
-- What.
--   1. shared.tenant_erasure_request: request_id, tenant_id (NO foreign key to shared.tenants: the request must outlive
--      the tenant row that the CIS apply deletes; it is the erasure record), mode (live | drill: a drill is the window-0
--      rehearsal of a synthetic tenant), phase (the contract's: dry_run -> awaiting_approval -> apply -> verify -> the
--      next stage's dry_run or done; cancelled by a restore before any app applied, failed when a guard stops it),
--      round (one per stage, plus a new one after an expired or refused approval), opened_at (T0), is_pilot /
--      is_synthetic (copied at T0: the apps' guards still read them after CIS erased the tenant row),
--      not_before_cis / _booking / _tripplanner / _crm, round_apps (the apps active in the current round) and
--      done_apps (verified), the combined fingerprint and when it was computed, the approval (fingerprint,
--      admin:<staff id>, time, expiry, the manual RDS snapshot id), blockers (a JSON array of {app, kind, detail}: ids
--      and codes only), the receipt (counts and hashes), created_by, timestamps and txid (xid8 of the writing
--      transaction, kept by a trigger on every insert and update: the cursor of GET /tenant/v1/erasure-requests, which
--      serves a row only once its writer is older than every open transaction, like the tenant.entitlements.v1 feed).
--      One open request per tenant (partial unique index).
--   2. shared.tenant_erasure_step: the newest report per (request, round, app, mode), in the contract's ErasureReport
--      shape: app cis | booking | tripplanner | crm, mode dry_run | apply | verify, status ok | blocked | refused |
--      failed (plus pending: a CIS job still running, app_not_ready: the app's report view cannot be read yet),
--      report_id (the app's idempotency key, unique per app), error_code, plan_hash (sha256 hex), approved_plan_hash
--      (set on the dry_run row at approval: what the app must match before it applies), tables (per table: action,
--      rows, digest), blockers, census (pii_columns_checked, pii_rows_found), job_id, reported_at, updated_at.
--      No tenant column (the request holds it), so the CIS tenant erasure plan does not count these rows and its own
--      plan hash stays stable while the other apps report.
--   3. A trigger keeps txid / updated_at of the request row on every write (new function shared.tenant_erasure_touch).
--   4. Grants: cis_app SELECT, INSERT, UPDATE on both (no DELETE: the rows are the erasure record; 409 revokes any
--      DELETE or other privilege the Dev default ACL adds, since an expand file only grants); nothing for aa_app_user
--      (no RLS: platform tables read by CIS only, rls_catalogue_rules allowlist rule a) or catalog_owner (CIS 410
--      grants catalog_owner the columns its contract view reads).
--   5. Register 408.
--
-- PII (DM-6.1). None: ids, codes, hashes, counts, timestamps and staff actor ids (admin:<uuid>). No name, no e-mail, no
-- row value of any app.
--
-- Retention (DM-7.1). Proposed: kept as the erasure record (the proof that and when a tenant was erased, which apps
-- reported what), like acp_shared.audit_log; never deleted by the tenant erasure (registered as `keep` in
-- services/erasure/inventory.py). The row is in root data standards Part B section 7 (S279 rows, root PR #747,
-- already on master before the Infra copy).
--
-- Behaviour. None on apply: empty tables. The AA-1093 saga code PR writes them (offboard / restore hooks, the
-- tenant_erasure_saga job, the admin routes); before this file the code answers 503 / skips the hook.
--
-- Class: expand (root ADR 0017 d3): two new tables with constraints and indexes, a new trigger function and its trigger
-- on the new table (plain CREATE: a re-run fails on the function, as every expand file does once applied), grants on
-- the new tables and comments; no existing object changes, no seed row, no DO block, no REVOKE.
-- Ships in one migration-only PR with 409 (the feed event type) and 410 (the contract view).
--
-- Number. 407 (the settings registry) is the highest claimed on main (13/11/2026). If the owner main max + 1 differs at
-- merge, renumber (git grep '408_' and '408' in this file, 409, 410, their tests and conftest).
--
-- Rollback (a new forward migration, after the saga code is reverted): DROP TABLE shared.tenant_erasure_step,
-- shared.tenant_erasure_request; DROP FUNCTION shared.tenant_erasure_touch() (a destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.tenant_erasure_request (
    request_id              uuid         NOT NULL DEFAULT gen_random_uuid(),
    tenant_id               uuid         NOT NULL,
    mode                    text         NOT NULL DEFAULT 'live',
    phase                   text         NOT NULL DEFAULT 'dry_run',
    round                   smallint     NOT NULL DEFAULT 1,
    opened_at               timestamptz  NOT NULL,
    is_pilot                boolean      NOT NULL DEFAULT false,
    is_synthetic            boolean      NOT NULL DEFAULT false,
    not_before_cis          timestamptz  NOT NULL,
    not_before_booking      timestamptz  NOT NULL,
    not_before_tripplanner  timestamptz  NOT NULL,
    not_before_crm          timestamptz  NOT NULL,
    round_apps              text[]       NOT NULL DEFAULT '{}'::text[],
    done_apps               text[]       NOT NULL DEFAULT '{}'::text[],
    combined_fingerprint    text,
    fingerprint_at          timestamptz,
    approved_fingerprint    text,
    approved_by             text,
    approved_at             timestamptz,
    approval_expires_at     timestamptz,
    snapshot_id             text,
    blockers                jsonb        NOT NULL DEFAULT '[]'::jsonb,
    receipt                 jsonb,
    created_by              text         NOT NULL,
    created_at              timestamptz  NOT NULL DEFAULT now(),
    updated_at              timestamptz  NOT NULL DEFAULT now(),
    cancelled_at            timestamptz,
    done_at                 timestamptz,
    txid                    xid8         NOT NULL DEFAULT pg_current_xact_id(),
    CONSTRAINT tenant_erasure_request_pkey PRIMARY KEY (request_id),
    CONSTRAINT tenant_erasure_request_mode_check CHECK (mode IN ('live', 'drill')),
    CONSTRAINT tenant_erasure_request_phase_check CHECK (phase IN ('dry_run', 'awaiting_approval', 'apply', 'verify',
                                                                   'done', 'failed', 'cancelled')),
    CONSTRAINT tenant_erasure_request_round_check CHECK (round BETWEEN 1 AND 100),
    CONSTRAINT tenant_erasure_request_window_check CHECK (
        not_before_cis >= opened_at AND not_before_booking >= opened_at
        AND not_before_tripplanner >= opened_at AND not_before_crm >= opened_at),
    CONSTRAINT tenant_erasure_request_apps_check CHECK (
        round_apps <@ ARRAY['cis', 'booking', 'tripplanner', 'crm']::text[]
        AND done_apps <@ ARRAY['cis', 'booking', 'tripplanner', 'crm']::text[]
        AND NOT (round_apps && done_apps)),
    CONSTRAINT tenant_erasure_request_fingerprint_check CHECK (
        (combined_fingerprint IS NULL OR combined_fingerprint ~ '^[0-9a-f]{64}$')
        AND ((combined_fingerprint IS NULL) = (fingerprint_at IS NULL))),
    CONSTRAINT tenant_erasure_request_approval_check CHECK (
        (approved_fingerprint IS NULL OR approved_fingerprint ~ '^[0-9a-f]{64}$')
        AND (approved_by IS NULL OR char_length(approved_by) BETWEEN 1 AND 64)
        AND (snapshot_id IS NULL OR char_length(snapshot_id) BETWEEN 1 AND 255)
        AND ((approved_fingerprint IS NULL) = (approved_by IS NULL))
        AND ((approved_fingerprint IS NULL) = (approved_at IS NULL))
        AND ((approved_fingerprint IS NULL) = (approval_expires_at IS NULL))),
    CONSTRAINT tenant_erasure_request_json_check CHECK (
        jsonb_typeof(blockers) = 'array' AND (receipt IS NULL OR jsonb_typeof(receipt) = 'object')),
    CONSTRAINT tenant_erasure_request_actor_check CHECK (char_length(created_by) BETWEEN 1 AND 64),
    CONSTRAINT tenant_erasure_request_end_check CHECK (
        (cancelled_at IS NULL OR phase = 'cancelled') AND (done_at IS NULL OR phase = 'done'))
);

-- One open request per tenant; a tenant restored and offboarded again gets a new one.
CREATE UNIQUE INDEX IF NOT EXISTS tenant_erasure_request_open_key
    ON shared.tenant_erasure_request (tenant_id) WHERE phase NOT IN ('done', 'cancelled', 'failed');
CREATE INDEX IF NOT EXISTS tenant_erasure_request_feed_idx ON shared.tenant_erasure_request (txid, request_id);
CREATE INDEX IF NOT EXISTS tenant_erasure_request_tenant_idx ON shared.tenant_erasure_request (tenant_id, created_at);

COMMENT ON TABLE shared.tenant_erasure_request IS
    'AA-1093 (CIS 408, contract tenant.erasure.v1, root ADR 0019 d1): the tenant offboarding erasure saga, one request '
    'per offboarded tenant. No FK to shared.tenants: it outlives the tenant row as the erasure record (CIS erases in '
    'stage 1, the CRM in stage 2). Written by services/tenant_erasure (offboard / restore hooks, the '
    'tenant_erasure_saga job, the admin approval). Ids, hashes, counts and staff actor ids only.';
COMMENT ON COLUMN shared.tenant_erasure_request.mode IS
    'AA-1093 (408): live (the windows of the offboard) | drill (window 0, synthetic tenants only).';
COMMENT ON COLUMN shared.tenant_erasure_request.phase IS
    'AA-1093 (408, tenant.erasure.v1 Phase): dry_run -> awaiting_approval -> apply -> verify -> (next stage: dry_run '
    'of the next round) -> done; failed | cancelled.';
COMMENT ON COLUMN shared.tenant_erasure_request.round_apps IS
    'AA-1093 (408): the apps active in the current round (fixed when the round starts: the apps whose not_before has '
    'passed and that are not done). Empty = waiting for the next not_before.';
COMMENT ON COLUMN shared.tenant_erasure_request.done_apps IS
    'AA-1093 (408): the apps whose erasure is verified (census 0).';
COMMENT ON COLUMN shared.tenant_erasure_request.is_synthetic IS
    'AA-1093 (408): shared.tenants.is_canary true and not the pilot, copied at T0 (on Dev an app applies only then).';
COMMENT ON COLUMN shared.tenant_erasure_request.txid IS
    'AA-1093 (408): the writing transaction (shared.tenant_erasure_touch on every insert / update), the cursor of '
    'GET /tenant/v1/erasure-requests.';

CREATE TABLE IF NOT EXISTS shared.tenant_erasure_step (
    request_id          uuid         NOT NULL,
    round               smallint     NOT NULL,
    app                 text         NOT NULL,
    mode                text         NOT NULL,
    status              text         NOT NULL,
    report_id           uuid,
    error_code          text,
    plan_hash           text,
    approved_plan_hash  text,
    tables              jsonb        NOT NULL DEFAULT '[]'::jsonb,
    blockers            jsonb        NOT NULL DEFAULT '[]'::jsonb,
    census              jsonb,
    job_id              uuid,
    reported_at         timestamptz,
    updated_at          timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT tenant_erasure_step_pkey PRIMARY KEY (request_id, round, app, mode),
    CONSTRAINT tenant_erasure_step_request_fkey FOREIGN KEY (request_id)
        REFERENCES shared.tenant_erasure_request (request_id),
    CONSTRAINT tenant_erasure_step_app_check CHECK (app IN ('cis', 'booking', 'tripplanner', 'crm')),
    CONSTRAINT tenant_erasure_step_mode_check CHECK (mode IN ('dry_run', 'apply', 'verify')),
    CONSTRAINT tenant_erasure_step_status_check CHECK (status IN ('pending', 'ok', 'blocked', 'refused', 'failed',
                                                                 'app_not_ready')),
    CONSTRAINT tenant_erasure_step_code_check CHECK (error_code IS NULL OR error_code ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT tenant_erasure_step_hash_check CHECK (
        (plan_hash IS NULL OR plan_hash ~ '^[0-9a-f]{64}$')
        AND (approved_plan_hash IS NULL OR approved_plan_hash ~ '^[0-9a-f]{64}$')),
    CONSTRAINT tenant_erasure_step_json_check CHECK (
        jsonb_typeof(tables) = 'array' AND jsonb_typeof(blockers) = 'array'
        AND (census IS NULL OR jsonb_typeof(census) = 'object'))
);

-- A report id is the idempotency key of one app's report (tenant.erasure.v1 ErasureReport.report_id).
CREATE UNIQUE INDEX IF NOT EXISTS tenant_erasure_step_report_key
    ON shared.tenant_erasure_step (app, report_id) WHERE report_id IS NOT NULL;

COMMENT ON TABLE shared.tenant_erasure_step IS
    'AA-1093 (CIS 408): the newest report of each app for one round and mode of an erasure request (tenant.erasure.v1 '
    'ErasureReport: status, error code, plan hash, tables with counts and digests, blockers, census, job id). Booking '
    'and TripPlanner rows are copied from their report views, CRM rows come from POST /tenant/v1/erasure-requests/{id}'
    '/reports, CIS rows from its own data_erasure jobs. No tenant column.';
COMMENT ON COLUMN shared.tenant_erasure_step.approved_plan_hash IS
    'AA-1093 (408): set on the dry_run row when the combined fingerprint is approved: the app recomputes its plan and '
    'applies only when it still matches (refused, error_code plan_changed, otherwise).';

CREATE FUNCTION shared.tenant_erasure_touch() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
BEGIN
    NEW.txid := pg_current_xact_id();
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

CREATE TRIGGER tenant_erasure_request_touch
    BEFORE INSERT OR UPDATE ON shared.tenant_erasure_request
    FOR EACH ROW EXECUTE FUNCTION shared.tenant_erasure_touch();

-- The Dev default ACL of cis_owner in shared may also give cis_app DELETE: CIS 409 (contract) revokes it, an expand
-- file only grants.
GRANT SELECT, INSERT, UPDATE ON shared.tenant_erasure_request, shared.tenant_erasure_step TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('408', now(), 'AA-1093: shared.tenant_erasure_request / tenant_erasure_step (tenant offboarding erasure saga)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
