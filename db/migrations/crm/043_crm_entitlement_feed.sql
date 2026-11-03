-- Migration crm-043: AA-1028 R1 slice 2 (root ADR 0019 d1, d2) — the storage of crm_entitlement_pull, the CRM consumer
-- of CIS tenant.entitlements.v1: the feed state, the projection marker on crm.tenant_entitlement, and the lock source
-- rule that lets the account feed's actor name cis_tenant.
--
-- Owner: AA-Partner (api/migrations/043_crm_entitlement_feed.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-043: crm-042 (AA-1027 F4) is the highest on main.
--
-- Why. ADR 0019 d1: crm.tenant and crm.tenant_entitlement become read-only projections of the CIS master (CIS shared,
-- 353-356); the CRM's own pull job crm_entitlement_pull writes them (README §3.5: the CIS feed is the only writer, the
-- crm.ops.v1 /entitlements routes become read-only). The pull reads GET /tenant/v1/account-events (cursor) and, for each
-- agency an event names, GET /tenant/v1/tenants/{id}/account, then writes the agency's plan, seats and allowed
-- features and locks / unlocks the agency on the account's in_service. It needs:
--   1. crm.entitlement_feed_state: platform singleton like crm.membership_feed_state (crm-013): the opaque cursor
--      CIS returned last, the last success, the last error class and time, the consecutive failures it backs off on,
--      and last_reconcile_at (the hourly pass that re-projects every agency, so an agency created in the CRM after its
--      tenant's last CIS event is projected too) with reconcile_failures (consecutive passes in which an agency's
--      snapshot failed: the reconcile's own health, which the event pull's success never resets). No tenant column, no
--      personal data. One row; crm_app SELECT + UPDATE.
--   2. crm.tenant_entitlement.projected_at (timestamptz, NULL = never projected from CIS: the row holds what the
--      L1 console wrote, and the console may still write it): set by the pull on every projection; crm.ops.v1 1.11
--      serves it as managed_by (the L1 PUT /entitlements-allowed answers 409 only once it is set).
--   3. crm.sync_tenant_lock_source() (crm-013 text plus one actor): a cis_tenant source may come from the membership
--      feed (platform:feed-tenant-membership) or the account feed (platform:feed-tenant-account); cis_membership stays
--      the membership feed's only. Everything else as crm-013.
--
-- Behaviour. None on apply: nothing reads the new column or table until the AA-Partner code PR is deployed. The CHECK
-- of crm.tenant_entitlement (plan free / core / pro, member_limit 1-500, the six feature codes) is unchanged.
--
-- Class: contract (ALTER of an existing table, CREATE OR REPLACE of an existing function, INSERT of the state row).
-- MIG-4: this migration-only PR, then the code PR once it is applied on Dev.
-- DM-7.1: crm.entitlement_feed_state is platform reference data (root 02-data-management.md row, same PR set).
--
-- Rollback (a NEW forward migration, after the code is reverted): DROP TABLE crm.entitlement_feed_state; ALTER TABLE
-- crm.tenant_entitlement DROP COLUMN projected_at; restate crm-013's crm.sync_tenant_lock_source().
--
-- X1. One BEGIN … COMMIT block, run by DB Migrate as crm_owner. Re-runnable (IF NOT EXISTS, CREATE OR REPLACE,
-- DROP TRIGGER IF EXISTS, ON CONFLICT DO NOTHING).

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-013') THEN
        RAISE EXCEPTION 'crm-043: apply crm-013 (the membership feed storage) first';
    END IF;
END $$;

-- ── 1. crm.entitlement_feed_state (platform singleton) ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.entitlement_feed_state (
    singleton         BOOLEAN PRIMARY KEY DEFAULT true,
    feed_cursor       TEXT,
    last_ok_at        TIMESTAMPTZ,
    last_error_class  TEXT,
    last_error_at     TIMESTAMPTZ,
    failures          INTEGER NOT NULL DEFAULT 0,
    last_reconcile_at TIMESTAMPTZ,
    reconcile_failures INTEGER NOT NULL DEFAULT 0,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT entitlement_feed_state_singleton_chk CHECK (singleton),
    CONSTRAINT entitlement_feed_state_cursor_chk CHECK (feed_cursor IS NULL OR feed_cursor ~ '^[!-~]{1,200}$'),
    CONSTRAINT entitlement_feed_state_error_chk CHECK (
        (last_error_class IS NULL) = (last_error_at IS NULL)
        AND (last_error_class IS NULL OR last_error_class ~ '^[a-z][a-z0-9_]{0,39}$')
    ),
    CONSTRAINT entitlement_feed_state_failures_chk CHECK (failures BETWEEN 0 AND 1000000),
    CONSTRAINT entitlement_feed_state_reconcile_failures_chk CHECK (reconcile_failures BETWEEN 0 AND 1000000)
);
DROP TRIGGER IF EXISTS entitlement_feed_state_set_updated_at ON crm.entitlement_feed_state;
CREATE TRIGGER entitlement_feed_state_set_updated_at
    BEFORE UPDATE ON crm.entitlement_feed_state
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
INSERT INTO crm.entitlement_feed_state (singleton) VALUES (true) ON CONFLICT DO NOTHING;
-- The crm-001 default privileges give crm_app DML on every new table: keep SELECT + UPDATE only.
REVOKE ALL ON crm.entitlement_feed_state FROM PUBLIC;
REVOKE INSERT, DELETE, TRUNCATE, REFERENCES, TRIGGER ON crm.entitlement_feed_state FROM crm_app;
GRANT SELECT, UPDATE ON crm.entitlement_feed_state TO crm_app;
COMMENT ON TABLE crm.entitlement_feed_state IS 'AA-1028 R1 slice 2 (crm-043): the one consumer state of the CIS feed tenant.entitlements.v1 (crm_entitlement_pull): the opaque cursor CIS returned last (printable ASCII, <= 200), the last successful pull, the last error class and time, the consecutive failures the job backs off on, the last hourly reconcile of every agency and the consecutive reconcile passes in which an agency failed. Platform table: no tenant column, no personal data. One row; crm_app SELECT + UPDATE only.';

