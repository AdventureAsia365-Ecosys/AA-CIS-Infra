-- Migration 375: AA-1035 (R2 close-out, S269) — the reviewer alias is removed: the last 'reviewer' row (the A10 E2E
-- account) becomes 'content', and no row may hold 'reviewer' again.
--
-- Why. Root ADR 0019 d3: "reviewer merges into content ... the cis-reviewer group stays as an alias for one release".
-- CIS 363 merged every company reviewer into content and kept ONE row as 'reviewer': the TEMPORARY E2E test account
-- e2e@e2e-mail.lumiguides.it.com (root ADR 0006a A10), because the WORKFORCE pre token trigger (AA-CIS-Infra) issued
-- its tokens only with exactly the group cis-reviewer. 363 said "then the trigger, this row and the CHECK move to
-- content together". The release has passed (R2 slices 1-2 live, S267-S268); this file moves the row and the CHECK.
--
-- What.
--   1. The A10 E2E row (role 'reviewer') becomes 'content'. No other row holds 'reviewer' since 363 (guard 0 below
--      refuses to run if one does: that would be a row someone wrote after 363 with the old code, to look at first).
--   2. admin_users_email_chk is replaced (one ALTER TABLE: drop + add, same name): the 363 rule with the A10 address
--      allowed as 'content' only (363 allowed 'reviewer' or 'content').
--   3. New CHECK admin_users_role_not_alias_chk: role <> 'reviewer'. The enum value shared.admin_role 'reviewer' stays
--      (Postgres can not drop an enum value without rebuilding the type and every column using it); the CHECK keeps it
--      unused, so a code path that still wrote it fails loudly instead of creating an alias row.
--   4. Register 375.
--
-- Guards (RAISE, nothing changes):
--   0. before: shared.admin_users exists and the runner owns it (or is a member of its owner); no row but the A10 E2E
--      address holds 'reviewer'.
--   1. after: no row holds 'reviewer'; both CHECKs exist, are validated and name what this file promises.
--
-- Class: contract (root ADR 0017 d3: UPDATE of an existing table, a replaced CHECK and a new CHECK). No `migrate:`
-- directive. Migration-only PR (MIG-4); the code PR that drops the alias from the code adds 375 to
-- REQUIRED_CIS_ABOVE_GAP (api/core/readiness.py). On Dev it is applied by Infra Migration Apply once every job table
-- is idle (root ADR 0017a; while CIS 336 is unapplied the CIS auto-apply waits behind it, so it is applied by hand).
--
-- Behaviour on apply with the code before the alias removal: the E2E account's group is still cis-reviewer, which that
-- code reads as content (the alias), so its sign-in role equals its row (no `staff_role_drift`) and its access is
-- unchanged (reviewer and content have had the same capabilities since AA-882). The staff reconcile job of that code
-- still expects the E2E row as 'reviewer' and lists it under "known E2E exceptions" with a role note until the code PR
-- ships; nothing is refused. The order after this file: AA-CIS-Infra trigger (E2E account issued with cis-content),
-- move the E2E user's group in the WORKFORCE pool, then the CIS code without the alias, then the cis-reviewer group
-- goes (AA-CIS-Infra).
--
-- Locks. The UPDATE and the two ADD CONSTRAINT CHECKs scan a handful of rows under ACCESS EXCLUSIVE for milliseconds;
-- shared.admin_users is read on every staff verify (60 s cache). lock_timeout 5s. Re-running is a no-op in effect
-- (the UPDATE finds nothing, drop + add the same definitions, ON CONFLICT DO NOTHING).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243, AA-CIS-Infra db/owners.yaml). No catalog.* view
-- is touched.
--
-- Rollback (a new forward migration, after the code is reverted): drop admin_users_role_not_alias_chk, put back the 363
-- admin_users_email_chk and set the E2E row back to 'reviewer' (only if the trigger issues cis-reviewer again).
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: the directory exists, the runner may alter it, and only the A10 row is left as reviewer ──────────
DO $$
DECLARE
    owner_name text;
    left_over integer;
BEGIN
    IF to_regclass('shared.admin_users') IS NULL THEN
        RAISE EXCEPTION 'migration 375: shared.admin_users does not exist (migration 247)';
    END IF;
    SELECT pg_catalog.pg_get_userbyid(relowner) INTO owner_name
      FROM pg_catalog.pg_class WHERE oid = 'shared.admin_users'::regclass;
    IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
        RAISE EXCEPTION 'migration 375: shared.admin_users is owned by %, not by the runner % (ALTER TABLE needs the owner)',
            owner_name, current_user;
    END IF;
    SELECT count(*) INTO left_over FROM shared.admin_users
     WHERE role = 'reviewer' AND email IS DISTINCT FROM 'e2e@e2e-mail.lumiguides.it.com';
    IF left_over > 0 THEN
        RAISE EXCEPTION 'migration 375: % reviewer row(s) other than the A10 E2E account exist (written after 363); '
                        'look at them before removing the alias', left_over;
    END IF;
