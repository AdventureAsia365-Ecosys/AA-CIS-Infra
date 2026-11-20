-- Migration 462: AA-1155 (S286, custom staff roles, foundation) — CIS custom roles as data, the business-owner marker
-- and the key-only contract view Booking reads each staff member's Booking role from.
--
-- Why. Booking resolves one built-in role per person from the first booking-* Cognito group, and CIS roles are a code
-- dict. The content + operations staff member needs a combined role no built-in expresses (Booking "Product, ops &
-- accounting": make and read rights, no approve right; CIS "Content": content_lead without content.settings.write,
-- plus tenant.read). Tech lead S285: Q1 (no interim Booking contracting grant), Q2 = option A (this contract view,
-- root ADR 0006a A14), Q3 (agency quote and booking rights in the Booking role), Q7 (the CIS "Content" role). A
-- WORKFORCE group (cis-custom / booking-custom, AA-CIS-Infra identity.tf) only says "a custom role"; WHICH one is the
-- data below. Built-in roles stay in code (api/core/staff_authz.py ROLE_PERMS, AA-Booking app/auth/staff.py
-- PERMISSIONS); these tables hold custom roles only. Spec: root .kiro/specs/AA-1155-custom-staff-roles/ (task T3).
--
-- What.
--   1. shared.staff_role: one row per CIS custom role. code ^custom_[a-z][a-z0-9_]{1,46}$ (the same pattern as a
--      Booking custom role code, so the two never collide with a built-in), label, based_on (the built-in CIS role a
--      holder's admin_users.role keeps: never admin, viewer or the retired reviewer alias, so a custom holder can never
--      pass an "is admin" test), archived, created / updated stamps and actors.
--   2. shared.staff_role_capability: (role_code, capability), the capabilities of a custom role. A CHECK refuses the
--      approve class (any *.approve or *.approve_<x>) and staff.write / staff.admin: custom roles never approve and never
--      edit the staff directory (AA-1155 "approve-class capabilities are reserved for built-in roles"); the CIS code
--      also checks every capability against its CAPABILITIES set (unknown = refused).
--   3. shared.admin_users gains:
--        custom_role text NULL, FK to shared.staff_role (RESTRICT: a role in use cannot be deleted, only archived);
--          CHECK admin_users_custom_role_chk: a custom holder's built-in role is never admin / viewer / reviewer;
--        is_business_owner boolean NOT NULL DEFAULT false, the business-owner marker (approvals of AA-1158 and view-as
--          read it server-side); unique index admin_users_one_business_owner_key: at most one row holds it. Set only
--          on the Staff page by an is_owner user, audited (CIS code).
--   4. staff_app_grant_role_chk widened: the five built-in Booking roles OR a Booking custom role code (same pattern;
--      Booking checks the code against booking.staff_role, bk-062, and fails closed on an unknown or archived one).
--   5. admin_users_email_chk replaced: the 378 rule, every E2E branch now also NOT is_business_owner, plus two Dev-only
--      E2E addresses (root ADR 0006a, TEMPORARY like A10..A10e):
--        A10f e2e-cis-content-lead@e2e-mail.lumiguides.it.com: content_lead, no custom role, not an owner, no password;
--        A10g e2e-custom-maker@e2e-mail.lumiguides.it.com: content_lead (the based_on of the seeded CIS custom role),
--          custom role allowed, not an owner, no password.
--   6. shared.v_staff_booking_grant (security_barrier, owner view): the key-only contract (staff.booking_grant.v1)
--      (cognito_sub, booking_role_code, is_owner, is_business_owner) of every ACTIVE staff member with a Cognito
--      identity who holds a Booking grant or one of the two markers. No e-mail, no name, no CIS role. GRANT USAGE on
--      schema shared and SELECT on the view to booking only (new: booking had no USAGE on shared; no shared function
--      is SECURITY DEFINER, and the base tables stay closed: AA-CIS-Infra isolation probe CROSS_APP). Booking reads it
--      only for booking-custom holders and the owner markers, with a 60 s cache, failing closed.
--   7. Seed (exact allow-list, unit-tested in the code PR): the CIS custom role custom_content "Content", based_on
--      content_lead = content_lead's capabilities (staff_authz.py ROLE_PERMS, 20/11/2026) minus content.settings.write,
--      plus tenant.read (Q7). docs.read is included (every role holds it, AA-1133 B7).
--   8. Grants: SELECT on the two tables to cis_app (the CIS code reads them; writes come with a CIS editor, not yet).
--   9. Register 462.
--
-- Guards (RAISE, nothing changes): 0. before: the directory tables exist, the runner may alter them, role booking
-- exists. 1. after: the CHECKs name what this file promises; the view has exactly the four columns; booking may read
-- the view and not admin_users / staff_app_grant; the seed holds no approve-class capability.
--
-- Class: CONTRACT (root ADR 0017 d3: columns, an index and replaced CHECKs on existing tables, a seed, a cross-app
-- grant). No migrate directive line. MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply once every job
-- table is idle (ADR 0017a), then the code PRs (CIS readiness, Booking resolver). DM-6.1: v_staff_booking_grant.
-- cognito_sub is pii:online_id (the key); no other personal column is added. DM-7.1: two new tables, rows in root data
-- standards Part B section 7 (root PR of this change, merged before the Infra copy).
--
-- Number. 461 is the newest CIS migration on main (20/11/2026). If the owner main max + 1 differs at merge, renumber
-- (git grep '462_' and "'462'": this file, tests/integration/test_aa1155_migration_462.py, AA-CIS-Infra db/owners.yaml
-- and db/isolation_probe.py expected_from, root ADR 0006a A14 and the spec).
--
-- Behaviour on apply: none for running code. Both new columns are NULL / false on every row; nothing on main reads
-- the tables or the view; the wider CHECKs accept every existing row (the new email branches name addresses no row
-- uses; the E2E rows are not business owners).
--
-- Locks. ADD COLUMN (no rewrite: a constant default), CREATE UNIQUE INDEX and the replaced CHECKs take ACCESS
-- EXCLUSIVE on shared.admin_users / staff_app_grant for milliseconds (about 12 rows; read on every staff verify,
-- 60 s cache). lock_timeout 5s. Re-runnable (IF NOT EXISTS, drop + add the same CHECKs, CREATE OR REPLACE VIEW,
-- ON CONFLICT DO NOTHING).
--
-- X1. One BEGIN … COMMIT block, no role switch (the runner is cis_owner, the owner of schema shared). No catalog.* view
-- is touched: catalog is the content read model; this directory contract stays in shared, granted to booking alone.
--
-- Rollback (a new forward migration, after the code PRs are reverted): DROP VIEW shared.v_staff_booking_grant, REVOKE
-- USAGE ON SCHEMA shared FROM booking, put back the 363 staff_app_grant_role_chk and the 378 admin_users_email_chk
-- (they RAISE while a row uses a custom code or an A10f / A10g address), drop the two columns and the two tables (a
-- destructive file, DRY RUN).
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: the directory exists, the runner may alter it, the consumer role exists ─────────────────────────────
DO $$
DECLARE
    rel text;
    owner_name text;
