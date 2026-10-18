-- Migration 247: AA-816 / AA-854 (Cognito Phase 1, ADR 0006) — shared.admin_users becomes the staff
-- directory: Cognito identity columns, an owner flag, a nullable password hash, and the per-app grant
-- table shared.staff_app_grant.
--
-- Why. Phase 1 (ADR 0006 "Phasing", row 1) signs CIS staff in through the WORKFORCE pool. The directory
-- (shared.admin_users) is the source of truth for who is staff (ADR 0006 §"Staff directory"): each row
-- needs the person's @adventure.asia address (the pool's username and the link key for the first
-- sign-in), a display name, and the Cognito identity it is bound to. The identity key is the PAIR
-- (iss, sub) (ADR 0006 §9): `sub` alone is unique only inside one pool, and a pool rebuild or a future
-- production pool issues new values. A Cognito-only staff member has no password, so password_hash
-- becomes nullable (ADR 0006: "password_hash becomes nullable and is dropped after cutover"); the legacy
-- password login refuses a NULL hash with the same 401 as a wrong password (api/main.py admin_login,
-- api/routers/auth.py _verify_password). Booking roles live in a grant table, not a per-app column
-- (S241 decision Q3, judge plan S242 C1): one row per (person, app), so a later app adds CHECK values,
-- not columns. The CIS role stays in admin_users.role, NOT NULL (S241 decision Q3).
--
-- What.
--   1. shared.admin_users gains (all additive; existing rows get NULL / false):
--        email          text  — lower-cased, ends in @adventure.asia (CHECK), unique on lower(email);
--        display_name   text;
--        cognito_iss    text  — the token issuer URL (https://…), set together with cognito_sub (CHECK);
--        cognito_sub    text  — unique together with cognito_iss;
--        last_login_at  timestamptz;
--        is_owner       boolean NOT NULL DEFAULT false — who may write the staff directory
--                       (staff.write, owner-only, AA-816 AC). Left false for every existing row here:
--                       the owner flag is set by the one-off link script (plan step C8,
--                       scripts/link_staff_identity.py), not by a migration;
--      password_hash loses NOT NULL; role keeps it.
--   2. shared.staff_app_grant (admin_user_id → shared.admin_users(id) ON DELETE CASCADE, app, role,
--      created_at, updated_at; PK (admin_user_id, app)). app ∈ {booking}; role ∈ the Booking staff roles
--      {admin, sales, contracting, content_creator} (Booking bk-003 staff_users_role_chk, ADR 0006 groups
--      booking-*). No data.
--   3. Grants and RLS: shared.admin_users has neither today (owner aa_cis_admin, no grant to any other
--      role, RLS off — schema reference 16/10), and the new table copies that: no GRANT, no RLS. CIS 244
--      (X1 S16) grants cis_app on ALL TABLES of shared and sets default privileges, so the new table is
--      covered whichever lands first (before 244: ON ALL TABLES; after it: 244's default privileges for
--      the runner). A guard checks that the grant table is never MORE reachable than the directory: no
--      non-owner grant that shared.admin_users lacks, and the same RLS / FORCE flags.
--   4. Data-standards tags (DM-6.1, "tag existing columns when the owner next touches the table"): the
--      personal-data columns of shared.admin_users carry 'pii:<class>; …' comments (email pii:contact,
--      display_name pii:name, username / cognito_iss / cognito_sub pii:online_id) and password_hash carries
--      'conf:credential; …'. The new table holds no personal data beyond the FK.
--   5. Register 247.
--
-- Guards (RAISE on failure, nothing changes):
--   0. before: shared.admin_users exists and the runner owns it or is a member of its owner
--      (ALTER TABLE needs the owner; after X1 245 DB Migrate runs cis/ files as cis_owner).
--   1. after, by shape: the six columns exist with their types, is_owner NOT NULL, password_hash
--      nullable, role NOT NULL; both CHECKs and both unique indexes on admin_users; staff_app_grant has
--      its PK, two CHECKs and the FK; staff_app_grant has no non-owner grant that admin_users lacks
--      and the same RLS / FORCE flags.
--
-- Locks. shared.admin_users has a handful of rows and is read on every staff verify (60 s cache,
-- api/main.py). ADD COLUMN (a constant default is metadata-only on PG 11+), ADD CONSTRAINT CHECK (scans
-- the few rows) and DROP NOT NULL take ACCESS EXCLUSIVE for milliseconds; the two unique indexes are
-- built inside the transaction (a few rows, no CONCURRENTLY). lock_timeout 5s below. Not destructive
-- (no `migrate:` directive). Re-running is a no-op (IF NOT EXISTS everywhere, constraints added only
-- when missing).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243, AA-CIS-Infra db/owners.yaml): it
-- runs as the DB Migrate login today, as cis_owner after 245, unchanged. No catalog.* view is touched
-- (XD9 freeze). 244/245/246 (X1) are reserved; this file may apply before them (the runner keys
-- "applied" on the version only). The X1 245 transfer and the 246 probe must cover
-- shared.staff_app_grant and the new columns like every other shared table.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow);
-- keep the two byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB
-- Schema Dump workflow); expect the six columns, the two CHECKs and the two indexes on
-- shared.admin_users and the new table shared.staff_app_grant.
--
-- Rollback (forward file; only while no row has email / cognito_* / a NULL password_hash / a grant):
--   DROP TABLE IF EXISTS shared.staff_app_grant;
--   ALTER TABLE shared.admin_users ALTER COLUMN password_hash SET NOT NULL;
--   ALTER TABLE shared.admin_users DROP CONSTRAINT IF EXISTS admin_users_email_chk,
--       DROP CONSTRAINT IF EXISTS admin_users_cognito_pair_chk;
--   DROP INDEX IF EXISTS shared.admin_users_email_lower_key, shared.admin_users_cognito_identity_key;
--   ALTER TABLE shared.admin_users DROP COLUMN IF EXISTS email, DROP COLUMN IF EXISTS display_name,
--       DROP COLUMN IF EXISTS cognito_iss, DROP COLUMN IF EXISTS cognito_sub,
--       DROP COLUMN IF EXISTS last_login_at, DROP COLUMN IF EXISTS is_owner;
--   DELETE FROM shared.schema_versions WHERE version = '247';

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

