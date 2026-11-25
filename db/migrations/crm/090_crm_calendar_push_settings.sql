-- Migration crm-090: AA-1011 part 3 (tech lead S279: every limit is a setting) — the limits of the one-way calendar
-- push (crm_calendar_push, app/calendar/push.py) as CRM settings the tech lead edits on the CIS Platform > Settings
-- page (CRM tab).
--
-- Owner: AA-Partner (api/migrations/090_crm_calendar_push_settings.sql). AA-CIS-Infra db/migrations/crm/ holds the
-- byte copy Migration Apply runs. Key crm-090 (crm-089, the calendar connection table, is the migration-only PR of
-- this change, applied first); if the numbers move, renumber: file name, this header, Guard 0 and the registration
-- below, and the tests that name it (git grep '090_' and 'crm-090').
--
-- What:
--   1. Four crm.setting_definition rows, area "calendar" (settings-seed block, read by
--      api/scripts/gen_settings_defaults.py into app/platform_settings/compiled_defaults.json; guides in
--      app/platform_settings/guides.json; readers shipped in this PR, app/calendar/push.py):
--        crm.calendar_push.window_days   int days, default 120 (7-365): how far ahead departures and tasks are pushed;
--        crm.calendar_push.past_days     int days, default 7 (0-30): how far back the push still keeps the calendar
--                                        in step (an older event is left as it is);
--        crm.calendar_push.batch_size    int, default 200 (10-1000): calendar writes (create, update, delete) per
--                                        connection per run; the rest waits for the next run;
--        crm.calendar_push.max_attempts  int, default 3 (1-10): tries of a connect or disconnect run when the
--                                        calendar provider is down (the last try of a disconnect deletes the token
--                                        anyway).
--   2. Register crm-090.
--
-- Behaviour on apply: none for running code (the readers serve the compiled defaults, the same values, until a value
-- is approved).
--
-- Class: contract (INSERT of config rows into an existing table; no '-- migrate:' directive). Shipped with its readers
-- in the code PR like crm-087 and crm-088: the readers fall back to the compiled defaults and readiness does not wait
-- for crm-090 (root ADR 0017a). No new table (no DM-7.1 row), no personal data, no crm.erase_subject change.
--
-- Rollback (a new forward migration, after the code is reverted): DELETE FROM crm.setting_value /
-- crm.setting_definition WHERE key LIKE 'crm.calendar_push.%', as crm_owner.
--
-- Runs as crm_owner (the crm-064 definition guard allows only the owner), one BEGIN … COMMIT block, no role DDL.
-- Re-runnable (ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-089 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-090: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-089') THEN
        RAISE EXCEPTION 'crm-090: crm-089 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-090' AND description NOT LIKE 'AA-1011 calendar push settings:%') THEN
        RAISE EXCEPTION 'crm-090: the key crm-090 is already held by another migration (not AA-1011): renumber one';
    END IF;
END $$;

-- ── 1. The calendar push settings ────────────────────────────────────────────────────────────────
-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$
[
{"key": "crm.calendar_push.window_days", "app": "crm", "area": "calendar", "label": "Calendar push: days ahead pushed", "description": "How many days after today a member's departures and tasks are written into their own connected Google or Microsoft 365 calendar (crm_calendar_push). Events further ahead are pushed as the days pass. Read by app/calendar/push.py.", "value_type": "int", "unit": "days", "min_value": 7, "max_value": 365, "allowed_values": null, "default_value": 120, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.calendar_push.past_days", "app": "crm", "area": "calendar", "label": "Calendar push: days back kept in step", "description": "How many days before today the calendar push still updates or removes the CRM events of a connected calendar (a task done late, a trip cancelled after its departure). Older events are left as they are. Read by app/calendar/push.py.", "value_type": "int", "unit": "days", "min_value": 0, "max_value": 30, "allowed_values": null, "default_value": 7, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.calendar_push.batch_size", "app": "crm", "area": "calendar", "label": "Calendar push: writes per calendar per run", "description": "At most this many calendar writes (create, update, delete) for one connected calendar in one run of the calendar push; the rest waits for the next run (hourly, or at once after a connect or disconnect). Keeps one run inside the providers' rate limits. Read by app/calendar/push.py.", "value_type": "int", "unit": "writes", "min_value": 10, "max_value": 1000, "allowed_values": null, "default_value": 200, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.calendar_push.max_attempts", "app": "crm", "area": "calendar", "label": "Calendar push: tries of a connect or disconnect run", "description": "How many times the run queued by a calendar connect or disconnect is tried while the calendar provider is down (with the job queue's backoff). The last try of a disconnect deletes the stored token whatever happens, so a disconnect never keeps a token. Read by app/calendar/push.py.", "value_type": "int", "unit": "attempts", "min_value": 1, "max_value": 10, "allowed_values": null, "default_value": 3, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── Post-check ────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT count(*) FROM crm.setting_definition WHERE key LIKE 'crm.calendar_push.%') < 4 THEN
        RAISE EXCEPTION 'crm-090: the calendar push settings are not defined';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-090', now(), 'AA-1011 calendar push settings: crm.calendar_push.* (window days, past days, writes per run, tries of a connect / disconnect run)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
