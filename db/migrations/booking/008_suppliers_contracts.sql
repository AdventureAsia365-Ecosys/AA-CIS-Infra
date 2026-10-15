-- Migration bk-008: AA-822 — Booking wave 2a: suppliers and supplier contracts (ADR 0005 decisions 1, 2, 8;
-- S236 UI spec §3, §6.3, module spec 08, Q20).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/008_suppliers_contracts.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as aa_cis_admin. Never run it from a laptop.
--
-- Depends on bk-001 (schema, role, set_updated_at), bk-003 (staff_users) and bk-005 (countries) only. It does NOT
-- reference any bk-004 / bk-006 / bk-007 object (bk-007, AA-810, was written in parallel and is applied before it on
-- Dev, but bk-008 would apply without it). Every grant below names its table: no blanket "ON ALL TABLES" grant, which would re-open
-- UPDATE/DELETE on the append-only pricing tables of bk-004.
--
-- What it adds (docs/implementation-notes/AA-822.md):
--   * booking.suppliers: the supplier master record (all COMMERCIAL data, spec 08 data mapping). Human code
--     SUP-000123. categories[] is one or more of hotel / transport / guide / entrance / activity / meal (Q20; no
--     "awaiting document check" state). destination_id is a CIS place id (catalog.v_destination) validated by the
--     API: there is no FK across schemas (role booking has SELECT on the catalog views, not REFERENCES). country_code
--     references the bk-005 ISO list. Suppliers are never deleted: status active / inactive only (role booking has
--     no DELETE), and the API refuses to deactivate a supplier while a published contract is in force or upcoming.
--   * booking.supplier_contracts: validity (valid_from / valid_to, NULL = open-ended), the supplier currency,
--     payment terms, cancellation policy, a free-text document reference (no upload yet) and status
--     draft -> published -> expired. Maker-checker (ADR 0005 d8): the person who publishes is not the last person
--     who wrote the draft terms (its last editor, or its creator when nobody edited it; CHECK below, the API answers
--     403 first). So a two-person team never deadlocks: when B corrects A's draft, A checks B's edit and publishes.
--     Publishing is a move on its own: the same UPDATE may not change the terms or their writer (trigger below).
--     A published contract is fixed
--     ("never overwrite", ADR 0005 d2): only the move to expired is allowed (trigger below). Contracts are never
--     deleted either.
--   * Personal-data and commercial columns carry pii: / conf:commercial comment tags (data standards DM-6.1).
--   * One 'MN' (Mongolia) row in booking.countries: AA sells Mongolia and its suppliers need a country.
--
-- Status columns stay TEXT + CHECK. Re-running the whole file is a no-op.

BEGIN;

-- ── Countries: one more ISO row ──────────────────────────────────────────────

INSERT INTO booking.countries (iso2, name) VALUES ('MN', 'Mongolia')
ON CONFLICT (iso2) DO NOTHING;

-- ── Suppliers ────────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS booking.supplier_code_seq;

CREATE TABLE IF NOT EXISTS booking.suppliers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code            TEXT NOT NULL DEFAULT ('SUP-' || lpad(nextval('booking.supplier_code_seq')::text, 6, '0')),
    company_name    TEXT NOT NULL,
    categories      TEXT[] NOT NULL,
    website         TEXT,
    internal_notes  TEXT,
    contact_name    TEXT,
    contact_title   TEXT,
    contact_email   TEXT,
    contact_phone   TEXT,
    address         TEXT,
    region          TEXT,
    postal_code     TEXT,
    destination_id  UUID,
    country_code    CHAR(2) REFERENCES booking.countries (iso2),
    status          TEXT NOT NULL DEFAULT 'active',
    created_by      TEXT REFERENCES booking.staff_users (cis_user_id),
    updated_by      TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT suppliers_code_uq UNIQUE (code),
    CONSTRAINT suppliers_name_chk CHECK (length(btrim(company_name)) BETWEEN 1 AND 200),
    CONSTRAINT suppliers_categories_chk CHECK (
        cardinality(categories) BETWEEN 1 AND 6
        AND categories <@ ARRAY['hotel', 'transport', 'guide', 'entrance', 'activity', 'meal']::text[]),
    CONSTRAINT suppliers_website_chk CHECK (website IS NULL OR website ~* '^https?://[^\s]+$'),
    CONSTRAINT suppliers_email_chk CHECK (contact_email IS NULL OR contact_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    CONSTRAINT suppliers_status_chk CHECK (status IN ('active', 'inactive'))
);

COMMENT ON TABLE booking.suppliers IS
    'bk-008 (AA-822, ADR 0005 d1): supplier master record, all commercial. Never deleted: status active / inactive. destination_id is a CIS catalog.v_destination id checked by the API (no cross-schema FK).';
