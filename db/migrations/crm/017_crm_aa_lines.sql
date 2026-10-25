-- Migration crm-017: AA-947 (partner CRM, design v3 card CRM-19) — the B2B client and Adventure Asia lines: AA lines
-- that come only from a Booking quote, hold or feed event (never typed by the agency), the outage queue that retries
-- Booking calls without duplicates ("AA pending"), the Booking event feed's cursor and dedupe inbox, and the cache of
-- published AA tour content from CIS (catalog.http.v1).
--
-- Owner: AA-Partner (api/migrations/017_crm_aa_lines.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy DB
-- Migrate applies (Migration Copy Guard). Key crm-017. crm.erase_subject below is the crm-016 text plus this file's
-- tables; a later key that replaces it starts from THIS text. crm.erase_held is unchanged (crm-016): every new tenant
-- row that names a trip carries trip_id, which its trip scope already reaches through crm.hold_trip.
--
-- Why. Design v3 §6.3 card CRM-19 (deps B1-B4, CRM-16; checklist: M2M client, catalog cache, lines from quote / hold /
-- feed only, "from"-price warning, AA-aware Lost reasons, outage queue), §2.7 F6 / F7 and the Lost side flow, §3.4,
-- §3.5 (FX: AA lines take the Booking quote's FX lock; line status), §5.1 / §5.2 (booking.b2b.v1: errors, 503 = an
-- indicative price, no deposit while no active hold). Card R: editing an AA line -> 403 aa_line_read_only (crm-014
-- guard 3a and the money functions; nothing here weakens them). Card E: Booking down -> "AA pending", retried without
-- duplicates (crm.aa_request below).
--
-- What (DM-7 rows: root data standards Part B §7, added with this key: aa_request, booking_feed_state, aa_catalog_tour,
-- aa_catalog_state; inbox_events has its row since v1.3):
--   1. crm.booking_line, AA lines only: aa_tour_source_id (catalog soft key, source_system cis), aa_component_id /
--      aa_component_kind (the Booking component), aa_currency (the quote currency), aa_pax (counts only: adult, child,
--      infant, nights, rooms by occupancy), bk_quote_id, aa_price_hash, aa_quote_version (the hold set version),
--      quote_valid_until, hold_expires_at, from_price + below_from_price (the "from"-price warning, warn only),
--      aa_decline_code (Booking's line.declined code), aa_result_code (the last final Booking answer). aa_sub_status
--      adds pending (a request waits for Booking), quoted, sold_out, released, not_served, failed. Every one of these
--      columns is NULL on an agency line.
--   2. crm.aa_request (base template; the outage queue): one Booking call the CRM owes, kind quote | requote | hold |
--      confirm | release | refresh, status pending -> done | failed | cancelled, attempts, next_attempt_at (backoff),
--      lease_until (a claim lease: two runs never send one request twice), last_error_class / result_code (codes),
--      the quote parameters (counts and ids only, never a person). One live request per (line, kind): partial
--      UNIQUE aa_request_live_uq. crm_app never deletes one (erasure through crm.erase_subject).
--   3. crm.booking_feed_state (base template): the booking.b2b.v1 /events cursor of one agency (UNIQUE tenant_id),
--      failures and the last error class; created with the agency's first AA request, so an agency without AA lines is
--      never polled.
--   4. crm.inbox_events (append-only variant, the design's name; crm.ledger_append_only: DELETE only inside
--      crm.erase_subject): one row per Booking event, unique on (tenant_id, source, contract, idempotency_key = the
--      event id), with its type, outcome and reason code. No payload.
--   5. crm.aa_catalog_tour (platform table, no tenant, no personal data): the cache of published AA tours from CIS
--      (title, country, duration, content_hash, ETag, served_state served | paused | retired, the CIS reason, the
--      served body). Written by the hourly crm_catalog_sync only; crm_app SELECT, INSERT, UPDATE.
--      crm.aa_catalog_state: its one platform row (list cursor, last full pass, failures, last error class).
--   6. crm.aa_line_request(...) (SECURITY DEFINER, EXECUTE crm_app): the only member path to an AA line: a planning
--      line with aa_sub_status pending, its title taken from crm.aa_catalog_tour (never from the caller), the quote
--      request, and the agency's feed row, in one call. A sell amount needs an owner or agent (42501
--      margin_forbidden); a closed trip or a bad parameter is CRM33 aa_request_invalid; a tour that is not served
--      CRM34 aa_tour_not_served.
--   7. crm.booking_line_aa_money(...) (SECURITY DEFINER, EXECUTE crm_app): the money of an AA line, written by the
--      Booking sync job only (a job: actor without a member role; 42501 otherwise): cost = the quote's b2b_price,
--      sell = the agency's sell, frozen at once with fx_source aa_quote_lock / fx_basis quote_lock: one unit of the
--      quote currency = 1 / rate_per_usd USD, crossed to a non-USD base through crm.fx_resolve('USD', base, rate date)
--      (CRM25 when no rate). Nothing is written when the head already holds that amount, currency and rate.
--   8. crm.erase_subject (the crm-016 text) + aa_request (trip, booking_line and agency scopes), inbox_events and
--      booking_feed_state (agency scope); the hold guard on aa_request (trip_id).
--   SQLSTATEs CRM33 and CRM34 are this file's; the next key starts at CRM35.
--
-- Order: after crm-016 (AA-946); Guard 0 refuses to run before it is registered (erase_subject builds on its text).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); before the AA-947
-- code deploys nothing reads these objects, and the code merges only after this file is applied (S249 lesson).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-016 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-017: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-016') THEN
        RAISE EXCEPTION 'crm-017: crm-016 is not registered (CRM-18 thin lifecycle, AA-946, lands first)';
    END IF;
    IF to_regclass('crm.booking_line') IS NULL OR to_regclass('crm.trip_commitment') IS NULL
       OR to_regclass('crm.proposal') IS NULL
       OR to_regprocedure('crm.ensure_aa_supplier()') IS NULL
       OR to_regprocedure('crm.fx_resolve(text,text,date)') IS NULL
       OR to_regprocedure('crm.ledger_append_only()') IS NULL
       OR to_regprocedure('crm.guard_held_change()') IS NULL THEN
        RAISE EXCEPTION 'crm-017: crm.booking_line / crm.ensure_aa_supplier / crm.fx_resolve / crm.ledger_append_only (crm-014), crm.trip_commitment / crm.guard_held_change (crm-010) or crm.proposal (crm-016) missing';
    END IF;
END $$;

-- ── 1. crm.booking_line: the AA columns ──────────────────────────────────────────────────────────
ALTER TABLE crm.booking_line
    ADD COLUMN IF NOT EXISTS aa_tour_source_id TEXT,
    ADD COLUMN IF NOT EXISTS aa_component_id   TEXT,
    ADD COLUMN IF NOT EXISTS aa_component_kind TEXT,
    ADD COLUMN IF NOT EXISTS aa_currency       CHAR(3),
    ADD COLUMN IF NOT EXISTS aa_pax            JSONB,
    ADD COLUMN IF NOT EXISTS bk_quote_id       TEXT,
    ADD COLUMN IF NOT EXISTS aa_price_hash     TEXT,
    ADD COLUMN IF NOT EXISTS aa_quote_version  INTEGER,
    ADD COLUMN IF NOT EXISTS quote_valid_until TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS hold_expires_at   TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS from_price        NUMERIC(14, 2),
    ADD COLUMN IF NOT EXISTS below_from_price  BOOLEAN,
    ADD COLUMN IF NOT EXISTS aa_decline_code   TEXT,
    ADD COLUMN IF NOT EXISTS aa_result_code    TEXT;
