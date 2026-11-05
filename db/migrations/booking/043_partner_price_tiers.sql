-- Migration bk-043: AA-1030 R4 — agency price tiers: per-partner tier discounts and contract rate cards on the B2B
-- price (root ADR 0019 b15: one net price per tour per season, three agency tiers with percentage discounts set per
-- contract, 0 / 3 / 6 % to start, policy data editable later; RRP = net + 25 % stays the public price, bk-039).
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/043_partner_price_tiers.sql; on Dev it is applied as bk_owner (the live owner of schema
-- booking since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a), or by a person with DB
-- Migrate apply. Never run it from a laptop.
--
-- What:
--   1. booking.partner_tiers: the tier list (code, label, sort order). Seeded standard / silver / gold. Staff may add a
--      tier and relabel one (label, sort_order); a code never changes.
--   2. booking.partner_tier_discounts: the discount of a tier on the agency (b2b) price, a fraction (0.0300 = 3 %),
--      dated (valid_from), append-only like booking.pricing_rules: a change is a new row, in force only once a second
--      person approved it (booking.partner_price_approvals, maker-checker). Seeded 0 / 0.03 / 0.06 from 2026-11-01,
--      approved as seed:bk-043 (ADR 0019 b15 starting values).
--   3. booking.partner_rate_cards: an optional contract rate card of one partner: a discount on the agency price for
--      the whole catalogue (trip_plan_id NULL) or one trip plan, valid_from .. valid_to (NULL = open-ended), with the
--      contract reference. Append-only and maker-checker like the tier discounts. A card in force beats the tier; a
--      plan card beats a catalogue card. A card with discount_pct NULL is an END card: from its valid_from it ends the
--      contract rate of its scope (back to the catalogue card, then the tier), so an open-ended card can be ended
--      (contract over, card approved by mistake) through the same maker-checker. On one day an end card beats a
--      discount card of the same scope.
--   4. booking.partner_price_approvals: the second-person approvals of 2. and 3. (one row per approved row), with a
--      trigger refusing an approval by the row's creator. A table of its own, not more entity types on
--      booking.policy_approvals: bk-007 / bk-021 re-add that table's entity CHECK when they are replayed, which would
--      then refuse the new rows.
--   5. booking.b2b_partners.tier_code (NOT NULL DEFAULT 'standard', FK to partner_tiers): the partner's tier. Every
--      existing row (and every row bk_tenant_pull projects) starts on standard (0 %). Staff change it in Booking admin
--      (audited); role booking keeps its table-level UPDATE.
--   6. booking.b2b_quotes.partner_tier_code / tier_discount_pct and booking.b2b_quote_lines.agency_discount_pct /
--      rate_card_id: what a quote was priced with (the tier and its discount; per line the discount applied and the
--      rate card behind it, NULL = the tier). Quotes stay append-only; existing rows read as no discount.
--
-- Class: contract, not expand (root ADR 0017 d3): ALTERs, CHECKs and a FK on existing tables, seed rows. So a
-- migration-only PR (MIG-4); the code PR raises readiness to bk-043. On Dev: Infra Migration Apply once every job table
-- is idle (root ADR 0017a). Needs bk-009 (trip_plans), bk-019 (b2b_partners, b2b_quotes + lines).
-- DM-7.1 rows for the four new tables: root docs/architecture/data-standards/02-data-management.md (AA-1030 root PR,
-- merged before the Infra copy).
--
-- Locks: ACCESS EXCLUSIVE on b2b_partners, b2b_quotes and b2b_quote_lines for constant-default / nullable ADD COLUMNs
-- (no rewrite on PostgreSQL 11+) and the FK / CHECK adds (a scan of a few hundred rows). lock_timeout 5s.
-- Re-runnable (the integration tests replay every file): IF NOT EXISTS, DROP CONSTRAINT / TRIGGER IF EXISTS before each
-- ADD / CREATE, CREATE OR REPLACE FUNCTION, seed rows ON CONFLICT DO NOTHING, grants repeat.
-- Undo (a later bk- file, after the code is reverted): ALTER TABLE ... DROP COLUMN for the columns of 5. and 6.; DROP
-- TABLE booking.partner_price_approvals, booking.partner_rate_cards, booking.partner_tier_discounts,
-- booking.partner_tiers; DROP FUNCTION booking.partner_price_maker_checker().

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-043: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.b2b_partners') IS NULL OR to_regclass('booking.b2b_quotes') IS NULL
       OR to_regclass('booking.b2b_quote_lines') IS NULL OR to_regclass('booking.trip_plans') IS NULL THEN
        RAISE EXCEPTION 'bk-043: needs bk-009 (trip_plans) and bk-019 (b2b_partners, b2b_quotes, b2b_quote_lines)';
    END IF;
