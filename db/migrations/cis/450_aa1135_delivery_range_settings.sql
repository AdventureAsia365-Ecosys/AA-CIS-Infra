-- Migration 450: AA-1135 (S284) — the two limits of the custom date range of Platform › Delivery in the platform
-- settings registry (CIS 407; tech lead S279: a threshold, limit, cap or policy value is a setting on Platform ›
-- Settings, never a code literal or an env var alone). Same area and pattern as CIS 433 and CIS 445 (AA-1108, AA-1125).
--
-- Why. Platform › Delivery gets a range picker (presets 7 / 28 / 90 days from the root collector, and a custom from / to).
-- The CIS API (api/services/delivery_range.py) computes a custom range from the collector's daily event files on S3
-- with a byte copy of the collector's engine and keeps the result per range until the next collection. The longest
-- range it accepts and how many results it keeps are these two settings.
--
-- What:
--   1. Two rows in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), area "delivery", scope platform, impact low, single approval,
--      no evidence, no env override, enforced (services/reports/delivery_settings.py names both keys in this PR, the
--      settings-lint reader check; the code PR reads them through shared.settings):
--        cis.delivery.custom_range_max_days       int days 1-400, default 90  (the longest preset)
--        cis.delivery.custom_range_cache_entries  int ranges 1-200, default 20
--      Each seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 450.
--
-- Behaviour on apply. None for running code: no value row is seeded and nothing on main reads these keys; after the code
-- PR the custom range reads the defaults until an administrator changes a value.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): config rows INSERTed into an existing table.
-- MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a), then the
-- code PR (no readiness raise: a reader falls back to the compiled defaults). DM-6.1: no personal data. DM-7.1: no new
-- table.
--
-- Number. 447 is the newest CIS migration on main (18/11/2026); 448 and 449 are taken by a parallel lane (AA-1127). If the
-- owner main max + 1 differs at merge, renumber
-- (git grep '450_' and '450' here, in tests/integration/test_aa1135_migration_450.py, compiled_defaults.json and
-- docs/implementation-notes/AA-1135.md).
--
-- Locks. One INSERT of two rows (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
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
{"key": "cis.delivery.custom_range_max_days", "app": "cis", "area": "delivery", "label": "Delivery: longest custom date range (days)", "description": "Platform › Delivery (api/services/delivery_range.py) refuses a custom date range longer than this many days (from and to included). The custom range is recomputed from the delivery collector's daily event files, which reach back about 98 days; a longer range is refused, never estimated. Starting value 90 days (the longest preset).", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 400, "allowed_values": null, "default_value": 90, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The longest custom date range (in days, both ends included) the Delivery page computes.", "raise": "Longer custom ranges are allowed, up to the history the collector keeps; each computation reads more data.", "lower": "Only shorter custom ranges are allowed; the presets (7, 28 and 90 days) still work.", "when": "Keep it at or under the collector's stored history (about 98 days); a range beyond the history is refused anyway.", "example": "With the default of 90 days, 1 August to 29 October is allowed and 1 August to 30 October is refused."}, "vi": {"what": "Khoảng thời gian tự chọn dài nhất (tính bằng ngày, gồm cả hai đầu) mà trang Delivery tính.", "raise": "Cho phép khoảng tự chọn dài hơn, tới mức lịch sử bộ thu thập còn giữ; mỗi lần tính đọc nhiều dữ liệu hơn.", "lower": "Chỉ cho phép khoảng ngắn hơn; các mốc sẵn (7, 28 và 90 ngày) vẫn dùng được.", "when": "Giữ bằng hoặc dưới lịch sử bộ thu thập lưu (khoảng 98 ngày); khoảng vượt lịch sử vẫn bị từ chối.", "example": "Với mặc định 90 ngày, từ 1/8 tới 29/10 được phép còn từ 1/8 tới 30/10 bị từ chối."}}},
{"key": "cis.delivery.custom_range_cache_entries", "app": "cis", "area": "delivery", "label": "Delivery: custom ranges kept in the cache", "description": "Platform › Delivery (api/services/delivery_range.py) keeps the result of this many custom date ranges in the API process until the next delivery collection replaces them; the least recently used range is dropped first. Starting value 20.", "value_type": "int", "unit": "ranges", "min_value": 1, "max_value": 200, "allowed_values": null, "default_value": 20, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How many computed custom date ranges the Delivery page keeps, so opening the same range again is instant.", "raise": "More ranges stay ready; each kept range uses a little more API memory.", "lower": "Fewer ranges stay ready; a range asked again after it is dropped is computed again (a few seconds).", "when": "Raise it when several people compare many ranges in the same hour; the cache empties at each hourly collection anyway.", "example": "With the default of 20, the 21st different range drops the one used longest ago."}, "vi": {"what": "Số khoảng thời gian tự chọn đã tính mà trang Delivery giữ lại, để mở lại cùng khoảng thì có ngay.", "raise": "Nhiều khoảng được giữ sẵn hơn; mỗi khoảng giữ lại tốn thêm một ít bộ nhớ API.", "lower": "Ít khoảng được giữ sẵn hơn; khoảng bị bỏ ra rồi hỏi lại thì được tính lại (vài giây).", "when": "Tăng khi nhiều người so sánh nhiều khoảng trong cùng một giờ; bộ đệm vẫn được làm trống sau mỗi lượt thu thập hằng giờ.", "example": "Với mặc định 20, khoảng khác nhau thứ 21 sẽ đẩy ra khoảng lâu chưa dùng nhất."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('450', now(), 'AA-1135: the Platform › Delivery custom date range limits in the settings registry')
ON CONFLICT (version) DO NOTHING;

COMMIT;
