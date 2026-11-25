-- Migration 491: AA-1154 (S293, phase A2 of the CIS admin assistant) — the three A2 choices as settings.
--
-- Why. Phase A2 checks each action card a person ran (acp_shared.ops_assist_run, CIS 490) at fixed minutes after it
-- was marked done, shows the hit rate of the last days on the status page and in the OPS-12 digest, and makes the
-- assistant's card build fail soft (a clear "try again" instead of a hang while a deploy replaces the API tasks: one
-- 503 and one hang of more than 5 minutes were seen on GET .../cards during the S292 deploy). Tech lead S279: every
-- window, limit and timeout is a setting (maker-checker, audited), never a code literal.
--
-- What:
--   1. Three rows in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py
--      into shared/settings/compiled_defaults.json in this PR), app cis, area "ops", scope platform, maker-checker, no
--      evidence, no env override, enforced (shared/ops_assist_settings.py names every key, the settings-lint reader
--      check):
--        cis.ops.assist_check_after_min   list of minutes, each one of 5, 10, 15, 20, 30, 45, 60, 90, 120; default
--                                         [10, 30] (the S285 advisory's +10 / +30); the 5-minute status sampler
--                                         takes each checkpoint at its first tick after it is due; the last one gives
--                                         the run's verdict; impact low
--        cis.ops.assist_digest_days       int days 1-90, default 7: the days of the hit rate the status page and the
--                                         daily OPS-12 digest show ("the last 7 days"); impact low
--        cis.ops.assist_build_timeout_s   int seconds 5-25, default 20: the longest the assistant may take to read
--                                         the evidence of one item (the status page build and the gateway reads)
--                                         before it answers 503 "try again" (below the API Gateway's 30 s, so the
--                                         page never waits on a request the gateway already dropped); impact low
--      Each seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 491.
--
-- Idempotent: ON CONFLICT DO NOTHING keeps a definition an admin already edited.
--
-- Class: contract (root ADR 0017 d3: INSERTs into the existing settings table), no directive line. MIG-4: this
-- migration-only PR ships first with CIS 490 (Infra copy, then Infra Migration Apply once every job table is idle,
-- ADR 0017a); the A2 code PR follows. No readiness raise: shared.settings serves the compiled defaults until the rows
-- exist, and the code answers "not set up yet" while acp_shared.ops_assist_run is missing. DM-6.1: no personal data.
-- DM-7.1: no new table here.
--
-- Number. Owner main max + 1 after CIS 490 of the same batch. If it differs at merge, renumber: git grep '491_' and
-- "'491'" (this file, tests/integration/test_aa1154_migration_490_491.py, compiled_defaults.json's _generated line,
-- docs/implementation-notes/AA-1154.md).
--
-- Locks. One INSERT ... ON CONFLICT of three rows (the definition guard trigger allows the file's role, cis_owner).
-- lock_timeout 5s.
--
-- Rollback (a new forward migration, after the A2 code PR is reverted): delete the three keys' value rows, then the
-- keys.
--
-- X1. One BEGIN … COMMIT block, no role switch (Migration Apply runs cis/ files as cis_owner).

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
{"key": "cis.ops.assist_check_after_min", "app": "cis", "area": "ops", "label": "Assistant: minutes after a card is done when its outcome is checked", "description": "On the CIS admin assistant (Ecosystem status page, the Analyse drawer; api/services/ops_assist/outcome.py) a card a person marks as done is checked again at each of these minutes: the 5-minute status sampler (job kind ops_status_sample) reads the card's measures again and records hit, miss or unclear against what the card predicted. The last checkpoint gives the card's verdict, which feeds the hit rate and the action's track record. Each one of 5, 10, 15, 20, 30, 45, 60, 90 or 120; a run keeps the checkpoints it was recorded with. The S285 advisory sets +10 and +30. Default [10, 30].", "value_type": "list", "unit": "minutes", "min_value": null, "max_value": null, "allowed_values": [5, 10, 15, 20, 30, 45, 60, 90, 120], "default_value": [10, 30], "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "When, after someone marks an action card as done, the assistant checks whether what the card predicted really happened.", "raise": "Later checkpoints give slow effects (a queue draining, spend falling) time to show; the verdict arrives later.", "lower": "Earlier checkpoints give a verdict sooner but may call a slow effect a miss.", "when": "Keep 10 and 30 minutes; add 60 if most actions take longer to show their effect.", "example": "With the default [10, 30], a wave paused at 10:00 is checked at about 10:10 and 10:30; the 10:30 check decides hit or miss."}, "vi": {"what": "Sau khi có người đánh dấu đã làm một thẻ hành động, bao nhiêu phút thì trợ lý kiểm lại điều thẻ dự đoán có xảy ra thật không.", "raise": "Mốc kiểm muộn hơn cho hiệu ứng chậm (hàng đợi rút dần, chi phí giảm) thời gian hiện ra; kết luận có muộn hơn.", "lower": "Mốc kiểm sớm hơn cho kết luận sớm hơn nhưng có thể coi hiệu ứng chậm là trượt.", "when": "Giữ 10 và 30 phút; thêm 60 nếu phần lớn hành động cần lâu hơn mới thấy tác dụng.", "example": "Với mặc định [10, 30], wave tạm dừng lúc 10:00 được kiểm khoảng 10:10 và 10:30; lần kiểm 10:30 quyết định đúng hay trượt."}}},
{"key": "cis.ops.assist_digest_days", "app": "cis", "area": "ops", "label": "Assistant: days of the hit rate shown", "description": "On the CIS admin assistant (Ecosystem status page and the daily OPS-12 digest; api/services/ops_assist/outcome.py) the hit rate \"right n of m\" counts the checked action cards of this many days back (a card with an unclear outcome is not counted). The S285 advisory reports it weekly. Default 7.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 90, "allowed_values": null, "default_value": 7, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How many days back the assistant's hit rate (right n of m checked cards) reaches on the status page and in the digest.", "raise": "A longer period counts more cards: a steadier number that reacts slowly to a change of rules.", "lower": "A shorter period shows recent changes sooner but often has too few cards to mean much.", "when": "Keep a week; raise it to 30 while incidents are rare (Dev has a few a month).", "example": "With the default 7, the digest of Monday counts the cards checked since the Monday before."}, "vi": {"what": "Tỉ lệ đúng của trợ lý (đúng n trên m thẻ đã kiểm) trên trang trạng thái và trong digest tính lùi bao nhiêu ngày.", "raise": "Khoảng dài hơn đếm nhiều thẻ hơn: con số ổn định hơn nhưng chậm phản ánh khi đổi luật.", "lower": "Khoảng ngắn hơn thấy thay đổi gần đây sớm hơn nhưng thường quá ít thẻ để có ý nghĩa.", "when": "Giữ một tuần; tăng lên 30 khi sự cố còn hiếm (Dev chỉ vài lần mỗi tháng).", "example": "Với mặc định 7, digest thứ Hai đếm các thẻ được kiểm từ thứ Hai tuần trước."}}},
{"key": "cis.ops.assist_build_timeout_s", "app": "cis", "area": "ops", "label": "Assistant: seconds to read the evidence before asking to try again", "description": "On the CIS admin assistant (Ecosystem status page, the Analyse drawer; api/routers/admin_ops_assist.py) the longest the assistant may take to read the evidence of one item (the status page build, the AI gateway breaker and ledger, jobs, waves) before it answers 503 with a clear \"try again\" message instead of keeping the page waiting (one hang of more than 5 minutes was seen while a deploy replaced the API tasks). Kept below the API Gateway's 30 s. Default 20.", "value_type": "int", "unit": "seconds", "min_value": 5, "max_value": 25, "allowed_values": null, "default_value": 20, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How long the assistant waits for its evidence before it tells the page to try again.", "raise": "A slow source (CloudWatch, a health check of another app) has more time to answer; the page waits longer before saying so.", "lower": "The page says \"try again\" sooner, also when a source was only a little slow.", "when": "Keep 20 seconds; lower it if the drawer often waits during deploys.", "example": "With the default 20, a status page build stuck behind a deploy ends after 20 seconds with \"The assistant could not read the evidence in time; try again in a minute\"."}, "vi": {"what": "Trợ lý chờ đọc bằng chứng tối đa bao lâu trước khi báo trang thử lại.", "raise": "Nguồn chậm (CloudWatch, kiểm sức khoẻ app khác) có thêm thời gian trả lời; trang chờ lâu hơn mới báo.", "lower": "Trang báo \"thử lại\" sớm hơn, kể cả khi nguồn chỉ chậm một chút.", "when": "Giữ 20 giây; giảm nếu ngăn kéo thường phải chờ lúc deploy.", "example": "Với mặc định 20, lần dựng trang trạng thái bị kẹt sau một lần deploy kết thúc sau 20 giây kèm thông báo thử lại sau một phút."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('491', now(), 'AA-1154 A2: three assistant settings (checkpoints after a card is done, days of the hit rate, '
                      'evidence read timeout)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
