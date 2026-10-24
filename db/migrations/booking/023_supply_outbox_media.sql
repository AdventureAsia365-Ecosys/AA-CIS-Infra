-- Migration bk-023: AA-835 — the supply stream of the shared outbox, supply_version on hotels and services, supplier
-- photos (booking.entity_media) and the facts-only contract views v_supply_* read by CIS (root ADR 0004a; contracts
-- supply.hotel.v1 / supply.service.v1, AA-Ecosys docs/contracts/).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra db/migrations/booking/023_supply_outbox_media.sql
-- and is applied to Dev by the DB Migrate workflow (check, then apply), as bk_owner (the live owner of schema booking
-- since bk-014). Never run it from a laptop.
--
-- Depends on bk-003 (staff_users, set_updated_at), bk-010 (hotels, hotel_room_types, services), bk-017 (USAGE on
-- schema booking for cis_app) and bk-022 (booking.outbox). Every grant names its object (no "ON ALL TABLES").
--
-- What it adds (docs/implementation-notes/AA-835.md):
--   * booking.outbox stream 'supply' (ADR 0004a decision 3): columns entity_type ('hotel' | 'service'), entity_id and
--     supply_version, event types supply.upsert / supply.deactivate. A supply row names its entity and version and
--     nothing else (no partner, no b2b id or code); a b2b row has none of the three. Typed ids only, as in bk-022: the
--     contract payload is the v_supply_hotels / v_supply_services row the consumer reads with the event.
--   * supply_version on hotels and services (BIGINT, 1 at insert): monotonic, bumped by a BEFORE trigger on every
--     material change of the facts the contract carries (hotels: name, style, stars, address, place, geo point,
--     check-in/out, amenities, status; services: type, working title, unit, place, duration, group size, inclusions,
--     status). internal_notes, links, source refs and the audit columns are not material. A room type insert or a
--     change of its name, occupancy, bed types, status or hotel bumps the hotel; a photo insert, a usage_rights flip or
--     a removal bumps its entity. Any write of supply_version itself counts as one bump (+1, never another value), so
--     the triggers above and a deliberate re-send ("touch") use the same path and the version can never go back.
--   * One outbox row per version: an AFTER trigger on hotels and services writes stream 'supply' when a row is
--     inserted or its supply_version changed. supply.deactivate while the entity is inactive, supply.upsert while it
--     is active (the contract ties change to facts.status). Several bumps in one transaction give several rows with
--     increasing versions; the consumer applies only a version newer than the one it holds.
--   * booking.entity_media: supplier photos of a hotel or a service. The object lives in the Booking supply-media
--     bucket under the fixed key supply-media/<entity_type>/<entity_id>/<id>.<ext> (CHECK: the key is derived from the
--     row, so no free URL or foreign key can be stored), JPEG / PNG / WebP, at most 10 MB, sha256 of the stored
--     bytes, usage_rights (false until contracting confirms AA may publish it; CIS never publishes a photo without
--     it), status active | removed (removed is final). No foreign key on the entity (one column pair for two
--     tables): the bump trigger refuses a photo of an entity that does not exist. Role booking: SELECT, INSERT,
--     UPDATE of usage_rights / status / updated_* only, never DELETE.
--   * Contract views for the CIS runtime role cis_app (security_barrier, facts only: no supplier, rate, contract,
--     internal note, link, staff id or audit column):
--       v_supply_hotels    one row per hotel: the supply.hotel.v1 facts + id + supply_version; room_types (all, as
--                          JSON) and media (active photos, as JSON, ids only);
--       v_supply_services  one row per service: the supply.service.v1 facts + id + supply_version; media as above;
--       v_supply_media     active photos: id, entity, usage_rights, bucket, key, sha256, content type (what CIS needs
--                          to copy a rights-cleared photo; its task role reads the bucket);
--       v_supply_outbox    supply events that have a feed_seq (stamped in commit order by app/outbox.py): the cursor
--                          of the CIS pull is feed_seq.
--     cis_app gets SELECT on the four views (USAGE on schema booking is bk-017's) and nothing on any table: a view reads
--     its base tables with its owner's (bk_owner's) rights. Mirrored in AA-CIS-Infra db/owners.yaml consumer_grants.
--
-- Not here: no outbox row for hotels and services that exist before bk-023 (each enters the stream on its next
-- material change, or on a deliberate touch: UPDATE ... SET supply_version = supply_version + 1). The Booking code
-- (upload API, read-back, REQUIRED_SCHEMA_VERSIONS) is AA-835 S4, deployed after this file is applied.
--
-- Locks: booking.outbox, booking.hotels and booking.services take ACCESS EXCLUSIVE for the column adds (constant
-- default: no rewrite) and the CHECK swaps on the outbox (a short scan of small tables on Dev); the new triggers take
-- SHARE ROW EXCLUSIVE on hotels, hotel_room_types and services for an instant. lock_timeout 5s: the apply fails rather
-- than queueing behind the job worker. Apply it in a quiet window on a busy database.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS everywhere, DROP CONSTRAINT IF EXISTS before
-- each added CHECK, CREATE OR REPLACE for functions, triggers and views (same column lists), grants repeat. bk-022
-- replayed after this file takes back its column grants on the outbox (a table-level REVOKE drops column grants):
-- replay this file after it (the tests do).
-- Undo (a later bk- file; the reverse recipe is in docs/implementation-notes/AA-835.md).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-023: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cis_app') THEN
        RAISE EXCEPTION 'bk-023: role cis_app is missing (AA-CIS-Infra roles/001, rl-001)';
    END IF;
    IF to_regclass('booking.outbox') IS NULL OR to_regclass('booking.hotels') IS NULL THEN
        RAISE EXCEPTION 'bk-023: needs bk-010 (hotels, services) and bk-022 (booking.outbox) first';
    END IF;
    IF NOT has_schema_privilege('cis_app', 'booking', 'USAGE') THEN
        RAISE EXCEPTION 'bk-023: cis_app has no USAGE on schema booking (bk-017 first)';
    END IF;
