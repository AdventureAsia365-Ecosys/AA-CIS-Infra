-- Migration bk-005: Wave 1 staff admin extras (AA-681 / AA-680 / AA-810 W1, S236 UI spec §6.2 and §8).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/005_w1_extras.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as aa_cis_admin, like bk-001..bk-004. Never run it from a laptop.
--
-- Depends on bk-001..bk-003 only. It does NOT reference any bk-004 object (pricing_rules, fx_rates,
-- version_item_costs), so it applies whether or not bk-004 is already in. It also avoids the blanket
-- "GRANT ... ON ALL TABLES IN SCHEMA booking": run after bk-004 that would re-open UPDATE/DELETE on the
-- append-only pricing tables. Every grant below names its table.
--
-- What it adds (docs/implementation-notes/AA-681-w1.md):
--   * D3: status edges proposal_sent -> confirmed (a version approved by the customer, recorded by staff),
--     confirmed -> cancelled (with a reason, until AA-682 adds the post-sale chain) and cancelled ->
--     new_inquiry (reopen with a reason). Seed rows only; bk-003 is unchanged.
--     trip_case_status_history.seq orders rows written in one transaction.
--   * Trip cases: pax_adults / pax_children (Q13), trip_case_countries over a small ISO reference table
--     booking.countries (codes + English short names only; country CONTENT stays in CIS, O7 / Q18).
--   * Customers: human code CUS-000123 (Q15) from booking.customer_code_seq, back-filled for existing rows;
--     booking.v_customer_summary (status lead / active / past derived from trip cases, case counts,
--     last activity).
--   * Versions: title, valid_until, channel, FX lock columns (filled when the pricing engine is wired),
--     sent_by / approved_by / approval_note, updated_by, deleted_at (soft delete of unsent drafts) and a
--     "sent = locked" trigger: once sent, a version's commercial fields and its items cannot change and the
--     version cannot be hard-deleted (role booking has no DELETE on versions; the app soft-deletes drafts).
--   * Notifications: recipient_ref (CIS user id of a targeted staff recipient) and per-staff read state
--     booking.notification_reads (the shared staff queue has one row per event, read state per person).
--   * Staff: preferences JSONB (notification toggles).
--   * booking.settings: config rows (deposit_pct 30, quote_validity_days 14), read-only for role booking.
--   * audit_logs: entity_label / summary (written by the API) + a time index for the audit log page.
--
-- Status columns stay TEXT + CHECK. Re-running the whole file is a no-op.

BEGIN;

-- ── D3: status edges (seed rows; bk-003 file unchanged) ──────────────────────

INSERT INTO booking.trip_case_status_transitions (from_status, to_status) VALUES
    ('proposal_sent', 'confirmed'),
    ('confirmed', 'cancelled'),
    ('cancelled', 'new_inquiry')
ON CONFLICT DO NOTHING;

COMMENT ON TABLE booking.trip_case_status_transitions IS
    'bk-003 + bk-005: allowed trip case status edges (read-only for role booking). Pre-sale edges, proposal_sent -> confirmed (version approval), confirmed -> cancelled and cancelled -> new_inquiry (reopen). Post-sale edges ship with AA-682.';

-- Several status rows can be written in one transaction (send walks discovery -> building ->
-- proposal_sent) and then share changed_at = now(); seq gives them a stable write order.
ALTER TABLE booking.trip_case_status_history
    ADD COLUMN IF NOT EXISTS seq BIGINT GENERATED ALWAYS AS IDENTITY;

CREATE INDEX IF NOT EXISTS trip_case_status_history_case_seq_idx
    ON booking.trip_case_status_history (trip_case_id, seq);

-- ── Trip cases: pax split ────────────────────────────────────────────────────

ALTER TABLE booking.trip_cases
    ADD COLUMN IF NOT EXISTS pax_adults SMALLINT,
    ADD COLUMN IF NOT EXISTS pax_children SMALLINT;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conname = 'trip_cases_pax_split_chk') THEN
        ALTER TABLE booking.trip_cases ADD CONSTRAINT trip_cases_pax_split_chk CHECK (
            (pax_adults IS NULL OR pax_adults >= 1)
            AND (pax_children IS NULL OR (pax_children >= 0 AND pax_adults IS NOT NULL))
            AND (pax_adults IS NULL OR pax = pax_adults + coalesce(pax_children, 0))
        );
    END IF;
END $$;

COMMENT ON COLUMN booking.trip_cases.pax_adults IS
    'bk-005 (Q13): adults; when set, pax = pax_adults + coalesce(pax_children, 0).';

CREATE INDEX IF NOT EXISTS trip_cases_updated_idx
    ON booking.trip_cases (updated_at DESC) WHERE deleted_at IS NULL;

