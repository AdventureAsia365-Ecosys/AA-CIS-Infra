-- Migration crm-082: AA-1111 (S285, slice S2; tech lead decisions S283 "admin MFA = TOTP" and S285 "drop the WAF geo
-- rule of the staff hosts once admin MFA is enforced") — the switch that makes the AA-Partner API refuse an AA operations
-- staff session signed in without an authenticator code, as a CRM setting.
--
-- Owner: AA-Partner (api/migrations/082_crm_admin_mfa_setting.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- Migration Apply runs. Key crm-082, right after crm-081 (AA-1144's 081_crm_option_display_note.sql, PR #360, the
-- quote item display note; this file was crm-081 before the two met); if the numbers move, renumber: file name, this
-- header, Guard 0 and the registration below, and the tests that name it (git grep '082_' and 'crm-082').
--
-- Why. WORKFORCE staff sign in with an e-mail one-time code; anyone who controls their mailbox can open every agency's
-- data on /crm/ops/v1 and /crm/staff/v1. The pool allows TOTP as optional MFA; a staff member with TOTP enrolled signs in
-- with password + TOTP and Amazon Cognito writes amr ["pwd", "otp", "mfa"] into the access token. app/auth/admin_mfa.py
-- (this PR) refuses a crm-platform-admin, crm-ops or cis-admin session whose token's amr lacks "otp" with 403
-- mfa_required while this switch is on; off, it only logs staff_admin_mfa_check (would_refuse).
--
-- What:
--   1. One crm.setting_definition row (settings-seed block, read by api/scripts/gen_settings_defaults.py into
--      app/platform_settings/compiled_defaults.json; its guide in app/platform_settings/guides.json; its reader
--      app/auth/admin_mfa.py ships in this PR, the settings lint):
--        crm.platform.admin_mfa_required  bool, default false (today's behaviour), area platform, platform scope,
--          impact high, maker-checker, enforced, no env override (an env var must never turn MFA off).
--   2. Register crm-082.
--
-- Behaviour on apply: none for running code (the reader serves the compiled default, off, until a value is approved).
--
-- Class: contract (INSERT of a config row into an existing table; no '-- migrate:' directive). Shipped with its reader
-- in one PR like crm-075 (#331): the reader falls back to the compiled default, there is no readiness raise, and off is
-- today's behaviour, so the code deploying before Infra Migration Apply registers the file changes nothing (root ADR
-- 0017a). No new table (no DM-7.1 row), no personal data, no crm.erase_subject change.
--
-- Rollback (a new forward migration, after the code is reverted): DELETE FROM crm.setting_value /
-- crm.setting_definition WHERE key = 'crm.platform.admin_mfa_required' as crm_owner.
--
-- Runs as crm_owner (the crm-064 definition guard allows only the owner), one BEGIN … COMMIT block, no role DDL.
-- Re-runnable (ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-081 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-082: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-081') THEN
        RAISE EXCEPTION 'crm-082: crm-081 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-082' AND description NOT LIKE 'AA-1111 admin MFA:%') THEN
        RAISE EXCEPTION 'crm-082: the key crm-082 is already held by another migration (not AA-1111): renumber one';
    END IF;
END $$;

-- ── 1. The administrator MFA switch ──────────────────────────────────────────────────────────────
-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "crm.platform.admin_mfa_required", "app": "crm", "area": "platform", "label": "Staff sign-in: CRM operations staff must use an authenticator code", "description": "On: the AA-Partner API refuses an AA staff session that holds an operations group (crm-platform-admin, crm-ops, or cis-admin on the operations surface) when its sign-in did not use an authenticator app code, with 403 mfa_required (app/auth/admin_mfa.py reads the token's amr claim, which Amazon Cognito sets to include otp after a password plus authenticator code sign-in). Off (default): nothing is refused; such sessions are logged as staff_admin_mfa_check would_refuse, so the switch can be checked before it is turned on. Agency members (partner pool, MFA always required there), the support desk groups and the Dev-only test identities are never checked. CIS and Booking have their own switch.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": false, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── Post-check ────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM crm.setting_definition WHERE key = 'crm.platform.admin_mfa_required') THEN
        RAISE EXCEPTION 'crm-082: crm.platform.admin_mfa_required is not defined';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-082', now(), 'AA-1111 admin MFA: the setting crm.platform.admin_mfa_required (refuse an AA operations staff session without an authenticator code)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
