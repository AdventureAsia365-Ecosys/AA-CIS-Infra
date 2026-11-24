-- Migration crm-088: AA-838 (S291 lane f-crm-perf; C4.3 W48 database review, findings 4 and 5; tech lead S279 "a
-- threshold is a setting") — the two cadences behind the CRM job worker's database load, as CRM settings the tech
-- lead edits on the CIS Platform > Settings page (CRM tab). The job contexts' agency status reuse (app/tenant_status.py)
-- has no setting: it lasts one Booking sync run of one agency, no time window.
--
-- Owner: AA-Partner (api/migrations/088_crm_job_load_settings.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- Migration Apply runs. Key crm-088 (owner main max crm-087 + 1); if the numbers move, renumber: file name, this
-- header, Guard 0 and the registration below, and the tests that name it (git grep '088_' and 'crm-088').
--
-- What:
--   1. Two crm.setting_definition rows, area "jobs" (settings-seed block, read by api/scripts/gen_settings_defaults.py
--      into app/platform_settings/compiled_defaults.json; guides in app/platform_settings/guides.json; readers shipped
--      in this PR):
--        crm.jobs.booking_proposal_check_every_s  int seconds, default 300 (60-3600): the minute Booking sync re-checks
--                                                 an agency's accepted proposals (two reads) only this often when
--                                                 nothing nudged it and its last check left no work
--                                                 (app/booking/proposal_checks.py; it was every run, about one read a
--                                                 second);
--        crm.jobs.history_prune_every_s           int seconds, default 60 (60-3600): the recurring kinds' history DELETE
--                                                 at most once per this many seconds per process (app/jobs/worker.py,
--                                                 wired in app/main.py; it ran on every maintenance pass, about every
--                                                 7 s). The retention rules (each kind's keep_days) are unchanged.
--   2. Register crm-088.
--
-- Behaviour on apply: none for running code (the readers serve the compiled defaults, the same values, until a value
-- is approved).
--
-- Class: contract (INSERT of config rows into an existing table; no '-- migrate:' directive). Shipped with its readers
-- in the code PR like crm-085 and crm-087: the readers fall back to the compiled defaults and readiness does not wait
-- for crm-088, so the code deploying before Infra Migration Apply registers the file changes nothing (root ADR 0017a).
-- No new table (no DM-7.1 row), no personal data, no crm.erase_subject change.
--
-- Rollback (a new forward migration, after the code is reverted): DELETE FROM crm.setting_value /
-- crm.setting_definition WHERE key LIKE 'crm.jobs.%', as crm_owner.
--
-- Runs as crm_owner (the crm-064 definition guard allows only the owner), one BEGIN … COMMIT block, no role DDL.
-- Re-runnable (ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-087 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-088: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-087') THEN
        RAISE EXCEPTION 'crm-088: crm-087 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-088' AND description NOT LIKE 'AA-838 job load settings:%') THEN
        RAISE EXCEPTION 'crm-088: the key crm-088 is already held by another migration (not AA-838): renumber one';
    END IF;
END $$;

-- ── 1. The job load settings ─────────────────────────────────────────────────────────────────────
-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$
[
{"key": "crm.jobs.booking_proposal_check_every_s", "app": "crm", "area": "jobs", "label": "Booking sync: accepted proposals re-checked every (seconds)", "description": "The minute run of the Booking sync (crm_booking_sync) re-checks an agency's accepted proposals (their AA lines and the confirm of a paid deposit) only this often when nothing nudged it and its last check left no work; an accept, a paid deposit, a claim or a re-hold nudges the agency's sync at once, and an agency with work due or a retry is checked every run. It was every run (about one read a second on Dev, C4.3 W48). Read by app/booking/proposal_checks.py.", "value_type": "int", "unit": "seconds", "min_value": 60, "max_value": 3600, "allowed_values": null, "default_value": 300, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.jobs.history_prune_every_s", "app": "crm", "area": "jobs", "label": "Job queue: recurring job history pruned every (seconds)", "description": "The job worker deletes the finished runs of its recurring kinds (heartbeat, CIS membership feed, Booking sync) older than each kind's own keep days at most once per this many seconds per worker; it was on every maintenance pass (about every 7 s, C4.3 W48). The keep days themselves are unchanged. Read by app/jobs/worker.py (wired in app/main.py).", "value_type": "int", "unit": "seconds", "min_value": 60, "max_value": 3600, "allowed_values": null, "default_value": 60, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
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
    IF (SELECT count(*) FROM crm.setting_definition WHERE key LIKE 'crm.jobs.%') < 2 THEN
        RAISE EXCEPTION 'crm-088: the job load settings are not defined';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-088', now(), 'AA-838 job load settings: crm.jobs.* (Booking sync proposal re-check interval, recurring job history prune interval)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
