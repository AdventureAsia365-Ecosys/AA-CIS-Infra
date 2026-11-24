-- Migration crm-087: AA-1152 (S289 lane g-1152; S285 decision B2 option C, tech lead S279 "a threshold is a setting")
-- — the two platform settings behind the agency's price rounding (crm-086): the default step per currency and the steps
-- an agency owner may choose, as CRM settings the tech lead edits on the CIS Platform > Settings page (CRM tab).
--
-- Owner: AA-Partner (api/migrations/087_crm_price_round_settings.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy Migration Apply runs. Key crm-087, right after crm-086 (the columns, its own migration-only PR); if the numbers
-- move, renumber: file name, this header, Guard 0 and the registration below, and the tests that name it (git grep
-- '087_' and 'crm-087').
--
-- What:
--   1. Two crm.setting_definition rows (settings-seed block, read by api/scripts/gen_settings_defaults.py into
--      app/platform_settings/compiled_defaults.json; guides in app/platform_settings/guides.json; readers in
--      app/proposals/rounding.py, shipped in this PR):
--        crm.agency_defaults.price_round_step   json {"USD": "1", "VND": "10000"}: the step of a currency the agency
--                                               chose none for (a currency not listed: 1 whole unit);
--        crm.agency_defaults.price_round_steps  json {"USD": ["1","5","10"], "VND": ["10000","50000","100000"]}: the
--                                               steps an agency owner may choose per currency.
--   2. Register crm-087.
--
-- Behaviour on apply: none for running code (the readers serve the compiled defaults, the same values, until a value
-- is approved).
--
-- Class: contract (INSERT of config rows into an existing table; no '-- migrate:' directive). Shipped with its readers
-- in the code PR like crm-084: the readers fall back to the compiled defaults and readiness does not wait for crm-087,
-- so the code deploying before Infra Migration Apply registers the file changes nothing (root ADR 0017a). No new
-- table (no DM-7.1 row), no personal data, no crm.erase_subject change.
--
-- Rollback (a new forward migration, after the code is reverted): DELETE FROM crm.setting_value /
-- crm.setting_definition WHERE key IN the two keys, as crm_owner.
--
-- Runs as crm_owner (the crm-064 definition guard allows only the owner), one BEGIN … COMMIT block, no role DDL.
-- Re-runnable (ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-086 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-087: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-086') THEN
        RAISE EXCEPTION 'crm-087: crm-086 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-087' AND description NOT LIKE 'AA-1152 price rounding settings:%') THEN
        RAISE EXCEPTION 'crm-087: the key crm-087 is already held by another migration (not AA-1152): renumber one';
    END IF;
END $$;

-- ── 1. The platform settings ─────────────────────────────────────────────────────────────────────
-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "crm.agency_defaults.price_round_step", "app": "crm", "area": "agency_defaults", "label": "Price rounding step (agency default)", "description": "Every price the CRM suggests to an agency (an AA item's sell in a proposal, the agency's own \"from\" prices on its planner) is rounded UP per traveller to a step of its currency, so agencies never show odd cents. An agency owner chooses its own step per currency in Settings > Payments; this is the step of a currency it did not choose, one decimal string per currency ({\"USD\": \"1\", \"VND\": \"10000\"}). A currency not listed rounds up to 1 whole unit. Read by app/proposals/rounding.py.", "value_type": "json", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": {"USD": "1", "VND": "10000"}, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.agency_defaults.price_round_steps", "app": "crm", "area": "agency_defaults", "label": "Price rounding steps an agency may choose", "description": "The rounding steps an agency owner may pick per currency in Settings > Payments (prices are always rounded up, never down, so a step never costs the agency margin). One list of decimal strings per currency; a currency not listed offers its default step only. Read by app/proposals/rounding.py.", "value_type": "json", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": {"USD": ["1", "5", "10"], "VND": ["10000", "50000", "100000"]}, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── Post-check ────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT count(*) FROM crm.setting_definition
         WHERE key IN ('crm.agency_defaults.price_round_step', 'crm.agency_defaults.price_round_steps')) <> 2 THEN
        RAISE EXCEPTION 'crm-087: the price rounding settings are not defined';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-087', now(), 'AA-1152 price rounding settings: crm.agency_defaults.price_round_step (the default step per currency) and crm.agency_defaults.price_round_steps (the steps an agency owner may choose)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
