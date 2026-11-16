-- Migration crm-071: AA-963 (design v3 §6.3 card CRM-32, R35 global search; tech lead S279: every threshold, limit
-- and cap is an admin-editable setting) — the four settings of the global search in the CRM settings registry
-- (crm-064).
--
-- Owner: AA-Partner (api/migrations/071_crm_search_settings.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- Migration Apply runs. Key crm-071, the next free number on main after crm-070; if the numbers move, renumber: file
-- name, this header, Guard 0 and the registration below, and the tests that name it (git grep '071_' and 'crm-071').
--
-- What: four crm.setting_definition rows, area search, enforced, no env override (the block between
-- "settings-seed:begin" and "settings-seed:end" is read by api/scripts/gen_settings_defaults.py into
-- app/platform_settings/compiled_defaults.json, the file the reader serves when the table has no row; the seed-parity
-- test keeps the two equal):
--   crm.search.enabled (off; platform+tenant: an administrator switches one agency on after the independent review
--   the card asks for, never the pilot before it), crm.search.results_per_kind (5), crm.search.query_max_chars (120,
--   the client directory's own bound), crm.search.min_text_chars (2). The CIS admin page (Platform > Settings, CRM
--   tab) edits them; the guides are app/platform_settings/guides.json.
--
-- Behaviour on apply: none for running code. The reader already serves these defaults from the compiled file (search
-- off everywhere); the rows only make the keys editable on the CIS page.
--
-- Class: contract (INSERTs of config rows; no '-- migrate:' directive). MIG-4 deviation, the same as crm-068 and
-- crm-070: this file ships in the code PR, because the settings lint (an enforced key must be read by code), the
-- guide lint and the seed-parity test bind this block, the readers and compiled_defaults.json together (either half
-- alone is red), and the code works before the apply (compiled defaults: search off). On Dev, Infra Migration Apply
-- once every job table is idle (root ADR 0017a). No new table (no DM-7.1 row), no crm.erase_subject change, no
-- personal data.
--
-- Rollback (a new forward migration, after the code that reads them is reverted): DELETE FROM crm.setting_value /
-- crm.setting_definition WHERE key IN (the four keys) as crm_owner.
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
        RAISE EXCEPTION 'crm-071: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-064') THEN
        RAISE EXCEPTION 'crm-071: crm-064 (settings registry) lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-071' AND description NOT LIKE 'AA-963 global search settings:%') THEN
        RAISE EXCEPTION 'crm-071: the key crm-071 is already held by another migration (not AA-963): renumber one';
    END IF;
END $$;

-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "crm.search.enabled", "app": "crm", "area": "search", "label": "Global search in the agency app", "description": "On: the agency app shows the search box (Ctrl K) over the agency's clients (exact e-mail, phone or whole name through the blind indexes only), trips, bookings, suppliers, services and its libraries. Off by default; switch it on for one agency at a time, and only after the independent review of the search.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": false, "scope_kind": "platform+tenant", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.search.results_per_kind", "app": "crm", "area": "search", "label": "Search results per kind", "description": "The most results one search shows per kind of record (clients, trips, bookings, suppliers and so on); each kind runs one bounded query, so this also bounds the work of one search.", "value_type": "int", "unit": "results", "min_value": 1, "max_value": 20, "allowed_values": null, "default_value": 5, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.search.query_max_chars", "app": "crm", "area": "search", "label": "Longest search term", "description": "The longest search term the agency app accepts; a longer term is refused before anything is read.", "value_type": "int", "unit": "characters", "min_value": 20, "max_value": 200, "allowed_values": null, "default_value": 120, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.search.min_text_chars", "app": "crm", "area": "search", "label": "Shortest text search", "description": "The fewest characters a text search needs before it runs (an e-mail or an international phone number is always searched whole); a shorter term returns nothing.", "value_type": "int", "unit": "characters", "min_value": 1, "max_value": 10, "allowed_values": null, "default_value": 2, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── Post-check: the four keys are defined ────────────────────────────────────────────────────────
DO $$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM crm.setting_definition
     WHERE key IN ('crm.search.enabled', 'crm.search.results_per_kind', 'crm.search.query_max_chars',
                   'crm.search.min_text_chars');
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'crm-071: expected the 4 global search settings, found %', v_n;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-071', now(), 'AA-963 global search settings: the per-agency switch (off) and the three bounds of the global search (area search, maker-checker)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