ALTER TABLE crm.booking_line DROP CONSTRAINT IF EXISTS booking_line_aa_chk;
ALTER TABLE crm.booking_line ADD CONSTRAINT booking_line_aa_chk CHECK (
    (supplier_kind = 'aa' OR (
        aa_sub_status IS NULL AND bk_hold_id IS NULL AND bk_booking_id IS NULL
        AND num_nonnulls(aa_tour_source_id, aa_component_id, aa_component_kind, aa_currency, aa_pax, bk_quote_id,
                         aa_price_hash, aa_quote_version, quote_valid_until, hold_expires_at, from_price,
                         below_from_price, aa_decline_code, aa_result_code) = 0))
    AND (aa_sub_status IS NULL OR aa_sub_status IN ('pending', 'quoted', 'sold_out', 'held', 'on_request', 'declined',
                                                     'expired', 'released', 'not_served', 'failed'))
);
ALTER TABLE crm.booking_line DROP CONSTRAINT IF EXISTS booking_line_aa_values_chk;
ALTER TABLE crm.booking_line ADD CONSTRAINT booking_line_aa_values_chk CHECK (
    (aa_tour_source_id IS NULL OR (char_length(aa_tour_source_id) BETWEEN 1 AND 128
                                   AND aa_tour_source_id !~ '[[:cntrl:]]'))
    AND coalesce(aa_component_id, 'x') ~ '^[A-Za-z0-9:_.-]{1,64}$'
    AND (aa_component_kind IS NULL OR aa_component_kind IN ('trip_plan', 'hotel_room', 'transfer', 'guide', 'activity',
                                                            'entrance', 'meal'))
    AND coalesce(aa_currency, 'USD') ~ '^[A-Z]{3}$'
    AND (aa_pax IS NULL OR jsonb_typeof(aa_pax) = 'object')
    AND coalesce(bk_quote_id, 'x') ~ '^[A-Za-z0-9:_.-]{1,64}$'
    AND coalesce(aa_price_hash, repeat('0', 64)) ~ '^[a-f0-9]{64}$'
    AND (aa_quote_version IS NULL OR aa_quote_version >= 1)
    AND (from_price IS NULL OR from_price >= 0)
    AND (aa_decline_code IS NULL OR aa_decline_code IN ('sold_out', 'supplier_unavailable', 'minimum_not_met', 'other'))
    AND coalesce(aa_result_code, 'x') ~ '^[a-z][a-z_]{0,39}$'
);
CREATE INDEX IF NOT EXISTS booking_line_hold_idx ON crm.booking_line (tenant_id, bk_hold_id) WHERE bk_hold_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS booking_line_booking_idx ON crm.booking_line (tenant_id, bk_booking_id)
    WHERE bk_booking_id IS NOT NULL;
COMMENT ON COLUMN crm.booking_line.aa_sub_status IS 'AA-944 / AA-947 (crm-017): AA lines only, from the Booking calls and feed (CRM-19): pending (a request waits for Booking: "AA pending"), quoted, sold_out, held, on_request, declined, expired, released, not_served (the tour left the AA catalog), failed (Booking refused the request; aa_result_code says why)';
COMMENT ON COLUMN crm.booking_line.aa_tour_source_id IS 'AA-947 (crm-017): the AA tour of an AA line, catalog soft key (source_system cis, source_id); joins crm.aa_catalog_tour for the served state ("no longer offered")';
COMMENT ON COLUMN crm.booking_line.aa_pax IS 'AA-947 (crm-017): the counts the AA line was quoted for: adult, child, infant, nights, rooms [{occupancy, count}]. Counts only, never a person';
COMMENT ON COLUMN crm.booking_line.aa_price_hash IS 'AA-947 (crm-017): the Booking quote''s price_hash, presented by the hold and the confirm';
COMMENT ON COLUMN crm.booking_line.aa_quote_version IS 'AA-947 (crm-017): the line''s quote count, sent as proposal_version with proposal_ref crm-line:<line id> until CRM-21b ties holds to a proposal version';
COMMENT ON COLUMN crm.booking_line.below_from_price IS 'AA-947 (crm-017): the agency''s sell per person (adults + children) is below AA''s public "from" price (from_price, quote currency, GET /price-parity): a warning, never a block (ADR 0005a decision 1). NULL = not known';
COMMENT ON COLUMN crm.booking_line.aa_result_code IS 'AA-947 (crm-017): the last final Booking answer for this line (sold_out, price_changed, hold_expired, rehold_limit, tour_not_served, unknown_partner, invalid, ...); a code, never a message';

