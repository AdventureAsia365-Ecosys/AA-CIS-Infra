-- Migration bk-027: AA-682 slice S2 — trip checks of a sold trip case and the case lifecycle after the sale
-- (operations MVP, S252 design §3.2, §4, §9 with the critic fixes).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/027_trip_checks_lifecycle.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as bk_owner (the live owner of schema booking since bk-014). Never run it from a laptop.
--
-- Depends on bk-003 (trip_cases, staff_users, set_updated_at), bk-005 (settings, notifications.recipient_ref) and
-- bk-026 (v_trip_case_supply_state, settings pre_departure_days). Every grant names its object (no "ON ALL TABLES").
--
-- What it adds (docs/implementation-notes/AA-682.md, section S2):
--   * booking.trip_case_checks: the pre-departure checks of a sold trip case. Three standard rows per case
--     (pre_trip_recheck, emergency_contact, insurance; at most one of each) plus any number of custom rows (title
--     required). status open -> done | not_applicable, done | not_applicable -> open (reopen); done <=> done_at.
--     due_date, assignee_ref (a staff key), note. The emergency contact (name, phone) lives on the emergency_contact
--     row only, and never on a B2B case (DM-6.8: no traveller data of an agency trip in booking.*): there the row is
--     not_applicable with empty contact fields, enforced by trip_case_checks_guard. The contact fields and every note
--     of the case are cleared at trip end + emergency_contact_keep_days by the bk_case_lifecycle job (DM-7 row of
--     trip_case_checks; cleared_at says when; a cleared row never takes them again). Never deleted by role booking;
--     the rows go with their case (ON DELETE CASCADE: Booking only soft-deletes cases, a hard delete is a reviewed
--     script).
--   * booking.trip_case_seed_checks() + trigger trip_cases_seed_checks (AFTER INSERT OR UPDATE OF status, start_date
--     ON trip_cases): when a case enters confirmed (B2C version approval, or the B2B confirm that inserts the case at
--     confirmed) the three standard rows are inserted ON CONFLICT DO NOTHING, due = start_date - pre_departure_days;
--     when the start date moves, the due date of the standard rows still open on the derived date moves with it.
--     One backfill statement seeds the cases already sold (confirmed .. on_trip).
--   * booking.v_trip_check_board: per open sold case, the stored check counts (open / done / not applicable / overdue,
--     next due date) and the derived checks: suppliers_confirmed (supply state booked or none, bk-026 view) and
--     payment_verified (NULL until bk-028 replaces this view with the invoice state).
--   * notifications_reminder_uq (moved forward from the bk-028 plan, critic B7): UNIQUE (recipient_type, type,
--     entity_id, data->>'reminder_key') WHERE data ? 'reminder_key', so the daily jobs (bk_case_lifecycle gate
--     notices, bk_ops_reminders) write each reminder once; their inserts use ON CONFLICT DO NOTHING.
--   * settings rows trip_check_reminder_days (3) and emergency_contact_keep_days (90).
--
-- Not here: invoices / payments (bk-028), supplier bills (bk-029). No new case edge: the travel edges
-- (-> pre_departure -> on_trip -> completed) and their fact guard are bk-026; bk_case_lifecycle walks them.
--
-- Locks: trip_cases takes SHARE ROW EXCLUSIVE for the new trigger and notifications SHARE for the new index (both an
-- instant at Booking's size); the new table is empty before the backfill. lock_timeout 5s: the apply fails rather than
-- queueing behind the job worker.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS everywhere, CREATE OR REPLACE for functions,
-- triggers and the view (same column list), ON CONFLICT DO NOTHING for seed rows and the backfill, grants repeat.
-- Undo (a later bk- file): DROP the view, the seeding trigger and function, trip_case_checks and its guard,
-- notifications_reminder_uq, DELETE the two settings rows.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-027: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.v_trip_case_supply_state') IS NULL THEN
        RAISE EXCEPTION 'bk-027: needs bk-026 (v_trip_case_supply_state, pre_departure_days) first';
    END IF;
END $$;

-- ── Trip checks ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.trip_case_checks (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_case_id             UUID NOT NULL REFERENCES booking.trip_cases (id) ON DELETE CASCADE,
    code                     TEXT NOT NULL,
    title                    TEXT NOT NULL,
    status                   TEXT NOT NULL DEFAULT 'open',
    due_date                 DATE,
    assignee_ref             TEXT REFERENCES booking.staff_users (cis_user_id),
    done_by                  TEXT REFERENCES booking.staff_users (cis_user_id),
    done_at                  TIMESTAMPTZ,
    note                     TEXT,
    emergency_contact_name   TEXT,
    emergency_contact_phone  TEXT,
    cleared_at               TIMESTAMPTZ,
    created_by               TEXT REFERENCES booking.staff_users (cis_user_id),
    updated_by               TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT trip_case_checks_code_chk CHECK (code IN ('pre_trip_recheck', 'emergency_contact', 'insurance', 'custom')),
    CONSTRAINT trip_case_checks_title_chk CHECK (length(title) BETWEEN 1 AND 200),
    CONSTRAINT trip_case_checks_status_chk CHECK (status IN ('open', 'done', 'not_applicable')),
    CONSTRAINT trip_case_checks_done_chk CHECK (
        (status = 'done') = (done_at IS NOT NULL) AND (done_by IS NULL OR status = 'done')),
    CONSTRAINT trip_case_checks_note_chk CHECK (note IS NULL OR length(note) BETWEEN 1 AND 2000),
    -- The emergency contact lives on the emergency_contact row only.
    CONSTRAINT trip_case_checks_contact_row_chk CHECK (
        code = 'emergency_contact' OR (emergency_contact_name IS NULL AND emergency_contact_phone IS NULL)),
    CONSTRAINT trip_case_checks_contact_name_chk CHECK (
        emergency_contact_name IS NULL OR length(emergency_contact_name) BETWEEN 1 AND 200),
    CONSTRAINT trip_case_checks_contact_phone_chk CHECK (
        emergency_contact_phone IS NULL OR emergency_contact_phone ~ '^\+?[0-9][0-9 ().-]{3,38}[0-9]$'),
    -- Once cleared (trip end + emergency_contact_keep_days), the personal fields stay empty.
    CONSTRAINT trip_case_checks_cleared_chk CHECK (
        cleared_at IS NULL OR (emergency_contact_name IS NULL AND emergency_contact_phone IS NULL AND note IS NULL))
);

COMMENT ON TABLE booking.trip_case_checks IS
    'bk-027 (AA-682 S2): pre-departure checks of a sold trip case: the three standard rows (pre_trip_recheck, emergency_contact, insurance), seeded when the case enters confirmed (trigger trip_cases_seed_checks), plus custom rows. status open -> done | not_applicable -> open. No emergency contact on a B2B case (DM-6.8). Contact fields and notes cleared at trip end + emergency_contact_keep_days by bk_case_lifecycle. Never deleted by role booking.';
COMMENT ON COLUMN booking.trip_case_checks.title IS
    'pii:free_text; what to check (standard rows: a fixed English title; custom rows: typed by staff, may name a person).';
COMMENT ON COLUMN booking.trip_case_checks.note IS
    'pii:free_text; staff note on the check (bk-027), cleared at trip end + emergency_contact_keep_days.';
COMMENT ON COLUMN booking.trip_case_checks.emergency_contact_name IS
    'pii:emergency_contact; also pii:name (the third person to call in an emergency, B2C only; bk-027, cleared at trip end + emergency_contact_keep_days).';
COMMENT ON COLUMN booking.trip_case_checks.emergency_contact_phone IS
    'pii:emergency_contact; also pii:contact (phone of that person, B2C only; bk-027, cleared with the name).';
COMMENT ON COLUMN booking.trip_case_checks.due_date IS
    'bk-027: when the check should be done; standard rows: start_date - pre_departure_days (moves with the start date while open).';
COMMENT ON COLUMN booking.trip_case_checks.assignee_ref IS
    'bk-027: the staff key of the person who owns the check (NULL = anyone on the case).';
COMMENT ON COLUMN booking.trip_case_checks.cleared_at IS
    'bk-027: when bk_case_lifecycle cleared the emergency contact and the note (DM-7 trip end + 90 days); final.';

-- At most one standard row of each code per case; custom rows are free.
CREATE UNIQUE INDEX IF NOT EXISTS trip_case_checks_standard_uq
    ON booking.trip_case_checks (trip_case_id, code) WHERE code <> 'custom';
CREATE INDEX IF NOT EXISTS trip_case_checks_case_idx ON booking.trip_case_checks (trip_case_id, created_at);
CREATE INDEX IF NOT EXISTS trip_case_checks_open_due_idx
    ON booking.trip_case_checks (due_date) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS trip_case_checks_assignee_idx
    ON booking.trip_case_checks (assignee_ref) WHERE assignee_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS trip_case_checks_done_by_idx
    ON booking.trip_case_checks (done_by) WHERE done_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS trip_case_checks_created_by_idx
    ON booking.trip_case_checks (created_by) WHERE created_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS trip_case_checks_updated_by_idx
    ON booking.trip_case_checks (updated_by) WHERE updated_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS trip_case_checks_uncleared_idx
    ON booking.trip_case_checks (trip_case_id) WHERE cleared_at IS NULL;

CREATE OR REPLACE TRIGGER trip_case_checks_set_updated_at
    BEFORE UPDATE ON booking.trip_case_checks
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- Facts of a check: what never changes, the status edges, no emergency contact on a B2B case, cleared is final.
CREATE OR REPLACE FUNCTION booking.trip_case_checks_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_channel  TEXT;
BEGIN
    SELECT channel INTO v_channel FROM booking.trip_cases WHERE id = NEW.trip_case_id;
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.trip_case_id, NEW.code, NEW.created_by, NEW.created_at)
           IS DISTINCT FROM (OLD.trip_case_id, OLD.code, OLD.created_by, OLD.created_at) THEN
            RAISE EXCEPTION 'trip check %: its case and code never change', OLD.id USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.code <> 'custom' AND NEW.title IS DISTINCT FROM OLD.title THEN
            RAISE EXCEPTION 'trip check %: a standard check keeps its title', OLD.id USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.status IS DISTINCT FROM OLD.status
           AND NOT ((OLD.status = 'open' AND NEW.status IN ('done', 'not_applicable'))
                    OR (OLD.status IN ('done', 'not_applicable') AND NEW.status = 'open')) THEN
            RAISE EXCEPTION 'illegal trip check status transition % -> %', OLD.status, NEW.status
                USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.cleared_at IS NOT NULL AND NEW.cleared_at IS DISTINCT FROM OLD.cleared_at THEN
            RAISE EXCEPTION 'trip check %: its personal fields were cleared after the trip; cleared is final', OLD.id
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF v_channel = 'b2b' AND NEW.code = 'emergency_contact'
       AND (NEW.status <> 'not_applicable' OR NEW.emergency_contact_name IS NOT NULL
            OR NEW.emergency_contact_phone IS NOT NULL) THEN
        RAISE EXCEPTION 'no emergency contact on a B2B trip case (DM-6.8: the agency keeps traveller data)'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.trip_case_checks_guard() IS
    'bk-027 (AA-682 S2): a check keeps its case, code and (standard rows) title; status edges open -> done | not_applicable -> open; the emergency_contact row of a B2B case stays not_applicable without contact fields (DM-6.8); cleared_at is final.';

