-- Migration bk-046: AA-1073 (Booking departures; S275 study root docs/research/2026-11-10-odoo-tour-travel-plugin-comparison.md
-- items bk-01, bk-02, bk-03) — departure minimum to operate, sales cutoff and decision date, the at-risk stamp, and
-- per-agency seat allotments with a release date.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/046_departure_minimum_cutoff_allotments.sql; on Dev it is applied as bk_owner (the live owner of
-- schema booking since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a), or by a person
-- with DB Migrate apply. Never run it from a laptop.
--
-- What:
--   1. booking.departures gains
--        min_to_operate        sold seats the departure needs to run (0 = no minimum: managed by hand, as before);
--        sales_cutoff_days     sales close on start_date - sales_cutoff_days (that day included; 0 = the start day);
--        decision_days_before  the go / cancel decision date = start_date - decision_days_before (default 21);
--        at_risk_at            stamped once by the daily job bk_departure_watch when the decision date is reached
--                              while the departure is scheduled with fewer sold seats than its minimum.
--      CHECKs: 0 <= min_to_operate <= capacity, cutoff 0..90 days, decision 0..365 days, at_risk_at only with a
--      minimum. Defaults 0 / 0 / 21 (proposed for the business owner, S275 Jira draft; adjusted after her answer).
--   2. The outbox: event types departure.at_risk (fan-out to the agencies on the departure, like departure.guaranteed)
--      and allotment.released (to the one agency whose allotment was released). departures_outbox replaced: it also
--      emits departure.at_risk when at_risk_at is first stamped on a scheduled departure; the trigger now fires on
--      UPDATE OF status, at_risk_at.
--   3. booking.departure_allotments: seats on one departure reserved for one agency (b2b partner) until a release date
--      (start_date - release_days_before). Append-only: the facts never change; a change is a new pending row naming
--      the row it replaces (replaces_id). Maker-checker: approved by a second staff member (CHECK approved_by <>
--      created_by). At most one in force (approved, not ended) and one pending per departure and agency. Ended once
--      (end_reason replaced | withdrawn | rejected | departure_cancelled), released once (released_at, by the job
--      bk_allotment_release). The guard trigger enforces the life; the outbox trigger emits allotment.released.
--      Seats are counted by the app (app/b2b/allotments.py): an agency's unused allotment (seats minus its own held +
--      sold on the departure) is taken out of everyone else's free seats until it is released.
--
-- Class: contract (root ADR 0017 d3): ALTER TABLE departures (columns + CHECKs), the outbox CHECK and trigger function
-- replaced, next to one new table. So a migration-only PR first (MIG-4); the code PR raises readiness to bk-046. On
-- Dev: Infra Migration Apply once every job table is idle (root ADR 0017a). Needs bk-019 (b2b_partners), bk-020
-- (departures, b2b holds) and bk-022 (outbox, departures_outbox, outbox_departure_event).
-- DM-7.1 row for the new table: root docs/architecture/data-standards/02-data-management.md (AA-1073 root PR, merged
-- before the Infra copy). DM-6.1: departure_allotments.seats conf:commercial (an agency's reserved block); no free text.
--
-- Locks: ACCESS EXCLUSIVE on departures for the ADD COLUMNs (constant defaults: no rewrite) and the CHECK adds (a scan of
-- tens of rows), on outbox for the CHECK replace (a scan of tens of rows); SHARE ROW EXCLUSIVE on departures and
-- b2b_partners for the new FKs (a moment). lock_timeout 5s.
-- Key guard: refuses to run when shared.schema_versions already holds bk-046 with another description.
-- Re-runnable (the integration tests replay every file): IF NOT EXISTS, DROP CONSTRAINT / TRIGGER IF EXISTS before each
-- ADD / CREATE, CREATE OR REPLACE FUNCTION, grants repeat.
-- Undo (a later bk- file, after the code is reverted): DROP TABLE booking.departure_allotments and its two functions,
-- DROP the four departures columns and their CHECKs, restore the bk-023 outbox_event_type_chk and the bk-022 body and
-- trigger of departures_outbox (outbox rows of the two new types must be deleted first).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-046: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.departures') IS NULL OR to_regclass('booking.b2b_partners') IS NULL
       OR to_regclass('booking.outbox') IS NULL OR to_regprocedure('booking.outbox_departure_event(uuid,text,text)') IS NULL
    THEN
        RAISE EXCEPTION 'bk-046: needs bk-019, bk-020 and bk-022 first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-046' AND description NOT LIKE 'AA-1073:%') THEN
        RAISE EXCEPTION 'bk-046: the key bk-046 is already held by another migration (not AA-1073 departures): renumber one';
    END IF;
