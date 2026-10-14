-- Migration bk-001: AA-678 — schema `booking` foundation (first slice).
--
-- Owner: AA-Booking (key bk-NNN, AA-Ecosys docs/database/schema-ownership.md rule 4). A
-- byte-identical copy lives in AA-CIS-Infra db/migrations/booking/001_booking_foundation.sql and is
-- applied to Dev by the DB Migrate workflow (check, then apply). Never run it from a laptop.
--
-- Scope (root ADR 0004 decision 7, "Foundation" + "Tier A"):
--   * schema `booking`, role `booking` NOLOGIN, grants and default privileges;
--   * identity: customers, customer_otps, customer_sessions;
--   * cross-cutting: media_files, audit_logs, inbox_events (table only, no consumer);
--   * booking.v_schema_versions: Booking's own rows of shared.schema_versions, read by
--     GET /booking/health/ready.
-- Not here (later bk-NNN, each blocked by an open decision in ADR 0004): staff_users / staff_role
-- (O1), trip_cases* and their enums (O6 + status vocabulary), areas / country_profiles (O7 + ISO
-- mapping), catalog and trip_plans (AA-679), versions / operations / money (AA-681/682), any job
-- table or shared.job use (O3).
--
-- Who runs it: DB Migrate connects as the CIS api task's DATABASE_URL, the RDS master user
-- `aa_cis_admin`, so every object below is owned by aa_cis_admin. Default privileges therefore
-- name that role explicitly (`FOR ROLE aa_cis_admin`); without FOR ROLE they would bind to
-- whichever role happens to run the file. If the runner is not aa_cis_admin the file fails loudly
-- and is not registered.
--
-- Role `booking`: created NOLOGIN here so the file is self-contained and idempotent. Nghiep sets
-- LOGIN + PASSWORD out-of-band (value kept in Secrets Manager `booking/dev/database-url`). No
-- password ever goes in Git or in a migration file.
--
-- Privileges of `booking` (least privilege, enforced by the database):
--   * USAGE on schema booking only — no CREATE: schema changes go through bk-NNN migrations;
--   * SELECT/INSERT/UPDATE/DELETE on booking tables (default privileges + explicit grants);
--   * audit_logs is append-only for the app (UPDATE/DELETE revoked);
--   * v_schema_versions is read-only (INSERT/UPDATE/DELETE revoked: a simple view is
--     auto-updatable and would otherwise write into shared.schema_versions as the view owner);
--   * nothing outside schema booking. Reads of CIS / TripPlanner objects are granted later by
--     their owners, in their own migrations, unguarded (ADR 0004 decision 6).
--
-- Re-running the whole file is a no-op (IF NOT EXISTS / OR REPLACE / idempotent GRANT/REVOKE).

BEGIN;

-- ── Schema and role ──────────────────────────────────────────────────────────

CREATE SCHEMA IF NOT EXISTS booking;

COMMENT ON SCHEMA booking IS
    'AA-Booking (AAA). Owner repo AA-Booking, migrations bk-NNN, applied by AA-CIS-Infra DB Migrate. ADR 0001 decision 6, root ADR 0004.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'booking') THEN
        CREATE ROLE booking NOLOGIN;
    END IF;
END $$;

REVOKE ALL ON SCHEMA booking FROM PUBLIC;
GRANT USAGE ON SCHEMA booking TO booking;

ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA booking
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO booking;
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA booking
    GRANT USAGE, SELECT ON SEQUENCES TO booking;
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA booking
    GRANT EXECUTE ON FUNCTIONS TO booking;

-- ── Helpers ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION booking.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.set_updated_at() IS 'BEFORE UPDATE trigger: keeps updated_at current.';

-- ── Media ────────────────────────────────────────────────────────────────────
-- Media is never a URL column: rows point here (bucket + key) and the API builds the CDN URL.