END $$;

-- ── The supply stream on the shared outbox ───────────────────────────────────

ALTER TABLE booking.outbox
    ADD COLUMN IF NOT EXISTS entity_type TEXT,
    ADD COLUMN IF NOT EXISTS entity_id UUID,
    ADD COLUMN IF NOT EXISTS supply_version BIGINT;

ALTER TABLE booking.outbox DROP CONSTRAINT IF EXISTS outbox_stream_chk;
ALTER TABLE booking.outbox ADD CONSTRAINT outbox_stream_chk CHECK (stream IN ('b2b', 'supply'));

ALTER TABLE booking.outbox DROP CONSTRAINT IF EXISTS outbox_event_type_chk;
ALTER TABLE booking.outbox ADD CONSTRAINT outbox_event_type_chk CHECK (event_type IN (
    'hold.expired', 'hold.extended', 'line.confirmed', 'line.declined', 'booking.cancelled',
    'departure.guaranteed', 'departure.cancelled', 'departure.incident', 'departure.incident_cleared',
    'supply.upsert', 'supply.deactivate'));

-- A supply event names its entity and version and nothing else; a b2b event never carries the supply columns.
-- coalesce: a NULL entity_type or supply_version must make the CHECK false, not unknown (unknown passes a CHECK).
ALTER TABLE booking.outbox DROP CONSTRAINT IF EXISTS outbox_supply_chk;
ALTER TABLE booking.outbox ADD CONSTRAINT outbox_supply_chk CHECK (
    (stream = 'supply'
     AND event_type IN ('supply.upsert', 'supply.deactivate')
     AND coalesce(entity_type IN ('hotel', 'service') AND supply_version >= 1, false) AND entity_id IS NOT NULL
     AND num_nonnulls(partner_id, hold_id, booking_id, line_ref, departure_id, incident_code, decline_code) = 0)
    OR (stream <> 'supply'
        AND event_type NOT IN ('supply.upsert', 'supply.deactivate')
        AND entity_type IS NULL AND entity_id IS NULL AND supply_version IS NULL));

