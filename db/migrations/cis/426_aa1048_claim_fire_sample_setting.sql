-- Migration 426: AA-1048 (S281 lane l13) — the size of the R1 firing sample of unlabelled claims, in the platform
-- settings registry (CIS 407; tech lead S279: a threshold, limit or cap is a setting on Platform › Settings, never a
-- code literal or an env var alone).
--
-- Why. The fresh pool of the two-step claim instrument (services/ground_truth/fresh_pool.py) labels the claims R1
-- (gpt-6-luna-openai extraction, prompt v1) fired on. The existing firing path (scripts/aa1048/r1_calibrate.py) fires
-- only on labelled claims, and the train split holds 126 of them with 8 violations: too few for the 20 violations and
-- 25 false positives the 50-claim subset needs. The new firing path (services/ground_truth/r1_fire.py) fires R1 on a
-- deterministic, salted, writer-proportional sample of UNLABELLED eligible claims, and the panel then labels only what
-- R1 fired. The size of that sample sets the paid calls of the run, so it is a setting. The run's cap stays the CIS 417
-- key cis.spend.instrument_eval_cap_usd and its trial size cis.spend.instrument_eval_trial_claims.
--
-- What:
--   1. One row in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), with its plain label and EN + VI guide (CIS 416):
--        cis.quality.claim_fire_sample_max   int claims 1..3000, default 600, maker-checker
--      Seeded with enforced = false: the code that reads it ships in the next PR of this lane (MIG-4), and the
--      settings-lint guard refuses an enforced key that no code reads. A later migration marks it enforced (with the
--      CIS 417 and 423 keys) once the firing code is on Dev.
--   2. Register 426.
--
-- Behaviour on apply. None for running code: no value row is seeded and nothing reads the key until the firing code is
-- deployed; then it resolves to its default until an administrator approves a change.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a config row INSERTed into an existing table.
-- MIG-4: a migration-only PR in the wave's CIS migration batch; applied on Dev by Infra Migration Apply when the job
-- tables are idle (ADR 0017a). DM-7.1: no new table.
--
-- Number. Renumbered to 426 in the S281 wave batch (424, 425 are the other lanes). If the owner main max + 1
-- differs at merge, renumber (git grep '426_' and '426' here, in tests/integration/test_aa1048_migration_426.py,
-- compiled_defaults.json and the seed-parity test).
--
-- Locks. One INSERT of one row (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
-- Idempotent (ON CONFLICT (key) DO NOTHING), one transaction, self-registering.
--
-- Rollback (a new forward migration, after the firing code is reverted): DELETE the key (no value row can exist before
-- the code reads it; a value row would have to go first).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$[
{"key": "cis.quality.claim_fire_sample_max", "app": "cis", "area": "quality", "label": "Claim checker test: statements checked to find flagged ones", "description": "The most unlabelled claims one R1 firing run may check (a deterministic, salted sample spread over the writers in proportion, drawn from claims on pieces no earlier claim-instrument evaluation touched). The fresh-pool sheet then draws its claims from the ones R1 fired on. It sets the paid calls of the firing run; the run's spending cap is cis.spend.instrument_eval_cap_usd. Read by the firing run from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "claims", "min_value": 1, "max_value": 3000, "allowed_values": null, "default_value": 600, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": false, "guide": {"en": {"what": "Before a test run of the claim checker (the AI check that flags statements in written content that the source material does not back up), the current checker looks at a sample of statements nobody has labelled yet, from content no earlier test used. A review panel then labels only the statements it flagged. This is how many statements go into that sample.", "raise": "More flagged statements come out, so the label sheet holds enough real problems and false alarms, but the run makes more paid AI calls.", "lower": "The run costs less, but it may flag too few statements, so the label sheet holds too few real problems for the test run.", "when": "Raise it when the label sheet ends up with fewer real problems than the test run needs; lower it when the sheet regularly holds far more flagged statements than it uses.", "example": "With the default of 600, the checker looks at up to 600 statements; at a flag rate of about one in five that gives about 120 flagged statements for the panel."}, "vi": {"what": "Trước khi chạy thử bộ kiểm tra câu khẳng định (bước AI đánh dấu những câu trong bài viết mà tài liệu nguồn không chứng minh được), bộ kiểm tra hiện tại xem một mẫu các câu chưa ai gán nhãn, lấy từ nội dung chưa lần thử nào dùng tới. Sau đó hội đồng duyệt chỉ gán nhãn những câu nó đã đánh dấu. Đây là số câu được đưa vào mẫu đó.", "raise": "Có nhiều câu bị đánh dấu hơn, nên bảng gán nhãn đủ lỗi thật và báo động nhầm, nhưng lần chạy gọi AI trả phí nhiều hơn.", "lower": "Lần chạy tốn ít tiền hơn, nhưng có thể đánh dấu quá ít câu, nên bảng gán nhãn có quá ít lỗi thật cho lần chạy thử.", "when": "Tăng khi bảng gán nhãn có ít lỗi thật hơn mức lần chạy thử cần; giảm khi bảng thường xuyên có nhiều câu bị đánh dấu hơn hẳn số câu được dùng.", "example": "Với mặc định 600, bộ kiểm tra xem tối đa 600 câu; với tỷ lệ đánh dấu khoảng một trên năm, hội đồng có khoảng 120 câu để gán nhãn."}}}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('426', now(), 'AA-1048: the R1 firing sample size of unlabelled claims')
ON CONFLICT (version) DO NOTHING;

COMMIT;