END $$;

-- ── 1. Departure minimum, cutoff, decision date, at-risk stamp ───────────────

ALTER TABLE booking.departures
    ADD COLUMN IF NOT EXISTS min_to_operate INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS sales_cutoff_days SMALLINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS decision_days_before SMALLINT NOT NULL DEFAULT 21,
    ADD COLUMN IF NOT EXISTS at_risk_at TIMESTAMPTZ;

ALTER TABLE booking.departures DROP CONSTRAINT IF EXISTS departures_min_chk;
ALTER TABLE booking.departures ADD CONSTRAINT departures_min_chk CHECK (min_to_operate BETWEEN 0 AND capacity);
ALTER TABLE booking.departures DROP CONSTRAINT IF EXISTS departures_cutoff_chk;
ALTER TABLE booking.departures ADD CONSTRAINT departures_cutoff_chk CHECK (sales_cutoff_days BETWEEN 0 AND 90);
ALTER TABLE booking.departures DROP CONSTRAINT IF EXISTS departures_decision_chk;
ALTER TABLE booking.departures ADD CONSTRAINT departures_decision_chk CHECK (decision_days_before BETWEEN 0 AND 365);
ALTER TABLE booking.departures DROP CONSTRAINT IF EXISTS departures_at_risk_chk;
ALTER TABLE booking.departures ADD CONSTRAINT departures_at_risk_chk CHECK (at_risk_at IS NULL OR min_to_operate >= 1);

COMMENT ON COLUMN booking.departures.min_to_operate IS
    'bk-046 (AA-1073, bk-01): sold seats the departure needs to run; 0 = no minimum (status managed by hand). bk_departure_watch guarantees a scheduled departure once sold >= min_to_operate >= 1.';
COMMENT ON COLUMN booking.departures.sales_cutoff_days IS
    'bk-046 (AA-1073, bk-01): sales close on start_date - sales_cutoff_days (that day included): every line on it is sold_out (sales closed). 0 = the start day.';
COMMENT ON COLUMN booking.departures.decision_days_before IS
    'bk-046 (AA-1073, bk-01): the go / cancel decision date is start_date - decision_days_before; on it a scheduled departure short of its minimum is stamped at risk.';
COMMENT ON COLUMN booking.departures.at_risk_at IS
    'bk-046 (AA-1073, bk-01): when bk_departure_watch found the departure short of its minimum on the decision date (stamped once; emits departure.at_risk). Resolved by a staff status move (guaranteed or cancelled).';

-- ── 2. Outbox: two new event types; departures_outbox also emits departure.at_risk ──

ALTER TABLE booking.outbox DROP CONSTRAINT IF EXISTS outbox_event_type_chk;
ALTER TABLE booking.outbox ADD CONSTRAINT outbox_event_type_chk CHECK (event_type IN (
    'hold.expired', 'hold.extended', 'line.confirmed', 'line.declined', 'booking.cancelled',
    'departure.guaranteed', 'departure.cancelled', 'departure.incident', 'departure.incident_cleared',
    'departure.at_risk', 'allotment.released',
    'supply.upsert', 'supply.deactivate'));

-- allotment.released names the departure (and, through outbox_b2b_partner_chk, the agency).
ALTER TABLE booking.outbox DROP CONSTRAINT IF EXISTS outbox_allotment_chk;
ALTER TABLE booking.outbox ADD CONSTRAINT outbox_allotment_chk CHECK (
    event_type <> 'allotment.released' OR (stream = 'b2b' AND departure_id IS NOT NULL));

CREATE OR REPLACE FUNCTION booking.departures_outbox() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.status IN ('guaranteed', 'cancelled') AND OLD.status IS DISTINCT FROM NEW.status THEN
        PERFORM booking.outbox_departure_event(NEW.id, 'departure.' || NEW.status, NULL);
    END IF;
    IF NEW.at_risk_at IS NOT NULL AND OLD.at_risk_at IS NULL AND NEW.status = 'scheduled' THEN
        PERFORM booking.outbox_departure_event(NEW.id, 'departure.at_risk', NULL);
    END IF;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.departures_outbox() IS
    'bk-022 (AA-975), bk-046 (AA-1073): departure.guaranteed / departure.cancelled on a status move, departure.at_risk when at_risk_at is first stamped on a scheduled departure; fan-out to every agency with seats on it.';

DROP TRIGGER IF EXISTS departures_outbox ON booking.departures;
CREATE TRIGGER departures_outbox
    AFTER UPDATE OF status, at_risk_at ON booking.departures
    FOR EACH ROW EXECUTE FUNCTION booking.departures_outbox();