-- ── 2. crm.aa_request: the outage queue ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.aa_request (
    aa_request_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    trip_id          UUID NOT NULL,
    booking_line_id  UUID NOT NULL,
    kind             TEXT NOT NULL,
    status           TEXT NOT NULL DEFAULT 'pending',
    tour_source_id   TEXT,
    component_id     TEXT,
    component_kind   TEXT,
    departure_id     TEXT,
    service_date     DATE,
    nights           SMALLINT,
    pax_adult        SMALLINT,
    pax_child        SMALLINT,
    pax_infant       SMALLINT,
    rooms            JSONB,
    currency         CHAR(3),
    sell_amount      NUMERIC(14, 2),
    attempts         INTEGER NOT NULL DEFAULT 0,
    next_attempt_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    lease_until      TIMESTAMPTZ,
    last_error_class TEXT,
    result_code      TEXT,
    finished_at      TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT aa_request_tenant_id_uq UNIQUE (tenant_id, aa_request_id),
    CONSTRAINT aa_request_trip_fk FOREIGN KEY (tenant_id, trip_id) REFERENCES crm.trip (tenant_id, trip_id),
    CONSTRAINT aa_request_line_fk FOREIGN KEY (tenant_id, booking_line_id)
        REFERENCES crm.booking_line (tenant_id, booking_line_id),
    CONSTRAINT aa_request_kind_chk CHECK (kind IN ('quote', 'requote', 'hold', 'confirm', 'release', 'refresh')),
    CONSTRAINT aa_request_status_chk CHECK (status IN ('pending', 'done', 'failed', 'cancelled')),
    -- A quote names everything Booking prices; every other kind acts on the line's current quote / hold / booking
    -- (a re-quote may carry a new sell amount).
    CONSTRAINT aa_request_params_chk CHECK (
        (kind = 'quote' AND num_nulls(tour_source_id, component_id, component_kind, service_date, pax_adult, pax_child,
                                      pax_infant, currency) = 0)
        OR (kind <> 'quote' AND num_nonnulls(tour_source_id, component_id, component_kind, departure_id, service_date,
                                             nights, pax_adult, pax_child, pax_infant, rooms, currency) = 0
            AND (kind = 'requote' OR sell_amount IS NULL))
    ),
    CONSTRAINT aa_request_values_chk CHECK (
        (tour_source_id IS NULL OR (char_length(tour_source_id) BETWEEN 1 AND 128 AND tour_source_id !~ '[[:cntrl:]]'))
        AND coalesce(component_id, 'x') ~ '^[A-Za-z0-9:_.-]{1,64}$'
        AND (component_kind IS NULL OR component_kind IN ('trip_plan', 'hotel_room', 'transfer', 'guide', 'activity',
                                                          'entrance', 'meal'))
        AND coalesce(departure_id, 'x') ~ '^[A-Za-z0-9:_.-]{1,64}$'
        AND (nights IS NULL OR nights BETWEEN 1 AND 60)
        AND (pax_adult IS NULL OR pax_adult BETWEEN 1 AND 60)
        AND (pax_child IS NULL OR pax_child BETWEEN 0 AND 60)
        AND (pax_infant IS NULL OR pax_infant BETWEEN 0 AND 20)
        AND (rooms IS NULL OR (jsonb_typeof(rooms) = 'array' AND jsonb_array_length(rooms) BETWEEN 1 AND 30))
        AND coalesce(currency, 'USD') ~ '^[A-Z]{3}$'
        AND (sell_amount IS NULL OR sell_amount >= 0)
        AND attempts >= 0
        AND coalesce(last_error_class, 'x') ~ '^[a-z][a-z0-9_]{0,59}$'
        AND coalesce(result_code, 'x') ~ '^[a-z][a-z_]{0,39}$'
    ),
    CONSTRAINT aa_request_finished_chk CHECK ((status = 'pending') = (finished_at IS NULL)),
    CONSTRAINT aa_request_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS aa_request_live_uq ON crm.aa_request (tenant_id, booking_line_id, kind)
    WHERE status = 'pending' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS aa_request_due_idx ON crm.aa_request (tenant_id, next_attempt_at) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS aa_request_trip_idx ON crm.aa_request (tenant_id, trip_id);
CREATE INDEX IF NOT EXISTS aa_request_line_idx ON crm.aa_request (tenant_id, booking_line_id);
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('aa_request', 'pending', 'done'),
    ('aa_request', 'pending', 'failed'),
    ('aa_request', 'pending', 'cancelled')
ON CONFLICT DO NOTHING;
REVOKE DELETE, TRUNCATE ON crm.aa_request FROM crm_app;
COMMENT ON TABLE crm.aa_request IS 'AA-947 (crm-017; design v3 CRM-19 "outage queue", card E): one Booking call the CRM owes for an AA line (quote, requote, hold, confirm, release, refresh). Status pending -> done | failed | cancelled; while pending the line reads "AA pending". The Booking sync job (crm_booking_sync) claims due rows with a lease, sends them with a stable Idempotency-Key (crm-<kind>:<request id>), and on a transient failure keeps them pending with a backoff (next_attempt_at). One live request per (line, kind) (aa_request_live_uq). Counts and ids only; no PII. crm_app never deletes one; erasure through crm.erase_subject.';
COMMENT ON COLUMN crm.aa_request.lease_until IS 'AA-947: set when a run claims the request (FOR UPDATE SKIP LOCKED); another run skips it until the lease ends, so a request is never sent twice at once';
COMMENT ON COLUMN crm.aa_request.last_error_class IS 'AA-947: the last transient failure (booking_unavailable, booking_timeout, booking_unauthorized, ...), a code only';
COMMENT ON COLUMN crm.aa_request.result_code IS 'AA-947: how a finished request ended (quoted, held, confirmed, on_request, released, sold_out, price_changed, rehold_limit, tour_not_served, unknown_partner, invalid, gave_up, ...), a code only';

-- ── 3. crm.booking_feed_state: one Booking /events cursor per agency ─────────────────────────────
CREATE TABLE IF NOT EXISTS crm.booking_feed_state (
    booking_feed_state_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                          REFERENCES crm.tenant (tenant_id),
    feed_cursor           TEXT,
    failures              INTEGER NOT NULL DEFAULT 0,
    last_error_class      TEXT,
    last_error_at         TIMESTAMPTZ,
    last_ok_at            TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at            TIMESTAMPTZ,
    deleted_by            TEXT,
    purge_after           TIMESTAMPTZ,
    CONSTRAINT booking_feed_state_tenant_uq UNIQUE (tenant_id),
    CONSTRAINT booking_feed_state_values_chk CHECK (
        (feed_cursor IS NULL OR char_length(feed_cursor) BETWEEN 1 AND 200)
        AND failures >= 0
        AND coalesce(last_error_class, 'x') ~ '^[a-z][a-z0-9_]{0,59}$'
    ),
    CONSTRAINT booking_feed_state_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
REVOKE DELETE, TRUNCATE ON crm.booking_feed_state FROM crm_app;
COMMENT ON TABLE crm.booking_feed_state IS 'AA-947 (crm-017; design v3 §5.2 "GET /events?after= pulled every minute"): the booking.b2b.v1 event cursor of one agency (Booking''s feed is per calling agency), its consecutive failures and last error class (codes). Created with the agency''s first AA request; agencies without AA lines are never polled. No PII. Erased with the agency.';

-- ── 4. crm.inbox_events: one row per Booking event (append-only) ────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.inbox_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                    REFERENCES crm.tenant (tenant_id),
    source          TEXT NOT NULL,
    contract        TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    event_type      TEXT,
    outcome         TEXT NOT NULL,
    reason_code     TEXT NOT NULL,
    received_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    CONSTRAINT inbox_events_key_uq UNIQUE (tenant_id, source, contract, idempotency_key),
    CONSTRAINT inbox_events_values_chk CHECK (
        source IN ('booking') AND contract IN ('booking.b2b.v1')
        AND idempotency_key ~ '^[A-Za-z0-9:_.-]{1,64}$'
        AND coalesce(event_type, 'x') ~ '^[a-z][a-z_.]{0,39}$'
        AND outcome IN ('applied', 'ignored', 'rejected')
        AND reason_code ~ '^[a-z][a-z_]{0,39}$'
    )
);
REVOKE UPDATE, DELETE, TRUNCATE ON crm.inbox_events FROM crm_app;
COMMENT ON TABLE crm.inbox_events IS 'AA-947 (crm-017; design v3 group J): one row per consumed event of another app''s feed, today booking.b2b.v1 /events (source booking): unique on (tenant_id, source, contract, idempotency_key = the event id), so a replayed page applies nothing twice; the event type, the outcome (applied | ignored | rejected) and a reason code. No payload, no PII. Append-only (crm.ledger_append_only): DELETE only inside crm.erase_subject (agency scope).';

-- ── 5. The catalog cache (platform tables) ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.aa_catalog_tour (
    source_system    TEXT NOT NULL DEFAULT 'cis',
    source_id        TEXT NOT NULL,
    title            TEXT NOT NULL,
    country_code     CHAR(2),
    duration_days    INTEGER,
    content_hash     TEXT,
    etag             TEXT,
    served_state     TEXT NOT NULL DEFAULT 'served',
    reason           TEXT,
    body             JSONB,
    fetched_at       TIMESTAMPTZ,
    checked_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    state_changed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (source_system, source_id),
    CONSTRAINT aa_catalog_tour_values_chk CHECK (
        source_system = 'cis'
        AND char_length(source_id) BETWEEN 1 AND 128 AND source_id !~ '[[:cntrl:]]'
        AND char_length(title) BETWEEN 1 AND 300
        AND coalesce(country_code, 'VN') ~ '^[A-Z]{2}$'
        AND (duration_days IS NULL OR duration_days BETWEEN 1 AND 366)
        AND (content_hash IS NULL OR char_length(content_hash) <= 100)
        AND (etag IS NULL OR char_length(etag) <= 100)
        AND served_state IN ('served', 'paused', 'retired')
        AND coalesce(reason, 'x') ~ '^[a-z][a-z_]{0,63}$'
        AND (body IS NULL OR jsonb_typeof(body) = 'object')
    )
);
CREATE INDEX IF NOT EXISTS aa_catalog_tour_served_idx ON crm.aa_catalog_tour (served_state, country_code, title);
REVOKE DELETE, TRUNCATE ON crm.aa_catalog_tour FROM crm_app;
COMMENT ON TABLE crm.aa_catalog_tour IS 'AA-947 (crm-017; design v3 CRM-19 "catalog cache", root ADR 0010 decision 4): published AA tour content from CIS catalog.http.v1 (AA-976), no tenant column, no personal data: title, country, duration, the served body, content_hash and ETag. served_state served | paused (CIS 404 with a reason: hidden, lines not marked) | retired (CIS 410: AA lines of it read "no longer offered"). Written only by the hourly crm_catalog_sync (app/catalog/store.py); crm_app SELECT, INSERT, UPDATE. Kept while the CRM runs (a retired tour stays: lines still name it).';

CREATE TABLE IF NOT EXISTS crm.aa_catalog_state (
    singleton         BOOLEAN PRIMARY KEY DEFAULT true,
    list_cursor       TEXT,
    pass_started_at   TIMESTAMPTZ,
    last_full_pass_at TIMESTAMPTZ,
    failures          INTEGER NOT NULL DEFAULT 0,
    last_error_class  TEXT,
    last_error_at     TIMESTAMPTZ,
    last_ok_at        TIMESTAMPTZ,
    CONSTRAINT aa_catalog_state_one_chk CHECK (singleton),
    CONSTRAINT aa_catalog_state_values_chk CHECK (
        (list_cursor IS NULL OR char_length(list_cursor) BETWEEN 1 AND 200)
        AND failures >= 0
        AND coalesce(last_error_class, 'x') ~ '^[a-z][a-z0-9_]{0,59}$'
    )
);
INSERT INTO crm.aa_catalog_state (singleton) VALUES (true) ON CONFLICT DO NOTHING;
REVOKE INSERT, DELETE, TRUNCATE ON crm.aa_catalog_state FROM crm_app;
COMMENT ON TABLE crm.aa_catalog_state IS 'AA-947 (crm-017): the one platform row of the catalog sync (crm_catalog_sync): the list cursor and start time of an unfinished pass, the last full pass, failures and the last error class. No tenant column, no PII. crm_app SELECT, UPDATE.';

-- ── RLS, triggers and the hold guard on the new tenant tables ────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['aa_request', 'booking_feed_state', 'inbox_events'] LOOP
        EXECUTE format('ALTER TABLE crm.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE crm.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON crm.%I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON crm.%I '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)', t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['aa_request', 'booking_feed_state'] LOOP
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON crm.%I FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at()',
            t || '_set_updated_at', t);
    END LOOP;
    EXECUTE 'CREATE OR REPLACE TRIGGER aa_request_status_transition BEFORE UPDATE OF status ON crm.aa_request '
            'FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition()';
    -- Append-only (the ledger rule of crm-014: DELETE only inside crm.erase_subject).
    EXECUTE 'CREATE OR REPLACE TRIGGER inbox_events_append_only BEFORE UPDATE OR DELETE ON crm.inbox_events '
            'FOR EACH ROW EXECUTE FUNCTION crm.ledger_append_only()';
    EXECUTE 'CREATE OR REPLACE TRIGGER inbox_events_no_truncate BEFORE TRUNCATE ON crm.inbox_events '
            'FOR EACH STATEMENT EXECUTE FUNCTION crm.ledger_append_only()';
    -- Hold rule 4h: a held trip's requests are neither deleted, trashed nor moved to another trip.
    EXECUTE 'DROP TRIGGER IF EXISTS aa_request_hold_guard ON crm.aa_request';
    EXECUTE 'CREATE TRIGGER aa_request_hold_guard BEFORE DELETE OR UPDATE ON crm.aa_request FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_held_change(''trip_id'')';
