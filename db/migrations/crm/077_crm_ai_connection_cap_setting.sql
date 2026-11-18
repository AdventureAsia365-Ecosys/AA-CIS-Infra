-- Migration crm-077: AA-1113 (S284, tech lead redesign of 18/11/2026; root ADR 0009 decision 6) — the CRM's own monthly
-- cap per model connection as a CRM setting.
--
-- Owner: AA-Partner (api/migrations/077_crm_ai_connection_cap_setting.sql). AA-CIS-Infra db/migrations/crm/ holds the
-- byte copy Migration Apply runs. Key crm-077, right after crm-076; if the numbers move, renumber: file name, this
-- header, Guard 0 and the registration below, and the tests that name it (git grep '077_' and 'crm-077').
--
-- Why. A model connection (an AWS account's Bedrock, a vendor API) has one budget at its provider. CIS (with
-- TripPlanner) and the CRM spend on the same connections through their own gateways and ledgers. The tech lead decided
-- (S284) that the CRM reads no CIS view or table (root ADR 0008a: no grants in either direction): each app has its OWN
-- monthly cap per connection, enforced on its own ledger, and the shares together stay under the provider budget, so
-- the provider total is never exceeded. The CIS share is the connection's monthly budget in the CIS gateway registry;
-- the provider budget is the CIS setting cis.spend.connection_provider_budget_usd (CIS 453); this file is the CRM
-- share. CIS AI gateway > Budgets reads this setting through the CRM settings relay it already uses for Platform >
-- Settings (crm.ops.v1 /settings) and flags a connection whose CIS and CRM shares add up to more than the provider
-- budget.
--
-- What:
--   1. One crm.setting_definition row (settings-seed block, read by api/scripts/gen_settings_defaults.py into
--      app/platform_settings/compiled_defaults.json; its guide in app/platform_settings/guides.json; its reader
--      app/llm/connection_share.py ships in this PR, the settings lint):
--        crm.ai.connection_monthly_cap_usd  json object {CIS connection key: USD per month}, every entry 0..1000000,
--          default {} (no CRM cap on any connection: today's behaviour), area ai, platform scope, impact high,
--          maker-checker, enforced, no env override. The CRM gateway (app/llm/connection_cap.py, the AA-1113 code PR)
--          compares the CRM's spend of the UTC month (crm.llm_usage_daily) with the entry of the connection its
--          provider runs on: the dev spend rules (crm.spend.environment, crm-076) refuse connection_budget_exhausted
--          at the cap, the prod rules only log. The CIS admin page (Platform > Settings, CRM tab) edits it.
--   2. Register crm-077.
--
-- Behaviour on apply: none for running code (the default {} caps nothing; nothing on main enforces the key).
--
-- Class: contract (INSERT of a config row into an existing table; no '-- migrate:' directive). MIG-4: a migration-only
-- PR, applied on Dev by Infra Migration Apply once every job table is idle (root ADR 0017a), then the code PR. No new
-- table (no DM-7.1 row), no personal data (USD amounts per connection), no crm.erase_subject change.
--
-- Rollback (a new forward migration, after the code PR is reverted): DELETE FROM crm.setting_value /
-- crm.setting_definition WHERE key = 'crm.ai.connection_monthly_cap_usd' as crm_owner.
--
-- Runs as crm_owner (the crm-064 definition guard allows only the owner), one BEGIN … COMMIT block, no role DDL.
-- Re-runnable (ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-076 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-077: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-076') THEN
        RAISE EXCEPTION 'crm-077: crm-076 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-077' AND description NOT LIKE 'AA-1113 connection cap:%') THEN
        RAISE EXCEPTION 'crm-077: the key crm-077 is already held by another migration (not AA-1113): renumber one';
    END IF;
END $$;

-- ── 1. The CRM's monthly cap per connection ──────────────────────────────────────────────────────
-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "crm.ai.connection_monthly_cap_usd", "app": "crm", "area": "ai", "label": "CRM AI: monthly cap per model connection (USD)", "description": "The CRM's own monthly AI spend cap on each model connection, by the connection's key in the CIS gateway registry, for example {\"acc2\": 20}. The CRM compares its spend of the UTC month (every agency together) with the entry of the connection its AI runs on: under the dev spend rules (crm.spend.environment) an AI draft is refused at the cap (write it by hand), under the prod rules the cap only logs. The CIS share of the same connection is its monthly budget in the CIS AI gateway; together the two must stay under the provider budget (CIS setting cis.spend.connection_provider_budget_usd), which CIS AI gateway > Budgets checks. A connection left out has no CRM cap. Read by app/llm/connection_share.py.", "value_type": "json", "unit": "USD/month", "min_value": 0, "max_value": 1000000, "allowed_values": null, "default_value": {}, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── Post-check ────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM crm.setting_definition WHERE key = 'crm.ai.connection_monthly_cap_usd') THEN
        RAISE EXCEPTION 'crm-077: crm.ai.connection_monthly_cap_usd is not defined';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-077', now(), 'AA-1113 connection cap: the setting crm.ai.connection_monthly_cap_usd (the CRM''s own monthly cap per model connection, its share of the provider budget)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