END $$;

-- ── 1. Tiers ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.partner_tiers (
    code        TEXT PRIMARY KEY,
    label       TEXT NOT NULL,
    sort_order  SMALLINT NOT NULL DEFAULT 0,
    created_by  TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT partner_tiers_code_chk CHECK (code ~ '^[a-z][a-z0-9_]{1,31}$'),
    CONSTRAINT partner_tiers_label_chk CHECK (length(btrim(label)) BETWEEN 1 AND 60),
    CONSTRAINT partner_tiers_sort_chk CHECK (sort_order BETWEEN 0 AND 999)
);
COMMENT ON TABLE booking.partner_tiers IS
    'bk-043 (AA-1030, root ADR 0019 b15): agency price tiers. b2b_partners.tier_code points here; the discount of a tier is a dated, approved row of partner_tier_discounts. Seeded standard / silver / gold.';
COMMENT ON COLUMN booking.partner_tiers.code IS 'bk-043: stable key (never renamed); label is what staff see.';
COMMENT ON COLUMN booking.partner_tiers.label IS 'conf:commercial; bk-043: the tier name staff and contracts use (Standard, Silver, Gold).';
COMMENT ON COLUMN booking.partner_tiers.created_by IS 'bk-043: staff cis_user_id who added the tier; NULL = the bk-043 seed.';

INSERT INTO booking.partner_tiers (code, label, sort_order) VALUES
    ('standard', 'Standard', 10),
    ('silver', 'Silver', 20),
    ('gold', 'Gold', 30)
ON CONFLICT (code) DO NOTHING;

-- ── 2. Tier discounts (append-only, maker-checker) ──────────────────────────

CREATE TABLE IF NOT EXISTS booking.partner_tier_discounts (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tier_code     TEXT NOT NULL REFERENCES booking.partner_tiers (code),
    discount_pct  NUMERIC(5, 4) NOT NULL,
    valid_from    DATE NOT NULL,
    note          TEXT,
    created_by    TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT partner_tier_discounts_pct_chk CHECK (discount_pct >= 0 AND discount_pct < 0.5),
    CONSTRAINT partner_tier_discounts_note_chk CHECK (note IS NULL OR length(note) <= 500)
);
CREATE UNIQUE INDEX IF NOT EXISTS partner_tier_discounts_tier_day_uq
    ON booking.partner_tier_discounts (tier_code, valid_from);
COMMENT ON TABLE booking.partner_tier_discounts IS
    'bk-043 (AA-1030, root ADR 0019 b15): discount of a tier on the agency (b2b) price. Append-only; in force on a day = the newest APPROVED row (partner_price_approvals) of the tier dated on or before it. Policy data, changed by a new row and a second person.';
COMMENT ON COLUMN booking.partner_tier_discounts.discount_pct IS
    'conf:commercial; bk-043: fraction taken off the b2b price (0.0300 = 3 %); below 0.5.';
COMMENT ON COLUMN booking.partner_tier_discounts.note IS 'conf:commercial; bk-043: why the change, who confirmed it.';
COMMENT ON COLUMN booking.partner_tier_discounts.created_by IS 'bk-043: staff cis_user_id (the maker); NULL = the bk-043 seed.';

INSERT INTO booking.partner_tier_discounts (id, tier_code, discount_pct, valid_from, note) VALUES
    ('00000000-0000-4000-8000-0000000b4501', 'standard', 0.0000, DATE '2026-11-01', 'bk-043 seed: ADR 0019 b15 starting value'),
    ('00000000-0000-4000-8000-0000000b4502', 'silver', 0.0300, DATE '2026-11-01', 'bk-043 seed: ADR 0019 b15 starting value'),
    ('00000000-0000-4000-8000-0000000b4503', 'gold', 0.0600, DATE '2026-11-01', 'bk-043 seed: ADR 0019 b15 starting value')
ON CONFLICT (id) DO NOTHING;

-- ── 3. Contract rate cards (append-only, maker-checker) ─────────────────────

