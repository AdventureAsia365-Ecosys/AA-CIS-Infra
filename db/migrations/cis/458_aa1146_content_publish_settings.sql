-- Migration 458: AA-1146 (S285, slice L3 part 1; tech lead approvals D1 and A2 of S285) — the content publish settings:
-- the two-person publish switch and the monthly cap of the automatic agency-copy refresh.
--
-- Why. D1: who may publish a tour's content (Review Queue approve, promote, a draft version's publish) is a capability,
-- content.publish (admin, content_lead; AA-CIS-App code PR). Whether the person who wrote a draft may also publish it
-- is a policy value that changes at the first prod, so it is a setting, never a code literal or an env var (tech lead
-- S279), separate from cis.settings.two_person_approval (settings changes and content publishing go live at different
-- times). A2: the automatic refresh of the agencies' copies when a tour's facts change (slice L3 part 2) spends within a
-- monthly cap editable in admin; the cap is seeded now so it is visible and reviewed before the job that reads it
-- ships.
--
-- What:
--   1. Three rows in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR):
--        cis.content.publish_two_person      bool, default false (Dev: the writer may publish their own draft), area
--          content, platform scope, impact high, maker_checker (with cis.settings.two_person_approval on, a second
--          admin approves the change; and while this switch is on, turning it off needs a second person whatever the
--          other flag says: api/services/settings_registry.py), enforced: read by api/services/content_publish_gate.py
--          (this PR) on every publish route of the code PR. On: only content.publish holders publish, and never their
--          own draft (403 two_person_required / same_person).
--        cis.content.t2_rerun_monthly_cap_usd  usd, 0..1000, default 10 (tech lead A2: 10 USD a month on Dev), area
--          content, impact high, maker_checker, enforced false: no running path reads it until the refresh job of
--          slice L3 part 2 ships (its guide says so).
--        cis.content.t2_rerun_alert_pct      pct, 1..100, default 80 (A2: alert at 80 %), area content, impact medium,
--          single approval, enforced false (same reason).
--      Each seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 458.
--
-- Behaviour on apply. None for running code: no value row is seeded; nothing on main reads the keys (the default of the
-- switch is off, the behaviour of today).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): config rows INSERTed into an existing table.
-- MIG-4: a migration-only PR with 457 (one batch, cis 457-458), applied on Dev by Infra Migration Apply when the job
-- tables are idle (ADR 0017a), then the code PR. DM-6.1: no personal data. DM-7.1: no new table.
--
-- Number. 457 (same PR) comes first. If the owner main max + 1 differs at merge, renumber both (see 457's header).
--
-- Locks. One INSERT of three rows (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
--
-- Rollback (a new forward migration, after the code PR is reverted): DELETE the keys' value rows first, then the keys.

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.setting_definition') IS NULL THEN
        RAISE EXCEPTION 'migration 458: shared.setting_definition missing (apply 407 first)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'shared' AND table_name = 'setting_definition' AND column_name = 'guide') THEN
        RAISE EXCEPTION 'migration 458: shared.setting_definition.guide missing (apply 416 first)';
    END IF;
END $$;

-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$
[
{"key": "cis.content.publish_two_person", "app": "cis", "area": "content", "label": "Two-person publishing of tour content", "description": "On: a tour version goes live (Review Queue approve, promote, publish of a draft version) only when the person publishing holds content.publish (admin, content_lead) and did not write the draft: 403 two_person_required / same_person otherwise. Off (development phase): content staff may publish their own drafts through the same re-check gate. Read on every publish by api/services/content_publish_gate.py, in the publish transaction's connection (fails closed: an unreadable value counts as on). Separate from cis.settings.two_person_approval. While it is on, turning it off needs a second person.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": false, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "Whether a tour's content needs a second person before it goes live: the person who wrote a draft or edited a version cannot publish it, and only a content lead or an administrator can publish.", "raise": "On: every published change to a tour is read by a second person first; changes reach the website more slowly.", "lower": "Off: content staff publish their own edits after the automatic checks pass; faster, with no second reader.", "when": "Turn it on at the first production launch, or as soon as more than one person edits tours every day.", "example": "With the default off (development phase), a content editor fixes a typo and publishes it alone; when on, a content lead publishes it."}, "vi": {"what": "Nội dung tour có cần người thứ hai trước khi lên trang hay không: người viết bản nháp hoặc sửa một phiên bản không tự xuất bản được, và chỉ trưởng nhóm nội dung hoặc quản trị viên mới xuất bản.", "raise": "Bật: mọi thay đổi xuất bản của một tour đều được người thứ hai đọc trước; thay đổi lên website chậm hơn.", "lower": "Tắt: nhân viên nội dung tự xuất bản bản sửa của mình khi bước kiểm tự động đạt; nhanh hơn, không có người đọc thứ hai.", "when": "Bật khi ra mắt bản production đầu tiên, hoặc ngay khi có hơn một người sửa tour hằng ngày.", "example": "Với mặc định tắt (giai đoạn phát triển), nhân viên nội dung sửa một lỗi chính tả và tự xuất bản; khi bật, trưởng nhóm nội dung xuất bản."}}},
{"key": "cis.content.t2_rerun_monthly_cap_usd", "app": "cis", "area": "content", "label": "Agency copy refresh after a fact change: monthly cap (USD)", "description": "The billed model cost a calendar month (UTC) may spend on the automatic rewrite of the agencies' tour copies when a tour's facts change (FactSheet diff; wording-only edits never trigger it). At the cap the copies are only marked stale and the agencies notified. Seeded now (tech lead S285 A2: 10 USD a month on Dev, alert at 80 %, cis.content.t2_rerun_alert_pct); not enforced yet: the refresh job of AA-1146 part 2 reads it.", "value_type": "usd", "unit": "USD/month", "min_value": 0, "max_value": 1000, "allowed_values": null, "default_value": 10, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": false, "guide": {"en": {"what": "The most a month may spend on rewriting the agencies' copies of a tour automatically when the tour's facts change. Not used yet: the automatic refresh is still being built, so nothing spends against it today.", "raise": "More agency copies follow a fact change on their own within the month; the model bill can grow with it.", "lower": "Fewer automatic rewrites; past the cap the copies are only marked out of date and the agencies are told to refresh them.", "when": "Raise it when the alert fires early in the month and agencies wait for refreshed copies; lower it when the bill matters more than freshness.", "example": "With the default of 10 USD, about 40 to 80 agency copies can be refreshed a month at the measured cost per copy."}, "vi": {"what": "Số tiền tối đa một tháng được chi để tự viết lại bản tour của các đại lý khi dữ kiện của tour thay đổi. Chưa dùng: phần tự làm mới đang được xây, nên hiện chưa có khoản chi nào tính vào mức này.", "raise": "Nhiều bản của đại lý tự theo kịp thay đổi dữ kiện trong tháng hơn; hoá đơn model có thể tăng theo.", "lower": "Ít lượt tự viết lại hơn; quá mức trần thì các bản chỉ bị đánh dấu lỗi thời và đại lý được báo để tự làm mới.", "when": "Tăng khi cảnh báo bật sớm trong tháng và đại lý phải chờ bản làm mới; giảm khi hoá đơn quan trọng hơn độ mới.", "example": "Với mặc định 10 USD, khoảng 40 đến 80 bản của đại lý được làm mới mỗi tháng theo chi phí đo được cho mỗi bản."}}},
{"key": "cis.content.t2_rerun_alert_pct", "app": "cis", "area": "content", "label": "Agency copy refresh after a fact change: alert at (% of the monthly cap)", "description": "The share of cis.content.t2_rerun_monthly_cap_usd at which the operators are alerted (bell + e-mail). Seeded now (tech lead S285 A2: alert at 80 %); not enforced yet: the refresh job of AA-1146 part 2 reads it.", "value_type": "pct", "unit": "%", "min_value": 1, "max_value": 100, "allowed_values": null, "default_value": 80, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": false, "guide": {"en": {"what": "How much of the monthly cap of the automatic agency-copy refresh may be spent before the team gets an alert. Not used yet: the automatic refresh is still being built.", "raise": "The alert comes later, closer to the cap; less noise, less time to react before refreshes stop.", "lower": "The alert comes earlier; more time to raise the cap or pause before the agencies' copies stop refreshing.", "when": "Lower it if the cap is often reached before anyone notices; raise it if the alert fires every month without action.", "example": "With the default of 80 % and a cap of 10 USD, the alert fires once 8 USD is spent in the month."}, "vi": {"what": "Phần trăm của mức trần tháng của việc tự làm mới bản đại lý được chi trước khi nhóm nhận cảnh báo. Chưa dùng: phần tự làm mới đang được xây.", "raise": "Cảnh báo đến muộn hơn, gần mức trần hơn; ít ồn hơn, ít thời gian xử lý hơn trước khi việc làm mới dừng.", "lower": "Cảnh báo đến sớm hơn; có thêm thời gian để tăng trần hoặc tạm dừng trước khi bản của đại lý ngừng được làm mới.", "when": "Giảm nếu mức trần thường bị chạm trước khi có người để ý; tăng nếu cảnh báo bật hằng tháng mà không ai cần làm gì.", "example": "Với mặc định 80 % và mức trần 10 USD, cảnh báo bật khi đã chi 8 USD trong tháng."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('458', now(), 'AA-1146: content publish settings (two-person publishing, agency copy refresh cap and alert)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