BEGIN
    FOREACH rel IN ARRAY ARRAY['shared.admin_users', 'shared.staff_app_grant'] LOOP
        IF to_regclass(rel) IS NULL THEN
            RAISE EXCEPTION 'migration 462: % does not exist (migration 247)', rel;
        END IF;
        SELECT pg_catalog.pg_get_userbyid(relowner) INTO owner_name
          FROM pg_catalog.pg_class WHERE oid = rel::regclass;
        IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
            RAISE EXCEPTION 'migration 462: % is owned by %, not by the runner % (ALTER TABLE needs the owner)',
                rel, owner_name, current_user;
        END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'booking') THEN
        RAISE EXCEPTION 'migration 462: role booking does not exist (bk-001)';
    END IF;
END $$;

-- ── 1. CIS custom roles ──────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.staff_role (
    code        text                NOT NULL,
    label       text                NOT NULL,
    based_on    shared.admin_role   NOT NULL,
    archived    boolean             NOT NULL DEFAULT false,
    created_at  timestamptz         NOT NULL DEFAULT now(),
    created_by  text                NOT NULL,
    updated_at  timestamptz         NOT NULL DEFAULT now(),
    updated_by  text                NOT NULL,
    CONSTRAINT staff_role_pkey PRIMARY KEY (code),
    CONSTRAINT staff_role_code_chk CHECK (code ~ '^custom_[a-z][a-z0-9_]{1,46}$'),
    CONSTRAINT staff_role_label_chk CHECK (char_length(btrim(label)) BETWEEN 1 AND 80 AND label !~ '[[:cntrl:]]'),
    CONSTRAINT staff_role_based_on_chk CHECK (based_on NOT IN ('admin', 'viewer', 'reviewer')),
    CONSTRAINT staff_role_actor_chk CHECK (char_length(created_by) BETWEEN 1 AND 128
                                           AND char_length(updated_by) BETWEEN 1 AND 128),
    CONSTRAINT staff_role_time_chk CHECK (updated_at >= created_at)
);

