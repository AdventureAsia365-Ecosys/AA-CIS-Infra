-- Migration crm-004: AA-935 (partner CRM, design v3 card CRM-07) — the agency directory the CRM web needs: an agency
-- label and default date locale on crm.tenant, and a caller-scoped membership lookup.
--
-- Owner: AA-Partner (api/migrations/004_crm_tenant_directory.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-004.
--
-- Why. After sign-in the web knows only the token's (iss, sub). tenant_tx() needs the agency id first, and the
-- crm-002 policies show a member row only once app.tenant_id is set, so nothing could tell a signed-in person which
-- agencies they belong to. The sidebar also needs the agency's name, and dates follow a locale (R32).
--
-- What:
--   1. crm.tenant.display_name: the agency's label in the CRM (business name, not personal data). Until the CIS
--      membership feed (AA-978, tenant.membership.v1) carries the CIS agency name, the CRM keeps its own. The column
--      default 'Unnamed agency' only fills rows created before this file (and inserts that name nothing, e.g. older
--      tests); provisioning code always passes a name (app/agencies.py).
--   2. crm.tenant.default_locale: the agency's default date locale (en-AU, en-GB, en-US, vi-VN; design v3 §2.3
--      "dates follow the locale"). A person's own choice (web cookie) wins over it.
--   3. Two SELECT-only policies TO crm_app, for app.tenancy.caller_memberships() (one transaction that sets
--      app.caller_iss / app.caller_sub from the verified token, never from input):
--        member_self_lookup    on crm.member: the caller's own, not trashed member rows, in any agency;
--        tenant_member_lookup  on crm.tenant: the agencies where the caller holds an active, not trashed row.
--      Policies of one command are OR-ed (permissive), so inside tenant_tx() (app.caller_* unset) both are false and
--      crm-002 tenant_isolation alone decides, as before. They give SELECT only: INSERT / UPDATE / DELETE still need
--      tenant_isolation (FOR ALL). The NOLOGIN readers get neither policy.
--   No personal data is added. The catalogue guard (tests/integration/test_crm002_tenancy.py) still finds exactly one
--   tenant_isolation policy per table; the two lookups are listed there by name.
--
-- Order: after crm-003 (the AA-934 vault); Guard 0 refuses to run before it is registered. This file was drafted as
-- crm-003 and renumbered to crm-004 before either landed (S249).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP
-- POLICY IF EXISTS). Rollback: a forward crm- file (MIG-14); before AA-935 deploys nothing reads these columns.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-003 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-004: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-003') THEN
        RAISE EXCEPTION 'crm-004: crm-003 is not registered (the vault, AA-934, lands first)';
    END IF;
    IF to_regclass('crm.tenant') IS NULL OR to_regclass('crm.member') IS NULL THEN
        RAISE EXCEPTION 'crm-004: crm.tenant / crm.member are missing (crm-002)';
    END IF;
END $$;

-- ── 1–2. Agency label and default locale ─────────────────────────────────────────────────────────
ALTER TABLE crm.tenant ADD COLUMN IF NOT EXISTS display_name TEXT NOT NULL DEFAULT 'Unnamed agency';
ALTER TABLE crm.tenant ADD COLUMN IF NOT EXISTS default_locale TEXT NOT NULL DEFAULT 'en-AU';

ALTER TABLE crm.tenant DROP CONSTRAINT IF EXISTS tenant_display_name_chk;
ALTER TABLE crm.tenant ADD CONSTRAINT tenant_display_name_chk CHECK (
    length(btrim(display_name)) BETWEEN 1 AND 120 AND display_name = btrim(display_name)
);
ALTER TABLE crm.tenant DROP CONSTRAINT IF EXISTS tenant_default_locale_chk;
ALTER TABLE crm.tenant ADD CONSTRAINT tenant_default_locale_chk CHECK (
    default_locale IN ('en-AU', 'en-GB', 'en-US', 'vi-VN')
);

COMMENT ON COLUMN crm.tenant.display_name IS 'AA-935 (crm-004): the agency label shown in the CRM (a business name, not personal data). Synced from the CIS agency name once tenant.membership.v1 exists (AA-978).';
COMMENT ON COLUMN crm.tenant.default_locale IS 'AA-935 (crm-004): default date locale of the agency (R32): en-AU, en-GB, en-US or vi-VN; a person''s own choice wins.';

-- ── 3. Caller-scoped membership lookup ───────────────────────────────────────────────────────────
DROP POLICY IF EXISTS member_self_lookup ON crm.member;
CREATE POLICY member_self_lookup ON crm.member
    FOR SELECT
    TO crm_app
    USING (
        deleted_at IS NULL
        AND cognito_iss = NULLIF(current_setting('app.caller_iss', true), '')
        AND cognito_sub = NULLIF(current_setting('app.caller_sub', true), '')
    );

DROP POLICY IF EXISTS tenant_member_lookup ON crm.tenant;
CREATE POLICY tenant_member_lookup ON crm.tenant
    FOR SELECT
    TO crm_app
    USING (
        deleted_at IS NULL
        AND EXISTS (
            SELECT 1 FROM crm.member m
             WHERE m.tenant_id = tenant.tenant_id
               AND m.status = 'active'
               AND m.deleted_at IS NULL
               AND m.cognito_iss = NULLIF(current_setting('app.caller_iss', true), '')
               AND m.cognito_sub = NULLIF(current_setting('app.caller_sub', true), '')
        )
    );

COMMENT ON POLICY member_self_lookup ON crm.member IS 'AA-935 (crm-004): the caller''s own member rows across agencies, only while app.caller_iss / app.caller_sub are set (app.tenancy.caller_memberships). SELECT only.';
COMMENT ON POLICY tenant_member_lookup ON crm.tenant IS 'AA-935 (crm-004): the agencies the caller is an active member of, only while app.caller_iss / app.caller_sub are set. SELECT only.';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    pol record;
BEGIN
    FOR pol IN
        SELECT c.relname, p.polname, p.polcmd,
               ARRAY(SELECT r::regrole::text FROM unnest(p.polroles) r WHERE r <> 0) AS roles,
               0 = ANY (p.polroles) AS to_public
          FROM pg_catalog.pg_policy p JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
         WHERE c.relnamespace = 'crm'::regnamespace AND p.polname IN ('member_self_lookup', 'tenant_member_lookup')
    LOOP
        IF pol.polcmd <> 'r' OR pol.to_public OR pol.roles <> ARRAY['crm_app'] THEN
            RAISE EXCEPTION 'crm-004: policy %.% must be FOR SELECT TO crm_app only', pol.relname, pol.polname;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM pg_catalog.pg_policy p JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
         WHERE c.relnamespace = 'crm'::regnamespace
           AND p.polname IN ('member_self_lookup', 'tenant_member_lookup')) <> 2 THEN
        RAISE EXCEPTION 'crm-004: the two lookup policies are missing';
    END IF;
    IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = 'crm.tenant'::regclass)
       OR NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = 'crm.member'::regclass)
    THEN
        RAISE EXCEPTION 'crm-004: crm.tenant / crm.member lost ENABLE + FORCE row level security';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-004', now(), 'AA-935: agency display name + default locale, caller-scoped membership lookup policies')
ON CONFLICT (version) DO NOTHING;

COMMIT;
