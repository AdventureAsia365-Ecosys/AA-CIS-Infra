-- Migration bk-033: AA-996 — widen booking.trip_plan_prices.effective_margin from NUMERIC(6, 4) to NUMERIC(12, 4).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/033_trip_plan_prices_margin_width.sql and is applied to Dev by the DB Migrate workflow (check,
-- then apply), as bk_owner (the live owner of schema booking since bk-014). Never run it from a laptop.
--
-- Depends on bk-032 (booking.trip_plan_prices).
--
-- Why: the S254 review of AA-996 slice 2 (Booking #130) widened effective_margin to NUMERIC(12, 4) by editing
-- bk-032 after bk-032 had already been copied to AA-CIS-Infra and applied to Dev with NUMERIC(6, 4). An applied file
-- is never edited: bk-032 is back to the bytes that were applied, and the widening ships here. NUMERIC(6, 4) holds a
-- margin up to 99.9999 (9,999.99 %); the API refuses margins of -100 % or lower (override_too_low) but has no upper
-- bound, so a price far above its net cost could overflow the column and give a 500. NUMERIC(12, 4) matches the
-- column width the API code and its tests were written for.
--
-- Locks: ACCESS EXCLUSIVE on booking.trip_plan_prices for the type change. Raising the precision of a NUMERIC with
-- the same scale is binary-coercible in PostgreSQL 15, so there is no table rewrite and no index rebuild; the table is
-- small on Dev anyway. lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): ALTER COLUMN ... TYPE to the same type is a no-op.
-- Undo (a later bk- file): ALTER COLUMN effective_margin TYPE NUMERIC(6, 4), only while every value fits.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-033: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.trip_plan_prices') IS NULL THEN
        RAISE EXCEPTION 'bk-033: needs bk-032 (booking.trip_plan_prices) first';
    END IF;
END $$;

ALTER TABLE booking.trip_plan_prices
    ALTER COLUMN effective_margin TYPE NUMERIC(12, 4);

DO $$
BEGIN
    IF (SELECT numeric_precision FROM information_schema.columns
        WHERE table_schema = 'booking' AND table_name = 'trip_plan_prices' AND column_name = 'effective_margin') <> 12 THEN
        RAISE EXCEPTION 'bk-033: booking.trip_plan_prices.effective_margin is not NUMERIC(12, 4)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-033', now(), 'AA-996: widen trip_plan_prices.effective_margin to NUMERIC(12, 4) (bk-032 restored to its applied bytes)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
