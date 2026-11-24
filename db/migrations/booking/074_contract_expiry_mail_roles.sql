-- Migration bk-074: AA-1177 (Jira PR-31, business owner 24/11: remind the admins before a supplier contract ends) —
-- the pricing policy parameter that says which Booking staff roles get the contract expiry e-mail.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/074_contract_expiry_mail_roles.sql and Migration Apply applies it on Dev as bk_owner once
-- every job table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Why: the daily job bk_contract_expiry_watch (bk-068) writes one in-app staff notification per supplier contract
-- ending within contract_expiry_alert_days, but nobody who does not open the Booking admin hears of it. The code PR
-- that follows also e-mails the active Booking staff of the roles named here, once per contract and end date (the
-- notification's reminder_key). Who receives it is a policy choice (tech lead S279: no recipient list in code or in an
-- env var), so it is a parameter of Pricing > Policy:
--   contract_expiry_mail_roles  ["admin", "contracting"]  (codes) the built-in staff roles whose active members get
--                                                          the e-mail; an empty list switches the e-mail off (the
--                                                          in-app notification and the lists stay). A custom role
--                                                          (bk-062) counts as its based_on role (code PR).
-- Key, type, choices and approver group: backend/app/pricing/policy_params_ops.py (section operations, approved by the
-- pricing group like contract_expiry_alert_days).
--
-- What: one version 1, made by the migration ('seed:bk-074'), submitted and approved by another actor.
-- Class: contract (root ADR 0017 d3): config rows into existing tables. Migration-only PR first (MIG-4), then the code
-- PR raises readiness to bk-074. On Dev: Infra Migration Apply once every job table is idle (root ADR 0017a). The
-- running code before the code PR does not read this key (app.pricing.policy_values ignores a key the code does not
-- know), so nothing changes here.
-- DM-6.1: no personal data (role codes). DM-7.1: no new table.
-- Locks: row inserts only; lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): ON CONFLICT DO NOTHING.
-- Number: owner main max + 1 (bk-073 on main). If it moves, renumber: file name, this header, the post-check, the
-- registration, the ids (…b74000…) and the tests that name it (git grep '074_' and 'bk-074').
-- Undo (a later bk- file, after the code is reverted): DELETE the seed:bk-074 events, then the version.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. The parameter, version 1 ──────────────────────────────────────────────────────────────────────────────────

INSERT INTO booking.pricing_policy (id, param_key, version_no, value, unit, effective_from, reason, created_by)
VALUES
    ('00000000-0000-4000-8000-0000b7400000', 'contract_expiry_mail_roles', 1, '["admin", "contracting"]'::jsonb,
     NULL, DATE '2026-01-01',
     'AA-1177 (Jira PR-31): the staff roles whose active members get the supplier contract expiry e-mail.',
     'seed:bk-074')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT (substr(p.id::text, 1, 35) || '1')::uuid, p.id, p.created_by, 'submitted', p.created_by
FROM booking.pricing_policy p
WHERE p.created_by = 'seed:bk-074' AND p.version_no = 1
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT (substr(p.id::text, 1, 35) || '2')::uuid, p.id, p.created_by, 'approved',
       'tech lead S279 (thresholds rule: seeded defaults, Jira PR-31 admins reminded)'
FROM booking.pricing_policy p
WHERE p.created_by = 'seed:bk-074' AND p.version_no = 1
ON CONFLICT DO NOTHING;

-- ── 2. Post-check: the parameter has an approved version 1 ───────────────────────────────────────────────────────

DO $$
DECLARE
    n integer;
BEGIN
    SELECT count(DISTINCT p.param_key) INTO n
    FROM booking.pricing_policy p
    JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
    WHERE p.version_no = 1 AND p.param_key IN ('contract_expiry_mail_roles');
    IF n <> 1 THEN
        RAISE EXCEPTION 'bk-074: % of the 1 seeded parameter has an approved version 1', n
            USING HINT = 'The key already had a version 1 made by someone else; the seed must not overwrite it.';
    END IF;
END
$$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-074', now(), 'AA-1177: the staff roles that get the supplier contract expiry e-mail as a pricing policy parameter')
ON CONFLICT (version) DO NOTHING;

COMMIT;
