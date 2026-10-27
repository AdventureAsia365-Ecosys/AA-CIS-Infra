-- Migration 288: AA-990 (S252) — a tour's country is any ISO 3166-1 country, as its source says: raw_tours.country
-- becomes a foreign key to shared.countries (name) instead of the hand-made 20-name CHECK chk_raw_tours_country.
--
-- Why. Nghiệp (S252, 27/10): "tour nào thì ghi đúng nội dung của tour" and "nó thuộc file excel nào, tour thô của
-- quốc gia nào thì ghi đúng vậy". A tour's country is exactly what its uploaded Excel row says (the file name only
-- when the column is empty), never re-labelled, and no hand-made "AA country" list restricts it. chk_raw_tours_country
-- (150 -> 197 -> 281's Dev form) allows 20 names only, so S0 cannot store a tour whose source says Singapore, the
-- Maldives or any other country (its own resolver already emits Singapore and Maldives, which the CHECK refuses).
-- shared.countries (CIS 279) is the one ISO country table; its name column is the canonical spelling.
--
-- What (cis_owner, one BEGIN … COMMIT):
--   1. Guard before: shared.countries has its 249 rows; every non-NULL raw_tours.country is a shared.countries.name
--      (RAISE listing the values otherwise; none expected: the 20 CHECK names are all names); no row has a country
--      and no country_iso2, or a country_iso2 and no country.
--   2. Aliases: the S0 spellings shared/country_resolver.py knew that shared.countries lacked (japanese, srilanka,
--      sri landka, thai, khmer, bali, phil, prc) are appended to aliases (sorted, distinct; re-runnable). The list
--      sits between the two aa990:aliases markers: scripts/aa990_country_data.py reads it into the in-code mirror
--      shared/countries/data/countries.json (tests/unit/test_aa990_country_mirror.py). Then 279's guard 2 again:
--      every lookup key (lower name, iso_name, alias, iso2, iso3) names exactly one country.
--   3. raw_tours_country_fkey: FOREIGN KEY (country) REFERENCES shared.countries (name), NOT VALID then VALIDATE
--      (~1k rows; countries_name_key is the UNIQUE it needs; idx_aa_internal_raw_tours_country indexes the
--      referencing side). It enforces both "a real ISO country" and "the one canonical spelling" (never 'INDIA',
--      'india' or 'Viet Nam' in the display column). ON UPDATE / DELETE NO ACTION: renaming a country's display name
--      later is its own migration.
--   4. raw_tours_country_iso2_set: CHECK ((country IS NULL) = (country_iso2 IS NULL)), NOT VALID then VALIDATE. The
--      BEFORE trigger raw_tours_country_iso2 (279) fills country_iso2 from country before the check runs.
--   5. DROP CONSTRAINT IF EXISTS chk_raw_tours_country (the 20-name list).
--   6. Guard after: both constraints present and validated, chk_raw_tours_country gone, the trigger still there,
--      every lookup key unique. NOTICE: tours per country.
--   7. Register 288.
--
-- Not changed: shared.destinations.country (a place's own country, any text; its trigger resolves any ISO name), the
-- catalog views, booking.countries (Booking's markets). No tour's country is changed: a tour sold as India that
-- climbs Kilimanjaro stays India (its source row says INDIA); its places are Tanzanian places (geocoding).
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: no rows, then 0 0):
--   SELECT country, count(*) FROM silver_aa_internal.raw_tours r WHERE country IS NOT NULL
--      AND NOT EXISTS (SELECT 1 FROM shared.countries c WHERE c.name = r.country) GROUP BY 1;
--   SELECT count(*) FILTER (WHERE country IS NOT NULL AND country_iso2 IS NULL),
--          count(*) FILTER (WHERE country IS NULL AND country_iso2 IS NOT NULL) FROM silver_aa_internal.raw_tours;
--
-- Locks. SHARE ROW EXCLUSIVE on shared.countries and raw_tours for the FK, ACCESS EXCLUSIVE on raw_tours for the
-- CHECK / DROP, held until COMMIT; the VALIDATEs read ~1k rows. Seconds; lock_timeout 5s. Apply through AA-CIS-Infra
-- DB Migrate (byte copy in db/migrations/cis/) with the job tables idle (DM-11.4), after 287.
--
-- Order with the code. Apply BEFORE the S0 change of the same PR (shared/country_resolver.py through shared/countries)
-- is deployed: from then on S0 may write any ISO name, which only this file allows. The places change (guards from
-- shared/countries) does not depend on this file.
--
-- conftest skips 288 (the replay's tests drop and recreate shared.countries, which the FK would pin);
-- tests/integration/test_aa990_migration_288.py applies it the DB Migrate way on the RDS-like state and rolls back.
--
-- Rollback (a NEW forward migration, only while every raw_tours.country is one of the 20 names): ADD CONSTRAINT
-- chk_raw_tours_country CHECK (country IS NULL OR country = ANY (ARRAY[…20 names…])) NOT VALID; DROP CONSTRAINT
-- raw_tours_country_fkey; DROP CONSTRAINT raw_tours_country_iso2_set. The aliases stay (harmless).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── 1. Guard before ───────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    bad text;
BEGIN
    IF to_regclass('shared.countries') IS NULL OR to_regclass('silver_aa_internal.raw_tours') IS NULL THEN
        RAISE EXCEPTION 'migration 288: shared.countries (279) and silver_aa_internal.raw_tours must exist';
    END IF;
    IF (SELECT count(*) FROM shared.countries) <> 249 THEN
        RAISE EXCEPTION 'migration 288: shared.countries has % rows, expected 249',
            (SELECT count(*) FROM shared.countries);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'silver_aa_internal.raw_tours'::regclass
                                              AND tgname = 'raw_tours_country_iso2' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'migration 288: the trigger raw_tours_country_iso2 (279) is missing';
    END IF;
    SELECT string_agg(format('%L (%s)', country, n), ', ' ORDER BY country) INTO bad
      FROM (SELECT r.country, count(*) AS n FROM silver_aa_internal.raw_tours r
             WHERE r.country IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM shared.countries c WHERE c.name = r.country)
             GROUP BY r.country) x;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 288: raw_tours.country values that are not a shared.countries name: %', bad;
    END IF;
    IF EXISTS (SELECT 1 FROM silver_aa_internal.raw_tours WHERE (country IS NULL) <> (country_iso2 IS NULL)) THEN
        RAISE EXCEPTION 'migration 288: raw_tours rows with a country and no country_iso2 (or the reverse): %',
            (SELECT count(*) FROM silver_aa_internal.raw_tours WHERE (country IS NULL) <> (country_iso2 IS NULL));
    END IF;
END $$;

-- ── 2. The S0 spellings as aliases ────────────────────────────────────────────────────────────────────────────────
UPDATE shared.countries c
   SET aliases = ARRAY(SELECT DISTINCT a FROM unnest(c.aliases || v.extra) AS a ORDER BY a)
  FROM (VALUES
-- aa990:aliases:begin
    ('CN', ARRAY['prc']::text[]),
    ('ID', ARRAY['bali']::text[]),
    ('JP', ARRAY['japanese']::text[]),
    ('KH', ARRAY['khmer']::text[]),
    ('LK', ARRAY['sri landka', 'srilanka']::text[]),
    ('PH', ARRAY['phil']::text[]),
    ('TH', ARRAY['thai']::text[])
-- aa990:aliases:end
       ) AS v (iso2, extra)
 WHERE c.iso2 = v.iso2
   AND NOT (c.aliases @> v.extra);

-- ── 3 and 4. The foreign key on the canonical name, and country / country_iso2 set together ───────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'silver_aa_internal.raw_tours'::regclass
                                                 AND conname = 'raw_tours_country_fkey') THEN
        ALTER TABLE silver_aa_internal.raw_tours ADD CONSTRAINT raw_tours_country_fkey
            FOREIGN KEY (country) REFERENCES shared.countries (name) NOT VALID;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'silver_aa_internal.raw_tours'::regclass
                                                 AND conname = 'raw_tours_country_iso2_set') THEN
        ALTER TABLE silver_aa_internal.raw_tours ADD CONSTRAINT raw_tours_country_iso2_set
            CHECK ((country IS NULL) = (country_iso2 IS NULL)) NOT VALID;
    END IF;
