-- Migration 418: AA-1077 (S280) — the switch of the blog lengthening repair in the platform settings registry
-- (CIS 407; tech lead S279: a threshold, limit, cap or policy value is a setting on Platform › Settings, never a code
-- literal or an env var alone).
--
-- Why. After the S279 fixes (one length floor in the registry, the F4 re-check after the normalizer, the T7 Blog seed
-- floor sized from the F4 floor) the main reason blog pieces are held is still F4 length: 25 of the 37 held audit-tenant
-- blogs are too short. The extend repair exists (services/acp_content_writing/length_extend.py: after the attempt-2
-- repair round a blog under the floor gets new paragraphs in its thinnest sections from its own untold seed facts, each
-- checked in code, then every gate runs again), but its switch is the worker env var T9_LENGTH_EXTEND (default off), so
-- the tech lead cannot turn it on from the admin page, and a trial cannot turn it on for one audit tenant: the tenant
-- studio routes never pass a job's trial_flags. This key is that switch.
--
-- What:
--   1. One row in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR):
--        cis.t9.blog_length_extend   enum off | on, default off, scope platform+tenant, impact high, maker-checker,
--                                    evidence required, env override T9_LENGTH_EXTEND (the old switch; an emergency
--                                    override for one release, badge on the page), enforced
--      platform+tenant: a tenant value turns the repair on for one agency only (the audit-tenant trial), the platform
--      value for everyone. The seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--      Enforced: services/quality/settings_keys.T9_BLOG_LENGTH_EXTEND names the key in this PR (the settings-lint reader
--      check), and every reader falls back to the default off = main's path until the code PR reads it.
--   2. Register 418.
--
-- Behaviour on apply. None for running code: no value row is seeded, the deployed code still reads the env var (unset
-- on Dev = off), and after the code PR the key resolves to its default off (= main) until an administrator approves a
-- value.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): config rows INSERTed into an existing table.
-- MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a), then the
-- code PR. DM-7.1: no new table.
--
-- Number. 417 is the newest CIS migration on main (14/11/2026). If the owner main max + 1 differs at merge, renumber
-- (git grep '418_' and '418' here, in tests/integration/test_aa1077_migration_418.py, compiled_defaults.json and the
-- implementation notes docs/implementation-notes/AA-1077.md).
--
-- Locks. One INSERT of one row (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
-- Idempotent (ON CONFLICT (key) DO NOTHING), one transaction, self-registering.
--
-- Rollback (a new forward migration, after the code PR is reverted): DELETE the key's value rows first, then the key.

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
{"key": "cis.t9.blog_length_extend", "app": "cis", "area": "content", "label": "Blog length: lengthen a short blog before holding it", "description": "off: a blog still under the length minimum after its repair round is held for length (the full rewrite path, unchanged). on: a blog under the minimum after its repair round gets one lengthening repair first: one new paragraph in each of up to three of its thinnest sections, written only from facts of its own source that the blog does not use yet; each paragraph is checked in code (no new number, time, heading, list, question or call to action, no mention of where a fact comes from) and then every quality check runs again on the whole text. A tenant value turns it on for one agency only (a trial on an audit tenant); the platform value for everyone. The env var stays an emergency override for one release (a badge on this page). Evidence required: a $0 replay of stored pieces, or a trial run whose cost is read from the call ledger.", "value_type": "enum", "unit": null, "min_value": null, "max_value": null, "allowed_values": ["off", "on"], "default_value": "off", "scope_kind": "platform+tenant", "impact": "high", "approval": "maker_checker", "evidence_required": true, "env_override": "T9_LENGTH_EXTEND", "cache_s": 30, "enforced": true, "guide": {"en": {"what": "Whether a blog that is still shorter than the blog length minimum after its repair round gets one lengthening pass before it is held. The pass adds one paragraph to each of up to three of its thinnest sections, using only facts from its own source material that the blog does not use yet; every added paragraph is checked, then all the quality checks run again on the whole blog.", "raise": "Turn on: fewer blogs are held for being too short. Each short blog costs one more writer call (one or two US cents), and an added paragraph can trip another check, which then holds the blog as before. A blog whose source has no unused fact left is still held.", "lower": "Turn off: a short blog keeps the old path, one full rewrite and a hold for length if it is still short. No extra writer call.", "when": "Turn it on for one test agency first and compare how many of its blogs are held for being too short; turn it on for everyone when that test shows fewer length holds and no new holds from other checks. Turn it off if added paragraphs start causing other holds. The change form asks for evidence: a free replay of stored blogs, or the test run with its cost.", "example": "With the default of off: a blog of 4,200 characters after its repair round is held for being too short (the minimum is 4,700 characters by default). With on, it first gets new paragraphs from facts it has not used, and is held only if it is still short."}, "vi": {"what": "Một bài blog vẫn ngắn hơn độ dài tối thiểu sau vòng sửa có được kéo dài thêm một lần trước khi bị giữ lại hay không. Lần kéo dài thêm một đoạn vào tối đa ba phần mỏng nhất của bài, chỉ dùng những dữ kiện trong tư liệu nguồn của chính bài mà bài chưa dùng tới; mỗi đoạn thêm vào đều được kiểm tra, rồi mọi bước kiểm chất lượng chạy lại trên toàn bài.", "raise": "Bật: ít blog bị giữ vì quá ngắn hơn. Mỗi bài ngắn tốn thêm một lần gọi bộ viết (một đến hai xu Mỹ), và một đoạn thêm vào có thể vướng một bước kiểm khác, khi đó bài vẫn bị giữ như trước. Bài mà nguồn không còn dữ kiện nào chưa dùng thì vẫn bị giữ.", "lower": "Tắt: bài ngắn đi theo đường cũ, viết lại toàn bài một lần và bị giữ vì độ dài nếu vẫn còn ngắn. Không tốn thêm lần gọi bộ viết nào.", "when": "Bật cho một đại lý thử nghiệm trước và so số blog của đại lý đó bị giữ vì quá ngắn; bật cho tất cả khi lần thử cho thấy ít bài bị giữ vì độ dài hơn và không có bài bị giữ mới vì bước kiểm khác. Tắt nếu các đoạn thêm vào bắt đầu gây ra lý do giữ bài khác. Form đổi giá trị yêu cầu bằng chứng: một lần replay miễn phí các blog đã lưu, hoặc lần chạy thử kèm chi phí.", "example": "Với mặc định off (tắt): một blog dài 4.200 ký tự sau vòng sửa bị giữ vì quá ngắn (mức tối thiểu mặc định là 4.700 ký tự). Khi bật, bài được thêm đoạn từ những dữ kiện chưa dùng trước, và chỉ bị giữ nếu vẫn còn ngắn."}}}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('418', now(), 'AA-1077: the blog lengthening repair switch in the settings registry (cis.t9.blog_length_extend)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