COMMENT ON COLUMN booking.suppliers.categories IS
    'bk-008 (Q20): one or more of hotel, transport, guide, entrance, activity, meal (ADR 0005 rate sheet types).';
COMMENT ON COLUMN booking.suppliers.internal_notes IS
    'conf:commercial; bk-008 (spec 08 conflict 2): staff-only notes about the supplier; never shown to customers.';
COMMENT ON COLUMN booking.suppliers.contact_name IS 'pii:name; bk-008: supplier contact person.';
COMMENT ON COLUMN booking.suppliers.contact_email IS 'pii:contact; bk-008: supplier contact e-mail (lower-cased by the API).';
COMMENT ON COLUMN booking.suppliers.contact_phone IS 'pii:contact; bk-008: supplier contact phone.';
COMMENT ON COLUMN booking.suppliers.destination_id IS
    'bk-008: CIS place id (catalog.v_destination.destination_id, golden record shared.destinations). Validated by the API; no FK across schemas.';

-- One live record per supplier name and country (a double submit or a duplicate entry is refused).
CREATE UNIQUE INDEX IF NOT EXISTS suppliers_name_country_uq
    ON booking.suppliers (lower(btrim(company_name)), coalesce(country_code, '--'));
CREATE INDEX IF NOT EXISTS suppliers_status_idx ON booking.suppliers (status);
CREATE INDEX IF NOT EXISTS suppliers_country_idx ON booking.suppliers (country_code);
CREATE INDEX IF NOT EXISTS suppliers_categories_idx ON booking.suppliers USING gin (categories);
CREATE INDEX IF NOT EXISTS suppliers_updated_idx ON booking.suppliers (updated_at DESC);
CREATE INDEX IF NOT EXISTS suppliers_destination_idx ON booking.suppliers (destination_id) WHERE destination_id IS NOT NULL;

CREATE OR REPLACE TRIGGER suppliers_set_updated_at
    BEFORE UPDATE ON booking.suppliers
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Supplier contracts ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.supplier_contracts (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id          UUID NOT NULL REFERENCES booking.suppliers (id),
    title                TEXT NOT NULL,
    reference            TEXT,
    valid_from           DATE NOT NULL,
    valid_to             DATE,
    currency             CHAR(3) NOT NULL,
    payment_terms        TEXT,
    cancellation_policy  TEXT,
    notes                TEXT,
    status               TEXT NOT NULL DEFAULT 'draft',
    created_by           TEXT NOT NULL REFERENCES booking.staff_users (cis_user_id),
    updated_by           TEXT REFERENCES booking.staff_users (cis_user_id),
    published_by         TEXT REFERENCES booking.staff_users (cis_user_id),
    published_at         TIMESTAMPTZ,
    expired_by           TEXT REFERENCES booking.staff_users (cis_user_id),
    expired_at           TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT supplier_contracts_title_chk CHECK (length(btrim(title)) BETWEEN 1 AND 200),
    CONSTRAINT supplier_contracts_validity_chk CHECK (valid_to IS NULL OR valid_to >= valid_from),
    CONSTRAINT supplier_contracts_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT supplier_contracts_status_chk CHECK (status IN ('draft', 'published', 'expired')),
    CONSTRAINT supplier_contracts_published_chk CHECK (
        (status = 'draft' AND published_by IS NULL AND published_at IS NULL)
        OR (status IN ('published', 'expired') AND published_by IS NOT NULL AND published_at IS NOT NULL)),
    CONSTRAINT supplier_contracts_expired_chk CHECK (
        (status = 'expired') = (expired_by IS NOT NULL AND expired_at IS NOT NULL)),
    -- Maker-checker (ADR 0005 d8): one person enters or edits, another publishes. The maker is the last writer of
    -- the draft terms (updated_by; created_by while nobody has edited it).
    CONSTRAINT supplier_contracts_maker_checker_chk CHECK (
        published_by IS NULL
        OR published_by <> coalesce(updated_by, created_by))
);

COMMENT ON TABLE booking.supplier_contracts IS
    'bk-008 (AA-822, ADR 0005 d2/d8): supplier contract terms (validity, currency, payment terms, cancellation policy). draft -> published (by a second person) -> expired. Published rows are fixed; never deleted.';
COMMENT ON COLUMN booking.supplier_contracts.currency IS
    'bk-008: the supplier currency of the contract (ISO 4217); rates under it are converted with bk-004 fx_rates.';
COMMENT ON COLUMN booking.supplier_contracts.reference IS
    'bk-008: the supplier''s contract number or a document reference (free text; document upload is out of scope).';