CREATE TABLE IF NOT EXISTS booking.partner_rate_cards (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id    UUID NOT NULL REFERENCES booking.b2b_partners (id),
    trip_plan_id  UUID REFERENCES booking.trip_plans (id),
    discount_pct  NUMERIC(5, 4),
    valid_from    DATE NOT NULL,
    valid_to      DATE,
    contract_ref  TEXT,
    note          TEXT,
    created_by    TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT partner_rate_cards_pct_chk CHECK (discount_pct IS NULL OR (discount_pct >= 0 AND discount_pct < 0.5)),
    CONSTRAINT partner_rate_cards_validity_chk CHECK (valid_to IS NULL OR valid_to >= valid_from),
    CONSTRAINT partner_rate_cards_ref_chk CHECK (
        contract_ref IS NULL OR length(btrim(contract_ref)) BETWEEN 1 AND 120),
    CONSTRAINT partner_rate_cards_note_chk CHECK (note IS NULL OR length(note) <= 500)
);
-- One discount card and one end card per partner, scope and day (an end card can end a card on its first day).
CREATE UNIQUE INDEX IF NOT EXISTS partner_rate_cards_scope_day_uq
    ON booking.partner_rate_cards (partner_id, coalesce(trip_plan_id, '00000000-0000-0000-0000-000000000000'::uuid),
                                   valid_from, (discount_pct IS NULL));
CREATE INDEX IF NOT EXISTS partner_rate_cards_partner_idx ON booking.partner_rate_cards (partner_id, valid_from DESC);
COMMENT ON TABLE booking.partner_rate_cards IS
    'bk-043 (AA-1030): contract rate card of one B2B partner, a discount on the agency (b2b) price for the whole catalogue (trip_plan_id NULL) or one trip plan, valid_from .. valid_to. Overrides the tier while in force (a plan card beats a catalogue card). discount_pct NULL = an end card: ends the contract rate of its scope from valid_from (back to the catalogue card, then the tier). Append-only; in force once approved (partner_price_approvals).';
COMMENT ON COLUMN booking.partner_rate_cards.discount_pct IS
    'conf:commercial; bk-043: fraction taken off the b2b price (0.0450 = 4.5 %); below 0.5. NULL = an end card (no contract rate for this scope from valid_from).';
COMMENT ON COLUMN booking.partner_rate_cards.valid_to IS 'bk-043: last day of the card; NULL = open-ended.';
COMMENT ON COLUMN booking.partner_rate_cards.contract_ref IS 'conf:commercial; bk-043: the partner contract reference (no personal data).';
COMMENT ON COLUMN booking.partner_rate_cards.note IS 'conf:commercial; bk-043: staff note.';
COMMENT ON COLUMN booking.partner_rate_cards.created_by IS 'bk-043: staff cis_user_id (the maker).';

-- ── 4. Approvals (maker-checker) ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.partner_price_approvals (
    id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type               TEXT NOT NULL,
    partner_tier_discount_id  UUID REFERENCES booking.partner_tier_discounts (id),
    partner_rate_card_id      UUID REFERENCES booking.partner_rate_cards (id),
    approved_by               TEXT NOT NULL,
    approved_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    note                      TEXT,

    CONSTRAINT partner_price_approvals_entity_chk CHECK (
        (entity_type = 'partner_tier_discount' AND partner_tier_discount_id IS NOT NULL
            AND partner_rate_card_id IS NULL)
        OR (entity_type = 'partner_rate_card' AND partner_rate_card_id IS NOT NULL
            AND partner_tier_discount_id IS NULL)),
    CONSTRAINT partner_price_approvals_by_chk CHECK (length(btrim(approved_by)) BETWEEN 1 AND 128),
    CONSTRAINT partner_price_approvals_note_chk CHECK (note IS NULL OR length(note) <= 500)
);
CREATE UNIQUE INDEX IF NOT EXISTS partner_price_approvals_discount_uq
    ON booking.partner_price_approvals (partner_tier_discount_id);
CREATE UNIQUE INDEX IF NOT EXISTS partner_price_approvals_card_uq
    ON booking.partner_price_approvals (partner_rate_card_id);
COMMENT ON TABLE booking.partner_price_approvals IS
    'bk-043 (AA-1030): second-person approvals of partner_tier_discounts and partner_rate_cards rows (one per approved row); the creator of a row cannot approve it (trigger). Same maker-checker as booking.policy_approvals (bk-007).';
