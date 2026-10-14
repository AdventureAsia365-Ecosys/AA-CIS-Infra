-- Migration bk-003: AA-680 (staff half) + AA-681 slice 3 — staff profiles, trip case workflow, versions.
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy lives in AA-CIS-Infra
-- db/migrations/booking/003_staff_trip_case_workflow.sql and is applied to Dev by the DB Migrate
-- workflow (check, then apply), as aa_cis_admin, like bk-001/bk-002. Never run it from a laptop.
--
-- Decisions it implements (ADR 0004 O1, ERD v2, docs/implementation-notes/AA-681-slice3.md):
--   * O1: staff log in through CIS (shared.admin_users). Booking keeps a THIN profile keyed by the
--     CIS user id (the staff JWT `sub`), with the Booking role and an active flag — no password.
--     Rows are provisioned by the API on the first valid token: CIS admin -> active admin; any other
--     CIS role -> an inactive row until a Booking admin activates it.
--   * Status workflow: allowed edges in booking.trip_case_status_transitions (read-only for the
--     app); a BEFORE UPDATE trigger rejects any other edge, an AFTER trigger writes
--     booking.trip_case_status_history. Actor and reason come from the transaction-local settings
--     booking.actor / booking.status_note. Only the pre-sale edges are seeded; post-sale edges come
--     with operations and payments (AA-682).
--   * Staff assignments, proposal versions (one approved per case, locked once approved) and
--     free-text version items (catalog references arrive with AA-679).
--   * audit_logs.actor_ref: the CIS user id as text (actor_id stays a UUID column).
--
-- Status columns stay TEXT + CHECK (bk-001/bk-002 rule). Re-running the whole file is a no-op
-- (IF NOT EXISTS / OR REPLACE / ON CONFLICT DO NOTHING / idempotent GRANT/REVOKE).

BEGIN;

-- ── Audit: text actor reference ──────────────────────────────────────────────

ALTER TABLE booking.audit_logs
    ADD COLUMN IF NOT EXISTS actor_ref TEXT;

COMMENT ON COLUMN booking.audit_logs.actor_ref IS
    'bk-003: actor as text, e.g. the staff CIS user id (staff JWT sub). actor_id is set too when that id is a UUID.';

CREATE INDEX IF NOT EXISTS audit_logs_actor_ref_idx
    ON booking.audit_logs (actor_ref, created_at DESC) WHERE actor_ref IS NOT NULL;

-- ── Staff (O1: thin profile over the CIS staff login) ────────────────────────

CREATE TABLE IF NOT EXISTS booking.staff_users (
    cis_user_id   TEXT PRIMARY KEY,                -- CIS shared.admin_users.id = staff JWT sub
    email         TEXT,
    name          TEXT,
    role          TEXT NOT NULL,
    active        BOOLEAN NOT NULL DEFAULT false,
    cis_role      TEXT,                            -- last cis_role claim seen (informational)
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at  TIMESTAMPTZ,

    CONSTRAINT staff_users_id_chk CHECK (length(cis_user_id) BETWEEN 1 AND 128),
    CONSTRAINT staff_users_role_chk CHECK (role IN ('admin', 'sales', 'contracting', 'content_creator'))
);

COMMENT ON TABLE booking.staff_users IS
    'bk-003 (ADR 0004 O1): Booking profile of a CIS staff user. Provisioned on the first valid staff JWT; role and active are owned by Booking admins.';

CREATE INDEX IF NOT EXISTS staff_users_active_idx
    ON booking.staff_users (active, role);

CREATE OR REPLACE TRIGGER staff_users_set_updated_at
    BEFORE UPDATE ON booking.staff_users
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Trip cases: notes ────────────────────────────────────────────────────────

ALTER TABLE booking.trip_cases
    ADD COLUMN IF NOT EXISTS notes TEXT;

-- ── Status workflow ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.trip_case_status_transitions (
    from_status  TEXT NOT NULL,
    to_status    TEXT NOT NULL,

    CONSTRAINT trip_case_status_transitions_pk PRIMARY KEY (from_status, to_status),
    CONSTRAINT trip_case_status_transitions_from_chk CHECK (from_status IN (
        'new_inquiry', 'discovery', 'building', 'proposal_sent', 'confirmed', 'supplier_confirming',
        'invoice_sent', 'payment_pending', 'paid', 'pre_departure', 'on_trip', 'completed', 'cancelled')),
    CONSTRAINT trip_case_status_transitions_to_chk CHECK (to_status IN (
        'new_inquiry', 'discovery', 'building', 'proposal_sent', 'confirmed', 'supplier_confirming',
        'invoice_sent', 'payment_pending', 'paid', 'pre_departure', 'on_trip', 'completed', 'cancelled')),
    CONSTRAINT trip_case_status_transitions_distinct_chk CHECK (from_status <> to_status)
);

COMMENT ON TABLE booking.trip_case_status_transitions IS
    'bk-003: allowed trip case status edges (read-only for role booking). Pre-sale edges only; post-sale edges ship with AA-682.';

