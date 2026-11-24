-- Migration 478: AA-1148 (S290; S285 advisory r2-content-staff T4 / T5, slice L4 of root
-- docs/audits/2026-11-19-S285-session/advisory-r2-plan.md) — hand-made tours in the content workspace and the link of
-- a source tour to an AA supplier of AA-Booking.
--
-- Why. Content staff bring tours in only by Excel (S0 upload). A supplier that sends one tour by e-mail or PDF needs a
-- hand-made tour: the content workspace (/admin/content-workspace, AA-CIS-App code PR) creates the source tour from a
-- structured form (day cards, inclusions, exclusions) and keeps the structured facts next to the text columns the
-- pipeline reads. The tour's supplier is today free text (raw_tours.provider, the Excel cell) that CIS cannot link to
-- Booking's supplier list; Booking bk-073 opens the read-only view booking.v_supply_suppliers (contract
-- supply.supplier.v1) to cis_app, and CIS stores the chosen supplier's id as a soft key (no foreign key across owners).
--
-- What (cis_owner, the owner of silver_aa_internal):
--   1. silver_aa_internal.raw_tours gains three columns:
--        supplier_id   uuid, NULL — the AA supplier (booking.v_supply_suppliers.id) the tour comes from; a soft key,
--                      never a foreign key (root ADR 0008: no constraint across owners). provider stays the name in
--                      the sheet. NULL = not linked yet (the "unlinked tours" report of the workspace).
--        entry_origin  text NOT NULL DEFAULT 'sheet' — how the source tour entered CIS: sheet (the Excel upload, every
--                      existing row) or manual (created in the content workspace). CHECK on the two values.
--        manual_facts  jsonb, NULL — the structured facts of a hand-made tour (day cards with title, places, meals,
--                      overnight and description; inclusions; exclusions; nights; group size; tour type; guide
--                      languages; best time to go). The text columns (src_itineraries, inclusions, exclusions,
--                      duration, group_size, best_time_to_go) are rendered from it on every save, so S1, the
--                      re-validation, atomize and every reader keep reading the text. CHECK: NULL or an object.
--      One partial index raw_tours_supplier_idx (supplier_id) WHERE supplier_id IS NOT NULL (the workspace list and the
--      unlinked report filter on it).
--   2. Seven rows in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), app cis, area content, platform scope, enforced (read by
--      services/content_workspace/policy.py, the same file in this PR and the code PR):
--        cis.content.manual_tour.max_days        int days 1..60, default 21 (the longest AA program today is 18 days)
--        cis.content.manual_tour.min_inclusions  int items 0..20, default 3 (the S285 required list)
--        cis.content.manual_tour.min_exclusions  int items 0..20, default 1 (the S285 required list)
--        cis.content.supplier_link.bulk_max      int tours 1..500, default 100 (one bulk link action)
--      and three business option lists of the form, data an administrator edits, not code lists (the Booking bk-067
--      pattern of supplier_profile_option, kept here as settings: no new table):
--        cis.content.manual_tour.tour_types      json, the tour types [{code, label, label_vi}] (private, join_in)
--        cis.content.manual_tour.quick_inclusions list, the one-click "included" items of the form
--        cis.content.manual_tour.quick_exclusions list, the one-click "not included" items of the form
--      Each seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   3. Register 478.
--
-- Behaviour on apply. Every existing row gets entry_origin 'sheet' (a constant default: no table rewrite on
-- PostgreSQL 15), supplier_id and manual_facts NULL. Nothing on main reads the columns or the keys before the code PR.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): it ALTERs an existing table (columns, a CHECK,
-- an index) and INSERTs config rows. MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply when every
-- job table is idle (root ADR 0017a), then the code PR, which raises readiness to 478. DM-6.1: no personal data
-- (ids, a code and tour facts typed by staff; the workspace form says not to type personal data). DM-7.1: no new table
-- (the columns live and die with their raw_tours row).
--
-- Number. Owner main max (477) + 1. If the owner main max + 1 differs at merge, renumber (git grep '478_' and '478'
-- here, in tests/integration/test_aa1148_migration_478.py, api/core/readiness.py of the code PR,
-- shared/settings/compiled_defaults.json and docs/implementation-notes/AA-1148.md).
--
-- Locks. ALTER TABLE ... ADD COLUMN (three, metadata only), ADD CONSTRAINT ... CHECK on ~1k rows, CREATE INDEX on
-- ~1k rows (not CONCURRENTLY: the file is one transaction; the table is small), one INSERT of seven rows.
-- lock_timeout 5s, statement_timeout 1min. Idempotent (IF NOT EXISTS, a guarded constraint add, ON CONFLICT DO
-- NOTHING), one transaction, self-registering.
--
-- Rollback (a NEW forward migration, after the code PR is reverted): DELETE the keys' value rows, then the keys; DROP
-- the index, the constraints and the three columns.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

