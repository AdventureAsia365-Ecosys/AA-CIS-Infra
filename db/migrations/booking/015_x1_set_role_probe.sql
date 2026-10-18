-- Migration bk-015: AA-852 (X1 plan S9) — probe only. Proves that DB Migrate runs booking/ files as the live owner
-- of schema booking (bk_owner since bk-014) and that bk_owner can register a file in shared.schema_versions.
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra db/migrations/booking/015_x1_set_role_probe.sql
-- and is applied to Dev by the DB Migrate workflow (check, then apply). Never run it from a laptop.
--
-- Why (X1 plan XD7, AA-Ecosys docs/audits/2026-10-17-S241-x1/x1-plan.md §5 S9): the runner reads the owner of the
-- anchor schema before each file and SET ROLEs to it (XD8). This file is the permanent evidence that the switch
-- works end to end: the guard below fails unless the file runs as bk_owner, and the INSERT needs the CIS 243 grants
-- (USAGE on shared, INSERT on shared.schema_versions) and passes the 243 prefix trigger (bk- keys for bk_owner).
-- It creates and changes nothing else. Assert-only, so no undo file.

BEGIN;

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-015: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF (SELECT nspowner::regrole::text FROM pg_namespace WHERE nspname = 'booking') <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-015: schema booking is not owned by bk_owner';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-015', now(), 'AA-852 (X1 S9): probe, ran as bk_owner (automatic SET ROLE to the live owner of schema booking)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