CREATE TABLE IF NOT EXISTS booking.media_files (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    s3_bucket     TEXT NOT NULL,
    s3_key        TEXT NOT NULL,
    content_type  TEXT NOT NULL,
    bytes         BIGINT,
    width         INTEGER,
    height        INTEGER,
    sha256        TEXT,
    uploaded_by   UUID,                          -- a staff or customer id; no FK until O1 decides staff identity
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at    TIMESTAMPTZ,

    CONSTRAINT media_files_object_uq UNIQUE (s3_bucket, s3_key),
    CONSTRAINT media_files_bytes_chk CHECK (bytes IS NULL OR bytes >= 0),
    CONSTRAINT media_files_dims_chk CHECK ((width IS NULL OR width > 0) AND (height IS NULL OR height > 0)),
    CONSTRAINT media_files_sha256_chk CHECK (sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$')
);

-- ── Customer identity (OTP only, ADR 0001: AA-Booking owns customer identity) ─

CREATE TABLE IF NOT EXISTS booking.customers (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name              TEXT,
    email             TEXT,
    phone             TEXT,
    address           TEXT,
    gender            TEXT,
    marital_status    TEXT,
    profession        TEXT,
    profile_media_id  UUID REFERENCES booking.media_files (id),
    is_blocked        BOOLEAN NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,

    CONSTRAINT customers_contact_chk CHECK (email IS NOT NULL OR phone IS NOT NULL)
);

-- One live customer per email / phone; a soft-deleted row does not block re-registration.
CREATE UNIQUE INDEX IF NOT EXISTS customers_email_live_uq
    ON booking.customers (lower(email)) WHERE email IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS customers_phone_live_uq
    ON booking.customers (phone) WHERE phone IS NOT NULL AND deleted_at IS NULL;

CREATE OR REPLACE TRIGGER customers_set_updated_at
    BEFORE UPDATE ON booking.customers
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

CREATE TABLE IF NOT EXISTS booking.customer_otps (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id  UUID NOT NULL REFERENCES booking.customers (id) ON DELETE CASCADE,
    otp_hash     TEXT NOT NULL,                   -- hash only, never the plain code
    channel      TEXT NOT NULL,
    expires_at   TIMESTAMPTZ NOT NULL,
    used_at      TIMESTAMPTZ,
    attempts     SMALLINT NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT customer_otps_channel_chk CHECK (channel IN ('email', 'sms')),
    CONSTRAINT customer_otps_attempts_chk CHECK (attempts >= 0)
);

CREATE INDEX IF NOT EXISTS customer_otps_customer_idx
    ON booking.customer_otps (customer_id, created_at DESC);

CREATE TABLE IF NOT EXISTS booking.customer_sessions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id         UUID NOT NULL REFERENCES booking.customers (id) ON DELETE CASCADE,
    refresh_token_hash  TEXT NOT NULL,
    expires_at          TIMESTAMPTZ NOT NULL,
    revoked_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT customer_sessions_token_uq UNIQUE (refresh_token_hash)
);

CREATE INDEX IF NOT EXISTS customer_sessions_customer_idx
    ON booking.customer_sessions (customer_id);

-- ── Cross-cutting ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.audit_logs (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_type   TEXT NOT NULL,
    actor_id     UUID,
    action       TEXT NOT NULL,
    entity_type  TEXT NOT NULL,
    entity_id    UUID,
    before       JSONB,
    after        JSONB,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT audit_logs_actor_type_chk CHECK (actor_type IN ('staff', 'customer', 'system'))
);

CREATE INDEX IF NOT EXISTS audit_logs_entity_idx
    ON booking.audit_logs (entity_type, entity_id, created_at DESC);

-- Consumer side of the ADR 0001 outbox contracts (inquiry.submitted from TripPlanner, later
-- catalog.tour.* from CIS): one row per consumed event. Idempotency keys are unique per source and
-- contract, not globally. The consumer itself is out of the bootstrap (ADR 0004 O3/O6).
CREATE TABLE IF NOT EXISTS booking.inbox_events (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source           TEXT NOT NULL,
    contract         TEXT NOT NULL,
    idempotency_key  TEXT NOT NULL,
    payload          JSONB NOT NULL,
    received_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at     TIMESTAMPTZ,
    error            TEXT,

    CONSTRAINT inbox_events_source_chk CHECK (source IN ('tripplanner', 'cis')),
    CONSTRAINT inbox_events_key_uq UNIQUE (source, contract, idempotency_key)
);

CREATE INDEX IF NOT EXISTS inbox_events_pending_idx
    ON booking.inbox_events (received_at) WHERE processed_at IS NULL;

-- ── Readiness view ───────────────────────────────────────────────────────────
-- Booking's own rows of shared.schema_versions (rule 4: the table is CIS's, each owner's rows are
-- its own). The view runs with its owner's rights, so role `booking` needs no grant on schema
-- shared. security_barrier keeps the WHERE filter ahead of any caller-supplied function.

CREATE OR REPLACE VIEW booking.v_schema_versions WITH (security_barrier = true) AS
SELECT version, description, applied_at
FROM shared.schema_versions
WHERE version LIKE 'bk-%';

COMMENT ON VIEW booking.v_schema_versions IS
    'bk-001: Booking-owned rows of shared.schema_versions (read-only for role booking). Used by GET /booking/health/ready.';

-- ── Explicit grants (also cover objects that existed before the default privileges) ─

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA booking TO booking;
GRANT EXECUTE ON FUNCTION booking.set_updated_at() TO booking;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_schema_versions FROM booking;
REVOKE UPDATE, DELETE, TRUNCATE ON booking.audit_logs FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-001', now(), 'AA-678: booking schema foundation — role booking NOLOGIN, grants, default privileges FOR ROLE aa_cis_admin, customers/otps/sessions, media_files, audit_logs, inbox_events, v_schema_versions')
ON CONFLICT (version) DO NOTHING;

COMMIT;