-- ── Guard 0: the directory exists and the runner may alter it ───────────────────────────────────
DO $$
DECLARE
    owner_name text;
BEGIN
    IF to_regclass('shared.admin_users') IS NULL THEN
        RAISE EXCEPTION 'migration 247: shared.admin_users does not exist (migration 074)';
    END IF;
    SELECT pg_catalog.pg_get_userbyid(relowner) INTO owner_name
      FROM pg_catalog.pg_class WHERE oid = 'shared.admin_users'::regclass;
    IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
        RAISE EXCEPTION 'migration 247: shared.admin_users is owned by %, not by the runner % (ALTER TABLE needs the owner)',
            owner_name, current_user;
    END IF;
END $$;

-- ── 1. Identity columns on the staff directory ───────────────────────────────────────────────────
ALTER TABLE shared.admin_users
    ADD COLUMN IF NOT EXISTS email         text,
    ADD COLUMN IF NOT EXISTS display_name  text,
    ADD COLUMN IF NOT EXISTS cognito_iss   text,
    ADD COLUMN IF NOT EXISTS cognito_sub   text,
    ADD COLUMN IF NOT EXISTS last_login_at timestamptz,
    ADD COLUMN IF NOT EXISTS is_owner      boolean NOT NULL DEFAULT false;

