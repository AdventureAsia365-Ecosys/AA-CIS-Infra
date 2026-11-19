-- Migration 461: AA-1127 (S285, UI audit batch C2 "spend truth"; tech lead decision S285 evening E2: a daily Cost
-- Explorer check, about 0.02 USD a run, on/off and frequency as settings) — the three settings of the daily Cost
-- Explorer refresh in the platform settings registry (CIS 407; tech lead S279: a threshold, limit or policy value is a
-- setting on Platform › Settings, never a code literal or an env var alone).
--
-- Why. shared.cost_explorer_snapshot / shared.cost_explorer_app_snapshot (CIS 248) are only refreshed when someone
-- opens Spend › By app (the lazy refresh of api/services/platform_cost.py) or presses "Refresh from AWS", so the
-- forecast's AWS rows and the nightly LLM cost reconciliation can read days-old figures without saying so (S283 UI
-- audit, C2). The code PR adds job kind cost_explorer_refresh (services/jobs/cost_explorer_refresh_job.py), queued by
-- the api's ops metrics sampler once per UTC day from the hour below, and a "stale" badge on the Spend page when the
-- newest stored fetch is older than the stale window below.
--
-- What:
--   1. Three rows in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), area "spend", scope platform, single approval, no evidence,
--      no env override, enforced (api/services/cost_explorer_daily.py names the keys in the code PR, the settings-lint
--      reader check):
--        cis.spend.ce_daily_refresh_enabled     bool, default true (the tech lead's yes for Dev, S285 E2)
--        cis.spend.ce_daily_refresh_hour_utc    int hour (UTC) 0-23, default 1 (before the 02:00 UTC LLM cost
--                                               reconciliation, which reads the stored Cost Explorer snapshot)
--        cis.spend.ce_stale_after_hours         int hours 1-720, default 36 (one daily run plus a missed tick's slack)
--      Each seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 461.
--
-- Behaviour on apply. None for running code: no value row is seeded and nothing on main reads the keys; after the code
-- PR the sampler reads the defaults (on, 01:00 UTC, 36 h) until an administrator changes them.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): config rows INSERTed into an existing table.
-- MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a), then
-- the code PR (no readiness raise: the readers fall back to the compiled defaults). DM-6.1: no personal data. DM-7.1:
-- no new table.
--
-- Number. Owner main max (460) + 1. If the owner main max + 1 differs at merge, renumber (git grep '461_' and '461'
-- here, in tests/integration/test_aa1127_migration_461.py, compiled_defaults.json and
-- docs/implementation-notes/AA-1127-l28.md).
--
-- Locks. One INSERT of three rows (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
--
-- Rollback (a new forward migration, after the code PR is reverted): DELETE the keys' value rows first, then the keys.

BEGIN;
SET LOCAL lock_timeout = '5s';

-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$
[
{"key": "cis.spend.ce_daily_refresh_enabled", "app": "cis", "area": "spend", "label": "Daily Cost Explorer check: on", "description": "On: once per UTC day, from the hour of cis.spend.ce_daily_refresh_hour_utc, the api's ops metrics sampler queues one cost_explorer_refresh job (services/jobs/cost_explorer_refresh_job.py). It reads AWS Cost Explorer for the main and the LLM account, grouped by service and, for the main account, by App tag, for the current month and the last few days, and stores the figures the Spend page, the forecast and the nightly LLM cost reconciliation read. About 0.01 USD per Cost Explorer request, about 3 requests a run. Off: nothing is queued; the figures are only fetched when Spend > By app finds them old, or with Refresh from AWS.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": true, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "Whether the platform reads the real AWS bill from Cost Explorer once a day by itself.", "raise": "On: the Spend page, the forecast and the cost reconciliation see AWS figures at most about a day old; each run costs about 0.03 USD (about 1 USD a month).", "lower": "Off: no daily charge; the AWS figures grow old until someone opens Spend > By app or presses Refresh from AWS, and the Spend page shows them as stale.", "when": "Leave it on while the AWS bill is watched; turn it off only when the account is idle and nobody reads the Spend page.", "example": "With the default on and the hour at 1, the check runs a little after 01:00 UTC (08:00 in Vietnam) every day."}, "vi": {"what": "Nền tảng có tự đọc hoá đơn AWS thật từ Cost Explorer mỗi ngày một lần hay không.", "raise": "Bật: trang Spend, dự báo và đối soát chi phí thấy số AWS cũ nhất khoảng một ngày; mỗi lượt tốn khoảng 0.03 USD (khoảng 1 USD mỗi tháng).", "lower": "Tắt: không tốn tiền mỗi ngày; số AWS cũ dần cho tới khi có người mở Spend > By app hoặc bấm Refresh from AWS, và trang Spend đánh dấu là cũ.", "when": "Để bật khi còn theo dõi hoá đơn AWS; chỉ tắt khi tài khoản không chạy gì và không ai đọc trang Spend.", "example": "Với mặc định bật và giờ chạy là 1, lượt kiểm chạy ngay sau 01:00 UTC (08:00 giờ Việt Nam) mỗi ngày."}}},
{"key": "cis.spend.ce_daily_refresh_hour_utc", "app": "cis", "area": "spend", "label": "Daily Cost Explorer check: hour (UTC)", "description": "The UTC hour from which the api's ops metrics sampler queues the day's cost_explorer_refresh job (one per UTC day, idempotency key cost_explorer_refresh:<day>), while cis.spend.ce_daily_refresh_enabled is on. A run before 02:00 UTC gives the nightly LLM cost reconciliation (llm_cost_reconcile) fresh Bedrock figures. A change applies from the next UTC day when today's run already exists.", "value_type": "int", "unit": "hour (UTC)", "min_value": 0, "max_value": 23, "allowed_values": null, "default_value": 1, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The hour (UTC) of the day from which the daily Cost Explorer check runs.", "raise": "The check runs later in the day; AWS has finished more of the previous day's figures, but the nightly cost reconciliation reads older ones.", "lower": "The check runs earlier; the nightly cost reconciliation at 02:00 UTC reads the new figures.", "when": "Move it when another night job needs the figures at a different time.", "example": "With the default 1, the check runs a little after 01:00 UTC (08:00 in Vietnam), before the 02:00 UTC cost reconciliation."}, "vi": {"what": "Giờ (UTC) trong ngày mà lượt kiểm Cost Explorer hằng ngày bắt đầu chạy.", "raise": "Lượt kiểm chạy muộn hơn trong ngày; AWS đã chốt thêm số của ngày hôm trước, nhưng đối soát chi phí ban đêm đọc số cũ hơn.", "lower": "Lượt kiểm chạy sớm hơn; đối soát chi phí lúc 02:00 UTC đọc được số mới.", "when": "Dời giờ khi một job ban đêm khác cần số vào giờ khác.", "example": "Với mặc định 1, lượt kiểm chạy ngay sau 01:00 UTC (08:00 giờ Việt Nam), trước đối soát chi phí lúc 02:00 UTC."}}},
{"key": "cis.spend.ce_stale_after_hours", "app": "cis", "area": "spend", "label": "Cost Explorer figures: hours before they show as stale", "description": "AI & spend > Spend (the forecast and the By app tab) marks the stored Cost Explorer figures stale when the newest fetch of either snapshot (shared.cost_explorer_snapshot, shared.cost_explorer_app_snapshot) is older than this many hours, or when nothing is stored (api/services/cost_explorer_daily.py freshness). Display only: it never triggers a Cost Explorer call.", "value_type": "int", "unit": "hours", "min_value": 1, "max_value": 720, "allowed_values": null, "default_value": 36, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How old the stored AWS bill figures may get before the Spend page marks them stale.", "raise": "The stale mark appears later; a check that stopped running goes unnoticed for longer.", "lower": "The stale mark appears sooner, also after a short delay of the daily check.", "when": "Keep it a little above a day while the daily check is on; raise it when the check is off on purpose.", "example": "With the default 36 hours, figures last fetched yesterday morning are fine, figures from two days ago show Stale."}, "vi": {"what": "Số hoá đơn AWS đã lưu được cũ tối đa bao lâu trước khi trang Spend đánh dấu là cũ.", "raise": "Dấu cũ hiện muộn hơn; lượt kiểm ngừng chạy lâu hơn mới bị phát hiện.", "lower": "Dấu cũ hiện sớm hơn, kể cả khi lượt kiểm hằng ngày chỉ trễ một chút.", "when": "Giữ ở mức hơn một ngày một chút khi lượt kiểm hằng ngày đang bật; tăng lên khi cố ý tắt lượt kiểm.", "example": "Với mặc định 36 giờ, số lấy sáng hôm qua vẫn ổn, số lấy từ hai ngày trước hiện Stale."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('461', now(), 'AA-1127: the daily Cost Explorer check settings (cis.spend.ce_*) in the settings registry')
ON CONFLICT (version) DO NOTHING;

COMMIT;
