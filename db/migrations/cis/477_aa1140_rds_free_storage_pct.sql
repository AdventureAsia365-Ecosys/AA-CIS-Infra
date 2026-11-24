-- Migration 477: AA-1140 (S289 live check, the Ecosystem status page) — the database free storage limits as a share of
-- the allocated storage instead of a fixed size in GiB.
--
-- Why. The status page raised "Free storage 14.83 GiB, at or below the warn limit 15" as a SEV3 item on Dev. The
-- shared database has 20 GiB allocated with storage autoscaling up to 100 GiB, and its free space has been flat at about
-- 14.8 GiB for 14 days: nothing is wrong. A fixed GiB limit (CIS 475, cis.ops.status_rds_free_storage_*_gib, default
-- 15 / 10) cannot fit a small volume that autoscaling grows; a share of the allocated size follows the volume.
--
-- What:
--   1. Two rows in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), app cis, area "ops", scope platform, impact low,
--      maker-checker, no evidence, no env override, enforced (shared/ops_status_thresholds.py reads both):
--        cis.ops.status_rds_free_warn_pct   pct % 5-60, default 20 (amber, SEV3)
--        cis.ops.status_rds_free_crit_pct   pct % 2-50, default 10 (red, SEV2; RDS autoscaling grows the volume
--                                           when free space drops under about 10 %)
--      The status sampler reads AllocatedStorage with DescribeDBInstances (free; the CIS task role already holds
--      rds:DescribeDBInstances) and the page compares FreeStorageSpace with this share of it.
--   2. The two CIS 475 GiB keys stay, as a deprecated fallback used only while the allocated size is unknown: their
--      label, description and guide say so (the same seed block, ON CONFLICT DO UPDATE of those three columns only;
--      every other column is the CIS 475 value, so the generator's "a later row replaces an earlier one" equals the
--      table). Values an administrator approved for them stay.
--   3. Register 477.
--
-- Behaviour on apply. None for running code: the page reads the compiled defaults until the code PR ships; no value
-- row is seeded.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): config rows INSERTed into an existing table
-- and an UPDATE of three text columns of two existing config rows. MIG-4: this migration-only PR first, applied on Dev
-- by Infra Migration Apply when the job tables are idle (ADR 0017a), then the code PR (no readiness raise: the reader
-- falls back to the compiled default). DM-6.1: no personal data. DM-7.1: no new table.
--
-- Number. Owner main max (476) + 1. If the owner main max + 1 differs at merge, renumber (git grep '477_' and '477'
-- here, in tests/integration/test_aa1140_migration_477.py and compiled_defaults.json's _generated line).
--
-- Locks. One INSERT ... ON CONFLICT of four rows (the definition guard trigger allows the file's role, cis_owner).
-- lock_timeout 5s. Re-runnable: the update rewrites equal values.
--
-- Rollback (a new forward migration, after the code PR is reverted): DELETE the two pct keys' value rows first, then
-- the keys; put the CIS 475 label, description and guide of the GiB keys back.

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
{"key": "cis.ops.status_rds_free_warn_pct", "app": "cis", "area": "ops", "label": "Status page: database free storage, warn (% of allocated)", "description": "On the Ecosystem status page (/admin/overview, api/services/ops_status/) the database storage tile (RDS FreeStorageSpace) turns amber (SEV3) when the free space falls to or below this share of the instance's allocated storage (AllocatedStorage, read by the 5-minute status sampler with DescribeDBInstances). A share follows the volume as storage autoscaling grows it; a fixed GiB limit raised a false alarm on a small autoscaling volume. Default 20 %.", "value_type": "pct", "unit": "%", "min_value": 5, "max_value": 60, "allowed_values": null, "default_value": 20, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How small a share of the database disk may be free before its tile turns amber. The share is of the disk size the database has now, so it follows the disk when storage autoscaling grows it.", "raise": "Earlier warning, but a small disk that autoscaling keeps growing may show amber often.", "lower": "Fewer amber tiles, but less time to act if autoscaling has reached its maximum size.", "when": "Raise it when data grows fast or autoscaling is near its maximum; lower it if the tile turns amber while autoscaling still has room.", "example": "With the default 20 % and a 20 GiB disk, the tile turns amber at 4 GiB free or less."}, "vi": {"what": "Phần trăm dung lượng đĩa database còn trống tối thiểu trước khi ô chuyển vàng. Phần trăm tính trên dung lượng đĩa hiện tại, nên tự theo khi storage autoscaling nới đĩa.", "raise": "Báo sớm hơn, nhưng đĩa nhỏ được autoscaling nới dần có thể hay chuyển vàng.", "lower": "Ô ít chuyển vàng hơn, nhưng còn ít thời gian xử lý nếu autoscaling đã chạm mức tối đa.", "when": "Tăng khi dữ liệu tăng nhanh hoặc autoscaling gần mức tối đa; giảm nếu ô chuyển vàng trong khi autoscaling vẫn còn chỗ nới.", "example": "Với mặc định 20 % và đĩa 20 GiB, ô chuyển vàng khi còn trống từ 4 GiB trở xuống."}}},
{"key": "cis.ops.status_rds_free_crit_pct", "app": "cis", "area": "ops", "label": "Status page: database free storage, critical (% of allocated)", "description": "On the Ecosystem status page (/admin/overview, api/services/ops_status/) the database storage tile turns red (SEV2) when the free space falls to or below this share of the instance's allocated storage. The page keeps it at or below the warn share. RDS storage autoscaling grows the volume when free space drops under about 10 %, so a red tile with autoscaling on usually means it reached its maximum size. Default 10 %.", "value_type": "pct", "unit": "%", "min_value": 2, "max_value": 50, "allowed_values": null, "default_value": 10, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How small a share of the database disk may be free before its tile turns red (SEV2).", "raise": "The tile turns red while autoscaling may still grow the disk on its own.", "lower": "Writes may fail soon after the tile turns red if autoscaling cannot grow the disk.", "when": "Keep it near the point where storage autoscaling grows the disk (about 10 % free).", "example": "With the default 10 % and a 20 GiB disk, 1.8 GiB free turns the tile red."}, "vi": {"what": "Phần trăm dung lượng đĩa database còn trống tối thiểu trước khi ô chuyển đỏ (SEV2).", "raise": "Ô chuyển đỏ trong khi autoscaling có thể vẫn tự nới đĩa.", "lower": "Lệnh ghi có thể lỗi ngay sau khi ô chuyển đỏ nếu autoscaling không nới được đĩa.", "when": "Giữ gần ngưỡng storage autoscaling nới đĩa (khoảng 10 % còn trống).", "example": "Với mặc định 10 % và đĩa 20 GiB, còn trống 1,8 GiB làm ô chuyển đỏ."}}},
{"key": "cis.ops.status_rds_free_storage_warn_gib", "app": "cis", "area": "ops", "label": "Status page: database free storage, warn (GiB, fallback)", "description": "Fallback only: the Ecosystem status page judges free storage as a share of the allocated storage (cis.ops.status_rds_free_warn_pct). This GiB value is used only while the allocated size is unknown (no fresh sampler row, or DescribeDBInstances refused). Then the database storage tile turns amber (SEV3) when the free space falls to or below it. Default 15 GiB.", "value_type": "numeric", "unit": "GiB", "min_value": 1, "max_value": 1000, "allowed_values": null, "default_value": 15, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "Fallback only. The free storage tile uses the share of allocated storage; this GiB value applies only while the database size cannot be read.", "raise": "While the size is unknown: earlier warning, but a small disk may show amber for weeks.", "lower": "While the size is unknown: less time to grow the disk before writes fail.", "when": "Change the percentage settings instead; touch this only if the size read keeps failing.", "example": "With the default 15 GiB and no size read, 12.4 GiB free turns the tile amber."}, "vi": {"what": "Chỉ dùng dự phòng. Ô dung lượng trống dùng phần trăm trên dung lượng cấp phát; giá trị GiB này chỉ áp dụng khi không đọc được dung lượng database.", "raise": "Khi không rõ dung lượng: báo sớm hơn, nhưng đĩa nhỏ có thể vàng hàng tuần.", "lower": "Khi không rõ dung lượng: ít thời gian nới đĩa hơn trước khi ghi bị lỗi.", "when": "Hãy chỉnh các cài đặt phần trăm; chỉ đổi giá trị này nếu việc đọc dung lượng liên tục lỗi.", "example": "Với mặc định 15 GiB và không đọc được dung lượng, còn trống 12,4 GiB làm ô chuyển vàng."}}},
{"key": "cis.ops.status_rds_free_storage_crit_gib", "app": "cis", "area": "ops", "label": "Status page: database free storage, critical (GiB, fallback)", "description": "Fallback only: the Ecosystem status page judges free storage as a share of the allocated storage (cis.ops.status_rds_free_crit_pct). This GiB value is used only while the allocated size is unknown; then the tile turns red (SEV2) when the free space falls to or below it. The page keeps it below the warn value. Default 10 GiB.", "value_type": "numeric", "unit": "GiB", "min_value": 0.5, "max_value": 1000, "allowed_values": null, "default_value": 10, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "Fallback only. The red line of the free storage tile while the database size cannot be read.", "raise": "While the size is unknown: the tile turns red while there is still room.", "lower": "While the size is unknown: writes may fail before the tile turns red.", "when": "Change the percentage settings instead; touch this only if the size read keeps failing.", "example": "With the default 10 GiB and no size read, 8 GiB free turns the tile red."}, "vi": {"what": "Chỉ dùng dự phòng. Ngưỡng đỏ của ô dung lượng trống khi không đọc được dung lượng database.", "raise": "Khi không rõ dung lượng: ô chuyển đỏ trong khi vẫn còn chỗ.", "lower": "Khi không rõ dung lượng: lệnh ghi có thể lỗi trước khi ô chuyển đỏ.", "when": "Hãy chỉnh các cài đặt phần trăm; chỉ đổi giá trị này nếu việc đọc dung lượng liên tục lỗi.", "example": "Với mặc định 10 GiB và không đọc được dung lượng, còn trống 8 GiB làm ô chuyển đỏ."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO UPDATE
   SET label = EXCLUDED.label, description = EXCLUDED.description, guide = EXCLUDED.guide;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('477', now(), 'AA-1140: database free storage limits as a share of the allocated storage (cis.ops.status_rds_free_*_pct)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
