-- Migration bk-019: AA-972 (CRM-B1) — B2B partners, B2B quotes and the supply components of a trip plan
-- (root ADR 0005a decisions 1-2, ADR 0006b decision 7; contract booking.b2b.v1; Booking commercial-core memo seams 1, 6,
-- 7, 9).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra db/migrations/booking/019_b2b_partners_quotes.sql
-- and is applied to Dev by the DB Migrate workflow (check, then apply), as bk_owner (the live owner of schema booking
-- since bk-014). Never run it from a laptop.
--
-- Depends on bk-001 (schema, role, set_updated_at), bk-003 (staff_users), bk-005 (settings), bk-009 (trip_plans) and
-- bk-010 (hotel_room_types, services). Every grant names its table (no "ON ALL TABLES").
--
-- What it adds (docs/implementation-notes/AA-972.md):
--   * booking.b2b_partners: one row per partner agency allowed to call booking.b2b.v1. tenant_id is the agency's CIS
--     tenant id (soft key, the X-AA-Tenant-Id header; no FK across apps); m2m_client_id is the aa-m2m app client that
--     may act for it (the token's client_id must match). Never deleted: status active / suspended.
--   * booking.b2b_quotes + booking.b2b_quote_lines: one priced quote per POST /booking/b2b/v1/quotes, APPEND-ONLY for
--     role booking (SELECT, INSERT). A quote carries its FX lock (plain rate, buffer, date, source), the b2b rule it
--     used, the rounding rule, valid_until and the price_hash; a line carries what was asked (component, service date,
--     pax counts, rooms) and b2b_price. The net cost behind a line (net_cost_usd, supplier_rate_ids) is commercial and
--     never leaves Booking: no column, field or contract key is named supplier_net (ADR 0005a decision 2, Fix B19).
--     No personal data: pax are counts, never people (contract rule).
--   * booking.trip_plan_components: the bookable supply items of a sellable trip plan (a hotel room type or a service
--     on a day of the plan). Ids only, no content (O7). Staff replace the set of a plan (SELECT, INSERT, DELETE).
--   * booking.settings row b2b_quote_valid_hours = 48 (how long a B2B quote stays valid; data, not code).
--
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS everywhere, CHECKs inside CREATE TABLE, the
-- settings row ON CONFLICT DO NOTHING. New tables only: no lock on an existing table.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── Partners ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.b2b_partners (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL,
    agency_name       TEXT NOT NULL,
    status            TEXT NOT NULL DEFAULT 'active',
    billing_currency  CHAR(3) NOT NULL DEFAULT 'USD',
    credit_terms_ref  TEXT,
    m2m_client_id     TEXT NOT NULL,
    created_by        TEXT REFERENCES booking.staff_users (cis_user_id),
    updated_by        TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT b2b_partners_name_chk CHECK (length(btrim(agency_name)) BETWEEN 1 AND 200),
    CONSTRAINT b2b_partners_status_chk CHECK (status IN ('active', 'suspended')),
    CONSTRAINT b2b_partners_currency_chk CHECK (billing_currency ~ '^[A-Z]{3}$'),
    CONSTRAINT b2b_partners_terms_chk CHECK (credit_terms_ref IS NULL OR length(btrim(credit_terms_ref)) BETWEEN 1 AND 120),
    CONSTRAINT b2b_partners_client_chk CHECK (m2m_client_id ~ '^[A-Za-z0-9]{1,128}$')
);

CREATE UNIQUE INDEX IF NOT EXISTS b2b_partners_tenant_uq ON booking.b2b_partners (tenant_id);
CREATE INDEX IF NOT EXISTS b2b_partners_client_idx ON booking.b2b_partners (m2m_client_id);

DROP TRIGGER IF EXISTS b2b_partners_set_updated_at ON booking.b2b_partners;
CREATE TRIGGER b2b_partners_set_updated_at
    BEFORE UPDATE ON booking.b2b_partners
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

COMMENT ON TABLE booking.b2b_partners IS
    'bk-019 (AA-972, ADR 0005a): a partner agency allowed to call booking.b2b.v1. Never deleted (suspend).';
COMMENT ON COLUMN booking.b2b_partners.tenant_id IS
    'bk-019: the agency''s CIS tenant id (soft key, header X-AA-Tenant-Id); no FK across apps.';
COMMENT ON COLUMN booking.b2b_partners.agency_name IS
    'conf:commercial; bk-019: the agency''s trading name as AA staff know it (a business, not a person).';
COMMENT ON COLUMN booking.b2b_partners.credit_terms_ref IS
    'conf:commercial; bk-019: reference of the B2B terms AA bills the agency under (settlement is outside the CRM).';
COMMENT ON COLUMN booking.b2b_partners.m2m_client_id IS
    'bk-019 (ADR 0006b d7): the aa-m2m app client allowed to act for this agency; the token client_id must equal it.';

-- ── Quotes (append-only) ─────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.b2b_quotes (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id               UUID NOT NULL REFERENCES booking.b2b_partners (id),
    m2m_client_id            TEXT NOT NULL,
    proposal_ref             TEXT NOT NULL,
    proposal_version         INTEGER NOT NULL,
    currency                 CHAR(3) NOT NULL,
    fx_rate_per_usd          NUMERIC(18, 8) NOT NULL,
    fx_buffer_pct            NUMERIC(5, 4) NOT NULL DEFAULT 0,
    fx_as_of                 DATE NOT NULL,
    fx_source                TEXT NOT NULL,
    pricing_rule_valid_from  DATE NOT NULL,
    margin_applied           NUMERIC(5, 4) NOT NULL,
    card_fee_pct             NUMERIC(5, 4) NOT NULL,
    rounding                 TEXT NOT NULL,
    priced_on                DATE NOT NULL,
    total_b2b_price          NUMERIC(14, 2) NOT NULL,
    price_hash               CHAR(64) NOT NULL,
    valid_until              TIMESTAMPTZ NOT NULL,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT b2b_quotes_client_chk CHECK (m2m_client_id ~ '^[A-Za-z0-9]{1,128}$'),
    CONSTRAINT b2b_quotes_proposal_chk CHECK (length(proposal_ref) BETWEEN 1 AND 64 AND proposal_version >= 1),
    CONSTRAINT b2b_quotes_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT b2b_quotes_fx_chk CHECK (fx_rate_per_usd > 0 AND fx_buffer_pct >= 0 AND fx_buffer_pct < 1
                                        AND length(fx_source) BETWEEN 1 AND 64),
    CONSTRAINT b2b_quotes_margin_chk CHECK (margin_applied >= 0 AND margin_applied < 1
                                            AND card_fee_pct >= 0 AND card_fee_pct < 1),
    CONSTRAINT b2b_quotes_rounding_chk CHECK (length(rounding) BETWEEN 1 AND 64),
    CONSTRAINT b2b_quotes_total_chk CHECK (total_b2b_price >= 0),
    CONSTRAINT b2b_quotes_hash_chk CHECK (price_hash ~ '^[a-f0-9]{64}$'),
    CONSTRAINT b2b_quotes_valid_chk CHECK (valid_until > created_at)
);

CREATE INDEX IF NOT EXISTS b2b_quotes_partner_idx ON booking.b2b_quotes (partner_id, created_at DESC);
CREATE INDEX IF NOT EXISTS b2b_quotes_proposal_idx ON booking.b2b_quotes (partner_id, proposal_ref, proposal_version);

COMMENT ON TABLE booking.b2b_quotes IS
    'bk-019 (AA-972): one priced B2B quote (POST /booking/b2b/v1/quotes). Append-only for role booking. No personal data.';
COMMENT ON COLUMN booking.b2b_quotes.fx_rate_per_usd IS
    'bk-019: the plain approved rate of the quote currency locked at quote time (1 for USD); the selling rate is x (1 + fx_buffer_pct).';
COMMENT ON COLUMN booking.b2b_quotes.margin_applied IS
    'conf:commercial; bk-019: the b2b channel margin used (pricing_rules, in force on priced_on).';
COMMENT ON COLUMN booking.b2b_quotes.card_fee_pct IS
    'conf:commercial; bk-019: the card fee of the b2b rule used.';
COMMENT ON COLUMN booking.b2b_quotes.price_hash IS
    'bk-019: SHA-256 over lines, prices, FX lock and rounding (app/b2b/quotes.py); holds must present it.';

CREATE TABLE IF NOT EXISTS booking.b2b_quote_lines (
    quote_id           UUID NOT NULL REFERENCES booking.b2b_quotes (id),
    line_no            SMALLINT NOT NULL,
    line_ref           TEXT NOT NULL,
    component_id       TEXT NOT NULL,
    component_kind     TEXT NOT NULL,
    service_date       DATE NOT NULL,
    nights             SMALLINT,
    pax_adult          SMALLINT NOT NULL,
    pax_child          SMALLINT NOT NULL DEFAULT 0,
    pax_infant         SMALLINT NOT NULL DEFAULT 0,
    rooms              JSONB NOT NULL DEFAULT '[]'::jsonb,
    unit               TEXT NOT NULL,
    availability       TEXT NOT NULL,
    b2b_price          NUMERIC(14, 2) NOT NULL,
    net_cost_usd       NUMERIC(16, 4) NOT NULL,
    supplier_rate_ids  UUID[] NOT NULL DEFAULT '{}',
    PRIMARY KEY (quote_id, line_no),
    CONSTRAINT b2b_quote_lines_no_chk CHECK (line_no BETWEEN 1 AND 200),
    CONSTRAINT b2b_quote_lines_ref_chk CHECK (length(line_ref) BETWEEN 1 AND 64),
    CONSTRAINT b2b_quote_lines_component_chk CHECK (length(component_id) BETWEEN 1 AND 64),
    CONSTRAINT b2b_quote_lines_kind_chk CHECK (
        component_kind IN ('trip_plan', 'hotel_room', 'transfer', 'guide', 'activity', 'entrance', 'meal')),
    CONSTRAINT b2b_quote_lines_nights_chk CHECK (nights IS NULL OR nights BETWEEN 1 AND 60),
    CONSTRAINT b2b_quote_lines_pax_chk CHECK (pax_adult BETWEEN 1 AND 60 AND pax_child BETWEEN 0 AND 60
                                              AND pax_infant BETWEEN 0 AND 20),
    CONSTRAINT b2b_quote_lines_rooms_chk CHECK (jsonb_typeof(rooms) = 'array' AND jsonb_array_length(rooms) <= 30),
    CONSTRAINT b2b_quote_lines_unit_chk CHECK (unit IN ('per_person', 'per_group', 'per_room_night', 'per_line')),
    CONSTRAINT b2b_quote_lines_availability_chk CHECK (availability IN ('available', 'on_request', 'sold_out')),
    CONSTRAINT b2b_quote_lines_price_chk CHECK (b2b_price >= 0 AND net_cost_usd >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS b2b_quote_lines_ref_uq ON booking.b2b_quote_lines (quote_id, line_ref);

COMMENT ON TABLE booking.b2b_quote_lines IS
    'bk-019 (AA-972): the lines of a B2B quote. Append-only for role booking. Pax are counts by age band, never people.';
COMMENT ON COLUMN booking.b2b_quote_lines.line_ref IS
    'bk-019: the CRM''s id of the option or booking line (opaque to Booking).';
COMMENT ON COLUMN booking.b2b_quote_lines.b2b_price IS
    'bk-019 (ADR 0005a d2): the agency-facing price of the line (the agency''s "net"); the only price that leaves Booking.';
COMMENT ON COLUMN booking.b2b_quote_lines.net_cost_usd IS
    'conf:commercial; bk-019: supplier net cost behind the line in USD at the plain rate; never leaves Booking (Fix B19).';
COMMENT ON COLUMN booking.b2b_quote_lines.supplier_rate_ids IS
    'conf:commercial; bk-019: the booking.supplier_rates rows the net cost was taken from (provenance).';

-- ── Supply components of a trip plan ─────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.trip_plan_components (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_plan_id        UUID NOT NULL REFERENCES booking.trip_plans (id),
    day_no              SMALLINT NOT NULL,
    hotel_room_type_id  UUID REFERENCES booking.hotel_room_types (id),
    service_id          UUID REFERENCES booking.services (id),
    created_by          TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT trip_plan_components_day_chk CHECK (day_no BETWEEN 1 AND 366),
    CONSTRAINT trip_plan_components_target_chk CHECK (num_nonnulls(hotel_room_type_id, service_id) = 1)
);

CREATE UNIQUE INDEX IF NOT EXISTS trip_plan_components_uq
    ON booking.trip_plan_components (trip_plan_id, day_no, coalesce(hotel_room_type_id, service_id));

COMMENT ON TABLE booking.trip_plan_components IS
    'bk-019 (AA-972): the bookable supply items (a hotel room type or a service) on a day of a sellable trip plan; ids only, no content (O7). Read by GET /booking/b2b/v1/products and quotes.';

-- ── Settings ─────────────────────────────────────────────────────────────────

INSERT INTO booking.settings (key, value, description) VALUES
    ('b2b_quote_valid_hours', '48'::jsonb, 'Validity of a B2B quote (booking.b2b.v1 POST /quotes) in hours (AA-972; policy data).')
ON CONFLICT (key) DO NOTHING;

-- ── Grants (per table) ───────────────────────────────────────────────────────

GRANT SELECT, INSERT, UPDATE ON booking.b2b_partners TO booking;
GRANT SELECT, INSERT ON booking.b2b_quotes TO booking;
GRANT SELECT, INSERT ON booking.b2b_quote_lines TO booking;
GRANT SELECT, INSERT, DELETE ON booking.trip_plan_components TO booking;

-- The schema's default privileges may have granted more on creation: take back what the app must not do.
REVOKE DELETE, TRUNCATE ON booking.b2b_partners FROM booking;
REVOKE UPDATE, DELETE, TRUNCATE ON booking.b2b_quotes FROM booking;
REVOKE UPDATE, DELETE, TRUNCATE ON booking.b2b_quote_lines FROM booking;
REVOKE UPDATE, TRUNCATE ON booking.trip_plan_components FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-019', now(), 'AA-972 (CRM-B1): b2b_partners, b2b_quotes + lines (append-only), trip_plan_components, setting b2b_quote_valid_hours')
ON CONFLICT (version) DO NOTHING;

COMMIT;