COMMENT ON COLUMN booking.supplier_contracts.payment_terms IS 'conf:commercial; bk-008: payment terms agreed with the supplier.';
COMMENT ON COLUMN booking.supplier_contracts.cancellation_policy IS 'conf:commercial; bk-008: supplier cancellation policy.';
COMMENT ON COLUMN booking.supplier_contracts.notes IS 'conf:commercial; bk-008: staff-only notes on the contract.';
COMMENT ON COLUMN booking.supplier_contracts.updated_by IS
    'bk-008: last editor of the draft terms (the maker); publishing does not change it.';

CREATE INDEX IF NOT EXISTS supplier_contracts_supplier_idx
    ON booking.supplier_contracts (supplier_id, valid_from DESC);
CREATE INDEX IF NOT EXISTS supplier_contracts_published_idx
    ON booking.supplier_contracts (supplier_id, valid_to) WHERE status = 'published';

CREATE OR REPLACE TRIGGER supplier_contracts_set_updated_at
    BEFORE UPDATE ON booking.supplier_contracts
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- A published contract is fixed (new terms = a new contract, ADR 0005 d2). The only change allowed afterwards is
-- published -> expired (with who and when); an expired contract does not change at all. A draft never jumps to
-- expired: it is published first.
CREATE OR REPLACE FUNCTION booking.supplier_contract_lock() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF OLD.status = 'draft' THEN
        IF NEW.status = 'expired' THEN
            RAISE EXCEPTION 'supplier contract % is a draft and cannot expire before it is published', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        -- Publishing is a move on its own: the checker publishes exactly the terms the maker wrote, so the same
        -- UPDATE may not change the terms or who wrote them (else the maker-checker CHECK could be side-stepped).
        IF NEW.status = 'published'
           AND (NEW.supplier_id, NEW.title, NEW.reference, NEW.valid_from, NEW.valid_to, NEW.currency,
                NEW.payment_terms, NEW.cancellation_policy, NEW.notes, NEW.created_by, NEW.updated_by)
               IS DISTINCT FROM
               (OLD.supplier_id, OLD.title, OLD.reference, OLD.valid_from, OLD.valid_to, OLD.currency,
                OLD.payment_terms, OLD.cancellation_policy, OLD.notes, OLD.created_by, OLD.updated_by)
        THEN
            RAISE EXCEPTION 'supplier contract % is published on its own, without changing its terms', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.status = 'published' AND NEW.status = 'expired'
       AND NEW.supplier_id = OLD.supplier_id
       AND NEW.title = OLD.title
       AND NEW.reference IS NOT DISTINCT FROM OLD.reference
       AND NEW.valid_from = OLD.valid_from
       AND NEW.valid_to IS NOT DISTINCT FROM OLD.valid_to
       AND NEW.currency = OLD.currency
       AND NEW.payment_terms IS NOT DISTINCT FROM OLD.payment_terms
       AND NEW.cancellation_policy IS NOT DISTINCT FROM OLD.cancellation_policy
       AND NEW.notes IS NOT DISTINCT FROM OLD.notes
       AND NEW.created_by = OLD.created_by
       AND NEW.updated_by IS NOT DISTINCT FROM OLD.updated_by
       AND NEW.published_by = OLD.published_by
       AND NEW.published_at = OLD.published_at
    THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'supplier contract % is % and is locked', OLD.id, OLD.status
        USING ERRCODE = 'object_not_in_prerequisite_state';
END $$;

COMMENT ON FUNCTION booking.supplier_contract_lock() IS
    'bk-008: published supplier contracts are fixed except published -> expired; expired contracts never change.';

CREATE OR REPLACE TRIGGER supplier_contracts_lock
    BEFORE UPDATE ON booking.supplier_contracts
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_contract_lock();

-- ── Grants (per object; no blanket ALL TABLES grant, see header) ─────────────

GRANT SELECT, INSERT, UPDATE ON booking.suppliers TO booking;
GRANT SELECT, INSERT, UPDATE ON booking.supplier_contracts TO booking;
GRANT USAGE, SELECT ON SEQUENCE booking.supplier_code_seq TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_contract_lock() TO booking;

-- Suppliers and contracts are never deleted (deactivate / expire instead); default privileges grant DELETE.
REVOKE DELETE, TRUNCATE ON booking.suppliers FROM booking;
REVOKE DELETE, TRUNCATE ON booking.supplier_contracts FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-008', now(), 'AA-822 wave 2a: suppliers (SUP- code, categories, contact, address, destination_id, country_code, active/inactive, no delete) + supplier_contracts (validity, currency, payment terms, cancellation policy, draft/published/expired, maker-checker publish, published lock), countries MN')
ON CONFLICT (version) DO NOTHING;

COMMIT;