COMMENT ON COLUMN booking.partner_price_approvals.approved_by IS
    'bk-043: staff cis_user_id of the checker, or seed:bk-043.';
COMMENT ON COLUMN booking.partner_price_approvals.note IS 'conf:commercial; bk-043: approval note.';

CREATE OR REPLACE FUNCTION booking.partner_price_maker_checker() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_maker TEXT;
BEGIN
    IF NEW.entity_type = 'partner_tier_discount' THEN
        SELECT d.created_by INTO v_maker FROM booking.partner_tier_discounts d WHERE d.id = NEW.partner_tier_discount_id;
    ELSE
        SELECT c.created_by INTO v_maker FROM booking.partner_rate_cards c WHERE c.id = NEW.partner_rate_card_id;
    END IF;
    IF v_maker IS NOT NULL AND v_maker = NEW.approved_by THEN
        RAISE EXCEPTION 'the creator of a % row cannot approve it (maker-checker)', NEW.entity_type
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
COMMENT ON FUNCTION booking.partner_price_maker_checker() IS
    'bk-043: refuses a partner_price_approvals row whose approver created the approved tier discount / rate card.';

DROP TRIGGER IF EXISTS partner_price_approvals_maker_checker ON booking.partner_price_approvals;
CREATE TRIGGER partner_price_approvals_maker_checker
    BEFORE INSERT ON booking.partner_price_approvals
    FOR EACH ROW EXECUTE FUNCTION booking.partner_price_maker_checker();

INSERT INTO booking.partner_price_approvals (entity_type, partner_tier_discount_id, approved_by, note) VALUES
    ('partner_tier_discount', '00000000-0000-4000-8000-0000000b4501', 'seed:bk-043', 'ADR 0019 b15 starting value'),
    ('partner_tier_discount', '00000000-0000-4000-8000-0000000b4502', 'seed:bk-043', 'ADR 0019 b15 starting value'),
    ('partner_tier_discount', '00000000-0000-4000-8000-0000000b4503', 'seed:bk-043', 'ADR 0019 b15 starting value')
ON CONFLICT (partner_tier_discount_id) DO NOTHING;

-- ── 5. The partner's tier ────────────────────────────────────────────────────

ALTER TABLE booking.b2b_partners ADD COLUMN IF NOT EXISTS tier_code TEXT NOT NULL DEFAULT 'standard';
ALTER TABLE booking.b2b_partners DROP CONSTRAINT IF EXISTS b2b_partners_tier_fk;
ALTER TABLE booking.b2b_partners ADD CONSTRAINT b2b_partners_tier_fk
    FOREIGN KEY (tier_code) REFERENCES booking.partner_tiers (code);
COMMENT ON COLUMN booking.b2b_partners.tier_code IS
    'conf:commercial; bk-043 (AA-1030): the partner''s price tier (booking.partner_tiers); its approved discount applies to the b2b price unless a partner rate card is in force. Default standard.';

-- ── 6. What a quote was priced with ──────────────────────────────────────────

ALTER TABLE booking.b2b_quotes
    ADD COLUMN IF NOT EXISTS partner_tier_code TEXT,
    ADD COLUMN IF NOT EXISTS tier_discount_pct NUMERIC(5, 4) NOT NULL DEFAULT 0;
ALTER TABLE booking.b2b_quotes DROP CONSTRAINT IF EXISTS b2b_quotes_tier_discount_chk;
ALTER TABLE booking.b2b_quotes ADD CONSTRAINT b2b_quotes_tier_discount_chk CHECK (
    tier_discount_pct >= 0 AND tier_discount_pct < 0.5
    AND (partner_tier_code IS NULL OR partner_tier_code ~ '^[a-z][a-z0-9_]{1,31}$'));
COMMENT ON COLUMN booking.b2b_quotes.partner_tier_code IS
    'bk-043 (AA-1030): the partner''s tier when the quote was priced; NULL = a quote from before bk-043.';
COMMENT ON COLUMN booking.b2b_quotes.tier_discount_pct IS
    'conf:commercial; bk-043: the approved tier discount in force on the quote day (0 = none or before bk-043).';

ALTER TABLE booking.b2b_quote_lines
    ADD COLUMN IF NOT EXISTS agency_discount_pct NUMERIC(5, 4) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS rate_card_id UUID;
