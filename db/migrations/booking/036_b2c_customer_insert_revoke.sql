-- Migration bk-036: AA-1034 R0 — the Booking app role can no longer INSERT into the B2C customer tables.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/036_b2c_customer_insert_revoke.sql; on Dev it is applied by Infra Migration Apply once every
-- job table is idle (root ADR 0017a), as bk_owner (the live owner of schema booking since bk-014). Never run it from a
-- laptop.
--
-- Why (root ADR 0019 "B2B-only ecosystem model", decision d8; S265 record docs/audits/2026-11-03-S265-ecosystem-
-- restructure/ README section 11 R0): Adventure Asia sells to partner agencies only and keeps no end-traveller data
-- of its own. The B2C part of Booking is frozen: the TripPlanner intake (bk_inquiry_pull / bk_inquiry_process) and the
-- staff "new lead" paths are switched off by the B2C_INTAKE_ENABLED flag (default off), and this file makes the
-- freeze hold in the database too, so no code path, old image or script can add a traveller record again.
--
-- What: REVOKE INSERT from role booking on the four B2C PII tables (grants per docs/architecture/db-schema-reference.md):
--   booking.customers            (INSERT, SELECT, UPDATE, DELETE today)
--   booking.customer_identities  (INSERT, SELECT + column UPDATE (customer_id) today)
--   booking.customer_otps        (INSERT, SELECT, UPDATE, DELETE today)
--   booking.customer_sessions    (INSERT, SELECT, UPDATE, DELETE today)
-- SELECT, UPDATE and DELETE stay: staff still read the frozen rows, the retention jobs (bk_retention_job) and an
-- erasure request still update (redact) and delete them. The later drop of these tables follows the destructive-ops
-- DRY RUN procedure in its own file.
--
-- Guard (first apply only): the file refuses while INSERT is still granted on a table that got a row in the last hour.
-- A recent row means the intake is still on (the code with B2C_INTAKE_ENABLED off is not deployed yet, or the flag was
-- turned on): revoking then would make a running intake fail mid-hand-off. Switch the intake off, wait an hour, apply
-- again. The guard is keyed on the registry, not on the current grant: once bk-036 is in shared.schema_versions it does
-- not look at rows any more, so a re-run is a no-op whatever the grants are. That matters for a full replay of every
-- file (the Integration Tests do it): bk-001 / bk-002 / bk-003 grant INSERT on ALL TABLES IN SCHEMA booking and bk-024
-- grants it on customer_identities, so INSERT is granted again when this file replays, next to recent test rows; the
-- REVOKEs below then run unchanged and put the frozen state back.
--
-- Class: contract, not expand (root ADR 0017 d3): it changes the privileges of existing tables. So it merges as a
-- migration-only PR (MIG-4) and Migration Apply runs it when the job tables are idle. No readiness key: no Booking
-- code needs this shape (the code refuses B2C inserts by its own flag first).
--
-- Re-runnable (the Integration Tests replay every file): REVOKE of a privilege not held is a no-op; the guard is skipped
-- once bk-036 is registered.
-- Undo: GRANT INSERT ON booking.customers, booking.customer_identities, booking.customer_otps,
-- booking.customer_sessions TO booking (a later bk- file, only if the B2B-only decision is reversed).

BEGIN;

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-036: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'booking') THEN
        RAISE EXCEPTION 'bk-036: role booking is missing';
    END IF;
    -- First apply only (see the header): a replay finds bk-036 registered and skips the row checks.
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'bk-036') THEN
        IF has_table_privilege('booking', 'booking.customers', 'INSERT')
           AND EXISTS (SELECT 1 FROM booking.customers WHERE created_at > now() - interval '1 hour') THEN
            RAISE EXCEPTION 'bk-036: booking.customers got a row in the last hour; switch the B2C intake off '
                '(B2C_INTAKE_ENABLED) and apply again after an hour without new rows';
        END IF;
        IF has_table_privilege('booking', 'booking.customer_identities', 'INSERT')
           AND EXISTS (SELECT 1 FROM booking.customer_identities WHERE created_at > now() - interval '1 hour') THEN
            RAISE EXCEPTION 'bk-036: booking.customer_identities got a row in the last hour; switch the B2C intake off '
                '(B2C_INTAKE_ENABLED) and apply again after an hour without new rows';
        END IF;
        IF has_table_privilege('booking', 'booking.customer_otps', 'INSERT')
           AND EXISTS (SELECT 1 FROM booking.customer_otps WHERE created_at > now() - interval '1 hour') THEN
            RAISE EXCEPTION 'bk-036: booking.customer_otps got a row in the last hour; switch the B2C intake off '
                '(B2C_INTAKE_ENABLED) and apply again after an hour without new rows';
        END IF;
        IF has_table_privilege('booking', 'booking.customer_sessions', 'INSERT')
           AND EXISTS (SELECT 1 FROM booking.customer_sessions WHERE created_at > now() - interval '1 hour') THEN
            RAISE EXCEPTION 'bk-036: booking.customer_sessions got a row in the last hour; switch the B2C intake off '
                '(B2C_INTAKE_ENABLED) and apply again after an hour without new rows';
        END IF;
    END IF;
END $$;

REVOKE INSERT ON booking.customers FROM booking;
REVOKE INSERT ON booking.customer_identities FROM booking;
REVOKE INSERT ON booking.customer_otps FROM booking;
REVOKE INSERT ON booking.customer_sessions FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-036', now(), 'AA-1034: REVOKE INSERT on the B2C customer tables from role booking (ADR 0019 d8)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