CREATE INDEX IF NOT EXISTS outbox_supply_feed_idx ON booking.outbox (feed_seq) WHERE stream = 'supply';

COMMENT ON COLUMN booking.outbox.stream IS
    'bk-022: b2b = the booking.b2b.v1 feed of partner_id. bk-023 (AA-835): supply = hotel / service facts for CIS (supply.hotel.v1 / supply.service.v1, read through booking.v_supply_outbox).';
COMMENT ON COLUMN booking.outbox.entity_type IS
    'bk-023 (AA-835): supply stream only: hotel or service.';
COMMENT ON COLUMN booking.outbox.entity_id IS
    'bk-023: supply stream only: booking.hotels.id or booking.services.id (soft key, no FK: the outbox is a log).';
COMMENT ON COLUMN booking.outbox.supply_version IS
    'bk-023: supply stream only: the entity supply_version this event announces (the contract supply_version is the one of the facts read with it).';

-- ── supply_version on hotels and services ────────────────────────────────────

ALTER TABLE booking.hotels ADD COLUMN IF NOT EXISTS supply_version BIGINT NOT NULL DEFAULT 1;
ALTER TABLE booking.services ADD COLUMN IF NOT EXISTS supply_version BIGINT NOT NULL DEFAULT 1;

ALTER TABLE booking.hotels DROP CONSTRAINT IF EXISTS hotels_supply_version_chk;
ALTER TABLE booking.hotels ADD CONSTRAINT hotels_supply_version_chk CHECK (supply_version >= 1);
ALTER TABLE booking.services DROP CONSTRAINT IF EXISTS services_supply_version_chk;
ALTER TABLE booking.services ADD CONSTRAINT services_supply_version_chk CHECK (supply_version >= 1);

COMMENT ON COLUMN booking.hotels.supply_version IS
    'bk-023 (AA-835, ADR 0004a d4): monotonic version of the supply facts; 1 at insert, +1 on a material change, a room type change or a photo change (trigger hotels_supply_version). Each new version writes one supply outbox row.';
COMMENT ON COLUMN booking.services.supply_version IS
    'bk-023 (AA-835, ADR 0004a d4): monotonic version of the supply facts; 1 at insert, +1 on a material change or a photo change (trigger services_supply_version). Each new version writes one supply outbox row.';

CREATE OR REPLACE FUNCTION booking.hotels_supply_version() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.supply_version := 1;
    ELSIF NEW.supply_version IS DISTINCT FROM OLD.supply_version
       OR (NEW.name, NEW.hotel_style, NEW.star_rating, NEW.address, NEW.destination_id, NEW.country_code,
           NEW.latitude, NEW.longitude, NEW.check_in_time, NEW.check_out_time, NEW.amenities, NEW.status)
          IS DISTINCT FROM
          (OLD.name, OLD.hotel_style, OLD.star_rating, OLD.address, OLD.destination_id, OLD.country_code,
           OLD.latitude, OLD.longitude, OLD.check_in_time, OLD.check_out_time, OLD.amenities, OLD.status) THEN
        NEW.supply_version := OLD.supply_version + 1;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.hotels_supply_version() IS
    'bk-023 (AA-835): supply_version = 1 at insert; +1 on a material change of the supply.hotel.v1 facts or on any write of supply_version (room type / photo bumps, a touch). Never another value.';

CREATE OR REPLACE TRIGGER hotels_supply_version
    BEFORE INSERT OR UPDATE ON booking.hotels
    FOR EACH ROW EXECUTE FUNCTION booking.hotels_supply_version();