INSERT INTO booking.trip_case_status_transitions (from_status, to_status) VALUES
    ('new_inquiry', 'discovery'),
    ('discovery', 'building'),
    ('building', 'proposal_sent'),
    ('building', 'discovery'),
    ('proposal_sent', 'building'),
    ('new_inquiry', 'cancelled'),
    ('discovery', 'cancelled'),
    ('building', 'cancelled'),
    ('proposal_sent', 'cancelled')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS booking.trip_case_status_history (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_case_id  UUID NOT NULL REFERENCES booking.trip_cases (id) ON DELETE CASCADE,
    from_status   TEXT,
    to_status     TEXT NOT NULL,
    changed_by    TEXT REFERENCES booking.staff_users (cis_user_id),
    note          TEXT,
    changed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT trip_case_status_history_to_chk CHECK (to_status IN (
        'new_inquiry', 'discovery', 'building', 'proposal_sent', 'confirmed', 'supplier_confirming',
        'invoice_sent', 'payment_pending', 'paid', 'pre_departure', 'on_trip', 'completed', 'cancelled')),
    CONSTRAINT trip_case_status_history_from_chk CHECK (from_status IS NULL OR from_status IN (
        'new_inquiry', 'discovery', 'building', 'proposal_sent', 'confirmed', 'supplier_confirming',
        'invoice_sent', 'payment_pending', 'paid', 'pre_departure', 'on_trip', 'completed', 'cancelled'))
);

CREATE INDEX IF NOT EXISTS trip_case_status_history_case_idx
    ON booking.trip_case_status_history (trip_case_id, changed_at);

-- Rejects a status change that is not an allowed edge. Not SECURITY DEFINER: runs with the
-- caller's rights (role booking can read the transitions table).
CREATE OR REPLACE FUNCTION booking.trip_case_check_transition() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM booking.trip_case_status_transitions t
        WHERE t.from_status = OLD.status AND t.to_status = NEW.status
    ) THEN
        RAISE EXCEPTION 'illegal trip case status transition % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

-- Writes one history row per status write. Actor / reason: transaction-local settings set by the API
-- (set_config('booking.actor', ..., true)); empty or unset means a system change.
CREATE OR REPLACE FUNCTION booking.trip_case_record_status() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    INSERT INTO booking.trip_case_status_history (trip_case_id, from_status, to_status, changed_by, note)
    VALUES (
        NEW.id,
        CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END,
        NEW.status,
        nullif(current_setting('booking.actor', true), ''),
        nullif(current_setting('booking.status_note', true), '')
    );
    RETURN NULL;
END $$;

CREATE OR REPLACE TRIGGER trip_cases_check_transition
    BEFORE UPDATE OF status ON booking.trip_cases
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION booking.trip_case_check_transition();

CREATE OR REPLACE TRIGGER trip_cases_record_status_insert
    AFTER INSERT ON booking.trip_cases
    FOR EACH ROW EXECUTE FUNCTION booking.trip_case_record_status();

CREATE OR REPLACE TRIGGER trip_cases_record_status_update
    AFTER UPDATE OF status ON booking.trip_cases
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION booking.trip_case_record_status();

-- Cases opened before bk-003 get their starting point in the history.
INSERT INTO booking.trip_case_status_history (trip_case_id, from_status, to_status, note, changed_at)
SELECT tc.id, NULL, tc.status, 'bk-003 backfill', tc.created_at
FROM booking.trip_cases tc
WHERE NOT EXISTS (SELECT 1 FROM booking.trip_case_status_history h WHERE h.trip_case_id = tc.id);

-- ── Staff assignments ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.staff_assignments (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_case_id   UUID NOT NULL REFERENCES booking.trip_cases (id) ON DELETE CASCADE,
    staff_user_id  TEXT NOT NULL REFERENCES booking.staff_users (cis_user_id),
    role           TEXT NOT NULL DEFAULT 'sales',
    assigned_by    TEXT REFERENCES booking.staff_users (cis_user_id),
    assigned_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    unassigned_at  TIMESTAMPTZ,

    CONSTRAINT staff_assignments_role_chk CHECK (role IN ('sales', 'contracting', 'ops', 'guide')),
    CONSTRAINT staff_assignments_period_chk CHECK (unassigned_at IS NULL OR unassigned_at >= assigned_at)
);

-- At most one open assignment per case and role.
CREATE UNIQUE INDEX IF NOT EXISTS staff_assignments_open_uq
    ON booking.staff_assignments (trip_case_id, role) WHERE unassigned_at IS NULL;
CREATE INDEX IF NOT EXISTS staff_assignments_staff_open_idx
    ON booking.staff_assignments (staff_user_id, assigned_at DESC) WHERE unassigned_at IS NULL;