-- ── 3. Per-agency seat allotments ────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.departure_allotments (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    departure_id         UUID NOT NULL REFERENCES booking.departures (id),
    partner_id           UUID NOT NULL REFERENCES booking.b2b_partners (id),
    seats                SMALLINT NOT NULL,
    release_days_before  SMALLINT NOT NULL,
    replaces_id          UUID REFERENCES booking.departure_allotments (id),
    created_by           TEXT NOT NULL,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    approved_by          TEXT,
    approved_at          TIMESTAMPTZ,
    released_at          TIMESTAMPTZ,
    ended_at             TIMESTAMPTZ,
    ended_by             TEXT,
    end_reason           TEXT,
    CONSTRAINT departure_allotments_seats_chk CHECK (seats BETWEEN 1 AND 1000),
    CONSTRAINT departure_allotments_release_chk CHECK (release_days_before BETWEEN 0 AND 365),
    CONSTRAINT departure_allotments_approved_chk CHECK (
        (approved_by IS NULL) = (approved_at IS NULL)
        AND (approved_by IS NULL OR (approved_by <> created_by AND length(approved_by) BETWEEN 1 AND 128))
        AND (approved_at IS NULL OR approved_at >= created_at)),
    CONSTRAINT departure_allotments_released_chk CHECK (
        released_at IS NULL OR (approved_at IS NOT NULL AND released_at >= approved_at)),
    CONSTRAINT departure_allotments_ended_chk CHECK (
        (ended_at IS NULL) = (ended_by IS NULL) AND (ended_at IS NULL) = (end_reason IS NULL)
        AND (end_reason IS NULL OR end_reason IN ('replaced', 'withdrawn', 'rejected', 'departure_cancelled'))
        AND (end_reason IS DISTINCT FROM 'rejected' OR approved_at IS NULL)
        AND (end_reason NOT IN ('replaced', 'withdrawn') OR end_reason IS NULL OR approved_at IS NOT NULL)
        AND (ended_by IS NULL OR length(ended_by) BETWEEN 1 AND 128)),
    CONSTRAINT departure_allotments_replaces_chk CHECK (replaces_id IS NULL OR replaces_id <> id),
    CONSTRAINT departure_allotments_creator_chk CHECK (length(created_by) BETWEEN 1 AND 128)
);

CREATE INDEX IF NOT EXISTS departure_allotments_departure_idx ON booking.departure_allotments (departure_id);
CREATE INDEX IF NOT EXISTS departure_allotments_partner_idx ON booking.departure_allotments (partner_id);
CREATE INDEX IF NOT EXISTS departure_allotments_replaces_idx
    ON booking.departure_allotments (replaces_id) WHERE replaces_id IS NOT NULL;
-- At most one allotment in force and one pending per departure and agency.
CREATE UNIQUE INDEX IF NOT EXISTS departure_allotments_in_force_uq
    ON booking.departure_allotments (departure_id, partner_id) WHERE approved_at IS NOT NULL AND ended_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS departure_allotments_pending_uq
    ON booking.departure_allotments (departure_id, partner_id) WHERE approved_at IS NULL AND ended_at IS NULL;
-- The release job: in force and not released yet.
CREATE INDEX IF NOT EXISTS departure_allotments_live_idx
    ON booking.departure_allotments (departure_id)
    WHERE approved_at IS NOT NULL AND ended_at IS NULL AND released_at IS NULL;

COMMENT ON TABLE booking.departure_allotments IS
    'bk-046 (AA-1073, bk-03): seats on one departure reserved for one agency until start_date - release_days_before. Append-only facts; maker-checker approval; a change is a new row replacing the old (ended on approval); released once by bk_allotment_release (allotment.released event). Unused seats (seats minus the agency''s own held + sold) are taken out of the other agencies'' free seats while in force and not released.';
COMMENT ON COLUMN booking.departure_allotments.seats IS 'conf:commercial; seats reserved for the agency on the departure.';
COMMENT ON COLUMN booking.departure_allotments.release_days_before IS
    'Days before the departure start when unused seats go back to the general pool (release on start_date - release_days_before, UTC day).';

