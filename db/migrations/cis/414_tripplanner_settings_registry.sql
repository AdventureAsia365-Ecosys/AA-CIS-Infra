-- Migration 414: S279 thresholds lane L5 (AA-1096; tech lead S279: every threshold, limit, cap and policy value is
-- editable on an admin page by the administrator) — TripPlanner's settings in the platform settings registry (CIS 407)
-- and the TripPlanner daily AI cap seeded on its app profile, the one place it is set from now on.
--
-- Why. The S279 thresholds audit (root docs/audits/2026-11-13-S279-session/thresholds-audit/, section 3.1 and lane L5)
-- found TripPlanner's caps and limits in Lambda env vars and code constants: a change needed a Terraform apply or a
-- deploy. TripPlanner has no staff surface, so its rows live in CIS (shared.setting_definition with app =
-- 'tripplanner') and TripPlanner reads them through the contract view catalog.v_app_settings_v1 (CIS 415). The daily
-- AI cap of $5 sat in three places (the TripPlanner code default, the Terraform variable, a CIS mirror constant); the
-- app profile row (shared.llm_app_profile, CIS 345, edited on AI gateway › App profiles, audited, tighten-only for
-- delegated roles) already overrides the env cap in TripPlanner, so it becomes the single source: no registry key
-- duplicates it.
--
-- What:
--   1. Seventeen rows in shared.setting_definition, app 'tripplanner' (seed block below, read by
--      scripts/settings/gen_compiled_defaults.py into shared/settings/compiled_defaults.json in this PR). Every default
--      is today's effective value: the TripPlanner code default (backend/config.py, backend/assembly/plan_chat.py,
--      backend/assembly/agent.py), because Terraform sets none of these env vars except
--      REQUIRE_REGISTRATION_BEFORE_HANDOFF = "true", which equals the code default:
--        rate     narrate 10 / session / h, search 30 / IP / min, signed-in factor 2, send 5 / session / h,
--                 send 20 / IP / h, chat 20 / session / h, chat 40 / IP / h
--        spend    planning chat 2 USD / UTC month for the app, 2 USD / UTC month per tenant (per-tenant override)
--        leads    200 leads per tenant per 24 h (per-tenant override), lead hold 7 days (bounds 3..7, DM-7.1 row
--                 tripplanner.outbox: at most 7 days; the floor 3 keeps two daily ticks of headroom)
--        ai       narration cache 168 h, narration max_tokens 1200, planning chat 3 steps and 700 max_tokens per call
--        handoff  advisor hand-off demo on (B2B only, root ADR 0019), registration before a hand-off on
--      env_override is NULL on purpose: TripPlanner's reader serves the view first; the old env var (and then the code
--      default) is only its fallback while the view cannot be read (one release, then Infra lane L6 removes the env
--      vars). The CIS reader never reads a TripPlanner env var.
--   2. shared.llm_app_profile row 'tripplanner': default_daily_budget_usd = 5.0 when it is still NULL (an
--      administrator's value is kept), updated_by 'migration:414'. Same number as today's TP_DAILY_SPEND_CAP_USD
--      (Terraform 5.0, code default 5.0). TripPlanner then caps every tp_* stage on it (today tp_compose,
--      tp_search_embed and tp_plan_chat: the online stages the env cap covered, so the money stop is the same), and
--      the CIS ops check llm_spend_alert sends its 80 % / 100 % lines for TripPlanner too.
--   3. Register 414.
--
-- Behaviour on apply. No setting_value row is seeded: every TripPlanner key resolves to its default, today's value.
-- TripPlanner reads the view only from the release of lane L5 (AA-TripPlanner-Web backend/shared/settings.py); before
-- it, nothing reads the rows. The daily cap number does not change (5.0 USD); TripPlanner's budget_status reports the
-- source app_profile instead of env.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no '-- migrate:' directive): config rows INSERTed into an existing table
-- and an UPDATE of an existing row. MIG-4: one migration-only PR with 415 (batch cis 414-415); applied on Dev by Infra
-- Migration Apply when the job tables are idle (ADR 0017a).
-- DM-7.1: no new table.
--
-- Number. 413 is the highest on main (13/11/2026, the quality settings registry); if the owner main max + 1 differs,
-- renumber (git grep '414_' and '414' here, in compiled_defaults.json, the 415 precondition and the tests).
--
-- Locks. One INSERT of 17 rows (the definition guard trigger allows the file's role, cis_owner) and a one-row UPDATE.
-- lock_timeout 5s. Idempotent (ON CONFLICT (key) DO NOTHING, the UPDATE only touches a NULL budget), one transaction,
-- self-registering.
--
-- Rollback (a new forward migration, after the TripPlanner reader is reverted): DELETE the value rows of the 17 keys,
-- then the keys; set the profile budget back to NULL on AI gateway › App profiles (the env cap then applies again).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "tripplanner.rate.narrate_per_hour", "app": "tripplanner", "area": "rate", "label": "AI narrations per visitor session per hour", "description": "Narrations one guest session may ask for in one hour when the request would call a model (a cached or all-AA-text narration is not counted). A signed-in traveller gets the signed-in factor times this. Past it the planner answers 429 and shows the basic narration. Fallback while TripPlanner cannot read the view: its env var TP_RATE_NARRATE_PER_HOUR, then this default.", "value_type": "int", "unit": "per hour", "min_value": 1, "max_value": 200, "allowed_values": null, "default_value": 10, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.rate.search_per_minute", "app": "tripplanner", "area": "rate", "label": "AI searches per visitor IP per minute", "description": "Free-text searches one traveller IP may run in one minute when the query would call the embedding model (an empty query is not counted). A signed-in traveller gets the signed-in factor times this. Past it search answers 429. Fallback while TripPlanner cannot read the view: TP_RATE_SEARCH_PER_MINUTE, then this default.", "value_type": "int", "unit": "per minute", "min_value": 1, "max_value": 600, "allowed_values": null, "default_value": 30, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.rate.signed_in_factor", "app": "tripplanner", "area": "rate", "label": "Signed-in traveller allowance factor", "description": "A signed-in traveller gets this many times every per-session and per-IP allowance (narration, search, send to advisor, planning chat). 1 = no extra allowance. Fallback while TripPlanner cannot read the view: TP_RATE_SIGNED_IN_FACTOR, then this default.", "value_type": "int", "unit": "x", "min_value": 1, "max_value": 10, "allowed_values": null, "default_value": 2, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.rate.send_per_hour", "app": "tripplanner", "area": "rate", "label": "Leads per visitor session per hour", "description": "Send to advisor requests one guest session may make in one hour on an agency tenant's planner, counted only when the request would store a lead (it carries the traveller's contact). Fallback while TripPlanner cannot read the view: TP_RATE_SEND_PER_HOUR, then this default.", "value_type": "int", "unit": "per hour", "min_value": 1, "max_value": 100, "allowed_values": null, "default_value": 5, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.rate.send_ip_per_hour", "app": "tripplanner", "area": "rate", "label": "Leads per visitor IP per hour", "description": "Send to advisor requests one traveller IP may make in one hour on an agency tenant's planner, counted only when the request would store a lead. Fallback while TripPlanner cannot read the view: TP_RATE_SEND_IP_PER_HOUR, then this default.", "value_type": "int", "unit": "per hour", "min_value": 1, "max_value": 500, "allowed_values": null, "default_value": 20, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.rate.chat_per_hour", "app": "tripplanner", "area": "rate", "label": "Planning chat messages per visitor session per hour", "description": "Planning chat messages one guest session may send in one hour, counted only when the message would reach a model. Fallback while TripPlanner cannot read the view: TP_RATE_CHAT_PER_HOUR, then this default.", "value_type": "int", "unit": "per hour", "min_value": 1, "max_value": 200, "allowed_values": null, "default_value": 20, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.rate.chat_ip_per_hour", "app": "tripplanner", "area": "rate", "label": "Planning chat messages per visitor IP per hour", "description": "Planning chat messages one traveller IP may send in one hour, counted only when the message would reach a model. Fallback while TripPlanner cannot read the view: TP_RATE_CHAT_IP_PER_HOUR, then this default.", "value_type": "int", "unit": "per hour", "min_value": 1, "max_value": 1000, "allowed_values": null, "default_value": 40, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.spend.plan_chat_monthly_cap_usd", "app": "tripplanner", "area": "spend", "label": "Planning chat monthly cap (whole app)", "description": "The planning chat's model spend of the whole app per UTC month (tripplanner.ai_spend_month). At the cap the chat pauses with a plain message; the rest of the planner is untouched. The daily app cap (AI gateway > App profiles) and an agency tenant's AI budget apply too. Fallback while TripPlanner cannot read the view: TP_PLAN_CHAT_MONTHLY_CAP_USD, then this default.", "value_type": "usd", "unit": "USD/month", "min_value": 0, "max_value": 200, "allowed_values": null, "default_value": 2.0, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.spend.plan_chat_tenant_monthly_cap_usd", "app": "tripplanner", "area": "spend", "label": "Planning chat monthly cap per tenant", "description": "The planning chat's model spend of one tenant per UTC month (the AA demo tenant included). The platform value applies to every tenant; a tenant value overrides it for that tenant. Fallback while TripPlanner cannot read the view: TP_PLAN_CHAT_TENANT_MONTHLY_CAP_USD, then this default.", "value_type": "usd", "unit": "USD/month", "min_value": 0, "max_value": 200, "allowed_values": null, "default_value": 2.0, "scope_kind": "platform+tenant", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.leads.tenant_daily_cap", "app": "tripplanner", "area": "leads", "label": "Leads per tenant per 24 hours", "description": "Leads one agency tenant may receive in 24 hours. Past it a send is refused before anything is stored (429 lead_cap_reached), so a script on a public planner cannot flood the agency's inbox or CRM. A tenant value overrides the platform value for that tenant. Fallback while TripPlanner cannot read the view: TP_LEAD_TENANT_DAILY_CAP, then this default.", "value_type": "int", "unit": "leads/24 h", "min_value": 1, "max_value": 5000, "allowed_values": null, "default_value": 200, "scope_kind": "platform+tenant", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.leads.hold_days", "app": "tripplanner", "area": "leads", "label": "Lead hold before redaction", "description": "Days TripPlanner keeps an undelivered lead before it is redacted anyway (data standards DM-7.1 row tripplanner.outbox: at most 7 days). The floor 3 keeps two daily expiry ticks of headroom inside the hold. Fallback while TripPlanner cannot read the view: TP_LEAD_HOLD_DAYS (clamped 3..7), then this default.", "value_type": "int", "unit": "days", "min_value": 3, "max_value": 7, "allowed_values": null, "default_value": 7, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.ai.narration_cache_ttl_hours", "app": "tripplanner", "area": "ai", "label": "Narration cache lifetime", "description": "Hours a narration in tripplanner.narration_cache is reused for the same itinerary before a new one is written (a longer window means fewer paid narrations). Fallback while TripPlanner cannot read the view: NARRATION_CACHE_TTL_HOURS, then this default.", "value_type": "int", "unit": "hours", "min_value": 1, "max_value": 720, "allowed_values": null, "default_value": 168, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.ai.narration_max_tokens", "app": "tripplanner", "area": "ai", "label": "Narration output tokens", "description": "max_tokens of one trip narration call (stage tp_compose). A reasoning model's floor may raise it (aa_llm tokens), never lower it. A smaller number cuts long trips short (a truncated answer degrades to the basic narration).", "value_type": "int", "unit": "tokens", "min_value": 400, "max_value": 4000, "allowed_values": null, "default_value": 1200, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.ai.plan_chat_max_steps", "app": "tripplanner", "area": "ai", "label": "Planning chat model calls per message", "description": "Model calls one planning chat message may make: tool steps plus the final answer (the last call must answer). Each step is a paid call; the turn deadline still bounds the total time.", "value_type": "int", "unit": "calls", "min_value": 1, "max_value": 5, "allowed_values": null, "default_value": 3, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.ai.plan_chat_max_tokens", "app": "tripplanner", "area": "ai", "label": "Planning chat output tokens per call", "description": "max_tokens of one planning chat model call (stage tp_plan_chat). A reasoning model's floor may raise it, never lower it.", "value_type": "int", "unit": "tokens", "min_value": 200, "max_value": 2000, "allowed_values": null, "default_value": 700, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.handoff.advisor_demo", "app": "tripplanner", "area": "handoff", "label": "Send to advisor is a demo (B2B only)", "description": "On (the B2B-only model, root ADR 0019): on the bare planner and the AA demo tenant, send to advisor answers 410 b2b_only before any write (no registration, no inquiry, no Booking case). An agency tenant's planner sends leads to that tenant either way. Off turns the frozen AA hand-off back on. Fallback while TripPlanner cannot read the view: ADVISOR_HANDOFF_DEMO, then this default.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": true, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "tripplanner.handoff.require_registration", "app": "tripplanner", "area": "handoff", "label": "Registration before the AA hand-off", "description": "On: the frozen AA hand-off (advisor demo off) needs the traveller's name and a phone or e-mail before it sends. Fallback while TripPlanner cannot read the view: REQUIRE_REGISTRATION_BEFORE_HANDOFF (Terraform sets true), then this default.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": true, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- The daily AI cap: one source, the app profile (an administrator's value is kept).
UPDATE shared.llm_app_profile
   SET default_daily_budget_usd = 5.0, updated_at = now(), updated_by = 'migration:414'
 WHERE app = 'tripplanner' AND default_daily_budget_usd IS NULL;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('414', now(), 'S279 thresholds L5: TripPlanner settings in the registry (17 keys) and the TripPlanner daily '
                      'AI cap 5.0 USD on its app profile')
ON CONFLICT (version) DO NOTHING;

COMMIT;
