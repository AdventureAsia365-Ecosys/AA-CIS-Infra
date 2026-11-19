-- Migration 459: AA-1111 (S285, slice S2; tech lead decisions S283 "admin MFA = TOTP" and S285 "drop the WAF geo rule
-- for the staff hosts once admin MFA is enforced") — the switch that makes the CIS API refuse an administrator session
-- signed in without an authenticator code, in the platform settings registry (CIS 407; tech lead S279: a policy value is
-- a setting on Platform › Settings, never a code literal or an env var alone).
--
-- Why. WORKFORCE staff sign in with an e-mail one-time code; anyone who controls an administrator's mailbox can open the
-- admin pages. The pool already allows TOTP as optional MFA (AA-CIS-Infra identity.tf); a user with TOTP enrolled signs
-- in with password + TOTP, and Amazon Cognito then writes amr ["pwd", "otp", "mfa"] into the access token. The code PR
-- (api/core/staff_mfa.py) refuses a cis-admin or owner session whose token's amr lacks "otp" with 403 mfa_required, but
-- only while this switch is on; off, it only logs staff_admin_mfa_check (would_refuse) so the tech lead can see the
-- claim on his own session before turning it on.
--
-- What:
--   1. One row in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), area "platform", scope platform, impact high, maker-checker,
--      no evidence, no env override (an env var must never turn MFA off), enforced (api/core/staff_mfa_settings.py
--      names the key in this PR, the settings-lint reader check; the code PR reads it through shared.settings):
--        cis.platform.admin_mfa_required   bool, default false (today's behaviour)
--      The seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 459.
--
-- Behaviour on apply. None for running code: no value row is seeded and nothing on main reads the key; after the code
-- PR the API reads the default (off) until an administrator turns it on.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a config row INSERTed into an existing table.
-- MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a), then
-- the code PR (no readiness raise: the reader falls back to the compiled defaults). DM-6.1: no personal data. DM-7.1:
-- no new table.
--
-- Number. Owner main max (458) + 1. If the owner main max + 1 differs at merge,
-- renumber (git grep '459_' and '459' here, in tests/integration/test_aa1111_migration_459.py, compiled_defaults.json
-- and docs/implementation-notes/AA-1111-admin-mfa.md).
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
{"key": "cis.platform.admin_mfa_required", "app": "cis", "area": "platform", "label": "Staff sign-in: administrators must use an authenticator code", "description": "On: the CIS API refuses a staff session of an administrator (the cis-admin group, or a staff member with the owner flag) whose sign-in did not use an authenticator app code, with 403 mfa_required (api/core/staff_mfa.py reads the token's amr claim, which Amazon Cognito sets to include otp after a password plus authenticator code sign-in). Off (default): nothing is refused; every administrator session without that code is logged as staff_admin_mfa_check would_refuse, so the switch can be checked before it is turned on. Other CIS roles, the read-only Dev test accounts and the capped preview session are never checked. Booking and the CRM have their own switch.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": false, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "Whether a CIS administrator must sign in with a password and a six-digit code from an authenticator app before the admin pages answer.", "raise": "On: an administrator who signed in with an e-mail code only is refused and must sign in again with the authenticator code; a stolen mailbox no longer opens the admin pages.", "lower": "Off: administrators can work with an e-mail code sign-in as today; their sessions are only logged.", "when": "Turn it on only after every administrator has set up an authenticator app and one test sign-in shows the code was used; turn it off only to let an administrator back in while the authenticator is being reset.", "example": "With the default off, an administrator who signed in with an e-mail code opens the admin pages; switched on, the same session gets an error asking for an authenticator sign-in."}, "vi": {"what": "Quản trị viên CIS có phải đăng nhập bằng mật khẩu và mã 6 số từ ứng dụng xác thực thì các trang quản trị mới trả lời hay không.", "raise": "Bật: quản trị viên chỉ đăng nhập bằng mã e-mail bị từ chối và phải đăng nhập lại kèm mã xác thực; hộp thư bị lộ không còn mở được trang quản trị.", "lower": "Tắt: quản trị viên làm việc với đăng nhập mã e-mail như hiện nay; phiên của họ chỉ được ghi log.", "when": "Chỉ bật sau khi mọi quản trị viên đã cài ứng dụng xác thực và một lần đăng nhập thử cho thấy mã đã được dùng; chỉ tắt để cho một quản trị viên vào lại trong lúc đặt lại ứng dụng xác thực.", "example": "Với mặc định tắt, quản trị viên đăng nhập bằng mã e-mail vẫn mở được trang quản trị; khi bật, cùng phiên đó nhận lỗi yêu cầu đăng nhập kèm mã xác thực."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('459', now(), 'AA-1111: the administrator MFA switch (cis.platform.admin_mfa_required) in the settings registry')
ON CONFLICT (version) DO NOTHING;

COMMIT;
