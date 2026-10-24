-- Migration bk-024: AA-908 (root ADR 0006 Phase 4) — verified traveller identities on booking customers.
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra db/migrations/booking/024_customer_identities.sql
-- and is applied to Dev by the DB Migrate workflow (check, then apply), as bk_owner (the live owner of schema booking
-- since bk-014). Never run it from a laptop.
--
-- Why. TripPlanner travellers sign in on the Cognito EXTERNAL pool. A signed-in hand-off (contract inquiry.submitted
-- v1.4, AA-Ecosys docs/contracts/) carries customer.identity = {iss, sub} of the verified access token and
-- customer.verified = the token's email_verified. Intake (app/inquiry/intake.py, the AA-908 code PR deployed after this
-- file is applied) links such an identity to exactly one booking customer:
--   (a) a known identity -> its customer;
--   (b) else a verified live customer with the same email -> that customer, and the identity is attached to it;
--   (c) else a new customer with verified = true and source = 'traveller_signin' (name and the token's email only).
-- Unverified leads with the same email are only flagged for staff merge review, never merged (contract v1.1 rule).
--
-- What:
--   * booking.customer_identities (iss, sub) -> customer_id. PRIMARY KEY (iss, sub): one identity, one customer (keyed on
--     iss AND sub together, never sub alone, ADR 0006 decision 9). A customer may hold several identities (another
--     pool, a later Google sign-in). iss and sub carry the DM-6.1 tag pii:online_id. Same shape CHECKs as
--     staff_users.cognito_* (bk-016) and the contract (iss https, at most 300 characters; sub 1-128 characters).
--     ON DELETE CASCADE: the identity follows its customer (data standards DM-7: kept while the customer is kept).
--     Customers are archived with deleted_at, not deleted: intake re-points the identity of an archived customer
--     (UPDATE of customer_id), which is the one column role booking may update.
--   * customers_source_chk widened with 'traveller_signin'. The CHECK is swapped in place (DROP + ADD in one
--     transaction): every existing value stays valid. The new value is only written by the AA-908 intake code, which
--     deploys after this apply (lesson: a CHECK value must exist before the code that writes it).
--   * Grants: role booking SELECT and INSERT on customer_identities, UPDATE of customer_id only, never DELETE (the
--     bk_owner default privileges gave DELETE: revoked). No consumer role reads it.
--
-- Depends on bk-002 (customers.source / verified) and bk-014 (bk_owner). Re-runnable (the Integration Tests replay
-- every file): CREATE ... IF NOT EXISTS, each CHECK dropped if present and added again, grants repeat.
-- Locks: ACCESS EXCLUSIVE on booking.customers for the CHECK swap (the ADD validates with a scan of a table of a
-- handful of rows on Dev); lock_timeout 5s: the apply fails rather than queueing behind the job worker.
-- Undo (a later bk- file): DROP TABLE booking.customer_identities; restore customers_source_chk without
-- 'traveller_signin' after re-labelling any such row (UPDATE ... SET source = 'manual').

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-024: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.customers') IS NULL THEN
        RAISE EXCEPTION 'bk-024: booking.customers is missing (bk-001 / bk-002 first)';
    END IF;
END $$;

-- ── customers.source: 'traveller_signin' ─────────────────────────────────────

ALTER TABLE booking.customers DROP CONSTRAINT IF EXISTS customers_source_chk;
ALTER TABLE booking.customers ADD CONSTRAINT customers_source_chk
    CHECK (source IN ('manual', 'otp', 'tripplanner_lead', 'traveller_signin'));

COMMENT ON COLUMN booking.customers.verified IS
    'true only after the contact was verified: by Booking OTP (AA-680), or by a signed-in TripPlanner traveller whose Cognito token says email_verified (source traveller_signin, bk-024, AA-908). Leads from a guest hand-off start false.';

-- ── customer_identities ──────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.customer_identities (
    iss         TEXT NOT NULL,
    sub         TEXT NOT NULL,
    customer_id UUID NOT NULL REFERENCES booking.customers (id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT customer_identities_pkey PRIMARY KEY (iss, sub)
);

ALTER TABLE booking.customer_identities DROP CONSTRAINT IF EXISTS customer_identities_shape_chk;
ALTER TABLE booking.customer_identities ADD CONSTRAINT customer_identities_shape_chk
    CHECK (iss LIKE 'https://%' AND length(iss) <= 300 AND length(sub) BETWEEN 1 AND 128);

CREATE INDEX IF NOT EXISTS customer_identities_customer_idx ON booking.customer_identities (customer_id);

COMMENT ON TABLE booking.customer_identities IS
    'bk-024 (AA-908, ADR 0006 Phase 4): verified sign-in identities of a customer, from inquiry.submitted v1.4 customer.identity. One identity (iss, sub) belongs to one customer; a customer may have several.';
COMMENT ON COLUMN booking.customer_identities.iss IS
    'pii:online_id; bk-024: token issuer (the Cognito EXTERNAL pool URL); the identity is (iss, sub) together.';
COMMENT ON COLUMN booking.customer_identities.sub IS
    'pii:online_id; bk-024: Cognito subject (user id) of the signed-in traveller, unique with iss.';
COMMENT ON COLUMN booking.customer_identities.customer_id IS
    'bk-024: the customer this identity signs in as. Re-pointed by intake only when that customer was archived (deleted_at).';

REVOKE ALL ON booking.customer_identities FROM booking;
GRANT SELECT, INSERT ON booking.customer_identities TO booking;
GRANT UPDATE (customer_id) ON booking.customer_identities TO booking;

-- ── Post-checks ──────────────────────────────────────────────────────────────

DO $$
BEGIN
    IF has_table_privilege('booking', 'booking.customer_identities', 'DELETE')
       OR has_table_privilege('booking', 'booking.customer_identities', 'TRUNCATE') THEN
        RAISE EXCEPTION 'bk-024: role booking can delete customer identities';
    END IF;
    IF has_column_privilege('booking', 'booking.customer_identities', 'iss', 'UPDATE')
       OR has_column_privilege('booking', 'booking.customer_identities', 'sub', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-024: role booking can rewrite an identity';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cis_app')
       AND has_table_privilege('cis_app', 'booking.customer_identities', 'SELECT') THEN
        RAISE EXCEPTION 'bk-024: cis_app can read booking.customer_identities';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-024', now(), 'AA-908: booking.customer_identities (iss, sub) -> customer, customers_source_chk + traveller_signin')
ON CONFLICT (version) DO NOTHING;

COMMIT;
