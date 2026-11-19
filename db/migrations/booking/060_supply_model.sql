-- Migration bk-060: AA-1145 (S285 lane L5, root docs/audits/2026-11-19-S285-session/advisory-r2-plan.md slice L5;
-- advisories T12, B4, B7, B8, T7 and the T13 stop-sale rule) — one supply model that the tour, activity and hotel
-- slices reuse: inventory restrictions per component, structured contract terms, pax types on supplier rates, and
-- the source numbers of a commissionable rate.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/060_supply_model.sql and Migration Apply applies it on Dev as bk_owner once every job table is
-- idle (root ADR 0017a). Never run it from a laptop.
--
-- Depends on bk-008 (supplier_contracts), bk-010 (hotel_room_types, services, supplier_rates), bk-050
-- (pricing_policy, pricing_policy_events).
--
-- Why: child prices, cancellation terms, stop-sale and allotment were designed three ways across the hotel, activity
-- and tour advisories. AA's supply chain is AA -> supplier (DMC) -> hotel / operator: every term here is the term the
-- supplier gives AA under an AA supplier contract (booking.supplier_contracts), never a hotel's own term.
--
-- What:
--   1. booking.supplier_rates gains
--        pax_type          adult | child | infant (default adult; child / infant only on a per-person rate),
--        age_min, age_max  the age band of a child or infant rate (years, inclusive; empty = any age of that type),
--        published_amount, commission_pct
--                          the two source numbers of a commissionable supplier rate (B7). net_amount stays the only
--                          price every calculation reads; when the source numbers are kept, net_amount =
--                          round(published_amount x (100 - commission_pct) / 100, 2) (CHECK).
--   2. booking.supplier_contract_terms (new, one row per contract, written while the contract is a draft, fixed once
--      a second person publishes it): tiered cancellation terms (the bk-021 tier shape, {min_days, fee_pct}),
--      structured payment terms (deposit % and its due days after confirmation; balance days before the service OR
--      credit days after it) and the contract's default child price as a % of the adult net (B4). A later offer
--      overrides these terms field by field; the contract is the default (offers come with the activity slice).
--   3. booking.supply_restrictions (new): one table for every component (a hotel room type or a service) with the
--      inventory kind allotment | free_sale | on_request | stop_sale, scoped to (supplier contract, component, date
--      range, inclusive); allotment rows carry units and release days, free-sale rows an optional maximum of
--      travellers per booking (B8, T7). allotment / free_sale / on_request rows are contract terms (status
--      'contract', written while the contract is a draft, like rates). A stop_sale row is an event on a published
--      contract with a second-person flow (T13 review, advisory-r3-t13-roles.md section 2.4): it takes effect when
--      it is entered (status pending), a second person approves or rejects it later, its maker may withdraw it; an
--      approved stop-sale ends only when a second person approves the end request. Never deleted.
--   4. Version 1 of the pricing policy parameter child_price_pct_by_service_type (B4: the default child price as a
--      % of the adult net per service type when neither the supplier rate nor the contract gives one), seeded at
--      100 for every service type = TODAY'S EFFECTIVE VALUE (children priced as adults), so nothing changes until
--      staff change it on Pricing > Policy (maker-checker, approver group pricing).
--
-- Engine precedence (app.supply.restrictions): stop_sale > allotment / free_sale availability > on_request.
--
-- Class: contract (root ADR 0017 d3): columns and CHECKs on an existing table, guard functions, a config row.
-- Migration-only PR first (MIG-4); the code PR raises readiness to bk-060. The running code before the code PR never
-- reads the new columns or tables (a rate row keeps pax_type adult), so nothing it reads changes here.
-- DM-6.1: no personal data by rule. Commercial columns are tagged conf:commercial; the note and the three reason
-- columns of supply_restrictions are staff text, tagged pii:free_text like the season-range reasons (bk-055).
-- DM-7.1: both new tables have their row in the root data standards (root PR merged before the Infra copy).
-- Locks: supplier_rates, supplier_contracts (FK) take short locks (small tables); lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS, DROP CONSTRAINT IF EXISTS, CREATE OR
-- REPLACE, ON CONFLICT DO NOTHING.
-- Undo (a later bk- file, after the code is reverted): DROP the two tables and their functions, DROP the five
-- supplier_rates columns and their CHECKs, DELETE the seed:bk-060 policy events and version.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. supplier_rates: pax type, age band, commissionable source numbers ─────────────────────────────────────────

