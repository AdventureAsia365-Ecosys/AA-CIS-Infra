-- Migration 468: AA-788 (S287 lane l11) -- the Platform › Settings text of cis.quality_modes.t10_f12_scope says what
-- evidence the server accepts for block.
--
-- Why. The F12 scope mode may switch to block only with the passing pilot measurement record (root ADR 0020: "a gate
-- may hold content only with a passing measurement record"). The same PR makes the settings API refuse any other
-- evidence for block (services/quality/quality_settings.evidence_problem, 422 evidence_mismatch): the reference must be
-- "aa788-pilot:<run id>:<12 hex>", the text scripts/aa788/pilot.py score prints only for a record that clears the
-- deterministic-detector bar. The definition text (CIS 412 / 416 / 424) still told the administrator that "an eval or
-- golden-set run id, or a $0 replay of stored pieces" was enough, so the page would ask for evidence the server is
-- certain to refuse.
--
-- What.
--   1. The block between "settings-edit:begin" and "settings-edit:end" (read by scripts/settings/gen_compiled_defaults.py
--      into shared/settings/compiled_defaults.json, regenerated in this PR; the seed-parity test keeps them equal): the
--      key's description and its EN / VI guide ("raise" and "when"): block needs the passing pilot record reference,
--      warn takes any evidence. The description also drops its issue id. Value, default, allowed values, approval,
--      impact, evidence_required and enforcement do not change.
--   2. A post-check: the row holds its new fields (a misspelt key would otherwise pass silently).
--   3. Register 468.
--
-- Behaviour on apply. None for running code: the reader and the admin page serve the compiled defaults (regenerated
-- from this block in the same PR); the table row follows. No value row changes, so the mode in force stays warn.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): an UPDATE of an existing config row and one
-- DO block (the post-check). No readiness raise. MIG-4 deviation, the CIS 424 / 427 / 460 precedent (recorded in the
-- implementation notes): this file ships in ONE PR with the regenerated compiled_defaults.json and the code that
-- enforces the rule, because the seed-parity test binds this block, the generator and compiled_defaults.json together
-- (either half alone is red), and the text describes the server rule of the same PR. On Dev, Infra Migration Apply
-- once every job table is idle (root ADR 0017a). DM-6.1: no personal data (definition text). DM-7.1: no new table.
--
-- Number. 465 is the newest CIS migration on main (21/11/2026); 466-467 are taken by other lanes of this wave, so this
-- is 468. If the owner main max + 1 differs at merge, renumber (git grep '468' here, in
-- tests/integration/test_aa788_migration_468.py, compiled_defaults.json's _generated line and
-- docs/implementation-notes/AA-788.md).
--
-- Locks. An UPDATE of 1 row of a small table read by no hot path (the reader reads shared.setting_value); the
-- definition guard trigger (CIS 407) allows the file's role, cis_owner. lock_timeout 5s. Re-runnable (the Integration
-- Tests replay every file): the UPDATE skips an equal row.
--
-- Rollback (a new forward migration): the CIS 424 description and guide of the key (only together with a code change
-- that drops the record rule of quality_settings.HOLD_EVIDENCE).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- settings-edit:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted block)
CREATE TEMP TABLE IF NOT EXISTS m468_edit (key text PRIMARY KEY, doc jsonb NOT NULL) ON COMMIT DROP;
INSERT INTO m468_edit (key, doc)
SELECT e.doc ->> 'key', e.doc
  FROM jsonb_array_elements($edit$[
{"key": "cis.quality_modes.t10_f12_scope", "description": "warn: a place outside the piece's scope is reported only. block: a body finding blocks for one sentence repair and holds the piece when it is left. Evidence for block: only the reference of a passing F12 pilot measurement record, as scripts/aa788/pilot.py score prints it (aa788-pilot:<run id>:<12 hex>; root ADR 0020, the deterministic-detector bar); the server refuses any other evidence for block. Evidence for warn: any eval or golden-set run id, or a $0 replay of stored pieces.", "guide": {"en": {"what": "What the free scope check does when a blog or social post names a place outside the piece's scope (a place no day of the trip visits). warn: reported only. block: a finding in the body gets one sentence repair, and the piece is held if it is still there.", "raise": "block (the stricter choice): pieces stop naming places the trip does not visit; more repairs (paid) and holds. Allowed only with a passing pilot measurement record of this check.", "lower": "warn (the looser choice): the piece goes on with a flag.", "when": "Choose block only once the pilot measurement of this check has passed its accuracy bar. The change form then needs the record reference the pilot's scorer prints for a passing record (it starts with aa788-pilot:); any other evidence is refused for block. Going back to warn takes any evidence, such as an evaluation run or a free replay of stored pieces.", "example": "With the default warn: out-of-scope places are flagged, nothing is held."}, "vi": {"what": "Bước kiểm phạm vi (miễn phí) xử lý ra sao khi bài blog hay mạng xã hội nêu một địa điểm ngoài phạm vi của bài (nơi không ngày nào của chuyến ghé). warn: chỉ báo. block: lỗi trong thân bài được sửa một câu, nếu vẫn còn thì bài bị giữ.", "raise": "block (lựa chọn chặt hơn): bài không còn nhắc nơi chuyến đi không ghé; nhiều lần sửa (có phí) và giữ bài hơn. Chỉ được chọn khi có bản ghi đo thử (pilot) đạt của bước kiểm này.", "lower": "warn (lựa chọn nới hơn): bài đi tiếp kèm cờ.", "when": "Chỉ chọn block khi lần đo thử (pilot) của bước kiểm này đã đạt ngưỡng chính xác. Khi đó form đổi giá trị cần mã bản ghi mà công cụ chấm điểm của pilot in ra cho một bản ghi đạt (bắt đầu bằng aa788-pilot:); mọi bằng chứng khác bị từ chối cho block. Quay lại warn thì bằng chứng nào cũng được, ví dụ một lần chạy đánh giá hoặc một lần replay miễn phí các bài đã lưu.", "example": "Với mặc định warn: địa điểm ngoài phạm vi được gắn cờ, không giữ bài."}}}
]$edit$::jsonb) AS e (doc)
ON CONFLICT (key) DO UPDATE SET doc = EXCLUDED.doc;
-- settings-edit:end

UPDATE shared.setting_definition AS d
   SET description = COALESCE(e.doc ->> 'description', d.description),
       guide       = CASE WHEN e.doc ? 'guide' THEN e.doc -> 'guide' ELSE d.guide END
  FROM m468_edit AS e
 WHERE d.key = e.key
   AND (d.description IS DISTINCT FROM COALESCE(e.doc ->> 'description', d.description)
        OR d.guide IS DISTINCT FROM CASE WHEN e.doc ? 'guide' THEN e.doc -> 'guide' ELSE d.guide END);

-- Post-check: every row of the block exists with its new fields.
DO $check$
DECLARE
    missing text;
BEGIN
    SELECT string_agg(e.key, ', ' ORDER BY e.key) INTO missing
      FROM m468_edit AS e
     WHERE NOT EXISTS (
           SELECT 1 FROM shared.setting_definition AS d
            WHERE d.key = e.key
              AND (NOT e.doc ? 'description' OR d.description = e.doc ->> 'description')
              AND (NOT e.doc ? 'guide' OR d.guide = e.doc -> 'guide'));
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'CIS 468: no definition or not edited: %', missing;
    END IF;
END
$check$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('468', now(), 'AA-788 S287: the F12 scope mode text names the pilot record evidence block needs')
ON CONFLICT (version) DO NOTHING;

COMMIT;