-- ── 2. The projection marker ──────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE crm.tenant_entitlement ADD COLUMN IF NOT EXISTS projected_at TIMESTAMPTZ;
COMMENT ON COLUMN crm.tenant_entitlement.projected_at IS 'AA-1028 R1 slice 2 (crm-043): when crm_entitlement_pull last wrote plan, member_limit and allowed_features from the tenant''s CIS account (tenant.entitlements.v1); NULL = never projected (the row holds what the L1 console wrote, and the console may still write it). Served by crm.ops.v1 1.11 as managed_by.';

-- ── 3. The lock source rule: cis_tenant from either CIS feed ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.sync_tenant_lock_source() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    actor     text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    unscoped  boolean := actor = '' AND current_user::text <> 'crm_app';
    explicit  boolean;
BEGIN
    IF NEW.status IS DISTINCT FROM 'locked' THEN
        NEW.lock_source := NULL;  -- a: leaving locked (or never locked) clears the source, whoever moves the status
        RETURN NEW;
    END IF;
    explicit := NEW.lock_source IS NOT NULL
                AND (TG_OP = 'INSERT' OR NEW.lock_source IS DISTINCT FROM OLD.lock_source);
    IF explicit AND NOT unscoped THEN
        -- c: cis_tenant only from a CIS feed (membership or account, crm-043), cis_membership only from the
        -- membership feed; any source only from a platform actor.
        IF NEW.lock_source = 'cis_membership' AND actor <> 'platform:feed-tenant-membership' THEN
            RAISE EXCEPTION 'crm: lock_source_forbidden (only the CIS membership feed names cis_membership)'
                USING ERRCODE = 'CRM21';
        END IF;
        IF NEW.lock_source = 'cis_tenant'
           AND actor NOT IN ('platform:feed-tenant-membership', 'platform:feed-tenant-account') THEN
            RAISE EXCEPTION 'crm: lock_source_forbidden (only a CIS feed names cis_tenant)'
                USING ERRCODE = 'CRM21';
        END IF;
        IF actor NOT LIKE 'platform:%' THEN
            RAISE EXCEPTION 'crm: lock_source_forbidden (actor % may not name a lock source)', split_part(actor, ':', 1)
                USING ERRCODE = 'CRM21';
        END IF;
    END IF;
    IF NEW.lock_source IS NULL THEN
        NEW.lock_source := 'aa_ops';  -- b: a lock that names no source is AA's (the L1 console)
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.sync_tenant_lock_source() FROM PUBLIC;
COMMENT ON FUNCTION crm.sync_tenant_lock_source() IS 'AA-978 (crm-013), AA-1028 (crm-043): keeps crm.tenant.lock_source in step with the status: cleared when the agency is not locked, aa_ops when a lock names no source; cis_tenant only from a CIS feed actor (platform:feed-tenant-membership or platform:feed-tenant-account), cis_membership only from the membership feed, any explicit source only from a platform actor (CRM21 lock_source_forbidden); an unscoped session is not restricted.';

-- ── Guards ────────────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT count(*) FROM crm.entitlement_feed_state) <> 1 THEN
        RAISE EXCEPTION 'crm-043: crm.entitlement_feed_state must hold exactly one row';
    END IF;
    IF NOT has_table_privilege('crm_app', 'crm.entitlement_feed_state', 'SELECT')
       OR NOT has_table_privilege('crm_app', 'crm.entitlement_feed_state', 'UPDATE')
       OR has_table_privilege('crm_app', 'crm.entitlement_feed_state', 'INSERT')
       OR has_table_privilege('crm_app', 'crm.entitlement_feed_state', 'DELETE') THEN
        RAISE EXCEPTION 'crm-043: crm_app must hold SELECT and UPDATE only on crm.entitlement_feed_state';
    END IF;
    IF NOT has_column_privilege('crm_app', 'crm.tenant_entitlement', 'projected_at', 'UPDATE') THEN
        RAISE EXCEPTION 'crm-043: crm_app cannot write crm.tenant_entitlement.projected_at';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'crm.tenant'::regclass
                     AND tgname = 'tenant_sync_lock_source' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'crm-043: trigger tenant_sync_lock_source missing on crm.tenant';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-043', now(), 'AA-1028 R1 slice 2: crm.entitlement_feed_state, crm.tenant_entitlement.projected_at, cis_tenant lock source also from the CIS account feed (crm_entitlement_pull)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
