-- Migration 283: AA-816 (S252, A10b) — TEMPORARY second exception in shared.admin_users.admin_users_email_chk:
-- the Dev-only E2E CIS admin mailbox. Removal is tracked on AA-816 with A10 / A10a (see "Removal" below).
--
-- Why. The orchestrating agent must sign itself in to the CIS admin as an ADMIN to screenshot the admin-only pages
-- (/admin/content-quality, /admin/writing-memory) and produce the AA-916 WM-07 sentence-action sample; the A10
-- account e2e@ is a reviewer only. Root ADR 0006a A10b (S252): a third WORKFORCE E2E address,
-- e2e-cis-admin@e2e-mail.lumiguides.it.com, group cis-admin only, Dev only, read-only except the content-quality
-- sentence-apply routes (api/middleware/staff_bearer.py), its sign-in codes in a separate mailbox prefix that only
-- the MFA admin role can read (AA-CIS-Infra e2e_mailbox.tf, rule e2e-cognito-admin, prefix inbound-admin/). The
-- directory CHECK from 250 allows the 247 rule and the A10 reviewer only, so the row could not be stored.
--
-- What.
--   1. admin_users_email_chk is replaced (one ALTER TABLE: drop + add, same name) by the 250 rule OR the one exact
--      A10b address together with its scope: role 'admin', not an owner (staff.write needs is_owner: never), no
--      password (a Cognito-only row: no legacy password login under it). No pattern, no other address. The code
--      checks the same first (api/services/staff_directory.py E2E_CIS_ADMIN_TEST_STAFF_EMAIL /
--      require_e2e_test_scope, which also refuses a Booking grant, and require_dev_only_e2e_environment) and the
--      WORKFORCE pre token trigger (AA-CIS-Infra) issues a token for it only with the cis-admin group and only
--      where E2E_DEV_ONLY_STAFF_ENABLED is exactly "true" (Terraform: dev only).
--   2. COMMENT ON CONSTRAINT says both exceptions are temporary (it shows in the schema reference dump).
--   3. Register 283.
--   No row is written: the account is created after apply through the staff directory (create_staff).
--
-- Guards (RAISE on failure, nothing changes):
--   0. before: shared.admin_users has the 247 email column and the runner owns the table or is a member of its
--      owner (ALTER TABLE needs the owner; DB Migrate runs cis/ files as cis_owner since X1 245).
--   1. after: admin_users_email_chk exists, is validated, and its definition names both addresses, the reviewer and
--      the admin role and the company domain rule (a CHECK that lost an exception or the domain rule is refused).
--
-- Locks. ADD CONSTRAINT CHECK scans the handful of rows under ACCESS EXCLUSIVE for milliseconds; the table is read
-- on every staff verify (60 s cache). lock_timeout 5s. Not destructive (no `migrate:` directive): dropping a CHECK
-- only removes a constraint and the new one is a superset of the 250 one, so every existing row passes.
-- Re-running is a no-op in effect (drop + add the same definition, ON CONFLICT DO NOTHING).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243, AA-CIS-Infra db/owners.yaml). No catalog.*
-- view is touched.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the
-- two byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow);
-- expect the new admin_users_email_chk definition.
--
-- Removal (end of project code, AA-816, with A10 / A10a): disable both E2E users, delete their rows (DRY RUN
-- procedure) and their Cognito users, then a NEW migration restores the 247 rule; it RAISEs while a row still uses
-- either E2E address:
--   ALTER TABLE shared.admin_users DROP CONSTRAINT IF EXISTS admin_users_email_chk,
--       ADD CONSTRAINT admin_users_email_chk CHECK (
--           email IS NULL OR (email = lower(email) AND email ~ '^[^@[:space:]]+@adventure[.]asia$'));
-- and the code constants, the scope / environment checks, the read-only cap and the Infra trigger entries, flag,
-- receipt rule and bucket statements go in the same cleanup.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: the 247 directory exists and the runner may alter it ───────────────────────────────
DO $$
DECLARE
    owner_name text;
BEGIN
    IF to_regclass('shared.admin_users') IS NULL THEN
        RAISE EXCEPTION 'migration 283: shared.admin_users does not exist (migration 074)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
                    WHERE attrelid = 'shared.admin_users'::regclass AND attname = 'email' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 283: shared.admin_users.email does not exist (migration 247)';
    END IF;
    SELECT pg_catalog.pg_get_userbyid(relowner) INTO owner_name
      FROM pg_catalog.pg_class WHERE oid = 'shared.admin_users'::regclass;
    IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
        RAISE EXCEPTION 'migration 283: shared.admin_users is owned by %, not by the runner % (ALTER TABLE needs the owner)',
            owner_name, current_user;
    END IF;
END $$;

-- ── 1. The 247 rule, the A10 reviewer, or the A10b admin, each with its scope ───────────────────
ALTER TABLE shared.admin_users
    DROP CONSTRAINT IF EXISTS admin_users_email_chk,
    ADD CONSTRAINT admin_users_email_chk CHECK (
        email IS NULL
        OR (email = lower(email) AND email ~ '^[^@[:space:]]+@adventure[.]asia$')
        OR (email = 'e2e@e2e-mail.lumiguides.it.com' AND role = 'reviewer' AND NOT is_owner
            AND password_hash IS NULL)
        OR (email = 'e2e-cis-admin@e2e-mail.lumiguides.it.com' AND role = 'admin' AND NOT is_owner
            AND password_hash IS NULL));

-- ── 2. Say it is temporary ───────────────────────────────────────────────────────────────────────
COMMENT ON CONSTRAINT admin_users_email_chk ON shared.admin_users IS
    'AA-816 (247, 250, 283): lower-cased @adventure.asia only. TEMPORARY (250, root ADR 0006a A10): also the E2E test mailbox e2e@e2e-mail.lumiguides.it.com, as a reviewer, not an owner, without a password. TEMPORARY (283, A10b, Dev only by code): also e2e-cis-admin@e2e-mail.lumiguides.it.com, as an admin, not an owner, without a password. Both removed at the end of project code.';

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
        RAISE EXCEPTION 'migration 283: shared.admin_users has no validated admin_users_email_chk';
    END IF;
    IF position('''e2e@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-cis-admin@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('reviewer' IN def) = 0 OR position('''admin''' IN def) = 0
       OR position('adventure[.]asia' IN def) = 0 THEN
        RAISE EXCEPTION 'migration 283: admin_users_email_chk is not the expected rule: %', def;
    END IF;
END $$;

-- ── 3. Register ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('283', now(), 'AA-816 A10b: admin_users_email_chk also allows the Dev-only E2E CIS admin mailbox address (admin, no owner, no password); temporary')
ON CONFLICT (version) DO NOTHING;

COMMIT;
