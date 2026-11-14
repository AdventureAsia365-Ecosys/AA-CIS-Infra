-- Migration crm-070: AA-965 (design v3 §6.3 card CRM-33b; tech lead S279: every threshold, limit and cap is an
-- admin-editable setting) — the eight settings of the CRM-33b AI features in the CRM settings registry (crm-064).
--
-- Owner: AA-Partner (api/migrations/070_crm_ai_crm33b_settings.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- Migration Apply runs. Key crm-070, right after crm-069 (same lane, S281 wave); if the numbers move, renumber: file
-- name, this header, Guard 0 and the registration below, and the tests that name it (git grep '077_' and 'crm-070').
--
-- What: eight crm.setting_definition rows, area ai, platform scope, maker-checker, enforced, no env override (the block
-- between "settings-seed:begin" and "settings-seed:end" is read by api/scripts/gen_settings_defaults.py into
-- app/platform_settings/compiled_defaults.json, the file the reader serves when the table has no row; the seed-parity
-- test keeps the two equal):
--   crm.ai.supplier_confirm_max_tokens (800), crm.ai.supplier_confirm_max_chars (12000),
--   crm.ai.supplier_confirm_max_lines (20), crm.ai.notes_options_max_tokens (600),
--   crm.ai.notes_options_max_chars (8000), crm.ai.notes_options_max_candidates (80),
--   crm.ai.notes_options_max_suggestions (5), crm.ai.voice_profiles_per_member_max (4, design R41 "at most 4 per
--   member"). The other defaults are the values the code PR was tested with. The CIS admin page (Platform > Settings,
--   CRM tab) edits them; the guides are app/platform_settings/guides.json.
--
-- Behaviour on apply: none for running code. The reader already serves these defaults from the compiled file; the rows
-- only make the keys editable on the CIS page.
--
-- Class: contract (INSERTs of config rows; no '-- migrate:' directive). MIG-4 deviation, the same as crm-068 (AA-1096
-- lane l5): this file ships in the code PR, not the migration-only PR of crm-069, because the settings lint (an
-- enforced key must be read by code), the guide lint and the seed-parity test bind this block, the readers and
-- compiled_defaults.json together (either half alone is red), and the code works before the apply (compiled defaults).
-- On Dev, Infra Migration Apply once every job table is idle (root ADR 0017a). No new table (no DM-7.1 row), no
-- crm.erase_subject change, no personal data.
--
-- Rollback (a new forward migration, after the code that reads them is reverted): DELETE FROM crm.setting_value /
-- crm.setting_definition WHERE key IN (the eight keys) as crm_owner.
--
-- Runs as crm_owner (the crm-064 definition guard allows only the owner), one BEGIN … COMMIT block, no role DDL.
-- Re-runnable (ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-064 and crm-069 ────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-070: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-064')
       OR NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-069') THEN
        RAISE EXCEPTION 'crm-070: crm-064 (settings registry) and crm-069 (CRM-33b tables) land first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-070' AND description NOT LIKE 'AA-965 CRM-33b settings:%') THEN
        RAISE EXCEPTION 'crm-070: the key crm-070 is already held by another migration (not AA-965): renumber one';
    END IF;
END $$;

-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "crm.ai.supplier_confirm_max_tokens", "app": "crm", "area": "ai", "label": "AI supplier confirmation output token cap", "description": "Output token cap of every route entry of the crm_supplier_confirm stage (reading one supplier's confirmation into a proposed update of the trip's agency lines); an answer cut at the cap is logged truncated and the agent records the confirmation by hand.", "value_type": "int", "unit": "tokens", "min_value": 100, "max_value": 4000, "allowed_values": null, "default_value": 800, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ai.supplier_confirm_max_chars", "app": "crm", "area": "ai", "label": "AI supplier confirmation: longest text read", "description": "The longest supplier confirmation text (a supplier e-mail on the trip's supplier request thread, or text the agent pastes) the AI reads in one run; a longer text is refused before anything is scrubbed or paid.", "value_type": "int", "unit": "characters", "min_value": 500, "max_value": 60000, "allowed_values": null, "default_value": 12000, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ai.supplier_confirm_max_lines", "app": "crm", "area": "ai", "label": "AI supplier confirmation: lines per run", "description": "The most agency lines of one supplier on one trip that one AI run may propose an update for (the closed list the model picks from); a supplier with more open lines is refused and the agent records them by hand.", "value_type": "int", "unit": "lines", "min_value": 1, "max_value": 50, "allowed_values": null, "default_value": 20, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ai.notes_options_max_tokens", "app": "crm", "area": "ai", "label": "AI notes to options output token cap", "description": "Output token cap of every route entry of the crm_notes_options stage (proposing AA options for one proposal day from the trip's notes); an answer cut at the cap is logged truncated and the agent picks options by hand.", "value_type": "int", "unit": "tokens", "min_value": 100, "max_value": 4000, "allowed_values": null, "default_value": 600, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ai.notes_options_max_chars", "app": "crm", "area": "ai", "label": "AI notes to options: longest notes read", "description": "The longest notes text (the trip's own notes, newest first, or text the agent types) one AI notes-to-options run reads; older notes beyond it are left out, a longer typed text is refused.", "value_type": "int", "unit": "characters", "min_value": 500, "max_value": 30000, "allowed_values": null, "default_value": 8000, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ai.notes_options_max_candidates", "app": "crm", "area": "ai", "label": "AI notes to options: closed list size", "description": "The most AA components (the agency's live AA tours and their parts in the trip's countries) offered to the model as the day's closed list; the model may pick only from this list and any other code is rejected.", "value_type": "int", "unit": "components", "min_value": 5, "max_value": 300, "allowed_values": null, "default_value": 80, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ai.notes_options_max_suggestions", "app": "crm", "area": "ai", "label": "AI notes to options: suggestions per run", "description": "The most AA options one notes-to-options run proposes for a day; extra picks of the model are dropped.", "value_type": "int", "unit": "options", "min_value": 1, "max_value": 20, "allowed_values": null, "default_value": 5, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ai.voice_profiles_per_member_max", "app": "crm", "area": "ai", "label": "Voice profiles per member", "description": "The most writing voices one agency member may keep for the AI reply draft (Settings > AI > Voices); a new one above it is refused until the member deletes one.", "value_type": "int", "unit": "voices", "min_value": 1, "max_value": 20, "allowed_values": null, "default_value": 4, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── Post-check: the eight keys are defined ───────────────────────────────────────────────────────
DO $$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM crm.setting_definition
     WHERE key IN ('crm.ai.supplier_confirm_max_tokens', 'crm.ai.supplier_confirm_max_chars',
                   'crm.ai.supplier_confirm_max_lines', 'crm.ai.notes_options_max_tokens',
                   'crm.ai.notes_options_max_chars', 'crm.ai.notes_options_max_candidates',
                   'crm.ai.notes_options_max_suggestions', 'crm.ai.voice_profiles_per_member_max');
    IF v_n <> 8 THEN
        RAISE EXCEPTION 'crm-070: expected the 8 CRM-33b settings, found %', v_n;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-070', now(), 'AA-965 CRM-33b settings: the eight admin-editable limits of the AI supplier confirmations, notes to options and voice profiles (area ai, platform scope, maker-checker)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