CREATE OR REPLACE TRIGGER trip_case_checks_guard
    BEFORE INSERT OR UPDATE ON booking.trip_case_checks
    FOR EACH ROW EXECUTE FUNCTION booking.trip_case_checks_guard();

-- ── Seeding on entering confirmed; due dates follow the start date ───────────

CREATE OR REPLACE FUNCTION booking.trip_case_seed_checks() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_days  INTEGER;
    v_b2b   BOOLEAN := NEW.channel = 'b2b';
BEGIN
    SELECT CASE WHEN jsonb_typeof(value) = 'number' THEN (value #>> '{}')::numeric::integer END INTO v_days
      FROM booking.settings WHERE key = 'pre_departure_days';
    v_days := coalesce(v_days, 14);
    IF TG_OP = 'UPDATE' AND NEW.start_date IS DISTINCT FROM OLD.start_date THEN
        UPDATE booking.trip_case_checks
           SET due_date = NEW.start_date - v_days
         WHERE trip_case_id = NEW.id AND code <> 'custom' AND status = 'open'
           AND due_date IS NOT DISTINCT FROM OLD.start_date - v_days;
    END IF;
    IF NEW.status = 'confirmed' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
        INSERT INTO booking.trip_case_checks (trip_case_id, code, title, status, due_date)
        VALUES (NEW.id, 'pre_trip_recheck', 'Re-check every booking before departure', 'open', NEW.start_date - v_days),
               (NEW.id, 'emergency_contact', 'Emergency contact',
                CASE WHEN v_b2b THEN 'not_applicable' ELSE 'open' END,
                CASE WHEN v_b2b THEN NULL ELSE NEW.start_date - v_days END),
               (NEW.id, 'insurance', 'Travel insurance', 'open', NEW.start_date - v_days)
        ON CONFLICT (trip_case_id, code) WHERE code <> 'custom' DO NOTHING;
    END IF;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.trip_case_seed_checks() IS
    'bk-027 (AA-682 S2): AFTER INSERT OR UPDATE OF status, start_date on trip_cases. Entering confirmed seeds the three standard checks (ON CONFLICT DO NOTHING; due = start_date - pre_departure_days; B2B emergency_contact not_applicable); a new start date moves the due date of the standard checks still open on the derived date.';

CREATE OR REPLACE TRIGGER trip_cases_seed_checks
    AFTER INSERT OR UPDATE OF status, start_date ON booking.trip_cases
    FOR EACH ROW EXECUTE FUNCTION booking.trip_case_seed_checks();

-- Backfill: the cases already sold and not finished get their standard rows (same values as the trigger).
INSERT INTO booking.trip_case_checks (trip_case_id, code, title, status, due_date)
SELECT tc.id, s.code, s.title,
       CASE WHEN tc.channel = 'b2b' AND s.code = 'emergency_contact' THEN 'not_applicable' ELSE 'open' END,
       CASE WHEN tc.channel = 'b2b' AND s.code = 'emergency_contact' THEN NULL
            ELSE tc.start_date - coalesce((SELECT CASE WHEN jsonb_typeof(value) = 'number'
                                                       THEN (value #>> '{}')::numeric::integer END
                                             FROM booking.settings WHERE key = 'pre_departure_days'), 14) END
  FROM booking.trip_cases tc
 CROSS JOIN (VALUES ('pre_trip_recheck', 'Re-check every booking before departure', 1),
                    ('emergency_contact', 'Emergency contact', 2),
                    ('insurance', 'Travel insurance', 3)) AS s (code, title, ord)
 WHERE tc.deleted_at IS NULL
   AND tc.status IN ('confirmed', 'supplier_confirming', 'invoice_sent', 'payment_pending', 'paid', 'pre_departure',
                     'on_trip')
 ORDER BY tc.created_at, s.ord
ON CONFLICT (trip_case_id, code) WHERE code <> 'custom' DO NOTHING;

-- ── Check board (stored + derived checks per open sold case) ─────────────────

CREATE OR REPLACE VIEW booking.v_trip_check_board AS
SELECT tc.id AS trip_case_id,
       tc.code AS trip_case_code,
       tc.channel,
       tc.status AS case_status,
       tc.start_date,
       tc.end_date,
       coalesce(k.total, 0)::int AS checks_total,
       coalesce(k.open, 0)::int AS checks_open,
       coalesce(k.done, 0)::int AS checks_done,
       coalesce(k.not_applicable, 0)::int AS checks_not_applicable,
       coalesce(k.overdue, 0)::int AS checks_overdue,
       k.next_due AS next_due_date,
       s.state AS supply_state,
       s.state IN ('booked', 'none') AS suppliers_confirmed,
       NULL::boolean AS payment_verified
FROM booking.trip_cases tc
JOIN booking.v_trip_case_supply_state s ON s.trip_case_id = tc.id
LEFT JOIN LATERAL (
    SELECT count(*) AS total,
           count(*) FILTER (WHERE c.status = 'open') AS open,
           count(*) FILTER (WHERE c.status = 'done') AS done,
           count(*) FILTER (WHERE c.status = 'not_applicable') AS not_applicable,
           count(*) FILTER (WHERE c.status = 'open' AND c.due_date < current_date) AS overdue,
           min(c.due_date) FILTER (WHERE c.status = 'open') AS next_due
      FROM booking.trip_case_checks c
     WHERE c.trip_case_id = tc.id
) k ON true
WHERE tc.deleted_at IS NULL
  AND tc.status IN ('confirmed', 'supplier_confirming', 'invoice_sent', 'payment_pending', 'paid', 'pre_departure',
                    'on_trip');

COMMENT ON VIEW booking.v_trip_check_board IS
    'bk-027 (AA-682 S2): per open sold trip case (confirmed .. on_trip), the stored trip checks (total / open / done / not applicable / overdue = open with due_date before today, next due date) and the derived checks: suppliers_confirmed (supply state booked or none) and payment_verified (NULL until bk-028 replaces this view with the invoice state).';

-- ── Reminder dedupe (critic B7; used by bk_case_lifecycle and bk_ops_reminders) ─

CREATE UNIQUE INDEX IF NOT EXISTS notifications_reminder_uq
    ON booking.notifications (recipient_type, type, entity_id, (data ->> 'reminder_key'))
    WHERE data ? 'reminder_key';

-- ── Settings (policy data) ───────────────────────────────────────────────────

INSERT INTO booking.settings (key, value, description) VALUES
    ('trip_check_reminder_days', '3'::jsonb, 'Days before its due date an open trip check reminds its owner (AA-682 S2, bk_ops_reminders; policy data).'),
    ('emergency_contact_keep_days', '90'::jsonb, 'Days after the trip end the emergency contact and the notes of the trip checks are kept before bk_case_lifecycle clears them (AA-682 S2; data standards DM-7 row of trip_case_checks).')
ON CONFLICT (key) DO NOTHING;

-- ── Grants (per object) ──────────────────────────────────────────────────────

-- trip_case_checks: insert, then the working columns change; never deleted by role booking.
REVOKE ALL ON booking.trip_case_checks FROM booking;
GRANT SELECT, INSERT ON booking.trip_case_checks TO booking;
GRANT UPDATE (title, status, due_date, assignee_ref, done_by, done_at, note, emergency_contact_name,
              emergency_contact_phone, cleared_at, updated_by, updated_at) ON booking.trip_case_checks TO booking;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_trip_check_board FROM booking;
GRANT SELECT ON booking.v_trip_check_board TO booking;

GRANT EXECUTE ON FUNCTION booking.trip_case_checks_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.trip_case_seed_checks() TO booking;

DO $$
BEGIN
    IF has_table_privilege('booking', 'booking.trip_case_checks', 'DELETE')
       OR has_table_privilege('booking', 'booking.trip_case_checks', 'TRUNCATE')
       OR has_table_privilege('booking', 'booking.v_trip_check_board', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-027: role booking can delete trip checks or write the board view';
    END IF;
    IF has_column_privilege('booking', 'booking.trip_case_checks', 'trip_case_id', 'UPDATE')
       OR has_column_privilege('booking', 'booking.trip_case_checks', 'code', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-027: role booking can move a check to another case or code';
    END IF;
    IF has_table_privilege('cis_app', 'booking.trip_case_checks', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.v_trip_check_board', 'SELECT') THEN
        RAISE EXCEPTION 'bk-027: cis_app can read trip checks';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-027', now(), 'AA-682 S2: trip_case_checks (+ guard, seeding trigger on confirmed, backfill), v_trip_check_board (derived suppliers_confirmed / payment_verified), notifications_reminder_uq, settings trip_check_reminder_days / emergency_contact_keep_days')
ON CONFLICT (version) DO NOTHING;

COMMIT;
