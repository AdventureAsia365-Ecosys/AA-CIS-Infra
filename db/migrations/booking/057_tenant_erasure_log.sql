-- Migration bk-057: AA-1093 lane L3 — the Booking half of the tenant offboarding erasure (root plan
-- docs/audits/2026-11-13-S279-session/aa1093-plan.md Part 2; tech lead decisions D3 and D8, S279; contract
-- tenant.erasure.v1, root docs/contracts/tenant.erasure.v1.openapi.yaml): the append-only erasure log, the report view
-- CIS reads, the tenant scope of an erasure, and the narrow, scoped write paths the anonymisation needs on append-only
-- and money tables.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/057_tenant_erasure_log.sql; on Dev it is applied as bk_owner (the live owner of schema booking
-- since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Depends on bk-001 (audit_logs, set_updated_at), bk-003 (trip_case_status_history), bk-014 (bk_owner), bk-017
-- (USAGE on schema booking for cis_app), bk-041 / bk-042 (agency_invoice, agency_payment and its guard) and bk-047
-- (b2b_cancellations). bk-058 is the next free key (the B2C table drop takes it).
--
-- What:
--   1. booking.tenant_erasure_log: APPEND-ONLY, one row per report (contract ErasureReportRow): report_id, request_id,
--      tenant_id, app ('booking'), round, mode (dry_run | apply | verify), status (ok | blocked | refused | failed),
--      error_code (a code, NULL exactly when ok), plan_hash (64 hex; NULL on verify), tables (jsonb array of
--      {table, action, rows, digest}), blockers (jsonb array of {code, count}), census (jsonb, verify only), source
--      (cis = a request of catalog.v_tenant_erasure_v1, cli = python -m app.b2b.tenant_erase), job_id, reported_at.
--      Ids, codes, counts and hashes only: no name, no note, no row value. Role booking: SELECT and INSERT only (no
--      UPDATE, no DELETE: each DRY RUN, apply and verification is a new row, the log is the record that the agency was
--      erased, and bk_tenant_pull reads it to never write the agency name back). Row level security ENABLE + FORCE like
--      booking.b2b_partners (bk-049 / bk-053; the tenant_id rule of the RLS catalogue guard): the back office (no
--      app.tenant_id bound) reads and writes every row; a session that binds app.tenant_id reads its own rows only and
--      writes none.
--   2. booking.v_tenant_erasure_report_v1 (contract ErasureReportRow, exact column order): report_id, request_id,
--      tenant_id, app, round, mode, status, error_code, plan_hash, tables, blockers, census, job_id, reported_at.
--      SELECT to booking and to the CIS runtime role cis_app (the tenant_erasure_saga keeps the newest row of each
--      (app, round, mode); AA-CIS-Infra db/owners.yaml booking.consumer_grants + the isolation probe cell
--      consumer.contract_grants.bk-057).
--   3. booking.tenant_erase_scope(tenant) (SQL, STABLE, SECURITY INVOKER): the ids of every row of the agency's B2B
--      footprint (its B2B trip cases and their checks, supplier bookings and versions; its partner row and the
--      partner's quotes, holds, desk bookings, cancellations and departure fees; its agency invoices and their
--      payments). app.b2b.tenant_erase redacts the notifications and audit rows of exactly these ids, and the
--      audit_logs guard below accepts only these ids, so the app and the guard cannot disagree on the scope.
--   4. booking.tenant_erase_tenant() (plpgsql, STABLE, SECURITY INVOKER): the opening of an erasure. NULL when the
--      transaction did not set booking.tenant_erase. Otherwise the setting must be the report_id of a DRY RUN report
--      of status ok in the log and no tenant may be bound (app.tenant_id), and it returns that report's tenant; any
--      other value raises 42501. So a session that sets the GUC by hand reaches nothing unless an ok DRY RUN of that
--      tenant is on the append-only log (which role booking can never remove), and only that tenant's rows.
--   5. booking.audit_logs stays append-only for everything but a tenant erasure: role booking gets UPDATE on before,
--      after, entity_label and summary only; the BEFORE UPDATE trigger audit_logs_erase_guard refuses any update unless
--      tenant_erase_tenant() opens one AND the row's entity_id is in that tenant's scope, and then lets through only
--      the redaction: before / after NULL or {"redacted":"tenant_erased"}, entity_label NULL or unchanged, summary
--      NULL, '[redacted]' or unchanged (a staff summary can carry a cancel reason or a check title); every other
--      column unchanged.
--   6. booking.trip_case_status_history (a status note can carry a cancel reason): role booking gets UPDATE on note
--      only, and trip_case_status_history_erase_guard lets through only note -> NULL inside an opened erasure, on a
--      row of one of that tenant's B2B trip cases.
--   7. booking.agency_payment_guard() (bk-042) is replaced with one added branch, first in the UPDATE path: inside an
--      opened erasure, on a payment of an invoice of that tenant, note -> NULL and reject_reason -> '[redacted]' with
--      every other column unchanged (DM-7.1: the free text of the agency's money rows is redacted on its erasure; the
--      amounts, the references and the decision stay under the accounting exception). Everything else is bk-042
--      verbatim. The invoice side needs no change: bk-042 already leaves staff_note and void_reason editable.
--
-- Class: contract (root ADR 0017 d3): new triggers, a replaced guard and column grants on existing tables and a
-- cross-owner grant. On Dev Migration Apply applies it when the job tables are idle (ADR 0017a); the code PR raises
-- readiness to bk-057 (MIG-4).
-- DM-6.1: no personal data in the new table (ids, codes, counts, hashes). DM-7.1: one new table, its retention row is
-- in the root data standards (02-data-management.md, booking.tenant_erasure_log).
-- Locks: CREATE TRIGGER takes SHARE ROW EXCLUSIVE on audit_logs and trip_case_status_history (hundreds of rows, an
-- instant); CREATE OR REPLACE FUNCTION locks nothing; lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS, CREATE OR REPLACE, DROP ... IF EXISTS,
-- repeatable grants.
-- Undo (a later bk- file, after the code and the CIS reader are reverted): DROP VIEW booking.v_tenant_erasure_report_v1;
-- DROP the two erase guard triggers and functions; restore the bk-042 body of agency_payment_guard; DROP the two
-- tenant_erase_* functions; REVOKE UPDATE (before, after, entity_label, summary) ON booking.audit_logs and UPDATE
-- (note) ON booking.trip_case_status_history FROM booking; the log table stays (the erasure record).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-057: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.audit_logs') IS NULL OR to_regclass('booking.trip_case_status_history') IS NULL
       OR to_regclass('booking.agency_payment') IS NULL OR to_regclass('booking.b2b_cancellations') IS NULL THEN
        RAISE EXCEPTION 'bk-057: needs bk-001, bk-003, bk-041 and bk-047 first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-057' AND description NOT LIKE 'AA-1093 tenant erasure:%') THEN
        RAISE EXCEPTION 'bk-057: the key bk-057 is already held by another migration (not AA-1093): renumber one';
    END IF;
