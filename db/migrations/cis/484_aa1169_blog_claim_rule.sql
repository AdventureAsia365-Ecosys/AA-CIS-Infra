-- Migration 484: AA-1169 (S292, T9 blog first-pass yield under the W5 measure) — the switch of the blog writer's
-- CLAIM CHECK block (setting cis.t9.blog_claim_rule) and the prompt version of the T9 writer that knows it (t9_write v10).
--
-- Why. Under the W5 measure a T9 blog's first draft fails when the pinned claim instrument flags any sentence; the S285
-- proof (w5-t9) passed 1 of 12 against the 0.30 target. The $0 first-pass diagnosis (services/writer_proof/first_pass.py,
-- code PR) types the flagged sentences by writing-policy topic; on the local proxy most expected flags were ranking /
-- rarity (D13), route and time narration (D4 / D15, F17 direction) and the reader's-day lines (D14 / D15). The code PR
-- adds a blog-only CLAIM CHECK block to the writer prompt, but only while this switch is on: a writer prompt change
-- ships behind a switch whose default is main (S272 rule), and the paid re-measure of the W5 T9 sample (cap 5 USD, the
-- tech lead's yes) runs with it on before an administrator leaves it on. Tech lead S279: a policy value is a setting on
-- Platform › Settings (CIS 407 registry), never a code literal or an env var alone.
--
-- What:
--   1. One row in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), area "content", scope platform, impact high, maker-checker,
--      no evidence, no env override, enforced (services/acp_content_writing/claim_rule.py reads it through
--      shared.settings, the key named in services/quality/settings_keys.py, both in this PR):
--        cis.t9.blog_claim_rule   bool, default false (today's prompt)
--      The seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. One shared.prompt_version row (sha256 of the hashed symbols' source text, never the text; created_by
--      'migration-484'), the output of `python3 scripts/prompt_registry_check.py --sql --unregistered --created-by
--      migration-484` on the code PR's tree:
--        t9_write  v10  SYSTEM_PROMPT, build_user_prompt, _BLOG_WORDS_TOP, _blog_words, _BLOG_WORDS_MAX,
--                       _BLOG_SECTIONS_MAX, _BLOG_FAQ_PLAN, _BLOG_RICHEST_SHARE, _blog_length_plan,
--                       _blog_length_instructions, _WALK_FOCUS_MARK, _WALK_FOCUS_RULE, _seed_with_facts,
--                       _BLOG_CLAIM_RULE (services/acp_content_writing/prompts.py)
--      With the switch off the rendered prompts are v9's byte for byte (tests/unit/test_aa1169_blog_claim_rule.py);
--      only the hashed source changed. Without this row every t9_write call after the code deploy would carry
--      prompt_version NULL (shared/llm_client/prompt_registry.version_for).
--   3. Guard: the prompt row exists with exactly this hash and path.
--   4. Register 484.
--
-- Behaviour on apply. None for running code: no value row is seeded, nothing on main reads the key and no deployed
-- prompt matches v10 until the code PR deploys. After it deploys, the writer reads the default (off); t9_write rows
-- carry 'v10' (with '.s<8 hex>' while a prompt setting, this switch included, differs from its seed:
-- services/quality/quality_settings.prompt_fp counts the switch). Older versions stay registered.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): config rows INSERTed into existing tables.
-- MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a), then the
-- code PR (no readiness raise: the reader falls back to the compiled defaults). DM-6.1: no personal data. DM-7.1: no
-- new table.
--
-- Number. Taken from the S292 lane hint (owner main max 483; 484-489 held by other lanes of the same wave). If the
-- number differs at merge, renumber (git grep '484_' and '484' in tests/integration/test_aa1169_migration_484.py,
-- services/acp_content_writing/claim_rule.py, services/quality/settings_keys.py and docs/implementation-notes/AA-1169.md)
-- and regenerate the prompt row with --created-by migration-<new>.
--
-- Locks. Two single-row INSERTs into tables owned by cis_owner (the definition guard trigger allows it). lock_timeout 5s.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical.
--
-- Rollback (a NEW forward migration, after the code PR is reverted): DELETE the key's value rows first, then the key;
-- DELETE FROM shared.prompt_version WHERE created_by = 'migration-484'.

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.setting_definition') IS NULL THEN
        RAISE EXCEPTION 'migration 484: shared.setting_definition missing (apply 407 first)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'shared' AND table_name = 'setting_definition' AND column_name = 'guide') THEN
        RAISE EXCEPTION 'migration 484: shared.setting_definition.guide missing (apply 416 first)';
    END IF;
    IF to_regclass('shared.prompt_version') IS NULL THEN
        RAISE EXCEPTION 'migration 484: shared.prompt_version is missing (apply 321 first)';
    END IF;