END $$;

-- ── 1. The A10 E2E row: reviewer -> content ──────────────────────────────────────────────────────────────────────
UPDATE shared.admin_users
   SET role = 'content', updated_at = now()
 WHERE role = 'reviewer'
   AND email = 'e2e@e2e-mail.lumiguides.it.com';

-- ── 2. The 363 rule, the A10 address as content only ─────────────────────────────────────────────────────────────
ALTER TABLE shared.admin_users
    DROP CONSTRAINT IF EXISTS admin_users_email_chk,
    ADD CONSTRAINT admin_users_email_chk CHECK (
        email IS NULL
        OR (email = lower(email) AND email ~ '^[^@[:space:]]+@adventure[.]asia$')
        OR (email = 'e2e@e2e-mail.lumiguides.it.com' AND role = 'content' AND NOT is_owner
            AND password_hash IS NULL)
        OR (email = 'e2e-cis-admin@e2e-mail.lumiguides.it.com' AND role = 'admin' AND NOT is_owner
            AND password_hash IS NULL));

COMMENT ON CONSTRAINT admin_users_email_chk ON shared.admin_users IS
    'AA-816 (247, 250, 283), AA-1035 (363, 375): lower-cased @adventure.asia only. TEMPORARY (250, root ADR 0006a A10): also the E2E test mailbox e2e@e2e-mail.lumiguides.it.com, as content (was reviewer until the alias was removed, 375), not an owner, without a password. TEMPORARY (283, A10b, Dev only by code): also e2e-cis-admin@e2e-mail.lumiguides.it.com, as an admin, not an owner, without a password. Both removed at the end of project code.';

-- ── 3. No alias row again ────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.admin_users
    DROP CONSTRAINT IF EXISTS admin_users_role_not_alias_chk,
    ADD CONSTRAINT admin_users_role_not_alias_chk CHECK (role <> 'reviewer');

COMMENT ON CONSTRAINT admin_users_role_not_alias_chk ON shared.admin_users IS
    'AA-1035 (375, root ADR 0019 d3): reviewer merged into content (363) and the alias is removed; the enum value stays in shared.admin_role (an enum value can not be dropped), this CHECK keeps it unused.';

-- ── Guard 1: the rows and the constraints are what this file promises ─────────────────────────────────────────────
DO $$
DECLARE
    def text;
    left_over integer;
BEGIN
    SELECT count(*) INTO left_over FROM shared.admin_users WHERE role = 'reviewer';
    IF left_over > 0 THEN
        RAISE EXCEPTION 'migration 375: % reviewer row(s) left', left_over;
    END IF;

    SELECT pg_catalog.pg_get_constraintdef(oid) INTO def
      FROM pg_catalog.pg_constraint
     WHERE conrelid = 'shared.admin_users'::regclass AND conname = 'admin_users_email_chk'
       AND contype = 'c' AND convalidated;
    IF def IS NULL THEN
        RAISE EXCEPTION 'migration 375: shared.admin_users has no validated admin_users_email_chk';
    END IF;
    IF position('''e2e@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-cis-admin@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''content''' IN def) = 0 OR position('''reviewer''' IN def) > 0
       OR position('''admin''' IN def) = 0 OR position('adventure[.]asia' IN def) = 0 THEN
        RAISE EXCEPTION 'migration 375: admin_users_email_chk is not the expected rule: %', def;
    END IF;

    SELECT pg_catalog.pg_get_constraintdef(oid) INTO def
      FROM pg_catalog.pg_constraint
     WHERE conrelid = 'shared.admin_users'::regclass AND conname = 'admin_users_role_not_alias_chk'
       AND contype = 'c' AND convalidated;
    IF def IS NULL OR position('''reviewer''' IN def) = 0 THEN
        RAISE EXCEPTION 'migration 375: admin_users_role_not_alias_chk is not the expected rule: %', def;
    END IF;
END $$;

-- ── 4. Register ──────────────────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('375', now(), 'AA-1035: the reviewer alias is removed (A10 E2E row -> content, admin_users_email_chk content only, admin_users_role_not_alias_chk) (root ADR 0019 d3)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
