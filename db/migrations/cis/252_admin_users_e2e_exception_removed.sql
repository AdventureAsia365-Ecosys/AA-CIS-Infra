-- Migration 252: AA-816 — remove the TEMPORARY E2E test-mailbox exception that migration 250 added to
-- shared.admin_users.admin_users_email_chk (root ADR 0006a A10, removal step 3).
--
-- Why. 250 let one non-company address, e2e@e2e-mail.lumiguides.it.com (the SES inbound test mailbox), be a staff
-- address so the Cognito email-code E2E test could sign in. The E2E user is now the ordinary reviewer
-- e2e-cognito@adventure.asia, whose mail the adventure.asia mail host forwards to that mailbox, so the exception
-- is no longer needed. The code check went in the same cleanup (api/services/staff_directory.py), and the WORKFORCE
-- trigger exception went too (AA-CIS-Infra).
--
-- What.
--   1. admin_users_email_chk is replaced (one ALTER TABLE: drop + add, same name) by the 247 rule again:
--      NULL, or a lower-cased address ending in exactly @adventure.asia (no sub-domain).
--   2. COMMENT ON CONSTRAINT records that 252 removed the 250 exception (it shows in the schema reference dump).
--   3. Register 252.
--   No row is written or deleted here. The old E2E row is deleted BEFORE this file runs, by AA-CIS-Infra
--   db/scripts/aa816_delete_e2e_test_staff.py (DRY RUN procedure).
--
-- Guards (RAISE on failure, nothing changes):
--   0. before: shared.admin_users has the 247 email column, and the runner owns the table or is a member of its
--      owner (ALTER TABLE needs the owner; DB Migrate runs cis/ files as cis_owner).
--   A. before: no row still has the old E2E address (in any case), and no non-NULL email breaks the 247 rule. The
--      RAISE gives the count, never an address. ADD CONSTRAINT would fail on such a row anyway; this guard makes the
--      failure say why (delete the row first).
--   1. after: admin_users_email_chk exists, is validated, names adventure[.]asia, and names neither lumiguides
--      nor reviewer (a CHECK that still carries the exception is refused).
--
-- Locks. ADD CONSTRAINT CHECK scans the handful of rows under ACCESS EXCLUSIVE for milliseconds; the table is
-- read on every staff verify (60 s cache). lock_timeout 5s. Not destructive (no `migrate:` directive): the new
-- CHECK is narrower than 250's, but guard A proves first that every row already passes it, and no data changes.
-- Re-running is a no-op in effect (drop + add the same definition, ON CONFLICT DO NOTHING).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243, AA-CIS-Infra db/owners.yaml). No catalog.*
-- view is touched.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the
-- two byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow);
-- expect the 247 admin_users_email_chk definition and this file's comment.
--
-- Rollback (only together with the old code and trigger): re-apply the 250 constraint definition and comment
-- (api/migrations/250_admin_users_e2e_test_email.sql, step 1 and step 2) in a new migration.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: the 247 directory exists and the runner may alter it ───────────────────────────────
DO $$
DECLARE
    owner_name text;
BEGIN
    IF to_regclass('shared.admin_users') IS NULL THEN
        RAISE EXCEPTION 'migration 252: shared.admin_users does not exist (migration 074)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
                    WHERE attrelid = 'shared.admin_users'::regclass AND attname = 'email' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 252: shared.admin_users.email does not exist (migration 247)';
    END IF;
    SELECT pg_catalog.pg_get_userbyid(relowner) INTO owner_name
      FROM pg_catalog.pg_class WHERE oid = 'shared.admin_users'::regclass;
    IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
        RAISE EXCEPTION 'migration 252: shared.admin_users is owned by %, not by the runner % (ALTER TABLE needs the owner)',
            owner_name, current_user;
    END IF;
END $$;

-- ── Guard A: every row already passes the 247 rule ──────────────────────────────────────────────
DO $$
DECLARE
    e2e_rows bigint;
    off_rule bigint;
BEGIN
    SELECT count(*) FILTER (WHERE lower(btrim(email)) = 'e2e@e2e-mail.lumiguides.it.com'),
           count(*) FILTER (WHERE email IS NOT NULL
                              AND NOT (email = lower(email) AND email ~ '^[^@[:space:]]+@adventure[.]asia$'))
      INTO e2e_rows, off_rule
      FROM shared.admin_users;
    IF e2e_rows > 0 OR off_rule > 0 THEN
        RAISE EXCEPTION 'migration 252: % row(s) still use the old E2E test address and % row(s) break the @adventure.asia rule; delete the E2E row first (AA-CIS-Infra db/scripts/aa816_delete_e2e_test_staff.py)',
            e2e_rows, off_rule;
    END IF;
END $$;

-- ── 1. The 247 rule again ────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.admin_users
    DROP CONSTRAINT IF EXISTS admin_users_email_chk,
    ADD CONSTRAINT admin_users_email_chk CHECK (
        email IS NULL OR (email = lower(email) AND email ~ '^[^@[:space:]]+@adventure[.]asia$'));

-- ── 2. Say the exception is gone ─────────────────────────────────────────────────────────────────
COMMENT ON CONSTRAINT admin_users_email_chk ON shared.admin_users IS
    'AA-816 (247, 252): lower-cased @adventure.asia only; the temporary 250 E2E exception was removed by 252';

-- ── Guard 1: the constraint is the one this file promises ────────────────────────────────────────
DO $$
DECLARE
    def text;
BEGIN
    SELECT pg_catalog.pg_get_constraintdef(oid) INTO def
      FROM pg_catalog.pg_constraint
     WHERE conrelid = 'shared.admin_users'::regclass AND conname = 'admin_users_email_chk'
       AND contype = 'c' AND convalidated;
    IF def IS NULL THEN
        RAISE EXCEPTION 'migration 252: shared.admin_users has no validated admin_users_email_chk';
    END IF;
    IF position('adventure[.]asia' IN def) = 0 OR position('lumiguides' IN def) > 0
       OR position('reviewer' IN def) > 0 THEN
        RAISE EXCEPTION 'migration 252: admin_users_email_chk is not the expected rule: %', def;
    END IF;
END $$;

-- ── 3. Register ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('252', now(), 'AA-816: admin_users_email_chk back to @adventure.asia only (the temporary 250 E2E exception is removed)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
