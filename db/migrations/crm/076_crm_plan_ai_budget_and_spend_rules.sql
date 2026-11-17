-- Migration crm-076: AA-1126 (S283, tech lead AI spend policy of 17/11/2026; slices L3 and G3 / L4 of root
-- docs/audits/2026-11-17-S283-session/ai-caps-gap.md) — the agency AI budget comes from the agency's CRM plan, and the
-- CRM's AI spend rules per environment become a setting.
--
-- Owner: AA-Partner (api/migrations/076_crm_plan_ai_budget_and_spend_rules.sql). AA-CIS-Infra db/migrations/crm/ holds
-- the byte copy Migration Apply runs. Key crm-076, right after crm-075; if the numbers move, renumber: file name, this
-- header, Guard 0 and the registration below, and the tests that name it (git grep '076_' and 'crm-076').
--
-- Why. Today every agency gets a flat 2 USD a month of AI drafting (crm.ai.budget_default_usd / budget_max_usd), not
-- tied to what it pays for, and the CRM app's daily AI budget (AI gateway > App profiles) stops every agency at once.
-- The policy: on prod only an agency's own plan quota stops its AI (the reason told, with an upgrade path); app-wide
-- caps alert; a budget that cannot be read degrades with a warning. Dev keeps today's hard behaviour.
--
-- What:
--   1. crm.tenant_entitlement gains ai_budget_usd numeric(10,2) NULL (0..10000, the crm.tenant_settings budget CHECK):
--      the agency's monthly AI budget from its CIS plan (feature crm.ai_budget_usd_monthly, CIS 447: a limit on the
--      CIS Plans page, a per-tenant override on Tenant 360), projected by crm_entitlement_pull (the code PR). NULL =
--      the plan gives none (an agency never projected, or a plan without the key): the CRM settings below apply.
--   2. One crm.setting_definition row (settings-seed block, read by api/scripts/gen_settings_defaults.py into
--      app/platform_settings/compiled_defaults.json; its guide in app/platform_settings/guides.json):
--        crm.spend.environment  enum dev | prod, default dev (today's behaviour), area spend, platform scope, impact
--          high, maker-checker, enforced, no env override. prod: the CRM app's daily AI budget only alerts, and a
--          spend that cannot be read lets the draft go on with a warning; the agency's own monthly budget stays hard.
--        The CIS admin page (Platform > Settings, CRM tab) edits it.
--   3. settings-edit of the two existing budget keys' descriptions: they are now the fallback when the plan gives no
--      AI budget (the guides say the same), except an administrator's per-agency value of crm.ai.budget_max_usd,
--      which wins over the agency's plan (the code PR's app/llm/budget_limits.ceiling; so the CIS Platform › Settings
--      CRM tab never lists an agency value the gateway does not apply).
--   4. Register crm-076.
--
-- Behaviour on apply: none for running code (the new column is NULL for every agency until the code PR's projection
-- fills it; the setting reads dev, today's behaviour). The reader of the key (app/llm/spend_environment.py) ships in
-- this PR so the settings lint (an enforced key has a reader) stays green.
--
-- Class: contract (an ALTER TABLE of an existing table and INSERT / UPDATE of config rows; no '-- migrate:' directive).
-- MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply once every job table is idle (root ADR 0017a),
-- then the code PR. No new table (no DM-7.1 row), no personal data (a USD amount per agency), no crm.erase_subject
-- change: the column lives on the entitlement row, erased with it.
--
-- Rollback (a new forward migration, after the code PR is reverted): ALTER TABLE crm.tenant_entitlement DROP COLUMN
-- ai_budget_usd (destructive file); DELETE FROM crm.setting_value / crm.setting_definition WHERE key =
-- 'crm.spend.environment' as crm_owner; the descriptions back with a settings-edit block.
--
-- Runs as crm_owner (the crm-064 definition guard allows only the owner; the owner of crm.tenant_entitlement), one
-- BEGIN … COMMIT block, no role DDL. Re-runnable (ADD COLUMN IF NOT EXISTS, ON CONFLICT DO NOTHING, guarded UPDATE).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-075 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-076: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-075') THEN
        RAISE EXCEPTION 'crm-076: crm-075 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-076' AND description NOT LIKE 'AA-1126 plan AI budget:%') THEN
        RAISE EXCEPTION 'crm-076: the key crm-076 is already held by another migration (not AA-1126): renumber one';
    END IF;
