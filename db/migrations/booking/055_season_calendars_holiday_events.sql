-- Migration bk-055: AA-1091 (S278) — season calendars, stop-sale ranges and holiday events (root ADR 0005b decision 4;
-- delivery step 4).
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/055_season_calendars_holiday_events.sql; on Dev it is applied as bk_owner (the live owner of
-- schema booking since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a). Never run it
-- from a laptop.
--
-- Why: a season is a free-text label today and "peak" is found by the substring 'peak' (and B2B quotes run with
-- peak = false), so the agency price and the RRP follow two season logics. Seasons become data; holiday dates are
-- entered per country and year as data, never written in code.
--
-- What (new tables, one new column; no row is seeded):
--   1. booking.season_calendars: a calendar belongs to one destination (CIS destination id, the seasons of AA's
--      sell-side price list) or to one supplier contract (the supplier's seasons). default_season (low unless set)
--      prices every date no range covers; a change of it is proposed with a reason (pending_default_season,
--      default_request_reason) and approved by a second person.
--   2. booking.season_ranges: date ranges of a calendar, half-open [date_from, date_to) (d10): a season range (low,
--      high, peak, festive) or a stop-sale range (an availability overlay: never the season or the price). A festive
--      range may instead name a holiday event (holiday_country + holiday_code, with days before and after): it takes
--      its dates from that event's row of each year and never copies them. Maker-checker: a range counts once a
--      second person approves it; removing one is a request a second person approves (end_requested_by -> ended_by).
--      A reason is required on every proposal (note), withdrawal (withdraw_reason), removal request (end_reason) and
--      rejection (reject_reason) (ADR 0005b d1, the bk-048 model).
--      The fixed-date season ranges of one calendar never overlap (checked by the app under a calendar lock).
--   3. booking.holiday_events: one row per country, event code and year (Tet 2027 in VN, Songkran 2027 in TH...),
--      half-open dates, maker-checker and reasons like the ranges.
--   4. booking.trip_plans.season_calendar_id: the sell-side calendar of a plan (default: the calendar of the
--      destination of its first day, set by the app). A staff change is a request with a reason
--      (pending_season_calendar_id, season_calendar_requested_by / _at / season_calendar_request_reason) that a second
--      person approves: the calendar drives the peak uplift, festive validity and stop-sale of the plan's prices.
--
-- Class: contract (root ADR 0017 d3): ADD COLUMNs with FKs and a CHECK on an existing table (trip_plans). So a migration-only
-- PR (with bk-054) first, then the code PR raises readiness (MIG-4). On Dev: Infra Migration Apply once every job
-- table is idle (root ADR 0017a). Needs bk-005 (countries), bk-008 (supplier_contracts), bk-009 (trip_plans).
-- DM-7.1: the three new tables have their rows in the root data standards (root PR merged before the Infra copy).
-- DM-6.1: no personal data; names, note and the reasons are pii:free_text (staff text, never traveller data by rule).
-- Locks: SHARE ROW EXCLUSIVE on trip_plans (about 900 rows) for the FKs and ACCESS EXCLUSIVE for the nullable ADD
-- COLUMNs (no rewrite) and the CHECK (a scan of about 900 rows, all NULL). lock_timeout 5s.
-- Re-runnable (the integration tests replay every file): IF NOT EXISTS, DROP CONSTRAINT IF EXISTS before each ADD,
-- grants repeat.
-- Undo (a later bk- file, after the code is reverted): ALTER TABLE booking.trip_plans DROP CONSTRAINT
-- trip_plans_season_calendar_request_chk, DROP COLUMN season_calendar_id, pending_season_calendar_id,
-- season_calendar_requested_by, season_calendar_requested_at, season_calendar_request_reason;
-- DROP TABLE season_ranges, holiday_events, season_calendars.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('booking.countries') IS NULL OR to_regclass('booking.supplier_contracts') IS NULL
       OR to_regclass('booking.trip_plans') IS NULL THEN
        RAISE EXCEPTION 'bk-055: needs bk-005, bk-008 and bk-009 first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-055' AND description NOT LIKE 'AA-1091 season calendars%') THEN
        RAISE EXCEPTION 'bk-055: the key bk-055 is already held by another migration: renumber one';
    END IF;
