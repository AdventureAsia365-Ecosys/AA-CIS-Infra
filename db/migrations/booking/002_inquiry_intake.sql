-- Migration bk-002: AA-681 slice 2 — inquiry intake (TripPlanner inquiry.submitted → trip case).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy lives in AA-CIS-Infra
-- db/migrations/booking/002_inquiry_intake.sql and is applied to Dev by the DB Migrate workflow
-- (check, then apply), as aa_cis_admin, like bk-001. Never run it from a laptop.
--
-- Decisions it implements (Nghiep, S235, 14/10/2026 — ecosystem blueprint, docs/contracts/README.md):
--   * O3: Booking runs deferred work on its OWN table booking.job (same shape and claim semantics
--     as CIS shared.job, ADR 0003), so a Booking job never blocks the CIS deploy guard and a CIS
--     wave never blocks Booking.
--   * O9: Booking job kinds are prefixed bk_ (CHECK on booking.job.kind).
--   * O6: every inquiry opens a trip case for a customer; a TripPlanner contact that nobody has
--     verified becomes a LEAD row in booking.customers (verified = false, source
--     'tripplanner_lead'). Contract v1.1: an unverified contact must never be merged into an
--     existing customer automatically, so a lead whose email/phone matches an existing live
--     customer is created as a separate row flagged needs_merge_review (merge_candidate_id points
--     at the match). Email/phone uniqueness therefore applies to VERIFIED live customers only.
--   * Legacy hand-offs with customer = null (contract v1, deprecated by O6) stay parked in
--     booking.inbox_events (status 'parked'); they never become trip cases.
--   * Contract rule 4: the pull consumer anti-joins the outbox against booking.inbox_events and
--     keeps booking.inbox_cursor.safe_id only as a scan bound, advanced behind a lag window — never
--     the producer's BIGSERIAL id alone.
--
-- Scope: booking.job, booking.inbox_cursor, inbox_events.status (+ contract_version,
-- source_position), customer lead columns + verified-only uniqueness, trip_cases (first slice of
-- ERD v2, no trip_plan_id), trip_case_legs, notifications (staff queue, no e-mail yet).
-- Not here: trip_case_countries (needs country_profiles, O7), trip_case_status_history and the
-- transition trigger (status vocabulary still open), staff_users (O1: staff use the CIS login),
-- trip_case_versions and money (bk-003).
--
-- Status columns are TEXT + CHECK, not enum types (same reason as bk-001: cheap to change while
-- the vocabulary settles). The trip case statuses are ERD v2's booking.trip_case_status values.
--
-- Re-running the whole file is a no-op (IF NOT EXISTS / OR REPLACE / ADD COLUMN IF NOT EXISTS /
-- idempotent GRANT/REVOKE). Default privileges from bk-001 (FOR ROLE aa_cis_admin) cover every new
-- table and sequence; the explicit grants below repeat them so the file stands on its own.

BEGIN;

-- ── Job table (O3, O9) ───────────────────────────────────────────────────────
-- Same columns and ideas as CIS shared.job: claim = UPDATE ... WHERE id = (SELECT ... FOR UPDATE
-- SKIP LOCKED), a lease (locked_by / locked_until) renewed by the worker, a reaper that re-queues
-- expired leases while attempts remain, exponential backoff via run_after, idempotency_key unique
-- when set. Left out until a Booking job needs them: progress, cost_usd, cancel_requested,
-- parent_job_id and the job_worker registry.

CREATE TABLE IF NOT EXISTS booking.job (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind             TEXT NOT NULL,
    payload          JSONB NOT NULL DEFAULT '{}'::jsonb,
    status           TEXT NOT NULL DEFAULT 'queued',
    attempt          INTEGER NOT NULL DEFAULT 0,
    max_attempts     INTEGER NOT NULL DEFAULT 5,
    run_after        TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_by        TEXT,
    locked_until     TIMESTAMPTZ,
    idempotency_key  TEXT,
    result           JSONB,
    error            TEXT,
    created_by       TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at       TIMESTAMPTZ,
    finished_at      TIMESTAMPTZ,

    CONSTRAINT job_kind_chk CHECK (kind ~ '^bk_[a-z0-9_]+$'),
    CONSTRAINT job_status_chk CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
    CONSTRAINT job_attempts_chk CHECK (attempt >= 0 AND max_attempts >= 1),
    CONSTRAINT job_lease_chk CHECK (status <> 'running' OR (locked_by IS NOT NULL AND locked_until IS NOT NULL))
);

COMMENT ON TABLE booking.job IS
    'bk-002 (O3): Booking-owned job queue, same shape and claim semantics as CIS shared.job. Kinds are bk_* (O9).';

