-- Migration 453: AA-1113 (S284, tech lead redesign of 18/11/2026; root ADR 0009 decision 6) — the provider budget of
-- each LLM connection as a platform setting, so the split of that budget between the apps is visible and checkable.
--
-- Why. A model connection (an AWS account's Bedrock, a vendor API) has one budget at its provider (the AWS Budget of the
-- account, the vendor console's monthly limit). Two apps spend on the same connections with their own gateways: CIS
-- (with TripPlanner, one ledger, shared.llm_call_log) and the partner CRM (its own ledger, crm.llm_call). The tech lead
-- decided (S284) that no app reads another app's ledger or view: each app has its OWN monthly cap per connection and
-- the shares together stay under the provider budget, so the provider total is never exceeded. The CIS share is the
-- connection's existing monthly_budget_usd (shared.llm_provider_connection, AI gateway > Providers > Connections); the
-- CRM share is the CRM setting crm.ai.connection_monthly_cap_usd (AA-Partner crm-077, read by CIS through the existing
-- CRM settings relay of Platform > Settings, crm.ops.v1 /settings). The provider budget itself was nowhere: this file
-- makes it a setting (tech lead S279: a limit is a setting, never a code literal), and the AI gateway Budgets tab
-- (AA-CIS-App code PR) shows per connection the provider budget, the CIS share, the CRM share and a flag when the two
-- shares add up to more than the provider budget.
--
-- What:
--   1. One row in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR; its reader api/services/llm_connection_split.py ships in this
--      PR, the settings-lint reader check):
--        cis.spend.connection_provider_budget_usd  json object {connection key: USD per month}, every entry 0..1000000
--          (the bound of monthly_budget_usd), default {} (no provider budget declared: the Budgets tab says "not set"
--          and checks nothing), area spend, platform scope, impact medium, single approval, no evidence, no env
--          override, enforced. Informational: no gateway reads it on a call path; each app enforces its own share.
--      The seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 453.
--
-- Behaviour on apply. None for running code: no value row is seeded, nothing on main reads the key.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a config row INSERTed into an existing table.
-- MIG-4: a migration-only PR (with 451 and 452, one batch), applied on Dev by Infra Migration Apply when the job tables
-- are idle (ADR 0017a), then the code PR. DM-6.1: no personal data. DM-7.1: no new table.
--
-- Number. 451 and 452 (same PR) come first; 448-450 are held by other S284 lanes' open migration PRs. If the owner main
-- max + 1 differs at merge, renumber the three together (git grep '453_' and 'CIS 453' here, in
-- tests/integration/test_aa1113_migration_453.py, compiled_defaults.json, api/services/llm_connection_split.py and
-- docs/implementation-notes/AA-1113.md; the AA-Partner crm-077 header names it too).
--
-- Locks. One INSERT of one row (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
--
-- Rollback (a new forward migration, after the code PR is reverted): DELETE the key's value rows first, then the key.

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.setting_definition') IS NULL THEN
        RAISE EXCEPTION 'migration 453: shared.setting_definition missing (apply 407 first)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'shared' AND table_name = 'setting_definition' AND column_name = 'guide') THEN
        RAISE EXCEPTION 'migration 453: shared.setting_definition.guide missing (apply 416 first)';
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
{"key": "cis.spend.connection_provider_budget_usd", "app": "cis", "area": "spend", "label": "LLM connections: provider budget per month (USD)", "description": "The monthly budget each LLM connection has at its provider (the AWS Budget of the account, the vendor console's monthly limit), by connection key, for example {\"acc3\": 100}. The apps split it: the CIS share is the connection's monthly budget (AI gateway > Providers > Connections), the CRM share is the CRM setting crm.ai.connection_monthly_cap_usd. AI gateway > Budgets shows the split and flags a connection whose two shares add up to more than this budget. A connection left out has no provider budget declared and is not checked. Read by api/services/llm_connection_split.py; no gateway call reads it.", "value_type": "json", "unit": "USD/month", "min_value": 0, "max_value": 1000000, "allowed_values": null, "default_value": {}, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The monthly budget a model connection has at its provider, the ceiling that the apps' own monthly caps on that connection must fit under together.", "raise": "More room for the apps' shares; set it only to what the provider budget really is, or the check stops meaning anything.", "lower": "The Budgets tab flags the connection sooner when the CIS and CRM shares add up to more than the provider allows.", "when": "Set it when a provider budget is created or changed (an AWS Budget in Terraform, a vendor console limit), on the same day.", "example": "With {\"acc3\": 100}, a CIS share of 80 and a CRM share of 30 on acc3 add up to 110: the Budgets tab flags acc3 as over-allocated by 10 USD."}, "vi": {"what": "Ngân sách hằng tháng của một kết nối model tại nhà cung cấp, là mức trần mà hạn mức tháng riêng của các app trên kết nối đó cộng lại phải nằm dưới.", "raise": "Thêm chỗ cho phần của các app; chỉ đặt đúng bằng ngân sách thật ở nhà cung cấp, nếu không phép kiểm không còn ý nghĩa.", "lower": "Tab Budgets đánh dấu kết nối sớm hơn khi phần của CIS và CRM cộng lại vượt mức nhà cung cấp cho phép.", "when": "Đặt ngay trong ngày khi tạo hoặc đổi ngân sách ở nhà cung cấp (AWS Budget trong Terraform, giới hạn trên console của vendor).", "example": "Với {\"acc3\": 100}, phần CIS 80 và phần CRM 30 trên acc3 cộng lại 110: tab Budgets đánh dấu acc3 vượt phân bổ 10 USD."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('453', now(), 'AA-1113: the provider budget of each LLM connection as a platform setting (the per-app split)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