END $$;

-- ── 1. Calendars ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.season_calendars (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_kind              TEXT NOT NULL,
    destination_id          UUID,
    supplier_contract_id    UUID REFERENCES booking.supplier_contracts (id),
    name                    TEXT NOT NULL,
    default_season          TEXT NOT NULL DEFAULT 'low',
    pending_default_season  TEXT,
    default_requested_by    TEXT,
    default_requested_at    TIMESTAMPTZ,
    default_request_reason  TEXT,
    created_by              TEXT NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT season_calendars_owner_chk CHECK (
        owner_kind IN ('destination', 'supplier_contract')
        AND (owner_kind = 'destination') = (destination_id IS NOT NULL)
        AND (owner_kind = 'supplier_contract') = (supplier_contract_id IS NOT NULL)),
    CONSTRAINT season_calendars_default_chk CHECK (
        default_season IN ('low', 'high', 'peak', 'festive')
        AND (pending_default_season IS NULL OR pending_default_season IN ('low', 'high', 'peak', 'festive'))
        AND (pending_default_season IS NULL) = (default_requested_by IS NULL)
        AND (default_requested_by IS NULL) = (default_requested_at IS NULL)
        AND (default_requested_by IS NULL) = (default_request_reason IS NULL)),
    CONSTRAINT season_calendars_text_chk CHECK (
        length(btrim(name)) BETWEEN 1 AND 120 AND length(btrim(created_by)) BETWEEN 1 AND 128
        AND (default_request_reason IS NULL OR length(btrim(default_request_reason)) BETWEEN 1 AND 300))
);

CREATE UNIQUE INDEX IF NOT EXISTS season_calendars_destination_uq
    ON booking.season_calendars (destination_id) WHERE destination_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS season_calendars_contract_uq
    ON booking.season_calendars (supplier_contract_id) WHERE supplier_contract_id IS NOT NULL;

COMMENT ON TABLE booking.season_calendars IS
    'bk-055 (AA-1091, root ADR 0005b d4): the seasons of one destination (AA''s sell-side price list) or of one supplier contract. A date no approved range covers takes default_season. A change of default_season is proposed (pending_default_season) and approved by a second person.';
COMMENT ON COLUMN booking.season_calendars.name IS
    'pii:free_text; the calendar''s name (a destination or contract name); staff text, never traveller data by rule.';
COMMENT ON COLUMN booking.season_calendars.default_request_reason IS
    'pii:free_text; why the default season should change (staff text, never traveller data by rule).';
COMMENT ON COLUMN booking.season_calendars.destination_id IS
    'bk-055: the CIS destination (catalog.v_destination.destination_id) whose sell-side seasons this is.';

