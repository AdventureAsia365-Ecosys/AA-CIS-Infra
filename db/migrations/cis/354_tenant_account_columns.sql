-- Migration 354: AA-1028 R1 slice 1 (root ADR 0019 d1, d12, d16) — the account columns of shared.tenants (lifecycle
-- status, suspend reason, data region, kind, time zone, bill-to legal fields, the pilot marker), the trigger that
-- keeps the legacy is_active / cancelled_at in step with them, and the account.status_changed event.
--
-- Why. ADR 0019 d1: CIS shared is the master of the tenant account and lifecycle (README §3.2: lead -> applied ->
-- trial -> active <-> past_due -> suspended -> offboarding -> closed); d12: data_region exists from R1; d16: the Dev
-- pilot is exactly one kind='agency' tenant with a pilot marker, settled in this migration (a column, so a Dev guard
-- and the clean-up jobs can test it in SQL). TL-9: the bill-to legal fields live on shared.tenants (CIS is the master
-- of the account; Booking snapshots them when it issues an invoice, R4).
--
-- What.
--   1. ALTER TABLE shared.tenants ADD COLUMN (all with a constant default or nullable):
--        account_status text NOT NULL DEFAULT 'active'   lead | applied | trial | active | past_due | suspended |
--                                                        offboarding | closed
--        suspend_reason text                             billing | compliance | security | tenant_request; only while
--                                                        suspended (cleared on any other status)
--        data_region    text NOT NULL DEFAULT 'us'       us | eu (an EU cell is built only on a trigger, d12)
--        kind           text NOT NULL DEFAULT 'agency'   agency | demo | internal (is_canary stays as it is; the CRM
--                                                        still reads it as is_synthetic, tenant.membership.v1 1.2)
--        time_zone      text NOT NULL DEFAULT 'UTC'      an IANA name, checked by the trigger
--        legal_entity_name (pii:name), tax_id (pii:government_id), billing_email (pii:contact), billing_address
--        (pii:address), billing_country (ISO 3166-1 alpha-2), contract_version, segment (high_touch | tech_touch):
--        the bill-to fields, NULL until finance fills them; never served by tenant.entitlements.v1
--        is_pilot       boolean NOT NULL DEFAULT false   the d16 pilot marker
--        pilot_ends_at  timestamptz                      set exactly when is_pilot (at most 8 weeks, d16: a policy the
--                                                        Dev guard of a later slice checks, not a CHECK here)
--      CHECKs on the vocabularies and lengths; tenants_pilot_check (is_pilot = pilot_ends_at set; a pilot is an
--      agency); unique index tenants_one_pilot_key ((is_pilot)) WHERE is_pilot: at most one pilot tenant.
--   2. Backfill (every existing row): account_status from the legacy columns (cancelled_at set -> offboarding,
--      is_active false -> suspended, else active); kind = internal for the AA internal tenant
--      (00000000-0000-0000-0000-000000000001) and plan_tier internal, demo for is_canary true, else agency.
--   3. BEFORE INSERT OR UPDATE trigger tenants_account_status_sync (shared.tenants_account_status_sync()):
--        - a write that changes account_status leads: is_active := status in (trial, active, past_due);
--          cancelled_at := kept or now() for offboarding / closed, NULL otherwise; suspend_reason cleared unless
--          suspended;
--        - a legacy write (api/routers/admin.py: PATCH is_active, offboard, restore) that changes is_active or
--          cancelled_at but not account_status derives it: cancelled_at set -> offboarding; is_active false ->
--          suspended (lead / applied stay); is_active true from suspended / offboarding / closed / lead / applied ->
--          active (trial / past_due stay);
--        - an INSERT: cancelled_at set -> offboarding, is_active false over a live status -> suspended; then the
--          legacy columns follow the status;
--        - time_zone must be a name the server knows (now() AT TIME ZONE ... raises otherwise).
--   4. AFTER triggers tenants_account_event_ins / _upd (shared.tenants_account_emit_status()): one
--      account.status_changed event {status, previous_status, suspend_reason} when the status or the reason changes
--      (UPDATE OF account_status, suspend_reason, is_active, cancelled_at: a legacy write changes the status through
--      the BEFORE trigger, which a column list alone would not see).
--   5. tenants_membership_feed_upd (CIS 276) is re-created with account_status in its column list (same WHEN, same
--      function): a write of account_status alone changes is_active / cancelled_at in the BEFORE trigger, and a
--      column-list trigger fires only for the columns the UPDATE names.
--   6. Register 354.
--
-- Trigger privileges. The triggers run as the writer of shared.tenants (MIG-6): cis_app (and the owner, the master)
-- already holds INSERT on shared.tenant_account_event and EXECUTE on shared.tenant_account_emit (353). Guard 2
-- refuses the file if any role that may INSERT or UPDATE shared.tenants through a grant (the owner, a grantee of the
-- table or a column, or a member of one) could not emit an account event. A role whose only path is a predefined
-- role (rds_superuser through pg_write_all_data) is not a writer of this table and is not counted.
--
-- Behaviour. No change for running code: the legacy columns keep their meaning and every admin write path
-- (create, PATCH is_active, offboard, restore) leaves the same is_active / cancelled_at as before (guard 3 probes
-- them). New: one account.status_changed row per tenant create / lock / unlock / offboard / restore (a handful a
-- month on Dev). The backfill writes no event.
--
-- Class: contract (ADD COLUMN with constraints, a unique index, triggers on a pre-existing table, an UPDATE of its
-- rows, a re-created trigger). MIG-4: migration-only PR; on Dev a person applies it after 353 with DB Migrate apply
-- (every job table idle, DM-11.4; Infra Migration Apply stops at the pending 336, see 353). Locks: ACCESS EXCLUSIVE
-- on shared.tenants for the file's milliseconds (~4 rows).
--
-- Rollback (a NEW forward migration, after the code that reads the columns is reverted): DROP TRIGGER
-- tenants_account_status_sync, tenants_account_event_ins, tenants_account_event_upd; re-create
-- tenants_membership_feed_upd as in 276; DROP FUNCTION shared.tenants_account_status_sync(),
-- shared.tenants_account_emit_status(); ALTER TABLE shared.tenants DROP COLUMN the 14 columns (destructive, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of shared.tenants.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical.

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── Guard 1 ─────────────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regprocedure('shared.tenant_account_emit(text,uuid,jsonb)') IS NULL
       OR to_regprocedure('shared.tenant_membership_emit_tenant()') IS NULL THEN
        RAISE EXCEPTION 'migration 354: needs 353 (shared.tenant_account_emit) and 276 (the membership feed trigger)';
    END IF;
END $$;

-- ── 1. Columns ──────────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.tenants
    ADD COLUMN IF NOT EXISTS account_status    text NOT NULL DEFAULT 'active',
    ADD COLUMN IF NOT EXISTS suspend_reason    text,
    ADD COLUMN IF NOT EXISTS data_region       text NOT NULL DEFAULT 'us',
    ADD COLUMN IF NOT EXISTS kind              text NOT NULL DEFAULT 'agency',
    ADD COLUMN IF NOT EXISTS time_zone         text NOT NULL DEFAULT 'UTC',
    ADD COLUMN IF NOT EXISTS legal_entity_name text,
    ADD COLUMN IF NOT EXISTS tax_id            text,
    ADD COLUMN IF NOT EXISTS billing_email     text,
    ADD COLUMN IF NOT EXISTS billing_address   text,
    ADD COLUMN IF NOT EXISTS billing_country   text,
    ADD COLUMN IF NOT EXISTS contract_version  text,
    ADD COLUMN IF NOT EXISTS segment           text,
    ADD COLUMN IF NOT EXISTS is_pilot          boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS pilot_ends_at     timestamp with time zone;

-- ── 2. Backfill (before the triggers exist: no event, no derived write) ─────────────────────────────────────────────
UPDATE shared.tenants
   SET account_status = CASE WHEN cancelled_at IS NOT NULL THEN 'offboarding'
                             WHEN NOT is_active THEN 'suspended'
                             ELSE 'active' END,
       kind = CASE WHEN tenant_id = '00000000-0000-0000-0000-000000000001'::uuid OR plan_tier = 'internal'
                   THEN 'internal'
                   WHEN is_canary IS TRUE THEN 'demo'
                   ELSE 'agency' END
 WHERE NOT EXISTS (SELECT 1 FROM shared.schema_versions v WHERE v.version = '354');

ALTER TABLE shared.tenants DROP CONSTRAINT IF EXISTS tenants_account_status_check;
ALTER TABLE shared.tenants ADD CONSTRAINT tenants_account_status_check
    CHECK (account_status IN ('lead', 'applied', 'trial', 'active', 'past_due', 'suspended', 'offboarding', 'closed'));
ALTER TABLE shared.tenants DROP CONSTRAINT IF EXISTS tenants_suspend_reason_check;
ALTER TABLE shared.tenants ADD CONSTRAINT tenants_suspend_reason_check
    CHECK (suspend_reason IS NULL
           OR (account_status = 'suspended'
               AND suspend_reason IN ('billing', 'compliance', 'security', 'tenant_request')));
ALTER TABLE shared.tenants DROP CONSTRAINT IF EXISTS tenants_data_region_check;
ALTER TABLE shared.tenants ADD CONSTRAINT tenants_data_region_check CHECK (data_region IN ('us', 'eu'));
ALTER TABLE shared.tenants DROP CONSTRAINT IF EXISTS tenants_kind_check;
ALTER TABLE shared.tenants ADD CONSTRAINT tenants_kind_check CHECK (kind IN ('agency', 'demo', 'internal'));
ALTER TABLE shared.tenants DROP CONSTRAINT IF EXISTS tenants_time_zone_check;
ALTER TABLE shared.tenants ADD CONSTRAINT tenants_time_zone_check
    CHECK (char_length(time_zone) BETWEEN 1 AND 64 AND time_zone ~ '^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$');
ALTER TABLE shared.tenants DROP CONSTRAINT IF EXISTS tenants_bill_to_check;
ALTER TABLE shared.tenants ADD CONSTRAINT tenants_bill_to_check
    CHECK ((legal_entity_name IS NULL OR char_length(legal_entity_name) BETWEEN 1 AND 300)
           AND (tax_id IS NULL OR char_length(tax_id) BETWEEN 1 AND 64)
           AND (billing_email IS NULL OR (char_length(billing_email) <= 254 AND billing_email LIKE '%_@_%'))
           AND (billing_address IS NULL OR char_length(billing_address) BETWEEN 1 AND 1000)
           AND (billing_country IS NULL OR billing_country ~ '^[A-Z]{2}$')
           AND (contract_version IS NULL OR char_length(contract_version) BETWEEN 1 AND 64)
           AND (segment IS NULL OR segment IN ('high_touch', 'tech_touch')));
ALTER TABLE shared.tenants DROP CONSTRAINT IF EXISTS tenants_pilot_check;
ALTER TABLE shared.tenants ADD CONSTRAINT tenants_pilot_check
    CHECK (is_pilot = (pilot_ends_at IS NOT NULL) AND (NOT is_pilot OR kind = 'agency'));
CREATE UNIQUE INDEX IF NOT EXISTS tenants_one_pilot_key ON shared.tenants (is_pilot) WHERE is_pilot;

COMMENT ON COLUMN shared.tenants.account_status IS
    'AA-1028 R1 (CIS 354, root ADR 0019 §3.2): lead | applied | trial | active | past_due | suspended | offboarding | '
    'closed. The master of the tenant lifecycle; is_active / cancelled_at follow it (trigger '
    'tenants_account_status_sync) so legacy code keeps working. Changes write account.status_changed.';
COMMENT ON COLUMN shared.tenants.suspend_reason IS
    'AA-1028 R1 (354): billing | compliance | security | tenant_request, only while suspended.';
COMMENT ON COLUMN shared.tenants.data_region IS
    'AA-1028 R1 (354, ADR 0019 d12): us | eu, where the tenant''s data lives. Every tenant is us until an EU cell exists.';
COMMENT ON COLUMN shared.tenants.kind IS
    'AA-1028 R1 (354): agency (a paying or pilot agency) | demo (synthetic, E2E, sales demo) | internal (AA itself).';
COMMENT ON COLUMN shared.tenants.time_zone IS 'AA-1028 R1 (354): the agency''s IANA time zone (billing days, digests).';
COMMENT ON COLUMN shared.tenants.legal_entity_name IS
    'pii:name; AA-1028 R1 (354, TL-9): the bill-to legal entity (a sole trader''s name is a person''s name).';
COMMENT ON COLUMN shared.tenants.tax_id IS
    'pii:government_id; AA-1028 R1 (354, TL-9): the bill-to tax number (a sole trader''s identifies a person).';
COMMENT ON COLUMN shared.tenants.billing_email IS 'pii:contact; AA-1028 R1 (354, TL-9): where invoices are sent.';
COMMENT ON COLUMN shared.tenants.billing_address IS 'pii:address; AA-1028 R1 (354, TL-9): the bill-to address.';
COMMENT ON COLUMN shared.tenants.billing_country IS 'AA-1028 R1 (354): ISO 3166-1 alpha-2 of the bill-to entity.';
COMMENT ON COLUMN shared.tenants.contract_version IS 'AA-1028 R1 (354): the signed contract / DPA version label.';
COMMENT ON COLUMN shared.tenants.segment IS 'AA-1028 R1 (354, §3.8): high_touch | tech_touch care model.';
COMMENT ON COLUMN shared.tenants.is_pilot IS
    'AA-1028 R1 (354, ADR 0019 d16): the one Dev pilot agency (unique index tenants_one_pilot_key); clean-up, E2E and '
    'wave jobs skip it.';
COMMENT ON COLUMN shared.tenants.pilot_ends_at IS 'AA-1028 R1 (354, d16): end of the pilot (at most 8 weeks).';

-- ── 3. Status sync (BEFORE) ─────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION shared.tenants_account_status_sync() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
DECLARE
    live constant text[] := ARRAY['trial', 'active', 'past_due'];
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.cancelled_at IS NOT NULL AND NEW.account_status NOT IN ('offboarding', 'closed') THEN
            NEW.account_status := 'offboarding';
        ELSIF NOT NEW.is_active AND NEW.account_status = ANY (live) THEN
            NEW.account_status := 'suspended';
        END IF;
    ELSIF NEW.account_status IS NOT DISTINCT FROM OLD.account_status
          AND (NEW.is_active IS DISTINCT FROM OLD.is_active OR NEW.cancelled_at IS DISTINCT FROM OLD.cancelled_at) THEN
        -- a legacy writer (is_active / cancelled_at): derive the status from them
        IF NEW.cancelled_at IS NOT NULL THEN
            IF OLD.account_status NOT IN ('offboarding', 'closed') THEN
                NEW.account_status := 'offboarding';
            END IF;
        ELSIF NOT NEW.is_active THEN
            IF OLD.account_status = ANY (live) OR OLD.account_status IN ('offboarding', 'closed') THEN
                NEW.account_status := 'suspended';
            END IF;
        ELSIF OLD.account_status IN ('suspended', 'offboarding', 'closed', 'lead', 'applied') THEN
            NEW.account_status := 'active';
        END IF;
    END IF;
    -- the legacy columns follow the status
    NEW.is_active := NEW.account_status = ANY (live);
    IF NEW.account_status IN ('offboarding', 'closed') THEN
        NEW.cancelled_at := coalesce(NEW.cancelled_at, now());
    ELSE
        NEW.cancelled_at := NULL;
    END IF;
    IF NEW.account_status <> 'suspended' THEN
        NEW.suspend_reason := NULL;
    END IF;
    PERFORM now() AT TIME ZONE NEW.time_zone;    -- an unknown zone raises invalid_parameter_value
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS tenants_account_status_sync ON shared.tenants;
CREATE TRIGGER tenants_account_status_sync
    BEFORE INSERT OR UPDATE ON shared.tenants
    FOR EACH ROW EXECUTE FUNCTION shared.tenants_account_status_sync();

-- ── 4. account.status_changed (AFTER) ───────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION shared.tenants_account_emit_status() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
BEGIN
    PERFORM shared.tenant_account_emit('account.status_changed', NEW.tenant_id, jsonb_build_object(
        'status', NEW.account_status,
        'previous_status', CASE WHEN TG_OP = 'UPDATE' THEN OLD.account_status END,
        'suspend_reason', NEW.suspend_reason));
    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS tenants_account_event_ins ON shared.tenants;
CREATE TRIGGER tenants_account_event_ins
    AFTER INSERT ON shared.tenants
    FOR EACH ROW EXECUTE FUNCTION shared.tenants_account_emit_status();
DROP TRIGGER IF EXISTS tenants_account_event_upd ON shared.tenants;
CREATE TRIGGER tenants_account_event_upd
    AFTER UPDATE OF account_status, suspend_reason, is_active, cancelled_at ON shared.tenants
    FOR EACH ROW
    WHEN (OLD.account_status IS DISTINCT FROM NEW.account_status
          OR OLD.suspend_reason IS DISTINCT FROM NEW.suspend_reason)
    EXECUTE FUNCTION shared.tenants_account_emit_status();

-- ── 5. The 276 membership feed also sees a status-only write ────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS tenants_membership_feed_upd ON shared.tenants;
CREATE TRIGGER tenants_membership_feed_upd
    AFTER UPDATE OF is_active, cancelled_at, account_status ON shared.tenants
    FOR EACH ROW
    WHEN (OLD.is_active IS DISTINCT FROM NEW.is_active OR OLD.cancelled_at IS DISTINCT FROM NEW.cancelled_at)
    EXECUTE FUNCTION shared.tenant_membership_emit_tenant();

REVOKE ALL ON FUNCTION shared.tenants_account_status_sync(), shared.tenants_account_emit_status() FROM PUBLIC;

-- ── Guard 2: every writer of shared.tenants can emit an account event ───────────────────────────────────────────────
-- A writer is the table owner or a grantee of INSERT / UPDATE on the table or one of its columns, and every role
-- that inherits one of those. A role whose only path is a predefined role (pg_write_all_data, which rds_superuser
-- holds on RDS) is not counted: has_table_privilege() alone would report rds_superuser, which is no member of
-- cis_owner and so cannot run shared.tenant_account_emit() (the RDS master is a member of cis_owner and is counted
-- through it). The CI replay builds no rds_* role; test_aa1028 covers a pg_write_all_data member.
DO $$
DECLARE
    bad text;
BEGIN
    WITH grantee AS (
        SELECT c.relowner AS oid FROM pg_class c WHERE c.oid = 'shared.tenants'::regclass
        UNION
        SELECT a.grantee FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid = 'shared.tenants'::regclass AND a.privilege_type IN ('INSERT', 'UPDATE')
        UNION
        SELECT a.grantee FROM pg_attribute att CROSS JOIN LATERAL aclexplode(att.attacl) a
         WHERE att.attrelid = 'shared.tenants'::regclass AND NOT att.attisdropped
           AND a.privilege_type IN ('INSERT', 'UPDATE')
    )
    SELECT string_agg(r.rolname, ', ' ORDER BY r.rolname) INTO bad
      FROM pg_roles r
     WHERE r.rolname NOT LIKE 'pg\_%' AND NOT r.rolsuper
       AND EXISTS (SELECT 1 FROM grantee g WHERE g.oid = 0 OR pg_has_role(r.oid, g.oid, 'USAGE'))
       AND NOT (has_table_privilege(r.oid, 'shared.tenant_account_event', 'INSERT')
                AND has_function_privilege(r.oid, 'shared.tenant_account_emit(text,uuid,jsonb)', 'EXECUTE'));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 354: these writers of shared.tenants could not write an account event: %', bad;
    END IF;
END $$;

-- ── Guard 3: behaviour of the legacy write paths (a probe tenant, always rolled back) ───────────────────────────────
DO $$
DECLARE
    probe uuid := gen_random_uuid();
    st    text;
    act   boolean;
    canc  timestamptz;
    n     integer;
BEGIN
    BEGIN
        INSERT INTO shared.tenants (tenant_id, name, slug, plan_tier, posts_per_week, api_key_hash, rate_limit_rpm,
                                    is_active)
        VALUES (probe, 'migration 354 probe', 'zz354-' || left(probe::text, 8), 'starter', 3, NULL, 60, true);
        SELECT account_status INTO st FROM shared.tenants WHERE tenant_id = probe;
        IF st <> 'active' THEN RAISE EXCEPTION 'migration 354: create gave %', st; END IF;
        UPDATE shared.tenants SET is_active = false WHERE tenant_id = probe;              -- PATCH is_active false
        SELECT account_status INTO st FROM shared.tenants WHERE tenant_id = probe;
        IF st <> 'suspended' THEN RAISE EXCEPTION 'migration 354: lock gave %', st; END IF;
        UPDATE shared.tenants SET is_active = true WHERE tenant_id = probe;               -- PATCH is_active true
        UPDATE shared.tenants SET cancelled_at = now(), is_active = false WHERE tenant_id = probe;   -- offboard
        SELECT account_status, is_active INTO st, act FROM shared.tenants WHERE tenant_id = probe;
        IF st <> 'offboarding' OR act THEN RAISE EXCEPTION 'migration 354: offboard gave % / %', st, act; END IF;
        UPDATE shared.tenants SET cancelled_at = NULL, is_active = true WHERE tenant_id = probe;    -- restore
        UPDATE shared.tenants SET account_status = 'past_due' WHERE tenant_id = probe;   -- the new column leads
        SELECT account_status, is_active, cancelled_at INTO st, act, canc FROM shared.tenants WHERE tenant_id = probe;
        IF st <> 'past_due' OR NOT act OR canc IS NOT NULL THEN
            RAISE EXCEPTION 'migration 354: past_due gave % / % / %', st, act, canc;
        END IF;
        UPDATE shared.tenants SET account_status = 'suspended', suspend_reason = 'billing' WHERE tenant_id = probe;
        SELECT is_active INTO act FROM shared.tenants WHERE tenant_id = probe;
        IF act THEN RAISE EXCEPTION 'migration 354: a suspended tenant stayed active'; END IF;
        SELECT count(*) INTO n FROM shared.tenant_account_event
         WHERE tenant_id = probe AND type = 'account.status_changed';
        IF n <> 7 THEN RAISE EXCEPTION 'migration 354: % status events, expected 7', n; END IF;
        SELECT count(*) INTO n FROM shared.tenant_membership_event WHERE tenant_id = probe;
        -- created, locked, unlocked, deleted, unlocked (restore), locked (suspended); past_due keeps the agency active
        IF n <> 6 THEN RAISE EXCEPTION 'migration 354: % membership feed events, expected 6', n; END IF;
        RAISE EXCEPTION 'probe done' USING ERRCODE = 'ZZ354';
    EXCEPTION WHEN SQLSTATE 'ZZ354' THEN
        NULL;
    END;
    IF EXISTS (SELECT 1 FROM shared.tenants WHERE tenant_id = probe) THEN
        RAISE EXCEPTION 'migration 354: the behaviour probe was not rolled back';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('354', now(), 'AA-1028 R1: shared.tenants account status, region, kind, bill-to fields, pilot marker')
ON CONFLICT (version) DO NOTHING;

COMMIT;
