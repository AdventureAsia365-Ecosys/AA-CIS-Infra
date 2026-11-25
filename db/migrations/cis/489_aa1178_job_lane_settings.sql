-- Migration 489: AA-1178 (S292) — the two running caps of the CIS job runner's side lanes as settings: the long
-- background jobs a worker runs at once, and the new monitoring lane.
--
-- Why. Every background job kind shared one group capped at one running job per worker (code constant
-- BACKGROUND_MAX_RUNNING = 1, AA-712 / S217: background batches must not take a wave's slots). The short monitoring
-- kinds (the status page sampler, the AI route and quality watchers, the usage rollup, the connection probe, the model
-- lifecycle sync, the compliance database checks) are background too, so they queued behind any long background job:
-- on Dev 25/11/2026 the paid T9 re-measure (writing_memory_r2, expected 5,400 s) held them 40+ minutes and the
-- Ecosystem status page and the route / spend watchers stopped refreshing. The code PR gives those kinds their own lane
-- (monitor=True on @job_kind): slots of their own on top of the worker's main slots, with a small cap, so they never
-- wait behind a long background job and never take a slot a wave or a content job could use. Both caps are settings (tech lead S279: a cap is a setting,
-- maker-checker and audited, never a code literal), with today's value as the background default.
--
-- What:
--   1. Two rows in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), app cis, area "ops", scope platform, impact medium,
--      maker-checker, no evidence, no env override, enforced (shared/jobs/lanes.py names both keys, the settings-lint
--      reader check):
--        cis.ops.jobs_background_max_running   int jobs 1-4, default 1 (the AA-712 group cap, unchanged)
--        cis.ops.jobs_monitor_max_running      int jobs 1-4, default 2 (the monitoring lane)
--      Each seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 489.
--
-- Behaviour on apply. None for running code: no value row is seeded and the code on main reads neither key. After the
-- code PR the worker and the ops metrics sampler read the defaults until an administrator changes them.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): config rows INSERTed into an existing table.
-- MIG-4: a migration-only PR (with CIS 488), applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a), then
-- the code PR. No readiness raise: the reader serves the compiled defaults while the rows are missing. DM-6.1: no
-- personal data. DM-7.1: no new table.
--
-- Number. Owner main max (487) + 2, after CIS 488 (role connections samples) of the same S292 CIS migration batch
-- (488-489, one migration-only PR). If the owner main max + 1 differs at merge, renumber: git grep '489_' and "'489'" (this file, tests/integration/test_aa1178_migration_489.py,
-- compiled_defaults.json's _generated line, docs/implementation-notes/AA-1178.md).
--
-- Locks. One INSERT ... ON CONFLICT of two rows (the definition guard trigger allows the file's role, cis_owner).
-- lock_timeout 5s. Re-runnable: ON CONFLICT DO NOTHING keeps a row an earlier run wrote.
--
-- Rollback (a new forward migration, after the code PR is reverted): DELETE the two keys' value rows first, then the
-- keys.

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
{"key": "cis.ops.jobs_background_max_running", "app": "cis", "area": "ops", "label": "Job runner: long background jobs running at once (per worker)", "description": "The CIS job worker (shared/jobs/worker.py claim_caps_for) runs at most this many long background jobs at once on each worker: the place pipeline, retention, the writing-memory runs, reports and the other background kinds, all together. Monitoring kinds have their own lane (cis.ops.jobs_monitor_max_running) and are not counted here. Background jobs also never take the worker's last two free slots, so a wave keeps its slots. The ops metrics sampler (shared/jobs/backlog.py) applies the same rule. Default 1, the value the worker has used since the S217 Nepal wave.", "value_type": "int", "unit": "jobs", "min_value": 1, "max_value": 4, "allowed_values": null, "default_value": 1, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How many long background jobs (place pipeline, retention, writing-memory runs, reports) one worker runs at the same time.", "raise": "A backlog of background batches drains sooner, but each one holds a worker slot a wave's rewrites or atomize jobs could use.", "lower": "1 is the lowest: background batches run one after another and leave the most slots to waves and content jobs.", "when": "Raise it for a large background backlog while no wave runs; set it back to 1 before a wave starts.", "example": "With the default 1, while a 90-minute writing-memory run is going, the next background batch waits for it to finish."}, "vi": {"what": "Số job nền dài (pipeline địa điểm, retention, các lượt writing-memory, báo cáo) một worker chạy cùng lúc.", "raise": "Hàng đợi job nền chạy xong sớm hơn, nhưng mỗi job giữ một slot worker mà job viết lại hoặc atomize của wave có thể dùng.", "lower": "Thấp nhất là 1: các job nền chạy lần lượt và để lại nhiều slot nhất cho wave và job nội dung.", "when": "Tăng khi tồn nhiều job nền mà không có wave nào chạy; đặt lại 1 trước khi bắt đầu wave.", "example": "Với mặc định 1, khi một lượt writing-memory 90 phút đang chạy, job nền tiếp theo chờ nó xong."}}},
{"key": "cis.ops.jobs_monitor_max_running", "app": "cis", "area": "ops", "label": "Job runner: monitoring jobs running at once (per worker)", "description": "The CIS job worker (shared/jobs/worker.py claim_caps_for) runs the short monitoring kinds (the status page sampler, the AI route and quality watchers, the usage rollup, the connection probe, the model lifecycle sync and the compliance database checks; registered with monitor=True) in their own lane: they never wait behind a long background job and never count toward cis.ops.jobs_background_max_running. At most this many of them run at once on each worker, in slots of their own on top of the worker's main slots, so they never take a slot a wave or a content job could use, and they keep running while a wave fills the main slots. The ops metrics sampler (shared/jobs/backlog.py) applies the same rule. Default 2.", "value_type": "int", "unit": "jobs", "min_value": 1, "max_value": 4, "allowed_values": null, "default_value": 2, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How many monitoring jobs (status page sampler, route and quality watchers, usage rollup, connection probe) one worker runs at the same time, in their own slots beside the long background jobs and the waves.", "raise": "A slow monitoring job (a usage backfill, a connection probe) holds up the others less, but more of them use the worker's database connections and CPU at the same time.", "lower": "1 is the lowest: monitoring jobs run one after another, so a slow one delays the status page sample behind it.", "when": "Raise it when the status page or the route watcher falls behind while a slow monitoring job runs; keep the default otherwise.", "example": "With the default 2, the 5-minute status sample still runs while the usage rollup backfill, a long writing-memory run and a wave are all going."}, "vi": {"what": "Số job giám sát (bộ lấy mẫu trang trạng thái, theo dõi tuyến AI và chất lượng, tổng hợp mức dùng, kiểm kết nối) một worker chạy cùng lúc, trong slot riêng bên cạnh các job nền dài và các wave.", "raise": "Một job giám sát chậm (backfill mức dùng, kiểm kết nối) ít làm các job khác phải chờ hơn, nhưng nhiều job hơn dùng kết nối database và CPU của worker cùng lúc.", "lower": "Thấp nhất là 1: các job giám sát chạy lần lượt, nên một job chậm làm mẫu của trang trạng thái phía sau phải chờ.", "when": "Tăng khi trang trạng thái hoặc bộ theo dõi tuyến bị trễ trong lúc một job giám sát chậm đang chạy; còn lại giữ mặc định.", "example": "Với mặc định 2, mẫu trạng thái 5 phút vẫn chạy khi backfill tổng hợp mức dùng, một lượt writing-memory dài và một wave cùng đang chạy."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('489', now(), 'AA-1178: job runner lane caps as settings (long background jobs, monitoring lane)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