END $$;

ALTER TABLE silver_aa_internal.raw_tours VALIDATE CONSTRAINT raw_tours_country_fkey;
ALTER TABLE silver_aa_internal.raw_tours VALIDATE CONSTRAINT raw_tours_country_iso2_set;

-- ── 5. The hand-made 20-name list goes ────────────────────────────────────────────────────────────────────────────
ALTER TABLE silver_aa_internal.raw_tours DROP CONSTRAINT IF EXISTS chk_raw_tours_country;

COMMENT ON COLUMN silver_aa_internal.raw_tours.country IS
    'AA-990 (CIS 288): the country the tour''s source states (the Excel row''s country column, else the file name), '
    'as its shared.countries name (FK raw_tours_country_fkey; any ISO 3166-1 country). Never re-labelled from the '
    'itinerary: a place''s own country is shared.destinations.country.';
COMMENT ON CONSTRAINT raw_tours_country_fkey ON silver_aa_internal.raw_tours IS
    'AA-990 (CIS 288): country is a shared.countries name (replaces the 20-name CHECK chk_raw_tours_country).';
COMMENT ON CONSTRAINT raw_tours_country_iso2_set ON silver_aa_internal.raw_tours IS
    'AA-990 (CIS 288): country and country_iso2 are set together (the trigger raw_tours_country_iso2 fills the code).';