END $$;

-- ── 1. The agency AI budget from the plan ────────────────────────────────────────────────────────
ALTER TABLE crm.tenant_entitlement ADD COLUMN IF NOT EXISTS ai_budget_usd numeric(10,2);
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tenant_entitlement_ai_budget_chk') THEN
        ALTER TABLE crm.tenant_entitlement ADD CONSTRAINT tenant_entitlement_ai_budget_chk
            CHECK (ai_budget_usd IS NULL OR (ai_budget_usd >= 0 AND ai_budget_usd <= 10000));
    END IF;
END $$;
COMMENT ON COLUMN crm.tenant_entitlement.ai_budget_usd IS
    'AA-1126 (crm-076): the monthly AI budget of the agency''s CIS plan (crm.ai_budget_usd_monthly), projected by '
    'crm_entitlement_pull; NULL = none, the settings crm.ai.budget_default_usd / budget_max_usd apply.';

-- ── 2. The spend rules setting ───────────────────────────────────────────────────────────────────
-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "crm.spend.environment", "app": "crm", "area": "spend", "label": "CRM AI spend rules: environment", "description": "Which AI spend rules the CRM follows (tech lead policy S283). dev = hard caps everywhere: the CRM app's daily AI budget (AI gateway > App profiles) stops the AI drafts of every agency, and a spend that cannot be read stops them too. prod = pay per use: the app's daily budget only alerts and an unreadable spend lets the draft go on with a warning; an agency's own monthly AI budget (from its plan) always stops at its limit. Read by app/llm/spend_environment.py.", "value_type": "enum", "unit": null, "min_value": null, "max_value": null, "allowed_values": ["dev", "prod"], "default_value": "dev", "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── 3. The two budget keys are the fallback now ──────────────────────────────────────────────────
-- settings-edit:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted block)
CREATE TEMP TABLE IF NOT EXISTS m076_edit (key text PRIMARY KEY, doc jsonb NOT NULL) ON COMMIT DROP;
INSERT INTO m076_edit (key, doc)
SELECT e.doc ->> 'key', e.doc
  FROM jsonb_array_elements($edit$[
{"key": "crm.ai.budget_default_usd", "description": "The monthly AI budget of an agency whose CRM plan gives no AI budget (CIS feature crm.ai_budget_usd_monthly on the Plans page wins when set), and of an agency with no settings row yet. Never above the agency's ceiling (the lower of the two applies)."},
{"key": "crm.ai.budget_max_usd", "description": "The highest monthly AI budget an agency owner may set on Settings > AI. An administrator may give one agency its own ceiling here, and it wins over the agency's CRM plan. Without one, the plan's crm.ai_budget_usd_monthly (CIS Plans page, Tenant 360) is the ceiling when set, and this platform value when the plan gives none. Seeded at 2 USD (the old code default)."}
]$edit$::jsonb) AS e (doc)
ON CONFLICT (key) DO UPDATE SET doc = EXCLUDED.doc;
-- settings-edit:end

UPDATE crm.setting_definition AS d
   SET description = e.doc ->> 'description'
  FROM m076_edit AS e
 WHERE d.key = e.key AND d.description IS DISTINCT FROM e.doc ->> 'description';

-- ── Post-check ────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM crm.setting_definition WHERE key = 'crm.spend.environment') THEN
        RAISE EXCEPTION 'crm-076: crm.spend.environment is not defined';
    END IF;
    IF EXISTS (SELECT 1 FROM m076_edit AS e JOIN crm.setting_definition AS d ON d.key = e.key
                WHERE d.description <> e.doc ->> 'description') THEN
        RAISE EXCEPTION 'crm-076: a budget key description was not updated';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'crm' AND table_name = 'tenant_entitlement' AND column_name = 'ai_budget_usd') THEN
        RAISE EXCEPTION 'crm-076: crm.tenant_entitlement.ai_budget_usd is missing';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-076', now(), 'AA-1126 plan AI budget: crm.tenant_entitlement.ai_budget_usd (the agency AI budget from its CIS plan), the setting crm.spend.environment (dev | prod), the budget keys described as the fallback')
ON CONFLICT (version) DO NOTHING;

COMMIT;
