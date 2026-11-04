-- Migration 363: AA-1035 (R2 slice 1, S267) — reviewer merges into content; the Booking grant gains 'finance'.
--
-- Why. Root ADR 0019 d3: "reviewer merges into content. The same CIS migration fixes admin_users_email_chk, and the
-- cis-reviewer group stays as an alias for one release", and Booking gains a finance role whose CIS half is
-- `'finance'` in staff_app_grant_role_chk (the check is on shared.staff_app_grant, owner cis_owner, so Booking may
-- not migrate it). The new enum values come from CIS 362 (its own file: a value added in a transaction can not be
-- used in it); nothing here names one of them.
--
-- What.
--   1. Every shared.admin_users row with role 'reviewer' becomes 'content' (the two roles have had the same
--      capabilities since AA-882; api/core/staff_authz.py keeps 'reviewer' as an alias of content for one release),
--      EXCEPT the TEMPORARY E2E test account e2e@e2e-mail.lumiguides.it.com: the WORKFORCE pre token trigger
--      (AA-CIS-Infra) issues its tokens only with exactly the group cis-reviewer, so its row stays 'reviewer' until
--      the alias is removed (then the trigger, this row and the CHECK move to content together).
--   2. The column default of shared.admin_users.role becomes 'content' (was 'reviewer', migration 074). Every writer
--      sets the role explicitly; the default only stops a forgotten column from creating an alias row.
--   3. admin_users_email_chk is replaced (one ALTER TABLE: drop + add, same name): the 283 rule, with the A10 E2E
--      address allowed as 'reviewer' (today) or 'content' (after the alias). Superset of 283, so every row passes.
--   4. staff_app_grant_role_chk is replaced (same name): 'admin', 'sales', 'contracting', 'content_creator' and
--      'finance' (Booking reads the finance role from the WORKFORCE group booking-finance, which the CIS Staff page
--      grants through this row).
--   5. Register 363.
--
-- Guards (RAISE, nothing changes):
--   0. before: shared.admin_users and shared.staff_app_grant exist with their 247 columns and the runner owns them or
--      is a member of their owner (ALTER TABLE needs the owner; DB Migrate runs cis/ files as cis_owner since X1 245).
--   1. after: no row but the A10 E2E address holds 'reviewer'; both CHECKs exist, are validated and name what this
--      file promises (the 283 addresses, the company domain rule, 'content' and 'finance').
--
-- Class: contract (root ADR 0017 d3: UPDATE of an existing table, a column default, two replaced CHECKs). No
-- `migrate:` directive. On Dev it is applied by Infra Migration Apply when every job table is idle (root ADR 0017a),
-- in the batch 362-364, before the R2 code PR (readiness 364).
--
-- Behaviour on apply with the code before R2: a merged reviewer reads every page and calls every route it did (same
-- capabilities); the identity resolver logs `staff_role_drift` (group cis-reviewer, row content), which is not a
-- refusal. The staff directory "Sync" moves such a person to the group cis-content once the R2 code runs (the
-- reconcile job lists them meanwhile).
--
-- Locks. The UPDATE and the two ADD CONSTRAINT CHECKs scan a handful of rows under ACCESS EXCLUSIVE for milliseconds;
-- shared.admin_users is read on every staff verify (60 s cache). lock_timeout 5s. Re-running is a no-op in effect
-- (the UPDATE finds nothing, drop + add the same definitions, ON CONFLICT DO NOTHING).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243, AA-CIS-Infra db/owners.yaml). No catalog.* view
-- is touched.
--
-- Rollback (a new forward migration, after the code is reverted): the CHECK definitions of 283 and 247; rows merged
-- here stay 'content' (no information was lost: the two roles had the same capabilities).
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: the 247 directory exists and the runner may alter it ───────────────────────────────
DO $$
DECLARE
    rel text;
    owner_name text;
BEGIN
    FOREACH rel IN ARRAY ARRAY['shared.admin_users', 'shared.staff_app_grant'] LOOP
        IF to_regclass(rel) IS NULL THEN
            RAISE EXCEPTION 'migration 363: % does not exist (migration 247)', rel;
        END IF;
        SELECT pg_catalog.pg_get_userbyid(relowner) INTO owner_name
          FROM pg_catalog.pg_class WHERE oid = rel::regclass;
        IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
            RAISE EXCEPTION 'migration 363: % is owned by %, not by the runner % (ALTER TABLE needs the owner)',
                rel, owner_name, current_user;
        END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
                    WHERE attrelid = 'shared.admin_users'::regclass AND attname = 'email' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 363: shared.admin_users.email does not exist (migration 247)';
    END IF;