-- ── 2. Their capabilities (never the approve class, never the staff directory) ───────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.staff_role_capability (
    role_code   text         NOT NULL,
    capability  text         NOT NULL,
    created_at  timestamptz  NOT NULL DEFAULT now(),
    created_by  text         NOT NULL,
    CONSTRAINT staff_role_capability_pkey PRIMARY KEY (role_code, capability),
    CONSTRAINT staff_role_capability_role_fkey FOREIGN KEY (role_code)
        REFERENCES shared.staff_role (code) ON DELETE CASCADE,
    CONSTRAINT staff_role_capability_name_chk CHECK (capability ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,3}$'),
    CONSTRAINT staff_role_capability_not_approve_chk CHECK (
        capability !~ '\.approve(_[a-z0-9_]+)?$' AND capability NOT IN ('staff.write', 'staff.admin')),
    CONSTRAINT staff_role_capability_actor_chk CHECK (char_length(created_by) BETWEEN 1 AND 128)
);

COMMENT ON TABLE shared.staff_role IS
    'AA-1155 (CIS 462): CIS custom staff roles only (built-in roles stay in api/core/staff_authz.py ROLE_PERMS). A '
    'holder has WORKFORCE group cis-custom and shared.admin_users.custom_role = code; admin_users.role keeps based_on. '
    'Archived roles stay for history; a role in use cannot be deleted.';
COMMENT ON COLUMN shared.staff_role.based_on IS
    'AA-1155 (462): the built-in CIS role the holder''s admin_users.role keeps (informational; authorisation never falls '
    'back to it). Never admin, viewer or reviewer.';
COMMENT ON TABLE shared.staff_role_capability IS
    'AA-1155 (CIS 462): the capabilities of a CIS custom role. Never an approve-class capability or the staff directory '
    '(CHECK); the CIS code also refuses a capability its CAPABILITIES set does not know.';

-- ── 3. The custom role and the business-owner marker of a staff member ───────────────────────────────────────────
ALTER TABLE shared.admin_users
    ADD COLUMN IF NOT EXISTS custom_role text,
    ADD COLUMN IF NOT EXISTS is_business_owner boolean NOT NULL DEFAULT false;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'shared.admin_users'::regclass AND conname = 'admin_users_custom_role_fkey') THEN
        ALTER TABLE shared.admin_users ADD CONSTRAINT admin_users_custom_role_fkey FOREIGN KEY (custom_role)
            REFERENCES shared.staff_role (code) ON DELETE RESTRICT;
    END IF;
END $$;

ALTER TABLE shared.admin_users
    DROP CONSTRAINT IF EXISTS admin_users_custom_role_chk,
    ADD CONSTRAINT admin_users_custom_role_chk CHECK (
        custom_role IS NULL OR role NOT IN ('admin', 'viewer', 'reviewer'));

CREATE UNIQUE INDEX IF NOT EXISTS admin_users_one_business_owner_key
    ON shared.admin_users (is_business_owner) WHERE is_business_owner;

COMMENT ON COLUMN shared.admin_users.custom_role IS
    'AA-1155 (462): the CIS custom role (shared.staff_role.code) of a cis-custom holder; NULL = the built-in role in '
    'role. A holder is refused (fail closed) when the role or its capabilities cannot be read.';