END $$;

-- ── 1. The erasure log (append-only) ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS booking.tenant_erasure_log (
    report_id   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id  UUID        NOT NULL,
    tenant_id   UUID        NOT NULL,
    app         TEXT        NOT NULL DEFAULT 'booking',
    round       INTEGER     NOT NULL,
    mode        TEXT        NOT NULL,
    status      TEXT        NOT NULL,
    error_code  TEXT,
    plan_hash   TEXT,
    tables      JSONB       NOT NULL DEFAULT '[]'::jsonb,
    blockers    JSONB       NOT NULL DEFAULT '[]'::jsonb,
    census      JSONB,
    source      TEXT        NOT NULL,
    job_id      UUID,
    reported_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT tenant_erasure_log_app_chk CHECK (app = 'booking'),
    CONSTRAINT tenant_erasure_log_round_chk CHECK (round >= 1),
    CONSTRAINT tenant_erasure_log_mode_chk CHECK (mode IN ('dry_run', 'apply', 'verify')),
    CONSTRAINT tenant_erasure_log_status_chk CHECK (status IN ('ok', 'blocked', 'refused', 'failed')),
    CONSTRAINT tenant_erasure_log_code_chk CHECK (
        (status = 'ok') = (error_code IS NULL) AND (error_code IS NULL OR error_code ~ '^[a-z][a-z0-9_]{1,63}$')),
    CONSTRAINT tenant_erasure_log_hash_chk CHECK (
        (plan_hash IS NULL OR plan_hash ~ '^[0-9a-f]{64}$')
        AND (mode <> 'verify' OR plan_hash IS NULL)
        AND (mode = 'verify' OR status <> 'ok' OR plan_hash IS NOT NULL)),
    CONSTRAINT tenant_erasure_log_json_chk CHECK (
        jsonb_typeof(tables) = 'array' AND jsonb_typeof(blockers) = 'array'
        AND jsonb_array_length(tables) <= 500 AND jsonb_array_length(blockers) <= 50),
    CONSTRAINT tenant_erasure_log_census_chk CHECK (
        (census IS NULL OR (mode = 'verify' AND jsonb_typeof(census) = 'object'))
        AND (mode <> 'verify' OR status <> 'ok' OR census IS NOT NULL)),
    CONSTRAINT tenant_erasure_log_source_chk CHECK (source IN ('cis', 'cli'))
);

