-- Migration 487: AA-1154 (S292, phase A1 of the CIS admin assistant) — the AI gateway stage `ops_assist`, its own
-- monthly spend cap, and the four A1 choices as settings.
--
-- Why. Phase A0 (CIS 481, code PR 149c844c) turns a Needs-attention item of the Ecosystem status page into ranked action
-- cards by rule, with no model call. Phase A1 lets a model rank and explain those cards (and phrase the "what changed
-- in the last hour" look-up) through the existing AI gateway. Tech lead decisions S285 (root
-- docs/audits/2026-11-19-S285-session/advisory-ai-assistants.md sections 5, 6 and 9):
--   AI2  Claude Haiku 5.5 by default, Sonnet 5.5 only on "Deep analysis"; the Anthropic API first, then acc1 (the
--        route control's own provider order decides, nothing here names a connection);
--   AI3  a cap of 10 USD a month as its own spend row for the stage, hard stop, editable on AI gateway > Budgets;
--   AI4  the model has no tools: it only ranks the rule-made cards and explains them;
--   AI6  an automatic quick analysis once per SEV1 / SEV2 incident;
--   kill switch = shared.llm_role_config.is_active of the stage (no new setting).
-- Tech lead S279: every choice that decides cost or what a person sees is a setting (maker-checker, audited), never a
-- code literal: which severities trigger the automatic (paid) analysis, the Deep analysis model, how long an item must
-- stay away before it counts as a new incident, and the windows the look-up panel offers.
-- The code (api/services/ops_assist/explain.py) makes no model call while either gateway row below is missing: a
-- stage with no row would run on the gateway's defaults, and a stage with no hard-stop cap has no ceiling.
--
-- What:
--   1. One shared.llm_role_config row:
--        stage ops_assist, role writer (the generate seam: the call writes a ranking and a short explanation; the
--        ledger role `decide` is the Jev seam, ADR 0009 D3, and the row CHECK allows writer / judge / validate /
--        embed only), provider claude, model_id haiku-5-5 (the Converse key of migration 259; its deployments and their
--        order are the route control's), account_route NULL (the column is ignored for every value but acc3, AA-998),
--        no fallback model (the haiku-5-5 deployments already span two failure domains, the Anthropic API and Bedrock;
--        an admin adds a fallback on AI gateway > Routing), no shadow, allowed_scopes {aws_only, vendor_direct} (the
--        stage sends aggregated operations numbers, keys and error classes, so the Anthropic API may serve it: AI2),
--        route_deadline_s 25 (the call answers a click and must end inside the API Gateway's 30 s), degrade_mode
--        basic_narration (when the stage cannot run the page shows the rule-made cards and Summary without the
--        model's words), pii_class content, free_text TRUE: the evidence carries one free text, the item detail (a
--        job's last error, an alarm description, an ECS rollout reason), which can quote an e-mail, a phone, a token
--        or a connection string; the gateway's free-text scrub (shared/llm_client/free_text_scrub.py, CIS 451) then
--        redacts every prompt of the stage before any attempt and refuses the call when it cannot (fail closed). The
--        code also scrubs that detail before it builds the prompt (defence in depth). The CHECK
--        llm_role_config_free_text_pii_check allows it (pii_class is content).
--   2. One shared.spend_budget row: provider llm, scope stage:ops_assist, per_month_usd 10.00, hard_stop true,
--      alert_pct 80, no day or run cap. shared/llm_client/central_budget.py refuses a call of the stage that would pass
--      the month's cap (0 USD ledger row, status refused, class budget); the bell at 80 %.
--   3. Four rows in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py
--      into shared/settings/compiled_defaults.json in this PR), app cis, area "ops", scope platform, maker-checker, no
--      evidence, no env override, enforced (shared/ops_assist_settings.py names every key, the settings-lint reader
--      check):
--        cis.ops.assist_auto_severities        list, each one of sev1, sev2, sev3; default [sev1, sev2] (AI6); an
--                                              empty list = no automatic analysis; impact medium (each one is a
--                                              paid call)
--        cis.ops.assist_auto_incident_gap_min  int minutes 30-2880, default 240: an item the automatic analysis has
--                                              not seen open for this long counts as a new incident next time
--                                              (never shorter than the card lifetime, cis.ops.assist_card_ttl_min)
--        cis.ops.assist_deep_model             enum of the Claude chat keys of the catalog (haiku-5-5, sonnet-5-5,
--                                              opus-5-5), default sonnet-5-5 (AI2); the code checks the key is still
--                                              an enabled catalog model before each Deep call and uses the stage
--                                              route when it is not; impact medium
--        cis.ops.assist_lookup_windows_min     list of minutes, each one of 15, 30, 60, 120, 180, 360, 720, 1440,
--                                              default [15, 60, 360, 1440] (the look-up panel's choices; the API
--                                              refuses any other window); impact low
--      Each seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   4. Register 487.
--
-- Idempotent: ON CONFLICT DO NOTHING keeps a row an admin already edited (a lowered cap, a switched-off stage, a
-- setting); the guard checks the gateway rows exist with a hard-stop month cap.
--
-- Class: contract (root ADR 0017 d3: INSERTs into existing routing, budget and settings tables), no directive line.
-- MIG-4: this migration-only PR ships first (Infra copy, then Infra Migration Apply once every job table is idle, ADR
-- 0017a); the A1 code PR follows. No readiness raise: the code reads both gateway rows before every model call and
-- answers with the rule-made cards while they are missing. DM-6.1: no personal data. DM-7.1: no new table.
--
-- Number. Owner main max + 1 once CIS 484 (AA-1169) and 485-486 (AA-1142) of the same S292 CIS migration batch have
-- landed: this file ships in that batch, after them. If the owner main max + 1 differs at merge, renumber: git grep
-- '487_' and "'487'"
-- (this file, tests/integration/test_aa1154_migration_487.py, compiled_defaults.json's _generated line,
-- docs/implementation-notes/AA-1154.md).
--
-- Locks. Two single-row INSERTs and one INSERT ... ON CONFLICT of four rows (the definition guard trigger allows the
-- file's role, cis_owner). lock_timeout 5s.
--
-- Rollback (a new forward migration, after the A1 code PR is reverted):
--   DELETE FROM shared.spend_budget WHERE provider IN ('llm') AND scope IN ('stage:ops_assist');
--   DELETE FROM shared.llm_role_config WHERE stage IN ('ops_assist');
--   then the four keys' value rows, then the keys.
--
-- X1. One BEGIN … COMMIT block, no role switch (Migration Apply runs cis/ files as cis_owner).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    col text;
BEGIN
    FOREACH col IN ARRAY ARRAY['allowed_scopes', 'route_deadline_s', 'degrade_mode', 'pii_class', 'free_text'] LOOP
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'shared'
                          AND table_name = 'llm_role_config' AND column_name = col) THEN
            RAISE EXCEPTION 'migration 487: shared.llm_role_config.% is missing (apply 311, 320, 326, 373, 451 first)',
                col;
        END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'shared'
                      AND table_name = 'spend_budget' AND column_name = 'per_month_usd') THEN
        RAISE EXCEPTION 'migration 487: shared.spend_budget.per_month_usd is missing (apply 340 first)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog WHERE model_key = 'haiku-5-5' AND enabled) THEN
        RAISE EXCEPTION 'migration 487: haiku-5-5 is not an enabled catalog model (migration 259)';
    END IF;
END $$;

INSERT INTO shared.llm_role_config
    (stage, role, provider, model_id, account_route, is_active, fallback_model_ids, shadow_model_id,
     shadow_sample_pct, allowed_scopes, route_deadline_s, degrade_mode, pii_class, free_text, updated_by)
VALUES
    ('ops_assist', 'writer', 'claude', 'haiku-5-5', NULL, true, ARRAY[]::text[], NULL, 0,
     ARRAY['aws_only', 'vendor_direct']::text[], 25, 'basic_narration', 'content', true, 'migration-487-aa1154')
ON CONFLICT (stage) DO NOTHING;

INSERT INTO shared.spend_budget
    (provider, scope, per_run_usd, per_day_usd, per_month_usd, hard_stop, alert_pct, updated_by)
VALUES
    ('llm', 'stage:ops_assist', NULL, NULL, 10.00, true, 80, 'migration-487-aa1154')
ON CONFLICT (provider, scope) DO NOTHING;

-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$
[
{"key": "cis.ops.assist_auto_severities", "app": "cis", "area": "ops", "label": "Assistant: severities analysed automatically", "description": "On the CIS admin assistant (Ecosystem status page; api/services/ops_assist/analysis.py) an open Needs-attention item or assistant signal of one of these severities gets one quick AI analysis per incident while the status page is open (one paid call of the AI gateway stage ops_assist, inside its month cap); every other item waits for a click on Analyse. Each one of sev1, sev2 or sev3. An empty list turns the automatic analysis off. The S285 advisory (AI6) sets SEV1 and SEV2. Default [sev1, sev2].", "value_type": "list", "unit": null, "min_value": null, "max_value": null, "allowed_values": ["sev1", "sev2", "sev3"], "default_value": ["sev1", "sev2"], "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "Which alert severities get an AI analysis by themselves, once per incident, while the status page is open.", "raise": "Adding sev3 analyses minor alerts too: more paid calls, the month cap of the assistant is reached sooner.", "lower": "Fewer automatic calls; the other alerts are analysed only when someone clicks Analyse.", "when": "Keep SEV1 and SEV2; empty it to stop automatic calls when the month cap runs low.", "example": "With the default [sev1, sev2], a SEV2 alert gets one analysis when it opens; a SEV3 alert waits for a click."}, "vi": {"what": "Những mức cảnh báo nào được AI tự phân tích, mỗi sự cố một lần, khi trang trạng thái đang mở.", "raise": "Thêm sev3 thì cả cảnh báo nhẹ cũng được phân tích: nhiều lần gọi trả phí hơn, trần tháng của trợ lý chạm sớm hơn.", "lower": "Ít lần gọi tự động hơn; cảnh báo còn lại chỉ phân tích khi có người bấm Analyse.", "when": "Giữ SEV1 và SEV2; để trống khi trần tháng sắp hết để dừng gọi tự động.", "example": "Với mặc định [sev1, sev2], cảnh báo SEV2 được phân tích một lần khi mở; cảnh báo SEV3 chờ người bấm."}}},
{"key": "cis.ops.assist_auto_incident_gap_min", "app": "cis", "area": "ops", "label": "Assistant: minutes away before an alert is a new incident", "description": "On the CIS admin assistant (Ecosystem status page; api/services/ops_assist/analysis.py) the automatic analysis keeps one marker per alert while it stays open (renewed each time the status page asks, every few minutes). An alert the automatic analysis has not seen open for this many minutes counts as a new incident the next time it is open, and gets one new automatic analysis. Never shorter than the card lifetime (cis.ops.assist_card_ttl_min). Default 240.", "value_type": "int", "unit": "minutes", "min_value": 30, "max_value": 2880, "allowed_values": null, "default_value": 240, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How long an alert must be gone (or unwatched) before its return counts as a new incident with a new automatic AI analysis.", "raise": "Fewer repeat analyses of an alert that comes and goes; a real new incident on the same alert may reuse the old analysis until someone clicks Analyse again.", "lower": "An alert that returns gets a fresh automatic analysis sooner: more paid calls for flapping alerts.", "when": "Keep a few hours; raise it if a flapping alert keeps paying for new analyses.", "example": "With the default 240, an alert that closes at 10:00 and opens again at 12:00 keeps its analysis; opening again at 15:00 gets a new one."}, "vi": {"what": "Cảnh báo phải vắng (hoặc không ai xem) bao lâu thì lần quay lại được tính là sự cố mới và được AI tự phân tích lại.", "raise": "Ít phân tích lặp cho cảnh báo chập chờn; sự cố mới thật trên cùng cảnh báo có thể dùng lại phân tích cũ tới khi có người bấm Analyse lại.", "lower": "Cảnh báo quay lại được phân tích tự động mới sớm hơn: nhiều lần gọi trả phí hơn với cảnh báo chập chờn.", "when": "Giữ vài giờ; tăng nếu một cảnh báo chập chờn cứ tốn tiền phân tích mới.", "example": "Với mặc định 240, cảnh báo đóng lúc 10:00 và mở lại lúc 12:00 giữ phân tích cũ; mở lại lúc 15:00 thì được phân tích mới."}}},
{"key": "cis.ops.assist_deep_model", "app": "cis", "area": "ops", "label": "Assistant: model of Deep analysis", "description": "On the CIS admin assistant (Ecosystem status page, the Analyse drawer; api/services/ops_assist/explain.py) \"Deep analysis\" asks this catalog model on the same AI gateway stage ops_assist (same kill switch, data scope and month cap); the quick analysis uses the stage route (AI gateway > Routing). Before each call the code checks the model is still an enabled catalog model and uses the stage route when it is not. The S285 advisory (AI2) sets Sonnet 5.5. Default sonnet-5-5.", "value_type": "enum", "unit": null, "min_value": null, "max_value": null, "allowed_values": ["haiku-5-5", "sonnet-5-5", "opus-5-5"], "default_value": "sonnet-5-5", "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "Which AI model answers when someone clicks Deep analysis on an alert.", "raise": "A larger model (opus-5-5) reasons better on hard incidents and costs more per click.", "lower": "A smaller model (haiku-5-5) is cheaper and faster, and Deep analysis then adds little over the quick one.", "when": "Keep sonnet-5-5; change it when a newer model is added to the catalog or this one is retired.", "example": "With the default sonnet-5-5, Deep analysis costs a few cents per click; a disabled model falls back to the quick route."}, "vi": {"what": "Model AI nào trả lời khi có người bấm Phân tích sâu trên một cảnh báo.", "raise": "Model lớn hơn (opus-5-5) suy luận tốt hơn với sự cố khó và tốn tiền hơn mỗi lần bấm.", "lower": "Model nhỏ hơn (haiku-5-5) rẻ và nhanh hơn, khi đó Phân tích sâu không hơn bản nhanh là mấy.", "when": "Giữ sonnet-5-5; đổi khi danh mục có model mới hơn hoặc model này bị ngừng.", "example": "Với mặc định sonnet-5-5, Phân tích sâu tốn vài cent mỗi lần bấm; model bị tắt thì dùng tuyến nhanh."}}},
{"key": "cis.ops.assist_lookup_windows_min", "app": "cis", "area": "ops", "label": "Assistant: look-up windows offered (minutes)", "description": "On the CIS admin assistant (Ecosystem status page, the \"What changed in the last ...\" look-up; api/services/ops_assist/lookup.py) the windows the panel offers, in minutes, each one of 15, 30, 60, 120, 180, 360, 720 or 1440. The API refuses any other window (GET /admin/ops-assist/changes). The answer from the records is free; Phrase with AI is one paid call. Default [15, 60, 360, 1440].", "value_type": "list", "unit": "minutes", "min_value": null, "max_value": null, "allowed_values": [15, 30, 60, 120, 180, 360, 720, 1440], "default_value": [15, 60, 360, 1440], "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The time windows the \"What changed\" look-up offers on the status page.", "raise": "More or longer windows: a long window lists more changes and a phrased answer reads more rows.", "lower": "Fewer choices keep the panel short.", "when": "Add 180 (3 hours) if incidents usually start a few hours after a change.", "example": "With the default [15, 60, 360, 1440], the panel offers 15 minutes, 1 hour, 6 hours and 24 hours."}, "vi": {"what": "Các khoảng thời gian mà ô tra cứu \"Điều gì đã thay đổi\" trên trang trạng thái đưa ra.", "raise": "Nhiều hoặc dài hơn: khoảng dài liệt kê nhiều thay đổi hơn và câu trả lời AI đọc nhiều dòng hơn.", "lower": "Ít lựa chọn giữ ô tra cứu gọn.", "when": "Thêm 180 (3 giờ) nếu sự cố thường bắt đầu vài giờ sau một thay đổi.", "example": "Với mặc định [15, 60, 360, 1440], ô tra cứu đưa ra 15 phút, 1 giờ, 6 giờ và 24 giờ."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.llm_role_config WHERE stage = 'ops_assist' AND role = 'writer') THEN
        RAISE EXCEPTION 'migration 487: the ops_assist stage row is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.spend_budget WHERE provider = 'llm' AND scope = 'stage:ops_assist'
                      AND per_month_usd IS NOT NULL) THEN
        RAISE EXCEPTION 'migration 487: the stage:ops_assist month cap is missing';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('487', now(), 'AA-1154 A1: AI gateway stage ops_assist (writer, haiku-5-5, deadline 25 s, free-text scrub), '
                      'its own month cap llm / stage:ops_assist 10 USD hard stop, and four assistant settings')
ON CONFLICT (version) DO NOTHING;

COMMIT;
