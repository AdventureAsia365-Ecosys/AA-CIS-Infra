-- Migration crm-062: AA-1092 (S278 pre-PII review, residual item: Book now price checks per agency) — the agency's
-- ceiling of "Book now" price checks a minute, an editable setting.
--
-- Owner: AA-Partner (api/migrations/062_crm_book_now_price_ceiling.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy Migration Apply runs (Migration Copy Guard). Key crm-062 (crm-062..065 belong to other cards of the same wave and
-- are independent: no object of theirs is used here); if main moves, renumber: file name, this header, Guard 0 and the
-- registration below, app/db.py REQUIRED_SCHEMA_VERSIONS and the tests that name it (git grep '066_' and 'crm-062').
--
-- Why: POST /crm/public/v1/book/{key}/price asks AA-Booking for a live quote on every call. It is bounded per client
-- address (RATE_LIMIT_BOOKING_PRICE_PER_MINUTE, 20) but not per agency, so many addresses together could make one
-- agency's page send an unbounded number of quotes to Booking. The ceiling per agency is a policy value (tech lead rule
-- S278: business and policy values are data with a page to change them, never literals in code), so it is a column of
-- the agency's settings that the owner changes on Settings > Payments "Online booking".
--
-- What: crm.tenant_settings.public_price_per_minute (SMALLINT, NOT NULL, default 60, CHECK 10..600): the price checks a
-- minute the agency's Book now takes from every address together; past it the price check answers 429
-- agency_rate_limited with Retry-After. The count lives in each API task's memory (the CRM API has no shared limiter
-- store; one task on Dev), so with N tasks the agency gets up to N x this value: the default and the bounds are sized
-- for one or two tasks. Not personal data.
--
-- Behaviour on apply: none. Every existing settings row gets 60; no code reads the column until the AA-Partner code PR
-- (readiness crm-062) deploys.
--
-- Class: contract (ALTER of crm.tenant_settings, a new CHECK on it). MIG-4: this migration-only PR, then the code PR
-- once it is applied on Dev. No new table (no DM-7.1 row), no crm.erase_subject change (a setting, not personal data).
--
-- Rollback (a NEW forward migration, after the code is reverted): ALTER TABLE crm.tenant_settings DROP CONSTRAINT
-- tenant_settings_public_price_chk, DROP COLUMN public_price_per_minute.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (IF NOT EXISTS, DROP …
-- IF EXISTS before the ADD CONSTRAINT, ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

-- ── Guard 0: runs as the owner, after crm-057 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-062: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-057') THEN
        RAISE EXCEPTION 'crm-062: crm-057 (AA-1072 Book now, tenant_settings.public_booking_enabled) lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-062' AND description NOT LIKE 'AA-1092: Book now price ceiling%') THEN
        RAISE EXCEPTION 'crm-062: the key crm-062 is already held by another migration (not AA-1092): renumber one';
    END IF;
END $$;

ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS public_price_per_minute SMALLINT NOT NULL DEFAULT 60;
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_public_price_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_public_price_chk
    CHECK (public_price_per_minute BETWEEN 10 AND 600);
COMMENT ON COLUMN crm.tenant_settings.public_price_per_minute IS 'AA-1092 (crm-062): the "Book now" price checks a minute the agency''s public tour page takes from every address together (10..600, default 60, per API task: each task counts on its own); past it the price check answers 429 agency_rate_limited. The owner sets it on Settings > Payments "Online booking"';

DO $$
BEGIN
    IF NOT has_column_privilege('crm_app', 'crm.tenant_settings', 'public_price_per_minute', 'UPDATE')
       OR NOT has_column_privilege('crm_app', 'crm.tenant_settings', 'public_price_per_minute', 'SELECT') THEN
        RAISE EXCEPTION 'crm-062: crm_app is missing a privilege on crm.tenant_settings.public_price_per_minute';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-062', now(), 'AA-1092: Book now price ceiling: crm.tenant_settings.public_price_per_minute (default 60, 10..600), the agency''s price checks a minute')
ON CONFLICT (version) DO NOTHING;

COMMIT;