CREATE OR REPLACE FUNCTION booking.services_supply_version() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.supply_version := 1;
    ELSIF NEW.supply_version IS DISTINCT FROM OLD.supply_version
       OR (NEW.service_type, NEW.title, NEW.unit, NEW.destination_id, NEW.country_code, NEW.duration_minutes,
           NEW.max_group_size, NEW.inclusions, NEW.status)
          IS DISTINCT FROM
          (OLD.service_type, OLD.title, OLD.unit, OLD.destination_id, OLD.country_code, OLD.duration_minutes,
           OLD.max_group_size, OLD.inclusions, OLD.status) THEN
        NEW.supply_version := OLD.supply_version + 1;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.services_supply_version() IS
    'bk-023 (AA-835): supply_version = 1 at insert; +1 on a material change of the supply.service.v1 facts or on any write of supply_version (photo bumps, a touch). Never another value.';

CREATE OR REPLACE TRIGGER services_supply_version
    BEFORE INSERT OR UPDATE ON booking.services
    FOR EACH ROW EXECUTE FUNCTION booking.services_supply_version();

-- One supply outbox row per new version (hotels and services share the function: same status / supply_version).
CREATE OR REPLACE FUNCTION booking.supply_outbox() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.supply_version <> OLD.supply_version THEN
        INSERT INTO booking.outbox (stream, event_type, entity_type, entity_id, supply_version)
        VALUES ('supply',
                CASE WHEN NEW.status = 'inactive' THEN 'supply.deactivate' ELSE 'supply.upsert' END,
                CASE TG_TABLE_NAME WHEN 'hotels' THEN 'hotel' WHEN 'services' THEN 'service' END,
                NEW.id, NEW.supply_version);
    END IF;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.supply_outbox() IS
    'bk-023 (AA-835): one booking.outbox row (stream supply) per inserted hotel / service and per new supply_version: supply.deactivate while inactive, supply.upsert while active.';

CREATE OR REPLACE TRIGGER hotels_supply_outbox
    AFTER INSERT OR UPDATE ON booking.hotels
    FOR EACH ROW EXECUTE FUNCTION booking.supply_outbox();

CREATE OR REPLACE TRIGGER services_supply_outbox
    AFTER INSERT OR UPDATE ON booking.services
    FOR EACH ROW EXECUTE FUNCTION booking.supply_outbox();

-- A room type is part of its hotel's facts: a new room type or a material change bumps the hotel (both hotels when
-- it moves).
CREATE OR REPLACE FUNCTION booking.hotel_room_types_supply_bump() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT'
       OR (NEW.hotel_id, NEW.name, NEW.max_occupancy, NEW.bed_types, NEW.status)
          IS DISTINCT FROM (OLD.hotel_id, OLD.name, OLD.max_occupancy, OLD.bed_types, OLD.status) THEN
        UPDATE booking.hotels SET supply_version = supply_version + 1 WHERE id = NEW.hotel_id;
        IF TG_OP = 'UPDATE' AND NEW.hotel_id IS DISTINCT FROM OLD.hotel_id THEN
            UPDATE booking.hotels SET supply_version = supply_version + 1 WHERE id = OLD.hotel_id;
        END IF;
    END IF;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.hotel_room_types_supply_bump() IS
    'bk-023 (AA-835): a room type insert or a change of hotel, name, occupancy, bed types or status bumps the hotel supply_version.';

CREATE OR REPLACE TRIGGER hotel_room_types_supply_bump
    AFTER INSERT OR UPDATE ON booking.hotel_room_types
    FOR EACH ROW EXECUTE FUNCTION booking.hotel_room_types_supply_bump();

