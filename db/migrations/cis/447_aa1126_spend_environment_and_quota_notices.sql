-- Migration 447: AA-1126 (S283, tech lead AI spend policy of 17/11/2026) — the spend environment settings of CIS and
-- TripPlanner, and the tenant-facing "AI allowance used up" notices (Content studio and TripPlanner).
--
-- Why. The policy keeps hard caps on Dev and, on prod, lets only a tenant's plan quota stop its AI (the reason told
-- to the agency, with an upgrade path); app-wide fixed caps become alerts and a budget that cannot be read degrades
-- with a warning instead of blocking. One code path for every environment: going to prod is a settings change, not new
-- code (tech lead S279: a policy value is a setting on Platform › Settings, never a code literal or an env var alone).
-- Today a Content studio tenant whose AI budget is used up sees "Writing failed" and nothing tells the agency why, and
-- a TripPlanner agency whose monthly AI sessions are used up is told nothing at all (root
-- docs/audits/2026-11-17-S283-session/ai-caps-gap.md, slices G3 and L1-L4).
--
-- What.
--   1. Five rows in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), area "spend", platform scope, no env override, enforced.
--      Two spend environment keys, enum dev | prod, default dev (today's hard behaviour), impact high, maker-checker:
--        cis.spend.environment          read by shared/llm_client/tenant_budget.py (AA-CIS-App code PR): prod = a
--                                       tenant AI budget that cannot be read degrades with a warning (log + admin
--                                       bell) and the call goes on; dev = it fails closed as today (AA-642 A8).
--        tripplanner.spend.environment  read by AA-TripPlanner-Web through catalog.v_app_settings_v1 (CIS 415): prod =
--                                       the app-wide daily cap and the chat's app monthly cap only alert, and an
--                                       unreadable spend / quota degrades with a warning; dev = all of them block as
--                                       today. A tenant's own plan quota and AI budget stay hard in both.
--      Three TripPlanner cap keys that were an env var or a code constant (TP backend/config.py
--      TP_DAILY_SPEND_CAP_COMPOSE_USD / _SEARCH_USD, SPEND_NEAR_CAP_RATIO) and a mirrored CIS constant
--      (api/core/app_registry.py TP_STAGE_CAPS_USD / TP_NEAR_CAP_RATIO), so the Apps board shows what TripPlanner
--      enforces and an administrator edits it (tech lead S279: a threshold is a setting; S283: keep the admin pages
--      true to the code):
--        tripplanner.spend.stage_cap_compose_usd  usd 0..200 USD/day, default 0 = no stage cap (no env var is set on
--        tripplanner.spend.stage_cap_search_usd   the Lambdas today, so 0 is today's behaviour); impact high, maker-checker
--        tripplanner.spend.near_cap_pct           pct 50..99, default 80 (today's 0.8); impact medium, single
--      TripPlanner's daily app cap itself keeps its one source, the app profile (AI gateway > App profiles, CIS 414).
--      Each seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. The AI allowance notices and the TripPlanner degraded-check bell in shared.notifications, all written by CIS:
--        a. a partial UNIQUE index notifications_ai_allowance_once_uq on (tenant_id, event_type, entity_id) for the two
--           tenant-facing event types (target_roles {tenant}, read by the Content studio bell, GET /v1/notifications)
--           ai.allowance_used (CIS, when a tenant's AI budget stops its Content studio writing) and
--           tripplanner.ai_allowance_used (CIS, from TripPlanner's outbox event ai.allowance_used when an agency's AI
--           sessions quota stops new AI sessions). entity_id is '<kind>:<YYYY-MM>', so a notice is written at most once
--           per tenant, kind and month (INSERT ... ON CONFLICT DO NOTHING). Today's table has no row of either type.
--        b. AA-1126 L4: the admin bell platform.tripplanner.spend_degraded (platform.*: the admin bell only, never a
--           content role's; target_roles {admin}, the AA internal tenant), written by CIS from TripPlanner's outbox
--           event ai.spend_degraded (a spend, AI budget or AI sessions read failed under the prod spend rules and the
--           AI went on without it). A partial UNIQUE index notifications_tp_spend_degraded_once_uq on (tenant_id,
--           event_type, entity_id) with entity_id '<check>:<YYYY-MM-DD>' keeps it to one bell per check and UTC day.
--      TripPlanner gets NO grant on shared.notifications (S284 redesign): CIS 274 (the tenant notification policies)
--      and CIS 351 (tripplanner holds INSERT on shared.llm_call_log and nothing else of schema shared) forbid it, and
--      data standards DM-5.4 routes cross-app lineage through a producer outbox and a contract view. TripPlanner
--      writes the two events into its own outbox (tripplanner tp-034) and CIS pulls them through
--      tripplanner.v_ai_notices_v1 on the worker's ops tick (services/tripplanner_notices.py, AA-CIS-App code PR).
--   3. The CRM agency AI budget comes from the plan (slice L3): a feature crm.ai_budget_usd_monthly (product crm, limit,
--      usd_month) in shared.entitlement_feature, so it is a limit on the Plans page (PlanDrawer) and a per-tenant
--      override in Tenant 360 like crm.seats, and one plan_feature row on each live crm plan (crm.core, crm.pro) at
--      today's flat CRM default, 2 USD (crm.ai.budget_default_usd, crm-064): no agency's budget changes on apply. The
--      CRM projects it from the tenant.entitlements.v1 snapshot (AA-Partner crm_entitlement_pull) into its agency
--      budget and ceiling. The plan values are commercial: the tech lead sets them on the Plans page.
--   4. Register 447.
--
-- Behaviour on apply. None for running code: no value row is seeded (both keys read dev, today's behaviour), nothing
-- on main writes the three notice types, and the CRM plan rows equal the CRM default (2 USD) the CRM enforces today.
-- No grant or policy changes (shared.notifications keeps CIS 274's policies; tripplanner keeps CIS 351's set).
-- The code PRs (AA-CIS-App, AA-TripPlanner-Web, AA-Partner) start using them.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): config rows INSERTed into existing tables and
-- two indexes on an existing table. MIG-4: a migration-only PR, applied on Dev by Infra Migration
-- Apply when the job tables are idle (ADR 0017a), then the code PRs. DM-6.1: no personal data (the payload carries the
-- kind and the month only). DM-7.1: no new table. MIG-6: no SECURITY DEFINER routine.
--
-- Number. 446 (AA-1126 gateway spend controls) is the newest CIS migration on main (applied 17/11/2026), so this is
-- main max + 1. If the owner main max + 1 differs at merge, renumber (git grep '447_' and '447' here, in
-- tests/integration/test_aa1126_migration_447.py, compiled_defaults.json and docs/implementation-notes/AA-1126-l16-quota-ux.md).
--
-- Locks. INSERT of five definition rows; CREATE UNIQUE INDEX (two) (not CONCURRENTLY: one transaction; shared.notifications
-- holds a few hundred rows, a SHARE lock for milliseconds). lock_timeout 5s.
--
-- Rollback (a new forward migration, after the code PRs are reverted): DROP INDEX notifications_ai_allowance_once_uq and
-- notifications_tp_spend_degraded_once_uq; DELETE the five keys' value rows, then the keys.

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
{"key": "cis.spend.environment", "app": "cis", "area": "spend", "label": "AI spend rules: environment", "description": "Which AI spend rules CIS follows (tech lead policy S283). dev = hard caps everywhere: a tenant AI budget that cannot be read stops the tenant's Content studio writing until it can (AA-642 A8). prod = pay per use: only a tenant's plan allowance stops its AI; a budget that cannot be read degrades with a warning (log + admin bell) and the call goes on. Read by shared/llm_client/tenant_budget.py.", "value_type": "enum", "unit": null, "min_value": null, "max_value": null, "allowed_values": ["dev", "prod"], "default_value": "dev", "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "Which AI spend rules CIS follows. dev keeps every hard stop. prod follows the pay-per-use rules: only a tenant's own plan allowance stops its AI writing, and when a tenant's AI budget cannot be read the writing goes on with a warning to staff instead of stopping.", "raise": "prod (the looser choice): no tenant is stopped because a budget could not be read; staff get a bell instead.", "lower": "dev (the stricter choice): a budget that cannot be read stops that tenant's writing until it can be read.", "when": "Set prod on the production environment; keep dev on Dev and test environments. To check the prod behaviour on Dev, set prod, test, then set dev again.", "example": "With the default dev: the budget database read fails, so a tenant's rewrite waits and retries. With prod: the rewrite runs and an admin bell says the budget could not be read."}, "vi": {"what": "CIS áp dụng quy tắc chi tiêu AI nào. dev giữ mọi điểm chặn cứng. prod theo quy tắc trả theo mức dùng: chỉ hạn mức AI trong gói của chính tenant mới dừng việc viết bằng AI, và khi không đọc được ngân sách AI của tenant thì việc viết vẫn chạy kèm cảnh báo cho staff thay vì dừng.", "raise": "prod (lựa chọn nới hơn): không tenant nào bị dừng chỉ vì không đọc được ngân sách; staff nhận chuông cảnh báo.", "lower": "dev (lựa chọn chặt hơn): không đọc được ngân sách thì việc viết của tenant đó dừng tới khi đọc được.", "when": "Đặt prod trên môi trường production; giữ dev trên Dev và môi trường test. Muốn xem hành vi prod trên Dev thì đặt prod, kiểm thử, rồi đặt lại dev.", "example": "Với mặc định dev: đọc ngân sách lỗi thì bản viết lại của tenant chờ và chạy lại sau. Với prod: bản viết lại vẫn chạy và chuông admin báo không đọc được ngân sách."}}},
{"key": "tripplanner.spend.environment", "app": "tripplanner", "area": "spend", "label": "TripPlanner AI spend rules: environment", "description": "Which AI spend rules TripPlanner follows (tech lead policy S283). dev = hard caps everywhere: the app's daily AI cap (AI gateway > App profiles) and the planning chat's monthly app cap stop the AI of every agency, and a spend or quota that cannot be read stops it too. prod = pay per use: those app-wide caps only alert, a spend or quota that cannot be read degrades with a warning and the call goes on; an agency's own AI sessions quota and AI budget stay hard. Read by AA-TripPlanner-Web through catalog.v_app_settings_v1.", "value_type": "enum", "unit": null, "min_value": null, "max_value": null, "allowed_values": ["dev", "prod"], "default_value": "dev", "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "Which AI spend rules TripPlanner follows. dev keeps every hard stop, including the app-wide daily AI cap and the planning chat's monthly cap for the whole app. prod follows the pay-per-use rules: those app-wide caps only raise an alert, and a spend or quota that cannot be read lets the AI go on with a warning. Each agency's own AI sessions and AI budget from its plan always stop at their limit.", "raise": "prod (the looser choice): one busy agency can no longer use up the AI of every other agency; staff get alerts instead.", "lower": "dev (the stricter choice): the app-wide caps stop the AI of every agency once reached.", "when": "Set prod on the production environment; keep dev on Dev and test environments. To check the prod behaviour on Dev, set prod, test, then set dev again.", "example": "With the default dev: once the app's daily cap is reached, every planner shows places without AI-written days until the next day. With prod: the planners keep their AI and an alert is raised."}, "vi": {"what": "TripPlanner áp dụng quy tắc chi tiêu AI nào. dev giữ mọi điểm chặn cứng, kể cả trần AI theo ngày của cả app và trần theo tháng của chat lập kế hoạch cho cả app. prod theo quy tắc trả theo mức dùng: các trần cấp app đó chỉ cảnh báo, và khi không đọc được chi tiêu hay hạn mức thì AI vẫn chạy kèm cảnh báo. Số phiên AI và ngân sách AI theo gói của từng đại lý luôn dừng khi chạm hạn.", "raise": "prod (lựa chọn nới hơn): một đại lý đông khách không còn làm cạn AI của mọi đại lý khác; staff nhận cảnh báo.", "lower": "dev (lựa chọn chặt hơn): chạm trần cấp app là AI của mọi đại lý dừng.", "when": "Đặt prod trên môi trường production; giữ dev trên Dev và môi trường test. Muốn xem hành vi prod trên Dev thì đặt prod, kiểm thử, rồi đặt lại dev.", "example": "Với mặc định dev: chạm trần ngày của app thì mọi trang lập kế hoạch chỉ hiện địa điểm, không có ngày viết bằng AI, tới hôm sau. Với prod: các trang vẫn có AI và hệ thống phát cảnh báo."}}},
{"key": "tripplanner.spend.stage_cap_compose_usd", "app": "tripplanner", "area": "spend", "label": "TripPlanner daily AI cap: trip-day writing", "description": "TripPlanner's AI spend per UTC day on the AI-written trip days alone (tp_compose), on top of the app's daily cap (AI gateway > App profiles); both apply. 0 = no stage cap: only the app cap applies (today's behaviour). Under tripplanner.spend.environment = prod a reached cap only alerts. Read by AA-TripPlanner-Web backend/shared/spend_rules.py through catalog.v_app_settings_v1; the Apps board and the Spend page show it.", "value_type": "usd", "unit": "USD/day", "min_value": 0, "max_value": 200, "allowed_values": null, "default_value": 0, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "The most TripPlanner may spend on AI for the AI-written trip days in one UTC day, on top of the app's daily cap on AI gateway > App profiles. 0 means no separate cap for this stage.", "raise": "The trip-day writing keeps its AI longer on a busy day; AA's AI bill for it can grow up to the new cap.", "lower": "The trip-day writing falls back to its basic version earlier on a busy day, and leaves more of the app's daily cap to the other stages.", "when": "Set it when one stage uses up the app's daily cap and the other stages lose their AI; keep 0 while the app cap alone is enough. Under the prod spend rules it only raises an alert.", "example": "With the default 0 the trip-day writing has no cap of its own. With 3: once it has spent 3 USD in a UTC day, planners show places with plain day lines until the next UTC day, while search keeps its AI."}, "vi": {"what": "Số tiền AI tối đa TripPlanner được dùng cho các ngày lịch trình viết bằng AI trong một ngày UTC, thêm vào trần ngày của app ở AI gateway > App profiles. 0 nghĩa là bước này không có trần riêng.", "raise": "Phần viết ngày lịch trình giữ AI lâu hơn trong ngày đông khách; hoá đơn AI của AA cho bước này có thể tăng tới mức trần mới.", "lower": "Phần viết ngày lịch trình chuyển sang bản cơ bản sớm hơn trong ngày đông khách, và chừa nhiều trần ngày của app hơn cho các bước khác.", "when": "Đặt khi một bước dùng hết trần ngày của app làm các bước khác mất AI; giữ 0 khi trần của app là đủ. Với quy tắc chi tiêu prod thì trần này chỉ cảnh báo.", "example": "Với mặc định 0, phần viết ngày lịch trình không có trần riêng. Với 3: khi phần này đã tiêu 3 USD trong một ngày UTC, trang lập kế hoạch hiện địa điểm với dòng ngày đơn giản tới ngày UTC sau, còn tìm kiếm vẫn có AI."}}},
{"key": "tripplanner.spend.stage_cap_search_usd", "app": "tripplanner", "area": "spend", "label": "TripPlanner daily AI cap: free-text search", "description": "TripPlanner's AI spend per UTC day on the free-text search alone (tp_search_embed), on top of the app's daily cap (AI gateway > App profiles); both apply. 0 = no stage cap: only the app cap applies (today's behaviour). Under tripplanner.spend.environment = prod a reached cap only alerts. Read by AA-TripPlanner-Web backend/shared/spend_rules.py through catalog.v_app_settings_v1; the Apps board and the Spend page show it.", "value_type": "usd", "unit": "USD/day", "min_value": 0, "max_value": 200, "allowed_values": null, "default_value": 0, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "The most TripPlanner may spend on AI for the free-text search in one UTC day, on top of the app's daily cap on AI gateway > App profiles. 0 means no separate cap for this stage.", "raise": "The free-text search keeps its AI longer on a busy day; AA's AI bill for it can grow up to the new cap.", "lower": "The free-text search falls back to its basic version earlier on a busy day, and leaves more of the app's daily cap to the other stages.", "when": "Set it when one stage uses up the app's daily cap and the other stages lose their AI; keep 0 while the app cap alone is enough. Under the prod spend rules it only raises an alert.", "example": "With the default 0 the free-text search has no cap of its own. With 1: once it has spent 1 USD in a UTC day, search uses the keyword ranking until the next UTC day, while the trip-day writing keeps its AI."}, "vi": {"what": "Số tiền AI tối đa TripPlanner được dùng cho phần tìm kiếm bằng câu chữ tự do trong một ngày UTC, thêm vào trần ngày của app ở AI gateway > App profiles. 0 nghĩa là bước này không có trần riêng.", "raise": "Phần tìm kiếm giữ AI lâu hơn trong ngày đông khách; hoá đơn AI của AA cho bước này có thể tăng tới mức trần mới.", "lower": "Phần tìm kiếm chuyển sang bản cơ bản sớm hơn trong ngày đông khách, và chừa nhiều trần ngày của app hơn cho các bước khác.", "when": "Đặt khi một bước dùng hết trần ngày của app làm các bước khác mất AI; giữ 0 khi trần của app là đủ. Với quy tắc chi tiêu prod thì trần này chỉ cảnh báo.", "example": "Với mặc định 0, phần tìm kiếm không có trần riêng. Với 1: khi phần này đã tiêu 1 USD trong một ngày UTC, tìm kiếm dùng xếp hạng theo từ khoá tới ngày UTC sau, còn phần viết ngày lịch trình vẫn có AI."}}},
{"key": "tripplanner.spend.near_cap_pct", "app": "tripplanner", "area": "spend", "label": "TripPlanner AI cap warning at (% of a cap)", "description": "The share of a TripPlanner daily AI cap (the app's daily cap on AI gateway > App profiles, or a stage cap) at which TripPlanner raises its 'near cap' alert and the Apps board marks the cap near. Read by AA-TripPlanner-Web backend/shared/spend_rules.py and by the CIS Apps board.", "value_type": "pct", "unit": "%", "min_value": 50, "max_value": 99, "allowed_values": null, "default_value": 80, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "At what share of a TripPlanner daily AI cap staff get the 'near cap' alert, and the Apps board shows the cap as near.", "raise": "The warning comes later, closer to the cap, with less time to act.", "lower": "The warning comes earlier and more often on busy days.", "when": "Lower it when a cap is reached before anyone reacts to the warning; raise it when the warning fires on most ordinary days.", "example": "With the default 80 and a 5 USD daily cap: the alert is raised once TripPlanner has spent 4 USD in that UTC day."}, "vi": {"what": "Ở mức bao nhiêu phần trăm của một trần AI theo ngày của TripPlanner thì staff nhận cảnh báo 'gần chạm trần', và bảng Apps hiện trần đó là gần chạm.", "raise": "Cảnh báo đến muộn hơn, sát trần hơn, còn ít thời gian xử lý.", "lower": "Cảnh báo đến sớm hơn và nhiều hơn trong ngày đông khách.", "when": "Giảm khi trần bị chạm trước khi có ai kịp xử lý cảnh báo; tăng khi cảnh báo bật vào hầu hết các ngày bình thường.", "example": "Với mặc định 80 và trần ngày 5 USD: cảnh báo bật khi TripPlanner đã tiêu 4 USD trong ngày UTC đó."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- 2a. At most one AI allowance notice per tenant, kind and month (entity_id '<kind>:<YYYY-MM>').
CREATE UNIQUE INDEX IF NOT EXISTS notifications_ai_allowance_once_uq
    ON shared.notifications (tenant_id, event_type, entity_id)
 WHERE event_type IN ('ai.allowance_used', 'tripplanner.ai_allowance_used');

-- 2b. At most one TripPlanner "spend check degraded" staff bell per check and UTC day (entity_id '<check>:<YYYY-MM-DD>').
CREATE UNIQUE INDEX IF NOT EXISTS notifications_tp_spend_degraded_once_uq
    ON shared.notifications (tenant_id, event_type, entity_id)
 WHERE event_type = 'platform.tripplanner.spend_degraded';

-- 3. The CRM agency AI budget per plan (L3).
INSERT INTO shared.entitlement_feature (feature_key, product, value_kind, unit, description)
VALUES ('crm.ai_budget_usd_monthly', 'crm', 'limit', 'usd_month',
        'USD a month of CRM AI drafting this plan gives the agency (the CRM agency AI budget and its ceiling; '
        'AA-Partner crm_entitlement_pull projects it, AA-1126 L3, CIS 447). No limit = the CRM platform settings.')
ON CONFLICT (feature_key) DO NOTHING;

INSERT INTO shared.plan_feature (plan_key, feature_key, limit_value, updated_by)
SELECT p.plan_key, 'crm.ai_budget_usd_monthly', 2, 'migration:447'
  FROM shared.plan p
 WHERE p.product = 'crm' AND p.retired_at IS NULL
ON CONFLICT (plan_key, feature_key) DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.entitlement_feature WHERE feature_key = 'crm.ai_budget_usd_monthly') THEN
        RAISE EXCEPTION 'migration 447: crm.ai_budget_usd_monthly is not in the feature catalogue';
    END IF;
    IF (SELECT count(*) FROM shared.setting_definition
         WHERE key IN ('cis.spend.environment', 'tripplanner.spend.environment',
                       'tripplanner.spend.stage_cap_compose_usd', 'tripplanner.spend.stage_cap_search_usd',
                       'tripplanner.spend.near_cap_pct')) <> 5 THEN
        RAISE EXCEPTION 'migration 447: the five spend keys are not registered';
    END IF;
    IF to_regrole('tripplanner') IS NOT NULL
       AND has_table_privilege('tripplanner', 'shared.notifications', 'SELECT, INSERT, UPDATE, DELETE') THEN
        RAISE EXCEPTION 'migration 447: tripplanner holds a privilege on shared.notifications (CIS 351: none)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('447', now(), 'AA-1126: spend environment settings (CIS, TripPlanner), the TripPlanner cap settings, the once-only indexes of the AI allowance notices and the TripPlanner degraded-check bell')
ON CONFLICT (version) DO NOTHING;

COMMIT;
