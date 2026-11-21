-- Migration crm-085: AA-1171 (S287, alerts catalogue P0; tech lead decision D3 of the S287 alerting decision page) —
-- the thresholds of the CRM in-app ops checks as CRM settings (tech lead S279: every threshold is admin-editable).
--
-- Owner: AA-Partner (api/migrations/085_crm_ops_check_settings.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy Migration Apply runs. Key crm-085 (owner main max crm-084 + 1); if the numbers move, renumber: file name, this
-- header, Guard 0 and the registration below, and the tests that name it (git grep '085_' and 'crm-085').
--
-- What:
--   1. Seven crm.setting_definition rows, area "ops" (settings-seed block, read by api/scripts/gen_settings_defaults.py
--      into app/platform_settings/compiled_defaults.json; guides in app/platform_settings/guides.json; readers in
--      app/observability/ops_alerts.py, app/jobs/metrics.py and app/cis/membership_feed.py, shipped in this PR),
--      today's code constants as the defaults:
--        crm.ops.jobs_stuck_after_s              int seconds, default 900 (STUCK_AFTER_S)
--        crm.ops.jobs_overdue_factor             numeric, default 2 (kinds.OVERDUE_FACTOR)
--        crm.ops.audit_export_lag_min            int minutes, default 180 (AUDIT_EXPORT_LAG_MIN)
--        crm.ops.audit_verify_lag_h              int hours, default 50 (AUDIT_VERIFY_LAG_H)
--        crm.ops.audit_partition_months_ahead    int months, default 1 (the "< 1 month ahead" rule)
--        crm.ops.membership_feed_stuck_failures  int, default 10 (membership_feed.STUCK_FAILURES)
--        crm.ops.app_spend_near_pct              pct 50-99, default 80 (the AI core's NEAR_CAP_RATIO, as CIS 469's
--                                                cis.ops.app_spend_near_pct)
--      Edited on the CIS Platform > Settings page (CRM tab, crm.ops.v1 /settings), single approval like the other
--      operational CRM values; the CIS alerts catalogue lists them next to their checks (crm.ops.v1 GET /ops-checks).
--   2. Register crm-085.
--
-- Behaviour on apply: none for running code (the readers serve the compiled defaults, the same values, until a value
-- is approved).
--
-- Class: contract (INSERT of config rows into an existing table; no '-- migrate:' directive). Shipped with its readers
-- in the code PR like crm-082 (#363) and crm-084: the readers fall back to the compiled defaults and readiness does not
-- wait for crm-085, so the code deploying before Infra Migration Apply registers the file changes nothing (root ADR
-- 0017a). No new table (no DM-7.1 row), no personal data, no crm.erase_subject change.
--
-- Rollback (a new forward migration, after the code is reverted): DELETE FROM crm.setting_value /
-- crm.setting_definition WHERE key LIKE 'crm.ops.%', as crm_owner.
--
-- Runs as crm_owner (the crm-064 definition guard allows only the owner), one BEGIN … COMMIT block, no role DDL.
-- Re-runnable (ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-084 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-085: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-084') THEN
        RAISE EXCEPTION 'crm-085: crm-084 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-085' AND description NOT LIKE 'AA-1171 ops check settings:%') THEN
        RAISE EXCEPTION 'crm-085: the key crm-085 is already held by another migration (not AA-1171): renumber one';
    END IF;
END $$;

-- ── 1. The ops check thresholds ──────────────────────────────────────────────────────────────────
-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$
[
{"key": "crm.ops.jobs_stuck_after_s", "app": "crm", "area": "ops", "label": "Job check: queue stuck after (seconds)", "description": "The ops check jobs_stuck e-mails the platform alerts topic when the oldest due crm.job row has waited longer than this while no healthy job runs (the serial worker). It replaced the CloudWatch alarm on AA/Jobs/Crm queue age (S263); 900 s was its value. Read by app/observability/ops_alerts.py (the job sampler's tick, app/jobs/metrics.py).", "value_type": "int", "unit": "seconds", "min_value": 120, "max_value": 7200, "allowed_values": null, "default_value": 900, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ops.jobs_overdue_factor", "app": "crm", "area": "ops", "label": "Job check: running job overdue after (x its expected time)", "description": "A running crm.job attempt counts as overdue once it has run this many times its kind's expected seconds (app/jobs/kinds.py); the ops check jobs_overdue e-mails on any overdue job. Read by app/jobs/metrics.py.", "value_type": "numeric", "unit": "x expected", "min_value": 1.2, "max_value": 10, "allowed_values": null, "default_value": 2, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ops.audit_export_lag_min", "app": "crm", "area": "ops", "label": "Audit check: export behind after (minutes)", "description": "The ops check audit_export_lag e-mails when the hourly agency audit export is this many minutes or more behind (design v3 4.9: no partition can be dropped while an agency is behind). Read by app/observability/ops_alerts.py (the job sampler's tick, app/jobs/metrics.py).", "value_type": "int", "unit": "minutes", "min_value": 30, "max_value": 1440, "allowed_values": null, "default_value": 180, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ops.audit_verify_lag_h", "app": "crm", "area": "ops", "label": "Audit check: export not verified after (hours)", "description": "The ops check audit_verify_lag e-mails when an agency's exported audit has not been verified for this many hours or more. Read by app/observability/ops_alerts.py (the job sampler's tick, app/jobs/metrics.py).", "value_type": "int", "unit": "hours", "min_value": 6, "max_value": 240, "allowed_values": null, "default_value": 50, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ops.audit_partition_months_ahead", "app": "crm", "area": "ops", "label": "Audit check: partitions needed ahead (months)", "description": "The ops check audit_partitions e-mails when fewer than this many future months have a crm.audit_event partition (without next month's, every audit write fails from the 1st). Read by app/observability/ops_alerts.py (the job sampler's tick, app/jobs/metrics.py).", "value_type": "int", "unit": "months", "min_value": 1, "max_value": 6, "allowed_values": null, "default_value": 1, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ops.membership_feed_stuck_failures", "app": "crm", "area": "ops", "label": "Feed check: CIS membership feed stuck after (failed pulls in a row)", "description": "The ops check membership_feed_stuck e-mails (and logs crm_membership_feed_stuck) once the pull of the CIS membership feed has failed this many times in a row: CIS removals and agency locks no longer reach the CRM. Read by app/cis/membership_feed.py.", "value_type": "int", "unit": "failures", "min_value": 3, "max_value": 100, "allowed_values": null, "default_value": 10, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ops.app_spend_near_pct", "app": "crm", "area": "ops", "label": "Spend check: AI spend near its daily cap (%)", "description": "The ops check llm_app_spend_near e-mails the platform alerts topic when the CRM's AI spend today (UTC) passes this share of its daily budget (the CRM app profile's daily budget); the cap alert at 100 % is separate. 80 % was the shared AI core's near-cap ratio. Read by app/observability/ops_alerts.py (the job sampler's tick, app/jobs/metrics.py).", "value_type": "pct", "unit": "%", "min_value": 50, "max_value": 99, "allowed_values": null, "default_value": 80, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
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
    IF (SELECT count(*) FROM crm.setting_definition WHERE key LIKE 'crm.ops.%') < 7 THEN
        RAISE EXCEPTION 'crm-085: the ops check settings are not defined';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-085', now(), 'AA-1171 ops check settings: crm.ops.* (job queue stuck, job overdue factor, audit export / verify lag, audit partitions ahead, membership feed stuck, AI spend near cap)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
