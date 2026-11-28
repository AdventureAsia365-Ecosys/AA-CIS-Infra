-- Migration 497: AA-1191 (S297) — "Enabled currencies": the one settings-registry key that says which currencies the
-- platform shows and accepts (CIS, Booking, Partner). USD only by default.
--
-- Why. The tech lead decided on 27/11/2026 (S295) that the system uses one currency, USD, and for now shows only USD.
-- The code still offers VND: the plan VND list (shared.plan.price_vnd_monthly / price_extra_seat_vnd), the tenant
-- billing currency and the agreed currency (CHECK USD | VND, CIS 435), the Booking SaaS invoice drafts and the CRM
-- money helpers. Which currencies are open is a policy value (tech lead S279: never a code literal), so it is one
-- administrator-edited key; VND comes back by changing this key alone (the VND columns stay, nothing is dropped).
--
-- What:
--   1. One row in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), app cis, area billing, scope platform, impact high,
--      maker-checker, no evidence, no env override, enforced (services/tenant_account/currency.py names the key, the
--      settings-lint reader check):
--        cis.billing.enabled_currencies   list, allowed ["USD", "VND"] (the CIS 435 CHECK values), default ["USD"]
--      USD is the base currency and is always enabled, even when the list leaves it out (every price has a USD column;
--      the readers add it back). Its plain label and EN + VI operator guide ship on the seed row (CIS 416 rule).
--      The key is a cis.billing.* key, so shared.v_setting_billing_effective (CIS 435) serves its value in force to
--      the SQL readers (the Booking contract view of CIS 498).
--   2. Register 497.
--
-- Behaviour on apply. None for running code: no value row is seeded, and the AA-1191 code PRs read the compiled
-- default (USD only) until an administrator approves another value. No data changes: tenants, plans and terms that
-- hold VND keep their values (the DRY RUN of the AA-1191 lane counts them; any conversion is a later reviewed step).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a config row INSERTed into an existing
-- table. MIG-4: the AA-1191 migration-only PR (batch cis 497-498), applied on Dev by Infra Migration Apply when the job
-- tables are idle (ADR 0017a), then the code PR. No readiness raise: the reader serves the compiled default while the
-- row is missing. DM-6.1: no personal data. DM-7.1: no new table.
--
-- Number. 497 (S297 renumber: 495-496 are taken by another lane of the wave, AA-1054). If the owner main max + 1
-- differs at merge, renumber: git grep '497_' and "'497'" (this file, 498, tests/integration/test_aa1191_migration_497.py
-- and test_aa1191_migration_498.py, compiled_defaults.json's _generated line, docs/implementation-notes/AA-1191.md).
--
-- Locks. One INSERT ... ON CONFLICT of one row (the definition guard trigger allows the file's role, cis_owner).
-- lock_timeout 5s. Re-runnable: ON CONFLICT DO NOTHING keeps a row an earlier run wrote.
--
-- Rollback (a new forward migration, after the code PRs and 498 are reverted): DELETE the key's value rows first, then
-- the key.

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
{"key": "cis.billing.enabled_currencies", "app": "cis", "area": "billing", "label": "Enabled currencies", "description": "The currencies the platform shows and accepts (services/tenant_account/currency.py). USD is the base currency and always enabled, even when the list leaves it out. A currency that is not enabled is hidden everywhere (CIS Plans & add-ons, the plan drawer, the commercial terms, Tenant 360, the Content studio billing page and dashboard; Booking SaaS invoice drafts read it through catalog.v_billing_currencies_v1, CIS 498; the partner CRM through GET /catalog/v1/currencies, contract catalog.http.v1 1.5), and every API refuses a write in it (422 currency_not_enabled). A tenant whose stored billing currency is not enabled is quoted and invoiced in USD; its stored value and the plans' VND list stay in the database and come back when the currency is enabled again. Default USD only (tech lead S295).", "value_type": "list", "unit": null, "min_value": null, "max_value": null, "allowed_values": ["USD", "VND"], "default_value": ["USD"], "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "Which currencies agencies and staff see and can use for plans, billing terms, quotes, SaaS invoices and CRM proposals. USD is always on.", "raise": "Adding VND: the VND price list, the billing currency and agreed-currency pickers, the VND quote and the VND invoice drafts come back, with the values saved before.", "lower": "Removing VND: every VND field and picker is hidden, writes in VND are refused, and agencies set to VND are quoted and invoiced in USD until it is added again.", "when": "Add VND only once the business owner confirms agencies must be invoiced in VND (for example a legal or accounting need); keep USD only otherwise.", "example": "With the default of USD only, an agency whose billing currency was saved as VND sees its plan and quote in USD, and staff cannot pick VND anywhere."}, "vi": {"what": "Những loại tiền nào đại lý và staff thấy và được dùng cho gói, điều khoản thanh toán, báo giá, hoá đơn SaaS và proposal trong CRM. USD luôn bật.", "raise": "Thêm VND: bảng giá VND, ô chọn tiền tệ thanh toán và tiền tệ thoả thuận, báo giá VND và hoá đơn nháp VND hiện lại, với các giá trị đã lưu trước đó.", "lower": "Bỏ VND: mọi ô và lựa chọn VND bị ẩn, ghi bằng VND bị từ chối, và đại lý đang đặt VND được báo giá, lập hoá đơn bằng USD cho tới khi thêm lại.", "when": "Chỉ thêm VND khi chủ doanh nghiệp xác nhận phải lập hoá đơn VND cho đại lý (ví dụ yêu cầu pháp lý hoặc kế toán); còn lại giữ chỉ USD.", "example": "Với mặc định chỉ USD, đại lý đã lưu tiền tệ thanh toán là VND thấy gói và báo giá bằng USD, và staff không chọn được VND ở đâu cả."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('497', now(), 'AA-1191: Enabled currencies setting (USD only by default)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
