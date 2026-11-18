-- Migration 449: AA-1127 (S284, UI audit batch C1) — the AI gateway's idle window in the platform settings registry
-- (CIS 407; tech lead S279: a threshold, limit, cap or policy value is a setting on Platform › Settings, never a code
-- literal or an env var alone).
--
-- Why. The S283 UI audit (root docs/audits/2026-11-17-S283-fe-audit, CIS row 13) found that the "Need a look" tile of
-- AI gateway › Providers counted connections that were only idle: api/services/llm_availability.py turned a healthy
-- connection to status unknown once its newest answered call was older than STALE_OK_HOURS = 6 (a code literal), the row
-- badge then said "No recent calls", but the tile counted the row as needing a look, so the number moved with the probe
-- timing (8 of 13, then 4 of 13). The code PR makes the tile follow the badge (an idle row is left out) and reads the
-- window from this key, so the tile, the badge and the status use one value an administrator can change.
--
-- What:
--   1. One row in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), area "ai", scope platform, impact low, single approval, no
--      evidence, no env override, enforced (api/services/gateway_health_settings.py names the key in this PR, the
--      settings-lint reader check; the code PR reads it through shared.settings):
--        cis.llm.idle_after_hours   int hours 1-168, default 6 (today's STALE_OK_HOURS)
--      The seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 449.
--
-- Behaviour on apply. None for running code: no value row is seeded and nothing on main reads the key; after the code
-- PR the gateway reads the default (6, today's value) until an administrator changes it.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a config row INSERTed into an existing table.
-- MIG-4: the AA-1127 migration-only PR (448-449, one batch), applied on Dev by Infra Migration Apply when the job tables
-- are idle (ADR 0017a), then the code PR (no readiness raise: the reader falls back to the compiled defaults). DM-6.1:
-- no personal data. DM-7.1: no new table.
--
-- Number. 448 (this PR) + 1 (448 names the wave's order: this batch merges first, 450-453 follow). If the owner main
-- max + 1 differs at merge, renumber (git grep '449_' and '449' here, in
-- tests/integration/test_aa1127_migration_449.py, compiled_defaults.json and docs/implementation-notes/AA-1127.md).
--
-- Locks. One INSERT of one row (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
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
{"key": "cis.llm.idle_after_hours", "app": "cis", "area": "ai", "label": "AI gateway: hours without a call before a connection reads idle", "description": "AI gateway > Providers (api/services/llm_availability.py): a connection or model with no failure since its newest answered call reads ok while that call is at most this many hours old, then unknown with no reason, shown as No recent calls. The Need a look tile leaves such an idle row out (frontend/lib/aiGateway.ts needsLook follows the row badge). A failure newer than the answered call still reads blocked or degraded at once, whatever this value.", "value_type": "int", "unit": "hours", "min_value": 1, "max_value": 168, "allowed_values": null, "default_value": 6, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "How long a working AI connection keeps its green ok badge on AI gateway > Providers after its last answered call. After that it shows No recent calls and is not counted in Need a look.", "raise": "A connection used only now and then stays green longer; a connection that silently stopped answering also looks fine for longer.", "lower": "The page tells you sooner that a connection has not been used; quiet connections show No recent calls more often.", "when": "Raise it when connections that are only used a few times a day keep showing No recent calls; lower it when you want to notice an unused connection sooner.", "example": "With the default of 6 hours, a connection whose last answered call was 7 hours ago shows No recent calls and the Need a look tile does not count it."}, "vi": {"what": "Một kết nối AI đang chạy tốt giữ nhãn xanh ok trên AI gateway > Providers bao lâu sau lần gọi có trả lời gần nhất. Sau mốc đó nó hiện No recent calls và không được tính vào ô Need a look.", "raise": "Kết nối chỉ thỉnh thoảng mới dùng giữ màu xanh lâu hơn; kết nối âm thầm ngừng trả lời cũng trông như bình thường lâu hơn.", "lower": "Trang báo sớm hơn rằng một kết nối chưa được dùng; kết nối ít dùng hiện No recent calls thường hơn.", "when": "Tăng khi các kết nối chỉ dùng vài lần mỗi ngày cứ hiện No recent calls; giảm khi muốn biết sớm hơn một kết nối không được dùng.", "example": "Với mặc định 6 giờ, kết nối có lần gọi trả lời gần nhất cách đây 7 giờ hiện No recent calls và ô Need a look không tính nó."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('449', now(), 'AA-1127: the AI gateway idle window (cis.llm.idle_after_hours) in the settings registry')
ON CONFLICT (version) DO NOTHING;

COMMIT;
