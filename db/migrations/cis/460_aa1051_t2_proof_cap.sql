-- Migration 460: AA-1051 (S285 C2) -- the T2 writer proof's D12 spending cap goes from 5 to 6.5 USD.
--
-- Why. The tech lead approved on 19/11/2026 (S285 decision page, item C2) raising the cap of the T2 tenant tour
-- writer proof to 6.5 USD and keeping all 20 GATE samples: the DRY plan of `w5-t2` on golden aa729@1.7.0 (CIS 75db7a9c)
-- estimated 6.2525 USD against the 5 USD cap, with the fire share measured on t2 (0.225), and a smaller sample would
-- lose the power the proof was drafted for. The cap is a setting (CIS 419, tech lead S279), and a pre-registration's
-- own cap_usd must be at or below it (services/writer_proof/prereg.py `problems`), which every process checks
-- against the compiled defaults until it reads the values in force. So the default moves, in the same PR as the
-- pre-registration file (`prereg/w5-t2.json` cap_usd 6.5), not only a value row on Dev.
--
-- What.
--   1. The block between "settings-edit:begin" and "settings-edit:end" (read by scripts/settings/gen_compiled_defaults.py
--      into shared/settings/compiled_defaults.json, regenerated in this PR; the seed-parity test keeps them equal):
--        cis.spend.writer_proof_t2_cap_usd     default_value 5 -> 6.5, the guide's example says so (EN + VI);
--        cis.spend.writer_proof_total_cap_usd  only the guide's example: the four workflow caps now add up to 34.5,
--                                              above the total.
--      The D12 total stays 33 USD: the null run and the T9 proof are done (W5 ledger about 2.65 USD on 19/11/2026),
--      so S1 (8) + T2 (6.5) + the C1 fire measurement (cap 2.5) fit with room to spare; the spend gate checks the
--      total on every run (ledger + reservations + cap). Descriptions, bounds, approval and impact do not change.
--   2. A post-check: every row of the block holds its new fields (a misspelt key would otherwise pass silently).
--   3. Register 460.
--
-- Behaviour on apply. None for running code: the reader serves the compiled defaults (regenerated from this block in
-- the same PR), so the deploy of this PR is what raises the default in force; the table row follows for the admin
-- page. An approved platform value row of the key, if one exists, still wins over the default (the live step checks).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): UPDATEs of existing config rows and one DO
-- block (the post-check). No readiness raise. MIG-4 deviation, the CIS 424 / 427 precedent (recorded in the
-- implementation notes): this file ships in ONE PR with the regenerated compiled_defaults.json, the pre-registration and
-- the tests, because the seed-parity test binds this block, the generator and compiled_defaults.json together (either
-- half alone is red) and the w5-t2 file with cap 6.5 refuses to load under a 5 USD default. On Dev, Infra Migration
-- Apply once every job table is idle (root ADR 0017a). DM-6.1: no personal data. DM-7.1: no new table.
--
-- Number. 459 is the newest CIS migration on main (19/11/2026), so this is 460 (main max + 1). If the owner main
-- max + 1 differs at merge, renumber (git grep '460' here, in tests/integration/test_aa1051_migration_460.py,
-- tests/integration/test_aa1051_migration_419.py, compiled_defaults.json's _generated line and
-- docs/implementation-notes/AA-1051.md).
--
-- Locks. UPDATEs of 2 rows of a small table read by no hot path (the reader reads shared.setting_value); the
-- definition guard trigger (CIS 407) allows the file's role, cis_owner. lock_timeout 5s. Re-runnable (the Integration
-- Tests replay every file): the UPDATE skips equal rows.
--
-- Rollback (a new forward migration): default_value 5 and the old examples (only if the tech lead takes the decision
-- back; a T2 pre-registration with cap_usd above 5 must be re-drafted first).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- settings-edit:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted block)
CREATE TEMP TABLE IF NOT EXISTS m460_edit (key text PRIMARY KEY, doc jsonb NOT NULL) ON COMMIT DROP;
INSERT INTO m460_edit (key, doc)
SELECT e.doc ->> 'key', e.doc
  FROM jsonb_array_elements($edit$[
{"key": "cis.spend.writer_proof_t2_cap_usd", "default_value": 6.5, "guide": {"en": {"what": "The most money, in US dollars, that the agency tour writer proof (the test of a change to the AI that writes tour pages for partner agencies) may spend on AI calls in total. A writer proof is a paid test that checks, on a fixed set of samples, whether a change to an AI writer keeps or improves the quality of what it writes. Money already spent and the limits of tests still waiting in the queue both count.", "raise": "A bigger or pricier test fits under the limit, but a test that goes wrong spends more before it is stopped, and less of the overall test budget is left for the other tests.", "lower": "The test stays cheap, but a plan that needs more than the limit is refused before it starts, so the test must use fewer samples or a cheaper checking model.", "when": "Raise it when the dry-run plan shows the pre-registered sample cannot fit and the tech lead agrees to spend more; lower it when the month's AI budget is tight.", "example": "With the default of 6.5 USD (raised from 5 by the tech lead on 19/11/2026), an agency tour writer proof on 20 sample tours fits under the limit: its dry-run plan estimated about 6.3 USD."}, "vi": {"what": "Số tiền tối đa (đô la Mỹ) mà writer proof của bước viết tour cho đại lý (bài kiểm tra một thay đổi của AI viết trang tour cho đại lý đối tác) được tiêu cho các lượt gọi AI. Writer proof là một bài kiểm tra có tính phí, chạy trên một bộ mẫu cố định, để xem một thay đổi của bước AI viết bài có giữ được hoặc nâng chất lượng bài viết hay không. Cả số tiền đã tiêu lẫn giới hạn của các bài kiểm tra còn đang chờ trong hàng đợi đều được tính.", "raise": "Bài kiểm tra lớn hơn hoặc đắt hơn vẫn nằm trong giới hạn, nhưng nếu bài kiểm tra gặp lỗi thì sẽ tốn nhiều tiền hơn trước khi bị dừng, và phần ngân sách chung còn lại cho các bài kiểm tra khác ít đi.", "lower": "Bài kiểm tra rẻ hơn, nhưng kế hoạch nào cần nhiều hơn giới hạn sẽ bị từ chối trước khi chạy, nên phải dùng ít mẫu hơn hoặc model chấm rẻ hơn.", "when": "Tăng khi bản kế hoạch chạy khô cho thấy bộ mẫu đã đăng ký trước không vừa và tech lead đồng ý chi thêm; giảm khi ngân sách AI của tháng đang eo hẹp.", "example": "Với mặc định 6,5 USD (tech lead nâng từ 5 lên ngày 19/11/2026), một writer proof cho bước viết tour đại lý trên 20 tour mẫu vẫn nằm trong giới hạn: bản kế hoạch chạy khô ước tính khoảng 6,3 USD."}}},
{"key": "cis.spend.writer_proof_total_cap_usd", "guide": {"en": {"what": "The most money, in US dollars, that all writer proofs together may spend on AI calls. Writer proofs are paid tests that check, on a fixed set of samples, whether a change to an AI writer keeps or improves the quality of what it writes. Money already spent and the limits of tests still waiting in the queue both count.", "raise": "A bigger or pricier test fits under the limit, but a test that goes wrong spends more before it is stopped, and less of the overall test budget is left for the other tests.", "lower": "The test stays cheap, but a plan that needs more than the limit is refused before it starts, so the test must use fewer samples or a cheaper checking model.", "when": "Raise it when the dry-run plan shows the pre-registered sample cannot fit and the tech lead agrees to spend more; lower it when the month's AI budget is tight.", "example": "With the default of 33 USD: the null run (5), the blog writer proof (15), the tour rewrite proof (8) and the agency tour writer proof (6.5) add up to 34.5 USD, so all four can only use their whole limits if one of them stays at least 1.5 USD under its own; each proof usually spends well below it."}, "vi": {"what": "Tổng số tiền tối đa (đô la Mỹ) mà tất cả các writer proof cộng lại được tiêu cho các lượt gọi AI. Writer proof là các bài kiểm tra có tính phí, chạy trên một bộ mẫu cố định, để xem một thay đổi của bước AI viết bài có giữ được hoặc nâng chất lượng bài viết hay không. Cả số tiền đã tiêu lẫn giới hạn của các bài kiểm tra còn đang chờ trong hàng đợi đều được tính.", "raise": "Bài kiểm tra lớn hơn hoặc đắt hơn vẫn nằm trong giới hạn, nhưng nếu bài kiểm tra gặp lỗi thì sẽ tốn nhiều tiền hơn trước khi bị dừng, và phần ngân sách chung còn lại cho các bài kiểm tra khác ít đi.", "lower": "Bài kiểm tra rẻ hơn, nhưng kế hoạch nào cần nhiều hơn giới hạn sẽ bị từ chối trước khi chạy, nên phải dùng ít mẫu hơn hoặc model chấm rẻ hơn.", "when": "Tăng khi bản kế hoạch chạy khô cho thấy bộ mẫu đã đăng ký trước không vừa và tech lead đồng ý chi thêm; giảm khi ngân sách AI của tháng đang eo hẹp.", "example": "Với mặc định 33 USD: lần chạy đối chứng (5), writer proof viết blog (15), viết lại tour (8) và viết tour đại lý (6,5) cộng lại 34,5 USD, nên cả bốn chỉ dùng hết giới hạn riêng khi một bài tiêu ít hơn giới hạn của nó ít nhất 1,5 USD; thường mỗi proof tiêu thấp hơn nhiều so với giới hạn."}}}
]$edit$::jsonb) AS e (doc)
ON CONFLICT (key) DO UPDATE SET doc = EXCLUDED.doc;
-- settings-edit:end