ALTER TABLE booking.supplier_rates
    ADD COLUMN IF NOT EXISTS pax_type text NOT NULL DEFAULT 'adult',
    ADD COLUMN IF NOT EXISTS age_min smallint,
    ADD COLUMN IF NOT EXISTS age_max smallint,
    ADD COLUMN IF NOT EXISTS published_amount numeric(16,2),
    ADD COLUMN IF NOT EXISTS commission_pct numeric(5,2);

ALTER TABLE booking.supplier_rates DROP CONSTRAINT IF EXISTS supplier_rates_pax_type_chk;
ALTER TABLE booking.supplier_rates ADD CONSTRAINT supplier_rates_pax_type_chk CHECK (
    pax_type IN ('adult', 'child', 'infant')
    AND (pax_type = 'adult' OR unit = 'person')
    AND (age_min IS NULL OR age_min BETWEEN 0 AND 17)
    AND (age_max IS NULL OR age_max BETWEEN 0 AND 17)
    AND (age_min IS NULL OR age_max IS NULL OR age_max >= age_min)
    AND (pax_type <> 'adult' OR (age_min IS NULL AND age_max IS NULL)));

ALTER TABLE booking.supplier_rates DROP CONSTRAINT IF EXISTS supplier_rates_commission_chk;
ALTER TABLE booking.supplier_rates ADD CONSTRAINT supplier_rates_commission_chk CHECK (
    (published_amount IS NULL) = (commission_pct IS NULL)
    AND (published_amount IS NULL OR (
        published_amount >= 0 AND commission_pct >= 0 AND commission_pct < 100
        AND net_amount = round(published_amount * (100 - commission_pct) / 100, 2))));

COMMENT ON COLUMN booking.supplier_rates.pax_type IS
    'bk-060 (AA-1145, B4): who the rate prices: adult (every rate before bk-060), child or infant (per-person rates only).';
COMMENT ON COLUMN booking.supplier_rates.age_min IS
    'bk-060 (AA-1145, B4): youngest age (years) of a child or infant rate; NULL = any age of its type.';
COMMENT ON COLUMN booking.supplier_rates.age_max IS
    'bk-060 (AA-1145, B4): oldest age (years) of a child or infant rate; NULL = any age of its type.';
COMMENT ON COLUMN booking.supplier_rates.published_amount IS
    'conf:commercial; bk-060 (AA-1145, B7): the supplier''s published price of a commissionable rate (source number); net_amount is what AA pays.';
COMMENT ON COLUMN booking.supplier_rates.commission_pct IS
    'conf:commercial; bk-060 (AA-1145, B7): the supplier''s commission % off published_amount (source number); net_amount = published x (1 - pct).';

-- ── 2. supplier_contract_terms: tiered cancellation, structured payment, contract child % ────────────────────────

