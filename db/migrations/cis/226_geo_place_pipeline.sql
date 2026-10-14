-- Migration 226: AA-712 — the place pipeline moves into CIS (ADR 0007 "Place pipeline data model",
-- design AA-Ecosys/docs/audits/2026-10-14-S236-design-review/aa712/03-design.md §2 + §3 + §4).
--
-- 1. Schema `geo` (CIS-internal, never granted to another app): the derived place data of every live
--    tour — day skeleton, places (= itinerary components), the name-resolution cache and the tour
--    graph (stops, nodes, edges, legs, junctions) as versioned builds. Rows are keyed by source_id
--    (= COALESCE(raw_tours.source_group_id, tour_id), the catalog.v_tour identity), tour_id is the
--    version they were built from. Readers get catalog.* views (migration 227, not this file); until
--    then nothing outside CIS reads geo.*. Written only by the job kinds place_extract,
--    place_geocode and tour_graph_build (services/jobs/place_*_job.py, tour_graph_job.py).
-- 2. shared.destinations (CIS-owned since ADR 0002) gains geo_status / confidence / geocoder ids /
--    name_norm / locality_norm / duplicate_of, and the key UNIQUE (name_norm, lower(country),
--    locality_norm) — the same name in two countries is two places (design Q2). The old global
--    UNIQUE lower(name) stays until TripPlanner's writers are off (dropped by a later migration). Every existing id is kept (place_photo, covers and TripPlanner trip events point at
--    them). Before the new index: blank countries are filled from the tours that use the place
--    (TripPlanner's backfill_country rule, when its tables are readable) or the row is marked
--    suspect; rows that collide on the new key keep one keeper, the others get duplicate_of = keeper
--    and geo_status = 'suspect' (no row is deleted, no FK moves). located_by also accepts
--    'geoapify' (the confirming geocoder, S236) and 'manual' (admin fix); geo_precision
--    (point | area), geocoder_provider / geocoded_at / geocoder_meta (audit + re-run on another
--    provider without a migration) and review_reason (unconfirmed hard place kinds → /admin/places).
--    Geoapify / OpenStreetMap ATTRIBUTION is required wherever these coordinates are shown.
--    geo.name_norm(text) is the SQL twin of services/places/names.py::name_norm — the same 504-letter
--    accent table; tests/integration/test_aa712_migration_226.py compares both on real Postgres.
-- 3. acp_shared.place_card.destination_id: a card resolves once to a destination (design §2.2).
-- 4. Stage keys (shared.llm_role_config, ON CONFLICT DO NOTHING — an admin change is never
--    overwritten; SAFE_DEFAULTS in shared/llm_client/role_config.py mirrors them):
--      a3_place_days   validate  Sonnet (acc3), shadow GPT-5.6 Luna (Bedrock acc3) at 20%  (design Q4)
--      a3_place_locate validate  Sonnet (acc3)
--      a3_place_embed  embed     Cohere Embed v4 (acc2), 1536-d = TripPlanner's tp_search_embed
--    `validate` (ADR 0008): extraction of reference data, never scored by a judge, any vendor.
-- 5. shared.spend_budget: provider 'geocoder' (Geoapify; Free plan = $0, the daily credit guard is
--    GEOAPIFY_DAILY_CREDIT_LIMIT — the $ rows matter only on a paid plan) + rows job:place_extract ($5/run, $40/day of that kind's own spend),
--    job:place_geocode ($3/run Bedrock; $50/run geocoder) and geocoder global $25/day (design §8).
--
-- pgvector: geo.tour_place.embedding vector(1536) + HNSW only where the `vector` type exists (RDS has
-- it since migration 041). The CI Postgres image has no pgvector: the column is then skipped with a
-- NOTICE and the jobs store no embedding (services/places/store.py checks the column).
--
-- RLS (lesson S236): no view here, so no catalog_owner dance. The only FORCE-RLS read is the blank
-- country fill (raw_tours), scoped with set_config('app.tenant_id', AA master, true) so it works for
-- a runner that is not BYPASSRLS. Views over geo.* (227) follow the 225 catalog_owner pattern.
--
-- Idempotent (IF NOT EXISTS / ON CONFLICT DO NOTHING / guarded DO blocks), one transaction,
-- self-registering. Applied on Dev by the AA-CIS-Infra DB Migrate workflow from the byte-identical
-- copy in db/migrations/cis/, BEFORE the code that uses it merges.

BEGIN;
-- The ALTERs on acp_shared.place_card / shared.destinations take ACCESS EXCLUSIVE locks: fail fast
-- (and re-run when idle) instead of queueing behind a long job transaction and blocking every reader.
SET LOCAL lock_timeout = '10s';

-- ── 0. Preconditions ──────────────────────────────────────────────────────────────────────────
-- shared.destinations was created by TripPlanner migrations 002/005: the runner must own it (or be a
-- member of its owner) to ALTER it. Fail with a clear message instead of a bare "must be owner".
DO $$
DECLARE
    o text;
BEGIN
    SELECT tableowner INTO o FROM pg_tables WHERE schemaname = 'shared' AND tablename = 'destinations';
    IF o IS NULL THEN
        RAISE EXCEPTION 'migration 226: shared.destinations does not exist';
    END IF;
    IF NOT pg_has_role(current_user, o, 'USAGE') THEN
        RAISE EXCEPTION 'migration 226: % cannot ALTER shared.destinations (owner %): ALTER TABLE '
                        'shared.destinations OWNER TO % first (ADR 0002: CIS owns it)', current_user, o, current_user;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector')
       AND EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'vector') THEN
        BEGIN
            CREATE EXTENSION IF NOT EXISTS vector;
        EXCEPTION WHEN insufficient_privilege THEN
            RAISE NOTICE 'migration 226: cannot create extension vector (%), embeddings skipped', SQLERRM;
        END;
    END IF;
END $$;

-- ── 1. Schema geo ────────────────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS geo;
COMMENT ON SCHEMA geo IS
    'AA-712 — CIS place pipeline (ADR 0007): day skeleton, places, name cache, tour graph builds. '
    'CIS-internal; other apps read catalog.* views only. Written by jobs place_extract, place_geocode, '
    'tour_graph_build.';
REVOKE ALL ON SCHEMA geo FROM PUBLIC;

-- SQL twin of services/places/names.py::name_norm (keep both in sync; the integration test compares).
CREATE OR REPLACE FUNCTION geo.name_norm(p text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $fn$
    SELECT COALESCE(NULLIF(regexp_replace(s, '^((the|a|an) )+', ''), ''), s)
      FROM (
        SELECT btrim(regexp_replace(
                   replace(lower(translate(
                       replace(replace(replace(replace(replace(replace(COALESCE(p, ''),
                           'ß', 'ss'), 'æ', 'ae'), 'Æ', 'ae'), 'œ', 'oe'), 'Œ', 'oe'), '’', ''''),
                       'ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝàáâãäåçèéêëìíîïñòóôõöùúûüýÿĀāĂăĄąĆćĈĉĊċČčĎďĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĨĩĪīĬĭĮįİĴĵĶķĹĺĻļĽľŃńŅņŇňŌōŎŏŐőŔŕŖŗŘřŚśŜŝŞşŠšŢţŤťŨũŪūŬŭŮůŰűŲųŴŵŶŷŸŹźŻżŽžſƠơƯưǍǎǏǐǑǒǓǔǕǖǗǘǙǚǛǜǞǟǠǡǦǧǨǩǪǫǬǭǰǴǵǸǹǺǻȀȁȂȃȄȅȆȇȈȉȊȋȌȍȎȏȐȑȒȓȔȕȖȗȘșȚțȞȟȦȧȨȩȪȫȬȭȮȯȰȱȲȳḀḁḂḃḄḅḆḇḈḉḊḋḌḍḎḏḐḑḒḓḔḕḖḗḘḙḚḛḜḝḞḟḠḡḢḣḤḥḦḧḨḩḪḫḬḭḮḯḰḱḲḳḴḵḶḷḸḹḺḻḼḽḾḿṀṁṂṃṄṅṆṇṈṉṊṋṌṍṎṏṐṑṒṓṔṕṖṗṘṙṚṛṜṝṞṟṠṡṢṣṤṥṦṧṨṩṪṫṬṭṮṯṰṱṲṳṴṵṶṷṸṹṺṻṼṽṾṿẀẁẂẃẄẅẆẇẈẉẊẋẌẍẎẏẐẑẒẓẔẕẖẗẘẙẛẠạẢảẤấẦầẨẩẪẫẬậẮắẰằẲẳẴẵẶặẸẹẺẻẼẽẾếỀềỂểỄễỆệỈỉỊịỌọỎỏỐốỒồỔổỖỗỘộỚớỜờỞởỠỡỢợỤụỦủỨứỪừỬửỮữỰựỲỳỴỵỶỷỸỹđĐøØłŁıħĦŧŦƀɨʉ',
                       'aaaaaaceeeeiiiinooooouuuuyaaaaaaceeeeiiiinooooouuuuyyaaaaaaccccccccddeeeeeeeeeegggggggghhiiiiiiiiijjkkllllllnnnnnnoooooorrrrrrssssssssttttuuuuuuuuuuuuwwyyyzzzzzzsoouuaaiioouuuuuuuuuuaaaaggkkoooojggnnaaaaaaeeeeiiiioooorrrruuuusstthhaaeeooooooooyyaabbbbbbccddddddddddeeeeeeeeeeffgghhhhhhhhhhiiiikkkkkkllllllllmmmmmmnnnnnnnnoooooooopppprrrrrrrrssssssssssttttttttuuuuuuuuuuvvvvwwwwwwwwwwxxxxyyzzzzzzhtwysaaaaaaaaaaaaaaaaaaaaaaaaeeeeeeeeeeeeeeeeiiiioooooooooooooooooooooooouuuuuuuuuuuuuuyyyyyyyyddoollihhttbiu')), '''', ''),
                   '[^a-z0-9]+', ' ', 'g')) AS s
      ) x
$fn$;
COMMENT ON FUNCTION geo.name_norm(text) IS
    'AA-712 — place-name key (accent-folded, lowercased, punctuation to space, leading the/a/an dropped). '
    'Twin of services/places/names.py::name_norm.';

-- Per source (tour identity): what was built, from which version, with which inputs.
CREATE TABLE IF NOT EXISTS geo.tour_build (
    source_id        text PRIMARY KEY,
    tour_id          uuid NOT NULL,
    country          text,
    days_hash        text,
    components_hash  text,
    rule_version     integer NOT NULL DEFAULT 0,
    status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'ok', 'partial', 'failed', 'retired')),
    counts           jsonb NOT NULL DEFAULT '{}'::jsonb,
    cost_usd         numeric(10, 6) NOT NULL DEFAULT 0,
    built_at         timestamptz,
    job_id           uuid,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE geo.tour_build IS
    'AA-712 — one row per tour source: built_from tour_id, days_hash (gates the paid a3_place_days call), '
    'components_hash (gates components/link/embed), status, counts, cost. Row-locked (FOR UPDATE) by '
    'place_extract while it persists, so an older version''s job never overwrites a newer build.';

CREATE TABLE IF NOT EXISTS geo.tour_day (
    source_id                 text NOT NULL,
    day_index                 integer NOT NULL,
    tour_id                   uuid NOT NULL,
    title                     text,
    start_place               text,
    end_place                 text,
    overnight_place           text,
    anchor_place              text,
    anchor_norm               text,
    anchor_country_norm       text,
    anchor_locality_norm      text NOT NULL DEFAULT '',
    overnight_destination_id  uuid REFERENCES shared.destinations(id) ON DELETE SET NULL,
    places                    text[] NOT NULL DEFAULT '{}',
    extracted_by              text NOT NULL DEFAULT 'rule' CHECK (extracted_by IN ('rule', 'llm', 'rule+llm')),
    is_transit_day            boolean NOT NULL DEFAULT false,
    created_at                timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source_id, day_index)
);
CREATE INDEX IF NOT EXISTS tour_day_unlinked_anchor_idx
    ON geo.tour_day (anchor_norm, anchor_country_norm, anchor_locality_norm)
    WHERE overnight_destination_id IS NULL AND anchor_norm IS NOT NULL;
COMMENT ON TABLE geo.tour_day IS
    'AA-712 — day skeleton per tour source (port of TripPlanner tour_day, AA-675): start / end / overnight '
    'place text, the night''s map anchor and its destination once resolved. Replaced per source in one '
    'transaction.';

CREATE TABLE IF NOT EXISTS geo.tour_place (
    component_id     uuid PRIMARY KEY,
    source_id        text NOT NULL,
    tour_id          uuid NOT NULL,
    day_index        integer NOT NULL,
    name             text NOT NULL,
    name_norm        text NOT NULL,
    country          text NOT NULL,
    country_norm     text NOT NULL,
    locality_norm    text NOT NULL DEFAULT '',
    destination_id   uuid REFERENCES shared.destinations(id) ON DELETE SET NULL,
    place_card_id    uuid REFERENCES acp_shared.place_card(card_id) ON DELETE SET NULL,
    activity         text NOT NULL CHECK (activity IN ('trekking', 'cultural_heritage', 'wildlife_nature',
                                                       'water_activities', 'culinary', 'wellness_relaxation',
                                                       'adventure_sport', 'local_immersion')),
    intensity_level  text NOT NULL CHECK (intensity_level IN ('leisurely', 'moderate', 'active', 'strenuous')),
    season_months    integer[] NOT NULL DEFAULT '{1,2,3,4,5,6,7,8,9,10,11,12}',
    duration_hint    text NOT NULL CHECK (duration_hint IN ('half_day', 'full_day', 'overnight', 'multi_night')),
    text_extract     text NOT NULL,
    text_hash        text NOT NULL,
    atom_ids         text[] NOT NULL DEFAULT '{}',
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tour_place_source_idx ON geo.tour_place (source_id, day_index);
CREATE INDEX IF NOT EXISTS tour_place_destination_idx ON geo.tour_place (destination_id);
CREATE INDEX IF NOT EXISTS tour_place_unlinked_idx ON geo.tour_place (name_norm, country_norm, locality_norm)
    WHERE destination_id IS NULL;
COMMENT ON TABLE geo.tour_place IS
    'AA-712 — places of a tour (= TripPlanner itinerary_components): one per (source, day, place, '
    'activity), component_id = uuid5 of that key (stable across re-atomize / re-upload). destination_id '
    'NULL until the name is resolved (views hide it). embedding reused while text_hash is unchanged.';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'vector') THEN
        EXECUTE 'ALTER TABLE geo.tour_place ADD COLUMN IF NOT EXISTS embedding vector(1536)';
        EXECUTE 'CREATE INDEX IF NOT EXISTS tour_place_embedding_hnsw ON geo.tour_place '
                'USING hnsw (embedding vector_cosine_ops)';
    ELSE
        RAISE NOTICE 'migration 226: type vector missing, geo.tour_place.embedding not created';
    END IF;
END $$;

-- Name → destination resolution cache. Single writer of status: place_geocode (place_extract only
-- inserts new names as pending, ON CONFLICT DO NOTHING).
CREATE TABLE IF NOT EXISTS geo.place_name (
    name_norm       text NOT NULL,
    country_norm    text NOT NULL,
    locality_norm   text NOT NULL DEFAULT '',
    display_name    text NOT NULL,
    country         text NOT NULL,
    locality        text,
    tour_name       text,
    destination_id  uuid REFERENCES shared.destinations(id) ON DELETE SET NULL,
    place_card_id   uuid REFERENCES acp_shared.place_card(card_id) ON DELETE SET NULL,
    status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'resolved', 'unknown', 'suspect')),
    tries           integer NOT NULL DEFAULT 0,
    last_error      text,
    next_retry_at   timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (name_norm, country_norm, locality_norm)
);
CREATE INDEX IF NOT EXISTS place_name_due_idx ON geo.place_name (next_retry_at) WHERE status = 'pending';
COMMENT ON TABLE geo.place_name IS
    'AA-712 — place-name resolution cache per (name_norm, country_norm, locality_norm; locality only for '
    'generic names). pending → resolved | unknown (after 3 tries) | suspect. Geocode once per place, '
    'never per tour.';

-- Outlier observations (design §4): a destination far from the tour's neighbouring stops on a day
-- whose text has no transit keyword. Two tours (or one with an LLM-only point) make it suspect.
CREATE TABLE IF NOT EXISTS geo.place_outlier (
    destination_id  uuid NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    source_id       text NOT NULL,
    day_index       integer NOT NULL,
    km              numeric(8, 1) NOT NULL,
    observed_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (destination_id, source_id, day_index)
);
COMMENT ON TABLE geo.place_outlier IS
    'AA-712 — a destination > 600 km from every stop of the same tour within ±2 days on a non-transit day. Feeds '
    'geo_status = suspect (≥2 tours, or ≥1 when located_by = llm) and the /admin/places fix list.';

-- Paid geocoder requests (cost guard day spend for provider 'geocoder', /admin/places cost).
CREATE TABLE IF NOT EXISTS geo.geocode_call (
    id         bigserial PRIMARY KEY,
    called_at  timestamptz NOT NULL DEFAULT now(),
    provider   text NOT NULL,
    requests   integer NOT NULL,
    cost_usd   numeric(10, 6) NOT NULL DEFAULT 0,
    job_id     uuid
);
CREATE INDEX IF NOT EXISTS geocode_call_called_at_idx ON geo.geocode_call (called_at);
COMMENT ON TABLE geo.geocode_call IS
    'AA-712 — external geocoder requests per batch (model_only writes none). Day spend of the cost-guard '
    'provider geocoder.';

-- Tour graph: versioned builds (ADR 0003 §3 swap). One current build; the current + 2 previous are kept.
CREATE TABLE IF NOT EXISTS geo.graph_build (
    build_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    params      jsonb NOT NULL DEFAULT '{}'::jsonb,
    stats       jsonb NOT NULL DEFAULT '{}'::jsonb,
    is_current  boolean NOT NULL DEFAULT false,
    built_at    timestamptz NOT NULL DEFAULT now(),
    job_id      uuid
);
CREATE UNIQUE INDEX IF NOT EXISTS graph_build_one_current_uq ON geo.graph_build (is_current) WHERE is_current;

CREATE TABLE IF NOT EXISTS geo.tour_stop (
    build_id        uuid NOT NULL REFERENCES geo.graph_build(build_id) ON DELETE CASCADE,
    source_id       text NOT NULL,
    day_index       integer NOT NULL,
    destination_id  uuid NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    country         text,
    source          text NOT NULL CHECK (source IN ('overnight', 'component')),
    PRIMARY KEY (build_id, source_id, day_index)
);
CREATE TABLE IF NOT EXISTS geo.graph_node (
    build_id        uuid NOT NULL REFERENCES geo.graph_build(build_id) ON DELETE CASCADE,
    destination_id  uuid NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    name            text NOT NULL,
    country         text,
    lat             double precision NOT NULL,
    lng             double precision NOT NULL,
    source_ids      text[] NOT NULL DEFAULT '{}',
    stop_count      integer NOT NULL DEFAULT 0,
    activities      text[] NOT NULL DEFAULT '{}',
    intensity_min   text,
    intensity_max   text,
    season_months   integer[] NOT NULL DEFAULT '{}',
    PRIMARY KEY (build_id, destination_id)
);
CREATE TABLE IF NOT EXISTS geo.graph_edge (
    build_id             uuid NOT NULL REFERENCES geo.graph_build(build_id) ON DELETE CASCADE,
    from_destination_id  uuid NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    to_destination_id    uuid NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    tour_count           integer NOT NULL,
    source_ids           text[] NOT NULL DEFAULT '{}',
    km                   numeric(8, 1),
    PRIMARY KEY (build_id, from_destination_id, to_destination_id)
);
CREATE TABLE IF NOT EXISTS geo.tour_leg (
    build_id              uuid NOT NULL REFERENCES geo.graph_build(build_id) ON DELETE CASCADE,
    source_id             text NOT NULL,
    day_from              integer NOT NULL,
    day_to                integer NOT NULL,
    days                  integer NOT NULL,
    start_destination_id  uuid NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    end_destination_id    uuid NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    destination_ids       uuid[] NOT NULL,
    countries             text[] NOT NULL DEFAULT '{}',
    activities            text[] NOT NULL DEFAULT '{}',
    PRIMARY KEY (build_id, source_id, day_from, day_to)
);
CREATE INDEX IF NOT EXISTS tour_leg_countries_gin ON geo.tour_leg USING gin (countries);
CREATE TABLE IF NOT EXISTS geo.tour_junction (
    build_id       uuid NOT NULL REFERENCES geo.graph_build(build_id) ON DELETE CASCADE,
    destination_a  uuid NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    destination_b  uuid NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    km             numeric(8, 1) NOT NULL,
    cross_border   boolean NOT NULL DEFAULT false,
    PRIMARY KEY (build_id, destination_a, destination_b)
);
COMMENT ON TABLE geo.graph_build IS
    'AA-712 — one row per tour graph build (tour_graph_build job). is_current marks the build views read; '
    'the swap sets it in one transaction and deletes builds older than the current + 2.';

REVOKE ALL ON ALL TABLES IN SCHEMA geo FROM PUBLIC;

-- ── 2. shared.destinations ───────────────────────────────────────────────────────────────────
ALTER TABLE shared.destinations
    ADD COLUMN IF NOT EXISTS geo_status        text NOT NULL DEFAULT 'ok',
    ADD COLUMN IF NOT EXISTS confidence        real,
    ADD COLUMN IF NOT EXISTS geocoder_place_id text,
    ADD COLUMN IF NOT EXISTS geo_checked_at    timestamptz,
    ADD COLUMN IF NOT EXISTS name_norm         text,
    ADD COLUMN IF NOT EXISTS locality_norm     text NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS duplicate_of      uuid REFERENCES shared.destinations(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS geo_precision     text,
    ADD COLUMN IF NOT EXISTS geocoder_provider text,
    ADD COLUMN IF NOT EXISTS geocoded_at       timestamptz,
    ADD COLUMN IF NOT EXISTS geocoder_meta     jsonb,
    ADD COLUMN IF NOT EXISTS review_reason     text;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'shared.destinations'::regclass
                    AND conname = 'destinations_geo_status_check') THEN
        ALTER TABLE shared.destinations ADD CONSTRAINT destinations_geo_status_check
            CHECK (geo_status IN ('ok', 'suspect', 'manual'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'shared.destinations'::regclass
                    AND conname = 'destinations_geo_precision_check') THEN
        ALTER TABLE shared.destinations ADD CONSTRAINT destinations_geo_precision_check
            CHECK (geo_precision IS NULL OR geo_precision IN ('point', 'area'));
    END IF;
END $$;

-- located_by (TripPlanner 005: mapbox | llm) also takes the adapter and admin values.
DO $$
DECLARE
    c record;
BEGIN
    FOR c IN SELECT conname FROM pg_constraint
              WHERE conrelid = 'shared.destinations'::regclass AND contype = 'c'
                AND pg_get_constraintdef(oid) LIKE '%located_by%'
                AND pg_get_constraintdef(oid) NOT LIKE '%geoapify%'
    LOOP
        EXECUTE format('ALTER TABLE shared.destinations DROP CONSTRAINT %I', c.conname);
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'shared.destinations'::regclass
                    AND conname = 'destinations_located_by_check') THEN
        ALTER TABLE shared.destinations ADD CONSTRAINT destinations_located_by_check
            CHECK (located_by IN ('mapbox', 'llm', 'geoapify', 'manual'));
    END IF;
END $$;

COMMENT ON COLUMN shared.destinations.geo_status IS
    'AA-712 — ok | suspect (outlier / duplicate / no country: excluded from graph views, listed on '
    '/admin/places) | manual (admin-fixed coordinates: never overwritten by a job).';
COMMENT ON COLUMN shared.destinations.geocoder_place_id IS
    'AA-712 — the external geocoder''s id of the confirming result (Geoapify place_id).';
COMMENT ON COLUMN shared.destinations.located_by IS
    'AA-712 — geoapify (confirmed by Geoapify / OpenStreetMap: show "Powered by Geoapify" + '
    '"© OpenStreetMap contributors" wherever the point is shown) | llm (the model''s point, area precision) | '
    'manual (admin fix) | mapbox (legacy TripPlanner row, re-confirmed by the CIS pipeline).';
COMMENT ON COLUMN shared.destinations.geo_precision IS
    'AA-712 — point (geocoder-confirmed or admin) | area (the model''s own point: show as an area, not a pin); '
    'NULL = legacy row not yet processed by the CIS pipeline.';
COMMENT ON COLUMN shared.destinations.geocoder_meta IS
    'AA-712 — audit of the last geocoder check: provider, outcome, query, result_type, raw rank.confidence '
    '(recorded, never a gate), name similarity, km to the model point, attribution.';
COMMENT ON COLUMN shared.destinations.review_reason IS
    'AA-712 — set when the row needs a human look on /admin/places (unconfirmed_hard_type: a temple / pass / '
    'lake / village… no geocoder confirmed).';
COMMENT ON COLUMN shared.destinations.name_norm IS
    'AA-712 — geo.name_norm(name); key (name_norm, lower(country), locality_norm) is unique among non-duplicates.';
COMMENT ON COLUMN shared.destinations.locality_norm IS
    'AA-712 — '''' for a distinctive name; the locality key of a generic name ("Base Camp", "Night Market").';
COMMENT ON COLUMN shared.destinations.duplicate_of IS
    'AA-712 — set by migration 226 on a row that collided with a keeper on the new key; kept for its '
    'existing references, never linked by the jobs.';

-- 2a. name_norm for every row that has none (a job-written row already has the Python value).
UPDATE shared.destinations SET name_norm = NULLIF(geo.name_norm(name), '') WHERE name_norm IS NULL;

-- 2b. blank country: the mode of the countries of the tours that use the place (TripPlanner's
--     backfill_country rule), read only when TripPlanner's tables exist and are readable here.
DO $$
DECLARE
    n bigint;
BEGIN
    IF to_regclass('tripplanner.itinerary_components') IS NOT NULL
       AND to_regclass('tripplanner.tour_day') IS NOT NULL
       AND EXISTS (SELECT 1 FROM shared.destinations WHERE NULLIF(btrim(country), '') IS NULL) THEN
        BEGIN
            PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000001', true);
            EXECUTE $q$
                UPDATE shared.destinations d SET country = m.country
                  FROM (SELECT u.dest_id, mode() WITHIN GROUP (ORDER BY btrim(rt.country)) AS country
                          FROM (SELECT destination_id AS dest_id, source_tour_id
                                  FROM tripplanner.itinerary_components
                                UNION ALL
                                SELECT overnight_destination_id, source_tour_id
                                  FROM tripplanner.tour_day WHERE overnight_destination_id IS NOT NULL) u
                          JOIN silver_aa_internal.raw_tours rt ON rt.tour_id::text = u.source_tour_id
                         WHERE NULLIF(btrim(rt.country), '') IS NOT NULL
                         GROUP BY u.dest_id) m
                 WHERE d.id = m.dest_id AND NULLIF(btrim(d.country), '') IS NULL
            $q$;
            GET DIAGNOSTICS n = ROW_COUNT;
            RAISE NOTICE 'migration 226: filled country on % destinations from tour usage', n;
            PERFORM set_config('app.tenant_id', '', true);
        EXCEPTION WHEN insufficient_privilege THEN
            RAISE NOTICE 'migration 226: TripPlanner tables not readable (%), blank countries marked suspect', SQLERRM;
        END;
    END IF;
END $$;
UPDATE shared.destinations SET geo_status = 'suspect'
 WHERE NULLIF(btrim(country), '') IS NULL AND geo_status = 'ok';

-- 2c. duplicates on the new key: keep one (Mapbox-located > LLM-located > legacy, then with a cover,
--     then oldest), point the others at it. Re-run: only rows not yet marked take part.
WITH ranked AS (
    SELECT id,
           first_value(id) OVER w AS keeper_id,
           row_number() OVER w    AS rn
      FROM shared.destinations
     WHERE duplicate_of IS NULL AND name_norm IS NOT NULL
    WINDOW w AS (PARTITION BY name_norm, lower(btrim(country)), locality_norm
                 ORDER BY (located_by = 'manual') DESC NULLS LAST, (located_by = 'mapbox') DESC NULLS LAST,
                          (located_by = 'llm') DESC NULLS LAST, (cover_image_url IS NOT NULL) DESC,
                          created_at, id)
)
UPDATE shared.destinations d
   SET duplicate_of = r.keeper_id,
       geo_status   = CASE WHEN d.geo_status = 'manual' THEN 'manual' ELSE 'suspect' END
  FROM ranked r
 WHERE d.id = r.id AND r.rn > 1;

DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM (
        SELECT 1 FROM shared.destinations
         WHERE duplicate_of IS NULL AND name_norm IS NOT NULL
         GROUP BY name_norm, lower(btrim(country)), locality_norm HAVING count(*) > 1) x;
    IF n > 0 THEN
        RAISE EXCEPTION 'migration 226: % duplicate (name_norm, country, locality_norm) groups remain', n;
    END IF;
    RAISE NOTICE 'migration 226: % destinations marked duplicate_of a keeper',
                 (SELECT count(*) FROM shared.destinations WHERE duplicate_of IS NOT NULL);
END $$;

-- 2d. the new key (same name, two countries = two places). The global UNIQUE lower(name) index is
--     KEPT for now: TripPlanner's extraction writers (backend/extraction/locate.py UPSERT_SQL,
--     geocode.py) upsert ON CONFLICT (lower(name)) and fail without it. A later migration drops it
--     once slice 6 has turned those writers off (design §7 rollout). Meanwhile CIS names a second
--     place with a taken name "<name> (<locality|country>)" (services/places/store.py
--     upsert_destination), and adopts a same-country row TripPlanner wrote without name_norm.
CREATE UNIQUE INDEX IF NOT EXISTS destinations_name_country_uidx
    ON shared.destinations (name_norm, lower(btrim(country)), locality_norm)
    WHERE duplicate_of IS NULL AND name_norm IS NOT NULL;

-- ── 3. place card → destination ───────────────────────────────────────────────────────────────
ALTER TABLE acp_shared.place_card
    ADD COLUMN IF NOT EXISTS destination_id uuid REFERENCES shared.destinations(id) ON DELETE SET NULL;
COMMENT ON COLUMN acp_shared.place_card.destination_id IS
    'AA-712 — the destination this card resolves to (set by place_geocode); catalog views join by id.';

-- ── 4. Stage keys ─────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.llm_role_config
    (stage, role, provider, model_id, account_route, is_active, fallback_model_ids,
     shadow_model_id, shadow_sample_pct, updated_by)
VALUES
    ('a3_place_days',   'validate', 'claude', 'sonnet',          'acc3', true, ARRAY[]::text[],
     'gpt-5.6-luna', 20, 'migration-226'),
    ('a3_place_locate', 'validate', 'claude', 'sonnet',          'acc3', true, ARRAY[]::text[],
     NULL, 0, 'migration-226'),
    ('a3_place_embed',  'embed',    'cohere', 'cohere-embed-v4', NULL,   true, ARRAY[]::text[],
     NULL, 0, 'migration-226')
ON CONFLICT (stage) DO NOTHING;

-- ── 5. Budgets ────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    c record;
BEGIN
    FOR c IN SELECT conname FROM pg_constraint
              WHERE conrelid = 'shared.spend_budget'::regclass AND contype = 'c'
                AND pg_get_constraintdef(oid) LIKE '%provider%' AND pg_get_constraintdef(oid) LIKE '%dfs%'
                AND pg_get_constraintdef(oid) NOT LIKE '%geocoder%'
    LOOP
        EXECUTE format('ALTER TABLE shared.spend_budget DROP CONSTRAINT %I', c.conname);
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'shared.spend_budget'::regclass
                    AND pg_get_constraintdef(oid) LIKE '%geocoder%') THEN
        ALTER TABLE shared.spend_budget ADD CONSTRAINT spend_budget_provider_check
            CHECK (provider IN ('dfs', 'bedrock', 'openai', 'jev', 'geocoder'));
    END IF;
END $$;

INSERT INTO shared.spend_budget (provider, scope, per_run_usd, per_day_usd, updated_by) VALUES
    ('bedrock',  'job:place_extract', 5.00, 40.00, 'migration-226'),
    ('bedrock',  'job:place_geocode', 3.00, NULL,  'migration-226'),
    ('geocoder', 'global',            NULL, 25.00, 'migration-226'),
    ('geocoder', 'job:place_geocode', 50.00, NULL, 'migration-226')
ON CONFLICT (provider, scope) DO NOTHING;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('226', now(), 'AA-712: schema geo (place pipeline: tour_build, tour_day, tour_place, place_name, '
                      'place_outlier, geocode_call, graph builds), shared.destinations key (name_norm, '
                      'country, locality_norm) + geo columns, place_card.destination_id, stages '
                      'a3_place_days/locate/embed, geocoder budgets')
ON CONFLICT (version) DO NOTHING;

COMMIT;
