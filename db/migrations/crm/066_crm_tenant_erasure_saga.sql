-- Migration crm-066: AA-1093 stage 2 (root plan docs/audits/2026-11-13-S279-session/aa1093-plan.md, decision D2) — the
-- storage of crm_tenant_erase, the CRM step of the CIS tenant offboarding erasure saga (contract tenant.erasure.v1).
--
-- Owner: AA-Partner (api/migrations/066_crm_tenant_erasure_saga.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy Migration Apply applies (Migration Copy Guard). Key crm-066 = crm main max + 1 (crm-065, 14/11/2026); if main
-- moves, renumber: file name, this header, the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS and the tests
-- that name it (git grep '066_' and 'crm-066').
--
-- Why. D2: after its exit window (T0 + 90 days) AA erases an offboarded agency's CRM data without the owner's click.
-- CIS runs the saga and serves the CRM its requests over HTTP (GET /tenant/v1/erasure-requests, cursor feed) and takes
-- the CRM's reports (POST .../reports); the CRM keeps "its own record of what it did per request and round" (the
-- contract). Three platform tables (no tenant_id column: the CIS tenant may have no CRM agency, and the rows must
-- outlive the agency erase they record):
--   1. crm.tenant_erasure_feed_state: the one consumer state of the feed, like crm.entitlement_feed_state (crm-043):
--      the opaque cursor CIS returned last, the last success, the last error class and time, the consecutive
--      failures. Its single row is inserted by the job on first use (no INSERT here: the file writes no row).
--   2. crm.tenant_erasure_saga: one row per CIS request, the newest state the feed served (phase, round, the crm
--      step status, its not_before, the approved plan hash in apply / verify, the approval expiry, is_pilot /
--      is_synthetic as CIS copied them at T0). The job acts on it, never on a value it computes itself.
--   3. crm.tenant_erasure_report: one row per (request, round, mode): the ErasureReport the CRM computed (ids, codes,
--      hashes, counts only), written in the transaction that did the work (an apply's report commits with the erase),
--      then posted to CIS; post_outcome records the answer (accepted, or refused:<code>), so a report is posted again
--      with the same report_id and body after a network error and never recomputed.
--   Ids, codes, hashes, counts and times only: no name, no e-mail, no free text (DM-6.1: no pii: column).
--
-- Class: contract (root ADR 0017 d3; no migrate directive line). Three new tables with their constraints, indexes,
-- triggers and comments; the only foreign key is between the new tables; no change to an existing object, no row
-- written. It is not expand only because schema crm is an RLS schema (Infra owners.yaml expand_rls_schemas) and these
-- platform tables have no tenant column, so they carry no ROW LEVEL SECURITY (like crm.aa_catalog_tour); the expand
-- post-check refuses a new crm table without ENABLE + FORCE (S281 preflight classify exit 14). crm_app keeps the default DML of crm-001 on the new tables. Ships in the migration-only PR with crm-067
-- (batch crm 066-067), applied before the code PR (MIG-4).
-- DM-7.1: root data standards 02-data-management.md Part B section 7, the rows added in the root PR of this lane.
--
-- Rollback (a forward crm- file, after the code that writes them is reverted): DROP TABLE crm.tenant_erasure_report,
-- crm.tenant_erasure_saga, crm.tenant_erasure_feed_state.
--
-- Runs as crm_owner (Migration Apply switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- ── 1. The feed state (platform singleton) ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.tenant_erasure_feed_state (
    singleton         BOOLEAN PRIMARY KEY DEFAULT true,
    feed_cursor       TEXT,
    last_ok_at        TIMESTAMPTZ,
    last_error_class  TEXT,
    last_error_at     TIMESTAMPTZ,
    failures          INTEGER NOT NULL DEFAULT 0,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT tenant_erasure_feed_state_singleton_chk CHECK (singleton),
    CONSTRAINT tenant_erasure_feed_state_cursor_chk CHECK (feed_cursor IS NULL OR feed_cursor ~ '^[!-~]{1,200}$'),
    CONSTRAINT tenant_erasure_feed_state_error_chk CHECK (
        (last_error_class IS NULL) = (last_error_at IS NULL)
        AND (last_error_class IS NULL OR last_error_class ~ '^[a-z][a-z0-9_]{0,39}$')
    ),
    CONSTRAINT tenant_erasure_feed_state_failures_chk CHECK (failures BETWEEN 0 AND 1000000)
);
CREATE OR REPLACE TRIGGER tenant_erasure_feed_state_set_updated_at
    BEFORE UPDATE ON crm.tenant_erasure_feed_state
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
COMMENT ON TABLE crm.tenant_erasure_feed_state IS 'AA-1093 stage 2 (crm-066): the one consumer state of the CIS feed GET /tenant/v1/erasure-requests (tenant.erasure.v1, job crm_tenant_erase): the opaque cursor CIS returned last (printable ASCII, <= 200), the last successful pull, the last error class and time, the consecutive failures the job backs off on. Platform table: no tenant column, no personal data. One row, inserted by the job on first use.';

-- ── 2. One row per CIS erasure request ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.tenant_erasure_saga (
    request_id           UUID PRIMARY KEY,
    subject_tenant_id    UUID NOT NULL,
    phase                TEXT NOT NULL,
    round                INTEGER NOT NULL,
    step_status          TEXT NOT NULL,
    not_before           TIMESTAMPTZ NOT NULL,
    approved_plan_hash   TEXT,
    approval_expires_at  TIMESTAMPTZ,
    is_pilot             BOOLEAN NOT NULL,
    is_synthetic         BOOLEAN NOT NULL,
    cis_updated_at       TIMESTAMPTZ NOT NULL,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT tenant_erasure_saga_phase_chk CHECK (
        phase IN ('dry_run', 'awaiting_approval', 'apply', 'verify', 'done', 'failed', 'cancelled')
    ),
    CONSTRAINT tenant_erasure_saga_round_chk CHECK (round BETWEEN 1 AND 1000),
    CONSTRAINT tenant_erasure_saga_step_chk CHECK (step_status IN ('waiting', 'active', 'done', 'failed')),
    CONSTRAINT tenant_erasure_saga_hash_chk CHECK (
        approved_plan_hash IS NULL OR approved_plan_hash ~ '^[0-9a-f]{64}$'
    )
);
CREATE INDEX IF NOT EXISTS tenant_erasure_saga_active_idx ON crm.tenant_erasure_saga (cis_updated_at)
    WHERE step_status = 'active';
CREATE INDEX IF NOT EXISTS tenant_erasure_saga_tenant_idx ON crm.tenant_erasure_saga (subject_tenant_id);
CREATE OR REPLACE TRIGGER tenant_erasure_saga_set_updated_at
    BEFORE UPDATE ON crm.tenant_erasure_saga
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
COMMENT ON TABLE crm.tenant_erasure_saga IS 'AA-1093 stage 2 (crm-066): one CIS tenant erasure request (tenant.erasure.v1 ErasureRequest) as the feed served it last: phase, round, the crm step status (waiting | active | done | failed) and its not_before, the approved plan hash (apply / verify), the approval expiry, is_pilot / is_synthetic as CIS copied them at T0. subject_tenant_id is the CIS tenant (= the CRM agency id when the CRM holds one; no foreign key: the row outlives the agency erase). Written by job:crm_tenant_erase only. Platform table: ids, codes, hashes and times; no personal data.';
COMMENT ON COLUMN crm.tenant_erasure_saga.subject_tenant_id IS 'the CIS tenant the request erases (= crm.tenant.tenant_id of its agency, if any); no foreign key';
COMMENT ON COLUMN crm.tenant_erasure_saga.cis_updated_at IS 'the request''s updated_at in the feed item: an older item never overwrites a newer one';

-- ── 3. One row per report the CRM made ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.tenant_erasure_report (
    report_id     UUID PRIMARY KEY,
    request_id    UUID NOT NULL REFERENCES crm.tenant_erasure_saga (request_id),
    round         INTEGER NOT NULL,
    mode          TEXT NOT NULL,
    outcome       TEXT NOT NULL,
    error_code    TEXT,
    plan_hash     TEXT,
    body          JSONB NOT NULL,
    reported_at   TIMESTAMPTZ NOT NULL,
    post_outcome  TEXT,
    posted_at     TIMESTAMPTZ,
    post_attempts INTEGER NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT tenant_erasure_report_round_uq UNIQUE (request_id, round, mode),
    CONSTRAINT tenant_erasure_report_round_chk CHECK (round BETWEEN 1 AND 1000),
    CONSTRAINT tenant_erasure_report_mode_chk CHECK (mode IN ('dry_run', 'apply', 'verify')),
    CONSTRAINT tenant_erasure_report_outcome_chk CHECK (outcome IN ('ok', 'blocked', 'refused', 'failed')),
    CONSTRAINT tenant_erasure_report_code_chk CHECK (error_code IS NULL OR error_code ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT tenant_erasure_report_hash_chk CHECK (plan_hash IS NULL OR plan_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT tenant_erasure_report_body_chk CHECK (
        jsonb_typeof(body) = 'object' AND octet_length(body::text) <= 65536
    ),
    CONSTRAINT tenant_erasure_report_post_chk CHECK (
        (post_outcome IS NULL OR post_outcome ~ '^(accepted|refused:[a-z][a-z0-9_]{1,63})$')
        AND ((post_outcome = 'accepted') = (posted_at IS NOT NULL))
        AND post_attempts BETWEEN 0 AND 1000000
    )
);
CREATE INDEX IF NOT EXISTS tenant_erasure_report_unposted_idx ON crm.tenant_erasure_report (created_at)
    WHERE post_outcome IS NULL;
CREATE OR REPLACE TRIGGER tenant_erasure_report_set_updated_at
    BEFORE UPDATE ON crm.tenant_erasure_report
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
COMMENT ON TABLE crm.tenant_erasure_report IS 'AA-1093 stage 2 (crm-066): one report of the CRM step of a CIS tenant erasure request (tenant.erasure.v1 ErasureReport), unique per request, round and mode (dry_run | apply | verify): outcome ok | blocked | refused | failed, the error code, the plan hash, the body as computed (ids, codes, hashes, counts) and when it was computed. Written by job:crm_tenant_erase in the transaction that did the work (an apply''s report commits with the erase), then posted to CIS: post_outcome accepted (posted_at set) or refused:<the CIS problem code>; NULL = not posted yet (posted again with the same report_id and body). Platform table: no personal data; kept as the erasure record.';
COMMENT ON COLUMN crm.tenant_erasure_report.outcome IS 'the report''s status (ok | blocked | refused | failed); not named status: no crm.status_transition rows for a platform record';
COMMENT ON COLUMN crm.tenant_erasure_report.post_outcome IS 'NULL (not posted yet: the next run posts it again), accepted (CIS answered 200 / 201), refused:<code> (CIS answered 4xx with that problem code: settled, never posted again)';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-066', now(), 'AA-1093 stage 2: crm.tenant_erasure_feed_state, crm.tenant_erasure_saga, crm.tenant_erasure_report (the CRM step of the CIS tenant offboarding erasure saga, tenant.erasure.v1)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