CREATE TABLE IF NOT EXISTS booking.supplier_contract_terms (
    supplier_contract_id     uuid PRIMARY KEY REFERENCES booking.supplier_contracts (id),
    cancellation_tiers       jsonb,
    deposit_pct              numeric(5,2),
    deposit_due_days         smallint,
    balance_due_days_before  smallint,
    credit_days_after        smallint,
    child_pct                numeric(5,2),
    created_by               text NOT NULL,
    updated_by               text,
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT supplier_contract_terms_tiers_chk CHECK (
        cancellation_tiers IS NULL OR (
            jsonb_typeof(cancellation_tiers) = 'array'
            AND jsonb_array_length(cancellation_tiers) BETWEEN 1 AND 20
            AND jsonb_path_exists(cancellation_tiers, '$[*] ? (@.min_days == 0)')
            AND NOT jsonb_path_exists(
                cancellation_tiers,
                '$[*] ? (!(exists(@.min_days) && @.min_days.type() == "number" && @.min_days >= 0'
                ' && @.min_days <= 730 && exists(@.fee_pct) && @.fee_pct.type() == "number" && @.fee_pct >= 0'
                ' && @.fee_pct <= 100))'))),
    CONSTRAINT supplier_contract_terms_deposit_chk CHECK (
        (deposit_pct IS NULL) = (deposit_due_days IS NULL)
        AND (deposit_pct IS NULL OR (deposit_pct > 0 AND deposit_pct <= 100))
        AND (deposit_due_days IS NULL OR deposit_due_days BETWEEN 0 AND 365)),
    CONSTRAINT supplier_contract_terms_balance_chk CHECK (
        (balance_due_days_before IS NULL OR balance_due_days_before BETWEEN 0 AND 365)
        AND (credit_days_after IS NULL OR credit_days_after BETWEEN 0 AND 365)
        AND (balance_due_days_before IS NULL OR credit_days_after IS NULL)),
    CONSTRAINT supplier_contract_terms_child_chk CHECK (child_pct IS NULL OR child_pct BETWEEN 0 AND 100),
    CONSTRAINT supplier_contract_terms_text_chk CHECK (
        length(btrim(created_by)) BETWEEN 1 AND 128
        AND (updated_by IS NULL OR length(btrim(updated_by)) BETWEEN 1 AND 128))
);

COMMENT ON TABLE booking.supplier_contract_terms IS
    'bk-060 (AA-1145, T12, B4): the structured terms the supplier gives AA under one supplier contract: cancellation tiers, payment terms, default child %. Written while the contract is a draft (the writer becomes its maker), fixed once published. An offer overrides field by field.';
COMMENT ON COLUMN booking.supplier_contract_terms.cancellation_tiers IS
    'conf:commercial; bk-060: [{min_days, fee_pct}] cancelling d days before the service costs the fee_pct of the tier with the largest min_days <= d (bk-021 shape).';
COMMENT ON COLUMN booking.supplier_contract_terms.deposit_pct IS
    'conf:commercial; bk-060: deposit % of the net due deposit_due_days after the supplier confirms.';
COMMENT ON COLUMN booking.supplier_contract_terms.deposit_due_days IS
    'conf:commercial; bk-060: days after the supplier confirms that the deposit is due.';
COMMENT ON COLUMN booking.supplier_contract_terms.balance_due_days_before IS
    'conf:commercial; bk-060: the balance is due this many days before the service date (prepaid supplier).';
COMMENT ON COLUMN booking.supplier_contract_terms.credit_days_after IS
    'conf:commercial; bk-060: the supplier is paid this many days after the service (credit terms).';
COMMENT ON COLUMN booking.supplier_contract_terms.child_pct IS
    'conf:commercial; bk-060 (B4): child net as a % of the adult net when the contract has no child rate for a service.';

CREATE OR REPLACE FUNCTION booking.supplier_contract_terms_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_status text;
    v_contract uuid;
BEGIN
    v_contract := CASE WHEN TG_OP = 'DELETE' THEN OLD.supplier_contract_id ELSE NEW.supplier_contract_id END;
    IF TG_OP = 'UPDATE' AND NEW.supplier_contract_id IS DISTINCT FROM OLD.supplier_contract_id THEN
        RAISE EXCEPTION 'the terms of contract % cannot move to another contract', OLD.supplier_contract_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    SELECT c.status INTO v_status FROM booking.supplier_contracts c WHERE c.id = v_contract FOR SHARE;
    IF v_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'the terms of a % contract are fixed (contract %)', v_status, v_contract
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_contract_terms_guard() IS
    'bk-060: supplier contract terms are written while the contract is a draft only (fixed once published, like rates).';

CREATE OR REPLACE TRIGGER supplier_contract_terms_guard
    BEFORE INSERT OR UPDATE OR DELETE ON booking.supplier_contract_terms
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_contract_terms_guard();

