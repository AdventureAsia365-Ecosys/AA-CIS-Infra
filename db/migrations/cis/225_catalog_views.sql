-- Migration 225: AA-679 — schema `catalog`: the CIS catalog read model (ADR 0001 decision 1).
--
-- TripPlanner and AA-Booking must stop reading CIS pipeline tables (gold_aa_internal,
-- silver_aa_internal, acp_*). This schema is the stable read model they read instead; the JSON
-- Schema of a catalog tour is AA-Ecosys/docs/contracts/catalog.tour.v1.json. Columns of these views
-- are a contract: add columns freely, but removing/renaming one needs a v2 view (contracts README).
--
-- Identity: (source_system, source_id). source_id = raw_tours.source_group_id, stable across
-- re-uploads (a re-upload is a new tour_id, source_version + 1, same group — migration 052); tour_id
-- is the current CIS version and changes on re-upload.
--
-- What is in the catalog: tours whose Master Content is live — published_tours.master_status =
-- 'active' and not soft-deleted (the rule of acp_contract.v_active_tour_atoms, migration 203) — whose
-- raw source is the active, non-deleted version (the rule of v_trip_registry, migration 195), of the
-- AA master-content tenant 00000000-0000-0000-0000-000000000001 (all AA tours; TripPlanner's
-- MASTER_CONTENT_TENANT_ID).
--
-- RLS: published_tours / raw_tours FORCE row-level security on app.tenant_id. These views are not
-- security_invoker, so they read with their owner's rights; DB Migrate runs as aa_cis_admin
-- (BYPASSRLS, migration 007b). The tenant filter below is therefore what scopes the rows, and
-- readers do not set app.tenant_id. The first statement asserts the runner bypasses RLS: under any
-- other role the views would silently return no rows (or fail on app.tenant_id) for every consumer,
-- so the file fails loudly instead and is not registered.
--
-- Not here: prices (owned by AA-Booking, ADR 0005), events catalog.tour.published|updated|trashed
-- (next AA-679 slice: an outbox; until then consumers poll v_tour and compare content_hash).
--
-- Cross-owner grants are NOT guarded by IF EXISTS(role) (schema-ownership rule 5, ADR 0004
-- decision 6): roles tripplanner and booking must exist; if not, this file fails and is not
-- registered, so it can be re-run.

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles
                    WHERE rolname = current_user AND (rolbypassrls OR rolsuper)) THEN
        RAISE EXCEPTION 'migration 225 must run as a BYPASSRLS role (aa_cis_admin), not %: the catalog '
                        'views read RLS tables with their owner''s rights', current_user;
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS catalog;
COMMENT ON SCHEMA catalog IS
    'AA-679 — CIS catalog read model for other apps (TripPlanner, AA-Booking). Owner: AA-CIS-App. '
    'Contract: AA-Ecosys/docs/contracts/catalog.tour.v1.json.';

