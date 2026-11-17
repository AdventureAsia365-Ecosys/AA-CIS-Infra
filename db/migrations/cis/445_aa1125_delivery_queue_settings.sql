-- Migration 445: AA-1125 (S283) — the colour thresholds of the Merge queue tab of Platform › Delivery in the platform
-- settings registry (CIS 407; tech lead S279: a threshold, limit, cap or policy value is a setting on Platform ›
-- Settings, never a code literal or an env var alone). Same area and pattern as CIS 433 (AA-1108).
--
-- Why. The root workflow "Delivery metrics" (AA-Ecosys .github/workflows/delivery-metrics.yml) now also publishes, per
-- app with a GitHub merge queue (AA-CIS-App, AA-Booking, AA-Partner), one `queue` section in
-- docs-reader/delivery/summary.json: each stay of a pull request in the queue, its wait, outcome (merged / ejected /
-- removed), ejection reason, merge_group CI minutes and flaky signals, each number with its sample size n. The CIS API
-- (api/services/delivery_metrics.py) colours three of them green / amber / red with these settings; the Merge queue tab
-- shows the colours. Below cis.delivery.min_sample (CIS 433) a number stays grey.
--
-- What:
--   1. Six rows in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py
--      into shared/settings/compiled_defaults.json in this PR), area "delivery", scope platform, impact low, single
--      approval, no evidence, no env override, enforced (services/reports/delivery_settings.py names every key in this
--      PR, the settings-lint reader check; the code PR reads them through shared.settings):
--        cis.delivery.queue_wait_green_hours     numeric hours 0.1-168, default 1  (p95 wait green at or below)
--        cis.delivery.queue_wait_amber_hours     numeric hours 0.1-336, default 4  (amber at or below; above: red)
--        cis.delivery.queue_ejection_green_pct   pct 0-100, default 10
--        cis.delivery.queue_ejection_amber_pct   pct 0-100, default 25
--        cis.delivery.queue_flaky_green_pct      pct 0-100, default 5
--        cis.delivery.queue_flaky_amber_pct      pct 0-100, default 15
--      Starting values: the merge_group checks take about 10 to 20 minutes on these repos, so a p95 wait of an hour
--      leaves room for one rebuild behind an ejected entry; ejection and flaky rates are starting values for the tech
--      lead to tune. Each seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 445.
--
-- Behaviour on apply. None for running code: no value row is seeded and nothing on main reads these keys; after the code
-- PR the Merge queue tab reads the defaults until an administrator changes a value.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): config rows INSERTed into an existing table.
-- MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a), then the
-- code PR (no readiness raise: a reader falls back to the compiled defaults). DM-6.1: no personal data. DM-7.1: no new
-- table.
--
-- Number. 444 is the newest CIS migration on main (17/11/2026). If the owner main max + 1 differs at merge, renumber
-- (git grep '445_' and '445' here, in tests/integration/test_aa1125_migration_445.py, compiled_defaults.json and
-- docs/implementation-notes/AA-1125.md).
--
-- Locks. One INSERT of six rows (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
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
{"key": "cis.delivery.queue_wait_green_hours", "app": "cis", "area": "delivery", "label": "Delivery: merge queue wait p95 for green (hours)", "description": "Platform › Delivery, tab Merge queue (api/services/delivery_metrics.py) colours the merge-queue wait of an app (p95 hours from a pull request entering the GitHub merge queue to its merge, over the entries merged in the last 4 weeks) green at or below this value. Starting value 1 h.", "value_type": "numeric", "unit": "hours", "min_value": 0.1, "max_value": 168, "allowed_values": null, "default_value": 1, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The p95 time a pull request waits in the merge queue before it merges, at or under which the queue of an app shows green.", "raise": "Longer queue waits still show green.", "lower": "Only a fast queue shows green; a slow merge_group check stands out.", "when": "Lower it once the merge_group checks are fast and cached; raise it while the queue runs a long suite on purpose.", "example": "With the default of 1 hour, a queue whose p95 wait is 40 minutes is green."}, "vi": {"what": "Thời gian chờ p95 của một pull request trong hàng merge trước khi được merge, mà bằng hoặc dưới mức đó hàng merge của app hiện xanh.", "raise": "Hàng merge chờ lâu hơn vẫn hiện xanh.", "lower": "Chỉ hàng merge nhanh mới hiện xanh; check merge_group chậm nổi bật.", "when": "Giảm khi check merge_group đã nhanh và có cache; tăng khi hàng merge cố ý chạy bộ kiểm tra dài.", "example": "Với mặc định 1 giờ, hàng merge có thời gian chờ p95 40 phút là xanh."}}},
{"key": "cis.delivery.queue_wait_amber_hours", "app": "cis", "area": "delivery", "label": "Delivery: merge queue wait p95 for amber (hours)", "description": "Platform › Delivery, tab Merge queue (api/services/delivery_metrics.py) colours the merge-queue wait p95 amber at or below this value and above the green value; above it red. Starting value 4 h.", "value_type": "numeric", "unit": "hours", "min_value": 0.1, "max_value": 336, "allowed_values": null, "default_value": 4, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The p95 queue wait above which an app's merge queue turns red; between the green value and this it is amber.", "raise": "A slow queue stays amber longer.", "lower": "A slow queue turns red sooner.", "when": "Keep it above the green value.", "example": "With the default of 4 hours, a p95 wait of 2 hours is amber and 6 hours is red."}, "vi": {"what": "Thời gian chờ p95 trong hàng merge mà trên mức đó hàng merge của app chuyển đỏ; giữa mức xanh và mức này là vàng.", "raise": "Hàng merge chậm giữ màu vàng lâu hơn.", "lower": "Hàng merge chậm chuyển đỏ sớm hơn.", "when": "Giữ cao hơn mức xanh.", "example": "Với mặc định 4 giờ, chờ p95 2 giờ là vàng và 6 giờ là đỏ."}}},
{"key": "cis.delivery.queue_ejection_green_pct", "app": "cis", "area": "delivery", "label": "Delivery: merge queue ejection rate for green (%)", "description": "Platform › Delivery, tab Merge queue (api/services/delivery_metrics.py) colours the ejection rate of an app (queue entries the merge queue removed without a merge, over the entries that merged or were ejected in the last 4 weeks) green at or below this percent. Starting value 10 %.", "value_type": "pct", "unit": "%", "min_value": 0, "max_value": 100, "allowed_values": null, "default_value": 10, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The share of merge-queue entries the queue throws out (red or timed-out checks) at or under which an app shows green.", "raise": "More ejections are tolerated before the colour changes.", "lower": "A few ejections are enough to show amber.", "when": "Lower it once ejections are rare; raise it while a known flaky check is being fixed.", "example": "With the default of 10 %, 1 ejection out of 20 entries (5 %) is green."}, "vi": {"what": "Tỉ lệ lượt vào hàng merge bị hàng loại ra (check đỏ hoặc quá giờ) mà bằng hoặc dưới mức đó app hiện xanh.", "raise": "Chấp nhận nhiều lần bị loại hơn trước khi đổi màu.", "lower": "Vài lần bị loại là đủ hiện vàng.", "when": "Giảm khi việc bị loại đã hiếm; tăng trong lúc đang sửa một check chập chờn đã biết.", "example": "Với mặc định 10 %, 1 lần bị loại trên 20 lượt (5 %) là xanh."}}},
{"key": "cis.delivery.queue_ejection_amber_pct", "app": "cis", "area": "delivery", "label": "Delivery: merge queue ejection rate for amber (%)", "description": "Platform › Delivery, tab Merge queue (api/services/delivery_metrics.py) colours the ejection rate amber at or below this percent and above the green value; above it red. Starting value 25 %.", "value_type": "pct", "unit": "%", "min_value": 0, "max_value": 100, "allowed_values": null, "default_value": 25, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The ejection rate above which an app's merge queue turns red; between the green value and this it is amber.", "raise": "Many ejections stay amber longer.", "lower": "Many ejections turn red sooner.", "when": "Keep it above the green value.", "example": "With the default of 25 %, 3 ejections out of 20 entries is amber and 6 out of 20 is red."}, "vi": {"what": "Tỉ lệ bị loại mà trên mức đó hàng merge của app chuyển đỏ; giữa mức xanh và mức này là vàng.", "raise": "Bị loại nhiều giữ màu vàng lâu hơn.", "lower": "Bị loại nhiều chuyển đỏ sớm hơn.", "when": "Giữ cao hơn mức xanh.", "example": "Với mặc định 25 %, 3 lần bị loại trên 20 lượt là vàng và 6 trên 20 là đỏ."}}},
{"key": "cis.delivery.queue_flaky_green_pct", "app": "cis", "area": "delivery", "label": "Delivery: merge queue flaky rate for green (%)", "description": "Platform › Delivery, tab Merge queue (api/services/delivery_metrics.py) colours the flaky rate of an app (queue entries with a flaky signal: a merge_group re-run that turned green, or an ejection on red checks followed by a merge with no new commit, over the entries that merged or were ejected in the last 4 weeks) green at or below this percent. Starting value 5 %.", "value_type": "pct", "unit": "%", "min_value": 0, "max_value": 100, "allowed_values": null, "default_value": 5, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The share of merge-queue entries that show a flaky signal (a re-run turned green, or an ejection then a merge with no new commit) at or under which an app shows green.", "raise": "More flaky checks are tolerated before the colour changes.", "lower": "A single flaky check is enough to show amber.", "when": "Lower it once the checks are stable; raise it while a known flaky test is quarantined.", "example": "With the default of 5 %, 1 flaky entry out of 25 (4 %) is green."}, "vi": {"what": "Tỉ lệ lượt vào hàng merge có dấu hiệu chập chờn (chạy lại thì xanh, hoặc bị loại rồi merge mà không có commit mới) mà bằng hoặc dưới mức đó app hiện xanh.", "raise": "Chấp nhận nhiều check chập chờn hơn trước khi đổi màu.", "lower": "Một check chập chờn là đủ hiện vàng.", "when": "Giảm khi các check đã ổn định; tăng trong lúc một test chập chờn đã biết đang được cách ly.", "example": "Với mặc định 5 %, 1 lượt chập chờn trên 25 (4 %) là xanh."}}},
{"key": "cis.delivery.queue_flaky_amber_pct", "app": "cis", "area": "delivery", "label": "Delivery: merge queue flaky rate for amber (%)", "description": "Platform › Delivery, tab Merge queue (api/services/delivery_metrics.py) colours the flaky rate amber at or below this percent and above the green value; above it red. Starting value 15 %.", "value_type": "pct", "unit": "%", "min_value": 0, "max_value": 100, "allowed_values": null, "default_value": 15, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The flaky rate above which an app's merge queue turns red; between the green value and this it is amber.", "raise": "Many flaky checks stay amber longer.", "lower": "Many flaky checks turn red sooner.", "when": "Keep it above the green value.", "example": "With the default of 15 %, 2 flaky entries out of 20 is amber and 4 out of 20 is red."}, "vi": {"what": "Tỉ lệ chập chờn mà trên mức đó hàng merge của app chuyển đỏ; giữa mức xanh và mức này là vàng.", "raise": "Chập chờn nhiều giữ màu vàng lâu hơn.", "lower": "Chập chờn nhiều chuyển đỏ sớm hơn.", "when": "Giữ cao hơn mức xanh.", "example": "Với mặc định 15 %, 2 lượt chập chờn trên 20 là vàng và 4 trên 20 là đỏ."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('445', now(), 'AA-1125: the Platform › Delivery merge-queue colour thresholds in the settings registry')
ON CONFLICT (version) DO NOTHING;

COMMIT;
