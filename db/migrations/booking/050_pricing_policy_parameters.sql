-- Migration bk-050: AA-1091 (S278) — pricing policy parameters as versioned staff data (root ADR 0005b decision 15).
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/050_pricing_policy_parameters.sql and Migration Apply applies it on Dev as bk_owner (the
-- runner's role switch, live owner of schema booking since bk-014) once every job table is idle. Never run it from a
-- laptop.
--
-- Why: the tech lead approved the pricing policy on 2026-11-12 (S278) and ruled that every business policy value is
-- adjustable on a Booking staff page, never a constant in code. Each scalar answer is one named parameter; the code
-- holds only its key, type and allowed range (backend/app/pricing/policy_params.py), the value lives here.
--
-- What (new tables only; the seed rows go into them):
--   * pricing_policy         one row per version of one parameter: the typed value (jsonb), its unit, the day it
--                            takes effect, the maker's reason (required), the version it replaces and the frozen diff
--                            (old -> new value). Append-only: role booking may INSERT and SELECT, never UPDATE or
--                            DELETE (REVOKEd below), so a value is never edited once written.
--   * pricing_policy_events  the life of a version, one row per step: submitted (by its maker), approved or rejected
--                            (by a second person: CHECK actor <> maker), withdrawn (by its maker). The maker is copied
--                            and pinned by a composite FK to (pricing_policy.id, created_by), so the CHECK compares the
--                            real maker. Each step at most once per version, at most one final step (approved,
--                            rejected or withdrawn). Append-only like the versions.
--   Status, derived (app/pricing/policy_admin.py): draft (no step yet), pending (submitted), published (approved:
--   in force, scheduled or superseded by date), rejected, withdrawn.
--   * Seed: version 1 of the 20 parameters with the answers the tech lead approved on 2026-11-12, made by the
--     migration ('seed:bk-050') and approved by 'tech lead S278'. They take effect on 2026-01-01 so that every quote
--     day the system can still meet finds a value; a later change is a new version with its own effective day.
--
-- Not here: the margins per channel (booking.pricing_rules), the cancellation scale (booking.cancellation_policies),
-- the deposit terms (booking.billing_terms), the agency tiers (booking.partner_tiers) and the seasons (season
-- calendars, a later file): they already are staff data with their own pages. bk-051 adds the S278 margins and
-- cancellation scale as new approved rows of those tables (contract: rows into existing tables).
--
-- Class: contract (root ADR 0017 d3): two new tables with their seed rows, plus a REVOKE of UPDATE / DELETE / TRUNCATE
-- from role booking (the schema's default privileges grant them on every new table; a REVOKE is not expand). So a
-- migration-only PR first (MIG-4, with bk-051), then the code PR raises readiness to bk-050. On Dev: Infra Migration
-- Apply once every job table is idle (root ADR 0017a). No function, trigger or DO block.
-- DM-7.1: both tables have their row in the root data standards (root PR merged before the Infra copy).
-- DM-6.1: no personal data. reason is staff text about a price policy (tagged pii:free_text in case); values are
-- conf:commercial.
-- Locks: none on existing tables (new tables only).
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS, ON CONFLICT DO NOTHING, grants and revokes
-- repeat.
-- Undo (a later bk- file, after the code is reverted and no row matters): DROP TABLE of the two tables.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS booking.pricing_policy (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    param_key       text NOT NULL,
    version_no      integer NOT NULL,
    value           jsonb NOT NULL,
    unit            text,
    effective_from  date NOT NULL,
    reason          text NOT NULL,
    replaces_id     uuid REFERENCES booking.pricing_policy (id),
    diff            jsonb,
    created_by      text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pricing_policy_key_chk CHECK (param_key ~ '^[a-z][a-z0-9_]{2,63}$'),
    CONSTRAINT pricing_policy_version_chk CHECK (version_no >= 1 AND (version_no = 1) = (replaces_id IS NULL)),
    CONSTRAINT pricing_policy_value_chk CHECK (
        jsonb_typeof(value) IN ('number', 'string', 'boolean', 'array', 'object') AND length(value::text) <= 2000),
    CONSTRAINT pricing_policy_text_chk CHECK (
        length(btrim(reason)) BETWEEN 1 AND 300
        AND (unit IS NULL OR length(btrim(unit)) BETWEEN 1 AND 40)
        AND length(btrim(created_by)) BETWEEN 1 AND 128),
    CONSTRAINT pricing_policy_diff_chk CHECK (diff IS NULL OR jsonb_typeof(diff) = 'object')
);
CREATE UNIQUE INDEX IF NOT EXISTS pricing_policy_key_version_uq ON booking.pricing_policy (param_key, version_no);
-- The target of the events' composite FK: an event names the version AND its maker.
CREATE UNIQUE INDEX IF NOT EXISTS pricing_policy_id_maker_uq ON booking.pricing_policy (id, created_by);
CREATE INDEX IF NOT EXISTS pricing_policy_key_effective_idx ON booking.pricing_policy (param_key, effective_from DESC);
COMMENT ON TABLE booking.pricing_policy IS
    'AA-1091 (bk-050, root ADR 0005b d15): one version of one pricing policy parameter (quote validity, surcharge '
    'rules, auto-publish threshold, provisional uplift, group size, deposits, ...). Append-only; a version prices '
    'nothing until a second person approves it (booking.pricing_policy_events). Keys, types and allowed ranges: '
    'backend/app/pricing/policy_params.py; the value is never a constant in code.';
COMMENT ON COLUMN booking.pricing_policy.value IS
    'conf:commercial; the typed value: a JSON number (integer parameters), a decimal as a JSON string ("5" = 5 %), '
    'a boolean, a month-day string "MM-DD", a list of those, a set of codes or a country -> currency map.';
COMMENT ON COLUMN booking.pricing_policy.reason IS
    'pii:free_text; why the maker changes the value (required, at most 300 characters); staff text about a price '
    'policy, never traveller data by rule.';
COMMENT ON COLUMN booking.pricing_policy.effective_from IS
    'The first day the value applies to new quotes, versions and tariffs; never before the day it is proposed.';
COMMENT ON COLUMN booking.pricing_policy.diff IS
    'conf:commercial; frozen when the version is written: {"from": <value of the version it replaces>, "to": <value>}.';

CREATE TABLE IF NOT EXISTS booking.pricing_policy_events (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_id   uuid NOT NULL,
    maker       text NOT NULL,
    event       text NOT NULL,
    actor       text NOT NULL,
    reason      text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pricing_policy_events_version_fk FOREIGN KEY (policy_id, maker)
        REFERENCES booking.pricing_policy (id, created_by),
    CONSTRAINT pricing_policy_events_event_chk CHECK (event IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    -- Maker-checker: the maker submits and withdraws; a second person approves or rejects (with a reason).
    CONSTRAINT pricing_policy_events_actor_chk CHECK (
        (event IN ('submitted', 'withdrawn') AND actor = maker)
        OR (event = 'approved' AND actor <> maker)
        OR (event = 'rejected' AND actor <> maker AND reason IS NOT NULL)),
    CONSTRAINT pricing_policy_events_text_chk CHECK (
        length(btrim(actor)) BETWEEN 1 AND 128
        AND (reason IS NULL OR length(btrim(reason)) BETWEEN 1 AND 300))
);
CREATE UNIQUE INDEX IF NOT EXISTS pricing_policy_events_step_uq ON booking.pricing_policy_events (policy_id, event);
CREATE UNIQUE INDEX IF NOT EXISTS pricing_policy_events_final_uq ON booking.pricing_policy_events (policy_id)
    WHERE event IN ('approved', 'rejected', 'withdrawn');
COMMENT ON TABLE booking.pricing_policy_events IS
    'AA-1091 (bk-050): the steps of a pricing policy version: submitted and withdrawn by its maker, approved or '
    'rejected by a second person (CHECK actor <> maker). Append-only; at most one final step per version.';
COMMENT ON COLUMN booking.pricing_policy_events.reason IS
    'pii:free_text; why a checker rejected the version (required on reject); staff text, never traveller data.';

-- ── Seed: version 1, the answers the tech lead approved on 2026-11-12 (S278) ────────────────────────────────────

INSERT INTO booking.pricing_policy (id, param_key, version_no, value, unit, effective_from, reason, created_by) VALUES
    ('00000000-0000-4000-8000-0000000b5001', 'tariff_year_start', 1, '"11-01"', 'MM-DD', DATE '2026-01-01',
     'Q1: the agency tariff year runs 1 November to 31 October (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5002', 'tariff_next_publish_by', 1, '"08-31"', 'MM-DD', DATE '2026-01-01',
     'Q1: the next tariff year is published by the end of August (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5003', 'quote_validity_days', 1, '14', 'days', DATE '2026-01-01',
     'Q2: a B2B quote is valid 14 days (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5004', 'quote_validity_festive_days', 1, '3', 'days', DATE '2026-01-01',
     'Q2: 3 days when the trip touches a festive period: Tet, Christmas, New Year (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5005', 'surcharge_causes', 1, '["fx", "tax"]', NULL, DATE '2026-01-01',
     'Q3: after confirmation only government tax and an FX move may add a surcharge line (approved S278).',
     'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5006', 'surcharge_fx_threshold_pct', 1, '"5"', '%', DATE '2026-01-01',
     'Q3: an FX move counts above 5 % against the rate locked on the booking (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5007', 'surcharge_notice_days', 1, '20', 'days', DATE '2026-01-01',
     'Q3: at least 20 days notice before departure, both ways (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5008', 'surcharge_free_cancel_pct', 1, '"8"', '%', DATE '2026-01-01',
     'Q3: above 8 % of the booking price the agency may cancel free of charge (ADR 0005b default).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5009', 'recompute_auto_publish_pct', 1, '"3"', '%', DATE '2026-01-01',
     'Q4: a recompute within plus or minus 3 % per row publishes by itself (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5010', 'diff_highlight_pct', 1, '"10"', '%', DATE '2026-01-01',
     'ADR 0005b d9: diff rows that move more than 10 % are highlighted for the checker.', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5011', 'provisional_uplift_pct', 1, '"5"', '%', DATE '2026-01-01',
     'Q12: a provisional price is last year''s same-season price plus 5 % (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5012', 'provisional_cis_ref_quotable', 1, 'false', NULL, DATE '2026-01-01',
     'Q12: a provisional price from the CIS reference is display only, never quoted (approved S278).',
     'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5013', 'group_on_request_min_pax', 1, '9', 'travellers', DATE '2026-01-01',
     'Q9: groups of 9 travellers or more are quoted on request (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5014', 'foc_one_per_pax', 1, '15', 'travellers', DATE '2026-01-01',
     'Q9: free places per supplier contract, by default one per 15 travellers (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5015', 'fit_full_payment_days', 1, '30', 'days', DATE '2026-01-01',
     'Q8: an individual (FIT) booking is paid in full 30 days before departure (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5016', 'group_deposit_pct', 1, '"25"', '%', DATE '2026-01-01',
     'Q8: a group pays a 25 % deposit (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5017', 'group_deposit_days', 1, '56', 'days', DATE '2026-01-01',
     'Q8: the group deposit is due 8 weeks (56 days) before departure (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5018', 'festive_non_refundable_days', 1, '30', 'days', DATE '2026-01-01',
     'Q8: a festive-period booking is non-refundable within 30 days of departure (approved S278).', 'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5019', 'gala_dinner_days', 1, '["12-24", "12-31"]', 'MM-DD',
     DATE '2026-01-01',
     'Q7: compulsory gala dinners on 24 and 31 December, charged at cost plus the standard margin (approved S278).',
     'seed:bk-050'),
    ('00000000-0000-4000-8000-0000000b5020', 'agency_currency_by_country', 1, '{"*": "USD", "VN": "VND"}', NULL,
     DATE '2026-01-01',
     'Q11: USD for foreign agencies, VND for Vietnamese agencies; FX locked at the quote (approved S278).',
     'seed:bk-050')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT ('00000000-0000-4000-8000-0000000b6' || right(p.id::text, 3))::uuid, p.id, p.created_by, 'submitted',
       p.created_by
FROM booking.pricing_policy p
WHERE p.created_by = 'seed:bk-050'
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT ('00000000-0000-4000-8000-0000000b7' || right(p.id::text, 3))::uuid, p.id, p.created_by, 'approved',
       'tech lead S278'
FROM booking.pricing_policy p
WHERE p.created_by = 'seed:bk-050'
ON CONFLICT DO NOTHING;

-- ── Grants: append-only for the runtime role ──────────────────────────────────────────────────────────────────────

GRANT SELECT, INSERT ON booking.pricing_policy TO booking;
GRANT SELECT, INSERT ON booking.pricing_policy_events TO booking;
REVOKE UPDATE, DELETE, TRUNCATE ON booking.pricing_policy, booking.pricing_policy_events FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-050', now(), 'AA-1091: pricing policy parameters (versioned, maker-checker) with the S278 seed')
ON CONFLICT (version) DO NOTHING;

COMMIT;