ALTER TABLE shared.admin_users ALTER COLUMN password_hash DROP NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'shared.admin_users'::regclass AND conname = 'admin_users_email_chk') THEN
        ALTER TABLE shared.admin_users ADD CONSTRAINT admin_users_email_chk CHECK (
            email IS NULL
            OR (email = lower(email) AND email ~ '^[^@[:space:]]+@adventure[.]asia$'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'shared.admin_users'::regclass AND conname = 'admin_users_cognito_pair_chk') THEN
        ALTER TABLE shared.admin_users ADD CONSTRAINT admin_users_cognito_pair_chk CHECK (
            (cognito_iss IS NULL AND cognito_sub IS NULL)
            OR (cognito_iss IS NOT NULL AND cognito_sub IS NOT NULL
                AND cognito_iss LIKE 'https://%' AND length(cognito_sub) BETWEEN 1 AND 128));
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS admin_users_email_lower_key
    ON shared.admin_users (lower(email));
CREATE UNIQUE INDEX IF NOT EXISTS admin_users_cognito_identity_key
    ON shared.admin_users (cognito_iss, cognito_sub);

COMMENT ON COLUMN shared.admin_users.email IS
    'pii:contact; AA-816 (247): the staff member''s @adventure.asia address, lower-cased; the WORKFORCE username and the first-sign-in link key. Unique.';
COMMENT ON COLUMN shared.admin_users.display_name IS
    'pii:name; AA-816 (247): name shown in the admin UI and audit views.';
COMMENT ON COLUMN shared.admin_users.cognito_iss IS
    'pii:online_id; AA-816 (247): issuer of the bound Cognito identity (ADR 0006 §9: the identity key is (iss, sub)). Set together with cognito_sub.';
COMMENT ON COLUMN shared.admin_users.cognito_sub IS
    'pii:online_id; AA-816 (247): Cognito sub of the bound identity, filled by that person''s first successful sign-in. Unique with cognito_iss.';
COMMENT ON COLUMN shared.admin_users.last_login_at IS
    'AA-816 (247): last successful staff sign-in (Cognito path).';
COMMENT ON COLUMN shared.admin_users.is_owner IS
    'AA-816 (247): may write the staff directory (staff.write). Set by the link script, never by a migration.';
COMMENT ON COLUMN shared.admin_users.password_hash IS
    'conf:credential; AA-232 bcrypt hash for the legacy password login; NULL for a Cognito-only staff member (247), which the legacy login refuses with 401. Dropped after the Phase 1 cutover (ADR 0006).';
COMMENT ON COLUMN shared.admin_users.username IS
    'pii:online_id; AA-232 login name of the legacy password login (unique); kept as the CIS display handle after the Phase 1 cutover. Tagged in 247 (data standards DM-6.1).';

-- ── 2. Per-app staff grants (Booking roles) ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.staff_app_grant (
    admin_user_id uuid        NOT NULL REFERENCES shared.admin_users(id) ON DELETE CASCADE,
    app           text        NOT NULL,
    role          text        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT staff_app_grant_pkey PRIMARY KEY (admin_user_id, app),
    CONSTRAINT staff_app_grant_app_chk CHECK (app IN ('booking')),
    CONSTRAINT staff_app_grant_role_chk CHECK (role IN ('admin', 'sales', 'contracting', 'content_creator'))
);

COMMENT ON TABLE shared.staff_app_grant IS
    'AA-816 (247): a staff member''s role in another app (one row per person and app). app=booking: the Booking staff roles of bk-003 / the booking-* WORKFORCE groups. Written by the CIS staff directory together with the Cognito group.';

-- ── Guard 1: the shape is what this file promises ────────────────────────────────────────────────
DO $$
DECLARE
    missing    text;
    extra_acl  text;
    au_rls     boolean[];
    sag_rls    boolean[];
BEGIN
    SELECT string_agg(want.col || ' ' || want.typ, ', ') INTO missing
      FROM (VALUES ('email', 'text'), ('display_name', 'text'), ('cognito_iss', 'text'),
                   ('cognito_sub', 'text'), ('last_login_at', 'timestamp with time zone'),
                   ('is_owner', 'boolean')) AS want(col, typ)
     WHERE NOT EXISTS (
         SELECT 1 FROM pg_catalog.pg_attribute a
          WHERE a.attrelid = 'shared.admin_users'::regclass AND a.attname = want.col
            AND NOT a.attisdropped AND pg_catalog.format_type(a.atttypid, a.atttypmod) = want.typ);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 247: shared.admin_users lacks column(s) %', missing;
    END IF;
    IF NOT (SELECT attnotnull FROM pg_catalog.pg_attribute
             WHERE attrelid = 'shared.admin_users'::regclass AND attname = 'is_owner') THEN
        RAISE EXCEPTION 'migration 247: shared.admin_users.is_owner is nullable';
    END IF;
    IF (SELECT attnotnull FROM pg_catalog.pg_attribute
         WHERE attrelid = 'shared.admin_users'::regclass AND attname = 'password_hash') THEN
        RAISE EXCEPTION 'migration 247: shared.admin_users.password_hash is still NOT NULL';
    END IF;
    IF NOT (SELECT attnotnull FROM pg_catalog.pg_attribute
             WHERE attrelid = 'shared.admin_users'::regclass AND attname = 'role') THEN
        RAISE EXCEPTION 'migration 247: shared.admin_users.role must stay NOT NULL';
    END IF;
    IF (SELECT count(*) FROM pg_catalog.pg_constraint
         WHERE conrelid = 'shared.admin_users'::regclass AND contype = 'c'
           AND conname IN ('admin_users_email_chk', 'admin_users_cognito_pair_chk')) <> 2 THEN
        RAISE EXCEPTION 'migration 247: a CHECK on shared.admin_users is missing';
    END IF;
    IF (SELECT count(*) FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid = i.indexrelid
         WHERE i.indrelid = 'shared.admin_users'::regclass AND i.indisunique AND i.indisvalid
           AND c.relname IN ('admin_users_email_lower_key', 'admin_users_cognito_identity_key')) <> 2 THEN
        RAISE EXCEPTION 'migration 247: a unique index on shared.admin_users is missing';
    END IF;
    IF (SELECT count(*) FROM pg_catalog.pg_constraint
         WHERE conrelid = 'shared.staff_app_grant'::regclass
           AND ((contype = 'p' AND conname = 'staff_app_grant_pkey')
             OR (contype = 'c' AND conname IN ('staff_app_grant_app_chk', 'staff_app_grant_role_chk'))
             OR (contype = 'f' AND confrelid = 'shared.admin_users'::regclass))) <> 4 THEN
        RAISE EXCEPTION 'migration 247: shared.staff_app_grant lacks its PK, a CHECK or the FK to shared.admin_users';
    END IF;

    -- Never more reachable than the directory: every non-owner grant on the grant table is also held on
    -- shared.admin_users (grantee, privilege, grant option), and the RLS flags match.
    SELECT string_agg(format('%s:%s:%s', pg_catalog.pg_get_userbyid(g.grantee), g.privilege_type, g.is_grantable),
                      ',' ORDER BY pg_catalog.pg_get_userbyid(g.grantee), g.privilege_type)
      INTO extra_acl
      FROM (SELECT x.grantee, x.privilege_type, x.is_grantable
              FROM pg_catalog.pg_class c, LATERAL aclexplode(c.relacl) x
             WHERE c.oid = 'shared.staff_app_grant'::regclass AND x.grantee <> c.relowner
            EXCEPT
            SELECT x.grantee, x.privilege_type, x.is_grantable
              FROM pg_catalog.pg_class c, LATERAL aclexplode(c.relacl) x
             WHERE c.oid = 'shared.admin_users'::regclass AND x.grantee <> c.relowner) g;
    IF extra_acl IS NOT NULL THEN
        RAISE EXCEPTION 'migration 247: shared.staff_app_grant has grants shared.admin_users lacks: %', extra_acl;
    END IF;
    SELECT ARRAY[relrowsecurity, relforcerowsecurity] INTO au_rls
      FROM pg_catalog.pg_class WHERE oid = 'shared.admin_users'::regclass;
    SELECT ARRAY[relrowsecurity, relforcerowsecurity] INTO sag_rls
      FROM pg_catalog.pg_class WHERE oid = 'shared.staff_app_grant'::regclass;
    IF au_rls IS DISTINCT FROM sag_rls THEN
        RAISE EXCEPTION 'migration 247: shared.staff_app_grant RLS/FORCE % differs from shared.admin_users %', sag_rls, au_rls;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('247', now(), 'AA-816: shared.admin_users Cognito identity columns (email, display_name, cognito_iss/sub, last_login_at, is_owner), nullable password_hash, shared.staff_app_grant')
ON CONFLICT (version) DO NOTHING;

COMMIT;
