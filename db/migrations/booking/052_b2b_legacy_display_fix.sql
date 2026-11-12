-- Migration bk-052: AA-1088 (S278 lane l18, M13 follow-up) — the version locks let the one-off display fix of B2B
-- cases confirmed before AA-1013 / AA-1088 rewrite exactly their placeholder titles and their short day spans.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/052_b2b_legacy_display_fix.sql; on Dev it is applied as bk_owner (the live owner of schema
-- booking since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a), or by a person with
-- DB Migrate apply. Never run it from a laptop.
--
-- Why. A B2B confirm writes the trip case and an APPROVED version 1, which the bk-003 locks freeze. Cases confirmed
-- before Booking #163 (AA-1013) carry the placeholder version title "B2B <proposal ref> v<n>" and item titles
-- "<kind> <component id> · line <line ref>"; cases confirmed before Booking #231 (AA-1088) carry an end date and item
-- spans of the highest priced day only (a 6-day tour reads 1 day). The documents already compute the right values;
-- the case header, Trip details and the version still show the old ones (S278 live verify, TC-000028 / TC-000035).
-- The tour name and the tour length live in the CIS catalogue (catalog.v_tour), which only role booking reads, so the
-- values are computed by the app (app/b2b/legacy_cases.py, the same code as #163 / #231) and written as role booking:
-- the locks must let that one write through, and nothing else.
--
-- What: booking.trip_case_version_lock() and booking.trip_case_version_item_lock() (bk-003) are replaced with the same
-- body plus one exception each, open only while the transaction set booking.legacy_display_fix = 'aa1088'
-- (set_config(..., true); the app sets it for the fix only):
--   versions: an UPDATE of an approved B2B version that changes nothing but title (and updated_at / updated_by), whose
--             OLD title is exactly the placeholder of its confirmed hold ('B2B ' || proposal_ref || ' v' ||
--             proposal_version), to a non-empty title;
--   items:    an UPDATE of an item of an approved B2B version that changes nothing but title, day_to (and updated_at),
--             where day_to only grows (at most 366), and the title changes only when the OLD title is exactly the
--             placeholder of the hold's quote line of the same number.
-- Every other write to an approved version or its items is refused exactly as before (same message, same SQLSTATE).
-- A version sent to the customer stays frozen by the bk-005 sent locks (B2B versions are never sent). trip_cases has no
-- lock on end_date: the app moves it directly.
--
-- Class: contract (root ADR 0017 d3): it replaces two existing trigger functions. MIG-4: a migration-only PR first,
-- then the code PR that raises readiness to bk-052 and ships app/b2b/legacy_cases.py. On Dev: Infra Migration Apply
-- once every job table is idle (root ADR 0017a).
-- DM-6.1 / DM-7.1: no new column or table.
-- Locks: CREATE OR REPLACE FUNCTION only (no table lock beyond the catalog row). lock_timeout 5s.
-- Re-runnable: CREATE OR REPLACE; the post-check reads the function bodies.
-- Undo (a later bk- file): CREATE OR REPLACE both functions with bk-003's bodies (the exception blocks removed).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-052: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regprocedure('booking.trip_case_version_lock()') IS NULL
       OR to_regprocedure('booking.trip_case_version_item_lock()') IS NULL THEN
        RAISE EXCEPTION 'bk-052: needs bk-003 (the version lock functions) first';
    END IF;
    IF to_regclass('booking.b2b_holds') IS NULL OR to_regclass('booking.b2b_quote_lines') IS NULL THEN
        RAISE EXCEPTION 'bk-052: needs bk-020 (B2B holds and quote lines) first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-052' AND description NOT LIKE 'AA-1088 legacy B2B display fix:%') THEN
        RAISE EXCEPTION 'bk-052: the key bk-052 is already held by another migration (not AA-1088): renumber one';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION booking.trip_case_version_lock() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF OLD.is_approved THEN
        -- bk-052 (AA-1088): the one-off display fix may replace the pre-AA-1013 placeholder title of a B2B version.
        IF TG_OP = 'UPDATE'
           AND current_setting('booking.legacy_display_fix', true) = 'aa1088'
           AND OLD.channel = 'b2b'
           AND (to_jsonb(NEW) - ARRAY['title', 'updated_at', 'updated_by'])
               = (to_jsonb(OLD) - ARRAY['title', 'updated_at', 'updated_by'])
           AND NEW.title IS NOT NULL AND length(btrim(NEW.title)) BETWEEN 1 AND 200
           AND OLD.title = (SELECT 'B2B ' || h.proposal_ref || ' v' || h.proposal_version
                              FROM booking.b2b_holds h WHERE h.trip_case_id = OLD.trip_case_id)
        THEN
            RETURN NEW;
        END IF;
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
    -- bk-052 (AA-1088): the one-off display fix may give an item of an approved B2B version its tour title (only over
    -- the pre-AA-1013 placeholder) and a longer day span (pre-AA-1088 confirms counted the priced days only).
    IF TG_OP = 'UPDATE'
       AND current_setting('booking.legacy_display_fix', true) = 'aa1088'
       AND NEW.trip_case_version_id = OLD.trip_case_version_id
       AND (to_jsonb(NEW) - ARRAY['title', 'day_to', 'updated_at'])
           = (to_jsonb(OLD) - ARRAY['title', 'day_to', 'updated_at'])
       AND NEW.day_to >= OLD.day_to AND NEW.day_to <= 366
       AND NEW.title IS NOT NULL AND length(btrim(NEW.title)) BETWEEN 1 AND 500
       AND EXISTS (
           SELECT 1 FROM booking.trip_case_versions v
             JOIN booking.b2b_holds h ON h.trip_case_id = v.trip_case_id
            WHERE v.id = OLD.trip_case_version_id AND v.channel = 'b2b' AND v.is_approved
              AND (NEW.title = OLD.title
                   OR OLD.title = (SELECT ql.component_kind || ' ' || ql.component_id || ' · line ' || ql.line_ref
                                     FROM booking.b2b_quote_lines ql
                                    WHERE ql.quote_id = h.quote_id AND ql.line_no = OLD.position)))
    THEN
        RETURN NEW;
    END IF;
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

COMMENT ON FUNCTION booking.trip_case_version_lock() IS
    'bk-003: an approved trip case version is locked. bk-052 (AA-1088): while booking.legacy_display_fix = aa1088, an '
    'approved B2B version may change its pre-AA-1013 placeholder title only (app/b2b/legacy_cases.py).';
COMMENT ON FUNCTION booking.trip_case_version_item_lock() IS
    'bk-003: items of an approved version are locked. bk-052 (AA-1088): while booking.legacy_display_fix = aa1088, an '
    'item of an approved B2B version may replace its placeholder title and lengthen day_to only.';

-- ── Post-check ──────────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'booking'
           AND p.proname IN ('trip_case_version_lock', 'trip_case_version_item_lock')
           AND p.prosrc LIKE '%legacy_display_fix%'
           AND pg_get_userbyid(p.proowner) = 'bk_owner') <> 2 THEN
        RAISE EXCEPTION 'bk-052: the two lock functions do not carry the display fix exception (or are not bk_owner''s)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-052', now(), 'AA-1088 legacy B2B display fix: the version locks let the one-off fix replace placeholder '
                         'titles and lengthen item spans of B2B cases confirmed before AA-1013 / AA-1088')
ON CONFLICT (version) DO NOTHING;

COMMIT;
