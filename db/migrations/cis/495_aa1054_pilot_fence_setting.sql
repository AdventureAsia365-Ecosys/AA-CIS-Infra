-- Migration 495: AA-1054 (S297; tech lead decision S295 sec-Q11 "disable the Dev-only E2E identities on the pilot day,
-- not at go-live, and add a shared is_pilot fence") — the pilot fence switch in the platform settings registry
-- (CIS 407; tech lead S279: a policy value is a setting on Platform › Settings, never a code literal or an env var).
--
-- Why. Root ADR 0006a keeps a set of Dev-only E2E staff identities (A10 ... A10h, the addresses of the E2E mailbox
-- domain) so the agent's E2E suites can sign in without a person. ADR 0019 d16 lets one real agency (the pilot) work on
-- Dev. On the pilot day those identities must stop working everywhere at once, before their Cognito users are disabled
-- (AA-CIS-Infra tools/identity/e2e_identity_fence.py) and whatever that disable step misses. One switch, edited and
-- audited here, is read by the CIS API (the settings snapshot, api/core/pilot_fence.py in the code PR) and by the
-- AA-Booking API (catalog.v_pilot_fence_v1, CIS 496: read-only, no write grant across apps).
--
-- What:
--   1. One row in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), area "platform", scope platform, impact high, maker-checker,
--      no evidence, no env override (an env var must never open the fence again), enforced
--      (api/core/pilot_fence_settings.py names the key in this PR, the settings-lint reader check):
--        cis.platform.pilot_e2e_fence   bool, default false (today's behaviour: the E2E identities work on Dev)
--      The seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 495.
--
-- Behaviour on apply. None for running code: no value row is seeded and nothing on main reads the key; after the code
-- PRs the CIS and Booking APIs read the default (off) until an administrator turns it on.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a config row INSERTed into an existing table.
-- MIG-4: a migration-only PR with 496 (batch cis 495-496), applied on Dev by Infra Migration Apply when the job tables
-- are idle (ADR 0017a), then the code PRs (no readiness raise: the CIS reader falls back to the compiled defaults).
-- DM-6.1: no personal data. DM-7.1: no new table.
--
-- Number. Owner main max (494) + 1. If the owner main max + 1 differs at merge, renumber 495 and 496 together
-- (git grep '495_' and '496_', and '495' / '496' in both files, tests/integration/test_aa1054_migration_495.py,
-- tests/integration/test_aa1054_migration_496.py, tests/integration/conftest.py, compiled_defaults.json and
-- docs/implementation-notes/AA-1054.md).
--
-- Locks. One INSERT of one row (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
--
-- Rollback (a new forward migration, after the code PRs are reverted and 496's view is dropped): DELETE the key's value
-- rows first, then the key.

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
{"key": "cis.platform.pilot_e2e_fence", "app": "cis", "area": "platform", "label": "Pilot fence: refuse the Dev-only E2E staff accounts", "description": "On: the CIS API and the Booking API refuse every staff sign-in and every request of an E2E test account (any address of the E2E mailbox domain: the Dev-only test identities of the agent's automated checks), with 403 e2e_pilot_fence, whatever the account's own Dev-only rules allow. Both APIs also refuse those accounts (403 e2e_pilot_fence_unknown) while they cannot read this value; Booking reads it through the read-only view catalog.v_pilot_fence_v1. Off (default): the E2E test accounts work on Dev under their own rules, as today. Turn it on the day the pilot agency starts on Dev, before the test accounts are disabled in Cognito. Real staff accounts are never affected.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": false, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "Whether the automated E2E test accounts may still sign in to the CIS and Booking staff pages on Dev. They exist only so the agent can check the system without a person.", "raise": "On: every E2E test account is refused at sign-in and on every request in CIS and Booking, so none of them can see or touch the pilot agency's data. The automated E2E suites that sign in stop working.", "lower": "Off: the E2E test accounts work again under their own Dev-only limits, and the signed-in E2E suites can run.", "when": "Turn it on the day the pilot agency starts working on Dev, before the test accounts are disabled in Cognito; keep it on while real agency data is on Dev. Turn it off only when no real agency data is left on Dev.", "example": "With the default off, the nightly signed-in check opens the admin pages as its test account. Switched on, the same sign-in gets an error saying the pilot fence is on, and real staff sign in as usual."}, "vi": {"what": "Các tài khoản kiểm thử E2E tự động còn được đăng nhập vào trang staff của CIS và Booking trên Dev hay không. Các tài khoản này chỉ có để agent kiểm hệ thống mà không cần người.", "raise": "Bật: mọi tài khoản kiểm thử E2E bị từ chối khi đăng nhập và ở mọi yêu cầu trong CIS và Booking, nên không tài khoản nào xem hay chạm được dữ liệu của đại lý pilot. Các bộ kiểm E2E có đăng nhập ngừng chạy được.", "lower": "Tắt: các tài khoản kiểm thử E2E hoạt động lại theo giới hạn chỉ-Dev của chúng, và các bộ kiểm E2E có đăng nhập chạy được.", "when": "Bật vào ngày đại lý pilot bắt đầu làm việc trên Dev, trước khi tắt các tài khoản kiểm thử trong Cognito; giữ bật khi dữ liệu thật của đại lý còn trên Dev. Chỉ tắt khi Dev không còn dữ liệu thật của đại lý nào.", "example": "Với mặc định tắt, bài kiểm có đăng nhập hằng đêm mở trang quản trị bằng tài khoản kiểm thử của nó. Khi bật, cùng lần đăng nhập đó nhận lỗi báo hàng rào pilot đang bật, còn staff thật đăng nhập như thường."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('495', now(), 'AA-1054: the pilot fence switch (cis.platform.pilot_e2e_fence) in the settings registry')
ON CONFLICT (version) DO NOTHING;

COMMIT;
