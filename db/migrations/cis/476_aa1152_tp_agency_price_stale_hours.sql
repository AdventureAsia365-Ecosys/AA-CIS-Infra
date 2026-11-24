-- Migration 476: AA-1152 (S289; S285 decision B2 option C, contract tripplanner.agency_prices.v1) — TripPlanner's window
-- for an agency's own "from" prices, in the platform settings registry (CIS 407; tech lead S279: a policy value is a
-- setting on Platform › Settings, never a code literal or an env var alone).
--
-- Why. An agency's CRM (AA-Partner) publishes the agency's own "from" prices to TripPlanner every hour and after each
-- change of its markups, rounding steps or "Show prices on my planner" switch. When the CRM can no longer publish (the
-- agency's CRM locked or deleted, the CRM down), the last list would stay on the agency's tour page and day cards for
-- good, priced from old tariffs and markups. TripPlanner (backend/shared/agency_prices.py) hides every price of an
-- agency whose last list arrived longer ago than this window (tripplanner.agency_prices.received_at, tp-036).
--
-- What:
--   1. One row in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), app tripplanner, area "prices", scope platform, impact
--      medium, maker-checker, no evidence, no env override, enforced (read by AA-TripPlanner-Web through
--      catalog.v_app_settings_v1, CIS 415; its code default equals this seed, backend/tests/test_s279_settings.py):
--        tripplanner.prices.agency_stale_hours   int hours, 2..168, default 6 (the CRM publishes every hour, so six
--                                                hours tolerate a few missed runs)
--      The seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 476.
--
-- Behaviour on apply. None for running code: no value row is seeded; TripPlanner serves its code default (6) until the
-- view lists the key, then the default here (6) until an administrator changes it.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a config row INSERTed into an existing table.
-- MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a), then
-- the TripPlanner code PR (no readiness raise: the reader falls back to its code default). DM-6.1: no personal data.
-- DM-7.1: no new table.
--
-- Number. Owner main max (475) + 1. If the owner main max + 1 differs at merge, renumber (git grep '476_' and '476'
-- here, in tests/integration/test_aa1152_migration_476.py, tests/integration/test_aa1096_migration_414.py,
-- tests/unit/test_aa1096_tp_settings_seed.py and compiled_defaults.json; AA-TripPlanner-Web names CIS 476 in
-- backend/config.py, backend/shared/settings.py and backend/tests/test_s279_settings.py).
--
-- Locks. One INSERT of one row (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
--
-- Rollback (a new forward migration, after the TripPlanner code PR is reverted): DELETE the key's value rows first,
-- then the key.

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
{"key": "tripplanner.prices.agency_stale_hours", "app": "tripplanner", "area": "prices", "label": "TripPlanner: hide an agency's prices older than (hours)", "description": "An agency's own \"from\" prices (published by its CRM every hour and after each change, contract tripplanner.agency_prices.v1) show on its tour page and day cards only while the last list arrived within this many hours. An older list hides every price of that agency until its CRM publishes again, so an agency whose CRM is locked, deleted or cannot reach TripPlanner never keeps showing prices from old tariffs. Read by AA-TripPlanner-Web backend/shared/agency_prices.py through catalog.v_app_settings_v1.", "value_type": "int", "unit": "hours", "min_value": 2, "max_value": 168, "allowed_values": null, "default_value": 6, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "How old an agency's last published price list may be before TripPlanner stops showing its prices. The agency's CRM publishes the list every hour.", "raise": "Higher: a short CRM outage no longer hides the prices, but a list from older tariffs or markups can stay up longer after the CRM stopped publishing.", "lower": "Lower: an out-of-date list disappears sooner, but one or two missed hourly runs already hide every price of the agency until the next run.", "when": "Raise it if agencies report prices that disappear during short CRM maintenance; lower it if prices must follow tariff changes more closely.", "example": "With the default 6: the CRM last published at 08:00 and then stopped; the agency's prices show until 14:00 and are hidden after that, until the CRM publishes again."}, "vi": {"what": "Bảng giá đại lý công bố lần cuối được cũ tối đa bao lâu trước khi TripPlanner ngừng hiện giá của đại lý. CRM của đại lý công bố bảng giá mỗi giờ.", "raise": "Cao hơn: CRM gián đoạn ngắn không làm mất giá, nhưng bảng giá tính từ biểu giá hoặc mức lời cũ có thể còn hiện lâu hơn sau khi CRM ngừng công bố.", "lower": "Thấp hơn: bảng giá lỗi thời biến mất sớm hơn, nhưng chỉ cần lỡ một hai lần chạy mỗi giờ là mọi giá của đại lý bị ẩn tới lần chạy kế tiếp.", "when": "Tăng nếu đại lý báo giá biến mất trong lúc bảo trì CRM ngắn; giảm nếu giá phải bám sát thay đổi biểu giá hơn.", "example": "Với mặc định 6: CRM công bố lần cuối lúc 08:00 rồi ngừng; giá của đại lý hiện tới 14:00, sau đó bị ẩn cho tới khi CRM công bố lại."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('476', now(), 'AA-1152: TripPlanner window for an agency''s own prices (tripplanner.prices.agency_stale_hours)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