CREATE INDEX IF NOT EXISTS tenant_erasure_log_request_idx
    ON booking.tenant_erasure_log (request_id, round, mode, reported_at DESC);
CREATE INDEX IF NOT EXISTS tenant_erasure_log_applied_idx
    ON booking.tenant_erasure_log (tenant_id) WHERE mode = 'apply' AND status = 'ok';

COMMENT ON TABLE booking.tenant_erasure_log IS
    'AA-1093 (bk-057, contract tenant.erasure.v1 ErasureReportRow): append-only, one row per DRY RUN, apply or '
    'verification of app.b2b.tenant_erase (job bk_tenant_erase, or the CLI). Ids, codes, counts and hashes only. An '
    'apply row of status ok makes bk_tenant_pull skip the agency (the erased name is never written back). Role booking '
    'inserts and reads, never updates or deletes.';
COMMENT ON COLUMN booking.tenant_erasure_log.request_id IS
    'The CIS erasure request (catalog.v_tenant_erasure_v1), or a UUIDv5 of the tenant for a CLI run.';
COMMENT ON COLUMN booking.tenant_erasure_log.plan_hash IS
    'sha256 hex of ''tenant.erasure.v1|<tenant>|<round>'' and the sorted ''<table>|<action>|<rows>|<digest>'' lines '
    '(contract tenant.erasure.v1); NULL on verify.';
COMMENT ON COLUMN booking.tenant_erasure_log.tables IS
    'Contract TableEntry list: {table, action, rows, digest}; digest = md5 of the sorted ''<id>|<updated_at UTC>'' lines.';
COMMENT ON COLUMN booking.tenant_erasure_log.error_code IS
    'A code (plan_changed, approval_expired, not_due, pilot_refused, not_synthetic, apply_disabled, census_not_zero, '
    'internal_error, ...), never free text; NULL exactly when the status is ok.';

ALTER TABLE booking.tenant_erasure_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking.tenant_erasure_log FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_erasure_log_back_office ON booking.tenant_erasure_log;
CREATE POLICY tenant_erasure_log_back_office ON booking.tenant_erasure_log
    AS PERMISSIVE FOR ALL TO booking, bk_owner
    USING (NULLIF(current_setting('app.tenant_id', true), '') IS NULL)
    WITH CHECK (NULLIF(current_setting('app.tenant_id', true), '') IS NULL);

DROP POLICY IF EXISTS tenant_erasure_log_tenant ON booking.tenant_erasure_log;
CREATE POLICY tenant_erasure_log_tenant ON booking.tenant_erasure_log
    AS PERMISSIVE FOR SELECT TO booking, bk_owner
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

COMMENT ON POLICY tenant_erasure_log_back_office ON booking.tenant_erasure_log IS
    'bk-057 (AA-1093): the back office (jobs, the CLI, the report view read by cis_app) with no tenant bound: every row.';
COMMENT ON POLICY tenant_erasure_log_tenant ON booking.tenant_erasure_log IS
    'bk-057 (AA-1093): a session that binds app.tenant_id reads that tenant''s rows only and writes none.';

REVOKE UPDATE, DELETE, TRUNCATE ON booking.tenant_erasure_log FROM booking;
GRANT SELECT, INSERT ON booking.tenant_erasure_log TO booking;

