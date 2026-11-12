-- migrate: expand
-- Migration 402: AA-1091 item 5 (root ADR 0005 decision 7) — the structured reference price of an AA tour: amount,
-- currency and basis, parsed from the free-text source price (raw_tours.price_raw) or entered by staff.
--
-- Why. The reference price of a tour is free text (raw_tours.price_raw: "$1,722/person", "from USD 495", a tier table)
-- and feeds nothing structured; 281 live tours have none. The customer-service team must be able to enter and correct
-- it quickly (admin page with inline edit, bulk accept, Excel export / import with DRY RUN), and AA-Booking reads it
-- (a later catalog contract view) next to the price its cost sheet computes. ADR 0005 d7: the text may be parsed once
-- into a REFERENCE price with a review flag; it is never a selling price and the text stays as stored, for audit.
--
-- What.
--   1. silver_aa_internal.tour_reference_price: one row per catalog key (raw_tours.source_key = the source_id of
--      catalog.tour.v1, stable across source versions, so a re-upload of the tour keeps its reference price):
--        amount / currency / basis   the reference price: amount > 0 (numeric(12,2)), ISO 4217 code, basis
--                                    per_person | per_group | from ("from" = the lowest per-person price of the tour);
--                                    all three or none (a row without an amount is never written; clearing deletes)
--        origin                      parsed (services/reference_price parser) | staff (admin inline edit or accept)
--                                    | import (an Excel import)
--        needs_review                true when the parser had doubts (several amounts or currencies, no basis word,
--                                    a tier table ...); review_reasons lists them (codes only, no text)
--        price_raw_seen              the source text the value was set against (audit; when raw_tours.price_raw moves
--                                    away from it the price shows "text changed" until a person confirms it again)
--        reviewed_by / reviewed_at   the staff member who confirmed the value (both or neither)
--        note                        optional staff note (<= 500 characters)
--        updated_by / created_at / updated_at
--      No FK: raw_tours.source_key is not unique (one key, several source versions). No tenant column: AA master tours
--      only (the writer checks the key against the AA master tenant's active rows).
--   2. GRANT cis_app SELECT, INSERT, UPDATE, DELETE (the admin routes write, the list reads). catalog_owner's SELECT
--      (the Booking contract view reads it under the catalog recipe) is granted by 403: an expand file grants only to
--      the owner's runtime roles.
--   3. Register 402.
--
-- PII (DM-6.1). None: a price, codes, the source price text (business data already in raw_tours) and staff actor ids
-- (admin:<uuid>). The note is a short business remark, never personal data (the UI says so).
--
-- Retention (DM-7.1). Proposed: kept while its catalog key exists (reference data, one row per key); a key that the tour
-- lifecycle purges loses its row in the same erasure run (no TTL kind). Row in root data standards Part B section 7, in
-- the root PR of this change (merged before the Infra copy).
--
-- Behaviour. None on apply: the table is empty. The code PR (admin page and routes) writes it; until then nothing reads
-- it, and the admin routes answer 503 "not migrated" before this file is applied.
--
-- Class: expand (root ADR 0017 d3): a new table with its constraints and an index, grants on it and comments; no existing
-- object changes, no seed row, no DO block. Ships in the migration-only PR with 403 (the contract view that reads it).
--
-- Number. 401 is the highest on main (12/11/2026, the tenant account is_synthetic view); renumbered from 401 (S278 review).
--
-- Rollback (a new forward migration, after the code and 403 are reverted): DROP TABLE
-- silver_aa_internal.tour_reference_price (a destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of schema
-- silver_aa_internal.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS silver_aa_internal.tour_reference_price (
    source_key      text           NOT NULL,
    amount          numeric(12,2)  NOT NULL,
    currency        text           NOT NULL,
    basis           text           NOT NULL,
    origin          text           NOT NULL,
    needs_review    boolean        NOT NULL DEFAULT false,
    review_reasons  text[]         NOT NULL DEFAULT '{}'::text[],
    price_raw_seen  text,
    note            text,
    reviewed_by     text,
    reviewed_at     timestamptz,
    updated_by      text           NOT NULL,
    created_at      timestamptz    NOT NULL DEFAULT now(),
    updated_at      timestamptz    NOT NULL DEFAULT now(),
    CONSTRAINT tour_reference_price_pkey PRIMARY KEY (source_key),
    CONSTRAINT tour_reference_price_key_check CHECK (length(source_key) BETWEEN 1 AND 64),
    CONSTRAINT tour_reference_price_amount_check CHECK (amount > 0 AND amount < 10000000000),
    CONSTRAINT tour_reference_price_currency_check CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT tour_reference_price_basis_check CHECK (basis IN ('per_person', 'per_group', 'from')),
    CONSTRAINT tour_reference_price_origin_check CHECK (origin IN ('parsed', 'staff', 'import')),
    CONSTRAINT tour_reference_price_reasons_check CHECK (cardinality(review_reasons) <= 10),
    CONSTRAINT tour_reference_price_review_check CHECK ((reviewed_by IS NULL) = (reviewed_at IS NULL)),
    CONSTRAINT tour_reference_price_text_check CHECK (
        (price_raw_seen IS NULL OR length(price_raw_seen) <= 2000) AND (note IS NULL OR length(note) <= 500)
        AND length(updated_by) BETWEEN 1 AND 128 AND (reviewed_by IS NULL OR length(reviewed_by) <= 128))
);

CREATE INDEX IF NOT EXISTS tour_reference_price_review_idx
    ON silver_aa_internal.tour_reference_price (needs_review, updated_at DESC);

COMMENT ON TABLE silver_aa_internal.tour_reference_price IS
    'AA-1091 (CIS 402, root ADR 0005 d7): the structured REFERENCE price of an AA tour per catalog key (raw_tours.'
    'source_key): amount, currency, basis, parsed from raw_tours.price_raw or entered by staff (admin Reference prices '
    'page, Excel import with DRY RUN). Never a selling price. The free text stays in raw_tours.price_raw.';
COMMENT ON COLUMN silver_aa_internal.tour_reference_price.basis IS
    'AA-1091 (402): per_person | per_group | from (the lowest per-person price of the tour).';
COMMENT ON COLUMN silver_aa_internal.tour_reference_price.origin IS
    'AA-1091 (402): parsed (the parser, not reviewed) | staff (admin edit or accept) | import (Excel import).';
COMMENT ON COLUMN silver_aa_internal.tour_reference_price.review_reasons IS
    'AA-1091 (402): the parser''s doubt codes (several_amounts, several_currencies, basis_assumed, tiered, ...); empty '
    'when it had none.';
COMMENT ON COLUMN silver_aa_internal.tour_reference_price.price_raw_seen IS
    'AA-1091 (402): the raw_tours.price_raw the value was set against; a different current text = needs review.';

GRANT SELECT, INSERT, UPDATE, DELETE ON silver_aa_internal.tour_reference_price TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('402', now(), 'AA-1091: silver_aa_internal.tour_reference_price (structured reference price per catalog key)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