-- ── Tours ───────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour WITH (security_barrier = true) AS
WITH live AS (
    SELECT rt.tour_id,
           COALESCE(rt.source_group_id, rt.tour_id)::text AS source_id,
           rt.source_version, rt.sku, rt.country, rt.duration, rt.inclusions, rt.exclusions,
           rt.activities, rt.best_time_to_go, rt.group_size, rt.lifecycle_stage,
           pt.aa_name, pt.aa_subtitle, pt.aa_summary, pt.aa_description, pt.aa_highlights,
           pt.aa_itineraries, pt.published_at
      FROM gold_aa_internal.published_tours pt
      JOIN silver_aa_internal.raw_tours rt ON rt.tour_id = pt.tour_id
     WHERE pt.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
       AND pt.master_status = 'active'
       AND pt.deleted_at IS NULL
       AND rt.source_status = 'active'
       AND rt.deleted_at IS NULL
),
enriched AS (
    SELECT l.*,
           cover.path AS cover_photo_path,
           COALESCE(photos.n, 0) AS photo_count,
           photos.last_update AS photos_updated_at,
           COALESCE(
               substring(lower(l.duration) FROM '(\d+)\s*-?\s*days?')::int,
               (SELECT max(m[1]::int)
                  FROM regexp_matches(l.aa_itineraries, '(?:^|\n)Day\s+(\d+)\s+—', 'g') AS m)
           ) AS duration_days
      FROM live l
      LEFT JOIN shared.v_tour_photos cover ON cover.tour_id = l.tour_id AND cover.position = 1
      LEFT JOIN LATERAL (
          SELECT count(*) AS n, max(p.updated_at) AS last_update
            FROM shared.v_tour_photos p
           WHERE p.tour_id = l.tour_id
      ) photos ON true
)
SELECT 'cis'::text                AS source_system,
       e.source_id,
       e.tour_id,
       e.source_version,
       e.sku,
       trim(BOTH '-' FROM left(regexp_replace(lower(e.aa_name || ' ' || COALESCE(e.country, '')),
                                              '[^a-z0-9]+', '-', 'g'), 80))
           || '-' || left(replace(e.source_id, '-', ''), 8) AS slug,
       e.aa_name                  AS title,
       e.aa_subtitle              AS subtitle,
       e.aa_summary               AS summary,
       e.aa_description           AS description,
       e.aa_highlights            AS highlights,
       e.country,
       e.duration                 AS duration_raw,
       e.duration_days,
       e.activities,
       e.inclusions,
       e.exclusions,
       e.best_time_to_go,
       e.group_size,
       e.lifecycle_stage::text    AS lifecycle_stage,
       e.aa_itineraries           AS itinerary_text,
       e.cover_photo_path,
       e.photo_count,
       e.published_at,
       -- not a change cursor: published_tours has no updated_at, so an in-place Master Content edit
       -- moves content_hash but not this. Consumers diff content_hash (contract catalog.tour.v1).
       GREATEST(e.published_at, e.photos_updated_at) AS updated_at,
       md5(jsonb_build_array(
           e.aa_name, e.aa_subtitle, e.aa_summary, e.aa_description, e.aa_highlights, e.aa_itineraries,
           e.country, e.duration, e.activities, e.inclusions, e.exclusions, e.best_time_to_go,
           e.group_size, e.lifecycle_stage::text, e.sku, e.cover_photo_path
       )::text)                   AS content_hash
  FROM enriched e;

COMMENT ON VIEW catalog.v_tour IS
    'AA-679 — live AA tours (Master Content active, active source). Key (source_system, source_id); '
    'contract catalog.tour.v1. updated_at is informative, not a change cursor: re-sync on content_hash.';

-- ── Day text (internal: not part of the contract, not granted) ────────────────────────────────
-- Days parsed from the canonical master itinerary "Day N — Title\nBody" (graph.py
-- _process_itineraries, AA-353; Python twin itinerary_utils.parse_canonical_itinerary_days).
CREATE OR REPLACE VIEW catalog._tour_day_text WITH (security_barrier = true) AS
WITH chunk AS (
    SELECT t.source_system, t.source_id, t.tour_id, t.country AS tour_country, c.ord,
           regexp_match(btrim(c.txt, E' \t\r\n'), '^Day\s+(\d+)\s+—[ \t]*([^\n]*)(.*)$') AS m
      FROM catalog.v_tour t
     CROSS JOIN LATERAL regexp_split_to_table(t.itinerary_text, '\n(?=Day\s+\d+\s+—)')
           WITH ORDINALITY AS c(txt, ord)
     WHERE t.itinerary_text IS NOT NULL
)
-- a repeated day number keeps the LAST block (parse_canonical_itinerary_days dict semantics)
SELECT DISTINCT ON (tour_id, (m[1])::int)
       source_system, source_id, tour_id, tour_country,
       (m[1])::int             AS day_number,
       btrim(m[2])             AS title,
       btrim(m[3], E' \t\r\n') AS body
  FROM chunk
 WHERE m IS NOT NULL
 ORDER BY tour_id, (m[1])::int, ord DESC;