-- ── 2. The report view CIS reads ─────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW booking.v_tenant_erasure_report_v1 AS
SELECT report_id, request_id, tenant_id, app, round, mode, status, error_code, plan_hash, tables, blockers, census,
       job_id, reported_at
  FROM booking.tenant_erasure_log;

COMMENT ON VIEW booking.v_tenant_erasure_report_v1 IS
    'AA-1093 (bk-057, contract tenant.erasure.v1 ErasureReportRow): the Booking erasure reports for the CIS '
    'tenant_erasure_saga, one row per report (append-only log); CIS keeps the newest of each (app, round, mode). Ids, '
    'codes, counts and hashes only. Columns are only appended.';

REVOKE INSERT, UPDATE, DELETE ON booking.v_tenant_erasure_report_v1 FROM booking;
GRANT SELECT ON booking.v_tenant_erasure_report_v1 TO booking;
GRANT USAGE ON SCHEMA booking TO cis_app;
GRANT SELECT ON booking.v_tenant_erasure_report_v1 TO cis_app;

-- ── 3. The tenant scope of an erasure ────────────────────────────────────────────────────────────────────────────
-- Plain SQL, no SET clause and fully qualified names, so the planner can inline it into the caller's query.
CREATE OR REPLACE FUNCTION booking.tenant_erase_scope(p_tenant uuid) RETURNS SETOF uuid
    LANGUAGE sql
    STABLE
AS $$
    WITH cases AS (
        SELECT id FROM booking.trip_cases WHERE channel = 'b2b' AND party_tenant_id = p_tenant
    ), partner AS (
        SELECT id FROM booking.b2b_partners WHERE tenant_id = p_tenant
    ), invoices AS (
        SELECT id FROM booking.agency_invoice WHERE party_tenant_id = p_tenant
    )
    SELECT id FROM cases
    UNION ALL SELECT id FROM booking.trip_case_checks WHERE trip_case_id IN (SELECT id FROM cases)
    UNION ALL SELECT id FROM booking.supplier_bookings WHERE trip_case_id IN (SELECT id FROM cases)
    UNION ALL SELECT id FROM booking.trip_case_versions WHERE trip_case_id IN (SELECT id FROM cases)
    UNION ALL SELECT id FROM partner
    UNION ALL SELECT id FROM booking.b2b_quotes WHERE partner_id IN (SELECT id FROM partner)
    UNION ALL SELECT id FROM booking.b2b_holds WHERE partner_id IN (SELECT id FROM partner)
    UNION ALL SELECT id FROM booking.b2b_desk_bookings WHERE partner_id IN (SELECT id FROM partner)
    UNION ALL SELECT id FROM booking.b2b_cancellations WHERE partner_id IN (SELECT id FROM partner)
    UNION ALL SELECT id FROM booking.departure_fees WHERE partner_id IN (SELECT id FROM partner)
    UNION ALL SELECT id FROM invoices
    UNION ALL SELECT id FROM booking.agency_payment WHERE invoice_id IN (SELECT id FROM invoices)
$$;

COMMENT ON FUNCTION booking.tenant_erase_scope(uuid) IS
    'bk-057 (AA-1093): ids of the agency''s B2B footprint (cases, checks, supplier bookings, versions, partner, quotes, '
    'holds, desk bookings, cancellations, departure fees, agency invoices and payments). The erasure redacts the '
    'notifications and audit rows of exactly these ids; the audit_logs erase guard accepts only these ids.';