-- ── 2. Ranges ────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.season_ranges (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    calendar_id       UUID NOT NULL REFERENCES booking.season_calendars (id),
    kind              TEXT NOT NULL,
    season_code       TEXT,
    date_from         DATE,
    date_to           DATE,
    holiday_country   CHAR(2),
    holiday_code      TEXT,
    days_before       SMALLINT NOT NULL DEFAULT 0,
    days_after        SMALLINT NOT NULL DEFAULT 0,
    note              TEXT NOT NULL,
    status            TEXT NOT NULL DEFAULT 'pending',
    created_by        TEXT NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_by        TEXT,
    decided_at        TIMESTAMPTZ,
    reject_reason     TEXT,
    withdraw_reason   TEXT,
    end_requested_by  TEXT,
    end_requested_at  TIMESTAMPTZ,
    end_reason        TEXT,
    ended_by          TEXT,
    ended_at          TIMESTAMPTZ,
    CONSTRAINT season_ranges_kind_chk CHECK (
        (kind = 'season' AND season_code IN ('low', 'high', 'peak', 'festive'))
        OR (kind = 'stop_sale' AND season_code IS NULL)),
    -- Fixed dates, or (festive only) a holiday event referenced by country and code: never both.
    CONSTRAINT season_ranges_dates_chk CHECK (
        (date_from IS NOT NULL AND date_to IS NOT NULL AND date_to > date_from AND date_to - date_from <= 366
         AND holiday_country IS NULL AND holiday_code IS NULL AND days_before = 0 AND days_after = 0)
        OR (date_from IS NULL AND date_to IS NULL AND kind = 'season' AND season_code = 'festive'
            AND holiday_country ~ '^[A-Z]{2}$' AND holiday_code ~ '^[a-z][a-z0-9_]{1,39}$'
            AND days_before BETWEEN 0 AND 60 AND days_after BETWEEN 0 AND 60)),
    CONSTRAINT season_ranges_text_chk CHECK (
        length(btrim(created_by)) BETWEEN 1 AND 128
        AND length(btrim(note)) BETWEEN 1 AND 300
        AND (reject_reason IS NULL OR length(btrim(reject_reason)) BETWEEN 1 AND 300)
        AND (withdraw_reason IS NULL OR length(btrim(withdraw_reason)) BETWEEN 1 AND 300)
        AND (end_reason IS NULL OR length(btrim(end_reason)) BETWEEN 1 AND 300)),
    -- Maker-checker: a second person approves or rejects; the maker withdraws a pending range.
    CONSTRAINT season_ranges_status_chk CHECK (
        status IN ('pending', 'approved', 'rejected', 'withdrawn')
        AND (status = 'pending') = (decided_by IS NULL)
        AND (decided_by IS NULL) = (decided_at IS NULL)
        AND (status NOT IN ('approved', 'rejected') OR decided_by <> created_by)
        AND (status <> 'withdrawn' OR decided_by = created_by)
        AND (status = 'rejected') = (reject_reason IS NOT NULL)
        AND (status = 'withdrawn') = (withdraw_reason IS NOT NULL)),
    CONSTRAINT season_ranges_end_chk CHECK (
        (end_requested_by IS NULL) = (end_requested_at IS NULL)
        AND (end_requested_by IS NULL) = (end_reason IS NULL)
        AND (ended_by IS NULL) = (ended_at IS NULL)
        AND (end_requested_by IS NULL OR status = 'approved')
        AND (ended_by IS NULL OR (end_requested_by IS NOT NULL AND ended_by <> end_requested_by)))
);

CREATE INDEX IF NOT EXISTS season_ranges_calendar_idx ON booking.season_ranges (calendar_id, status);
CREATE INDEX IF NOT EXISTS season_ranges_event_idx
    ON booking.season_ranges (holiday_country, holiday_code) WHERE holiday_code IS NOT NULL;

COMMENT ON TABLE booking.season_ranges IS
    'bk-055 (AA-1091, root ADR 0005b d4): a season range (low / high / peak / festive) or a stop-sale range of a calendar, half-open [date_from, date_to), or a festive range that names a holiday event (its dates come from the event row of each year, plus days_before / days_after). Counts once a second person approves it, until an approved removal (ended_at). The fixed-date season ranges of a calendar never overlap; a festive range from an event lies over them on its days; stop-sale changes availability only.';
COMMENT ON COLUMN booking.season_ranges.note IS
    'pii:free_text; the maker''s reason: why the range exists (required; staff text, never traveller data by rule).';
COMMENT ON COLUMN booking.season_ranges.withdraw_reason IS
    'pii:free_text; why the maker withdrew the pending range (staff text, never traveller data by rule).';
COMMENT ON COLUMN booking.season_ranges.end_reason IS
    'pii:free_text; why the range should be removed (staff text, never traveller data by rule).';
COMMENT ON COLUMN booking.season_ranges.reject_reason IS
    'pii:free_text; why a checker refused the range (staff text, never traveller data by rule).';

