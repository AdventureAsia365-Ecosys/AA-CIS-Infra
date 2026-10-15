-- Migration 235: AA-712 (L4) — catalog.v_tour_place parses the day text only of the tours it is asked for.
--
-- Why. v_tour_place (225, rewritten in 228) joined catalog._tour_day_text on tour_id. A reader's
-- `tour_id = ANY($1)` filter reaches catalog.v_tour inside the view, but Postgres does not carry a
-- ScalarArrayOp across the join's equivalence class, so _tour_day_text split and regex-parsed the
-- itinerary of EVERY live tour (~7k day blocks, ~850 ms on t4g.small) on each call, even for one tour.
-- TripPlanner's browse Lambda calls it twice per destination page and once per tour list (AA-812
-- fallback covers, TripPlanner #77, 15/10): pg_stat_statements showed mean 2.4 s / max 7.7 s; with the
-- 15 reserved Lambda instances busy at once the calls took 6–13 s and the browse Lambda throttled
-- (alarm aa-tripplanner-dev-browse-throttles, five times on 15/10).
--
-- What. The day texts are read through a LATERAL keyed on t.tour_id, aggregated to one jsonb map per tour
-- (day_number -> title || newline || body), so the tour filter reaches _tour_day_text and each requested
-- tour is parsed once. Same columns, same rows, same order semantics: verified on Dev against the 228
-- definition (row-for-row equal for 1 tour, 24 tours, the 85 Nepal tours and the full view of 22,201 rows;
-- 24 tours 904 -> 78 ms, 1 tour 872 -> 12 ms, Nepal 997 -> 262 ms, full view unchanged ~2.4 s).
-- NULL semantics are kept: a NULL title or body gives a NULL map value, ->> returns NULL as before.
--
-- CREATE OR REPLACE keeps the owner (catalog_owner), the grants and the comments of 228. The runner is a
-- member of catalog_owner for this transaction only (225 header). Contract catalog.tour.v1.1 is unchanged.
-- Idempotent, one transaction, self-registering. Applied on Dev by the AA-CIS-Infra DB Migrate workflow
-- from the byte-identical copy in db/migrations/cis/ (S237 migration flow D8); no code depends on it.
--
-- Rollback: re-run the v_tour_place statement of 228_catalog_place_graph_views.sql (with the same
--           catalog_owner membership dance), DELETE FROM shared.schema_versions WHERE version = '235'.

BEGIN;
-- CREATE OR REPLACE VIEW takes an ACCESS EXCLUSIVE lock on v_tour_place: fail fast (and re-run when
-- idle) instead of queueing behind a long reader and blocking every catalog read.
SET LOCAL lock_timeout = '10s';

DO $$
BEGIN
    IF to_regclass('catalog.v_tour_place') IS NULL OR to_regclass('catalog._tour_day_text') IS NULL THEN
        RAISE EXCEPTION 'migration 235: catalog.v_tour_place / catalog._tour_day_text missing (apply 225, 228 first)';
    END IF;
END $$;

GRANT catalog_owner TO CURRENT_USER;

CREATE OR REPLACE VIEW catalog.v_tour_place WITH (security_barrier = true) AS
WITH atom AS (
    SELECT t.source_system, t.source_id, t.tour_id, t.country AS tour_country,
           a.itinerary_day, btrim(a.place) AS place, lower(btrim(a.place)) AS place_key,
           a.atom_id, a.activity_type, a.created_at,
           dm.days ->> a.itinerary_day::text AS day_text,
           pc.card_id
      FROM catalog.v_tour t
      CROSS JOIN LATERAL (
          SELECT jsonb_object_agg(d.day_number::text, d.title || E'\n' || d.body) AS days
            FROM catalog._tour_day_text d
           WHERE d.tour_id = t.tour_id
      ) dm
      -- the v_active_tour_atoms rule (203) on the base table: t is already a live master tour
      JOIN acp_contract.tour_atoms a ON a.tour_id = t.tour_id AND NOT a.deleted AND NOT a.is_empty_marker
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
       g.atom_count,
       d.located_by,
       d.geo_precision AS precision
  FROM grouped g
  LEFT JOIN acp_shared.place_card pc ON pc.card_id = g.place_card_id
  -- 1. the place pipeline's link: the component of this source, day and place (component identity
  --    is name_norm of the itinerary spelling, 226 / services/places/components.py)
  LEFT JOIN LATERAL (
      SELECT gp.destination_id
        FROM geo.tour_place gp
       WHERE gp.source_id = g.source_id
         AND gp.day_index = g.day_number
         AND gp.destination_id IS NOT NULL
         AND geo.name_norm(gp.name) = geo.name_norm(g.place_name)
       ORDER BY gp.component_id
       LIMIT 1
  ) pipeline ON true
  -- 3. 225's exact name + country match (a 226 duplicate row resolves to its keeper); the first USABLE
  --    match, so a suspect card-name match does not hide a usable itinerary-name match
  LEFT JOIN LATERAL (
      SELECT k.id
        FROM shared.destinations dd
        JOIN shared.destinations k ON k.id = COALESCE(dd.duplicate_of, dd.id)
       WHERE lower(dd.name) IN (lower(pc.display_name), lower(g.place_name))
         AND lower(dd.country) = lower(COALESCE(pc.country, g.tour_country))
         AND k.geo_status <> 'suspect' AND k.duplicate_of IS NULL
       ORDER BY (lower(dd.name) = lower(pc.display_name)) DESC NULLS LAST, dd.id
       LIMIT 1
  ) legacy ON true
  -- first usable candidate: pipeline link, 2. the card's destination, legacy match
  LEFT JOIN LATERAL (
      SELECT dd.id, dd.name, dd.lat, dd.lng, dd.located_by, dd.geo_precision
        FROM (VALUES (1, pipeline.destination_id), (2, pc.destination_id), (3, legacy.id)) AS c(rank, id)
        JOIN shared.destinations dd ON dd.id = c.id
       WHERE dd.geo_status <> 'suspect' AND dd.duplicate_of IS NULL
       ORDER BY c.rank
       LIMIT 1
  ) d ON true;

-- privileges are checked when the plan starts: LIMIT 1 raises on a missing grant without a full scan
DO $$
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    SET LOCAL ROLE catalog_owner;
    PERFORM 1 FROM catalog.v_tour_place LIMIT 1;
    RESET ROLE;
END $$;

-- the runner keeps no membership (see 225 header)
REVOKE catalog_owner FROM CURRENT_USER;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('235', now(), 'AA-712 L4: catalog.v_tour_place reads day texts through a LATERAL per tour, so a '
                      'tour_id filter no longer parses every live tour''s itinerary (same columns and rows)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