REVOKE ALL ON FUNCTION booking.tenant_erase_scope(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION booking.tenant_erase_scope(uuid) TO booking;

-- ── 4. The opening of an erasure ─────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION booking.tenant_erase_tenant() RETURNS uuid
    LANGUAGE plpgsql
    STABLE
    SET search_path = pg_catalog
AS $$
DECLARE
    v_setting text := NULLIF(current_setting('booking.tenant_erase', true), '');
    v_tenant  uuid;
BEGIN
    IF v_setting IS NULL THEN
        RETURN NULL;
    END IF;
    IF NULLIF(current_setting('app.tenant_id', true), '') IS NOT NULL THEN
        RAISE EXCEPTION 'a tenant erasure never runs with a tenant bound (bk-057)' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF v_setting !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RAISE EXCEPTION 'booking.tenant_erase must be the report id of an ok DRY RUN (bk-057)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT l.tenant_id INTO v_tenant
      FROM booking.tenant_erasure_log l
     WHERE l.report_id = v_setting::uuid AND l.mode = 'dry_run' AND l.status = 'ok';
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'booking.tenant_erase names no ok DRY RUN report of the erasure log (bk-057)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v_tenant;
END $$;

COMMENT ON FUNCTION booking.tenant_erase_tenant() IS
    'bk-057 (AA-1093): NULL outside a tenant erasure; inside one (booking.tenant_erase set, no tenant bound) the tenant '
    'of the ok DRY RUN report the setting names; any other value raises 42501.';

REVOKE ALL ON FUNCTION booking.tenant_erase_tenant() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION booking.tenant_erase_tenant() TO booking;

-- ── 5. audit_logs: append-only except the scoped erasure redaction ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION booking.audit_logs_erase_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_marker CONSTANT jsonb := '{"redacted": "tenant_erased"}'::jsonb;
    v_tenant uuid := booking.tenant_erase_tenant();
BEGIN
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'booking.audit_logs is append-only (bk-001): only a tenant erasure redacts a row (bk-057)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF OLD.entity_id IS NULL OR NOT EXISTS (
           SELECT 1 FROM booking.tenant_erase_scope(v_tenant) AS s(id) WHERE s.id = OLD.entity_id) THEN
        RAISE EXCEPTION 'audit row %: its entity is not in the erased tenant''s scope', OLD.id
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF (NEW.id, NEW.actor_type, NEW.actor_id, NEW.actor_ref, NEW.action, NEW.entity_type, NEW.entity_id,
        NEW.created_at)
       IS DISTINCT FROM (OLD.id, OLD.actor_type, OLD.actor_id, OLD.actor_ref, OLD.action, OLD.entity_type,
                         OLD.entity_id, OLD.created_at) THEN
        RAISE EXCEPTION 'audit row %: a tenant erasure redacts before / after / entity_label / summary only', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF (NEW.before IS NOT NULL AND NEW.before <> v_marker) OR (NEW.after IS NOT NULL AND NEW.after <> v_marker)
       OR (NEW.entity_label IS NOT NULL AND NEW.entity_label IS DISTINCT FROM OLD.entity_label)
       OR (NEW.summary IS NOT NULL AND NEW.summary <> '[redacted]' AND NEW.summary IS DISTINCT FROM OLD.summary) THEN
        RAISE EXCEPTION 'audit row %: a tenant erasure writes only NULL or the redaction marker', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.audit_logs_erase_guard() IS
    'bk-057 (AA-1093): audit_logs stays append-only; inside an opened tenant erasure (tenant_erase_tenant()) an update '
    'of a row whose entity is in that tenant''s scope may only set before / after to NULL or {"redacted":"tenant_erased"}, '
    'entity_label to NULL and summary to NULL or ''[redacted]''.';

DROP TRIGGER IF EXISTS audit_logs_erase_guard ON booking.audit_logs;
CREATE TRIGGER audit_logs_erase_guard
    BEFORE UPDATE ON booking.audit_logs FOR EACH ROW EXECUTE FUNCTION booking.audit_logs_erase_guard();

GRANT UPDATE (before, after, entity_label, summary) ON booking.audit_logs TO booking;

-- ── 6. trip_case_status_history: the note is cleared inside a scoped erasure ─────────────────────────────────────
CREATE OR REPLACE FUNCTION booking.trip_case_status_history_erase_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_tenant uuid := booking.tenant_erase_tenant();
BEGIN
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'booking.trip_case_status_history is append-only: only a tenant erasure clears a note (bk-057)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM booking.trip_cases c
                    WHERE c.id = OLD.trip_case_id AND c.channel = 'b2b' AND c.party_tenant_id = v_tenant) THEN
        RAISE EXCEPTION 'status history row %: not a B2B trip case of the erased tenant', OLD.id
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.note IS NOT NULL
       OR (NEW.id, NEW.trip_case_id, NEW.from_status, NEW.to_status, NEW.changed_by, NEW.changed_at, NEW.seq)
          IS DISTINCT FROM (OLD.id, OLD.trip_case_id, OLD.from_status, OLD.to_status, OLD.changed_by, OLD.changed_at,
                            OLD.seq) THEN
        RAISE EXCEPTION 'status history row %: a tenant erasure only clears the note', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.trip_case_status_history_erase_guard() IS
    'bk-057 (AA-1093): the status history stays append-only; inside an opened tenant erasure an update of a row of one '
    'of that tenant''s B2B trip cases may only set note to NULL.';