-- ── Supplier photos ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.entity_media (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type   TEXT NOT NULL,
    entity_id     UUID NOT NULL,
    s3_bucket     TEXT NOT NULL,
    s3_key        TEXT NOT NULL,
    content_type  TEXT NOT NULL,
    bytes         INTEGER NOT NULL,
    width         INTEGER,
    height        INTEGER,
    sha256        TEXT NOT NULL,
    usage_rights  BOOLEAN NOT NULL DEFAULT false,
    status        TEXT NOT NULL DEFAULT 'active',
    uploaded_by   TEXT NOT NULL REFERENCES booking.staff_users (cis_user_id),
    updated_by    TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT entity_media_entity_type_chk CHECK (entity_type IN ('hotel', 'service')),
    CONSTRAINT entity_media_bucket_chk CHECK (s3_bucket ~ '^aa-booking-[a-z0-9]+-supply-media-[0-9]{12}$'),
    CONSTRAINT entity_media_content_type_chk CHECK (content_type IN ('image/jpeg', 'image/png', 'image/webp')),
    -- The key is derived from the row: supply-media/<entity_type>/<entity_id>/<id>.<ext of the content type>.
    CONSTRAINT entity_media_key_chk CHECK (
        s3_key = 'supply-media/' || entity_type || '/' || entity_id::text || '/' || id::text || '.'
                 || CASE content_type WHEN 'image/jpeg' THEN 'jpg' WHEN 'image/png' THEN 'png' ELSE 'webp' END),
    CONSTRAINT entity_media_bytes_chk CHECK (bytes BETWEEN 1 AND 10485760),
    CONSTRAINT entity_media_size_chk CHECK (
        (width IS NULL OR width BETWEEN 1 AND 20000) AND (height IS NULL OR height BETWEEN 1 AND 20000)),
    CONSTRAINT entity_media_sha256_chk CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT entity_media_status_chk CHECK (status IN ('active', 'removed'))
);

COMMENT ON TABLE booking.entity_media IS
    'bk-023 (AA-835, ADR 0004a d2): supplier photos of a hotel or a service, stored in the Booking supply-media bucket under supply-media/<entity_type>/<entity_id>/<id>.<ext>. CIS publishes a photo only while usage_rights is true. Never deleted: status active / removed (final). Not customer media (booking.media_files).';
COMMENT ON COLUMN booking.entity_media.entity_id IS
    'bk-023: booking.hotels.id or booking.services.id per entity_type (no FK: one column pair for two tables; the bump trigger refuses a missing entity).';
COMMENT ON COLUMN booking.entity_media.s3_bucket IS
    'bk-023: the Booking supply-media bucket (Terraform aa-booking-<env>-supply-media-<account>); settings SUPPLY_MEDIA_BUCKET.';
COMMENT ON COLUMN booking.entity_media.sha256 IS
    'bk-023: hex SHA-256 of the stored bytes, computed by the API; CIS re-checks it after its copy.';
COMMENT ON COLUMN booking.entity_media.usage_rights IS
    'bk-023: true = contracting confirmed AA may publish the photo. False by default; CIS never publishes it while false.';
COMMENT ON COLUMN booking.entity_media.status IS
    'bk-023: active, or removed (final; the object stays, CIS stops using it).';

-- One active copy of the same bytes per entity (a double submit is refused).
CREATE UNIQUE INDEX IF NOT EXISTS entity_media_entity_sha_uq
    ON booking.entity_media (entity_type, entity_id, sha256) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS entity_media_entity_idx ON booking.entity_media (entity_type, entity_id, created_at);

CREATE OR REPLACE TRIGGER entity_media_set_updated_at
    BEFORE UPDATE ON booking.entity_media
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

CREATE OR REPLACE FUNCTION booking.entity_media_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF OLD.status = 'removed' AND (NEW.status, NEW.usage_rights) IS DISTINCT FROM (OLD.status, OLD.usage_rights) THEN
        RAISE EXCEPTION 'photo % is removed; upload it again instead', OLD.id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.entity_media_guard() IS
    'bk-023 (AA-835): a removed photo stays removed (status and usage_rights are fixed once removed).';

CREATE OR REPLACE TRIGGER entity_media_guard
    BEFORE UPDATE ON booking.entity_media
    FOR EACH ROW EXECUTE FUNCTION booking.entity_media_guard();

-- A new photo, a usage_rights flip or a removal is a new version of the entity's facts.
CREATE OR REPLACE FUNCTION booking.entity_media_supply_bump() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT'
       OR (NEW.usage_rights, NEW.status) IS DISTINCT FROM (OLD.usage_rights, OLD.status) THEN
        IF NEW.entity_type = 'hotel' THEN
            UPDATE booking.hotels SET supply_version = supply_version + 1 WHERE id = NEW.entity_id;
        ELSE
            UPDATE booking.services SET supply_version = supply_version + 1 WHERE id = NEW.entity_id;
        END IF;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'photo %: % % does not exist', NEW.id, NEW.entity_type, NEW.entity_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
    END IF;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.entity_media_supply_bump() IS
    'bk-023 (AA-835): a photo insert, a usage_rights flip or a removal bumps the hotel / service supply_version; a photo of a missing entity is refused (foreign_key_violation).';

