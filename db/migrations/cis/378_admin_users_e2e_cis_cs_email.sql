-- Migration 378: AA-1035 (S270, A10d) — TEMPORARY third exception in shared.admin_users.admin_users_email_chk: the
-- Dev-only read-only E2E customer_success mailbox. Removal is tracked with A10 / A10a / A10b / A10c (see "Removal").
--
-- Why. AA-1035 Done-when: "Live on Dev: a customer_success E2E user sees only the assigned tenants (403 on another
-- tenant)". No E2E identity holds customer_success: the S267 probe proved the scoping through the header path in the
-- container, without a Cognito session. Root ADR 0006a A10d (S270): a fifth WORKFORCE E2E address,
-- e2e-cis-cs@e2e-mail.lumiguides.it.com, group cis-customer_success only, Dev only, read-only with NO write allow-list
-- (api/core/e2e_staff.py, api/middleware/staff_bearer.py, api/core/staff_authz.py), its tenant book synthetic tenants
-- only (api/routers/admin_tenant360.put_tenant_assignment), its sign-in codes in the A10b mailbox prefix that only the
-- MFA admin role can read (AA-CIS-Infra e2e_mailbox.tf, rule e2e-cognito-admin, prefix inbound-admin/). The 375 CHECK
-- allows the company domain, the A10 content row and the A10b admin row only, so this row could not be stored.
--
-- What.
--   1. admin_users_email_chk is replaced (one ALTER TABLE: drop + add, same name) by the 375 rule OR the one exact
--      A10d address together with its scope: role 'customer_success', not an owner (staff.write needs is_owner:
--      never), no password (a Cognito-only row: no legacy password login under it). No pattern, no other address.
--      The code checks the same first (api/services/staff_directory.py _E2E_TEST_STAFF_ROLES / require_e2e_test_scope,
--      which also refuses a Booking grant and CRM roles, and require_dev_only_e2e_environment) and the WORKFORCE pre
--      token trigger (AA-CIS-Infra) issues a token for it only with the cis-customer_success group and only where
--      E2E_DEV_ONLY_STAFF_ENABLED is exactly "true" (Terraform: dev only).
--   2. COMMENT ON CONSTRAINT says every exception is temporary (it shows in the schema reference dump).
--   3. Register 378.
--   No row is written: the account is created after apply through the staff directory (create_staff, ECS exec).
--
-- Guards (RAISE on failure, nothing changes):
--   0. before: shared.admin_users exists and the runner owns it or is a member of its owner (ALTER TABLE needs the
--      owner; DB Migrate runs cis/ files as cis_owner since X1 245).
--   1. after: admin_users_email_chk exists, is validated, and its definition names the three E2E addresses, the
--      content, admin and customer_success roles and the company domain rule, and no 'reviewer' (a CHECK that lost an
--      exception or the domain rule, or brought the alias back, is refused).
--
-- Class: contract (root ADR 0017 d3: a replaced CHECK on an existing table). No `migrate:` directive. Not destructive:
-- the new CHECK is a superset of the 375 one, so every existing row passes. Migration-only PR (MIG-4); the code PR adds
-- 378 to REQUIRED_CIS_ABOVE_GAP (api/core/readiness.py). On Dev it is applied by hand with DB Migrate while CIS 336 is
-- unapplied (the CIS auto-apply waits behind that gap, AA-1024), once every job table is idle (root ADR 0017a).
--
-- Locks. ADD CONSTRAINT CHECK scans the handful of rows under ACCESS EXCLUSIVE for milliseconds; the table is read on
-- every staff verify (60 s cache). lock_timeout 5s. Re-running is a no-op in effect (drop + add the same definition,
-- ON CONFLICT DO NOTHING).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243, AA-CIS-Infra db/owners.yaml). No catalog.* view
-- is touched.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (the migration sync bot copies it);
-- keep the two byte-identical. After apply: the DB Schema Dump workflow regenerates
-- docs/architecture/db-schema-reference.md; expect the new admin_users_email_chk definition.
--
-- Removal (end of project code, with A10 / A10a / A10b / A10c): disable the E2E users, delete their rows (DRY RUN
-- procedure) and their Cognito users, then a NEW migration restores the 247 rule; it RAISEs while a row still uses an
-- E2E address (migration 283's header holds the SQL). The code constants, the scope / environment checks, the
-- read-only cap and the Infra trigger entries, flag, receipt rule and bucket statements go in the same cleanup.
--
-- Rollback (a new forward migration, after the code is reverted and the A10d row is deleted): put back the 375
-- admin_users_email_chk.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: the directory exists and the runner may alter it ────────────────────────────────────────────────────
DO $$
DECLARE
    owner_name text;
BEGIN
    IF to_regclass('shared.admin_users') IS NULL THEN
        RAISE EXCEPTION 'migration 378: shared.admin_users does not exist (migration 074)';
    END IF;
    SELECT pg_catalog.pg_get_userbyid(relowner) INTO owner_name
      FROM pg_catalog.pg_class WHERE oid = 'shared.admin_users'::regclass;
    IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
        RAISE EXCEPTION 'migration 378: shared.admin_users is owned by %, not by the runner % (ALTER TABLE needs the owner)',
            owner_name, current_user;
    END IF;
END $$;

-- ── 1. The 375 rule, plus the A10d customer_success address with its scope ───────────────────────────────────────
ALTER TABLE shared.admin_users
    DROP CONSTRAINT IF EXISTS admin_users_email_chk,
    ADD CONSTRAINT admin_users_email_chk CHECK (
        email IS NULL
        OR (email = lower(email) AND email ~ '^[^@[:space:]]+@adventure[.]asia$')
        OR (email = 'e2e@e2e-mail.lumiguides.it.com' AND role = 'content' AND NOT is_owner
            AND password_hash IS NULL)
        OR (email = 'e2e-cis-admin@e2e-mail.lumiguides.it.com' AND role = 'admin' AND NOT is_owner
            AND password_hash IS NULL)
        OR (email = 'e2e-cis-cs@e2e-mail.lumiguides.it.com' AND role = 'customer_success' AND NOT is_owner
            AND password_hash IS NULL));

-- ── 2. Say it is temporary ───────────────────────────────────────────────────────────────────────────────────────
COMMENT ON CONSTRAINT admin_users_email_chk ON shared.admin_users IS
    'AA-816 (247, 250, 283), AA-1035 (363, 375, 378): lower-cased @adventure.asia only. TEMPORARY (250, root ADR 0006a A10): also the E2E test mailbox e2e@e2e-mail.lumiguides.it.com, as content, not an owner, without a password. TEMPORARY (283, A10b, Dev only by code): also e2e-cis-admin@e2e-mail.lumiguides.it.com, as an admin, not an owner, without a password. TEMPORARY (378, A10d, Dev only by code): also e2e-cis-cs@e2e-mail.lumiguides.it.com, as customer_success, not an owner, without a password. All removed at the end of project code.';

-- ── Guard 1: the constraint is the one this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    def text;
BEGIN
    SELECT pg_catalog.pg_get_constraintdef(oid) INTO def
      FROM pg_catalog.pg_constraint
     WHERE conrelid = 'shared.admin_users'::regclass AND conname = 'admin_users_email_chk'
       AND contype = 'c' AND convalidated;
    IF def IS NULL THEN
        RAISE EXCEPTION 'migration 378: shared.admin_users has no validated admin_users_email_chk';
    END IF;
    IF position('''e2e@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-cis-admin@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-cis-cs@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''content''' IN def) = 0 OR position('''admin''' IN def) = 0
       OR position('''customer_success''' IN def) = 0 OR position('reviewer' IN def) > 0
       OR position('adventure[.]asia' IN def) = 0 THEN
        RAISE EXCEPTION 'migration 378: admin_users_email_chk is not the expected rule: %', def;
    END IF;
END $$;

-- ── 3. Register ──────────────────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('378', now(), 'AA-1035 A10d: admin_users_email_chk also allows the Dev-only E2E customer_success mailbox address (customer_success, no owner, no password); temporary')
ON CONFLICT (version) DO NOTHING;

COMMIT;