-- ── Countries (ISO reference only) + trip case countries ─────────────────────

CREATE TABLE IF NOT EXISTS booking.countries (
    iso2    CHAR(2) PRIMARY KEY,
    name    TEXT NOT NULL,
    active  BOOLEAN NOT NULL DEFAULT true,

    CONSTRAINT countries_iso2_chk CHECK (iso2 ~ '^[A-Z]{2}$')
);

COMMENT ON TABLE booking.countries IS
    'bk-005: ISO 3166-1 alpha-2 reference for trip case countries (code + English short name). Not content: descriptions, photos and FAQs stay in CIS (O7, Q18).';

INSERT INTO booking.countries (iso2, name) VALUES
    ('VN', 'Vietnam'),
    ('KH', 'Cambodia'),
    ('LA', 'Laos'),
    ('TH', 'Thailand'),
    ('MM', 'Myanmar'),
    ('MY', 'Malaysia'),
    ('SG', 'Singapore'),
    ('ID', 'Indonesia'),
    ('PH', 'Philippines'),
    ('NP', 'Nepal'),
    ('BT', 'Bhutan'),
    ('IN', 'India'),
    ('LK', 'Sri Lanka'),
    ('CN', 'China'),
    ('JP', 'Japan'),
    ('KR', 'South Korea')
ON CONFLICT (iso2) DO NOTHING;

CREATE TABLE IF NOT EXISTS booking.trip_case_countries (
    trip_case_id  UUID NOT NULL REFERENCES booking.trip_cases (id) ON DELETE CASCADE,
    country_code  CHAR(2) NOT NULL REFERENCES booking.countries (iso2),
    position      SMALLINT NOT NULL DEFAULT 1,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT trip_case_countries_pk PRIMARY KEY (trip_case_id, country_code),
    CONSTRAINT trip_case_countries_position_chk CHECK (position >= 1)
);

CREATE INDEX IF NOT EXISTS trip_case_countries_country_idx
    ON booking.trip_case_countries (country_code);

-- ── Customers: human code ────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS booking.customer_code_seq;

-- A volatile default on ADD COLUMN back-fills every existing row with its own code.
ALTER TABLE booking.customers
    ADD COLUMN IF NOT EXISTS code TEXT NOT NULL
        DEFAULT ('CUS-' || lpad(nextval('booking.customer_code_seq')::text, 6, '0'));

CREATE UNIQUE INDEX IF NOT EXISTS customers_code_uq ON booking.customers (code);

COMMENT ON COLUMN booking.customers.code IS 'bk-005 (Q15): human customer code CUS-000123.';

-- ── Versions: send / approve / soft delete fields ────────────────────────────

ALTER TABLE booking.trip_case_versions
    ADD COLUMN IF NOT EXISTS title TEXT,
    ADD COLUMN IF NOT EXISTS valid_until DATE,
    ADD COLUMN IF NOT EXISTS channel TEXT,
    ADD COLUMN IF NOT EXISTS fx_rate_locked NUMERIC(18, 8),
    ADD COLUMN IF NOT EXISTS fx_as_of DATE,
    ADD COLUMN IF NOT EXISTS sent_by TEXT REFERENCES booking.staff_users (cis_user_id),
    ADD COLUMN IF NOT EXISTS approved_by TEXT REFERENCES booking.staff_users (cis_user_id),
    ADD COLUMN IF NOT EXISTS approval_note TEXT,
    ADD COLUMN IF NOT EXISTS updated_by TEXT REFERENCES booking.staff_users (cis_user_id),
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conname = 'trip_case_versions_title_chk') THEN
        ALTER TABLE booking.trip_case_versions ADD CONSTRAINT trip_case_versions_title_chk
            CHECK (title IS NULL OR length(title) BETWEEN 1 AND 200);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conname = 'trip_case_versions_channel_chk') THEN
        ALTER TABLE booking.trip_case_versions ADD CONSTRAINT trip_case_versions_channel_chk
            CHECK (channel IS NULL OR channel IN ('b2c_tailor_made', 'fixed_departure', 'b2b'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conname = 'trip_case_versions_fx_chk') THEN
        ALTER TABLE booking.trip_case_versions ADD CONSTRAINT trip_case_versions_fx_chk
            CHECK (fx_rate_locked IS NULL OR fx_rate_locked > 0);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conname = 'trip_case_versions_deleted_chk') THEN
        ALTER TABLE booking.trip_case_versions ADD CONSTRAINT trip_case_versions_deleted_chk
            CHECK (deleted_at IS NULL OR (NOT is_sent_to_customer AND NOT is_approved));
    END IF;
