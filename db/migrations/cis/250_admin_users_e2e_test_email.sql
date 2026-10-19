-- Migration 250: AA-816 — TEMPORARY exception in shared.admin_users.admin_users_email_chk for the Cognito
-- email-code E2E test account. Removal is tracked on AA-816 (see "Removal" below).
--
-- Why. The E2E test (AA-CIS-App .github/workflows/e2e-cognito.yml) signs in through the WORKFORCE pool with an
-- email one-time code and reads that code from the SES inbound test mailbox. S243 decision (Nghiệp, 19/10/2026,
-- option B; root ADR 0006a amendment): the staff user's address IS that mailbox, e2e@e2e-mail.lumiguides.it.com,
-- instead of a company address forwarded to it. The directory CHECK from 247 allows @adventure.asia only, so
-- the row could not be stored.
--
-- What.
--   1. admin_users_email_chk is replaced (one ALTER TABLE: drop + add, same name) by the 247 rule OR the one
--      exact address together with the scope the E2E account is allowed: role 'reviewer', not an owner, no
--      password (a Cognito-only row: no legacy password login under it). No pattern, no other address. The code
--      checks the same first (api/services/staff_directory.py E2E_TEST_STAFF_EMAIL / require_e2e_test_scope,
--      which also refuses a Booking grant for it) and the WORKFORCE pre token trigger (AA-CIS-Infra) issues a
--      token for it only with the cis-reviewer group.
--   2. COMMENT ON CONSTRAINT says the exception is temporary (it shows in the schema reference dump).
--   3. Register 250.
--   No row is written: the account is created after apply through the staff directory (create_staff).
--
-- Guards (RAISE on failure, nothing changes):
--   0. before: shared.admin_users has the 247 email column and the runner owns the table or is a member of its
--      owner (ALTER TABLE needs the owner; after X1 245 DB Migrate runs cis/ files as cis_owner).
--   1. after: admin_users_email_chk exists, is validated, and its definition names the address and the reviewer
--      role (a CHECK that lost the exception, or that lost the domain rule, is refused).
--
-- Locks. ADD CONSTRAINT CHECK scans the handful of rows under ACCESS EXCLUSIVE for milliseconds; the table is
-- read on every staff verify (60 s cache). lock_timeout 5s. Not destructive (no `migrate:` directive): dropping a
-- CHECK only removes a constraint and the new one is a superset of the old one, so every existing row passes.
-- Re-running is a no-op in effect (drop + add the same definition, ON CONFLICT DO NOTHING).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243, AA-CIS-Infra db/owners.yaml). No catalog.*
-- view is touched.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the
-- two byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow);
-- expect the new admin_users_email_chk definition.
--
-- Removal (when the E2E work is finished, AA-816): disable the E2E user, delete its row (DRY RUN procedure) and its
-- Cognito user, then a NEW migration restores the 247 rule; it must RAISE while a row still uses the address:
--   ALTER TABLE shared.admin_users DROP CONSTRAINT IF EXISTS admin_users_email_chk,
--       ADD CONSTRAINT admin_users_email_chk CHECK (
--           email IS NULL OR (email = lower(email) AND email ~ '^[^@[:space:]]+@adventure[.]asia$'));
-- and the code constant, the scope checks and the Infra trigger exception go in the same cleanup.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: the 247 directory exists and the runner may alter it ───────────────────────────────
DO $$
DECLARE
    owner_name text;
BEGIN
    IF to_regclass('shared.admin_users') IS NULL THEN
        RAISE EXCEPTION 'migration 250: shared.admin_users does not exist (migration 074)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
                    WHERE attrelid = 'shared.admin_users'::regclass AND attname = 'email' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 250: shared.admin_users.email does not exist (migration 247)';
    END IF;
    SELECT pg_catalog.pg_get_userbyid(relowner) INTO owner_name
      FROM pg_catalog.pg_class WHERE oid = 'shared.admin_users'::regclass;
    IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
        RAISE EXCEPTION 'migration 250: shared.admin_users is owned by %, not by the runner % (ALTER TABLE needs the owner)',
            owner_name, current_user;
    END IF;
END $$;

-- ── 1. The 247 rule, or the one E2E test address with its scope ─────────────────────────────────
ALTER TABLE shared.admin_users
    DROP CONSTRAINT IF EXISTS admin_users_email_chk,
    ADD CONSTRAINT admin_users_email_chk CHECK (
        email IS NULL
        OR (email = lower(email) AND email ~ '^[^@[:space:]]+@adventure[.]asia$')
        OR (email = 'e2e@e2e-mail.lumiguides.it.com' AND role = 'reviewer' AND NOT is_owner
            AND password_hash IS NULL));

-- ── 2. Say it is temporary ───────────────────────────────────────────────────────────────────────
COMMENT ON CONSTRAINT admin_users_email_chk ON shared.admin_users IS
    'AA-816 (247, 250): lower-cased @adventure.asia only. TEMPORARY (250, root ADR 0006a): also the one E2E test mailbox e2e@e2e-mail.lumiguides.it.com, as a reviewer, not an owner, without a password. Removed when the Cognito E2E work is finished.';

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
        RAISE EXCEPTION 'migration 250: shared.admin_users has no validated admin_users_email_chk';
    END IF;
    IF position('e2e@e2e-mail.lumiguides.it.com' IN def) = 0 OR position('reviewer' IN def) = 0
       OR position('adventure[.]asia' IN def) = 0 THEN
        RAISE EXCEPTION 'migration 250: admin_users_email_chk is not the expected rule: %', def;
    END IF;
END $$;

-- ── 3. Register ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('250', now(), 'AA-816: admin_users_email_chk allows the E2E test mailbox address (reviewer, no owner, no password); temporary')
ON CONFLICT (version) DO NOTHING;

COMMIT;
