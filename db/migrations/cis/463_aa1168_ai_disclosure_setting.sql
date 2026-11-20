-- Migration 463: AA-1168 follow-up (S286 settings-rule audit) — the AI disclosure wording as a setting.
--
-- Why. AA-1168 (EU AI Act Art. 50) ends every published or exported piece with a visible AI disclosure line (the last
-- paragraph of a WordPress article, the last line of a Facebook post with a hashtag, the trailer of the plain-text and
-- the agency CSV / XLSX exports). The wording shipped as a code constant, English only. A customer-visible wording is a
-- setting, editable on an admin page, seeded and audited, never a code literal or an env var (tech lead S278 / S279).
--
-- What:
--   1. One row in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR):
--        cis.content.ai_disclosure   json, area content, platform scope, impact high, maker_checker, enforced. Value
--          {"text": {"en": ..., "vi": ...}, "social_tag": "#AIgenerated"}: the line per language (the piece language
--          picks it, English is the fallback) and the tag of a social text post. The shape (English line required,
--          every line non-empty, one line, at most 200 characters; the tag one hashtag) is checked by
--          services/acp_content_writing/ai_disclosure_setting.py value_problem (this PR), which the settings API runs
--          on a proposal and on approval (code PR). The line cannot be switched off: an empty value is refused.
--      The seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 463.
--
-- Behaviour on apply. None for running code: no value row is seeded (the default equals the wording in force today in
-- English); nothing on main reads the key until the code PR.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a config row INSERTed into an existing table.
-- MIG-4: a migration-only PR with 464 (one batch, cis 463-464), applied on Dev by Infra Migration Apply when the job
-- tables are idle (ADR 0017a), then the code PR. DM-6.1: no personal data. DM-7.1: no new table.
--
-- Number. Owner main max + 1 (462). If it differs at merge, renumber 463 and 464 together (git grep '463_', '463',
-- '464_' and '464' in tests/integration/test_aa1168_migrations_463_464.py and docs/implementation-notes/).
--
-- Locks. One INSERT of one row (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
--
-- Rollback (a new forward migration, after the code PR is reverted): DELETE the key's value rows first, then the key.

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.setting_definition') IS NULL THEN
        RAISE EXCEPTION 'migration 463: shared.setting_definition missing (apply 407 first)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'shared' AND table_name = 'setting_definition' AND column_name = 'guide') THEN
        RAISE EXCEPTION 'migration 463: shared.setting_definition.guide missing (apply 416 first)';
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
{"key": "cis.content.ai_disclosure", "app": "cis", "area": "content", "label": "AI disclosure wording on published and exported content", "description": "The visible line that tells a reader a piece was written with AI (EU AI Act Art. 50): the last paragraph of a WordPress post and of the HTML exports, the last line of a Facebook post followed by social_tag, the trailer of the plain-text export and of the agency studio CSV / XLSX export. JSON {\"text\": {<two-letter language>: <line>}, \"social_tag\": <hashtag>}: the piece language picks the line, English (required) is the fallback. Every line non-empty, one line, at most 200 characters; the tag is one hashtag (# then 2 to 50 letters, digits or _). The line itself cannot be switched off: an empty or invalid value is refused, and a stored value that breaks the shape is ignored (the seeded wording is served). Read by services/acp_content_writing/ai_disclosure_setting.py (ai_marking, the publish dispatch and GET /v1/content-writing/ai-disclosure for the agency studio).", "value_type": "json", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": {"text": {"en": "This content was created with the help of AI.", "vi": "Nội dung này được tạo với sự hỗ trợ của AI."}, "social_tag": "#AIgenerated"}, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "The sentence every published or exported piece ends with to say it was written with the help of AI: on WordPress posts, Facebook posts (followed by the hashtag), text downloads and the agencies' catalog exports. One line per language; the piece's language picks the line and English is used when there is none for it.", "raise": "A longer or more specific wording explains more to the reader (for example who reviewed the text); keep it one line, at most 200 characters, and true for every piece.", "lower": "A shorter wording takes less space at the end of a post; it can never be empty, because the disclosure itself cannot be switched off.", "when": "Change it when legal counsel asks for a different wording, when a new market needs its own language line, or when a social platform asks for a different hashtag.", "example": "With the default, an English post ends with: This content was created with the help of AI. A Facebook post adds #AIgenerated after it."}, "vi": {"what": "Câu mà mọi nội dung được đăng hoặc xuất ra đều kết thúc bằng, để nói rằng nội dung được viết với sự hỗ trợ của AI: trên bài WordPress, bài Facebook (kèm hashtag), tệp văn bản tải về và tệp xuất danh mục của đại lý. Mỗi ngôn ngữ một dòng; ngôn ngữ của nội dung chọn dòng, và dùng dòng tiếng Anh khi không có dòng cho ngôn ngữ đó.", "raise": "Câu dài hơn hoặc cụ thể hơn giải thích rõ hơn cho người đọc (ví dụ ai đã duyệt nội dung); giữ trong một dòng, tối đa 200 ký tự, và đúng với mọi nội dung.", "lower": "Câu ngắn hơn chiếm ít chỗ hơn ở cuối bài; không bao giờ được để trống, vì không thể tắt phần công bố này.", "when": "Đổi khi luật sư yêu cầu câu khác, khi một thị trường mới cần dòng bằng ngôn ngữ riêng, hoặc khi một mạng xã hội yêu cầu hashtag khác.", "example": "Với mặc định, một bài tiếng Anh kết thúc bằng: This content was created with the help of AI. Bài Facebook thêm #AIgenerated sau câu đó."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('463', now(), 'AA-1168: AI disclosure wording setting (cis.content.ai_disclosure)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