DROP TRIGGER IF EXISTS trip_case_status_history_erase_guard ON booking.trip_case_status_history;
CREATE TRIGGER trip_case_status_history_erase_guard
    BEFORE UPDATE ON booking.trip_case_status_history FOR EACH ROW
    EXECUTE FUNCTION booking.trip_case_status_history_erase_guard();

GRANT UPDATE (note) ON booking.trip_case_status_history TO booking;

-- ── 7. agency_payment: the bk-042 guard plus the scoped erasure of its free text ─────────────────────────────────
CREATE OR REPLACE FUNCTION booking.agency_payment_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_status   text;
    v_currency text;
    v_total    numeric;
    v_approved numeric;
    v_party    uuid;
    v_erase    uuid;
BEGIN
    -- Lock the invoice first: two approvals of one invoice never race past its total.
    SELECT status, currency, total, party_tenant_id INTO v_status, v_currency, v_total, v_party
      FROM booking.agency_invoice WHERE id = NEW.invoice_id FOR UPDATE;
    IF TG_OP = 'INSERT' THEN
        IF v_status IS DISTINCT FROM 'issued' THEN
            RAISE EXCEPTION 'agency_payment: recorded against an issued invoice only (this one is %)',
                coalesce(v_status, 'missing') USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.currency IS DISTINCT FROM v_currency THEN
            RAISE EXCEPTION 'agency_payment: in the invoice currency %', v_currency USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.status <> 'recorded' THEN
            RAISE EXCEPTION 'agency_payment: a payment starts recorded' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    -- bk-057 (AA-1093): inside an opened tenant erasure, on a payment of that tenant's invoice, only the free text
    -- is redacted (note -> NULL, reject_reason -> '[redacted]'); amounts, references and the decision stay.
    v_erase := booking.tenant_erase_tenant();
    IF v_erase IS NOT NULL THEN
        IF v_party IS DISTINCT FROM v_erase THEN
            RAISE EXCEPTION 'agency_payment %: not a payment of the erased tenant', OLD.id
                USING ERRCODE = 'insufficient_privilege';
        END IF;
        IF (NEW.id, NEW.invoice_id, NEW.amount, NEW.currency, NEW.method, NEW.received_on, NEW.reference,
            NEW.document_ref, NEW.status, NEW.recorded_by, NEW.recorded_at, NEW.approved_by, NEW.approved_at,
            NEW.rejected_by, NEW.rejected_at, NEW.idempotency_key, NEW.created_at)
           IS DISTINCT FROM
           (OLD.id, OLD.invoice_id, OLD.amount, OLD.currency, OLD.method, OLD.received_on, OLD.reference,
            OLD.document_ref, OLD.status, OLD.recorded_by, OLD.recorded_at, OLD.approved_by, OLD.approved_at,
            OLD.rejected_by, OLD.rejected_at, OLD.idempotency_key, OLD.created_at)
           OR NEW.note IS NOT NULL
           OR (NEW.reject_reason IS DISTINCT FROM OLD.reject_reason AND NEW.reject_reason IS DISTINCT FROM '[redacted]')
        THEN
            RAISE EXCEPTION 'agency_payment %: a tenant erasure only redacts note and reject_reason', OLD.id
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF (NEW.id, NEW.invoice_id, NEW.amount, NEW.currency, NEW.method, NEW.received_on, NEW.reference,
        NEW.document_ref, NEW.note, NEW.recorded_by, NEW.recorded_at, NEW.idempotency_key, NEW.created_at)
       IS DISTINCT FROM
       (OLD.id, OLD.invoice_id, OLD.amount, OLD.currency, OLD.method, OLD.received_on, OLD.reference,
        OLD.document_ref, OLD.note, OLD.recorded_by, OLD.recorded_at, OLD.idempotency_key, OLD.created_at) THEN
        RAISE EXCEPTION 'agency_payment: a recorded payment keeps its facts' USING ERRCODE = 'restrict_violation';
    END IF;
    IF OLD.status <> 'recorded' THEN
        RAISE EXCEPTION 'agency_payment: the decision (%) is final', OLD.status USING ERRCODE = 'restrict_violation';
    END IF;
    IF NEW.status = 'approved' THEN
        IF v_status IS DISTINCT FROM 'issued' THEN
            RAISE EXCEPTION 'agency_payment: the invoice is % (approve against an issued invoice)',
                coalesce(v_status, 'missing') USING ERRCODE = 'check_violation';
        END IF;
        SELECT coalesce(sum(amount), 0) INTO v_approved
          FROM booking.agency_payment WHERE invoice_id = NEW.invoice_id AND status = 'approved' AND id <> NEW.id;
        IF v_approved + NEW.amount > v_total THEN
            RAISE EXCEPTION 'agency_payment: approving % would take the approved total above the invoice total %',
                NEW.amount, v_total USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END