END $$;

COMMENT ON COLUMN booking.trip_case_versions.fx_rate_locked IS
    'bk-005 (ADR 0005 §5): FX rate (units of currency per USD) locked when the version is sent; NULL until the pricing engine (bk-004) is wired into send.';

CREATE INDEX IF NOT EXISTS trip_case_versions_updated_idx
    ON booking.trip_case_versions (updated_at DESC) WHERE deleted_at IS NULL;

-- A sent version is customer-visible history: its commercial fields and items no longer change. Only the
-- approval columns (and bookkeeping) may move afterwards. The bk-003 trigger still locks approved rows fully.
CREATE OR REPLACE FUNCTION booking.trip_case_version_sent_lock() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    -- A sent version is never removed, not even by a cascade from its trip case (the item lock below cannot
    -- see the version once the cascade deleted it, so the version row itself must refuse).
    IF TG_OP = 'DELETE' THEN
        IF OLD.is_sent_to_customer THEN
            RAISE EXCEPTION 'trip case version % was sent to the customer and cannot be deleted', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.is_sent_to_customer AND (
        NOT NEW.is_sent_to_customer
        OR NEW.sent_at IS DISTINCT FROM OLD.sent_at
        OR NEW.title IS DISTINCT FROM OLD.title
        OR NEW.notes IS DISTINCT FROM OLD.notes
        OR NEW.total_price IS DISTINCT FROM OLD.total_price
        OR NEW.currency IS DISTINCT FROM OLD.currency
        OR NEW.valid_until IS DISTINCT FROM OLD.valid_until
        OR NEW.channel IS DISTINCT FROM OLD.channel
        OR NEW.fx_rate_locked IS DISTINCT FROM OLD.fx_rate_locked
        OR NEW.fx_as_of IS DISTINCT FROM OLD.fx_as_of
        OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at
        OR NEW.version_number IS DISTINCT FROM OLD.version_number
        OR NEW.trip_case_id IS DISTINCT FROM OLD.trip_case_id
    ) THEN
        RAISE EXCEPTION 'trip case version % was sent to the customer and is locked', OLD.id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION booking.trip_case_version_item_sent_lock() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_id UUID;
BEGIN
    v_id := CASE WHEN TG_OP = 'INSERT' THEN NEW.trip_case_version_id ELSE OLD.trip_case_version_id END;
    IF EXISTS (SELECT 1 FROM booking.trip_case_versions v WHERE v.id = v_id AND v.is_sent_to_customer)
       OR (TG_OP = 'UPDATE' AND EXISTS (
           SELECT 1 FROM booking.trip_case_versions v
           WHERE v.id = NEW.trip_case_version_id AND v.is_sent_to_customer))
    THEN
        RAISE EXCEPTION 'trip case version % was sent to the customer and is locked', v_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER trip_case_versions_sent_lock
    BEFORE UPDATE OR DELETE ON booking.trip_case_versions
    FOR EACH ROW EXECUTE FUNCTION booking.trip_case_version_sent_lock();

CREATE OR REPLACE TRIGGER trip_case_version_itinerary_sent_lock
    BEFORE INSERT OR UPDATE OR DELETE ON booking.trip_case_version_itinerary
    FOR EACH ROW EXECUTE FUNCTION booking.trip_case_version_item_sent_lock();

-- ── Notifications: targeted recipient + per-staff read state ─────────────────

ALTER TABLE booking.notifications
    ADD COLUMN IF NOT EXISTS recipient_ref TEXT;

COMMENT ON COLUMN booking.notifications.recipient_ref IS
    'bk-005: CIS user id of the staff recipient (staff_users.cis_user_id). NULL with recipient_type staff = the shared staff queue.';

CREATE INDEX IF NOT EXISTS notifications_staff_feed_idx
    ON booking.notifications (recipient_ref, created_at DESC) WHERE recipient_type = 'staff';

CREATE TABLE IF NOT EXISTS booking.notification_reads (
    notification_id  UUID NOT NULL REFERENCES booking.notifications (id) ON DELETE CASCADE,
    cis_user_id      TEXT NOT NULL REFERENCES booking.staff_users (cis_user_id),
    read_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT notification_reads_pk PRIMARY KEY (notification_id, cis_user_id)
);

CREATE INDEX IF NOT EXISTS notification_reads_staff_idx
    ON booking.notification_reads (cis_user_id, read_at DESC);

-- ── Staff preferences ────────────────────────────────────────────────────────

ALTER TABLE booking.staff_users
    ADD COLUMN IF NOT EXISTS preferences JSONB NOT NULL DEFAULT '{}'::jsonb;

