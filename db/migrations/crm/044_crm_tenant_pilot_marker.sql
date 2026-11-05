-- Migration crm-044: AA-969 part 2 (root ADR 0019 d16) — the pilot marker on crm.tenant, projected from CIS.
--
-- Owner: AA-Partner (api/migrations/044_crm_tenant_pilot_marker.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-044: crm-043 (AA-1028 R1 slice 2) is the highest on main.
--
-- Why. ADR 0019 d16 lets one real agency (the pilot) use Dev for at most 8 weeks, on conditions: every clean-up, E2E and
-- wave job skips the pilot agency, and the pilot agency gets a nightly export of its own (crm.export_job) so it can be
-- restored alone. The CIS tenant master holds the marker (shared.tenants.is_pilot, CIS 354, at most one pilot) and serves
-- it on the account snapshot of tenant.entitlements.v1 (is_pilot). The CRM projects that snapshot already
-- (crm_entitlement_pull, crm-043); it needs a place to keep the marker so its own jobs can read it inside the agency's
-- transaction (FORCE RLS, no cross-schema read of shared.tenants):
--   1. crm.tenant.is_pilot (boolean NOT NULL DEFAULT false): the CIS marker, written by the account feed only.
--   2. tenant_one_pilot_uq: at most one pilot agency (as CIS tenants_one_pilot_key).
--   3. crm.guard_pilot_marker() + triggers tenant_pilot_marker_ins / _upd: only the account feed
--      (platform:feed-tenant-account) or an unscoped owner session sets or changes the marker; any other actor (a
--      member, the L1 console, a seeder, a job) is refused with CRM04 platform_only. So a script or a console action
--      cannot mark a test agency "pilot" to shelter it, nor clear the marker to expose the pilot to a clean-up.
--
-- Behaviour. None on apply: every agency gets false; nothing reads the column until the AA-Partner code PR is deployed
-- (the projection then writes the CIS value, the lifecycle / clean-up paths skip the marked agency, the nightly pilot
-- backup exports it).
--
-- Class: contract (ALTER of an existing table, a new trigger on it). MIG-4: this migration-only PR, then the code PR
-- once it is applied on Dev. No new table, so no new DM-7.1 row (crm.tenant keeps its row).
--
-- Rollback (a NEW forward migration, after the code is reverted): DROP TRIGGER tenant_pilot_marker_ins / _upd ON
-- crm.tenant; DROP FUNCTION crm.guard_pilot_marker(); DROP INDEX crm.tenant_one_pilot_uq; ALTER TABLE crm.tenant DROP
-- COLUMN is_pilot.
--
-- X1. One BEGIN … COMMIT block, run by DB Migrate as crm_owner. Re-runnable (IF NOT EXISTS, CREATE OR REPLACE,
-- DROP TRIGGER IF EXISTS, ON CONFLICT DO NOTHING).

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-043') THEN
        RAISE EXCEPTION 'crm-044: apply crm-043 (the CIS account feed storage) first';
    END IF;
END $$;

-- ── 1. The marker ─────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE crm.tenant ADD COLUMN IF NOT EXISTS is_pilot BOOLEAN NOT NULL DEFAULT false;
COMMENT ON COLUMN crm.tenant.is_pilot IS 'AA-969 (crm-044, root ADR 0019 d16): the one Dev pilot agency, projected by crm_entitlement_pull from the CIS account snapshot (tenant.entitlements.v1 is_pilot = shared.tenants.is_pilot). Clean-up, E2E and wave jobs skip it; crm_pilot_backup exports it every night. Written only by the account feed (crm.guard_pilot_marker, CRM04).';

-- ── 2. At most one pilot ──────────────────────────────────────────────────────────────────────────────────────────
CREATE UNIQUE INDEX IF NOT EXISTS tenant_one_pilot_uq ON crm.tenant (is_pilot) WHERE is_pilot;

-- ── 3. Only the CIS account feed writes it ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.guard_pilot_marker() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    actor    text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    unscoped boolean := actor = '' AND current_user::text <> 'crm_app';
BEGIN
    IF NOT (unscoped OR actor = 'platform:feed-tenant-account') THEN
        RAISE EXCEPTION 'crm: platform_only (crm.tenant.is_pilot is written by the CIS account feed)'
            USING ERRCODE = 'CRM04';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_pilot_marker() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_pilot_marker() IS 'AA-969 (crm-044): refuses a change of crm.tenant.is_pilot (an insert with it true, an update that changes it) unless the actor is the CIS account feed (platform:feed-tenant-account) or the session is an unscoped owner session (CRM04 platform_only).';

DROP TRIGGER IF EXISTS tenant_pilot_marker_ins ON crm.tenant;
CREATE TRIGGER tenant_pilot_marker_ins
    BEFORE INSERT ON crm.tenant
    FOR EACH ROW WHEN (NEW.is_pilot)
    EXECUTE FUNCTION crm.guard_pilot_marker();
DROP TRIGGER IF EXISTS tenant_pilot_marker_upd ON crm.tenant;
CREATE TRIGGER tenant_pilot_marker_upd
    BEFORE UPDATE OF is_pilot ON crm.tenant
    FOR EACH ROW WHEN (OLD.is_pilot IS DISTINCT FROM NEW.is_pilot)
    EXECUTE FUNCTION crm.guard_pilot_marker();

-- ── Guards ────────────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'crm.tenant'::regclass AND attname = 'is_pilot'
                     AND NOT attisdropped AND attnotnull) THEN
        RAISE EXCEPTION 'crm-044: crm.tenant.is_pilot (NOT NULL) missing';
    END IF;
    IF NOT has_column_privilege('crm_app', 'crm.tenant', 'is_pilot', 'SELECT')
       OR NOT has_column_privilege('crm_app', 'crm.tenant', 'is_pilot', 'UPDATE') THEN
        RAISE EXCEPTION 'crm-044: crm_app must read and (through the account feed) write crm.tenant.is_pilot';
    END IF;
    IF (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'crm.tenant'::regclass AND NOT tgisinternal
          AND tgname IN ('tenant_pilot_marker_ins', 'tenant_pilot_marker_upd')) <> 2 THEN
        RAISE EXCEPTION 'crm-044: the pilot marker triggers are missing on crm.tenant';
    END IF;
    IF (SELECT count(*) FROM crm.tenant WHERE is_pilot) > 1 THEN
        RAISE EXCEPTION 'crm-044: more than one pilot agency';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-044', now(), 'AA-969 d16: crm.tenant.is_pilot (the CIS pilot marker, written by the account feed only, at most one)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