DO $$
BEGIN
    IF to_regclass('silver_aa_internal.raw_tours') IS NULL THEN
        RAISE EXCEPTION 'migration 478: silver_aa_internal.raw_tours missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'shared' AND table_name = 'setting_definition' AND column_name = 'guide') THEN
        RAISE EXCEPTION 'migration 478: shared.setting_definition.guide missing (apply 416 first)';
    END IF;
END $$;

-- ── 1. raw_tours columns ─────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE silver_aa_internal.raw_tours ADD COLUMN IF NOT EXISTS supplier_id uuid;
ALTER TABLE silver_aa_internal.raw_tours ADD COLUMN IF NOT EXISTS entry_origin text NOT NULL DEFAULT 'sheet';
ALTER TABLE silver_aa_internal.raw_tours ADD COLUMN IF NOT EXISTS manual_facts jsonb;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'raw_tours_entry_origin_chk'
                     AND conrelid = 'silver_aa_internal.raw_tours'::regclass) THEN
        ALTER TABLE silver_aa_internal.raw_tours
            ADD CONSTRAINT raw_tours_entry_origin_chk CHECK (entry_origin IN ('sheet', 'manual'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'raw_tours_manual_facts_chk'
                     AND conrelid = 'silver_aa_internal.raw_tours'::regclass) THEN
        ALTER TABLE silver_aa_internal.raw_tours
            ADD CONSTRAINT raw_tours_manual_facts_chk
            CHECK (manual_facts IS NULL OR jsonb_typeof(manual_facts) = 'object');
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS raw_tours_supplier_idx
    ON silver_aa_internal.raw_tours (supplier_id) WHERE supplier_id IS NOT NULL;

COMMENT ON COLUMN silver_aa_internal.raw_tours.supplier_id IS
    'AA-1148 (CIS 478): the AA supplier of AA-Booking this tour comes from (booking.v_supply_suppliers.id, contract '
    'supply.supplier.v1; a soft key, no foreign key across owners). NULL = not linked yet. provider keeps the sheet '
    'name.';
COMMENT ON COLUMN silver_aa_internal.raw_tours.entry_origin IS
    'AA-1148 (CIS 478): how the source tour entered CIS: sheet (Excel upload) or manual (content workspace).';
COMMENT ON COLUMN silver_aa_internal.raw_tours.manual_facts IS
    'AA-1148 (CIS 478): the structured facts of a hand-made tour (day cards, inclusions, exclusions, nights, group '
    'size, tour type, guide languages, best time to go); the text columns are rendered from it on every save.';

-- ── 2. settings ──────────────────────────────────────────────────────────────────────────────────────────────────
-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$
[
{"key": "cis.content.manual_tour.max_days", "app": "cis", "area": "content", "label": "Hand-made tour: most day cards", "description": "The most day cards a hand-made tour may have in the content workspace (/admin/content-workspace). A form with more days is refused with a plain message, so a typing slip (a tour of 300 days) never reaches the pipeline. Read by services/content_workspace/policy.py.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 60, "allowed_values": null, "default_value": 21, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "How many days a tour made by hand in the content workspace may last at most.", "raise": "Higher: longer programs can be entered by hand, but a typing slip in the number of days is caught later.", "lower": "Lower: slips are caught sooner, but a long program has to come in by Excel.", "when": "Raise it when AA sells a program longer than the value; lower it only if long programs never come by hand.", "example": "With the default 21: a 24-day program cannot be made by hand; the form says the most is 21 days."}, "vi": {"what": "Tour tạo tay trong khu làm nội dung được dài tối đa bao nhiêu ngày.", "raise": "Cao hơn: nhập tay được chương trình dài hơn, nhưng gõ nhầm số ngày bị phát hiện muộn hơn.", "lower": "Thấp hơn: gõ nhầm bị phát hiện sớm hơn, nhưng chương trình dài phải nhập bằng Excel.", "when": "Tăng khi AA bán chương trình dài hơn giá trị này; chỉ giảm khi không bao giờ nhập tay chương trình dài.", "example": "Với mặc định 21: chương trình 24 ngày không tạo tay được; form báo tối đa 21 ngày."}}},
{"key": "cis.content.manual_tour.min_exclusions", "app": "cis", "area": "content", "label": "Hand-made tour: items not included, at least", "description": "How many \"What is not included\" items a hand-made tour needs before it can be published (the required list of the content workspace; the draft publish refuses a tour below it with 409 required_missing). 0 turns the rule off. Read by services/content_workspace/policy.py.", "value_type": "int", "unit": "items", "min_value": 0, "max_value": 20, "allowed_values": null, "default_value": 1, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "How many items a hand-made tour must list under \"What is not included\" before it can be published.", "raise": "Higher: travellers see more clearly what they pay for themselves, but staff must find more items before publishing.", "lower": "Lower: tours publish with less checking; 0 lets a tour publish with no exclusions at all.", "when": "Raise it if agencies report surprise costs; lower it for programs where almost everything is included.", "example": "With the default 1: a tour that lists no exclusion stays a draft and the required list shows \"Not included: add at least 1 item\"."}, "vi": {"what": "Tour tạo tay phải ghi ít nhất bao nhiêu mục trong \"Không bao gồm\" mới được xuất bản.", "raise": "Cao hơn: khách thấy rõ hơn những khoản tự trả, nhưng nhân viên phải tìm thêm mục trước khi xuất bản.", "lower": "Thấp hơn: tour được xuất bản với ít kiểm tra hơn; 0 cho phép xuất bản khi không có mục nào.", "when": "Tăng nếu đại lý báo khách bị bất ngờ về chi phí; giảm cho chương trình gần như trọn gói.", "example": "Với mặc định 1: tour chưa ghi mục không bao gồm nào vẫn là nháp, danh sách bắt buộc hiện \"Không bao gồm: thêm ít nhất 1 mục\"."}}},
{"key": "cis.content.manual_tour.min_inclusions", "app": "cis", "area": "content", "label": "Hand-made tour: items included, at least", "description": "How many \"What is included\" items a hand-made tour needs before it can be published (the required list of the content workspace; the draft publish refuses a tour below it with 409 required_missing). 0 turns the rule off. Read by services/content_workspace/policy.py.", "value_type": "int", "unit": "items", "min_value": 0, "max_value": 20, "allowed_values": null, "default_value": 3, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "How many items a hand-made tour must list under \"What is included\" before it can be published.", "raise": "Higher: tours describe what the price covers in more detail, but staff must enter more items before publishing.", "lower": "Lower: tours publish with less detail; 0 lets a tour publish with no inclusions at all.", "when": "Raise it if agencies ask what a tour covers; lower it for very simple programs such as a single transfer.", "example": "With the default 3: a tour that lists transport and a guide but nothing else stays a draft until a third item (for example entrance fees) is added."}, "vi": {"what": "Tour tạo tay phải ghi ít nhất bao nhiêu mục trong \"Bao gồm\" mới được xuất bản.", "raise": "Cao hơn: tour mô tả kỹ hơn giá đã gồm những gì, nhưng nhân viên phải nhập nhiều mục hơn trước khi xuất bản.", "lower": "Thấp hơn: tour được xuất bản với ít chi tiết hơn; 0 cho phép xuất bản khi không có mục nào.", "when": "Tăng nếu đại lý hay hỏi tour gồm những gì; giảm cho chương trình rất đơn giản như một chuyến đưa đón.", "example": "Với mặc định 3: tour chỉ ghi xe và hướng dẫn viên vẫn là nháp cho tới khi thêm mục thứ ba (ví dụ vé tham quan)."}}},
{"key": "cis.content.supplier_link.bulk_max", "app": "cis", "area": "content", "label": "Supplier link: most tours in one action", "description": "The most tours one \"Link to supplier\" action of the unlinked tours report may change (the bulk link and the apply of the suggested matches). A larger selection is refused with a plain message; do it in parts. Read by services/content_workspace/policy.py.", "value_type": "int", "unit": "tours", "min_value": 1, "max_value": 500, "allowed_values": null, "default_value": 100, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "How many tours one bulk \"Link to supplier\" action may change at once.", "raise": "Higher: the old tours are linked in fewer clicks, but a wrong choice changes more tours at once.", "lower": "Lower: a wrong choice touches fewer tours, but linking a large catalogue takes more rounds.", "when": "Raise it for a one-off clean-up of many old tours; lower it again after the clean-up.", "example": "With the default 100: 140 tours of one supplier are linked in two actions, 100 and then 40."}, "vi": {"what": "Một lần \"Gắn nhà cung cấp\" hàng loạt được đổi tối đa bao nhiêu tour.", "raise": "Cao hơn: gắn tour cũ ít lần bấm hơn, nhưng chọn nhầm thì đổi nhiều tour cùng lúc.", "lower": "Thấp hơn: chọn nhầm chỉ ảnh hưởng ít tour, nhưng gắn cả danh mục lớn mất nhiều lượt hơn.", "when": "Tăng khi dọn một lần nhiều tour cũ; giảm lại sau khi dọn xong.", "example": "Với mặc định 100: 140 tour của một nhà cung cấp được gắn trong hai lần, 100 rồi 40."}}},
{"key": "cis.content.manual_tour.quick_exclusions", "app": "cis", "area": "content", "label": "Hand-made tour: one-click \"not included\" items", "description": "The common \"What is not included\" items the content workspace offers as one-click chips under the list of a hand-made tour (English: the tour's content language). A chip adds its text to raw_tours.exclusions, which customers read after the pipeline, so this is customer-facing wording. Staff can still type any other item. Each item is plain text of at most 200 characters; an empty list shows no chips. Read by services/content_workspace/policy.py.", "value_type": "list", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": ["International flights", "Travel insurance", "Drinks", "Tips", "Personal expenses", "Visa fees"], "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The \"not included\" items staff can add to a hand-made tour with one click.", "raise": "Adding items: staff fill the list faster and in the same words across tours, but a long row of chips is harder to scan.", "lower": "Removing items: fewer chips to read; staff type the removed items by hand when a tour needs them.", "when": "Add an item that staff type on many tours (for example domestic flights); remove one that no AA program uses any more.", "example": "With the default list, one click adds \"Travel insurance\" to the tour's \"What is not included\" list."}, "vi": {"what": "Các mục \"Không bao gồm\" nhân viên thêm vào tour tạo tay chỉ bằng một cú bấm.", "raise": "Thêm mục: nhân viên điền nhanh hơn và dùng cùng một cách viết cho mọi tour, nhưng hàng nút dài khó đọc hơn.", "lower": "Bớt mục: ít nút phải đọc hơn; khi tour cần mục đã bỏ thì nhân viên gõ tay.", "when": "Thêm mục nhân viên hay gõ trên nhiều tour (ví dụ vé máy bay nội địa); bỏ mục không chương trình AA nào còn dùng.", "example": "Với danh sách mặc định, một cú bấm thêm \"Travel insurance\" vào danh sách \"Không bao gồm\" của tour."}}},
{"key": "cis.content.manual_tour.quick_inclusions", "app": "cis", "area": "content", "label": "Hand-made tour: one-click \"included\" items", "description": "The common \"What is included\" items the content workspace offers as one-click chips under the list of a hand-made tour (English: the tour's content language). A chip adds its text to raw_tours.inclusions, which customers read after the pipeline, so this is customer-facing wording. Staff can still type any other item. Each item is plain text of at most 200 characters; an empty list shows no chips. Read by services/content_workspace/policy.py.", "value_type": "list", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": ["Private transport", "English-speaking guide", "Entrance fees", "Meals as listed", "Accommodation as listed", "Drinking water"], "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The \"included\" items staff can add to a hand-made tour with one click.", "raise": "Adding items: staff fill the list faster and in the same words across tours, but a long row of chips is harder to scan.", "lower": "Removing items: fewer chips to read; staff type the removed items by hand when a tour needs them.", "when": "Add an item that staff type on many tours (for example boat tickets); remove one that no AA program uses any more.", "example": "With the default list, one click adds \"Entrance fees\" to the tour's \"What is included\" list."}, "vi": {"what": "Các mục \"Bao gồm\" nhân viên thêm vào tour tạo tay chỉ bằng một cú bấm.", "raise": "Thêm mục: nhân viên điền nhanh hơn và dùng cùng một cách viết cho mọi tour, nhưng hàng nút dài khó đọc hơn.", "lower": "Bớt mục: ít nút phải đọc hơn; khi tour cần mục đã bỏ thì nhân viên gõ tay.", "when": "Thêm mục nhân viên hay gõ trên nhiều tour (ví dụ vé tàu thuyền); bỏ mục không chương trình AA nào còn dùng.", "example": "Với danh sách mặc định, một cú bấm thêm \"Entrance fees\" vào danh sách \"Bao gồm\" của tour."}}},
{"key": "cis.content.manual_tour.tour_types", "app": "cis", "area": "content", "label": "Hand-made tour: tour types", "description": "The tour types staff choose from on a hand-made tour, in the order shown: a list of objects {\"code\": lower-case letters, digits and underscores, \"label\": the English name rendered into the tour's source text as \"Tour type: <label>\" (customers can read it after the pipeline), \"label_vi\": optional Vietnamese name for the admin form}. A save accepts only a listed code, or the code the tour already holds; removing a type never breaks a tour that has it (the tour keeps the label it was saved with). Read by services/content_workspace/policy.py.", "value_type": "json", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": [{"code": "private", "label": "Private tour", "label_vi": "Tour riêng"}, {"code": "join_in", "label": "Join-in group tour", "label_vi": "Tour ghép đoàn"}], "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The kinds of tour (private, join-in and so on) staff can pick for a tour made by hand.", "raise": "Adding a type: staff can describe more kinds of program (for example small group or self-guided), and the new name reaches the tour text.", "lower": "Removing a type: staff can no longer pick it for a new tour; tours that already have it keep it.", "when": "Add a type when AA starts selling a new kind of program; rename a label to change the words the tour text uses from the next save.", "example": "With the default list, staff pick \"Private tour\" or \"Join-in group tour\", and the tour's source text says \"Tour type: Private tour\"."}, "vi": {"what": "Các loại tour (tour riêng, ghép đoàn...) nhân viên chọn được cho tour tạo tay.", "raise": "Thêm loại: nhân viên mô tả được nhiều kiểu chương trình hơn (ví dụ nhóm nhỏ, tự đi), và tên mới đi vào nội dung tour.", "lower": "Bớt loại: không chọn được loại đó cho tour mới nữa; tour đã có loại đó vẫn giữ nguyên.", "when": "Thêm khi AA bắt đầu bán kiểu chương trình mới; đổi nhãn để đổi chữ trong nội dung tour từ lần lưu kế tiếp.", "example": "Với danh sách mặc định, nhân viên chọn \"Private tour\" hoặc \"Join-in group tour\", và nội dung nguồn của tour ghi \"Tour type: Private tour\"."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── Post-checks ──────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT count(*) FROM information_schema.columns
         WHERE table_schema = 'silver_aa_internal' AND table_name = 'raw_tours'
           AND column_name IN ('supplier_id', 'entry_origin', 'manual_facts')) <> 3 THEN
        RAISE EXCEPTION 'migration 478: raw_tours is missing a new column';
    END IF;
    IF (SELECT count(*) FROM shared.setting_definition
         WHERE key IN ('cis.content.manual_tour.max_days', 'cis.content.manual_tour.min_inclusions',
                       'cis.content.manual_tour.min_exclusions', 'cis.content.supplier_link.bulk_max',
                       'cis.content.manual_tour.tour_types', 'cis.content.manual_tour.quick_inclusions',
                       'cis.content.manual_tour.quick_exclusions')) <> 7 THEN
        RAISE EXCEPTION 'migration 478: a content workspace setting is missing';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('478', now(), 'AA-1148: raw_tours supplier_id / entry_origin / manual_facts and the content workspace settings')
ON CONFLICT (version) DO NOTHING;

COMMIT;
