-- Migration 488: AA-1141 (S292, status page noise) — how many sampler ticks in a row a database login role must stay
-- above its connection alert share before the in-app check rds_role_connections alerts, as a setting.
--
-- Why. The Ecosystem status page listed "Database role near its connection limit: crm_app 5/6" (S292) only while the
-- partner CRM was rolling out: its role has CONNECTION LIMIT 6 = pool max_size 3 x 2 tasks because the old and the new
-- task overlap for a few minutes during a rolling deploy (AA-Partner api/app/db.py, AA-CIS-Infra
-- db/connection_budget.json, data standard C2.2). The limit is sized for that overlap, so one sample above the line
-- (cis.ops.role_connections_pct, CIS 469) during a deploy is expected, not a problem. The tech lead chose to fix the
-- check, not the line: the check now alerts only when the role stays above the line on this many consecutive ticks of
-- the api's ops sampler (5 minutes apart); a real, lasting near-limit role still alerts. The count is a setting, never
-- a code literal (tech lead S279).
--
-- What:
--   1. One row in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), app cis, area "ops", scope platform, impact medium (it delays
--      a real alert), maker-checker, no evidence, no env override, enforced (shared/ops_thresholds.py names the key in
--      this PR, the settings-lint reader check; the code PR reads it):
--        cis.ops.role_connections_samples   int samples 1-12, default 3 (1 = the behaviour before S292)
--      The seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 488.
--
-- Behaviour on apply. None for running code: no value row is seeded and the code on main reads no such key. After the
-- code PR the check reads the default until an administrator changes it.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a config row INSERTed into an existing table.
-- MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a), then
-- the code PR (readiness requires 488). DM-6.1: no personal data. DM-7.1: no new table.
--
-- Number. Owner main max (487, AA-1154) + 1. If the owner main max + 1 differs at merge, renumber (git grep '488_' and
-- '488' here, in tests/integration/test_aa1141_migration_488.py, compiled_defaults.json's _generated line,
-- api/core/readiness.py and docs/implementation-notes/AA-1141.md).
--
-- Locks. One INSERT ... ON CONFLICT of one row (the definition guard trigger allows the file's role, cis_owner).
-- lock_timeout 5s. Re-runnable: ON CONFLICT DO NOTHING keeps a row an earlier run wrote.
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
  FROM jsonb_to_recordset($seed$
[
{"key": "cis.ops.role_connections_samples", "app": "cis", "area": "ops", "label": "Ops check: database role connections, samples in a row", "description": "The in-app check rds_role_connections alerts only when a LOGIN role of the shared database stays above cis.ops.role_connections_pct on this many consecutive ticks of the api's ops sampler (one tick every 5 minutes). During a rolling deploy the old and the new task of an app overlap for a few minutes, and the role's CONNECTION LIMIT is sized for that overlap (data standard C2.2), so a short peak is expected; a lasting one still alerts. 1 alerts on the first tick above the line (the behaviour before S292). Counted per api task: an api restart starts the count again.", "value_type": "int", "unit": "samples", "min_value": 1, "max_value": 12, "allowed_values": null, "default_value": 3, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How many 5-minute samples in a row a database login role must stay above its connection alert share before the check alerts.", "raise": "Fewer alerts from deploys, but a role that is really near its limit alerts later (5 more minutes per sample).", "lower": "Earlier alerts, but a rolling deploy, whose old and new tasks overlap for a few minutes, may alert; 1 alerts on every single sample.", "when": "Raise it when deploys still raise the alert; lower it when a role ran out of connections before the alert came.", "example": "With the default 3, a role above the line at 10:00, 10:05 and 10:10 alerts at 10:10; a role above it only at 10:00, during a deploy, does not."}, "vi": {"what": "Một role đăng nhập database phải vượt ngưỡng cảnh báo kết nối bao nhiêu lần lấy mẫu 5 phút liên tiếp thì kiểm tra mới cảnh báo.", "raise": "Ít cảnh báo do deploy hơn, nhưng một role thật sự sắp chạm giới hạn sẽ được báo muộn hơn (thêm 5 phút cho mỗi mẫu).", "lower": "Báo sớm hơn, nhưng một lần deploy cuốn chiếu, khi task cũ và task mới chạy chồng nhau vài phút, có thể gây cảnh báo; 1 thì báo ngay mẫu đầu tiên.", "when": "Tăng khi deploy vẫn gây cảnh báo; giảm khi một role đã hết kết nối mà cảnh báo chưa tới.", "example": "Với mặc định 3, một role vượt ngưỡng lúc 10:00, 10:05 và 10:10 sẽ cảnh báo lúc 10:10; một role chỉ vượt lúc 10:00, trong lúc deploy, thì không."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('488', now(), 'AA-1141: role connections check samples in a row (rolling deploy overlap)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