-- ── 3. Holiday events ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.holiday_events (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    country_iso2      CHAR(2) NOT NULL REFERENCES booking.countries (iso2),
    code              TEXT NOT NULL,
    name              TEXT NOT NULL,
    year              SMALLINT NOT NULL,
    date_from         DATE NOT NULL,
    date_to           DATE NOT NULL,
    reason            TEXT NOT NULL,
    status            TEXT NOT NULL DEFAULT 'pending',
    created_by        TEXT NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_by        TEXT,
    decided_at        TIMESTAMPTZ,
    reject_reason     TEXT,
    withdraw_reason   TEXT,
    end_requested_by  TEXT,
    end_requested_at  TIMESTAMPTZ,
    end_reason        TEXT,
    ended_by          TEXT,
    ended_at          TIMESTAMPTZ,
    CONSTRAINT holiday_events_code_chk CHECK (code ~ '^[a-z][a-z0-9_]{1,39}$'),
    CONSTRAINT holiday_events_dates_chk CHECK (
        date_to > date_from AND date_to - date_from <= 60
        AND year = extract(year FROM date_from)::int AND year BETWEEN 2000 AND 2100),
    CONSTRAINT holiday_events_text_chk CHECK (
        length(btrim(name)) BETWEEN 1 AND 120 AND length(btrim(created_by)) BETWEEN 1 AND 128
        AND length(btrim(reason)) BETWEEN 1 AND 300
        AND (reject_reason IS NULL OR length(btrim(reject_reason)) BETWEEN 1 AND 300)
        AND (withdraw_reason IS NULL OR length(btrim(withdraw_reason)) BETWEEN 1 AND 300)
        AND (end_reason IS NULL OR length(btrim(end_reason)) BETWEEN 1 AND 300)),
    CONSTRAINT holiday_events_status_chk CHECK (
        status IN ('pending', 'approved', 'rejected', 'withdrawn')
        AND (status = 'pending') = (decided_by IS NULL)
        AND (decided_by IS NULL) = (decided_at IS NULL)
        AND (status NOT IN ('approved', 'rejected') OR decided_by <> created_by)
        AND (status <> 'withdrawn' OR decided_by = created_by)
        AND (status = 'rejected') = (reject_reason IS NOT NULL)
        AND (status = 'withdrawn') = (withdraw_reason IS NOT NULL)),
    CONSTRAINT holiday_events_end_chk CHECK (
        (end_requested_by IS NULL) = (end_requested_at IS NULL)
        AND (end_requested_by IS NULL) = (end_reason IS NULL)
        AND (ended_by IS NULL) = (ended_at IS NULL)
        AND (end_requested_by IS NULL OR status = 'approved')
        AND (ended_by IS NULL OR (end_requested_by IS NOT NULL AND ended_by <> end_requested_by)))
);

-- One live row (pending or approved, not ended) per country, event and year.
CREATE UNIQUE INDEX IF NOT EXISTS holiday_events_live_uq
    ON booking.holiday_events (country_iso2, code, year)
    WHERE status IN ('pending', 'approved') AND ended_at IS NULL;

COMMENT ON TABLE booking.holiday_events IS
    'bk-055 (AA-1091, root ADR 0005b d4): one holiday event (Tet, Songkran, Lebaran, Christmas...) of one country and one year, half-open [date_from, date_to), entered as data each year (never a date in code). Festive season ranges reference it by country and code; it counts once a second person approves it, until an approved removal.';
COMMENT ON COLUMN booking.holiday_events.name IS
    'pii:free_text; the event''s name (Lunar New Year, Songkran...); staff text, never traveller data by rule.';
COMMENT ON COLUMN booking.holiday_events.reason IS
    'pii:free_text; the maker''s reason for the event row (required; staff text, never traveller data by rule).';
COMMENT ON COLUMN booking.holiday_events.withdraw_reason IS
    'pii:free_text; why the maker withdrew the pending event (staff text, never traveller data by rule).';
COMMENT ON COLUMN booking.holiday_events.end_reason IS
    'pii:free_text; why the event should be removed (staff text, never traveller data by rule).';
COMMENT ON COLUMN booking.holiday_events.reject_reason IS
    'pii:free_text; why a checker refused the event (staff text, never traveller data by rule).';

-- ── 4. The sell-side calendar of a trip plan ─────────────────────────────────

ALTER TABLE booking.trip_plans
    ADD COLUMN IF NOT EXISTS season_calendar_id UUID REFERENCES booking.season_calendars (id),
    ADD COLUMN IF NOT EXISTS pending_season_calendar_id UUID REFERENCES booking.season_calendars (id),
    ADD COLUMN IF NOT EXISTS season_calendar_requested_by TEXT,
    ADD COLUMN IF NOT EXISTS season_calendar_requested_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS season_calendar_request_reason TEXT;
