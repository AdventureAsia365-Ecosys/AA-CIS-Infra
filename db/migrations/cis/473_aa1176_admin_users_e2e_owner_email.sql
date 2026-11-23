-- Migration 473: AA-1176 (S288, A10h) — TEMPORARY exception in shared.admin_users.admin_users_email_chk: the Dev-only
-- E2E owner mailbox, an administrator that may hold the owner marker (never the business owner). Removal is tracked
-- with A10 .. A10g (see "Removal").
--
-- Why. Tech lead decision S288: the orchestrating agent needs "an admin like the tech lead" for live checks that only an
-- owner can run (view-as, Platform > Compliance > Refresh, Staff > Add, a Booking sale exception on a synthetic tour).
-- Every existing E2E identity is read-only or not an owner. Root ADR 0006a A10h: one more WORKFORCE E2E address,
-- e2e-owner@e2e-mail.lumiguides.it.com, groups exactly booking-admin + cis-admin, Dev only, NOT read-only, its sign-in
-- codes in the A10b mailbox prefix that only the MFA admin role can read (AA-CIS-Infra e2e_mailbox.tf, rule
-- e2e-cognito-admin, prefix inbound-admin/). The 462 CHECK refuses an owner row on any E2E address, so this row could
-- not be stored.
--
-- What.
--   1. admin_users_email_chk is replaced (one ALTER TABLE: drop + add, same name) by the 462 rule, byte for byte, OR the
--      one exact A10h address together with its scope: role 'admin', no custom role, NOT the business owner (the
--      business owner marker approves prices and payments as a person: never), no password (a Cognito-only row: no
--      legacy password login under it). is_owner is left free on purpose: the row is written with is_owner = false and
--      the owner marker is set afterwards by the reviewed master run-script AA-CIS-Infra
--      db/scripts/aa1176_e2e_owner_row.py. No pattern, no other address.
--      A CHECK cannot see the environment. The code refuses the address everywhere ENVIRONMENT is not exactly "dev"
--      (api/core/e2e_staff.py is_e2e_owner, api/core/staff_identity.py, api/services/staff_directory.py; AA-Booking and
--      AA-Partner the same), and the WORKFORCE pre token trigger issues its token only with exactly booking-admin +
--      cis-admin and only where E2E_DEV_ONLY_STAFF_ENABLED is exactly "true" (Terraform: dev only, with a precondition).
--   2. COMMENT ON CONSTRAINT says every exception is temporary (it shows in the schema reference dump).
--   3. Register 473.
--   No row is written: the Cognito user comes from AA-CIS-Infra tools/identity/crm_dev_identity.py e2e-owner, the
--   directory row, the Booking grant and the owner marker from the master run-script above (DB Migrate mode=run-script).
--
-- Guards (RAISE on failure, nothing changes):
--   0. before: shared.admin_users exists and the runner owns it or is a member of its owner (ALTER TABLE needs the
--      owner; DB Migrate runs cis/ files as cis_owner since X1 245).
--   1. after: admin_users_email_chk exists, is validated, its definition still names the five 462 E2E addresses, the
--      company domain rule and is_business_owner, no 'reviewer', and names the A10h address; the A10h branch says NOT
--      is_business_owner (checked by evaluating the constraint expression on probe values, not by text search alone).
--
-- Class: contract (root ADR 0017 d3: a replaced CHECK on an existing table). No migrate directive line. Not
-- destructive: the new CHECK is a superset of the 462 one, so every existing row passes. Migration-only PR (MIG-4); the
-- code PR adds 473 to REQUIRED_CIS_ABOVE_GAP (api/core/readiness.py). Applied on Dev by AA-CIS-Infra Migration Apply
-- once every job table is idle (root ADR 0017a).
--
-- Number. 472 is the newest CIS migration on main (23/11/2026). If the owner main max + 1 differs at merge, renumber
-- (git grep '473_' and "'473'": this file, tests/integration/test_aa1176_migration_473.py, api/core/readiness.py, root
-- ADR 0006a A10h).
--
-- Locks. ADD CONSTRAINT CHECK scans the handful of rows under ACCESS EXCLUSIVE for milliseconds; the table is read on
-- every staff verify (60 s cache). lock_timeout 5s. Re-running is a no-op in effect (drop + add the same definition,
-- ON CONFLICT DO NOTHING).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243, AA-CIS-Infra db/owners.yaml). No catalog.* view
-- is touched.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical. After
-- apply: the DB Schema Dump workflow regenerates docs/architecture/db-schema-reference.md; expect the new
-- admin_users_email_chk definition.
--
-- Removal (end of project code, with A10 .. A10g, AA-1054; or at once if the tech lead drops A10h): disable the user on
-- Platform > Staff (or the run-script's REMOVE mode), delete its row (DRY RUN procedure) and its Cognito user, then a
-- NEW migration restores the 462 rule; it RAISEs while a row still uses the address. The code constants, guards and
-- MFA exemptions in AA-CIS-App, AA-Booking and AA-Partner and the Infra trigger entry, receipt rule recipient, tool
-- command and run-script go in the same cleanup.
--
-- Rollback (a new forward migration, after the code is reverted and the A10h row is deleted): put back the 462
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
        RAISE EXCEPTION 'migration 473: shared.admin_users does not exist (migration 074)';
    END IF;
    SELECT pg_catalog.pg_get_userbyid(relowner) INTO owner_name
      FROM pg_catalog.pg_class WHERE oid = 'shared.admin_users'::regclass;
    IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
        RAISE EXCEPTION 'migration 473: shared.admin_users is owned by %, not by the runner % (ALTER TABLE needs the owner)',
            owner_name, current_user;
    END IF;
END $$;

-- ── 1. The 462 rule, plus the A10h owner address with its scope ──────────────────────────────────────────────────
ALTER TABLE shared.admin_users
    DROP CONSTRAINT IF EXISTS admin_users_email_chk,
    ADD CONSTRAINT admin_users_email_chk CHECK (
        email IS NULL
        OR (email = lower(email) AND email ~ '^[^@[:space:]]+@adventure[.]asia$')
        OR (email = 'e2e@e2e-mail.lumiguides.it.com' AND role = 'content' AND NOT is_owner
            AND NOT is_business_owner AND password_hash IS NULL)
        OR (email = 'e2e-cis-admin@e2e-mail.lumiguides.it.com' AND role = 'admin' AND NOT is_owner
            AND NOT is_business_owner AND password_hash IS NULL)
        OR (email = 'e2e-cis-cs@e2e-mail.lumiguides.it.com' AND role = 'customer_success' AND NOT is_owner
            AND NOT is_business_owner AND password_hash IS NULL)
        OR (email = 'e2e-cis-content-lead@e2e-mail.lumiguides.it.com' AND role = 'content_lead'
            AND custom_role IS NULL AND NOT is_owner AND NOT is_business_owner AND password_hash IS NULL)
        OR (email = 'e2e-custom-maker@e2e-mail.lumiguides.it.com' AND role = 'content_lead' AND NOT is_owner
            AND NOT is_business_owner AND password_hash IS NULL)
        OR (email = 'e2e-owner@e2e-mail.lumiguides.it.com' AND role = 'admin' AND custom_role IS NULL
            AND NOT is_business_owner AND password_hash IS NULL));

-- ── 2. Say it is temporary ───────────────────────────────────────────────────────────────────────────────────────
COMMENT ON CONSTRAINT admin_users_email_chk ON shared.admin_users IS
    'AA-816 (247, 250, 283), AA-1035 (363, 375, 378), AA-1155 (462), AA-1176 (473): lower-cased @adventure.asia only. TEMPORARY (250, root ADR 0006a A10): also the E2E test mailbox e2e@e2e-mail.lumiguides.it.com, as content. TEMPORARY (283, A10b, Dev only by code): also e2e-cis-admin@e2e-mail.lumiguides.it.com, as an admin. TEMPORARY (378, A10d, Dev only by code): also e2e-cis-cs@e2e-mail.lumiguides.it.com, as customer_success. TEMPORARY (462, A10f / A10g, Dev only by code): also e2e-cis-content-lead@e2e-mail.lumiguides.it.com as content_lead without a custom role, and e2e-custom-maker@e2e-mail.lumiguides.it.com as content_lead with a custom role. None of those an owner. TEMPORARY (473, A10h, Dev only by code): also e2e-owner@e2e-mail.lumiguides.it.com as an admin without a custom role that may hold the owner marker. None the business owner, none with a password. All removed at the end of project code.';

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
        RAISE EXCEPTION 'migration 473: shared.admin_users has no validated admin_users_email_chk';
    END IF;
    IF position('''e2e@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-cis-admin@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-cis-cs@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-cis-content-lead@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-custom-maker@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-owner@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('is_business_owner' IN def) = 0 OR position('reviewer' IN def) > 0
       OR position('adventure[.]asia' IN def) = 0 THEN
        RAISE EXCEPTION 'migration 473: admin_users_email_chk is not the expected rule: %', def;
    END IF;
    -- The A10h branch never admits the business owner (the text after the address must say so before the next OR).
    IF position('NOT is_business_owner' IN split_part(split_part(def, '''e2e-owner@e2e-mail.lumiguides.it.com''', 2),
                                                        ' OR ', 1)) = 0 THEN
        RAISE EXCEPTION 'migration 473: the A10h branch of admin_users_email_chk does not refuse the business owner: %',
            def;
    END IF;
END $$;

-- ── 3. Register ──────────────────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('473', now(), 'AA-1176 A10h: admin_users_email_chk also allows the Dev-only E2E owner mailbox address (admin, owner marker allowed, never the business owner, no custom role, no password); temporary')
ON CONFLICT (version) DO NOTHING;

COMMIT;