CREATE OR REPLACE FUNCTION booking.departure_allotments_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.approved_at IS NOT NULL OR NEW.released_at IS NOT NULL OR NEW.ended_at IS NOT NULL THEN
            RAISE EXCEPTION 'an allotment starts pending: not approved, released or ended' USING ERRCODE = 'check_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM booking.departures d WHERE d.id = NEW.departure_id AND d.status = 'cancelled') THEN
            RAISE EXCEPTION 'departure % is cancelled: it takes no allotment', NEW.departure_id
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.replaces_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM booking.departure_allotments a
             WHERE a.id = NEW.replaces_id AND a.departure_id = NEW.departure_id AND a.partner_id = NEW.partner_id) THEN
            RAISE EXCEPTION 'an allotment replaces one of the same departure and agency' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF (NEW.departure_id, NEW.partner_id, NEW.seats, NEW.release_days_before, NEW.replaces_id, NEW.created_by,
        NEW.created_at)
       IS DISTINCT FROM
       (OLD.departure_id, OLD.partner_id, OLD.seats, OLD.release_days_before, OLD.replaces_id, OLD.created_by,
        OLD.created_at) THEN
        RAISE EXCEPTION 'allotment %: its facts never change (a change is a new allotment)', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.ended_at IS NOT NULL AND (NEW.ended_at, NEW.ended_by, NEW.end_reason, NEW.approved_at, NEW.approved_by,
                                     NEW.released_at)
                                    IS DISTINCT FROM (OLD.ended_at, OLD.ended_by, OLD.end_reason, OLD.approved_at,
                                                      OLD.approved_by, OLD.released_at) THEN
        RAISE EXCEPTION 'allotment % is ended; it is final', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.approved_at IS NOT NULL AND (NEW.approved_at, NEW.approved_by) IS DISTINCT FROM (OLD.approved_at, OLD.approved_by)
    THEN
        RAISE EXCEPTION 'allotment %: approved once', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.released_at IS NOT NULL AND NEW.released_at IS DISTINCT FROM OLD.released_at THEN
        RAISE EXCEPTION 'allotment %: released once', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.released_at IS NULL AND NEW.released_at IS NOT NULL AND NEW.ended_at IS NOT NULL THEN
        RAISE EXCEPTION 'allotment %: an ended allotment is not released', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.departure_allotments_guard() IS
    'bk-046 (AA-1073): an allotment starts pending on a departure that is not cancelled, replaces only one of the same departure and agency; its facts never change; approved once, released once, ended once (final).';

DROP TRIGGER IF EXISTS departure_allotments_guard ON booking.departure_allotments;
CREATE TRIGGER departure_allotments_guard
    BEFORE INSERT OR UPDATE ON booking.departure_allotments
    FOR EACH ROW EXECUTE FUNCTION booking.departure_allotments_guard();

CREATE OR REPLACE FUNCTION booking.departure_allotments_outbox() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.released_at IS NOT NULL AND OLD.released_at IS NULL THEN
        INSERT INTO booking.outbox (stream, event_type, partner_id, departure_id)
        VALUES ('b2b', 'allotment.released', NEW.partner_id, NEW.departure_id);
    END IF;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.departure_allotments_outbox() IS
    'bk-046 (AA-1073): allotment.released to the allotment''s agency when the release job stamps released_at.';

DROP TRIGGER IF EXISTS departure_allotments_outbox ON booking.departure_allotments;
CREATE TRIGGER departure_allotments_outbox
    AFTER UPDATE OF released_at ON booking.departure_allotments
    FOR EACH ROW EXECUTE FUNCTION booking.departure_allotments_outbox();

-- ── Grants (per object) ──────────────────────────────────────────────────────

REVOKE ALL ON booking.departure_allotments FROM booking;
GRANT SELECT, INSERT ON booking.departure_allotments TO booking;
GRANT UPDATE (approved_by, approved_at, released_at, ended_at, ended_by, end_reason)
    ON booking.departure_allotments TO booking;

-- departures: the table grants of bk-020 (SELECT, INSERT, UPDATE) cover the new columns.
GRANT EXECUTE ON FUNCTION booking.departures_outbox() TO booking;
GRANT EXECUTE ON FUNCTION booking.departure_allotments_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.departure_allotments_outbox() TO booking;

DO $$
BEGIN
    IF has_table_privilege('booking', 'booking.departure_allotments', 'DELETE')
       OR has_column_privilege('booking', 'booking.departure_allotments', 'seats', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-046: role booking can delete an allotment or change its seats';
    END IF;
    IF has_table_privilege('cis_app', 'booking.departure_allotments', 'SELECT') THEN
        RAISE EXCEPTION 'bk-046: cis_app can read agency allotments';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-046', now(), 'AA-1073: departures min_to_operate / sales_cutoff_days / decision_days_before / at_risk_at (+ CHECKs), outbox event types departure.at_risk + allotment.released (departures_outbox replaced, trigger on status and at_risk_at), departure_allotments (maker-checker, append-only, guard + release outbox trigger)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