END $$;

-- ── 1. the setting ───────────────────────────────────────────────────────────────────────────────────────────────

-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$
[
{"key": "cis.t9.blog_claim_rule", "app": "cis", "area": "content", "label": "Blog writer: claim check block in the first draft", "description": "On: the T9 blog writer prompt (first draft and rewrite) carries a CLAIM CHECK block after its length block: no time of day, order, direction or movement between moments, no ranking or rarity, no line about the day's pace, ease, who it suits or what the reader will see or feel, unless the content seed (or the audience line) states it, and seed facts restated in the seed's own words. Off (default): the blog prompt is the one of the release before, byte for byte. Other channels never change. The prompt version recorded on every write changes when it is on. Read by services/acp_content_writing/claim_rule.py on every T9 write; an unreadable value counts as off.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": false, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "Whether the AI blog writer is told, in its first draft, to leave out the kinds of sentences the quality check most often finds unsupported: times of day and route order the trip does not state, rankings such as 'one of the most', and lines about how a day feels or who it suits.", "raise": "On: blog first drafts stay closer to the trip's own facts, so fewer sentences are flagged and fewer blogs need a repair round; the prose can read plainer, so read the first blogs after switching.", "lower": "Off: the blog writer gets the prompt it had before this switch existed; such sentences are only caught by the later checks and repairs.", "when": "Turn it on after the paid re-measure of the fixed blog sample shows more blogs pass on the first draft with no rise in errors per blog; turn it off if blog quality or length drops.", "example": "With the default off, a blog may say 'By evening the group reaches the lake camp' when the itinerary gives no time. Switched on, the writer says only what the itinerary says: 'Day 4: overnight at the lake camp.'"}, "vi": {"what": "Bộ viết blog AI có được dặn, ngay ở bản nháp đầu, bỏ những kiểu câu mà bước kiểm chất lượng hay đánh dấu là không có nguồn hay không: giờ trong ngày và thứ tự lộ trình mà chuyến đi không nêu, các câu xếp hạng như 'một trong những nơi đẹp nhất', và câu nói một ngày cảm thấy thế nào hay hợp với ai.", "raise": "Bật: bản nháp blog đầu tiên bám sát dữ kiện của chuyến đi hơn, ít câu bị đánh dấu và ít blog phải sửa thêm một vòng; câu văn có thể mộc hơn, nên đọc vài blog đầu tiên sau khi bật.", "lower": "Tắt: bộ viết blog nhận prompt như trước khi có công tắc này; những câu như vậy chỉ bị bắt ở các bước kiểm và sửa sau đó.", "when": "Bật sau khi lần đo lại có trả phí trên bộ blog mẫu cố định cho thấy nhiều blog đạt ngay từ bản nháp đầu hơn mà số lỗi mỗi blog không tăng; tắt nếu chất lượng hoặc độ dài blog giảm.", "example": "Với mặc định tắt, một blog có thể viết 'Đến tối cả đoàn tới trại bên hồ' dù lịch trình không nêu giờ. Khi bật, bộ viết chỉ nói đúng như lịch trình: 'Ngày 4: nghỉ đêm ở trại bên hồ.'"}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── 2. the prompt version row ────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.prompt_version (stage, version, prompt_sha256, source_path, created_by) VALUES
    ('t9_write', 'v10', '28f5a801e90ed5a2ec881c2a6d2efc29706cc59435d6d28e35d451e3f65613fc', 'services/acp_content_writing/prompts.py', 'migration-484')
ON CONFLICT (stage, version) DO NOTHING;

-- ── 3. guard: the prompt row ─────────────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM shared.prompt_version
         WHERE stage = 't9_write' AND version = 'v10'
           AND prompt_sha256 = '28f5a801e90ed5a2ec881c2a6d2efc29706cc59435d6d28e35d451e3f65613fc'
           AND source_path = 'services/acp_content_writing/prompts.py'
    ) THEN
        RAISE EXCEPTION 'migration 484: t9_write v10 is registered with another hash or path, or missing (a version '
                        'is never edited: bump the manifest instead)';
    END IF;
END $$;

-- ── 4. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('484', now(), 'AA-1169: blog writer claim check switch (cis.t9.blog_claim_rule) and prompt version t9_write v10')
ON CONFLICT (version) DO NOTHING;

COMMIT;
