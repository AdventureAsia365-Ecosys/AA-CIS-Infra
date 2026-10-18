-- Migration tp-014: AA-852 — X1 S9: probe only. Proves that DB Migrate runs tripplanner/ files as the live owner of
-- schema tripplanner (tp_owner since tp-013) and that tp_owner can register a file in shared.schema_versions.
--
-- Why. X1 plan XD7 (AA-Ecosys docs/audits/2026-10-17-S241-x1/x1-plan.md §5 S9): the runner reads the owner of the
-- anchor schema before each file and SET ROLEs to it (XD8). This file is the permanent evidence that the switch
-- works end to end: the guard fails unless the file runs as tp_owner, and the INSERT needs the CIS 243 grants
-- (USAGE on shared, INSERT on shared.schema_versions) and passes the 243 prefix trigger (tp- keys for tp_owner).
-- It creates and changes nothing else. Assert-only, so no undo file.

BEGIN;

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-014: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
    IF (SELECT nspowner::regrole::text FROM pg_namespace WHERE nspname = 'tripplanner') <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-014: schema tripplanner is not owned by tp_owner';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-014', now(), 'AA-852 X1 S9: probe, ran as tp_owner (automatic SET ROLE to the live owner of schema tripplanner)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
