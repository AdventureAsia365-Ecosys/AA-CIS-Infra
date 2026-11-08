-- Migration crm-047: AA-1038 R5 close-out (root ADR 0019 d11) — which agencies TripPlanner sends its leads to: the
-- projected flag crm.tenant_entitlement.tp_crm_leads, so crm_tp_lead_pull calls TripPlanner only for those agencies.
--
-- Owner: AA-Partner (api/migrations/047_crm_tp_crm_leads.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-047: crm-046 is the highest on main; if main moves, renumber:
-- file name, this header, the guard and registration below, app/db.py REQUIRED_SCHEMA_VERSIONS, the schema test).
--
-- Why. crm_tp_lead_pull (AA-1038 slice 3) lists TripPlanner's M2M lead API once per minute for EVERY agency the CRM
-- holds. TripPlanner serves only a tenant whose lead route resolves to crm (catalog.v_tenant_tripplanner_v1, CIS 390:
-- a TripPlanner subscription, served = in service and tp.hosted live, lead_channel crm = crm.core live) and answers
-- every other one 404; on Dev that is 58 needless calls and 58 counted errors a minute. The CRM already reads the
-- tenant's CIS account (tenant.entitlements.v1 snapshot, crm_entitlement_pull) and holds its own projection of it:
-- this column adds the one fact the lead pull needs, written by the same projection.
--
-- What:
--   1. crm.tenant_entitlement.tp_crm_leads (BOOLEAN NOT NULL DEFAULT false): true when the tenant's CIS account
--      entitles both tp.hosted (the hosted TripPlanner site) and crm.core (the CRM add-on), the two keys CIS 390's
--      route resolves lead_channel crm from. Written by crm_entitlement_pull only (the crm-008 platform-only guard,
--      CRM04, covers the row); in_service is not part of it (an agency out of service is locked by the same feed and
--      the lead pull never enters a locked agency). No personal data; commercial entitlement only.
--
-- Behaviour on apply. Every agency reads false until crm_entitlement_pull projects it again (an event for the tenant,
-- or the hourly reconcile of every agency, once the AA-Partner code PR is deployed); nothing reads the column before
-- that code. The CHECKs of crm.tenant_entitlement are unchanged.
--
-- Class: contract (ALTER of an existing table). MIG-4: this migration-only PR, then the code PR once it is applied on
-- Dev. DM-7.1: no new table (crm.tenant_entitlement's row covers the column; erased with the agency).
--
-- Rollback (a NEW forward migration, after the code is reverted): ALTER TABLE crm.tenant_entitlement DROP COLUMN
-- tp_crm_leads.
--
-- X1. One BEGIN … COMMIT block, run by DB Migrate as crm_owner. Re-runnable (ADD COLUMN IF NOT EXISTS).

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-043') THEN
        RAISE EXCEPTION 'crm-047: apply crm-043 (the entitlement feed storage) first';
    END IF;
END $$;

-- ── 1. The column ────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE crm.tenant_entitlement ADD COLUMN IF NOT EXISTS tp_crm_leads BOOLEAN NOT NULL DEFAULT false;
COMMENT ON COLUMN crm.tenant_entitlement.tp_crm_leads IS 'AA-1038 R5 (crm-047): the tenant''s CIS account (tenant.entitlements.v1) entitles both tp.hosted and crm.core, so TripPlanner routes its lead.submitted.v1 leads to this CRM (catalog.v_tenant_tripplanner_v1 lead_channel crm). Written by crm_entitlement_pull only; crm_tp_lead_pull calls TripPlanner only for an agency where it is true. false until projected.';

-- ── Guards ────────────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT has_column_privilege('crm_app', 'crm.tenant_entitlement', 'tp_crm_leads', 'UPDATE')
       OR NOT has_column_privilege('crm_app', 'crm.tenant_entitlement', 'tp_crm_leads', 'INSERT')
       OR NOT has_column_privilege('crm_app', 'crm.tenant_entitlement', 'tp_crm_leads', 'SELECT') THEN
        RAISE EXCEPTION 'crm-047: crm_app cannot read and write crm.tenant_entitlement.tp_crm_leads';
    END IF;
    IF has_column_privilege('crm_support_reader', 'crm.tenant_entitlement', 'tp_crm_leads', 'SELECT') THEN
        RAISE EXCEPTION 'crm-047: crm_support_reader must not read crm.tenant_entitlement.tp_crm_leads';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'crm.tenant_entitlement'::regclass
                     AND tgname = 'tenant_entitlement_platform_only' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'crm-047: trigger tenant_entitlement_platform_only missing on crm.tenant_entitlement';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-047', now(), 'AA-1038 R5: crm.tenant_entitlement.tp_crm_leads (tp.hosted and crm.core entitled: TripPlanner leads come to this CRM), written by crm_entitlement_pull')
ON CONFLICT (version) DO NOTHING;

COMMIT;
