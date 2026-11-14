-- Migration 422: AA-1077 (S281) — what the blog lengthening repair may add, and how many sections it asks for after a
-- repair round that shrank the blog under the length minimum, in the platform settings registry (CIS 407; tech lead
-- S279: a threshold, limit or policy value is a setting on Platform › Settings, never a code literal or an env var).
--
-- Why. Paid trial 5 of the lengthening repair (S280, audit tenant, 0.23 USD; switch cis.t9.blog_length_extend on for
-- that tenant only) held one of its pieces on length: the attempt-2 repair round shrank it from 4,988 to 4,669
-- characters (under the 4,700 minimum), the lengthening repair then ran on what was left and added nothing: the writer
-- returned an empty paragraph for both sections it was asked for ("no fitting fact"), because the repair may only use
-- source facts the blog does not tell yet. Two causes, one setting each:
--   - the material: background about the places, peoples, culture and history the blog's own source names (the
--     writing policy allows it; never a trip activity, service, time, view or promise the source lacks) gives the
--     repair something to add when no untold fact fits a section;
--   - the budget after a shrink: when the repair round itself made the blog shorter and left it under the minimum, the
--     repair asks for a paragraph in more sections (each one another chance), instead of the one or two the deficit
--     alone gives.
--
-- What:
--   1. Two rows in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), both platform+tenant (a tenant value runs the next paid
--      trial on one audit tenant), both read only while cis.t9.blog_length_extend is on for the piece:
--        cis.t9.blog_extend_material        enum source_facts | with_background, default source_facts (= today's
--                                           repair), impact high, maker-checker, evidence required, no env override
--        cis.t9.blog_extend_shrink_sections int 0..6 sections, default 3, impact medium, maker-checker, evidence
--                                           required, no env override; 0 = no change after a shrink (the deficit
--                                           alone sizes the plan, today's repair)
--      Each seed row carries its plain label and its EN + VI operator guide (CIS 416 rule). Enforced: the keys are
--      named by services/quality/settings_keys.py in this PR (the settings-lint reader check); the code PR reads them,
--      and until it is deployed nothing reads them (the running repair is today's).
--   2. Register 422.
--
-- Behaviour on apply. None for running code: no value row is seeded; after the code PR every piece with the switch
-- off (every tenant but the audit trial tenant) is unchanged; with the switch on, the material stays source_facts
-- until an administrator approves with_background, and the shrink plan asks for up to 3 sections.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): config rows INSERTed into an existing table.
-- MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a), then the
-- code PR. DM-7.1: no new table.
--
-- Number. 420 is the newest CIS migration on main (15/11/2026) and the S281 wave's CIS batch has 421 before this file,
-- so 422 = owner main max + 1 once 421 is in. If the owner main max + 1 differs at merge, renumber (git grep '422_' and
-- '422' here, in tests/integration/test_aa1077_migration_422.py, compiled_defaults.json, services/quality/settings_keys.py
-- and docs/implementation-notes/AA-1077.md).
--
-- Locks. One INSERT of two rows (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
-- Idempotent (ON CONFLICT (key) DO NOTHING), one transaction, self-registering.
--
-- Rollback (a new forward migration, after the code PR is reverted): DELETE the keys' value rows first, then the keys.

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
{"key": "cis.t9.blog_extend_material", "app": "cis", "area": "content", "label": "Blog length: what the lengthening pass may add", "description": "Read only while the blog lengthening pass is on for the piece (cis.t9.blog_length_extend). source_facts: a new paragraph may only tell facts of the blog's own source that the blog does not use yet (a section with no fitting fact gets nothing). with_background: a paragraph may also give general background about a place, people, tradition or piece of history that the blog or its source names, written in the third person; it may never add a trip activity, service, meal, time, view or promise, a number or year, or a name the blog and its source do not have, and each paragraph is screened in code for wording that says so (the reader, the travellers or the trip as its subject, a guide, a meal, a tasting or a booking, a number, time or new name) before every quality check, the AI judge included, re-reads the whole blog. Evidence required: a $0 replay of stored pieces, or a trial run whose cost is read from the call ledger.", "value_type": "enum", "unit": null, "min_value": null, "max_value": null, "allowed_values": ["source_facts", "with_background"], "default_value": "source_facts", "scope_kind": "platform+tenant", "impact": "high", "approval": "maker_checker", "evidence_required": true, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "What the lengthening pass may write when it adds a paragraph to a blog that is too short. With source facts only, it can use only facts from the blog's own source that the blog does not use yet. With background, it may also explain the history, culture or people of a place the blog or its source already names, as general knowledge, never as something the trip offers.", "raise": "with_background: fewer blogs stay too short, because a section with no unused fact can still get a paragraph. The added background is general knowledge. A paragraph whose wording makes it about the trip (it speaks to the reader or about the travellers or the tour, names a guide, a meal, a tasting or a booking, or adds a time, number or new name) is refused in code; a claim worded any other way is left to the quality checks, the AI judge included, which re-read the whole blog, and a blog that then fails a check is held as before.", "lower": "source_facts: the pass only retells unused source facts. A blog whose source has no unused fact that fits a section stays short and is held for length.", "when": "Turn background on for one test agency first and compare its length holds and any new holds from the fact checks; turn it on for everyone when that test shows fewer length holds and no new fact holds. Go back to source facts if background paragraphs start causing holds. The change form asks for evidence: a free replay of stored blogs, or the test run with its cost.", "example": "With the default source_facts: a blog of 4,669 characters whose two thin sections have no unused source fact gets nothing added and is held for being too short. With with_background, each of those sections may get a short paragraph about the history of a town the blog already names."}, "vi": {"what": "Bước kéo dài được viết gì khi thêm một đoạn vào bài blog quá ngắn. Chỉ dữ kiện nguồn: chỉ dùng được những dữ kiện trong nguồn của chính bài mà bài chưa dùng tới. Có bối cảnh: được giải thích thêm lịch sử, văn hoá hay con người của một địa danh mà bài hoặc nguồn của bài đã nêu tên, như kiến thức phổ thông, không bao giờ như một thứ chuyến đi cung cấp.", "raise": "with_background: ít blog bị ngắn hơn, vì một phần không còn dữ kiện chưa dùng vẫn có thể được thêm đoạn. Phần bối cảnh thêm vào là kiến thức phổ thông. Đoạn nào có câu chữ biến nó thành chuyện của chuyến đi (nói với người đọc hoặc về du khách hay tour, nêu hướng dẫn viên, bữa ăn, buổi nếm thử hay việc đặt chỗ, hoặc thêm thời gian, con số hay tên mới) bị loại ngay trong code; một khẳng định viết theo cách khác thì để các bước kiểm chất lượng, kể cả giám khảo AI, đọc lại toàn bài, và bài vướng một bước kiểm sau đó vẫn bị giữ như trước.", "lower": "source_facts: bước kéo dài chỉ kể lại các dữ kiện nguồn chưa dùng. Bài mà nguồn không còn dữ kiện chưa dùng hợp với một phần nào thì vẫn ngắn và bị giữ vì độ dài.", "when": "Bật bối cảnh cho một đại lý thử nghiệm trước và so số bài bị giữ vì độ dài cùng các bài bị giữ mới vì bước kiểm dữ kiện; bật cho tất cả khi lần thử cho thấy ít bài bị giữ vì độ dài hơn và không có bài bị giữ mới vì dữ kiện. Quay về chỉ dữ kiện nguồn nếu đoạn bối cảnh bắt đầu gây ra lý do giữ bài. Form đổi giá trị yêu cầu bằng chứng: một lần replay miễn phí các blog đã lưu, hoặc lần chạy thử kèm chi phí.", "example": "Với mặc định source_facts: một blog dài 4.669 ký tự có hai phần mỏng không còn dữ kiện nguồn chưa dùng thì không được thêm gì và bị giữ vì quá ngắn. Với with_background, mỗi phần đó có thể được thêm một đoạn ngắn về lịch sử của một thị trấn mà bài đã nêu tên."}}},
{"key": "cis.t9.blog_extend_shrink_sections", "app": "cis", "area": "content", "label": "Blog length: sections to lengthen after a repair shortened the blog", "description": "Read only while the blog lengthening pass is on for the piece (cis.t9.blog_length_extend). When the repair round itself made a blog shorter and left it under the length minimum, the lengthening pass asks for a new paragraph in up to this many of its body sections (sections a repair cut first, then the thinnest), instead of the one or two the missing length alone gives: each section is one more chance that a paragraph fits. The total length asked stays the missing length to the target; it is shared between the sections. 0 = no change after a shrink. Evidence required: a $0 replay of stored pieces, or a trial run whose cost is read from the call ledger.", "value_type": "int", "unit": "sections", "min_value": 0, "max_value": 6, "allowed_values": null, "default_value": 3, "scope_kind": "platform+tenant", "impact": "medium", "approval": "maker_checker", "evidence_required": true, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "How many sections of a blog the lengthening pass asks to extend when the blog's repair round cut it under the length minimum. Each section asked is one more chance that a paragraph fits; the total length asked does not grow, it is shared between the sections.", "raise": "More sections asked: a shortened blog is more likely to get back over the minimum, because a section with nothing to add no longer decides the outcome. The paragraphs get shorter, and the call stays one call (a cent or two).", "lower": "Fewer sections asked: the paragraphs are longer and fewer; if the one or two sections asked have nothing that fits, the blog stays short and is held. 0 keeps the plan the missing length alone gives.", "when": "Raise it when the length holds show repaired blogs whose lengthening pass added nothing to the few sections it asked for; lower it if many short added paragraphs read as padding in review. The change form asks for evidence: a free replay of stored blogs, or the test run with its cost.", "example": "With the default of 3: a repair round cut a blog from 4,988 to 4,669 characters; the lengthening pass then asks three of its sections for about 50 words each, instead of two sections for about 70 words each."}, "vi": {"what": "Số phần của một bài blog mà bước kéo dài yêu cầu thêm đoạn khi vòng sửa của bài đã cắt bài xuống dưới độ dài tối thiểu. Mỗi phần được yêu cầu là thêm một cơ hội có đoạn phù hợp; tổng độ dài yêu cầu không tăng, mà được chia cho các phần.", "raise": "Yêu cầu nhiều phần hơn: bài bị cắt ngắn dễ vượt lại mức tối thiểu hơn, vì một phần không có gì để thêm không còn quyết định kết quả. Các đoạn ngắn hơn, và vẫn chỉ một lần gọi (một hai xu Mỹ).", "lower": "Yêu cầu ít phần hơn: đoạn dài hơn và ít hơn; nếu một hai phần được yêu cầu không có gì phù hợp, bài vẫn ngắn và bị giữ. 0 giữ kế hoạch chỉ tính theo phần độ dài còn thiếu.", "when": "Tăng khi các bài bị giữ vì độ dài cho thấy bài đã sửa mà bước kéo dài không thêm được gì vào vài phần nó yêu cầu; giảm nếu nhiều đoạn ngắn thêm vào đọc như độn chữ khi duyệt. Form đổi giá trị yêu cầu bằng chứng: một lần replay miễn phí các blog đã lưu, hoặc lần chạy thử kèm chi phí.", "example": "Với mặc định 3: vòng sửa cắt một blog từ 4.988 xuống 4.669 ký tự; bước kéo dài khi đó yêu cầu ba phần, mỗi phần khoảng 50 từ, thay vì hai phần, mỗi phần khoảng 70 từ."}}}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('422', now(), 'AA-1077: what the blog lengthening repair may add and its sections after a shrink (settings)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
