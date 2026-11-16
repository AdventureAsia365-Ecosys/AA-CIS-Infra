-- Migration crm-075: AA-1116 (option B pricing, S282; tech lead S279: every threshold, limit and cap is an
-- admin-editable setting) — the CRM member limit used when CIS gives no seats, and its ceiling, move from code literals
-- (DEFAULT_MEMBER_LIMIT 10, MEMBER_LIMIT_MAX 500) into the CRM settings registry (crm-064); the 008 column default 10
-- of crm.tenant_entitlement.member_limit goes (every writer now names the value).
--
-- Owner: AA-Partner (api/migrations/075_crm_member_limit_settings.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy Migration Apply runs. Key crm-075, right after crm-074; if the numbers move, renumber: file name, this header,
-- Guard 0 and the registration below, and the tests that name it (git grep '075_' and 'crm-075').
--
-- What:
--   1. two crm.setting_definition rows, area members, platform scope, maker-checker, enforced, no env override (the
--      block between "settings-seed:begin" and "settings-seed:end" is read by api/scripts/gen_settings_defaults.py into
--      app/platform_settings/compiled_defaults.json; the seed-parity test keeps the two equal):
--        crm.members.default_limit (3 members: option B, a CRM plan bills at least 3 seats; the limit of an agency CIS
--          gives no crm.seats, and of an agency with no entitlement row yet; 1..500),
--        crm.members.max_limit (500 members: the most seats the CIS crm.seats limit is projected to; 1..500, the
--          crm.tenant_entitlement CHECK tenant_entitlement_limit_chk of crm-008).
--      The CIS admin page (Platform > Settings, CRM tab) edits them; the guides are app/platform_settings/guides.json.
--   2. ALTER TABLE crm.tenant_entitlement ALTER COLUMN member_limit DROP DEFAULT: the entitlement feed and the L1
--      console write the value from the setting (the code PR this file ships in), so the literal 10 is gone from the
--      database too. NOT NULL and the 1..500 CHECK stay.
--
-- Behaviour on apply: none for running code once this PR is deployed (the reader serves the compiled defaults before
-- the rows exist; every INSERT names member_limit). Applied before that deploy, an L1 console "features" or "insights"
-- write that creates the agency's first entitlement row would fail NOT NULL until the deploy lands (minutes, Dev).
--
-- Class: contract (INSERTs of config rows and an ALTER of an existing table; no '-- migrate:' directive). MIG-4
-- deviation, the same as crm-068, crm-070 and crm-074: this file ships in the code PR, because the settings lint (an
-- enforced key must be read by code), the guide lint and the seed-parity test bind this block, the readers and
-- compiled_defaults.json together (either half alone is red), and the code works before the apply (compiled defaults,
-- explicit member_limit). On Dev, Infra Migration Apply once every job table is idle (root ADR 0017a). No new table
-- (no DM-7.1 row), no crm.erase_subject change, no personal data.
--
-- Rollback (a new forward migration, after the code that reads them is reverted): ALTER COLUMN member_limit SET
-- DEFAULT 10; DELETE FROM crm.setting_value / crm.setting_definition WHERE key IN (the two keys) as crm_owner.
--
-- Runs as crm_owner (the crm-064 definition guard allows only the owner; the owner of crm.tenant_entitlement), one
-- BEGIN … COMMIT block, no role DDL. Re-runnable (ON CONFLICT DO NOTHING; DROP DEFAULT is idempotent).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-064 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-075: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-064') THEN
        RAISE EXCEPTION 'crm-075: crm-064 (settings registry) lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-075' AND description NOT LIKE 'AA-1116 member limit settings:%') THEN
        RAISE EXCEPTION 'crm-075: the key crm-075 is already held by another migration (not AA-1116): renumber one';
    END IF;
END $$;

-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "crm.members.default_limit", "app": "crm", "area": "members", "label": "Member limit when CIS gives no seats", "description": "How many members (active, invited and pending invitations) an agency may have when its CIS account gives the CRM no seat number, and before the agency's first entitlement sync. Never above the member ceiling (the lower of the two applies). The seats CIS sells (crm.seats on Tenant 360) always win.", "value_type": "int", "unit": "members", "min_value": 1, "max_value": 500, "allowed_values": null, "default_value": 3, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.members.max_limit", "app": "crm", "area": "members", "label": "Member ceiling per agency", "description": "The most members one agency may have in the CRM, whatever seat number CIS sends (a larger number is cut to this ceiling). The database refuses more than 500.", "value_type": "int", "unit": "members", "min_value": 1, "max_value": 500, "allowed_values": null, "default_value": 500, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── The literal default of the column goes (every writer names the value) ─────────────────────────
ALTER TABLE crm.tenant_entitlement ALTER COLUMN member_limit DROP DEFAULT;

-- ── Post-check: the two keys are defined, the column has no default ──────────────────────────────
DO $$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM crm.setting_definition
     WHERE key IN ('crm.members.default_limit', 'crm.members.max_limit');
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'crm-075: expected the 2 member limit settings, found %', v_n;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'crm' AND table_name = 'tenant_entitlement' AND column_name = 'member_limit'
                  AND column_default IS NOT NULL) THEN
        RAISE EXCEPTION 'crm-075: crm.tenant_entitlement.member_limit still has a default';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-075', now(), 'AA-1116 member limit settings: the CRM member limit when CIS gives no seats (3) and the member ceiling (500), platform scope, area members, maker-checker; crm.tenant_entitlement.member_limit loses its default')
ON CONFLICT (version) DO NOTHING;

COMMIT;