CREATE OR REPLACE TRIGGER entity_media_supply_bump
    AFTER INSERT OR UPDATE ON booking.entity_media
    FOR EACH ROW EXECUTE FUNCTION booking.entity_media_supply_bump();

-- ── Contract views for CIS (facts only) ──────────────────────────────────────

CREATE OR REPLACE VIEW booking.v_supply_hotels WITH (security_barrier = true) AS
SELECT h.id,
       h.supply_version,
       h.name,
       h.hotel_style,
       h.star_rating,
       h.address,
       h.destination_id,
       h.country_code::text AS country_code,
       h.latitude::double precision AS lat,
       h.longitude::double precision AS lng,
       h.check_in_time,
       h.check_out_time,
       h.amenities,
       coalesce((SELECT jsonb_agg(jsonb_build_object(
                            'id', r.id, 'name', r.name, 'max_occupancy', r.max_occupancy,
                            'bed_types', to_jsonb(r.bed_types), 'status', r.status)
                        ORDER BY r.created_at, r.id)
                   FROM booking.hotel_room_types r
                  WHERE r.hotel_id = h.id), '[]'::jsonb) AS room_types,
       h.status,
       coalesce((SELECT jsonb_agg(jsonb_build_object(
                            'media_id', m.id, 'usage_rights', m.usage_rights, 'content_type', m.content_type,
                            'width', m.width, 'height', m.height, 'sha256', m.sha256)
                        ORDER BY m.created_at, m.id)
                   FROM booking.entity_media m
                  WHERE m.entity_type = 'hotel' AND m.entity_id = h.id AND m.status = 'active'), '[]'::jsonb) AS media
  FROM booking.hotels h;

COMMENT ON VIEW booking.v_supply_hotels IS
    'bk-023 (AA-835): supply.hotel.v1 facts per hotel (+ id, supply_version): room types (all) and active photos (ids only) as JSON. No supplier, rate, internal note, link or audit column. Read by the CIS runtime (cis_app).';

CREATE OR REPLACE VIEW booking.v_supply_services WITH (security_barrier = true) AS
SELECT s.id,
       s.supply_version,
       s.service_type,
       s.title AS working_title,
       s.unit,
       s.destination_id,
       s.country_code::text AS country_code,
       s.duration_minutes,
       s.max_group_size,
       s.inclusions,
       s.status,
       coalesce((SELECT jsonb_agg(jsonb_build_object(
                            'media_id', m.id, 'usage_rights', m.usage_rights, 'content_type', m.content_type,
                            'width', m.width, 'height', m.height, 'sha256', m.sha256)
                        ORDER BY m.created_at, m.id)
                   FROM booking.entity_media m
                  WHERE m.entity_type = 'service' AND m.entity_id = s.id AND m.status = 'active'), '[]'::jsonb) AS media
  FROM booking.services s;

COMMENT ON VIEW booking.v_supply_services IS
    'bk-023 (AA-835): supply.service.v1 facts per service (+ id, supply_version; working_title = the internal title, writer input only) and active photos (ids only) as JSON. No supplier, rate, internal note, source ref or audit column. Read by the CIS runtime (cis_app).';

CREATE OR REPLACE VIEW booking.v_supply_media WITH (security_barrier = true) AS
SELECT m.id AS media_id,
       m.entity_type,
       m.entity_id,
       m.usage_rights,
       m.s3_bucket,
       m.s3_key,
       m.sha256,
       m.content_type
  FROM booking.entity_media m
 WHERE m.status = 'active';

COMMENT ON VIEW booking.v_supply_media IS
    'bk-023 (AA-835): active supplier photos and where they are stored, for the CIS copy of rights-cleared photos. No uploader or audit column. Read by the CIS runtime (cis_app).';