$$;
COMMENT ON FUNCTION booking.agency_payment_guard() IS
    'AA-1037 (bk-042): recorded against an issued invoice in its currency; facts never change; one decision, final; '
    'approved payments never exceed the invoice total (the invoice row is locked first). bk-057 (AA-1093): inside an '
    'opened tenant erasure, on that tenant''s payments, only note -> NULL and reject_reason -> ''[redacted]''.';

REVOKE ALL ON FUNCTION booking.agency_payment_guard() FROM PUBLIC;

-- ── Post-check ───────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    cols text;
BEGIN
    IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class
             WHERE oid = 'booking.tenant_erasure_log'::regclass) THEN
        RAISE EXCEPTION 'bk-057: row level security is not enabled and forced on booking.tenant_erasure_log';
    END IF;
    IF has_table_privilege('booking', 'booking.tenant_erasure_log', 'DELETE')
       OR has_table_privilege('booking', 'booking.tenant_erasure_log', 'UPDATE')
       OR has_any_column_privilege('booking', 'booking.tenant_erasure_log', 'UPDATE')
       OR has_table_privilege('cis_app', 'booking.tenant_erasure_log', 'SELECT') THEN
        RAISE EXCEPTION 'bk-057: the erasure log is not append-only for booking, or cis_app can read the table';
    END IF;
    IF NOT has_table_privilege('cis_app', 'booking.v_tenant_erasure_report_v1', 'SELECT') THEN
        RAISE EXCEPTION 'bk-057: cis_app cannot read booking.v_tenant_erasure_report_v1';
    END IF;
    IF has_table_privilege('booking', 'booking.v_tenant_erasure_report_v1', 'INSERT') THEN
        RAISE EXCEPTION 'bk-057: booking.v_tenant_erasure_report_v1 is writable';
    END IF;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a
     WHERE a.attrelid = 'booking.v_tenant_erasure_report_v1'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM
       'report_id,request_id,tenant_id,app,round,mode,status,error_code,plan_hash,tables,blockers,census,job_id,'
       'reported_at' THEN
        RAISE EXCEPTION 'bk-057: booking.v_tenant_erasure_report_v1 columns are % (contract ErasureReportRow)', cols;
    END IF;
    IF has_table_privilege('booking', 'booking.audit_logs', 'UPDATE')
       OR has_column_privilege('booking', 'booking.audit_logs', 'action', 'UPDATE')
       OR has_column_privilege('booking', 'booking.audit_logs', 'entity_id', 'UPDATE')
       OR has_table_privilege('booking', 'booking.trip_case_status_history', 'UPDATE')
       OR has_column_privilege('booking', 'booking.trip_case_status_history', 'to_status', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-057: role booking can update more than the erasure columns of an append-only table';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc
                WHERE pronamespace = 'booking'::regnamespace AND prosecdef
                  AND proname IN ('tenant_erase_scope', 'tenant_erase_tenant', 'audit_logs_erase_guard',
                                  'trip_case_status_history_erase_guard', 'agency_payment_guard')) THEN
        RAISE EXCEPTION 'bk-057: an erasure function is SECURITY DEFINER (bk-014: never in schema booking)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-057', now(), 'AA-1093 tenant erasure: append-only booking.tenant_erasure_log (RLS) + booking.v_tenant_erasure_report_v1 (contract tenant.erasure.v1, reader cis_app), tenant scope + opening functions, scoped erase guards on audit_logs, trip_case_status_history and agency_payment')
ON CONFLICT (version) DO NOTHING;

COMMIT;
