-- Migration bk-061: AA-1111 slice S2 (S285; tech lead decisions S283 "admin MFA = TOTP" and S285 "drop the WAF geo rule
-- of the staff hosts once admin MFA is enforced") — the switch that makes the Booking staff API refuse an administrator
-- session signed in without an authenticator code, as a pricing policy parameter.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/061_admin_mfa_policy.sql and Migration Apply applies it on Dev as bk_owner once every job
-- table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Why: WORKFORCE staff sign in with an e-mail one-time code; anyone who controls a Booking administrator's mailbox can
-- open every trip case, customer and price. The pool allows TOTP as optional MFA; a staff member with TOTP enrolled
-- signs in with password + TOTP and Amazon Cognito writes amr ["pwd", "otp", "mfa"] into the access token. The code PR
-- that follows (app/auth/admin_mfa.py) refuses a booking-admin session whose token's amr lacks "otp" with 403
-- mfa_required while this parameter is true; false, it only logs staff_admin_mfa_check (would_refuse). The tech lead's
-- rule (S279) makes every policy value an admin-editable value, so the switch is a parameter of booking.pricing_policy
-- (Pricing > Policy, maker-checker, versioned, audited; key, type and approver:
-- backend/app/pricing/policy_params_security.py), section "security", approved by the administrator group.
--
-- What: version 1 of 1 new parameter, made by the migration ('seed:bk-061'), submitted, and approved, in force from
-- 2026-01-01 like the bk-050 / bk-056 / bk-059 seeds. The seed is TODAY'S EFFECTIVE VALUE, so nothing changes until
-- staff change it on the page:
--   staff_admin_mfa_required   false (administrators may still sign in with an e-mail code)
--
-- Class: contract (root ADR 0017 d3): config rows into existing tables. Migration-only PR first (MIG-4), then the code
-- PR raises readiness to bk-061. On Dev: Infra Migration Apply once every job table is idle (root ADR 0017a). The
-- running code before the code PR does not read this key (app.pricing.policy_values ignores a key the code does not
-- know), so nothing it reads changes here.
-- DM-6.1: no personal data (a policy value). DM-7.1: no new table.
-- Locks: row inserts only; lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): ON CONFLICT DO NOTHING.
-- Number: owner main max + 1 (bk-060 on main). If it moves, renumber: file name, this header, the post-check, the
-- registration, the ids (…b61000…) and the tests that name it (git grep '061_' and 'bk-061').
-- Undo (a later bk- file, after the code is reverted): DELETE the seed:bk-061 events, then the version.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. The new parameter, version 1 = today's effective value ────────────────────────────────────────────────────

INSERT INTO booking.pricing_policy (id, param_key, version_no, value, unit, effective_from, reason, created_by)
VALUES
    ('00000000-0000-4000-8000-0000b6100000', 'staff_admin_mfa_required', 1, 'false'::jsonb, NULL, DATE '2026-01-01',
     'AA-1111: administrators may sign in with an e-mail code until every administrator has an authenticator app.',
     'seed:bk-061')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT '00000000-0000-4000-8000-0000b6100001'::uuid, p.id, p.created_by, 'submitted', p.created_by
FROM booking.pricing_policy p
WHERE p.id = '00000000-0000-4000-8000-0000b6100000' AND p.created_by = 'seed:bk-061'
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT '00000000-0000-4000-8000-0000b6100002'::uuid, p.id, p.created_by, 'approved',
       'tech lead S279 (thresholds rule: seeded defaults)'
FROM booking.pricing_policy p
WHERE p.id = '00000000-0000-4000-8000-0000b6100000' AND p.created_by = 'seed:bk-061'
ON CONFLICT DO NOTHING;

-- ── 2. Post-check: the parameter has an approved version 1 ───────────────────────────────────────────────────────

DO $$
DECLARE
    n integer;
BEGIN
    SELECT count(*) INTO n
    FROM booking.pricing_policy p
    JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
    WHERE p.created_by IN ('seed:bk-061') AND p.version_no = 1;
    IF n <> 1 THEN
        RAISE EXCEPTION 'bk-061: % of the 1 new pricing policy parameter has an approved version 1', n
            USING HINT = 'The key already had a version 1 made by someone else; the seed must not overwrite it.';
    END IF;
END
$$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-061', now(), 'AA-1111 S2: the administrator MFA switch (staff_admin_mfa_required) as a pricing policy parameter')
ON CONFLICT (version) DO NOTHING;

COMMIT;