CREATE OR REPLACE TRIGGER supplier_contract_terms_set_updated_at
    BEFORE UPDATE ON booking.supplier_contract_terms
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── 3. supply_restrictions: inventory kind per (contract, component, date range) ─────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.supply_restrictions (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_contract_id  uuid NOT NULL REFERENCES booking.supplier_contracts (id),
    hotel_room_type_id    uuid REFERENCES booking.hotel_room_types (id),
    service_id            uuid REFERENCES booking.services (id),
    inventory_kind        text NOT NULL,
    date_from             date NOT NULL,
    date_to               date NOT NULL,
    units                 smallint,
    release_days          smallint,
    max_pax               smallint,
    note                  text,
    status                text NOT NULL,
    created_by            text NOT NULL,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_by            text,
    updated_at            timestamptz NOT NULL DEFAULT now(),
    decided_by            text,
    decided_at            timestamptz,
    reject_reason         text,
    withdraw_reason       text,
    end_requested_by      text,
    end_requested_at      timestamptz,
    end_reason            text,
    ended_by              text,
    ended_at              timestamptz,
    CONSTRAINT supply_restrictions_target_chk CHECK (num_nonnulls(hotel_room_type_id, service_id) = 1),
    CONSTRAINT supply_restrictions_kind_chk CHECK (
        inventory_kind IN ('allotment', 'free_sale', 'on_request', 'stop_sale')),
    CONSTRAINT supply_restrictions_dates_chk CHECK (date_to >= date_from AND date_to - date_from <= 731),
    CONSTRAINT supply_restrictions_numbers_chk CHECK (
        (inventory_kind = 'allotment') = (units IS NOT NULL)
        AND (inventory_kind = 'allotment') = (release_days IS NOT NULL)
        AND (max_pax IS NULL OR inventory_kind = 'free_sale')
        AND (units IS NULL OR units BETWEEN 1 AND 999)
        AND (release_days IS NULL OR release_days BETWEEN 0 AND 365)
        AND (max_pax IS NULL OR max_pax BETWEEN 1 AND 999)),
    CONSTRAINT supply_restrictions_status_chk CHECK (
        status IN ('contract', 'pending', 'approved', 'rejected', 'withdrawn')
        AND (inventory_kind = 'stop_sale') = (status <> 'contract')
        AND (status IN ('contract', 'pending')) = (decided_by IS NULL)
        AND (decided_by IS NULL) = (decided_at IS NULL)
        AND (status NOT IN ('approved', 'rejected') OR decided_by <> created_by)
        AND (status <> 'withdrawn' OR decided_by = created_by)
        AND (status = 'rejected') = (reject_reason IS NOT NULL)
        AND (status = 'withdrawn') = (withdraw_reason IS NOT NULL)),
    CONSTRAINT supply_restrictions_end_chk CHECK (
        (end_requested_by IS NULL) = (end_requested_at IS NULL)
        AND (end_requested_by IS NULL) = (end_reason IS NULL)
        AND (ended_by IS NULL) = (ended_at IS NULL)
        AND (end_requested_by IS NULL OR status = 'approved')
        AND (ended_by IS NULL OR (end_requested_by IS NOT NULL AND ended_by <> end_requested_by))),
    CONSTRAINT supply_restrictions_text_chk CHECK (
        length(btrim(created_by)) BETWEEN 1 AND 128
        AND (inventory_kind <> 'stop_sale' OR note IS NOT NULL)
        AND (note IS NULL OR length(btrim(note)) BETWEEN 1 AND 300)
        AND (reject_reason IS NULL OR length(btrim(reject_reason)) BETWEEN 1 AND 300)
        AND (withdraw_reason IS NULL OR length(btrim(withdraw_reason)) BETWEEN 1 AND 300)
        AND (end_reason IS NULL OR length(btrim(end_reason)) BETWEEN 1 AND 300))
);

CREATE INDEX IF NOT EXISTS supply_restrictions_contract_idx
    ON booking.supply_restrictions (supplier_contract_id);
CREATE INDEX IF NOT EXISTS supply_restrictions_room_type_idx
    ON booking.supply_restrictions (hotel_room_type_id, date_from) WHERE hotel_room_type_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supply_restrictions_service_idx
    ON booking.supply_restrictions (service_id, date_from) WHERE service_id IS NOT NULL;