CREATE UNIQUE INDEX IF NOT EXISTS job_idempotency_key_uq
    ON booking.job (idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS job_due_idx
    ON booking.job (run_after, created_at) WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS job_lease_idx
    ON booking.job (locked_until) WHERE status = 'running';
CREATE INDEX IF NOT EXISTS job_kind_created_idx
    ON booking.job (kind, created_at DESC);
-- The pull is a recurring singleton: at most one queued or running bk_inquiry_pull at a time, so
-- the scheduler can simply INSERT ... ON CONFLICT DO NOTHING on every tick.
CREATE UNIQUE INDEX IF NOT EXISTS job_active_pull_uq
    ON booking.job (kind) WHERE kind = 'bk_inquiry_pull' AND status IN ('queued', 'running');

CREATE OR REPLACE TRIGGER job_set_updated_at
    BEFORE UPDATE ON booking.job
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Inbox (consumer side of the contracts) ───────────────────────────────────
-- bk-001 created inbox_events with processed_at / error. A row's outcome is now explicit:
--   received  — stored by the pull, a bk_inquiry_process job is queued;
--   processed — a trip case exists for it;
--   parked    — kept but deliberately not turned into a trip case (legacy customer = null, no
--               contact data) — staff can read the payload;
--   failed    — the payload does not satisfy the contract (validation error in `error`).

ALTER TABLE booking.inbox_events
    ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'received'
        CONSTRAINT inbox_events_status_chk CHECK (status IN ('received', 'processed', 'parked', 'failed')),
    ADD COLUMN IF NOT EXISTS contract_version TEXT,
    ADD COLUMN IF NOT EXISTS source_position BIGINT;

COMMENT ON COLUMN booking.inbox_events.source_position IS
    'Producer outbox id (tripplanner.outbox.id) — informational; never the only cursor (contract rule 4).';

CREATE INDEX IF NOT EXISTS inbox_events_status_idx
    ON booking.inbox_events (status, received_at DESC);

-- One row per (source, contract) the pull consumer reads. safe_id is a scan bound only: every
-- producer row with id <= safe_id is known to be in inbox_events. The pull still anti-joins the
-- inbox for id > safe_id, and only advances safe_id over rows older than its lag window, so a row
-- whose transaction committed late (lower id, later commit) is never skipped.
CREATE TABLE IF NOT EXISTS booking.inbox_cursor (
    source      TEXT NOT NULL,
    contract    TEXT NOT NULL,
    safe_id     BIGINT NOT NULL DEFAULT 0,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT inbox_cursor_pk PRIMARY KEY (source, contract),
    CONSTRAINT inbox_cursor_source_chk CHECK (source IN ('tripplanner', 'cis')),
    CONSTRAINT inbox_cursor_safe_id_chk CHECK (safe_id >= 0)
);

CREATE OR REPLACE TRIGGER inbox_cursor_set_updated_at
    BEFORE UPDATE ON booking.inbox_cursor
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Customers: leads (O6) ────────────────────────────────────────────────────

ALTER TABLE booking.customers
    ADD COLUMN IF NOT EXISTS verified BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'manual'
        CONSTRAINT customers_source_chk CHECK (source IN ('manual', 'otp', 'tripplanner_lead')),
    ADD COLUMN IF NOT EXISTS needs_merge_review BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS merge_candidate_id UUID REFERENCES booking.customers (id),
    ADD COLUMN IF NOT EXISTS external_ref TEXT,
    ADD COLUMN IF NOT EXISTS contact_consent BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS contact_consent_at TIMESTAMPTZ;

COMMENT ON COLUMN booking.customers.verified IS
    'true only after Booking verified the contact by OTP (AA-680). Leads from TripPlanner start false.';
COMMENT ON COLUMN booking.customers.needs_merge_review IS
    'Lead whose email/phone matched an existing live customer: never merged automatically (contract v1.1); staff or the OTP sign-in decides.';
COMMENT ON COLUMN booking.customers.external_ref IS
    'Producer-side id when known, e.g. tripplanner.customers.id from inquiry.submitted (customer_id).';

-- bk-001 made email/phone unique among ALL live rows. A lead is an unverified contact snapshot and
-- may repeat an existing customer's email (that is exactly the case that must not be merged), so
-- uniqueness now holds among verified live customers only.
DROP INDEX IF EXISTS booking.customers_email_live_uq;
DROP INDEX IF EXISTS booking.customers_phone_live_uq;
CREATE UNIQUE INDEX IF NOT EXISTS customers_email_verified_uq
    ON booking.customers (lower(email)) WHERE email IS NOT NULL AND deleted_at IS NULL AND verified;
CREATE UNIQUE INDEX IF NOT EXISTS customers_phone_verified_uq
    ON booking.customers (phone) WHERE phone IS NOT NULL AND deleted_at IS NULL AND verified;
CREATE INDEX IF NOT EXISTS customers_email_lookup_idx
    ON booking.customers (lower(email)) WHERE email IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS customers_phone_lookup_idx
    ON booking.customers (phone) WHERE phone IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS customers_merge_review_idx
    ON booking.customers (created_at DESC) WHERE needs_merge_review AND deleted_at IS NULL;

-- ── Trip cases (first slice of ERD v2) ───────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS booking.trip_case_code_seq;

CREATE TABLE IF NOT EXISTS booking.trip_cases (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code              TEXT NOT NULL DEFAULT ('TC-' || lpad(nextval('booking.trip_case_code_seq')::text, 6, '0')),
    customer_id       UUID NOT NULL REFERENCES booking.customers (id),
    status            TEXT NOT NULL DEFAULT 'new_inquiry',
    trip_style        TEXT,
    start_date        DATE,
    end_date          DATE,
    pax               SMALLINT,
    currency          CHAR(3),
    source_system     TEXT NOT NULL DEFAULT 'manual',
    source_id         TEXT,
    idempotency_key   TEXT,
    inbox_event_id    UUID REFERENCES booking.inbox_events (id),
    inquiry_snapshot  JSONB,
    created_by        UUID,                        -- staff id; no FK until staff identity (O1) lands
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,

    CONSTRAINT trip_cases_code_uq UNIQUE (code),
    CONSTRAINT trip_cases_idempotency_key_uq UNIQUE (idempotency_key),
    CONSTRAINT trip_cases_status_chk CHECK (status IN (
        'new_inquiry', 'discovery', 'building', 'proposal_sent', 'confirmed', 'supplier_confirming',
        'invoice_sent', 'payment_pending', 'paid', 'pre_departure', 'on_trip', 'completed', 'cancelled')),
    CONSTRAINT trip_cases_source_system_chk CHECK (source_system IN ('cis', 'tripplanner', 'manual')),
    CONSTRAINT trip_cases_dates_chk CHECK (start_date IS NULL OR end_date IS NULL OR start_date <= end_date),
    CONSTRAINT trip_cases_pax_chk CHECK (pax IS NULL OR pax > 0),
    CONSTRAINT trip_cases_currency_chk CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$')
);

COMMENT ON TABLE booking.trip_cases IS
    'bk-002: customer container (ERD v2 first slice, no trip_plan_id yet). Opened by bk_inquiry_process from inquiry.submitted.';
COMMENT ON COLUMN booking.trip_cases.inquiry_snapshot IS
    'Itinerary of the inquiry as received (days, custom_days) for staff; legs are also normalised into trip_case_legs.';

CREATE INDEX IF NOT EXISTS trip_cases_customer_idx
    ON booking.trip_cases (customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS trip_cases_status_idx
    ON booking.trip_cases (status, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS trip_cases_source_idx
    ON booking.trip_cases (source_system, source_id);

CREATE OR REPLACE TRIGGER trip_cases_set_updated_at
    BEFORE UPDATE ON booking.trip_cases
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- TripPlanner leg chain (ADR 0001 decision 5). source_tour_id is TEXT, not UUID as in ERD v2: the
-- contract types it as a string and nothing here may reject a customer's inquiry over its format.
CREATE TABLE IF NOT EXISTS booking.trip_case_legs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_case_id    UUID NOT NULL REFERENCES booking.trip_cases (id) ON DELETE CASCADE,
    position        SMALLINT NOT NULL,
    source_tour_id  TEXT NOT NULL,
    day_from        SMALLINT NOT NULL,
    day_to          SMALLINT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT trip_case_legs_position_uq UNIQUE (trip_case_id, position),
    CONSTRAINT trip_case_legs_position_chk CHECK (position >= 1)
);

-- ── Notifications (staff queue; no e-mail yet) ───────────────────────────────
-- recipient_id NULL with recipient_type 'staff' = the shared sales queue (no staff identity until O1).

CREATE TABLE IF NOT EXISTS booking.notifications (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient_type  TEXT NOT NULL,
    recipient_id    UUID,
    type            TEXT NOT NULL,
    title           TEXT NOT NULL,
    message         TEXT,
    entity_type     TEXT,
    entity_id       UUID,
    data            JSONB NOT NULL DEFAULT '{}'::jsonb,
    read_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT notifications_recipient_type_chk CHECK (recipient_type IN ('customer', 'staff')),
    CONSTRAINT notifications_customer_recipient_chk CHECK (recipient_type <> 'customer' OR recipient_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS notifications_unread_idx
    ON booking.notifications (recipient_type, recipient_id, created_at DESC) WHERE read_at IS NULL;

-- ── Explicit grants (default privileges already cover these; repeated for a standalone file) ──

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA booking TO booking;
GRANT USAGE, SELECT ON SEQUENCE booking.trip_case_code_seq TO booking;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_schema_versions FROM booking;
REVOKE UPDATE, DELETE, TRUNCATE ON booking.audit_logs FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-002', now(), 'AA-681 slice 2: booking.job (O3, bk_ kinds O9), inbox_cursor + inbox_events.status, customer leads (verified, needs_merge_review, email/phone unique among verified only), trip_cases, trip_case_legs, notifications')
ON CONFLICT (version) DO NOTHING;

COMMIT;
