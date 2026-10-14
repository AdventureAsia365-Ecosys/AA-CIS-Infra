-- Migration bk-006: AA-810 — net cost lines of a SENT version are locked too (S236 review finding 7).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/006_version_cost_sent_lock.sql and is applied to Dev by the DB Migrate workflow
-- (check, then apply), as aa_cis_admin, after bk-004 and bk-005. Never run it from a laptop.
--
-- DEPENDS ON bk-004 (booking.version_item_costs and its lock function) and bk-003
-- (trip_case_versions.is_sent_to_customer / is_approved). It fails on a database without bk-004.
--
-- bk-004 locks a version's cost rows once the version is APPROVED. bk-005 locks a version's commercial
-- fields and items once it is SENT (customer-visible history), but its item lock cannot cover cost rows
-- (bk-005 must not reference bk-004 objects). This file closes the gap: the same function now refuses
-- INSERT / UPDATE / DELETE of a cost row whose item belongs to a version that is approved OR sent, so the
-- costs behind a sent price cannot change. The trigger (bk-004 version_item_costs_lock) is unchanged.
--
-- Re-running the whole file is a no-op (CREATE OR REPLACE, idempotent GRANT, ON CONFLICT DO NOTHING).

BEGIN;

CREATE OR REPLACE FUNCTION booking.version_item_cost_lock() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_item UUID;
BEGIN
    v_item := CASE WHEN TG_OP = 'INSERT' THEN NEW.version_item_id ELSE OLD.version_item_id END;
    IF EXISTS (
           SELECT 1
           FROM booking.trip_case_version_itinerary i
           JOIN booking.trip_case_versions v ON v.id = i.trip_case_version_id
           WHERE i.id = v_item AND (v.is_approved OR v.is_sent_to_customer))
       OR (TG_OP = 'UPDATE' AND EXISTS (
           SELECT 1
           FROM booking.trip_case_version_itinerary i
           JOIN booking.trip_case_versions v ON v.id = i.trip_case_version_id
           WHERE i.id = NEW.version_item_id AND (v.is_approved OR v.is_sent_to_customer)))
    THEN
        RAISE EXCEPTION 'version item % belongs to a sent or approved, locked version', v_item
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.version_item_cost_lock() IS
    'bk-004 + bk-006: cost rows of a sent or approved version cannot be added, changed or removed.';

GRANT EXECUTE ON FUNCTION booking.version_item_cost_lock() TO booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-006', now(), 'AA-810: version_item_cost_lock also refuses cost writes on SENT versions (was approved only)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