-- ── 6. Guard after ────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    bad text;
    per text;
BEGIN
    IF (SELECT count(*) FROM pg_constraint
         WHERE conrelid = 'silver_aa_internal.raw_tours'::regclass AND convalidated
           AND ((conname = 'raw_tours_country_fkey' AND contype = 'f'
                 AND confrelid = 'shared.countries'::regclass)
                OR (conname = 'raw_tours_country_iso2_set' AND contype = 'c'))) <> 2 THEN
        RAISE EXCEPTION 'migration 288: raw_tours_country_fkey / raw_tours_country_iso2_set missing or not validated';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'silver_aa_internal.raw_tours'::regclass
                                             AND conname = 'chk_raw_tours_country') THEN
        RAISE EXCEPTION 'migration 288: chk_raw_tours_country is still there';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'silver_aa_internal.raw_tours'::regclass
                                              AND tgname = 'raw_tours_country_iso2' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'migration 288: the trigger raw_tours_country_iso2 is gone';
    END IF;
    SELECT string_agg(k || ' -> ' || codes, ', ' ORDER BY k) INTO bad FROM (
        SELECT k, string_agg(iso2, '/' ORDER BY iso2) AS codes
          FROM (SELECT DISTINCT c.iso2::text AS iso2, k
                  FROM shared.countries c
                 CROSS JOIN LATERAL unnest(ARRAY[lower(c.name), lower(c.iso_name), lower(c.iso2), lower(c.iso3)]
                                           || c.aliases) AS k) x
         GROUP BY k HAVING count(*) > 1) y;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 288: country lookup keys that name more than one country: %', bad;
    END IF;
    SELECT string_agg(n, ', ' ORDER BY n) INTO bad
      FROM unnest(ARRAY['japanese', 'srilanka', 'sri landka', 'thai', 'khmer', 'bali', 'phil', 'prc']) n
     WHERE shared.country_iso2(n) IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 288: S0 spellings that do not resolve: %', bad;
    END IF;
    SELECT string_agg(format('%s %s', coalesce(country, '(none)'), n), ', ' ORDER BY country) INTO per
      FROM (SELECT country, count(*) AS n FROM silver_aa_internal.raw_tours GROUP BY country) x;
    RAISE NOTICE 'migration 288: raw_tours.country is a shared.countries name; tours per country: %', per;
END $$;

-- ── 7. Register ───────────────────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('288', now(), 'AA-990: raw_tours.country FK to shared.countries (name), any ISO country as the source says '
                      '(drops the 20-name chk_raw_tours_country); country / country_iso2 set together; S0 aliases')
ON CONFLICT (version) DO NOTHING;

COMMIT;
