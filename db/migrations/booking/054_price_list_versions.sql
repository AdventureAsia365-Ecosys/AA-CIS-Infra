-- Migration bk-054: AA-1091 (S278) — price list versions for the hand prices of a trip plan (root ADR 0005b decisions
-- 1, 2, 9 and 10; delivery step 3).
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/054_price_list_versions.sql; on Dev it is applied as bk_owner (the live owner of schema
-- booking since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a). Never run it from a
-- laptop.
--
-- Why: the tech lead ruled (S278) that every price the team enters or changes is a version, never an overwrite, and
-- that a second person approves it before it prices anything. Today PUT .../prices replaces a plan's matrix at once.
--
-- What:
--   1. booking.price_list_versions: one approved, immutable set of selling prices of one trip plan for one travel
--      window (d1): version_no per plan, label, tariff_year, travel window [travel_from, travel_to) (half-open, d10),
--      optional sale window [sale_from, sale_to), status (d2: draft -> pending -> published -> superseded, rejected,
--      withdrawn), the maker's reason (required from submit on, <= 300 characters), replaces_id, source (staff |
--      import | cost_sheet | provisional, d1; source_sha256 = the file of an import), the diff and impact frozen at
--      submit with the SHA-256 the checker approves (d9), and who made, approved, rejected or withdrew it when.
--      A guard trigger keeps a version's facts fixed once it leaves draft, moves the status only along d2 and lets a
--      published version and a superseded one swap (superseded is derived from the published set and recomputed by
--      the app on every publish and withdrawal, d2). Maker-checker in CHECKs: the approver and the rejecter are never
--      the maker. A version is never deleted (role booking has no DELETE).
--   2. booking.price_list_version_rows: the rows of a version, today's booking.trip_plan_prices row shape with its
--      dates half-open ([travel_from, travel_to), inside the version's window), and the row's own peak flag (kept for
--      a plan whose season calendar has no range yet: the old label-based peak until staff enter seasons). Written
--      only while the version is a draft (guard trigger); never updated.
--   3. booking.trip_plan_prices (the effective matrix every reader uses: tariff, RRP, from price, readiness) gains
--      version_id (the published version a hand row comes from; NULL for the cost sheet's computed rows) and
--      season_code (the season of the plan's season calendar on the row's dates, d4; bk-055 adds the calendars). Its
--      position cap rises from 200 to 1000: a row is cut where the calendar's season changes.
--   4. Data: every plan's history (booking.trip_plan_price_history, bk-039) becomes past versions, one per stored set
--      (source = its change_source), withdrawn by 'migration:bk-054' at the time the next set replaced it as a whole
--      (the old PUT replaced the whole set, so an older set never prices again); the rows in force today
--      (booking.trip_plan_prices) become each priced plan's latest version, published, and its hand rows point at it.
--      Nothing is deleted and no price changes: a quote or tariff read before and after this file answers the same.
--
-- Class: contract (root ADR 0017 d3): ALTERs on trip_plan_prices (columns, FK, CHECK) and rows written from existing
-- data, next to two new tables. So a migration-only PR (with bk-055) first, then the code PR raises readiness (MIG-4).
-- On Dev: Infra Migration Apply once every job table is idle (root ADR 0017a). Needs bk-032 / bk-039 / bk-047 (the
-- matrix and its history) and bk-050 (pricing_policy: the tariff year start of the migrated versions).
-- DM-7.1: both new tables have their row in the root data standards (root PR merged before the Infra copy).
-- DM-6.1: amounts and nets conf:commercial; label, reason, reject_reason and withdraw_reason pii:free_text (staff text
-- about a price; never traveller data by rule, tagged in case).
-- Erasure (DM-6.7): the guard lets one update set the label or a reason column to the fixed marker '[redacted]',
-- alone; it runs as
-- bk_owner in a reviewed DB Migrate run-script (root docs/legal/dsar-erasure-runbook.md).
-- Locks: ACCESS EXCLUSIVE on trip_plan_prices (tens of rows) for the nullable ADD COLUMNs and the CHECKs, SHARE ROW
-- EXCLUSIVE on trip_plans for the FK. lock_timeout 5s.
-- Re-runnable (the integration tests replay every file): IF NOT EXISTS, DROP CONSTRAINT / TRIGGER IF EXISTS before each
-- ADD / CREATE, CREATE OR REPLACE FUNCTION, the data step only for plans with no version yet, grants repeat.
-- Undo (a later bk- file, after the code is reverted): DROP the two triggers and functions, DROP TABLE of the rows and
-- the versions (trip_plan_prices.version_id first), DROP COLUMN version_id and season_code, restore the 200 cap.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('booking.trip_plan_prices') IS NULL OR to_regclass('booking.trip_plan_price_history') IS NULL
       OR to_regclass('booking.pricing_policy') IS NULL THEN
        RAISE EXCEPTION 'bk-054: needs bk-032, bk-039 and bk-050 first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-054' AND description NOT LIKE 'AA-1091 price list versions%') THEN
        RAISE EXCEPTION 'bk-054: the key bk-054 is already held by another migration: renumber one';
    END IF;
END $$;

-- ── 1. Versions ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.price_list_versions (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_plan_id     UUID NOT NULL REFERENCES booking.trip_plans (id),
    version_no       INTEGER NOT NULL,
    label            TEXT NOT NULL,
    tariff_year      SMALLINT NOT NULL,
    travel_from      DATE NOT NULL,
    travel_to        DATE NOT NULL,
    sale_from        DATE,
    sale_to          DATE,
    status           TEXT NOT NULL DEFAULT 'draft',
    source           TEXT NOT NULL DEFAULT 'staff',
    source_sha256    TEXT,
    reason           TEXT,
    replaces_id      UUID REFERENCES booking.price_list_versions (id),
    diff             JSONB,
    impact           JSONB,
    diff_sha256      TEXT,
    created_by       TEXT NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    submitted_at     TIMESTAMPTZ,
    approved_by      TEXT,
    approved_at      TIMESTAMPTZ,
    rejected_by      TEXT,
    rejected_at      TIMESTAMPTZ,
    reject_reason    TEXT,
    withdrawn_by     TEXT,
    withdrawn_at     TIMESTAMPTZ,
    withdraw_reason  TEXT,
    superseded_at    TIMESTAMPTZ,
    CONSTRAINT price_list_versions_no_chk CHECK (version_no >= 1),
    CONSTRAINT price_list_versions_text_chk CHECK (
        length(btrim(label)) BETWEEN 1 AND 80
        AND length(btrim(created_by)) BETWEEN 1 AND 128
        AND (reason IS NULL OR length(btrim(reason)) BETWEEN 1 AND 300)
        AND (reject_reason IS NULL OR length(btrim(reject_reason)) BETWEEN 1 AND 300)
        AND (withdraw_reason IS NULL OR length(btrim(withdraw_reason)) BETWEEN 1 AND 300)),
    CONSTRAINT price_list_versions_year_chk CHECK (tariff_year BETWEEN 2000 AND 2100),
    CONSTRAINT price_list_versions_window_chk CHECK (
        travel_to > travel_from
        AND (sale_from IS NULL OR sale_to IS NULL OR sale_to > sale_from)),
    CONSTRAINT price_list_versions_status_chk CHECK (
        status IN ('draft', 'pending', 'published', 'superseded', 'rejected', 'withdrawn')),
    CONSTRAINT price_list_versions_source_chk CHECK (
        source IN ('staff', 'import', 'cost_sheet', 'provisional')
        AND (source_sha256 IS NULL OR (source = 'import' AND source_sha256 ~ '^[0-9a-f]{64}$'))),
    CONSTRAINT price_list_versions_replaces_chk CHECK (replaces_id IS NULL OR replaces_id <> id),
    -- d2: a reason from submit on; the diff the checker approves is frozen at submit.
    CONSTRAINT price_list_versions_submitted_chk CHECK (
        status IN ('draft', 'withdrawn')
        OR (reason IS NOT NULL AND submitted_at IS NOT NULL AND diff IS NOT NULL AND impact IS NOT NULL
            AND diff_sha256 ~ '^[0-9a-f]{64}$')),
    -- Maker-checker: a second person approves or rejects; withdrawing a published version is the checker's.
    CONSTRAINT price_list_versions_approved_chk CHECK (
        (approved_by IS NULL) = (approved_at IS NULL)
        AND (approved_by IS NULL OR approved_by <> created_by)
        AND ((status IN ('published', 'superseded')) <= (approved_at IS NOT NULL))
        AND (approved_at IS NULL OR status IN ('published', 'superseded', 'withdrawn'))),
    CONSTRAINT price_list_versions_rejected_chk CHECK (
        (status = 'rejected') = (rejected_by IS NOT NULL)
        AND (rejected_by IS NULL) = (rejected_at IS NULL)
        AND (rejected_by IS NULL) = (reject_reason IS NULL)
        AND (rejected_by IS NULL OR rejected_by <> created_by)),
    CONSTRAINT price_list_versions_withdrawn_chk CHECK (
        (status = 'withdrawn') = (withdrawn_by IS NOT NULL)
        AND (withdrawn_by IS NULL) = (withdrawn_at IS NULL)
        AND (withdrawn_by IS NULL) = (withdraw_reason IS NULL)
        AND (withdrawn_by IS NULL OR withdrawn_by = created_by OR approved_at IS NOT NULL)),
    CONSTRAINT price_list_versions_superseded_chk CHECK ((status = 'superseded') = (superseded_at IS NOT NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS price_list_versions_no_uq ON booking.price_list_versions (trip_plan_id, version_no);
CREATE INDEX IF NOT EXISTS price_list_versions_plan_status_idx ON booking.price_list_versions (trip_plan_id, status);
CREATE INDEX IF NOT EXISTS price_list_versions_pending_idx
    ON booking.price_list_versions (submitted_at) WHERE status = 'pending';

COMMENT ON TABLE booking.price_list_versions IS
    'bk-054 (AA-1091, root ADR 0005b d1 / d2): one approved, immutable set of selling prices of one trip plan for one travel window [travel_from, travel_to). draft -> pending (diff + impact frozen) -> published by a second person -> superseded once newer published versions cover its whole window (derived, recomputed on every publish and withdrawal); rejected and withdrawn are final. Never deleted. The published versions build the hand rows of booking.trip_plan_prices (overlap rule: non-provisional first, then the latest approval, then the highest version_no).';
COMMENT ON COLUMN booking.price_list_versions.label IS
    'pii:free_text; the name staff give the version (for example "2027 v3"); staff text, never traveller data by rule.';
COMMENT ON COLUMN booking.price_list_versions.travel_from IS 'bk-054: first departure date the version prices.';
COMMENT ON COLUMN booking.price_list_versions.travel_to IS
    'bk-054 (d10): the day after the last departure date the version prices (half-open; the UI shows the inclusive last day).';
COMMENT ON COLUMN booking.price_list_versions.sale_from IS
    'bk-054: optional offer window: the first quote day the version may be used on (half-open with sale_to).';
COMMENT ON COLUMN booking.price_list_versions.reason IS
    'pii:free_text; why the maker made this version (required from submit on, at most 300 characters); staff text about a price, never traveller data by rule.';
COMMENT ON COLUMN booking.price_list_versions.reject_reason IS
    'pii:free_text; why the checker refused the version; staff text, never traveller data by rule.';
COMMENT ON COLUMN booking.price_list_versions.withdraw_reason IS
    'pii:free_text; why the version was withdrawn; staff text, never traveller data by rule.';
COMMENT ON COLUMN booking.price_list_versions.diff IS
    'conf:commercial; bk-054 (d9): per row old price -> new price and the change in percent, frozen at submit.';
COMMENT ON COLUMN booking.price_list_versions.impact IS
    'conf:commercial; bk-054 (d9): open quotes and departures in the travel window, frozen at submit.';
COMMENT ON COLUMN booking.price_list_versions.diff_sha256 IS
    'bk-054 (d9): SHA-256 of the frozen diff; the approve call carries the one the checker saw (409 on a mismatch).';

CREATE TABLE IF NOT EXISTS booking.price_list_version_rows (
    id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    version_id                    UUID NOT NULL REFERENCES booking.price_list_versions (id),
    position                      SMALLINT NOT NULL,
    channel                       TEXT NOT NULL,
    season                        TEXT,
    peak                          BOOLEAN NOT NULL DEFAULT false,
    travel_from                   DATE NOT NULL,
    travel_to                     DATE NOT NULL,
    pax_min                       SMALLINT NOT NULL,
    pax_max                       SMALLINT,
    currency                      CHAR(3) NOT NULL,
    amount                        NUMERIC(12, 2) NOT NULL,
    rrp_amount                    NUMERIC(12, 2),
    net_amount                    NUMERIC(12, 2),
    net_currency                  CHAR(3),
    effective_margin              NUMERIC(12, 4),
    priced_on                     DATE,
    overridden                    BOOLEAN NOT NULL DEFAULT false,
    computed                      BOOLEAN NOT NULL DEFAULT false,
    child_amount                  NUMERIC(12, 2),
    infant_amount                 NUMERIC(12, 2),
    single_supplement_amount      NUMERIC(12, 2),
    child_net_amount              NUMERIC(12, 2),
    infant_net_amount             NUMERIC(12, 2),
    single_supplement_net_amount  NUMERIC(12, 2),
    CONSTRAINT price_list_version_rows_position_uq UNIQUE (version_id, position),
    CONSTRAINT price_list_version_rows_position_chk CHECK (position BETWEEN 1 AND 1000),
    CONSTRAINT price_list_version_rows_channel_chk CHECK (channel IN ('b2c_tailor_made', 'fixed_departure', 'b2b')),
    CONSTRAINT price_list_version_rows_season_chk CHECK (season IS NULL OR length(btrim(season)) BETWEEN 1 AND 80),
    CONSTRAINT price_list_version_rows_dates_chk CHECK (travel_to > travel_from),
    CONSTRAINT price_list_version_rows_pax_chk CHECK (
        pax_min BETWEEN 1 AND 999 AND (pax_max IS NULL OR (pax_max BETWEEN 1 AND 999 AND pax_max >= pax_min))),
    CONSTRAINT price_list_version_rows_money_chk CHECK (
        currency ~ '^[A-Z]{3}$' AND amount > 0 AND (rrp_amount IS NULL OR (channel = 'b2b' AND rrp_amount > 0))
        AND ((net_amount IS NULL AND net_currency IS NULL AND effective_margin IS NULL AND priced_on IS NULL)
             OR (net_amount IS NOT NULL AND net_currency IS NOT NULL AND priced_on IS NOT NULL AND net_amount >= 0
                 AND net_currency ~ '^[A-Z]{3}$'))
        AND (NOT overridden OR net_amount IS NOT NULL) AND (NOT computed OR net_amount IS NOT NULL)
        AND (child_amount IS NULL OR child_amount >= 0) AND (infant_amount IS NULL OR infant_amount >= 0)
        AND (single_supplement_amount IS NULL OR single_supplement_amount >= 0)
        AND (child_net_amount IS NULL OR (child_net_amount >= 0 AND net_amount IS NOT NULL))
        AND (infant_net_amount IS NULL OR (infant_net_amount >= 0 AND net_amount IS NOT NULL))
        AND (single_supplement_net_amount IS NULL OR (single_supplement_net_amount >= 0 AND net_amount IS NOT NULL)))
);

COMMENT ON TABLE booking.price_list_version_rows IS
    'bk-054 (AA-1091, root ADR 0005b d1): the per-person selling prices of one price list version (channel x dates x pax band x currency), the booking.trip_plan_prices row shape with half-open dates [travel_from, travel_to) inside the version window. Written only while the version is a draft; never updated.';
COMMENT ON COLUMN booking.price_list_version_rows.amount IS 'conf:commercial; selling price per person.';
COMMENT ON COLUMN booking.price_list_version_rows.rrp_amount IS 'conf:commercial; suggested retail price per person (b2b) when the version was written.';
COMMENT ON COLUMN booking.price_list_version_rows.net_amount IS 'conf:commercial; net cost per person the row was priced from.';
COMMENT ON COLUMN booking.price_list_version_rows.net_currency IS 'conf:commercial; currency of net_amount.';
COMMENT ON COLUMN booking.price_list_version_rows.effective_margin IS 'conf:commercial; margin of amount over the net cost.';
COMMENT ON COLUMN booking.price_list_version_rows.child_amount IS 'conf:commercial; price per child.';
COMMENT ON COLUMN booking.price_list_version_rows.infant_amount IS 'conf:commercial; price per infant.';
COMMENT ON COLUMN booking.price_list_version_rows.single_supplement_amount IS 'conf:commercial; single supplement per person.';
COMMENT ON COLUMN booking.price_list_version_rows.child_net_amount IS 'conf:commercial; net behind child_amount.';
COMMENT ON COLUMN booking.price_list_version_rows.infant_net_amount IS 'conf:commercial; net behind infant_amount.';
COMMENT ON COLUMN booking.price_list_version_rows.single_supplement_net_amount IS 'conf:commercial; net behind the single supplement.';
COMMENT ON COLUMN booking.price_list_version_rows.peak IS
    'bk-054: the row''s peak flag as written (migrated from the matrix or the history). Read only while the plan''s season calendar has no range: then it keeps the peak uplift and the matrix flag of before bk-055; once the calendar has ranges, the calendar decides (ADR 0005b d4).';
COMMENT ON COLUMN booking.price_list_version_rows.computed IS
    'bk-054: a row the cost sheet computed, kept in a version migrated from the price history (a snapshot); staff drafts never hold one.';

-- The guards are created after the data step (it writes migrated versions that never were drafts).
DROP TRIGGER IF EXISTS price_list_versions_guard ON booking.price_list_versions;
DROP TRIGGER IF EXISTS price_list_version_rows_guard ON booking.price_list_version_rows;

-- ── 2. The effective matrix: version and season of each row ─────────────────

ALTER TABLE booking.trip_plan_prices
    ADD COLUMN IF NOT EXISTS version_id UUID REFERENCES booking.price_list_versions (id),
    ADD COLUMN IF NOT EXISTS season_code TEXT;
ALTER TABLE booking.trip_plan_prices DROP CONSTRAINT IF EXISTS trip_plan_prices_season_code_chk;
ALTER TABLE booking.trip_plan_prices ADD CONSTRAINT trip_plan_prices_season_code_chk CHECK (
    season_code IS NULL OR season_code IN ('low', 'high', 'peak', 'festive'));
ALTER TABLE booking.trip_plan_prices DROP CONSTRAINT IF EXISTS trip_plan_prices_position_chk;
ALTER TABLE booking.trip_plan_prices ADD CONSTRAINT trip_plan_prices_position_chk CHECK (position BETWEEN 1 AND 1000);
CREATE INDEX IF NOT EXISTS trip_plan_prices_version_idx
    ON booking.trip_plan_prices (version_id) WHERE version_id IS NOT NULL;
COMMENT ON COLUMN booking.trip_plan_prices.version_id IS
    'bk-054 (AA-1091, root ADR 0005b d1): the published price list version a hand row comes from (cut to the dates that version wins by the overlap rule); NULL for a row the cost sheet computed.';
COMMENT ON COLUMN booking.trip_plan_prices.season_code IS
    'bk-054 (root ADR 0005b d4): the season of the plan''s season calendar on the row''s dates (low, high, peak, festive); a row is cut where the season changes. NULL = no calendar read yet (the default season applies).';

-- ── 3. Data: history -> past versions, the rows in force -> the latest version ─

DO $$
DECLARE
    start_md   text;
    plan       record;
    batch      record;
    vid        uuid;
    vno        integer;
    w_from     date;
    w_to       date;
    v_source   text;
    v_by       text;
    v_at       timestamptz;
    next_at    timestamptz;
BEGIN
    -- The tariff year start approved in force today (bk-050, Q1); a version's tariff year is the year its tariff year
    -- ends in (a window from 1 November 2026 is tariff year 2027 with the default 11-01).
    SELECT p.value #>> '{}' INTO start_md
      FROM booking.pricing_policy p
      JOIN booking.pricing_policy_events e ON e.policy_id = p.id AND e.event = 'approved'
     WHERE p.param_key = 'tariff_year_start' AND p.effective_from <= current_date
     ORDER BY p.effective_from DESC, e.created_at DESC, p.version_no DESC
     LIMIT 1;
    IF start_md IS NULL OR start_md !~ '^[0-9]{2}-[0-9]{2}$' THEN
        RAISE EXCEPTION 'bk-054: no approved tariff_year_start in booking.pricing_policy (bk-050)';
    END IF;

    FOR plan IN
        SELECT tp.id
          FROM booking.trip_plans tp
         WHERE (EXISTS (SELECT 1 FROM booking.trip_plan_prices r WHERE r.trip_plan_id = tp.id)
                OR EXISTS (SELECT 1 FROM booking.trip_plan_price_history h WHERE h.trip_plan_id = tp.id))
           AND NOT EXISTS (SELECT 1 FROM booking.price_list_versions v WHERE v.trip_plan_id = tp.id)
         ORDER BY tp.id
    LOOP
        vno := 0;
        -- Past sets: one version per closed history set, withdrawn when the next set replaced it as a whole.
        FOR batch IN
            SELECT h.effective_from, max(h.effective_to) AS effective_to, min(h.change_source) AS change_source,
                   min(h.changed_by) AS changed_by, min(h.valid_from) AS w_from, max(h.valid_to) + 1 AS w_to
              FROM booking.trip_plan_price_history h
             WHERE h.trip_plan_id = plan.id AND h.effective_to IS NOT NULL
             GROUP BY h.effective_from
             ORDER BY h.effective_from
        LOOP
            vno := vno + 1;
            next_at := greatest(batch.effective_to, batch.effective_from);
            INSERT INTO booking.price_list_versions (
                trip_plan_id, version_no, label, tariff_year, travel_from, travel_to, status, source, reason,
                diff, impact, diff_sha256, created_by, created_at, updated_at, submitted_at, approved_by, approved_at,
                withdrawn_by, withdrawn_at, withdraw_reason)
            VALUES (
                plan.id, vno, 'v' || vno || ' (before versions)',
                (extract(year FROM batch.w_from)::int
                 + CASE WHEN to_char(batch.w_from, 'MM-DD') >= start_md THEN 1 ELSE 0 END)::smallint,
                batch.w_from, batch.w_to, 'withdrawn', batch.change_source,
                'Price set entered before price versions; migrated from the price history by bk-054.',
                '{"rows": [], "migrated": true}'::jsonb, '{"migrated": true}'::jsonb,
                encode(sha256('{"migrated": true, "rows": []}'::bytea), 'hex'),
                batch.changed_by, batch.effective_from, next_at, batch.effective_from, 'migration:bk-054',
                batch.effective_from, 'migration:bk-054', next_at,
                'Replaced as a whole by a later price set before price versions (bk-054).')
            RETURNING id INTO vid;
            INSERT INTO booking.price_list_version_rows (
                version_id, position, channel, season, peak, travel_from, travel_to, pax_min, pax_max, currency, amount,
                rrp_amount, net_amount, net_currency, effective_margin, overridden, computed, priced_on)
            SELECT vid, row_number() OVER (ORDER BY h.channel, h.valid_from, h.pax_min, h.currency, h.id),
                   h.channel, h.season, h.peak, h.valid_from, h.valid_to + 1, h.pax_min, h.pax_max, h.currency, h.amount,
                   h.rrp_amount, h.net_amount, h.net_currency, h.effective_margin, h.overridden, h.computed,
                   CASE WHEN h.net_amount IS NULL THEN NULL ELSE h.effective_from::date END
              FROM booking.trip_plan_price_history h
             WHERE h.trip_plan_id = plan.id AND h.effective_from = batch.effective_from
               AND h.effective_to IS NOT NULL;
        END LOOP;

        -- The rows in force today: the latest version, published, with the facts of the open history set when there
        -- is one (the set it was stored as), else of the rows themselves.
        IF EXISTS (SELECT 1 FROM booking.trip_plan_prices r WHERE r.trip_plan_id = plan.id) THEN
            SELECT min(r.valid_from), max(r.valid_to) + 1 INTO w_from, w_to
              FROM booking.trip_plan_prices r WHERE r.trip_plan_id = plan.id;
            SELECT min(h.change_source), min(h.changed_by), min(h.effective_from) INTO v_source, v_by, v_at
              FROM booking.trip_plan_price_history h
             WHERE h.trip_plan_id = plan.id AND h.effective_to IS NULL;
            IF v_source IS NULL THEN
                SELECT CASE WHEN bool_and(r.computed AND NOT r.overridden) THEN 'cost_sheet' ELSE 'staff' END,
                       coalesce(max(r.created_by), 'system:bk_price_recompute'), max(r.created_at)
                  INTO v_source, v_by, v_at
                  FROM booking.trip_plan_prices r WHERE r.trip_plan_id = plan.id;
            END IF;
            vno := vno + 1;
            INSERT INTO booking.price_list_versions (
                trip_plan_id, version_no, label, tariff_year, travel_from, travel_to, status, source, reason,
                diff, impact, diff_sha256, created_by, created_at, updated_at, submitted_at, approved_by, approved_at)
            VALUES (
                plan.id, vno, 'v' || vno || ' (in force before versions)',
                (extract(year FROM w_from)::int
                 + CASE WHEN to_char(w_from, 'MM-DD') >= start_md THEN 1 ELSE 0 END)::smallint,
                w_from, w_to, 'published', v_source,
                'Prices in force before price versions; migrated by bk-054.',
                '{"rows": [], "migrated": true}'::jsonb, '{"migrated": true}'::jsonb,
                encode(sha256('{"migrated": true, "rows": []}'::bytea), 'hex'),
                v_by, v_at, now(), v_at, 'migration:bk-054', v_at)
            RETURNING id INTO vid;
            INSERT INTO booking.price_list_version_rows (
                version_id, position, channel, season, peak, travel_from, travel_to, pax_min, pax_max, currency, amount,
                rrp_amount, net_amount, net_currency, effective_margin, priced_on, overridden, computed,
                child_amount, infant_amount, single_supplement_amount, child_net_amount, infant_net_amount,
                single_supplement_net_amount)
            SELECT vid, r.position, r.channel, r.season, r.peak, r.valid_from, r.valid_to + 1, r.pax_min, r.pax_max,
                   r.currency, r.amount, r.rrp_amount, r.net_amount, r.net_currency, r.effective_margin, r.priced_on,
                   r.overridden, r.computed, r.child_amount, r.infant_amount, r.single_supplement_amount,
                   r.child_net_amount, r.infant_net_amount, r.single_supplement_net_amount
              FROM booking.trip_plan_prices r WHERE r.trip_plan_id = plan.id;
            -- Hand rows (not computed, or computed and overridden by staff) point at the version they came from; the
            -- cost sheet's computed rows stay NULL (it rewrites them).
            UPDATE booking.trip_plan_prices r SET version_id = vid
             WHERE r.trip_plan_id = plan.id AND (NOT r.computed OR r.overridden);
        END IF;
    END LOOP;
END $$;

-- ── 4. Guards ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION booking.price_list_versions_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'draft' OR NEW.approved_at IS NOT NULL OR NEW.rejected_at IS NOT NULL
           OR NEW.withdrawn_at IS NOT NULL OR NEW.submitted_at IS NOT NULL THEN
            RAISE EXCEPTION 'a price list version starts as a draft' USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.replaces_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM booking.price_list_versions v
             WHERE v.id = NEW.replaces_id AND v.trip_plan_id = NEW.trip_plan_id) THEN
            RAISE EXCEPTION 'a price list version replaces one of the same trip plan' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    -- Erasure (DM-6.7): the label and the reason columns may be set to the fixed marker, nothing else in the same
    -- update.
    IF (to_jsonb(NEW) - 'label' - 'reason' - 'reject_reason' - 'withdraw_reason')
       = (to_jsonb(OLD) - 'label' - 'reason' - 'reject_reason' - 'withdraw_reason')
       AND (NEW.label IS NOT DISTINCT FROM OLD.label OR NEW.label = '[redacted]')
       AND (NEW.reason IS NOT DISTINCT FROM OLD.reason OR NEW.reason = '[redacted]')
       AND (NEW.reject_reason IS NOT DISTINCT FROM OLD.reject_reason OR NEW.reject_reason = '[redacted]')
       AND (NEW.withdraw_reason IS NOT DISTINCT FROM OLD.withdraw_reason OR NEW.withdraw_reason = '[redacted]') THEN
        RETURN NEW;
    END IF;
    IF (NEW.trip_plan_id, NEW.version_no, NEW.created_by, NEW.created_at, NEW.source, NEW.source_sha256)
       IS DISTINCT FROM (OLD.trip_plan_id, OLD.version_no, OLD.created_by, OLD.created_at, OLD.source,
                         OLD.source_sha256) THEN
        RAISE EXCEPTION 'price list version %: its plan, number, maker and source never change', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status IN ('rejected', 'withdrawn') THEN
        RAISE EXCEPTION 'price list version % is %; it is final', OLD.id, OLD.status USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status <> 'draft' AND (NEW.label, NEW.tariff_year, NEW.travel_from, NEW.travel_to, NEW.sale_from,
                                  NEW.sale_to, NEW.reason, NEW.replaces_id, NEW.diff, NEW.impact, NEW.diff_sha256,
                                  NEW.submitted_at)
                                 IS DISTINCT FROM
                                 (OLD.label, OLD.tariff_year, OLD.travel_from, OLD.travel_to, OLD.sale_from,
                                  OLD.sale_to, OLD.reason, OLD.replaces_id, OLD.diff, OLD.impact, OLD.diff_sha256,
                                  OLD.submitted_at) THEN
        RAISE EXCEPTION 'price list version % is not a draft: its prices and facts never change (make a new version)',
            OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.approved_at IS NOT NULL AND (NEW.approved_at, NEW.approved_by) IS DISTINCT FROM (OLD.approved_at,
                                                                                         OLD.approved_by) THEN
        RAISE EXCEPTION 'price list version %: approved once', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
        (OLD.status = 'draft' AND NEW.status IN ('pending', 'withdrawn'))
        OR (OLD.status = 'pending' AND NEW.status IN ('published', 'rejected', 'withdrawn'))
        OR (OLD.status = 'published' AND NEW.status IN ('superseded', 'withdrawn'))
        OR (OLD.status = 'superseded' AND NEW.status = 'published')) THEN
        RAISE EXCEPTION 'price list version %: % -> % is not a move of its life (ADR 0005b d2)', OLD.id, OLD.status,
            NEW.status USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.price_list_versions_guard() IS
    'bk-054 (AA-1091): a price list version starts as a draft and replaces only one of the same plan; its plan, number, maker and source never change; its facts change only while a draft; approved once; the status moves only along ADR 0005b d2 (published <-> superseded is derived); rejected and withdrawn are final; on erasure (DM-6.7) the label and the reasons may be set to [redacted], alone.';

CREATE TRIGGER price_list_versions_guard
    BEFORE INSERT OR UPDATE ON booking.price_list_versions
    FOR EACH ROW EXECUTE FUNCTION booking.price_list_versions_guard();

CREATE OR REPLACE FUNCTION booking.price_list_version_rows_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_status text;
    target   uuid;
BEGIN
    target := CASE WHEN TG_OP = 'DELETE' THEN OLD.version_id ELSE NEW.version_id END;
    SELECT v.status INTO v_status FROM booking.price_list_versions v WHERE v.id = target;
    IF v_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'the rows of price list version % change only while it is a draft', target
            USING ERRCODE = 'check_violation';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    IF NEW.computed THEN
        RAISE EXCEPTION 'a draft price list version holds no computed row' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.price_list_version_rows_guard() IS
    'bk-054 (AA-1091): the rows of a price list version are written and removed only while the version is a draft; a draft holds no computed row.';

CREATE TRIGGER price_list_version_rows_guard
    BEFORE INSERT OR DELETE ON booking.price_list_version_rows
    FOR EACH ROW EXECUTE FUNCTION booking.price_list_version_rows_guard();

-- ── 5. Grants ────────────────────────────────────────────────────────────────

REVOKE ALL ON booking.price_list_versions FROM booking;
GRANT SELECT, INSERT ON booking.price_list_versions TO booking;
GRANT UPDATE (label, tariff_year, travel_from, travel_to, sale_from, sale_to, status, reason, replaces_id, diff, impact,
              diff_sha256, updated_at, submitted_at, approved_by, approved_at, rejected_by, rejected_at, reject_reason,
              withdrawn_by, withdrawn_at, withdraw_reason, superseded_at)
    ON booking.price_list_versions TO booking;
REVOKE ALL ON booking.price_list_version_rows FROM booking;
GRANT SELECT, INSERT, DELETE ON booking.price_list_version_rows TO booking;
GRANT EXECUTE ON FUNCTION booking.price_list_versions_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.price_list_version_rows_guard() TO booking;
-- trip_plan_prices: the bk-032 table grant (SELECT, INSERT, DELETE) covers the new columns.

DO $$
BEGIN
    IF has_table_privilege('booking', 'booking.price_list_versions', 'DELETE')
       OR has_table_privilege('booking', 'booking.price_list_versions', 'TRUNCATE')
       OR has_column_privilege('booking', 'booking.price_list_versions', 'created_by', 'UPDATE')
       OR has_column_privilege('booking', 'booking.price_list_versions', 'trip_plan_id', 'UPDATE')
       OR has_table_privilege('booking', 'booking.price_list_version_rows', 'UPDATE')
       OR has_table_privilege('booking', 'booking.price_list_version_rows', 'TRUNCATE') THEN
        RAISE EXCEPTION 'bk-054: role booking can delete a version or rewrite its maker, plan or rows';
    END IF;
    IF NOT has_column_privilege('booking', 'booking.trip_plan_prices', 'version_id', 'INSERT') THEN
        RAISE EXCEPTION 'bk-054: role booking cannot write the version of a matrix row';
    END IF;
    IF EXISTS (SELECT 1 FROM booking.trip_plan_prices r
                WHERE (NOT r.computed OR r.overridden) AND r.version_id IS NULL) THEN
        RAISE EXCEPTION 'bk-054: a hand row of the price matrix has no version';
    END IF;
    IF EXISTS (SELECT 1 FROM booking.trip_plan_prices r
                WHERE NOT EXISTS (SELECT 1 FROM booking.price_list_versions v
                                   WHERE v.trip_plan_id = r.trip_plan_id AND v.status = 'published')) THEN
        RAISE EXCEPTION 'bk-054: a priced plan has no published version';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-054', now(), 'AA-1091 price list versions: price_list_versions + rows (draft / pending / published / superseded / rejected / withdrawn, maker-checker, frozen diff and impact), trip_plan_prices.version_id + season_code, history and rows in force migrated into versions')
ON CONFLICT (version) DO NOTHING;

COMMIT;
