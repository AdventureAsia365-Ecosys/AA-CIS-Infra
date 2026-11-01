-- Migration crm-039: AA-939 follow-up (S263, partner-pool account clean-up) — the partner-account clean-up job may
-- READ crm.studio_invitation, so it never deletes a partner-pool account that a Content studio invitation still uses.
--
-- Owner: AA-Partner (api/migrations/039_crm_partner_account_cleanup.sql). AA-CIS-Infra db/migrations/crm/ holds the
-- byte copy DB Migrate applies (Migration Sync bot, Migration Copy Guard). Key crm-039, after crm-038 (AA-959); if main
-- moves, renumber: file name, this header, Guard 0, the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS.
--
-- Why. Deleting a synthetic test agency (POST /crm/ops/v1/tenants/{id}/delete) or withdrawing / letting expire an
-- invitation leaves the partner-pool account the claim created; an address that never signed in stays a
-- FORCE_CHANGE_PASSWORD user for ever. The CRM API now deletes such an account (cognito-idp:AdminDeleteUser, root ADR
-- 0006b amendment) only when no CRM member, no live CRM invitation and no Content studio invitation still needs it
-- (AA-Partner app/members/accounts.py, job crm_partner_accounts, actor job:crm_partner_accounts). The CRM invitations
-- and members are read agency by agency (tenant_isolation, app.tenant_id); crm.studio_invitation is a platform table
-- (crm-020: no tenant_id) whose row security lets only platform:* and job:crm_studio_activation reach rows, so the job
-- would see no studio row at all and could delete an account a pending studio claim is about to use.
--
-- What: policy studio_invitation_platform (crm-020) is re-created with one more actor in its USING clause only:
-- job:crm_partner_accounts may SELECT every row. Its WITH CHECK is unchanged, so that actor can insert or update
-- nothing (row security refuses the new row, and the crm-020 guard trigger CRM37 refuses any write by an actor it does
-- not name); crm_app has no DELETE on the table. The policy keeps its name, so crm-020's Guard 1 (exactly three
-- policies) still holds when the files are replayed. No table, column, grant, function or data change; no DM-7.1 row
-- (no new table).
--
-- Class: contract (root ADR 0017 d3: a changed policy on an existing table). No migrate directive: MIG-4 order, this
-- migration-only PR first, the Infra copy (Migration Sync bot), the apply (ADR 0017a: Migration Apply on Dev once every
-- job table is idle), then the code PR that adds crm-039 to REQUIRED_SCHEMA_VERSIONS. The clean-up code also checks
-- that crm-039 is registered before it reads studio rows and refuses to run otherwise (fail closed). Code before it never
-- uses the new actor, so nothing changes for it.
--
-- Order: after crm-038 (AA-959); Guard 0 checks crm-020 (the table) and crm-038 (number order). Runs as crm_owner
-- (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (DROP POLICY IF EXISTS + CREATE, ON CONFLICT
-- DO NOTHING). Rollback: a forward crm- file (MIG-14) re-creating the crm-020 text of the policy, after the clean-up code
-- is reverted.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-038 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-039: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-038') THEN
        RAISE EXCEPTION 'crm-039: crm-038 (AA-959 workflows) lands first';
    END IF;
    IF to_regclass('crm.studio_invitation') IS NULL
       OR to_regprocedure('crm.guard_studio_invitation_write()') IS NULL THEN
        RAISE EXCEPTION 'crm-039: crm.studio_invitation and its guard (crm-020) missing';
    END IF;
END $$;

-- ── 1. The platform policy, plus the clean-up job's read ─────────────────────────────────────────
DROP POLICY IF EXISTS studio_invitation_platform ON crm.studio_invitation;
CREATE POLICY studio_invitation_platform ON crm.studio_invitation
    TO crm_owner, crm_app
    USING (COALESCE(current_setting('app.actor', true), '') LIKE 'platform:%'
           OR COALESCE(current_setting('app.actor', true), '') = 'job:crm_studio_activation'
           OR COALESCE(current_setting('app.actor', true), '') = 'job:crm_partner_accounts')
    WITH CHECK (COALESCE(current_setting('app.actor', true), '') LIKE 'platform:%'
                OR COALESCE(current_setting('app.actor', true), '') = 'job:crm_studio_activation');
COMMENT ON POLICY studio_invitation_platform ON crm.studio_invitation IS 'AA-979 (crm-020) + AA-939 (crm-039): platform:* (the L1 relay) and job:crm_studio_activation reach every row; job:crm_partner_accounts (the partner-account clean-up) may only read them (USING only: WITH CHECK refuses its writes, and guard CRM37 refuses any actor it does not name).';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    v_qual text;
    v_check text;
BEGIN
    IF (SELECT count(*) FROM pg_catalog.pg_policy WHERE polrelid = 'crm.studio_invitation'::regclass) <> 3 THEN
        RAISE EXCEPTION 'crm-039: crm.studio_invitation must keep exactly three policies';
    END IF;
    SELECT pg_catalog.pg_get_expr(polqual, polrelid), pg_catalog.pg_get_expr(polwithcheck, polrelid)
      INTO v_qual, v_check
      FROM pg_catalog.pg_policy
     WHERE polrelid = 'crm.studio_invitation'::regclass AND polname = 'studio_invitation_platform';
    IF v_qual IS NULL OR position('job:crm_partner_accounts' IN v_qual) = 0 THEN
        RAISE EXCEPTION 'crm-039: studio_invitation_platform does not let the clean-up job read';
    END IF;
    IF v_check IS NULL OR position('job:crm_partner_accounts' IN v_check) > 0 THEN
        RAISE EXCEPTION 'crm-039: the clean-up job must not pass the WITH CHECK of studio_invitation_platform';
    END IF;
    IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class
             WHERE oid = 'crm.studio_invitation'::regclass) THEN
        RAISE EXCEPTION 'crm-039: crm.studio_invitation must keep ENABLE + FORCE row level security';
    END IF;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.studio_invitation', 'DELETE') THEN
        RAISE EXCEPTION 'crm-039: crm_app may never DELETE crm.studio_invitation';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-039', now(), 'AA-939 follow-up: the partner-account clean-up job (job:crm_partner_accounts) may read crm.studio_invitation (policy studio_invitation_platform, USING only)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
