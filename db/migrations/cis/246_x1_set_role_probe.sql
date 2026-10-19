-- Migration 246: AA-860 (X1 step S22) — probe only. Proves that DB Migrate logs in as db_migrator and runs cis/
-- files as the live owner of schema shared (cis_owner since 245), and that cis_owner registers the file.
--
-- Owner: AA-CIS-App (key NNN). A byte-identical copy goes to AA-CIS-Infra db/migrations/cis/246_x1_set_role_probe.sql
-- and is applied to Dev by the DB Migrate workflow (check, then apply). Never run it from a laptop.
--
-- Why (X1 plan XD7 / XD8 / S22, AA-Ecosys docs/audits/2026-10-17-S241-x1/x1-plan.md). From S22 the migrator task
-- definition injects db_migrator's DSN, not the RDS master's. The runner reads the owner of the anchor schema
-- (shared) before each file and switches to it (SET LOCAL ROLE cis_owner): db_migrator is a member of cis_owner
-- (Infra role bootstrap rl-002). This file is the permanent evidence of that, like bk-015 / tp-014 for the other
-- owners: the guard fails unless the session user is db_migrator and the current user cis_owner, schema shared is
-- cis_owner's, and db_migrator reaches catalog_owner (what the catalog-view recipe needs; with it the X1 XD9 freeze
-- of catalog.* view changes ends, see CONTEXT.md). Applied before the S22 Terraform switch (master login) it fails
-- and registers nothing, so the key 246 is only ever spent on the real proof.
-- It creates and changes nothing else. Assert-only, so no undo file.

BEGIN;

DO $$
BEGIN
    IF current_user <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 246: expected to run as cis_owner (live owner of schema shared), running as %',
            current_user;
    END IF;
    IF session_user <> 'db_migrator' THEN
        RAISE EXCEPTION 'migration 246: expected the DB Migrate login db_migrator (X1 S22), logged in as %', session_user;
    END IF;
    IF (SELECT nspowner::regrole::text FROM pg_namespace WHERE nspname = 'shared') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 246: schema shared is not owned by cis_owner (245 not applied?)';
    END IF;
    IF NOT pg_has_role(session_user, 'catalog_owner', 'MEMBER') THEN
        RAISE EXCEPTION 'migration 246: db_migrator is not a member of catalog_owner (rl-002): the catalog recipe '
            'would fail';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('246', now(), 'AA-860 (X1 S22): probe, logged in as db_migrator, ran as cis_owner (automatic SET ROLE to the live owner of schema shared)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