END $$;

-- ── 1. reviewer -> content (the A10 E2E row keeps its trigger-bound role until the alias goes) ──
UPDATE shared.admin_users
   SET role = 'content', updated_at = now()
 WHERE role = 'reviewer'
   AND email IS DISTINCT FROM 'e2e@e2e-mail.lumiguides.it.com';

-- ── 2. No alias row by default ───────────────────────────────────────────────────────────────────
ALTER TABLE shared.admin_users ALTER COLUMN role SET DEFAULT 'content';

-- ── 3. The 283 rule, the A10 address also as content ─────────────────────────────────────────────
ALTER TABLE shared.admin_users
    DROP CONSTRAINT IF EXISTS admin_users_email_chk,
    ADD CONSTRAINT admin_users_email_chk CHECK (
        email IS NULL
        OR (email = lower(email) AND email ~ '^[^@[:space:]]+@adventure[.]asia$')
        OR (email = 'e2e@e2e-mail.lumiguides.it.com' AND role IN ('reviewer', 'content') AND NOT is_owner
            AND password_hash IS NULL)
        OR (email = 'e2e-cis-admin@e2e-mail.lumiguides.it.com' AND role = 'admin' AND NOT is_owner
            AND password_hash IS NULL));

COMMENT ON CONSTRAINT admin_users_email_chk ON shared.admin_users IS
    'AA-816 (247, 250, 283), AA-1035 (363): lower-cased @adventure.asia only. TEMPORARY (250, root ADR 0006a A10): also the E2E test mailbox e2e@e2e-mail.lumiguides.it.com, as a reviewer (content once the cis-reviewer alias is removed, root ADR 0019 d3), not an owner, without a password. TEMPORARY (283, A10b, Dev only by code): also e2e-cis-admin@e2e-mail.lumiguides.it.com, as an admin, not an owner, without a password. Both removed at the end of project code.';

-- ── 4. The Booking grant gains finance ───────────────────────────────────────────────────────────
ALTER TABLE shared.staff_app_grant
    DROP CONSTRAINT IF EXISTS staff_app_grant_role_chk,
    ADD CONSTRAINT staff_app_grant_role_chk CHECK (
        role IN ('admin', 'sales', 'contracting', 'content_creator', 'finance'));

COMMENT ON COLUMN shared.staff_app_grant.role IS
    'AA-816 (247), AA-1035 (363): the Booking role of the staff member = WORKFORCE group booking-<role> (admin, sales, contracting, content_creator, finance; root ADR 0019 d3 / d9).';

-- ── Guard 1: the rows and the constraints are what this file promises ────────────────────────────
DO $$
DECLARE
    def text;
    left_over integer;
BEGIN
    SELECT count(*) INTO left_over FROM shared.admin_users
     WHERE role = 'reviewer' AND email IS DISTINCT FROM 'e2e@e2e-mail.lumiguides.it.com';
    IF left_over > 0 THEN
        RAISE EXCEPTION 'migration 363: % reviewer row(s) were not merged into content', left_over;
    END IF;

    SELECT pg_catalog.pg_get_constraintdef(oid) INTO def
      FROM pg_catalog.pg_constraint
     WHERE conrelid = 'shared.admin_users'::regclass AND conname = 'admin_users_email_chk'
       AND contype = 'c' AND convalidated;
    IF def IS NULL THEN
        RAISE EXCEPTION 'migration 363: shared.admin_users has no validated admin_users_email_chk';
    END IF;
    IF position('''e2e@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-cis-admin@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''content''' IN def) = 0 OR position('''reviewer''' IN def) = 0
       OR position('''admin''' IN def) = 0 OR position('adventure[.]asia' IN def) = 0 THEN
        RAISE EXCEPTION 'migration 363: admin_users_email_chk is not the expected rule: %', def;
    END IF;

    SELECT pg_catalog.pg_get_constraintdef(oid) INTO def
      FROM pg_catalog.pg_constraint
     WHERE conrelid = 'shared.staff_app_grant'::regclass AND conname = 'staff_app_grant_role_chk'
       AND contype = 'c' AND convalidated;
    IF def IS NULL OR position('''finance''' IN def) = 0 OR position('''content_creator''' IN def) = 0 THEN
        RAISE EXCEPTION 'migration 363: staff_app_grant_role_chk is not the expected rule: %', def;
    END IF;
END $$;

-- ── 5. Register ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('363', now(), 'AA-1035: reviewer merges into content (A10 E2E row excepted), admin_users_email_chk and staff_app_grant_role_chk (finance) fixed (root ADR 0019 d3)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