ALTER TABLE booking.trip_plans DROP CONSTRAINT IF EXISTS trip_plans_season_calendar_request_chk;
-- A request: who, when and why together; a pending calendar only inside a request (a request with no pending
-- calendar asks to clear the plan's calendar).
ALTER TABLE booking.trip_plans ADD CONSTRAINT trip_plans_season_calendar_request_chk CHECK (
    (season_calendar_requested_by IS NULL) = (season_calendar_requested_at IS NULL)
    AND (season_calendar_requested_by IS NULL) = (season_calendar_request_reason IS NULL)
    AND (pending_season_calendar_id IS NULL OR season_calendar_requested_by IS NOT NULL)
    AND (season_calendar_requested_by IS NULL OR length(btrim(season_calendar_requested_by)) BETWEEN 1 AND 128)
    AND (season_calendar_request_reason IS NULL OR length(btrim(season_calendar_request_reason)) BETWEEN 1 AND 300));
CREATE INDEX IF NOT EXISTS trip_plans_season_calendar_idx
    ON booking.trip_plans (season_calendar_id) WHERE season_calendar_id IS NOT NULL;
COMMENT ON COLUMN booking.trip_plans.season_calendar_id IS
    'bk-055 (AA-1091, root ADR 0005b d4): the sell-side season calendar of the plan; its season on the departure date picks the season of the price row and the peak uplift. Default: the calendar of the destination of day 1 (set by the app); staff may change it. NULL = no calendar yet (every date is low season). Staff change it through a request a second person approves (pending_season_calendar_id).';
COMMENT ON COLUMN booking.trip_plans.pending_season_calendar_id IS
    'bk-055 (AA-1091): the calendar a staff request asks for (NULL inside a request = clear the calendar); applied when a second person approves it.';
COMMENT ON COLUMN booking.trip_plans.season_calendar_request_reason IS
    'pii:free_text; why the plan should use another season calendar (staff text, never traveller data by rule).';

-- ── 5. Grants ────────────────────────────────────────────────────────────────

REVOKE ALL ON booking.season_calendars FROM booking;
GRANT SELECT, INSERT ON booking.season_calendars TO booking;
GRANT UPDATE (name, default_season, pending_default_season, default_requested_by, default_requested_at,
              default_request_reason, updated_at)
    ON booking.season_calendars TO booking;
REVOKE ALL ON booking.season_ranges FROM booking;
GRANT SELECT, INSERT ON booking.season_ranges TO booking;
GRANT UPDATE (status, decided_by, decided_at, reject_reason, withdraw_reason, end_requested_by, end_requested_at,
              end_reason, ended_by, ended_at)
    ON booking.season_ranges TO booking;
REVOKE ALL ON booking.holiday_events FROM booking;
GRANT SELECT, INSERT ON booking.holiday_events TO booking;
GRANT UPDATE (status, decided_by, decided_at, reject_reason, withdraw_reason, end_requested_by, end_requested_at,
              end_reason, ended_by, ended_at)
    ON booking.holiday_events TO booking;
-- trip_plans: the bk-009 table grant (SELECT, INSERT, UPDATE) covers the new columns.

DO $$
BEGIN
    IF has_table_privilege('booking', 'booking.season_ranges', 'DELETE')
       OR has_table_privilege('booking', 'booking.holiday_events', 'DELETE')
       OR has_table_privilege('booking', 'booking.season_calendars', 'DELETE')
       OR has_column_privilege('booking', 'booking.season_ranges', 'date_from', 'UPDATE')
       OR has_column_privilege('booking', 'booking.holiday_events', 'date_from', 'UPDATE')
       OR has_column_privilege('booking', 'booking.season_calendars', 'destination_id', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-055: role booking can delete a calendar, a range or an event, or rewrite its dates';
    END IF;
    IF NOT has_column_privilege('booking', 'booking.trip_plans', 'season_calendar_id', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-055: role booking cannot set the season calendar of a trip plan';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-055', now(), 'AA-1091 season calendars: season_calendars (destination or supplier contract, default season), season_ranges (season / stop-sale, festive from a holiday event, maker-checker), holiday_events (per country and year), trip_plans.season_calendar_id with a second-person request')
ON CONFLICT (version) DO NOTHING;

COMMIT;
