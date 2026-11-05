-- Migration crm-046: AA-1030 R4 (root ADR 0019 b15, ADR 0005a decision 1) — the agency's default retail markup per
-- AA product type, from which the builder suggests the sell price of a new AA option.
--
-- Owner: AA-Partner (api/migrations/046_crm_retail_markup.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-046: crm-045 is the highest on main; if
-- main moves, renumber: file name, this header, the guard and registration below, app/db.py REQUIRED_SCHEMA_VERSIONS).
--
-- Why. ADR 0019 b15: AA quotes the agency its B2B price (with the agency's tier discount, Booking bk-045) and publishes
-- a suggested retail price (RRP = net + 25 %, the public "from" price). The agency sells at its own price (ADR 0005a d1:
-- warn below the "from" price, never block). The CRM suggests that sell price on a new AA option: the agency's own
-- markup on the B2B price for the item's product type when the owner set one, else AA's RRP (tours only).
--
-- What:
--   1. crm.tenant_settings.retail_markup_pct (JSONB, default '{}'): the owner's markup in percent per AA product type,
--      e.g. {"trip_plan": 20, "hotel_room": 15}; keys = the Booking component kinds (trip_plan, hotel_room, transfer,
--      guide, activity, entrance, meal), values 0 to 300 with at most 2 decimals; '{}' = no markup (the RRP is the
--      suggestion). Commercial data, no personal data; no reader role is granted it (crm_support_reader keeps its named
--      columns of crm-033).
--   2. crm.retail_markup_ok(jsonb): the shape rule (IMMUTABLE, invoker rights; EXECUTE to crm_app only, the role that
--      writes the column, as crm-012 did for crm.call_slot_rules_ok) and the CHECK tenant_settings_retail_markup_chk.
--
-- Behaviour. None on apply: every agency reads '{}' until its owner sets a markup in Settings; nothing reads the column
-- until the AA-Partner code PR is deployed.
--
-- Class: contract (ALTER of an existing table and a CHECK on it). MIG-4: this migration-only PR, then the code PR once
-- it is applied on Dev. DM-7.1: no new table (crm.tenant_settings' row covers the column; erased with the agency).
--
-- Rollback (a NEW forward migration, after the code is reverted): ALTER TABLE crm.tenant_settings DROP CONSTRAINT
-- tenant_settings_retail_markup_chk, DROP COLUMN retail_markup_pct; DROP FUNCTION crm.retail_markup_ok(jsonb).
--
-- X1. One BEGIN … COMMIT block, run by DB Migrate as crm_owner. Re-runnable (IF NOT EXISTS, CREATE OR REPLACE,
-- DROP CONSTRAINT IF EXISTS before the ADD).

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-005') THEN
        RAISE EXCEPTION 'crm-046: apply crm-005 (crm.tenant_settings) first';
    END IF;
END $$;

-- ── 1. The shape rule ────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.retail_markup_ok(p jsonb) RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    k text;
    v jsonb;
BEGIN
    IF p IS NULL OR jsonb_typeof(p) <> 'object' OR octet_length(p::text) > 1024 THEN
        RETURN false;
    END IF;
    FOR k, v IN SELECT * FROM jsonb_each(p) LOOP
        IF k NOT IN ('trip_plan', 'hotel_room', 'transfer', 'guide', 'activity', 'entrance', 'meal') THEN
            RETURN false;
        END IF;
        IF jsonb_typeof(v) <> 'number' OR (v #>> '{}')::numeric < 0 OR (v #>> '{}')::numeric > 300
           OR (v #>> '{}')::numeric <> round((v #>> '{}')::numeric, 2) THEN
            RETURN false;
        END IF;
    END LOOP;
    RETURN true;
END;
$$;
COMMENT ON FUNCTION crm.retail_markup_ok(jsonb) IS 'AA-1030 (crm-046): the shape of crm.tenant_settings.retail_markup_pct: an object keyed by AA product type (trip_plan, hotel_room, transfer, guide, activity, entrance, meal), each value a number of percent from 0 to 300 with at most 2 decimals; at most 1 KB.';
REVOKE ALL ON FUNCTION crm.retail_markup_ok(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.retail_markup_ok(jsonb) TO crm_app;  -- the CHECK runs with the writer's rights

-- ── 2. The column and its CHECK ──────────────────────────────────────────────────────────────────────────────────
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS retail_markup_pct JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_retail_markup_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_retail_markup_chk
    CHECK (crm.retail_markup_ok(retail_markup_pct));
COMMENT ON COLUMN crm.tenant_settings.retail_markup_pct IS 'AA-1030 (crm-046, ADR 0019 b15): the owner''s default retail markup in percent on the AA B2B price, per AA product type ({"trip_plan": 20}); the builder suggests sell = B2B price x (1 + markup / 100) on a new AA option, else AA''s suggested retail price (tours). ''{}'' = none. Commercial, no personal data.';

DO $$
BEGIN
    IF NOT has_column_privilege('crm_app', 'crm.tenant_settings', 'retail_markup_pct', 'UPDATE')
       OR NOT has_column_privilege('crm_app', 'crm.tenant_settings', 'retail_markup_pct', 'INSERT') THEN
        RAISE EXCEPTION 'crm-046: crm_app cannot write crm.tenant_settings.retail_markup_pct';
    END IF;
    IF NOT has_function_privilege('crm_app', 'crm.retail_markup_ok(jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-046: crm_app cannot run crm.retail_markup_ok (the CHECK of its writes)';
    END IF;
    IF has_column_privilege('crm_support_reader', 'crm.tenant_settings', 'retail_markup_pct', 'SELECT') THEN
        RAISE EXCEPTION 'crm-046: crm_support_reader must not read crm.tenant_settings.retail_markup_pct';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-046', now(), 'AA-1030: crm.tenant_settings.retail_markup_pct (the agency default retail markup per AA product type) + crm.retail_markup_ok')
ON CONFLICT (version) DO NOTHING;

COMMIT;