COMMENT ON TABLE booking.supply_restrictions IS
    'bk-060 (AA-1145, T12, B8, T7): inventory kind of a component (room type or service) under a supplier contract for a date range (inclusive). allotment / free_sale / on_request = contract terms (status contract, draft only); stop_sale = an event on a published contract, in effect while pending or approved and not ended (T13). Engine precedence: stop_sale > allotment / free_sale > on_request.';
COMMENT ON COLUMN booking.supply_restrictions.units IS
    'conf:commercial; bk-060: allotment only: rooms per night (room type) or seats per day (service) the supplier holds for AA.';
COMMENT ON COLUMN booking.supply_restrictions.release_days IS
    'conf:commercial; bk-060: allotment only: units not sold this many days before the date go back to the supplier.';
COMMENT ON COLUMN booking.supply_restrictions.max_pax IS
    'conf:commercial; bk-060: free_sale only: most travellers per booking AA may confirm without asking (NULL = no limit).';
COMMENT ON COLUMN booking.supply_restrictions.note IS
    'pii:free_text; also conf:commercial (bk-060: staff note on the supplier term, e.g. the supplier e-mail that announced a stop-sale; staff text, never traveller data by rule).';
COMMENT ON COLUMN booking.supply_restrictions.reject_reason IS
    'pii:free_text; bk-060: why the second person rejected a stop-sale (staff text, never traveller data by rule).';
COMMENT ON COLUMN booking.supply_restrictions.withdraw_reason IS
    'pii:free_text; bk-060: why the maker withdrew a pending stop-sale (staff text, never traveller data by rule).';
COMMENT ON COLUMN booking.supply_restrictions.end_reason IS
    'pii:free_text; bk-060: why an approved stop-sale should end (staff text, never traveller data by rule).';

CREATE OR REPLACE FUNCTION booking.supply_restriction_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    k RECORD;
    v_supplier uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.inventory_kind = 'stop_sale' THEN
            RAISE EXCEPTION 'stop-sale % is never deleted (withdraw, reject or end it)', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        SELECT c.status INTO k FROM booking.supplier_contracts c WHERE c.id = OLD.supplier_contract_id FOR SHARE;
        IF k.status IS DISTINCT FROM 'draft' THEN
            RAISE EXCEPTION 'restriction % belongs to a % contract and is fixed', OLD.id, k.status
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        RETURN OLD;
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.inventory_kind = 'stop_sale' THEN
        -- A stop-sale's facts are fixed; only its decision and its end move (CHECKs keep the people apart).
        IF (NEW.supplier_contract_id, NEW.hotel_room_type_id, NEW.service_id, NEW.inventory_kind, NEW.date_from,
            NEW.date_to, NEW.note, NEW.created_by, NEW.created_at)
           IS DISTINCT FROM
           (OLD.supplier_contract_id, OLD.hotel_room_type_id, OLD.service_id, OLD.inventory_kind, OLD.date_from,
            OLD.date_to, OLD.note, OLD.created_by, OLD.created_at) THEN
            RAISE EXCEPTION 'stop-sale % keeps its facts; enter a new one instead', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        IF OLD.status IN ('rejected', 'withdrawn') OR OLD.ended_by IS NOT NULL THEN
            RAISE EXCEPTION 'stop-sale % is closed (%)', OLD.id, OLD.status
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        IF OLD.status = 'approved' AND NEW.status IS DISTINCT FROM 'approved' THEN
            RAISE EXCEPTION 'an approved stop-sale % ends through an end request, never a new status', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        IF OLD.status = 'approved' AND (NEW.decided_by, NEW.decided_at) IS DISTINCT FROM (OLD.decided_by, OLD.decided_at) THEN
            RAISE EXCEPTION 'the approval of stop-sale % is fixed', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.inventory_kind IS DISTINCT FROM OLD.inventory_kind
       AND 'stop_sale' IN (NEW.inventory_kind, OLD.inventory_kind) THEN
        RAISE EXCEPTION 'a contract restriction never becomes a stop-sale (or back)'
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.supplier_contract_id IS DISTINCT FROM OLD.supplier_contract_id THEN
        RAISE EXCEPTION 'restriction % cannot move to another contract', OLD.id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    SELECT c.status, c.supplier_id, c.valid_from, c.valid_to INTO k
    FROM booking.supplier_contracts c WHERE c.id = NEW.supplier_contract_id FOR SHARE;
    IF NEW.inventory_kind = 'stop_sale' THEN
        IF k.status IS DISTINCT FROM 'published' THEN
            RAISE EXCEPTION 'a stop-sale applies to a published contract (contract % is %)', NEW.supplier_contract_id,
                k.status USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        IF NEW.status <> 'pending' THEN
            RAISE EXCEPTION 'a new stop-sale starts pending (in effect at once, a second person reviews it)'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF k.status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'allotment, free-sale and on-request terms are written under a draft contract only (contract % is %)',
            NEW.supplier_contract_id, k.status USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF NEW.hotel_room_type_id IS NOT NULL THEN
        SELECT h.supplier_id INTO v_supplier
        FROM booking.hotel_room_types r JOIN booking.hotels h ON h.id = r.hotel_id
        WHERE r.id = NEW.hotel_room_type_id;
    ELSE
        SELECT s.supplier_id INTO v_supplier FROM booking.services s WHERE s.id = NEW.service_id;
    END IF;
    IF v_supplier IS DISTINCT FROM k.supplier_id THEN
        RAISE EXCEPTION 'a restriction names a room type or service of its contract''s own supplier'
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.date_from < k.valid_from OR (k.valid_to IS NOT NULL AND NEW.date_to > k.valid_to) THEN
        RAISE EXCEPTION 'restriction dates are outside the contract validity'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supply_restriction_guard() IS
    'bk-060: contract restrictions (allotment, free_sale, on_request) are written under a draft contract only; a stop-sale is entered pending on a published contract, keeps its facts, is never deleted; both name a component of the contract''s supplier inside its validity.';