CREATE OR REPLACE VIEW booking.v_supply_outbox WITH (security_barrier = true) AS
SELECT o.event_id,
       o.event_type,
       o.entity_type,
       o.entity_id,
       o.supply_version,
       o.occurred_at,
       o.feed_seq
  FROM booking.outbox o
 WHERE o.stream = 'supply' AND o.feed_seq IS NOT NULL;

COMMENT ON VIEW booking.v_supply_outbox IS
    'bk-023 (AA-835): supply events visible to readers (feed_seq stamped in commit order by app/outbox.py); the CIS pull pages on feed_seq. Read by the CIS runtime (cis_app).';

-- ── Grants (per object) ──────────────────────────────────────────────────────

-- outbox: the supply columns are written by the supply_outbox trigger, which runs as the writing role (booking).
GRANT INSERT (entity_type, entity_id, supply_version) ON booking.outbox TO booking;

-- entity_media: insert, then only the rights flag, the status and the audit columns change; never deleted.
REVOKE UPDATE, DELETE, TRUNCATE ON booking.entity_media FROM booking;
GRANT SELECT, INSERT ON booking.entity_media TO booking;
GRANT UPDATE (usage_rights, status, updated_by, updated_at) ON booking.entity_media TO booking;

GRANT EXECUTE ON FUNCTION booking.hotels_supply_version() TO booking;
GRANT EXECUTE ON FUNCTION booking.services_supply_version() TO booking;
GRANT EXECUTE ON FUNCTION booking.supply_outbox() TO booking;
GRANT EXECUTE ON FUNCTION booking.hotel_room_types_supply_bump() TO booking;
GRANT EXECUTE ON FUNCTION booking.entity_media_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.entity_media_supply_bump() TO booking;

-- Role booking: read-only on the views (default privileges FOR ROLE bk_owner gave it DML).
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_supply_hotels FROM booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_supply_services FROM booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_supply_media FROM booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_supply_outbox FROM booking;

-- The CIS reader (contract grant; AA-CIS-Infra db/owners.yaml booking.consumer_grants). USAGE is bk-017's.
GRANT SELECT ON booking.v_supply_hotels, booking.v_supply_services, booking.v_supply_media, booking.v_supply_outbox
    TO cis_app;

DO $$
DECLARE
    v_rel TEXT;
BEGIN
    -- cis_app reads the four views and no table behind them.
    FOREACH v_rel IN ARRAY ARRAY['booking.hotels', 'booking.hotel_room_types', 'booking.services',
                                 'booking.entity_media', 'booking.outbox'] LOOP
        IF has_table_privilege('cis_app', v_rel, 'SELECT') THEN
            RAISE EXCEPTION 'bk-023: cis_app can read %', v_rel;
        END IF;
    END LOOP;
    FOREACH v_rel IN ARRAY ARRAY['booking.v_supply_hotels', 'booking.v_supply_services', 'booking.v_supply_media',
                                 'booking.v_supply_outbox'] LOOP
        IF NOT has_table_privilege('cis_app', v_rel, 'SELECT') THEN
            RAISE EXCEPTION 'bk-023: cis_app cannot read %', v_rel;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_class
                        WHERE oid = v_rel::regclass AND 'security_barrier=true' = ANY (reloptions)) THEN
            RAISE EXCEPTION 'bk-023: % is not a security_barrier view', v_rel;
        END IF;
    END LOOP;
    IF has_table_privilege('booking', 'booking.entity_media', 'DELETE') THEN
        RAISE EXCEPTION 'bk-023: role booking can delete supplier photos';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-023', now(), 'AA-835: outbox supply stream (entity_type, entity_id, supply_version, supply.upsert / supply.deactivate), supply_version + triggers on hotels / services (room types and photos bump), entity_media, views v_supply_hotels / v_supply_services / v_supply_media / v_supply_outbox SELECT to cis_app')
ON CONFLICT (version) DO NOTHING;

COMMIT;
