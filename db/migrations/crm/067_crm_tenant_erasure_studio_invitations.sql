-- Migration crm-067: AA-1093 stage 2 — the CRM erase of a CIS tenant also reaches its Content studio invitations.
--
-- Owner: AA-Partner (api/migrations/067_crm_tenant_erasure_studio_invitations.sql). AA-CIS-Infra db/migrations/crm/
-- holds the byte copy Migration Apply applies. Key crm-067 = crm-066 + 1 (same lane, one migration-only PR, batch crm
-- 066-067); if main moves, renumber both (git grep '067_' and 'crm-067').
--
-- Why. crm.studio_invitation (crm-020, AA-979) is keyed by cis_tenant_id, not tenant_id (the CIS tenant may have no
-- CRM agency), so crm.erase_subject('tenant') never reaches it, yet it holds personal data of the tenant's invitees
-- (cognito_sub pii:online_id, email_kept pii:contact, email_enc). The CRM step of the CIS erasure saga
-- (job:crm_tenant_erase, contract tenant.erasure.v1) counts the tenant's rows in its plan and census and deletes them in
-- its apply.
--
-- What: crm.erase_studio_invitations(p_cis_tenant uuid, p_dry_run boolean) RETURNS integer, SECURITY DEFINER (owner
-- crm_owner), EXECUTE for crm_eraser only (the job reaches it with SET LOCAL ROLE, as crm.erase_subject). It refuses
-- every actor but job:crm_tenant_erase (SQLSTATE CRM56); counts (dry run) or deletes the rows WHERE cis_tenant_id =
-- p_cis_tenant, as the platform actor platform:feed-tenant-erasure for the statement (the crm-020 row policy
-- studio_invitation_platform lets a platform: actor through; FORCE RLS holds for the owner too), then restores the
-- caller's actor. crm_app gets no DELETE on the table: no other code path can delete an invitation. A post-check.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a new SECURITY DEFINER function with REVOKE /
-- GRANT and a DO post-check is outside the expand set. On Dev: Infra Migration Apply once every job table is idle
-- (root ADR 0017a). MIG-4: the migration-only PR (with crm-066), then the code PR once both are applied on Dev.
--
-- Rollback (a forward crm- file, after the code is reverted): DROP FUNCTION crm.erase_studio_invitations(uuid, boolean).
--
-- Runs as crm_owner, one BEGIN … COMMIT block, no role DDL. Re-runnable (CREATE OR REPLACE of its own function).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

CREATE OR REPLACE FUNCTION crm.erase_studio_invitations(p_cis_tenant uuid, p_dry_run boolean) RETURNS integer
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_rows integer;
BEGIN
    IF v_actor <> 'job:crm_tenant_erase' THEN
        RAISE EXCEPTION 'crm: only job:crm_tenant_erase reaches the studio invitations of a CIS tenant'
            USING ERRCODE = 'CRM56';
    END IF;
    IF p_cis_tenant IS NULL OR p_dry_run IS NULL THEN
        RAISE EXCEPTION 'crm: erase_studio_invitations needs a tenant and dry_run true or false'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    PERFORM set_config('app.actor', 'platform:feed-tenant-erasure', true);
    IF p_dry_run THEN
        SELECT count(*) INTO v_rows FROM crm.studio_invitation WHERE cis_tenant_id = p_cis_tenant;
    ELSE
        DELETE FROM crm.studio_invitation WHERE cis_tenant_id = p_cis_tenant;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    END IF;
    PERFORM set_config('app.actor', v_actor, true);
    RETURN v_rows;
END;
$$;
REVOKE ALL ON FUNCTION crm.erase_studio_invitations(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.erase_studio_invitations(uuid, boolean) TO crm_eraser;
COMMENT ON FUNCTION crm.erase_studio_invitations(uuid, boolean) IS 'AA-1093 stage 2 (crm-067): counts (dry run) or deletes the crm.studio_invitation rows of one CIS tenant (cis_tenant_id), for the CRM step of the CIS tenant erasure saga. Refuses every actor but job:crm_tenant_erase (CRM56); runs the statement as platform:feed-tenant-erasure (the crm-020 row policy), then restores the actor. EXECUTE: crm_eraser only (SET LOCAL ROLE).';

DO $$
BEGIN
    IF pg_catalog.has_function_privilege('public', 'crm.erase_studio_invitations(uuid, boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-067: crm.erase_studio_invitations is executable by PUBLIC (SEC-4)';
    END IF;
    IF NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_studio_invitations(uuid, boolean)', 'EXECUTE')
    THEN
        RAISE EXCEPTION 'crm-067: crm_eraser cannot execute crm.erase_studio_invitations';
    END IF;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.studio_invitation', 'DELETE') THEN
        RAISE EXCEPTION 'crm-067: crm_app must not DELETE crm.studio_invitation (the function is the only path)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-067', now(), 'AA-1093 stage 2: crm.erase_studio_invitations (count or delete one CIS tenant''s Content studio invitations; job:crm_tenant_erase only, EXECUTE crm_eraser)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