CREATE OR REPLACE TRIGGER supply_restrictions_guard
    BEFORE INSERT OR UPDATE OR DELETE ON booking.supply_restrictions
    FOR EACH ROW EXECUTE FUNCTION booking.supply_restriction_guard();

CREATE OR REPLACE TRIGGER supply_restrictions_set_updated_at
    BEFORE UPDATE ON booking.supply_restrictions
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── 4. Pricing policy: default child % per service type (B4), version 1 = today's effective value ────────────────

INSERT INTO booking.pricing_policy (id, param_key, version_no, value, unit, effective_from, reason, created_by)
VALUES
    ('00000000-0000-4000-8000-0000b6000000', 'child_price_pct_by_service_type', 1,
     '{"activity": "100", "entrance": "100", "guide": "100", "meal": "100", "transfer": "100"}'::jsonb, '%',
     DATE '2026-01-01',
     'AA-1145: a child pays 100 % of the adult net when neither the supplier rate nor the contract gives a child price.',
     'seed:bk-060')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT '00000000-0000-4000-8000-0000b6000001'::uuid, p.id, p.created_by, 'submitted', p.created_by
FROM booking.pricing_policy p
WHERE p.id = '00000000-0000-4000-8000-0000b6000000' AND p.created_by = 'seed:bk-060'
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT '00000000-0000-4000-8000-0000b6000002'::uuid, p.id, p.created_by, 'approved',
       'tech lead S279 (thresholds rule: seeded defaults)'
FROM booking.pricing_policy p
WHERE p.id = '00000000-0000-4000-8000-0000b6000000' AND p.created_by = 'seed:bk-060'
ON CONFLICT DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM booking.pricing_policy p
        JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
        WHERE p.param_key = 'child_price_pct_by_service_type' AND p.version_no = 1
    ) THEN
        RAISE EXCEPTION 'bk-060: child_price_pct_by_service_type has no approved version 1';
    END IF;
END
$$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-060', now(), 'AA-1145: supply model (pax types and commissionable source numbers on rates, contract terms, supply restrictions with stop-sale, child % policy)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
