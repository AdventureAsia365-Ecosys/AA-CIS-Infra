-- Migration crm-072: AA-970 (design v3 §6.3 card CRM-37b, R42 "What's new + preview switch"; tech lead S279: every
-- switch and threshold is an admin-editable setting) — the per-agency preview switch in the CRM settings registry
-- (crm-064).
--
-- Owner: AA-Partner (api/migrations/072_crm_release_preview_setting.sql). AA-CIS-Infra db/migrations/crm/ holds the
-- byte copy Migration Apply runs. Key crm-072 = crm main max + 1 (main holds crm-071); the campaigns lane of the same
-- wave holds crm-073 and crm-074 right after it, so the wave's crm keys stay consecutive. If main moves first (the
-- migration preflight accepts only main max + 1), renumber to the next free key: file name, this header, Guard 0 and
-- the registration below, compiled_defaults.json (scripts/gen_settings_defaults.py), the CONTEXT.md migration row and
-- the comments that name it (git grep '072_' and 'crm-072').
--
-- What: one crm.setting_definition row, area release, enforced, no env override (the block between
-- "settings-seed:begin" and "settings-seed:end" is read by api/scripts/gen_settings_defaults.py into
-- app/platform_settings/compiled_defaults.json; the seed-parity test keeps the two equal):
--   crm.release.preview (off; platform+tenant): an agency whose own value is on is "on preview" and sees the agency
--   app's preview features (web/lib/preview.ts) and the preview entries of Help > What's new; every other agency does
--   not. The design's release_channel column (design v3 §1 R42) is this setting: one switch per agency, edited on the
--   CIS admin page Platform > Settings (CRM tab, the agency's own value), audited and versioned by crm-064. It never
--   gates privacy or price logic: api/scripts/preview_flag_lint.py fails CI when it does.
--
-- Behaviour on apply: none for running code. The reader already serves the default from the compiled file (preview
-- off everywhere); the row only makes the key editable on the CIS page.
--
-- Class: contract (an INSERT of a config row; no '-- migrate:' directive). MIG-4 deviation, the same as crm-068,
-- crm-070 and crm-071: this file ships in the code PR, because the settings lint (an enforced key must be read by
-- code), the guide lint and the seed-parity test bind this block, the reader and compiled_defaults.json together
-- (either half alone is red), and the code works before the apply (compiled default: preview off). On Dev, Infra
-- Migration Apply once every job table is idle (root ADR 0017a). No new table (no DM-7.1 row), no crm.erase_subject
-- change, no personal data.
--
-- Rollback (a new forward migration, after the code that reads it is reverted): DELETE FROM crm.setting_value /
-- crm.setting_definition WHERE key IN ('crm.release.preview') as crm_owner.
--
-- Runs as crm_owner (the crm-064 definition guard allows only the owner), one BEGIN … COMMIT block, no role DDL.
-- Re-runnable (ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-064 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-072: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-064') THEN
        RAISE EXCEPTION 'crm-072: crm-064 (settings registry) lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-072' AND description NOT LIKE 'AA-970 release preview setting:%') THEN
        RAISE EXCEPTION 'crm-072: the key crm-072 is already held by another migration (not AA-970): renumber one';
    END IF;
END $$;

-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "crm.release.preview", "app": "crm", "area": "release", "label": "Preview features for this agency", "description": "On: the agency app shows this agency the features still in preview and the preview entries of Help > What's new. Off by default; switch it on for one agency at a time, for an agency that agreed to try features early. A preview never changes privacy or price rules: those ship to every agency at once.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": false, "scope_kind": "platform+tenant", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── Post-check: the key is defined ───────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM crm.setting_definition WHERE key IN ('crm.release.preview')) THEN
        RAISE EXCEPTION 'crm-072: the release preview setting is missing';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-072', now(), 'AA-970 release preview setting: the per-agency preview switch (off; area release, maker-checker)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