COMMENT ON VIEW catalog._tour_day_text IS
    'AA-679 — INTERNAL helper of v_tour_day / v_tour_place (parsed day title + body). Not part of '
    'contract catalog.tour.v1 and not granted to consumers; may change without notice.';

-- ── Places per tour day (from active atoms) ─────────────────────────────────────────────────────
-- Order within a day = itinerary order: where the place first appears (case-insensitive) in that
-- day's title + body. Atoms of a tour are written in one a3_atomize run with random ids
-- (atom_<uuid hex>), so created_at / atom_id carry no order; they are only the fallback for a place
-- the day text does not name, then the place key (C collation) so the result never depends on a
-- random id. Spelling: the one that appears verbatim in the day text, else the most frequent, else
-- the first in C collation — deterministic for the same data.
CREATE OR REPLACE VIEW catalog.v_tour_place WITH (security_barrier = true) AS
WITH atom AS (
    SELECT t.source_system, t.source_id, t.tour_id, t.country AS tour_country,
           a.itinerary_day, btrim(a.place) AS place, lower(btrim(a.place)) AS place_key,
           a.atom_id, a.activity_type, a.created_at,
           dt.title || E'\n' || dt.body AS day_text,
           pc.card_id
      FROM catalog.v_tour t
      JOIN acp_contract.v_active_tour_atoms a ON a.tour_id = t.tour_id
      LEFT JOIN catalog._tour_day_text dt ON dt.tour_id = t.tour_id AND dt.day_number = a.itinerary_day
      LEFT JOIN acp_shared.atom_place_card apc ON apc.atom_id = a.atom_id
      LEFT JOIN acp_shared.place_card pc ON pc.card_id = apc.card_id AND pc.status <> 'rejected'
     WHERE a.place IS NOT NULL AND btrim(a.place) <> ''
),
spelled AS (
    SELECT atom.*,
           count(*) OVER (PARTITION BY tour_id, itinerary_day, place) AS spelling_n,
           strpos(COALESCE(day_text, ''), place) > 0                  AS spelled_in_text
      FROM atom
),
grouped AS (
    SELECT source_system, source_id, tour_id, tour_country,
           itinerary_day                                                      AS day_number,
           place_key,
           (array_agg(place ORDER BY spelled_in_text DESC, spelling_n DESC,
                                     place COLLATE "C"))[1]                   AS place_name,
           (array_agg(card_id ORDER BY created_at, card_id)
                FILTER (WHERE card_id IS NOT NULL))[1]                        AS place_card_id,
           array_agg(DISTINCT activity_type) FILTER (WHERE activity_type IS NOT NULL) AS activity_types,
           count(*)                                                           AS atom_count,
           min(created_at)                                                    AS first_seen_at,
           NULLIF(strpos(lower(COALESCE(max(day_text), '')), place_key), 0)   AS text_pos
      FROM spelled
     GROUP BY source_system, source_id, tour_id, tour_country, itinerary_day, place_key
)
SELECT g.source_system, g.source_id, g.tour_id, g.day_number,
       row_number() OVER (PARTITION BY g.tour_id, g.day_number
                          ORDER BY g.text_pos NULLS LAST, g.first_seen_at,
                                   g.place_key COLLATE "C") AS position,
       g.place_name,
       g.place_card_id,
       pc.display_name AS place_display_name,
       pc.locality,
       pc.region,
       COALESCE(pc.country, g.tour_country) AS country,
       d.id   AS destination_id,
       d.name AS destination_name,
       d.lat,
       d.lng,
       COALESCE(g.activity_types, ARRAY[]::text[]) AS activity_types,
       g.atom_count
  FROM grouped g
  LEFT JOIN acp_shared.place_card pc ON pc.card_id = g.place_card_id
  LEFT JOIN LATERAL (
      SELECT dd.id, dd.name, dd.lat, dd.lng
        FROM shared.destinations dd
       WHERE lower(dd.name) IN (lower(pc.display_name), lower(g.place_name))
         AND lower(dd.country) = lower(COALESCE(pc.country, g.tour_country))
       ORDER BY (lower(dd.name) = lower(pc.display_name)) DESC NULLS LAST, dd.id
       LIMIT 1
  ) d ON true;