-- ── Proposal versions ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.trip_case_versions (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_case_id         UUID NOT NULL REFERENCES booking.trip_cases (id),
    version_number       SMALLINT NOT NULL,
    notes                TEXT,
    total_price          NUMERIC(12, 2),
    currency             CHAR(3),
    is_sent_to_customer  BOOLEAN NOT NULL DEFAULT false,
    sent_at              TIMESTAMPTZ,
    is_approved          BOOLEAN NOT NULL DEFAULT false,
    approved_at          TIMESTAMPTZ,
    created_by           TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT trip_case_versions_number_uq UNIQUE (trip_case_id, version_number),
    CONSTRAINT trip_case_versions_number_chk CHECK (version_number >= 1),
    CONSTRAINT trip_case_versions_price_chk CHECK (total_price IS NULL OR total_price >= 0),
    CONSTRAINT trip_case_versions_currency_chk CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'),
    CONSTRAINT trip_case_versions_approved_chk CHECK (NOT is_approved OR approved_at IS NOT NULL),
    CONSTRAINT trip_case_versions_sent_chk CHECK (NOT is_sent_to_customer OR sent_at IS NOT NULL)
);

-- At most one approved version per case.
CREATE UNIQUE INDEX IF NOT EXISTS trip_case_versions_approved_uq
    ON booking.trip_case_versions (trip_case_id) WHERE is_approved;

CREATE OR REPLACE TRIGGER trip_case_versions_set_updated_at
    BEFORE UPDATE ON booking.trip_case_versions
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

CREATE TABLE IF NOT EXISTS booking.trip_case_version_itinerary (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_case_version_id  UUID NOT NULL REFERENCES booking.trip_case_versions (id) ON DELETE CASCADE,
    position              SMALLINT NOT NULL,
    title                 TEXT NOT NULL,
    day_from              SMALLINT NOT NULL,
    day_to                SMALLINT NOT NULL,
    source_tour_id        TEXT,                    -- CIS published tour id when the item comes from a leg
    notes                 TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT trip_case_version_itinerary_position_uq UNIQUE (trip_case_version_id, position),
    CONSTRAINT trip_case_version_itinerary_position_chk CHECK (position >= 1),
    CONSTRAINT trip_case_version_itinerary_days_chk CHECK (day_from >= 1 AND day_to >= day_from),
    CONSTRAINT trip_case_version_itinerary_title_chk CHECK (length(title) BETWEEN 1 AND 500)
);

COMMENT ON TABLE booking.trip_case_version_itinerary IS
    'bk-003: free-text proposal items (title, days, optional source tour). Catalog references (activity, hotel, destination, price) arrive with AA-679 / ADR 0005.';

CREATE OR REPLACE TRIGGER trip_case_version_itinerary_set_updated_at
    BEFORE UPDATE ON booking.trip_case_version_itinerary
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- An approved version is locked: the version row and its items can no longer change.
CREATE OR REPLACE FUNCTION booking.trip_case_version_lock() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF OLD.is_approved THEN
        RAISE EXCEPTION 'trip case version % is approved and locked', OLD.id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION booking.trip_case_version_item_lock() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_id UUID;
BEGIN
    v_id := CASE WHEN TG_OP = 'INSERT' THEN NEW.trip_case_version_id ELSE OLD.trip_case_version_id END;
    IF EXISTS (SELECT 1 FROM booking.trip_case_versions v WHERE v.id = v_id AND v.is_approved)
       OR (TG_OP = 'UPDATE' AND EXISTS (
           SELECT 1 FROM booking.trip_case_versions v WHERE v.id = NEW.trip_case_version_id AND v.is_approved))
    THEN
        RAISE EXCEPTION 'trip case version % is approved and locked', v_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER trip_case_versions_lock
    BEFORE UPDATE OR DELETE ON booking.trip_case_versions
    FOR EACH ROW EXECUTE FUNCTION booking.trip_case_version_lock();

CREATE OR REPLACE TRIGGER trip_case_version_itinerary_lock
    BEFORE INSERT OR UPDATE OR DELETE ON booking.trip_case_version_itinerary
    FOR EACH ROW EXECUTE FUNCTION booking.trip_case_version_item_lock();

-- ── Explicit grants (default privileges already cover these; repeated for a standalone file) ──

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA booking TO booking;
GRANT EXECUTE ON FUNCTION booking.trip_case_check_transition() TO booking;
GRANT EXECUTE ON FUNCTION booking.trip_case_record_status() TO booking;
GRANT EXECUTE ON FUNCTION booking.trip_case_version_lock() TO booking;
GRANT EXECUTE ON FUNCTION booking.trip_case_version_item_lock() TO booking;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.trip_case_status_transitions FROM booking;
-- History is written by the trigger only and never rewritten.
REVOKE UPDATE, DELETE, TRUNCATE ON booking.trip_case_status_history FROM booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_schema_versions FROM booking;
REVOKE UPDATE, DELETE, TRUNCATE ON booking.audit_logs FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-003', now(), 'AA-680/AA-681 slice 3: staff_users (O1 thin profile), trip_case_status_transitions + history + triggers, staff_assignments, trip_case_versions + version_itinerary (approved = locked), trip_cases.notes, audit_logs.actor_ref')
ON CONFLICT (version) DO NOTHING;

COMMIT;