UPDATE shared.setting_definition AS d
   SET default_value = CASE WHEN e.doc ? 'default_value' THEN e.doc -> 'default_value' ELSE d.default_value END,
       guide         = CASE WHEN e.doc ? 'guide' THEN e.doc -> 'guide' ELSE d.guide END
  FROM m460_edit AS e
 WHERE d.key = e.key
   AND (d.default_value IS DISTINCT FROM CASE WHEN e.doc ? 'default_value' THEN e.doc -> 'default_value'
                                              ELSE d.default_value END
        OR d.guide IS DISTINCT FROM CASE WHEN e.doc ? 'guide' THEN e.doc -> 'guide' ELSE d.guide END);

-- Post-check: every row of the block exists with its new fields.
DO $check$
DECLARE
    missing text;
BEGIN
    SELECT string_agg(e.key, ', ' ORDER BY e.key) INTO missing
      FROM m460_edit AS e
     WHERE NOT EXISTS (
           SELECT 1 FROM shared.setting_definition AS d
            WHERE d.key = e.key
              AND (NOT e.doc ? 'default_value' OR d.default_value = e.doc -> 'default_value')
              AND (NOT e.doc ? 'guide' OR d.guide = e.doc -> 'guide'));
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'CIS 460: no definition or not edited: %', missing;
    END IF;
END
$check$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('460', now(), 'AA-1051 S285 C2: the T2 writer proof cap default 5 -> 6.5 USD')
ON CONFLICT (version) DO NOTHING;

COMMIT;