ALTER TABLE booking.b2b_quote_lines DROP CONSTRAINT IF EXISTS b2b_quote_lines_discount_chk;
ALTER TABLE booking.b2b_quote_lines ADD CONSTRAINT b2b_quote_lines_discount_chk CHECK (
    agency_discount_pct >= 0 AND agency_discount_pct < 0.5);
ALTER TABLE booking.b2b_quote_lines DROP CONSTRAINT IF EXISTS b2b_quote_lines_rate_card_fk;
ALTER TABLE booking.b2b_quote_lines ADD CONSTRAINT b2b_quote_lines_rate_card_fk
    FOREIGN KEY (rate_card_id) REFERENCES booking.partner_rate_cards (id);
COMMENT ON COLUMN booking.b2b_quote_lines.agency_discount_pct IS
    'conf:commercial; bk-043 (AA-1030): the discount taken off this line''s b2b price (rate card or tier).';
COMMENT ON COLUMN booking.b2b_quote_lines.rate_card_id IS
    'conf:commercial; bk-043: the partner rate card behind agency_discount_pct; NULL = the tier discount (or none).';

-- ── Grants (per table) ───────────────────────────────────────────────────────

-- The schema's default privileges may have granted more on creation: the rate tables are append-only for the app, and
-- a tier's code never changes (a table-level REVOKE first, then the column grant: the REVOKE drops column grants too).
REVOKE UPDATE, DELETE, TRUNCATE ON booking.partner_tiers FROM booking;
GRANT SELECT, INSERT ON booking.partner_tiers TO booking;
GRANT UPDATE (label, sort_order) ON booking.partner_tiers TO booking;
GRANT SELECT, INSERT ON booking.partner_tier_discounts TO booking;
GRANT SELECT, INSERT ON booking.partner_rate_cards TO booking;
GRANT SELECT, INSERT ON booking.partner_price_approvals TO booking;
GRANT EXECUTE ON FUNCTION booking.partner_price_maker_checker() TO booking;
REVOKE UPDATE, DELETE, TRUNCATE ON booking.partner_tier_discounts FROM booking;
REVOKE UPDATE, DELETE, TRUNCATE ON booking.partner_rate_cards FROM booking;
REVOKE UPDATE, DELETE, TRUNCATE ON booking.partner_price_approvals FROM booking;

-- ── Closing checks ───────────────────────────────────────────────────────────

DO $$
BEGIN
    IF has_table_privilege('booking', 'booking.partner_tier_discounts', 'UPDATE')
       OR has_table_privilege('booking', 'booking.partner_rate_cards', 'UPDATE')
       OR has_table_privilege('booking', 'booking.partner_price_approvals', 'UPDATE')
       OR has_table_privilege('booking', 'booking.partner_tier_discounts', 'DELETE')
       OR has_table_privilege('booking', 'booking.partner_rate_cards', 'DELETE')
       OR has_table_privilege('booking', 'booking.partner_price_approvals', 'DELETE')
       OR has_table_privilege('booking', 'booking.partner_tiers', 'DELETE')
       OR has_column_privilege('booking', 'booking.partner_tiers', 'code', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-043: role booking can rewrite a tier, a discount, a rate card or an approval';
    END IF;
    IF NOT has_column_privilege('booking', 'booking.b2b_partners', 'tier_code', 'UPDATE')
       OR NOT has_column_privilege('booking', 'booking.b2b_quotes', 'tier_discount_pct', 'INSERT')
       OR NOT has_column_privilege('booking', 'booking.b2b_quote_lines', 'rate_card_id', 'INSERT')
       OR NOT has_table_privilege('booking', 'booking.partner_price_approvals', 'INSERT') THEN
        RAISE EXCEPTION 'bk-043: role booking cannot write the new columns or approvals';
    END IF;
    IF (SELECT count(*) FROM booking.partner_tier_discounts d
          JOIN booking.partner_price_approvals a ON a.partner_tier_discount_id = d.id
         WHERE d.id IN ('00000000-0000-4000-8000-0000000b4501', '00000000-0000-4000-8000-0000000b4502',
                        '00000000-0000-4000-8000-0000000b4503')) <> 3 THEN
        RAISE EXCEPTION 'bk-043: the three seeded tier discounts are not all approved';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-043', now(), 'AA-1030: agency price tiers (partner_tiers + approved dated discounts 0/3/6 %, partner rate cards, partner_price_approvals maker-checker, b2b_partners.tier_code, quote tier/discount columns)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