COMMENT ON COLUMN shared.admin_users.is_business_owner IS
    'AA-1155 (462): the business-owner marker, held by at most one row (admin_users_one_business_owner_key). Set only '
    'on the Staff page by an is_owner user, audited. Read server-side (Booking: shared.v_staff_booking_grant).';

-- ── 4. A Booking grant may name a Booking custom role ────────────────────────────────────────────────────────────
ALTER TABLE shared.staff_app_grant
    DROP CONSTRAINT IF EXISTS staff_app_grant_role_chk,
    ADD CONSTRAINT staff_app_grant_role_chk CHECK (
        role IN ('admin', 'sales', 'contracting', 'content_creator', 'finance')
        OR role ~ '^custom_[a-z][a-z0-9_]{1,46}$');

COMMENT ON COLUMN shared.staff_app_grant.role IS
    'AA-816 (247), AA-1035 (363), AA-1155 (462): the Booking role of the staff member: a built-in role = WORKFORCE group '
    'booking-<role> (admin, sales, contracting, content_creator, finance), or a Booking custom role code '
    '(booking.staff_role, bk-062) = group booking-custom, read by Booking through shared.v_staff_booking_grant.';

-- ── 5. The 378 rule, no E2E business owner, plus A10f and A10g ───────────────────────────────────────────────────
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
            AND NOT is_business_owner AND password_hash IS NULL));

COMMENT ON CONSTRAINT admin_users_email_chk ON shared.admin_users IS
    'AA-816 (247, 250, 283), AA-1035 (363, 375, 378), AA-1155 (462): lower-cased @adventure.asia only. TEMPORARY (250, root ADR 0006a A10): also the E2E test mailbox e2e@e2e-mail.lumiguides.it.com, as content. TEMPORARY (283, A10b, Dev only by code): also e2e-cis-admin@e2e-mail.lumiguides.it.com, as an admin. TEMPORARY (378, A10d, Dev only by code): also e2e-cis-cs@e2e-mail.lumiguides.it.com, as customer_success. TEMPORARY (462, A10f / A10g, Dev only by code): also e2e-cis-content-lead@e2e-mail.lumiguides.it.com as content_lead without a custom role, and e2e-custom-maker@e2e-mail.lumiguides.it.com as content_lead with a custom role. None an owner or the business owner, none with a password. All removed at the end of project code.';

-- ── 6. The contract view Booking reads (key-only, booking only) ──────────────────────────────────────────────────
CREATE OR REPLACE VIEW shared.v_staff_booking_grant WITH (security_barrier = true) AS
SELECT u.cognito_sub,
       g.role AS booking_role_code,
       u.is_owner,
       u.is_business_owner
  FROM shared.admin_users u
  LEFT JOIN shared.staff_app_grant g ON g.admin_user_id = u.id AND g.app = 'booking'
 WHERE u.is_active
   AND u.cognito_sub IS NOT NULL
   AND (g.role IS NOT NULL OR u.is_owner OR u.is_business_owner);

COMMENT ON VIEW shared.v_staff_booking_grant IS
    'AA-1155 (CIS 462, root ADR 0006a A14, contract staff.booking_grant.v1): per active staff member with a Cognito '
    'identity, the Booking role code of the CIS Staff page grant (built-in or a booking.staff_role custom code) and the '
    'owner / business-owner markers. Key-only (no e-mail, name or CIS role). SELECT to booking only.';
COMMENT ON COLUMN shared.v_staff_booking_grant.cognito_sub IS
    'pii:online_id; AA-1155 (462): the WORKFORCE sub, the key Booking matches its token against.';

REVOKE ALL ON shared.v_staff_booking_grant FROM PUBLIC;
GRANT USAGE ON SCHEMA shared TO booking;
GRANT SELECT ON shared.v_staff_booking_grant TO booking;

-- ── 7. Seed: the CIS "Content" custom role (Q7) ──────────────────────────────────────────────────────────────────
INSERT INTO shared.staff_role (code, label, based_on, created_by, updated_by)
VALUES ('custom_content', 'Content', 'content_lead', 'migration:462', 'migration:462')
ON CONFLICT (code) DO NOTHING;