-- ── Settings (config rows) ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.settings (
    key          TEXT PRIMARY KEY,
    value        JSONB NOT NULL,
    description  TEXT,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT settings_key_chk CHECK (key ~ '^[a-z][a-z0-9_]{0,62}$')
);

COMMENT ON TABLE booking.settings IS
    'bk-005: Booking-wide configuration rows (read-only for role booking; changed by a reviewed migration).';

INSERT INTO booking.settings (key, value, description) VALUES
    ('deposit_pct', '30'::jsonb, 'Deposit due on confirmation, percent of the approved total (ADR 0005, to confirm with Ms. Thu).'),
    ('quote_validity_days', '14'::jsonb, 'Default validity of a sent proposal in days (ADR 0005 §5: 7-14 days; the API accepts 7-30).')
ON CONFLICT (key) DO NOTHING;

-- ── Audit: label / summary + time index ──────────────────────────────────────

ALTER TABLE booking.audit_logs
    ADD COLUMN IF NOT EXISTS entity_label TEXT,
    ADD COLUMN IF NOT EXISTS summary TEXT;

CREATE INDEX IF NOT EXISTS audit_logs_created_idx
    ON booking.audit_logs (created_at DESC);

-- ── Customer summary view ────────────────────────────────────────────────────
-- status: active = has a live trip case in an open status past new_inquiry; past = otherwise has a
-- completed case; lead = everything else (no case, only new inquiries or cancelled cases).

CREATE OR REPLACE VIEW booking.v_customer_summary WITH (security_barrier = true) AS
SELECT
    c.id,
    c.code,
    c.name,
    c.email,
    c.phone,
    c.address,
    c.verified,
    c.is_blocked,
    c.needs_merge_review,
    c.merge_candidate_id,
    c.source,
    c.contact_consent,
    c.contact_consent_at,
    c.created_at,
    c.updated_at,
    coalesce(s.case_count, 0) AS case_count,
    coalesce(s.open_case_count, 0) AS open_case_count,
    greatest(c.updated_at, s.last_case_activity_at) AS last_activity_at,
    CASE
        WHEN coalesce(s.open_case_count, 0) > 0 THEN 'active'
        WHEN coalesce(s.completed_case_count, 0) > 0 THEN 'past'
        ELSE 'lead'
    END AS status
FROM booking.customers c
LEFT JOIN LATERAL (
    SELECT
        count(*) AS case_count,
        count(*) FILTER (WHERE tc.status NOT IN ('new_inquiry', 'completed', 'cancelled')) AS open_case_count,
        count(*) FILTER (WHERE tc.status = 'completed') AS completed_case_count,
        max(tc.updated_at) AS last_case_activity_at
    FROM booking.trip_cases tc
    WHERE tc.customer_id = c.id AND tc.deleted_at IS NULL
) s ON true
WHERE c.deleted_at IS NULL;

COMMENT ON VIEW booking.v_customer_summary IS
    'bk-005: live customers with derived status (lead / active / past), case counts and last activity (read-only).';

-- ── Grants (per object; no blanket ALL TABLES grant, see header) ─────────────

GRANT SELECT ON booking.countries TO booking;
GRANT SELECT, INSERT, UPDATE, DELETE ON booking.trip_case_countries TO booking;
GRANT SELECT, INSERT, DELETE ON booking.notification_reads TO booking;
GRANT SELECT ON booking.settings TO booking;
GRANT SELECT ON booking.v_customer_summary TO booking;
GRANT USAGE, SELECT ON SEQUENCE booking.customer_code_seq TO booking;
GRANT EXECUTE ON FUNCTION booking.trip_case_version_sent_lock() TO booking;
GRANT EXECUTE ON FUNCTION booking.trip_case_version_item_sent_lock() TO booking;

-- Reference / config data and the view are read-only for the app; read marks are never rewritten.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.countries FROM booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.settings FROM booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_customer_summary FROM booking;
REVOKE UPDATE, TRUNCATE ON booking.notification_reads FROM booking;
REVOKE TRUNCATE ON booking.trip_case_countries FROM booking;
-- Versions are soft-deleted (deleted_at) by the API; a hard DELETE would drop customer-visible history.
REVOKE DELETE, TRUNCATE ON booking.trip_case_versions FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-005', now(), 'AA-681 W1: transitions proposal_sent->confirmed, confirmed->cancelled, cancelled->new_inquiry, pax split, countries + trip_case_countries, customers.code (CUS-), v_customer_summary, version title/valid_until/channel/FX lock/sent+approved by/soft delete + sent lock (no hard delete), notifications.recipient_ref + notification_reads, staff preferences, settings, audit entity_label/summary')
ON CONFLICT (version) DO NOTHING;

COMMIT;
