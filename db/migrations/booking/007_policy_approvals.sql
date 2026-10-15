-- Migration bk-007: AA-810 — maker-checker approvals for pricing rules and FX rates (ADR 0005 decision 8, UI spec Q19).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/007_policy_approvals.sql and is applied to Dev by the DB Migrate workflow
-- (check, then apply), as aa_cis_admin. Never run it from a laptop.
--
-- DEPENDS ON bk-004 (booking.pricing_rules, booking.fx_rates) and bk-003 (booking.staff_users). It fails on a
-- database without bk-004.
--
-- ADR 0005 decision 8: "one person uploads or edits, another publishes; every change is audited". UI spec Q19
-- (accepted S236): maker-checker covers pricing rules and FX rows too, and a row is in force only once approved.
--
-- Shape. bk-004 made both policy tables append-only for role booking (UPDATE/DELETE/TRUNCATE revoked, guarded by
-- the integration test test_policy_tables_are_append_only). An approval therefore cannot be an UPDATE of an
-- approved_by column; it is a row in a separate append-only table, booking.policy_approvals:
--   * exactly one of pricing_rule_id / fx_rate_id is set, matching entity_type (typed FKs, not a polymorphic
--     entity_id, so an approval can never point at a missing row);
--   * one approval per policy row (UNIQUE on each FK);
--   * approved_by is TEXT without an FK: it is a CIS staff id (booking.staff_users.cis_user_id) for approvals
--     made through the API, or a marker for rows approved by a migration ('seed:bk-004', 'backfill:bk-007');
--   * a trigger refuses an approval by the row's creator (maker-checker backstop; the API answers 403 first).
--
-- Back-fill (live quotes must not change when this lands):
--   * the three bk-004 seed rules (created_by NULL, note 'ADR 0005 seed…', valid_from 2026-10-14) are approved as
--     'seed:bk-004';
--   * every other pricing rule / FX row that exists when bk-007 is first applied was already in force, so it is
--     approved as 'backfill:bk-007'. Rows created after the first apply are never back-filled, even if this
--     file runs again (the cut-off is bk-007's own applied_at in shared.schema_versions).
--
-- After this file the app reads only approved rows (backend app/pricing/repository.py): the rule / FX rate in
-- force on a day is the newest APPROVED row dated on or before that day.
--
-- Re-running the whole file is a no-op (IF NOT EXISTS / OR REPLACE / ON CONFLICT DO NOTHING / idempotent GRANT and
-- REVOKE, time-bounded back-fill).

BEGIN;

CREATE TABLE IF NOT EXISTS booking.policy_approvals (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type      TEXT NOT NULL,
    pricing_rule_id  UUID REFERENCES booking.pricing_rules (id) ON DELETE CASCADE,
    fx_rate_id       UUID REFERENCES booking.fx_rates (id) ON DELETE CASCADE,
    approved_by      TEXT NOT NULL,
    approved_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    note             TEXT,

    CONSTRAINT policy_approvals_pricing_rule_uq UNIQUE (pricing_rule_id),
    CONSTRAINT policy_approvals_fx_rate_uq UNIQUE (fx_rate_id),
    CONSTRAINT policy_approvals_entity_chk CHECK (
        (entity_type = 'pricing_rule' AND pricing_rule_id IS NOT NULL AND fx_rate_id IS NULL)
        OR (entity_type = 'fx_rate' AND fx_rate_id IS NOT NULL AND pricing_rule_id IS NULL)),
    CONSTRAINT policy_approvals_approved_by_chk CHECK (length(btrim(approved_by)) > 0)
);

COMMENT ON TABLE booking.policy_approvals IS
    'bk-007 (ADR 0005 d8, spec Q19): second-person approval of a pricing_rules / fx_rates row, append-only. Only approved rows are in force.';
COMMENT ON COLUMN booking.policy_approvals.approved_by IS
    'CIS staff id (staff_users.cis_user_id) of the approver, or seed:bk-004 / backfill:bk-007 for rows approved by a migration.';

-- Maker-checker backstop: the creator of a policy row may not approve it. Rows without a creator (migration seed,
-- rows added by hand on Dev) may be approved by any staff member with pricing.write.
CREATE OR REPLACE FUNCTION booking.policy_approval_maker_checker() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_maker TEXT;
BEGIN
    IF NEW.entity_type = 'pricing_rule' THEN
        SELECT r.created_by INTO v_maker FROM booking.pricing_rules r WHERE r.id = NEW.pricing_rule_id;
    ELSE
        SELECT f.created_by INTO v_maker FROM booking.fx_rates f WHERE f.id = NEW.fx_rate_id;
    END IF;
    IF v_maker IS NOT NULL AND v_maker = NEW.approved_by THEN
        RAISE EXCEPTION 'the creator of a % row cannot approve it (maker-checker)', NEW.entity_type
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.policy_approval_maker_checker() IS
    'bk-007: refuses a policy_approvals row whose approver created the approved pricing rule / FX rate.';

CREATE OR REPLACE TRIGGER policy_approvals_maker_checker
    BEFORE INSERT ON booking.policy_approvals
    FOR EACH ROW EXECUTE FUNCTION booking.policy_approval_maker_checker();

-- ── Back-fill ────────────────────────────────────────────────────────────────
-- Cut-off = bk-007's first apply (its shared.schema_versions row, inserted at the end of this file). On the first
-- run there is no row yet, so every existing row (created by earlier transactions, before now()) qualifies.

INSERT INTO booking.policy_approvals (entity_type, pricing_rule_id, approved_by, note)
SELECT 'pricing_rule',
       r.id,
       CASE WHEN r.created_by IS NULL AND r.valid_from = DATE '2026-10-14' AND r.note LIKE 'ADR 0005 seed%'
            THEN 'seed:bk-004' ELSE 'backfill:bk-007' END,
       'in force before maker-checker (bk-007)'
FROM booking.pricing_rules r
WHERE (r.created_by IS NULL AND r.valid_from = DATE '2026-10-14' AND r.note LIKE 'ADR 0005 seed%')
   OR r.created_at < coalesce((SELECT v.applied_at FROM shared.schema_versions v WHERE v.version = 'bk-007'), now())
ON CONFLICT (pricing_rule_id) DO NOTHING;

INSERT INTO booking.policy_approvals (entity_type, fx_rate_id, approved_by, note)
SELECT 'fx_rate', f.id, 'backfill:bk-007', 'in force before maker-checker (bk-007)'
FROM booking.fx_rates f
WHERE f.created_at < coalesce((SELECT v.applied_at FROM shared.schema_versions v WHERE v.version = 'bk-007'), now())
ON CONFLICT (fx_rate_id) DO NOTHING;

-- ── Grants ───────────────────────────────────────────────────────────────────
-- Default privileges (bk-001) give role booking full DML on a new table; approvals are append-only like the
-- policy rows they approve, so UPDATE/DELETE/TRUNCATE are revoked. Nothing here touches the bk-004 grants:
-- pricing_rules and fx_rates stay SELECT, INSERT only.

GRANT SELECT, INSERT ON booking.policy_approvals TO booking;
REVOKE UPDATE, DELETE, TRUNCATE ON booking.policy_approvals FROM booking;
GRANT EXECUTE ON FUNCTION booking.policy_approval_maker_checker() TO booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-007', now(), 'AA-810: policy_approvals (maker-checker for pricing_rules / fx_rates, append-only), seed rules approved as seed:bk-004, existing rows back-filled')
ON CONFLICT (version) DO NOTHING;

COMMIT;