INSERT INTO shared.staff_role_capability (role_code, capability, created_by)
SELECT 'custom_content', c, 'migration:462'
  FROM unnest(ARRAY[
      'content.read', 'content.write', 'review.act', 'content.publish', 'master.admin', 'atoms.write',
      'photos.write', 'a4.unpublish', 'quality.write', 'catalog.read', 'tenant_content.read', 'lab.read',
      'wave.run', 'notifications.read', 'reference_price.read', 'learn.preview', 'docs.read', 'tenant.read'
  ]) AS c
ON CONFLICT (role_code, capability) DO NOTHING;

-- ── 8. Runtime grants ────────────────────────────────────────────────────────────────────────────────────────────
GRANT SELECT ON shared.staff_role, shared.staff_role_capability TO cis_app;

-- ── Guard 1: what this file promises ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    def text;
    cols text;
    bad integer;
BEGIN
    SELECT pg_catalog.pg_get_constraintdef(oid) INTO def
      FROM pg_catalog.pg_constraint
     WHERE conrelid = 'shared.admin_users'::regclass AND conname = 'admin_users_email_chk'
       AND contype = 'c' AND convalidated;
    IF def IS NULL
       OR position('''e2e@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-cis-admin@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-cis-cs@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-cis-content-lead@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('''e2e-custom-maker@e2e-mail.lumiguides.it.com''' IN def) = 0
       OR position('is_business_owner' IN def) = 0 OR position('reviewer' IN def) > 0
       OR position('adventure[.]asia' IN def) = 0 THEN
        RAISE EXCEPTION 'migration 462: admin_users_email_chk is not the expected rule: %', def;
    END IF;

    SELECT pg_catalog.pg_get_constraintdef(oid) INTO def
      FROM pg_catalog.pg_constraint
     WHERE conrelid = 'shared.staff_app_grant'::regclass AND conname = 'staff_app_grant_role_chk'
       AND contype = 'c' AND convalidated;
    IF def IS NULL OR position('''finance''' IN def) = 0 OR position('^custom_' IN def) = 0 THEN
        RAISE EXCEPTION 'migration 462: staff_app_grant_role_chk is not the expected rule: %', def;
    END IF;

    SELECT string_agg(attname, ',' ORDER BY attnum) INTO cols
      FROM pg_catalog.pg_attribute
     WHERE attrelid = 'shared.v_staff_booking_grant'::regclass AND attnum > 0 AND NOT attisdropped;
    IF cols IS DISTINCT FROM 'cognito_sub,booking_role_code,is_owner,is_business_owner' THEN
        RAISE EXCEPTION 'migration 462: shared.v_staff_booking_grant columns are %', cols;
    END IF;

    IF NOT has_table_privilege('booking', 'shared.v_staff_booking_grant', 'SELECT')
       OR NOT has_schema_privilege('booking', 'shared', 'USAGE') THEN
        RAISE EXCEPTION 'migration 462: booking cannot read shared.v_staff_booking_grant';
    END IF;
    IF has_table_privilege('booking', 'shared.admin_users', 'SELECT')
       OR has_table_privilege('booking', 'shared.staff_app_grant', 'SELECT')
       OR has_table_privilege('booking', 'shared.staff_role', 'SELECT') THEN
        RAISE EXCEPTION 'migration 462: booking can read a staff directory table (only the view is granted)';
    END IF;

    SELECT count(*) INTO bad FROM shared.staff_role_capability
     WHERE role_code = 'custom_content'
       AND capability IN ('content.settings.write', 'settings.write', 'settings.approve', 'staff.write',
                          'staff.read', 'ai.admin', 'spend.write');
    IF bad > 0 THEN
        RAISE EXCEPTION 'migration 462: the Content custom role holds % forbidden capability(ies)', bad;
    END IF;
    IF (SELECT count(*) FROM shared.staff_role_capability WHERE role_code = 'custom_content') <> 18 THEN
        RAISE EXCEPTION 'migration 462: the Content custom role does not hold its 18 seeded capabilities';
    END IF;
END $$;

-- ── 9. Register ──────────────────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('462', now(), 'AA-1155: CIS custom staff roles (staff_role, staff_role_capability), admin_users.custom_role and is_business_owner, Booking custom grant codes, A10f/A10g E2E addresses, contract view shared.v_staff_booking_grant (booking)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
