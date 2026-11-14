-- Migration bk-058: AA-1096 (S280 settings UI audit) — reject and withdraw a pending pricing rule, FX rate or
-- cancellation fee schedule.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/058_policy_row_closures.sql; on Dev it is applied as bk_owner (the live owner of schema booking
-- since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Depends on bk-004 (pricing_rules, fx_rates), bk-007 (policy_approvals) and bk-021 (cancellation_policies). The bk-057
-- header names bk-058 for the B2C table drop; that file is not on main, and the numbers must stay contiguous
-- (test_migration_guard), so this one takes bk-058: whichever lands second renumbers.
--
-- Why: the three policy row tables are append-only and a row is in force only once a second person approves it
-- (policy_approvals). They had no way to end a pending row: a wrong row stayed "Pending approval" for ever, and the
-- approver's only choices were to approve it or leave it. The pricing policy parameters (bk-050) already have reject
-- and withdraw; this gives the same two steps to these rows.
--
-- What:
--   1. booking.policy_row_closures: APPEND-ONLY, at most one row per policy row: the end of a pending row, either
--      `rejected` by a second person with a reason or `withdrawn` by its maker. Exactly one of the three row ids is
--      set and matches entity_type. `maker` is the row's creator, checked against the row by the trigger below, so the
--      maker-checker CHECK compares the real maker (same rule as booking.pricing_policy_events, bk-050). ON DELETE
--      CASCADE like policy_approvals: role booking deletes no policy row; only the owner's test fixtures do.
--   2. Triggers (backstops of app.pricing.policy, which also locks the row): a closure is refused on an approved row
--      or with a wrong maker; an approval (policy_approvals) is refused on a closed row.
--
-- Not here: the unique day of a row (pricing_rules_channel_valid_from_uq, fx_rates_currency_as_of_uq,
-- cancellation_policies_scope_uq) still counts a closed row, so a corrected row takes another day. Freeing the day
-- means dropping those constraints and keeping "one approved row per scope and day" in the app only (and a tie-break
-- in every reader, the bk-039 view included); that is a tech lead decision, not this file.
--
-- Class: contract (root ADR 0017 d3): a new table with a REVOKE of UPDATE / DELETE / TRUNCATE from role booking and a
-- new trigger on the existing policy_approvals. A migration-only PR first (MIG-4), then the code PR raises readiness to
-- bk-058. On Dev: Infra Migration Apply once every job table is idle.
-- DM-6.1: no personal data (ids, staff refs, a staff reason about a price row: pii:free_text by rule, never traveller
-- data). DM-7.1: one new table; its retention row goes in the root data standards (02-data-management.md) before the
-- Infra copy.
-- Locks: CREATE TRIGGER takes SHARE ROW EXCLUSIVE on policy_approvals (a few dozen rows, an instant); lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS, CREATE OR REPLACE, repeatable grants.
-- Undo (a later bk- file, after the code is reverted): DROP TRIGGER policy_approvals_not_closed ON
-- booking.policy_approvals; DROP FUNCTION booking.policy_approval_not_closed(); DROP TABLE booking.policy_row_closures
-- (and its function booking.policy_row_closure_guard()).

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. The end of a pending policy row (append-only) ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.policy_row_closures (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type             TEXT        NOT NULL,
    pricing_rule_id         UUID        REFERENCES booking.pricing_rules (id) ON DELETE CASCADE,
    fx_rate_id              UUID        REFERENCES booking.fx_rates (id) ON DELETE CASCADE,
    cancellation_policy_id  UUID        REFERENCES booking.cancellation_policies (id) ON DELETE CASCADE,
    event                   TEXT        NOT NULL,
    maker                   TEXT        NOT NULL,
    actor                   TEXT        NOT NULL,
    reason                  TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT policy_row_closures_entity_chk CHECK (
        (entity_type = 'pricing_rule' AND pricing_rule_id IS NOT NULL AND fx_rate_id IS NULL
            AND cancellation_policy_id IS NULL)
        OR (entity_type = 'fx_rate' AND fx_rate_id IS NOT NULL AND pricing_rule_id IS NULL
            AND cancellation_policy_id IS NULL)
        OR (entity_type = 'cancellation_policy' AND cancellation_policy_id IS NOT NULL AND pricing_rule_id IS NULL
            AND fx_rate_id IS NULL)),
    CONSTRAINT policy_row_closures_event_chk CHECK (event IN ('rejected', 'withdrawn')),
    -- Maker-checker: the maker withdraws; a second person rejects, with a reason.
    CONSTRAINT policy_row_closures_actor_chk CHECK (
        (event = 'withdrawn' AND actor = maker)
        OR (event = 'rejected' AND actor <> maker AND reason IS NOT NULL)),
    CONSTRAINT policy_row_closures_text_chk CHECK (
        length(btrim(actor)) BETWEEN 1 AND 128
        AND length(btrim(maker)) BETWEEN 1 AND 128
        AND (reason IS NULL OR length(btrim(reason)) BETWEEN 1 AND 300))
);

CREATE UNIQUE INDEX IF NOT EXISTS policy_row_closures_pricing_rule_uq
    ON booking.policy_row_closures (pricing_rule_id) WHERE pricing_rule_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS policy_row_closures_fx_rate_uq
    ON booking.policy_row_closures (fx_rate_id) WHERE fx_rate_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS policy_row_closures_cancellation_policy_uq
    ON booking.policy_row_closures (cancellation_policy_id) WHERE cancellation_policy_id IS NOT NULL;

COMMENT ON TABLE booking.policy_row_closures IS
    'AA-1096 (bk-058): the end of a pending pricing_rules / fx_rates / cancellation_policies row: rejected by a second person (with a reason) or withdrawn by its maker. At most one per row; a closed row is never approved and never prices anything. Append-only.';
COMMENT ON COLUMN booking.policy_row_closures.maker IS
    'bk-058: the created_by of the closed row (checked by policy_row_closure_guard), so the maker-checker CHECK compares the real maker.';
COMMENT ON COLUMN booking.policy_row_closures.reason IS
    'pii:free_text; bk-058: why a second person rejected the row (required for rejected); staff text about a price row, never traveller data by rule.';

-- ── 2. Backstops: a closure only on a pending row of that maker; never an approval of a closed row ──────────────

CREATE OR REPLACE FUNCTION booking.policy_row_closure_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_maker TEXT;
    v_approved BOOLEAN;
BEGIN
    IF NEW.entity_type = 'pricing_rule' THEN
        SELECT r.created_by, EXISTS (SELECT 1 FROM booking.policy_approvals a WHERE a.pricing_rule_id = r.id)
          INTO v_maker, v_approved FROM booking.pricing_rules r WHERE r.id = NEW.pricing_rule_id;
    ELSIF NEW.entity_type = 'fx_rate' THEN
        SELECT r.created_by, EXISTS (SELECT 1 FROM booking.policy_approvals a WHERE a.fx_rate_id = r.id)
          INTO v_maker, v_approved FROM booking.fx_rates r WHERE r.id = NEW.fx_rate_id;
    ELSE
        SELECT r.created_by, EXISTS (SELECT 1 FROM booking.policy_approvals a WHERE a.cancellation_policy_id = r.id)
          INTO v_maker, v_approved FROM booking.cancellation_policies r WHERE r.id = NEW.cancellation_policy_id;
    END IF;
    IF v_approved THEN
        RAISE EXCEPTION 'an approved policy row cannot be rejected or withdrawn' USING ERRCODE = 'check_violation';
    END IF;
    IF v_maker IS DISTINCT FROM NEW.maker THEN
        RAISE EXCEPTION 'policy_row_closures.maker must be the creator of the row' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.policy_row_closure_guard() IS
    'bk-058: refuses a closure of an approved policy row, or one whose maker is not the row''s creator.';

CREATE OR REPLACE TRIGGER policy_row_closures_guard
    BEFORE INSERT ON booking.policy_row_closures
    FOR EACH ROW EXECUTE FUNCTION booking.policy_row_closure_guard();

CREATE OR REPLACE FUNCTION booking.policy_approval_not_closed() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM booking.policy_row_closures c
        WHERE (NEW.pricing_rule_id IS NOT NULL AND c.pricing_rule_id = NEW.pricing_rule_id)
           OR (NEW.fx_rate_id IS NOT NULL AND c.fx_rate_id = NEW.fx_rate_id)
           OR (NEW.cancellation_policy_id IS NOT NULL AND c.cancellation_policy_id = NEW.cancellation_policy_id)
    ) THEN
        RAISE EXCEPTION 'a rejected or withdrawn policy row cannot be approved' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.policy_approval_not_closed() IS
    'bk-058: refuses a policy_approvals row for a pricing rule, FX rate or cancellation policy that was rejected or withdrawn.';

CREATE OR REPLACE TRIGGER policy_approvals_not_closed
    BEFORE INSERT ON booking.policy_approvals
    FOR EACH ROW EXECUTE FUNCTION booking.policy_approval_not_closed();

-- ── Grants: append-only for the runtime role ──────────────────────────────────────────────────────────────────────

GRANT SELECT, INSERT ON booking.policy_row_closures TO booking;
REVOKE UPDATE, DELETE, TRUNCATE ON booking.policy_row_closures FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-058', now(), 'AA-1096: reject and withdraw of pending pricing rules, FX rates and cancellation policies')
ON CONFLICT (version) DO NOTHING;

COMMIT;