COMMENT ON VIEW catalog.v_tour_place IS
    'AA-679 — places of a live tour per itinerary day, from active atoms (+ AA-772 place card, + '
    'shared.destinations lat/lng on exact name and country match). day_number NULL = atom without a day. '
    'position = order of first mention in the day text; places the text does not name come after, '
    'in a stable but not itinerary-meaningful order.';

-- ── Day-by-day itinerary ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour_day WITH (security_barrier = true) AS
SELECT d.source_system, d.source_id, d.tour_id, d.day_number, d.title, d.body,
       COALESCE((SELECT array_agg(p.place_name ORDER BY p.position)
                   FROM catalog.v_tour_place p
                  WHERE p.tour_id = d.tour_id AND p.day_number = d.day_number),
                ARRAY[]::text[]) AS places
  FROM catalog._tour_day_text d;

COMMENT ON VIEW catalog.v_tour_day IS
    'AA-679 — day-by-day itinerary of a live tour, parsed from the canonical master itinerary. '
    'A tour whose text is not canonical has no rows (v_tour.itinerary_text keeps the full text).';

-- ── Photos ──────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour_photo WITH (security_barrier = true) AS
SELECT t.source_system, t.source_id, p.tour_id, p.photo_id, p.path, p.place_label, p.destination_id,
       p.width, p.height, p.position, p.updated_at
  FROM catalog.v_tour t
  JOIN shared.v_tour_photos p ON p.tour_id = t.tour_id;

COMMENT ON VIEW catalog.v_tour_photo IS
    'AA-679 — matched AA photos of a live tour. path is relative to the CIS public API base '
    '({base}{path}?size=large|small, migration 200); position 1 = cover.';

-- ── Destinations ────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_destination WITH (security_barrier = true) AS
SELECT 'cis'::text      AS source_system,
       d.id::text       AS source_id,
       d.id             AS destination_id,
       d.name,
       d.country,
       d.lat,
       d.lng,
       cover.path       AS cover_photo_path,
       d.cover_image_url,
       COALESCE(photos.n, 0) AS photo_count,
       d.created_at,
       GREATEST(d.created_at, d.located_at, photos.last_update) AS updated_at
  FROM shared.destinations d
  LEFT JOIN shared.v_destination_photos cover ON cover.destination_id = d.id AND cover.position = 1
  LEFT JOIN LATERAL (
      SELECT count(*) AS n, max(p.updated_at) AS last_update
        FROM shared.v_destination_photos p
       WHERE p.destination_id = d.id
  ) photos ON true;

COMMENT ON VIEW catalog.v_destination IS
    'AA-679 — golden record of places (shared.destinations, CIS-owned since ADR 0002) + AA cover photo.';

CREATE OR REPLACE VIEW catalog.v_destination_photo WITH (security_barrier = true) AS
SELECT p.destination_id, p.photo_id, p.path, p.place_label, p.tour_id, p.width, p.height,
       p.position, p.updated_at
  FROM shared.v_destination_photos p;

COMMENT ON VIEW catalog.v_destination_photo IS
    'AA-679 — matched AA photos per destination (path as in catalog.v_tour_photo); position 1 = cover.';

-- ── Grants (unguarded, see header) ──────────────────────────────────────────────────────────────
GRANT USAGE ON SCHEMA catalog TO aa_app_user, tripplanner, booking;
GRANT SELECT ON catalog.v_tour, catalog.v_tour_day, catalog.v_tour_place, catalog.v_tour_photo,
                catalog.v_destination, catalog.v_destination_photo
    TO aa_app_user, tripplanner, booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('225', now(), 'AA-679: schema catalog (CIS read model) — v_tour, v_tour_day, v_tour_place, '
                      'v_tour_photo, v_destination, v_destination_photo; SELECT to aa_app_user, '
                      'tripplanner, booking')
ON CONFLICT (version) DO NOTHING;

COMMIT;