END $$;
COMMENT ON FUNCTION crm.ledger_append_only() IS 'AA-944 (crm-014): crm.booking_line_money and crm.fx_rate_override (AA-946 crm-016: crm.payment; AA-947 crm-017: crm.inbox_events) are append-only; DELETE only as crm_owner inside crm.erase_subject (app.erasing), the crm.erasable_append_only() rule (crm-010) for these tables.';

-- ── 6. crm.aa_line_request: the member path to an AA line ────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.aa_line_request(p_trip uuid, p_source_id text, p_component_id text,
                                               p_component_kind text, p_departure_id text, p_service_date date,
                                               p_nights integer, p_adult integer, p_child integer, p_infant integer,
                                               p_rooms jsonb, p_currency text, p_sell numeric) RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_role text := COALESCE(current_setting('app.member_role', true), '');
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_stage text;
    v_tour record;
    v_supplier uuid;
    v_line uuid;
    v_to date;
    v_title text;
BEGIN
    IF NOT (v_role IN ('owner', 'agent', 'assistant') OR (v_role = '' AND v_actor ~ '^(job|seed):')) THEN
        RAISE EXCEPTION 'crm: aa_request_invalid:actor (a member of the agency asks for AA lines)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_sell IS NOT NULL AND NOT (v_role IN ('owner', 'agent') OR v_role = '') THEN
        RAISE EXCEPTION 'crm: margin_forbidden (only an owner or an agent sets a sell amount)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT t.stage INTO v_stage FROM crm.trip t WHERE t.trip_id = p_trip AND t.deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (trip %)', p_trip USING ERRCODE = 'CRM13';
    END IF;
    IF v_stage IN ('lost', 'cancelled', 'completed') THEN
        RAISE EXCEPTION 'crm: aa_request_invalid:trip_closed (a % trip takes no AA line)', v_stage
            USING ERRCODE = 'CRM33';
    END IF;
    IF p_component_kind = 'hotel_room' AND p_nights IS NULL THEN
        RAISE EXCEPTION 'crm: aa_request_invalid:nights (a hotel room needs its nights)' USING ERRCODE = 'CRM33';
    END IF;
    SELECT c.title, c.duration_days, c.served_state INTO v_tour
      FROM crm.aa_catalog_tour c WHERE c.source_system = 'cis' AND c.source_id = p_source_id;
    IF NOT FOUND OR v_tour.served_state <> 'served' THEN
        RAISE EXCEPTION 'crm: aa_tour_not_served (% is not in the AA catalog)', left(p_source_id, 128)
            USING ERRCODE = 'CRM34';
    END IF;
    v_to := CASE p_component_kind
                WHEN 'trip_plan' THEN p_service_date + GREATEST(COALESCE(v_tour.duration_days, 1), 1) - 1
                WHEN 'hotel_room' THEN p_service_date + p_nights
                ELSE p_service_date END;
    v_title := left(v_tour.title, 170) || CASE WHEN p_component_kind = 'trip_plan' THEN ''
                                               ELSE ' · ' || replace(p_component_kind, '_', ' ') END;
    v_supplier := crm.ensure_aa_supplier();
    BEGIN
        INSERT INTO crm.booking_line (trip_id, supplier_kind, agency_supplier_id, departure_id, status, aa_sub_status,
                                      title, service_from, service_to, aa_tour_source_id, aa_component_id,
                                      aa_component_kind, aa_currency, aa_pax)
        VALUES (p_trip, 'aa', v_supplier, p_departure_id, 'planning', 'pending', v_title, p_service_date, v_to,
                p_source_id, p_component_id, p_component_kind, p_currency,
                jsonb_strip_nulls(jsonb_build_object('adult', p_adult, 'child', p_child, 'infant', p_infant,
                                                     'nights', p_nights, 'rooms', p_rooms)))
        RETURNING booking_line_id INTO v_line;
        INSERT INTO crm.aa_request (trip_id, booking_line_id, kind, tour_source_id, component_id, component_kind,
                                    departure_id, service_date, nights, pax_adult, pax_child, pax_infant, rooms,
                                    currency, sell_amount)
        VALUES (p_trip, v_line, 'quote', p_source_id, p_component_id, p_component_kind, p_departure_id,
                p_service_date, p_nights, p_adult, p_child, p_infant, p_rooms, p_currency, round(p_sell, 2));
    EXCEPTION WHEN check_violation THEN
        RAISE EXCEPTION 'crm: aa_request_invalid:params (%)', SQLERRM USING ERRCODE = 'CRM33';
    END;
    INSERT INTO crm.booking_feed_state (tenant_id) VALUES (NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    ON CONFLICT (tenant_id) DO NOTHING;
    RETURN v_line;
END;
$$;
REVOKE ALL ON FUNCTION crm.aa_line_request(uuid, text, text, text, text, date, integer, integer, integer, integer,
                                           jsonb, text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.aa_line_request(uuid, text, text, text, text, date, integer, integer, integer, integer,
                                              jsonb, text, numeric) TO crm_app;
COMMENT ON FUNCTION crm.aa_line_request(uuid, text, text, text, text, date, integer, integer, integer, integer, jsonb, text, numeric) IS 'AA-947 (crm-017, CRM-19 "lines from quote / hold / feed only"): the one member path to an AA line in the agency of app.tenant_id: a planning AA line with aa_sub_status pending ("AA pending"), its title from crm.aa_catalog_tour (never from the caller), its dates from the component (a trip plan: the tour''s days; a hotel room: the nights), the quote request in crm.aa_request and the agency''s crm.booking_feed_state row. Any member (a sell amount: owner / agent only, 42501 margin_forbidden); a trashed or unknown trip CRM13; a lost, cancelled or completed trip or a bad parameter CRM33 aa_request_invalid; a tour that is not served CRM34 aa_tour_not_served. SECURITY DEFINER (crm_owner, so crm-014 guard 3a lets the pending line in); EXECUTE crm_app.';

-- ── 7. crm.booking_line_aa_money: the money of an AA line (the Booking sync job only) ───────────
CREATE OR REPLACE FUNCTION crm.booking_line_aa_money(p_line uuid, p_kind text, p_amount numeric, p_currency text,
                                                     p_rate_per_usd numeric, p_rate_date date) RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_role text := COALESCE(current_setting('app.member_role', true), '');
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_kind text;
    v_base text;
    v_rate numeric;
    v_stale integer := 0;
    v_fx record;
    v_head record;
    v_amount numeric := round(p_amount, 2);
    v_id uuid;
BEGIN
    IF NOT (v_role = '' AND v_actor ~ '^job:') THEN
        RAISE EXCEPTION 'crm: margin_forbidden (AA line money comes from the Booking sync job only)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('cost', 'sell') OR p_amount IS NULL OR p_amount < 0
       OR p_currency IS NULL OR p_currency !~ '^[A-Z]{3}$' OR p_rate_per_usd IS NULL OR p_rate_per_usd <= 0
       OR p_rate_date IS NULL THEN
        RAISE EXCEPTION 'crm: money_invalid (cost or sell, amount >= 0, an ISO currency, a rate > 0 and its date)'
            USING ERRCODE = 'check_violation';
    END IF;
    SELECT l.supplier_kind INTO v_kind FROM crm.booking_line l WHERE l.booking_line_id = p_line FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (booking_line %)', p_line USING ERRCODE = 'CRM13';
    END IF;
    IF v_kind <> 'aa' THEN
        RAISE EXCEPTION 'crm: line_not_editable (an agency line''s money goes through crm.booking_line_money_put)'
            USING ERRCODE = 'CRM26';
    END IF;
    v_base := COALESCE((SELECT ts.base_currency FROM crm.tenant_settings ts), 'USD');
    IF p_currency = v_base THEN
        v_rate := 1;
    ELSIF v_base = 'USD' THEN
        v_rate := round(1 / p_rate_per_usd, 10);
    ELSE
        -- The quote's lock into USD, then USD into the base currency at crm.fx_resolve's rate of that day.
        SELECT r.rate, r.stale_days INTO v_fx FROM crm.fx_resolve('USD', v_base, p_rate_date) r;
        IF v_fx.rate IS NULL THEN
            RAISE EXCEPTION 'crm: fx_rate_missing:% (no rate USD -> % within 30 days of %)', v_base, v_base,
                p_rate_date USING ERRCODE = 'CRM25';
        END IF;
        v_rate := round(v_fx.rate / p_rate_per_usd, 10);
        v_stale := LEAST(v_fx.stale_days, 366);
    END IF;
    IF v_rate <= 0 THEN
        RAISE EXCEPTION 'crm: fx_rate_missing:% (the rate rounds to 0)', p_currency USING ERRCODE = 'CRM25';
    END IF;
    SELECT m.* INTO v_head
      FROM crm.booking_line_money m
     WHERE m.booking_line_id = p_line AND m.kind = p_kind
       AND NOT EXISTS (SELECT 1 FROM crm.booking_line_money n WHERE n.supersedes_id = m.booking_line_money_id);
    IF v_head.booking_line_money_id IS NOT NULL AND v_head.amount = v_amount AND v_head.currency = p_currency
       AND v_head.fx_rate = v_rate AND v_head.base_currency = v_base THEN
        RETURN v_head.booking_line_money_id;  -- the same quote again: nothing changes
    END IF;
    INSERT INTO crm.booking_line_money (booking_line_id, kind, amount, currency, base_currency, amount_base, fx_rate,
                                        fx_rate_date, fx_source, fx_basis, stale_days, supersedes_id)
    VALUES (p_line, p_kind, v_amount, p_currency, v_base, round(v_amount * v_rate, 2), v_rate, p_rate_date,
            'aa_quote_lock', 'quote_lock', v_stale, v_head.booking_line_money_id)
    RETURNING booking_line_money_id INTO v_id;
    RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION crm.booking_line_aa_money(uuid, text, numeric, text, numeric, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.booking_line_aa_money(uuid, text, numeric, text, numeric, date) TO crm_app;
COMMENT ON FUNCTION crm.booking_line_aa_money(uuid, text, numeric, text, numeric, date) IS 'AA-947 (crm-017, design §3.5 "AA lines take the Booking quote''s FX lock"): writes the cost (the quote''s b2b_price) or the sell (the agency''s) of an AA line of the agency of app.tenant_id as a new head row, frozen at once: fx_source aa_quote_lock, fx_basis quote_lock, rate = 1 / rate_per_usd into USD, crossed to a non-USD base currency through crm.fx_resolve(''USD'', base, rate date) (CRM25 when none). Nothing when the head already has the amount, currency, base and rate. Only a job: actor without a member role (the Booking sync; 42501 margin_forbidden otherwise); an agency line CRM26. SECURITY DEFINER; EXECUTE crm_app.';

-- ── 8. crm.erase_subject: the crm-016 text plus the AA tables ───────────────────────────────────
-- A later key that replaces it starts from THIS text.
CREATE OR REPLACE FUNCTION crm.erase_subject(p_scope text, p_subject uuid, p_profile_token uuid DEFAULT NULL,
                                             p_dry_run boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_counts jsonb := '{}'::jsonb;
    v_blockers text[];
    v_status text;
    v_has_token boolean;
    v_step text[];
    v_left text[] := '{}';
    r record;
    -- Tables an agency erase keeps: the agency row (status offboarded), the destroyed key rows, the audit and its
    -- export registry and chain (crm-007: they leave with the partition drops / the archive), the erasure receipts,
    -- the lifecycle counts and the holds (ids and codes only).
    c_keep CONSTANT text[] := ARRAY['tenant', 'tenant_key', 'audit_event', 'audit_export_tenant',
                                    'audit_export_manifest', 'erasure_request', 'lifecycle_run', 'legal_hold'];
BEGIN
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'crm: erase_subject needs app.tenant_id' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_dry_run IS NULL OR p_subject IS NULL THEN
        RAISE EXCEPTION 'crm: erase_subject needs a subject and dry_run true or false'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_scope NOT IN ('trip', 'traveler', 'task', 'note', 'document', 'relation', 'booking_line', 'agency_supplier',
                       'conversation', 'tenant') THEN
        RAISE EXCEPTION 'crm: erase_subject scope % is unknown', p_scope USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Hold rule 4g: serialise with hold placement. SHARE conflicts with the ROW EXCLUSIVE of an INSERT / UPDATE on
    -- crm.legal_hold: a hold placed now waits until this transaction ends; a hold being placed makes this wait, then
    -- the check below (a new snapshot: this function is VOLATILE) sees it.
    LOCK TABLE crm.legal_hold IN SHARE MODE;

    -- The subject must exist in this agency (FORCE RLS: crm_owner sees app.tenant_id's rows only).
    IF p_scope = 'trip' THEN
        -- FOR UPDATE: a row that would reference the subject (FOR KEY SHARE of its foreign key) waits until this erase
        -- ends, so nothing is attached to it between the hold check and the deletes (the hold guard triggers catch
        -- any other change).
        PERFORM 1 FROM crm.trip WHERE trip_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'traveler' THEN
        SELECT profile_token_enc IS NOT NULL INTO v_has_token FROM crm.traveler WHERE traveler_id = p_subject
           FOR UPDATE;
    ELSIF p_scope = 'task' THEN
        PERFORM 1 FROM crm.task WHERE task_id = p_subject;
    ELSIF p_scope = 'note' THEN
        PERFORM 1 FROM crm.note WHERE note_id = p_subject;
    ELSIF p_scope = 'document' THEN
        PERFORM 1 FROM crm.document WHERE document_id = p_subject;
    ELSIF p_scope = 'relation' THEN
        PERFORM 1 FROM crm.traveler_relation WHERE relation_id = p_subject;
    ELSIF p_scope = 'booking_line' THEN
        PERFORM 1 FROM crm.booking_line WHERE booking_line_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'agency_supplier' THEN
        SELECT kind INTO v_status FROM crm.agency_supplier WHERE agency_supplier_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'conversation' THEN
        PERFORM 1 FROM crm.conversation WHERE conversation_id = p_subject FOR UPDATE;
    ELSE
        IF p_subject <> v_tenant THEN
            RAISE EXCEPTION 'crm: subject_not_found (a tenant erase names the agency of app.tenant_id)'
                USING ERRCODE = 'CRM13';
        END IF;
        SELECT status INTO v_status FROM crm.tenant WHERE tenant_id = v_tenant;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (% %)', p_scope, p_subject USING ERRCODE = 'CRM13';
    END IF;

    -- Hold rule 4e: any held row among those this erase would delete or update refuses it, dry run included.
    IF crm.erase_held(p_scope, p_subject, p_profile_token) THEN
        RAISE EXCEPTION 'crm: legal_hold (an active legal hold reaches a row the erase of % % would change)',
            p_scope, p_subject USING ERRCODE = 'CRM10';
    END IF;

    IF p_scope = 'trip' THEN
        v_blockers := crm.trip_delete_blockers(p_subject);
        IF cardinality(v_blockers) > 0 THEN
            RAISE EXCEPTION 'crm: delete_blocked %', array_to_string(v_blockers, ',') USING ERRCODE = 'CRM11';
        END IF;
    ELSIF p_scope = 'traveler' THEN
        IF EXISTS (SELECT 1 FROM crm.trip_traveler tt JOIN crm.trip t ON t.trip_id = tt.trip_id
                    WHERE tt.traveler_id = p_subject AND t.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'crm: traveler_on_trip (delete or erase the client''s live trips first)'
                USING ERRCODE = 'CRM12';
        END IF;
        IF v_has_token AND p_profile_token IS NULL THEN
            RAISE EXCEPTION 'crm: profile_token_required' USING ERRCODE = 'CRM15';
        END IF;
        -- Consistency guard (the database cannot open the encrypted pointer; the caller decrypted it from this row,
        -- bound by its AAD): every party row of the token is the F2 twin of one of the traveller's own party rows
        -- (same trip, same role).
        IF p_profile_token IS NOT NULL AND EXISTS (
            SELECT 1 FROM crm.trip_party p
             WHERE p.traveler_token = p_profile_token
               AND NOT EXISTS (SELECT 1 FROM crm.trip_traveler tt
                                WHERE tt.trip_id = p.trip_id AND tt.traveler_id = p_subject AND tt.role = p.role)) THEN
            RAISE EXCEPTION 'crm: profile_token_mismatch' USING ERRCODE = 'CRM15';
        END IF;
    ELSIF p_scope = 'agency_supplier' THEN
        -- crm-014: the built-in Adventure Asia row leaves only with the agency; a supplier lines still name stays.
        IF v_status = 'aa' THEN
            RAISE EXCEPTION 'crm: aa_supplier_builtin (the Adventure Asia row leaves with the agency only)'
                USING ERRCODE = 'CRM22';
        END IF;
        IF EXISTS (SELECT 1 FROM crm.booking_line l WHERE l.agency_supplier_id = p_subject) THEN
            RAISE EXCEPTION 'crm: supplier_in_use (booking lines name this supplier)' USING ERRCODE = 'CRM27';
        END IF;
    ELSIF p_scope = 'tenant' AND NOT p_dry_run AND v_status <> 'offboarding' THEN
        -- A dry run (the counts the owner sees before confirming) works on an active agency.
        RAISE EXCEPTION 'crm: tenant_not_offboarding (status %)', v_status USING ERRCODE = 'CRM14';
    END IF;

    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', 'on', true);
    END IF;

    IF p_scope = 'trip' THEN
        -- crm-012: the trip's submissions let go of the trip and of its links first, then the links and slots go.
        -- crm-014: the trip's line money, then its lines. crm-015: the messages of its conversations, then those.
        -- crm-016: signatures, codes, portal access, payments, schedule rows and proposals before the links.
        -- crm-017: the trip's AA requests (the outage queue) before its lines.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['signature_request', 'trip_id = $1', ''],
            ['otp_challenge', 'trip_id = $1', ''],
            ['traveler_access', 'trip_id = $1', ''],
            ['payment', 'trip_id = $1', ''],
            ['payment_schedule', 'trip_id = $1', ''],
            ['proposal', 'trip_id = $1', ''],
            ['form_submission', 'trip_id = $1', 'trip_id = NULL, client_link_id = NULL'],
            ['client_link', 'trip_id = $1', ''],
            ['meeting_slot', 'trip_id = $1', ''],
            ['dispatch_queue', 'trip_id = $1', ''],
            ['message', 'conversation_id IN (SELECT c.conversation_id FROM crm.conversation c WHERE c.trip_id = $1)', ''],
            ['conversation', 'trip_id = $1', ''],
            ['trip_commitment', 'trip_id = $1', ''],
            ['aa_request', 'trip_id = $1', ''],
            ['booking_line_money', 'booking_line_id IN (SELECT l.booking_line_id FROM crm.booking_line l '
                                   'WHERE l.trip_id = $1)', ''],
            ['booking_line', 'trip_id = $1', ''],
            ['document', 'trip_id = $1', ''],
            ['note', 'trip_id = $1', ''],
            ['task', 'trip_id = $1', ''],
            ['trip_stage_history', 'trip_id = $1', ''],
            ['trip_party', 'trip_id = $1', ''],
            ['trip_traveler', 'trip_id = $1', ''],
            ['trip', 'trip_id = $1', '']
        ] LOOP
            v_counts := v_counts || jsonb_build_object(
                v_step[1] || CASE WHEN v_step[3] <> '' THEN '_unlinked' ELSE '' END,
                crm.erase_rows(v_step[1], v_step[2], p_subject, NULL, p_dry_run, NULLIF(v_step[3], '')));
        END LOOP;
    ELSIF p_scope = 'traveler' THEN
        -- crm-012: their call slots (also those their submissions booked) before the submissions, their links after.
        -- crm-015: the messages of their conversations, then those. crm-016: the name they typed to accept a proposal
        -- (the proposal's link names them; before their links go), their signatures, codes and portal access.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['proposal', 'accepted_name_enc IS NOT NULL AND link_id IN (SELECT l.link_id FROM crm.client_link l '
                         'WHERE l.traveler_id = $1)', 'accepted_name_enc = NULL, accepted_name_erased_at = now()'],
            ['signature_request', 'traveler_id = $1', ''],
            ['otp_challenge', 'traveler_id = $1', ''],
            ['traveler_access', 'traveler_id = $1', ''],
            ['meeting_slot', 'traveler_id = $1 OR form_submission_id IN (SELECT s.submission_id '
                             'FROM crm.form_submission s WHERE s.traveler_id = $1)', ''],
            ['dispatch_queue', 'traveler_id = $1', ''],
            ['message', 'conversation_id IN (SELECT c.conversation_id FROM crm.conversation c '
                        'WHERE c.traveler_id = $1)', ''],
            ['conversation', 'traveler_id = $1', ''],
            ['traveler_health', 'traveler_id = $1', ''],
            ['document', 'traveler_id = $1', ''],
            ['note', 'traveler_id = $1', ''],
            ['traveler_relation', 'from_traveler_id = $1 OR to_traveler_id = $1', ''],
            ['trip_traveler', 'traveler_id = $1', ''],
            ['trip_party', 'traveler_token = $2', ''],
            ['profile_history', 'traveler_token = $2', ''],
            ['traveler_profile', 'traveler_token = $2', ''],
            ['consent', 'traveler_id = $1', ''],
            ['form_submission', 'traveler_id = $1', ''],
            ['client_link', 'traveler_id = $1', ''],
            ['traveler', 'referrer_traveler_id = $1', 'referrer_traveler_id = NULL'],
            ['traveler', 'traveler_id = $1', '']
        ] LOOP
            v_counts := v_counts || jsonb_build_object(
                v_step[1] || CASE WHEN v_step[3] = '' THEN '' WHEN v_step[1] = 'proposal' THEN '_acceptance_name_erased'
                                  ELSE '_referrer_unlinked' END,
                crm.erase_rows(v_step[1], v_step[2], p_subject, p_profile_token, p_dry_run, NULLIF(v_step[3], '')));
        END LOOP;
    ELSIF p_scope IN ('task', 'note', 'document') THEN
        v_counts := jsonb_build_object(p_scope,
            crm.erase_rows(p_scope, p_scope || '_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'relation' THEN
        v_counts := jsonb_build_object('traveler_relation',
            crm.erase_rows('traveler_relation', 'relation_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'booking_line' THEN
        -- crm-014: the trash purge of a planning line: its money, then the line. crm-017: its AA requests first (an
        -- agency line has none; an AA line never reaches the trash, the guard refuses it).
        v_counts := jsonb_build_object(
            'aa_request', crm.erase_rows('aa_request', 'booking_line_id = $1', p_subject, NULL, p_dry_run),
            'booking_line_money', crm.erase_rows('booking_line_money', 'booking_line_id = $1', p_subject, NULL, p_dry_run),
            'booking_line', crm.erase_rows('booking_line', 'booking_line_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'agency_supplier' THEN
        v_counts := jsonb_build_object('agency_supplier',
            crm.erase_rows('agency_supplier', 'agency_supplier_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'conversation' THEN
        -- crm-015: the trash purge of a conversation (an Unmatched one the agent deleted): its messages, then it. Kept
        -- attachments are documents of the trip / traveller and stay with them.
        v_counts := jsonb_build_object(
            'message', crm.erase_rows('message', 'conversation_id = $1', p_subject, NULL, p_dry_run),
            'conversation', crm.erase_rows('conversation', 'conversation_id = $1', p_subject, NULL, p_dry_run));
    ELSE
        -- The whole agency. Memberships are deleted as a platform action (crm-008 guard_member_write lets only an
        -- unscoped or platform context delete a member); the caller's actor is restored afterwards.
        PERFORM set_config('app.actor', 'platform:crm_offboarding', true);
        -- crm-013: the agency's CIS membership feed records (ids and codes) go first.
        -- crm-014: line money, lines and suppliers before the trips; the FX overrides before the members (set_by).
        -- crm-015: messages and conversations before the trips and travellers; saved replies, imports, the forward-in
        -- address and the mailboxes before the credentials and the members.
        -- crm-016: signatures, codes, portal access, payments, schedule rows, proposals and agreement versions first.
        -- crm-017: the Booking feed records and cursor, then the AA requests before the lines.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['membership_inbox', ''], ['inbox_events', ''], ['booking_feed_state', ''],
            ['signature_request', ''], ['otp_challenge', ''], ['traveler_access', ''], ['payment', ''],
            ['payment_schedule', ''], ['proposal', ''], ['agreement_doc', ''],
            ['dispatch_queue', ''], ['message', ''], ['conversation', ''],
            ['trip_commitment', ''], ['aa_request', ''], ['booking_line_money', ''], ['booking_line', ''],
            ['agency_supplier', ''], ['document', ''], ['traveler_health', ''],
            ['note', ''], ['task', ''], ['trip_stage_history', ''], ['trip_party', ''], ['trip_traveler', ''],
            ['traveler_relation', ''], ['consent', ''], ['meeting_slot', ''], ['form_submission', ''],
            ['client_link', ''], ['profile_history', ''],
            ['traveler_profile', ''], ['placeholder_map', 'optional'], ['llm_call', ''], ['trip', ''],
            ['traveler', 'unlink'], ['traveler', ''], ['intake_form', ''], ['form_definition', ''],
            ['saved_reply', ''], ['mail_import', ''], ['ingest_address', ''], ['channel_account', ''],
            ['integration_credential', ''], ['fx_rate_override', ''], ['tenant_settings', ''],
            ['member_invitation', 'optional'], ['owner_recovery_request', 'optional'],
            ['tenant_entitlement', 'optional'], ['member', '']
        ] LOOP
            CONTINUE WHEN v_step[2] = 'optional' AND to_regclass('crm.' || v_step[1]) IS NULL;
            IF v_step[2] = 'unlink' THEN
                v_counts := v_counts || jsonb_build_object('traveler_referrer_unlinked',
                    crm.erase_rows('traveler', 'referrer_traveler_id IS NOT NULL', p_subject, NULL, p_dry_run,
                                   'referrer_traveler_id = NULL'));
            ELSE
                v_counts := v_counts || jsonb_build_object(v_step[1],
                    crm.erase_rows(v_step[1], 'true', p_subject, NULL, p_dry_run));
            END IF;
        END LOOP;
        PERFORM set_config('app.actor', v_actor, true);
        -- Nothing of the agency may be left in a tenant table outside the keep list: a table added later that this
        -- function does not know fails the erase (rolled back) instead of keeping personal data silently.
        IF NOT p_dry_run THEN
            FOR r IN SELECT c.relname::text AS name
                       FROM pg_catalog.pg_class c
                       JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
                      WHERE c.relnamespace = 'crm'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
                        AND c.relname <> ALL (c_keep) AND c.relname NOT LIKE 'audit_event%'
                      ORDER BY 1 LOOP
                IF NOT (SELECT relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = ('crm.' || quote_ident(r.name))::regclass) THEN
                    v_left := v_left || r.name;  -- without FORCE RLS the owner would see every agency: refuse
                ELSE
                    EXECUTE format('SELECT EXISTS (SELECT 1 FROM crm.%I)', r.name) INTO v_has_token;
                    IF v_has_token THEN
                        v_left := v_left || r.name;
                    END IF;
                END IF;
            END LOOP;
            IF cardinality(v_left) > 0 THEN
                RAISE EXCEPTION 'crm: erase_incomplete (rows left in %)', array_to_string(v_left, ', ')
                    USING ERRCODE = 'CRM16';
            END IF;
        END IF;
    END IF;

    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', '', true);
    END IF;
    RETURN jsonb_build_object('scope', p_scope, 'dry_run', p_dry_run, 'counts', v_counts);
END;
$$;
REVOKE ALL ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) TO crm_eraser;

COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope), by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge), by AA-945 (crm-015) to mail (trip, traveller and agency scopes: message, conversation; agency scope: saved_reply, mail_import, ingest_address, channel_account; new scope conversation for the trash purge), by AA-946 (crm-016) to the lifecycle tables (trip and agency scopes: signature_request, otp_challenge, traveler_access, payment, payment_schedule, proposal; traveller scope: signature_request, otp_challenge, traveler_access, and the typed acceptance name of the proposals their links carried (accepted_name_enc := NULL); agency scope: agreement_doc) and by AA-947 (crm-017) to the AA lines (trip, booking_line and agency scopes: aa_request; agency scope: inbox_events, booking_feed_state): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, conversation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
BEGIN
    FOREACH t IN ARRAY ARRAY['crm.aa_request', 'crm.booking_feed_state', 'crm.inbox_events'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = t::regclass) THEN
            RAISE EXCEPTION 'crm-017: % must have ENABLE + FORCE row level security', t;
        END IF;
        IF pg_catalog.has_table_privilege('crm_app', t, 'DELETE')
           OR pg_catalog.has_table_privilege('crm_app', t, 'TRUNCATE')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'SELECT')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'INSERT') THEN
            RAISE EXCEPTION 'crm-017: crm_app must read and insert % and never delete or truncate it', t;
        END IF;
    END LOOP;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.inbox_events', 'UPDATE') THEN
        RAISE EXCEPTION 'crm-017: crm.inbox_events is append-only for crm_app';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.aa_request', 'crm.booking_feed_state', 'crm.inbox_events', 'crm.aa_catalog_tour',
                             'crm.aa_catalog_state'] LOOP
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, t, p) THEN
                    RAISE EXCEPTION 'crm-017: reader % may % on %', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.aa_catalog_tour', 'DELETE')
       OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.aa_catalog_tour', 'UPDATE')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.aa_catalog_state', 'INSERT')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.aa_catalog_state', 'DELETE') THEN
        RAISE EXCEPTION 'crm-017: the catalog cache tables: crm_app writes tours, updates the one state row, deletes nothing';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-017: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-017: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.aa_line_request(uuid,text,text,text,text,date,integer,integer,integer,integer,jsonb,text,numeric)',
                             'crm.booking_line_aa_money(uuid,text,numeric,text,numeric,date)'] LOOP
        IF NOT pg_catalog.has_function_privilege('crm_app', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-017: crm_app must execute %', t;
        END IF;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['crm.aa_line_request(uuid,text,text,text,text,date,integer,integer,integer,integer,jsonb,text,numeric)',
                             'crm.booking_line_aa_money(uuid,text,numeric,text,numeric,date)',
                             'crm.erase_subject(text,uuid,uuid,boolean)'] LOOP
        IF pg_catalog.has_function_privilege('public', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-017: % is executable by PUBLIC (SEC-4)', t;
        END IF;
    END LOOP;
    -- The AA money writer admits a job: actor only (never a member, never AA platform staff).
    IF position('platform' IN (SELECT prosrc FROM pg_catalog.pg_proc
                 WHERE oid = 'crm.booking_line_aa_money(uuid,text,numeric,text,numeric,date)'::regprocedure)) > 0 THEN
        RAISE EXCEPTION 'crm-017: crm.booking_line_aa_money must not admit a platform: actor';
    END IF;
    -- Every table an earlier key taught erase_subject, and this key's.
    FOREACH t IN ARRAY ARRAY['aa_request', 'inbox_events', 'booking_feed_state', 'signature_request',
                             'otp_challenge', 'traveler_access', 'payment', 'payment_schedule', 'proposal',
                             'agreement_doc', 'message', 'conversation', 'saved_reply', 'mail_import',
                             'ingest_address', 'channel_account', 'booking_line_money', 'booking_line',
                             'agency_supplier', 'fx_rate_override', 'membership_inbox', 'client_link',
                             'meeting_slot'] LOOP
        IF position(quote_literal(t) IN (SELECT prosrc FROM pg_catalog.pg_proc
                     WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
            RAISE EXCEPTION 'crm-017: crm.erase_subject does not erase crm.%', t;
        END IF;
    END LOOP;
    IF position('accepted_name_erased_at' IN (SELECT prosrc FROM pg_catalog.pg_proc
                 WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-017: crm.erase_subject lost the crm-016 typed acceptance name step';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-017', now(), 'AA-947: CRM-19 B2B client + AA lines (booking_line AA columns and sub-statuses, aa_request outage queue, booking_feed_state, inbox_events, aa_catalog_tour + aa_catalog_state catalog cache, crm.aa_line_request, crm.booking_line_aa_money with the quote FX lock, erase_subject + hold guard for the new tables)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
