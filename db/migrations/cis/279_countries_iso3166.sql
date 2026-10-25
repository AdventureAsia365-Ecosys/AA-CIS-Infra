-- Migration 279: AA-851 (data standards X5, DM-2.4, NAM-11) — the ISO 3166-1 country table shared.countries, the
-- additive country_iso2 key on the two CIS tables that carry a country (tours and places), an orphan report, and the
-- catalog contract view catalog.v_country (+ country_iso2 appended to catalog.v_destination) for Booking and
-- TripPlanner.
--
-- Why. There is no shared ISO country table: only Booking's own booking.countries ("markets we sell", bk-005). CIS
-- keeps free-text country names (silver_aa_internal.raw_tours.country, constrained to 20 names; shared.destinations
-- .country) and each app maps them to codes on its own (CIS services/places/guards.py, catalog_http/geo.py).
-- DM-2.4 makes shared.countries the one country pattern, keyed by iso2, read by other apps through a catalog view;
-- NAM-11 makes country_iso2 char(2) keyed to it the column next to any free-text country (S241 D-24 scope: column,
-- backfill, orphan report).
--
-- What.
--   Part A (cis_owner, the owner of shared since 245):
--     1. shared.countries: one row per ISO 3166-1 entry, 249 rows (Debian iso-codes 4.16.0, iso_3166-1.json).
--        iso2 (PK) / iso3 / numeric_code (all UNIQUE, format CHECKs), name = the common English short name
--        (iso-codes common_name: 'Vietnam', 'South Korea', 'Laos', 'Taiwan'), else the ISO short name; iso_name =
--        the ISO 3166-1 English short name ('Viet Nam', 'Korea, Republic of'); aliases = other lower-case spellings
--        (the ISO official name, common English names iso-codes lacks such as 'turkey', and the spellings AA meets in
--        source data: services/places/guards.py _ALIASES, 'tibet' -> CN as guards.py maps it). Reference data: no
--        tenant column, no personal data, no RLS. Seeded ON CONFLICT (iso2) DO NOTHING: a later change of the list
--        is a new migration.
--     2. shared.country_iso2(text) -> char(2): the one free-text resolver. Case- and space-insensitive match on
--        name, iso_name or an alias, else on the code itself (iso2 / iso3); NULL when nothing matches. SQL, STABLE,
--        SECURITY INVOKER, search_path pinned. Every lookup key names one country (guard 2).
--     3. country_iso2 character(2) NULL + FK to shared.countries (iso2) + btree index on
--        silver_aa_internal.raw_tours and shared.destinations (additive: country stays, display only; DM-2.3 allows
--        the FK, both sides are CIS's). A BEFORE INSERT OR UPDATE OF country trigger (shared.set_country_iso2())
--        keeps it in step without a code change: on INSERT it fills a NULL country_iso2 from country; on an UPDATE
--        that changes country and leaves country_iso2 as it was, it re-derives it. An explicit country_iso2 is
--        kept (a manual override); an unknown name leaves NULL (never an error: the orphan report lists it).
--     4. Backfill: every row whose country_iso2 is NULL gets shared.country_iso2(country) (~1k tours, ~2k places;
--        plain UPDATEs that do not fire the new trigger; neither table has another trigger).
--     5. shared.v_country_unmapped (security_invoker): the orphan report, one row per (source column, country
--        text) with a non-NULL country and a NULL country_iso2, and its row count. Expected empty on Dev.
--     6. Grants. REVOKE ALL from PUBLIC, cis_app, aa_app_user, catalog_owner first (it also takes away what the Dev
--        default ACL of cis_owner gives cis_app on a new table, view and function in shared, CIS 245), then exactly:
--        cis_app SELECT on shared.countries and shared.v_country_unmapped and EXECUTE on shared.country_iso2(text);
--        catalog_owner SELECT on shared.countries (part B). The trigger function is SECURITY INVOKER (MIG-6: no
--        SECURITY DEFINER in CIS schemas), so it runs as whoever writes the table and its call to the resolver (which
--        reads shared.countries) is checked against that role: every other role that may write raw_tours or
--        shared.destinations (INSERT at table or column level, UPDATE at table level or on country) also gets
--        SELECT on shared.countries and EXECUTE on the resolver. On Dev that set is cis_app alone (schema reference
--        24/10; the master writes as a member of cis_app); in CI it also holds the legacy app_user and the test
--        writer roles. aa_app_user nothing (AA-859 invariant). The trigger function: no EXECUTE for anyone (EXECUTE
--        is checked by CREATE TRIGGER only, never when a trigger fires). A role granted INSERT / UPDATE on either
--        table later must get the same two grants (a writer without them fails every insert: "permission denied for
--        function country_iso2").
--   Part B (catalog_owner, the X1 S22 catalog recipe, as 253 / 256 / 257 / 258 / 273 / 274 / 278):
--     7. catalog.v_country (security_barrier): iso2, iso3, numeric_code, name, iso_name of every shared.countries
--        row. SELECT to booking and tripplanner (contracts rule 5, unguarded; schema-ownership `catalog.*:booking`,
--        `catalog.*:tripplanner`; owners.yaml cis consumer_grants). Not to aa_app_user: catalog.http.v1 does not
--        read it yet (a later file adds the grant with the route). Contract root docs/contracts/catalog.country.v1.
--     8. catalog.v_destination: 256's statement with d.country_iso2 APPENDED as the last column (CREATE OR REPLACE
--        VIEW cannot drop, rename, reorder or retype a column; same rows, grants kept). Consumers join v_country on
--        it instead of matching names. Contract: folded into the next catalog.tour minor (the README registry row
--        says so, as 257 did for v_destination_redirect).
--   9. Register 279.
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before, part A: roles cis_app, aa_app_user, catalog_owner exist; the runner may create in shared; a
--      shared.countries that exists already has exactly this file's columns, and a country_iso2 that exists already
--      is character(2) (re-run).
--   2. after, part A: 249 rows, every lookup key (lower name, iso_name, alias, iso2, iso3) names exactly one
--      country, the AA tour countries of chk_raw_tours_country all resolve; the FKs validated and the triggers
--      present; no row whose country_iso2 is NULL while its country resolves; privileges exactly as in point 6 for
--      PUBLIC, cis_app, aa_app_user and catalog_owner (no column-level grant); both functions SECURITY INVOKER with
--      a pinned search_path and no EXECUTE for PUBLIC; PUBLIC and aa_app_user may not write either table; cis_app
--      and every other writer of either table have SELECT on shared.countries and EXECUTE on the resolver (a writer
--      also USAGE on shared), and no one else holds EXECUTE on either function or SELECT on shared.countries
--      (catalog_owner aside). NOTICE: the unmapped values (orphan report), never fatal.
--   3. before, part B: schema catalog owned by cis_owner (245); roles catalog_owner, booking, tripplanner exist;
--      catalog_owner reads shared.countries; catalog.v_destination is catalog_owner's with 256's columns (or 256's +
--      country_iso2: re-run); catalog.v_country, if present, is catalog_owner's.
--   4. after, part B (as catalog_owner, then as cis_owner): both views catalog_owner's and security_barrier, their
--      columns exactly as in points 7 and 8, v_country granted exactly SELECT to booking and tripplanner,
--      v_destination's grants unchanged (aa_app_user, booking, tripplanner SELECT), no column grants; catalog_owner
--      has no CREATE on catalog any more.
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: NULL, NULL, and the free-text values
-- the backfill will meet):
--   SELECT to_regclass('shared.countries'), (SELECT attname FROM pg_attribute WHERE attrelid =
--          'shared.destinations'::regclass AND attname = 'country_iso2');
--   SELECT 'raw_tours', country, count(*) FROM silver_aa_internal.raw_tours GROUP BY 2
--   UNION ALL SELECT 'destinations', country, count(*) FROM shared.destinations GROUP BY 2 ORDER BY 1, 2;
--
-- Locks. ACCESS EXCLUSIVE on raw_tours and shared.destinations (ADD COLUMN without a default: catalog only) and on
-- the two views, held until COMMIT; the backfill rewrites ~3k small rows. Seconds; lock_timeout 5s. Apply through
-- AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/) with the job tables idle (DM-11.4: no S1 wave or place
-- job writes raw_tours / destinations while it runs), after 278.
--
-- Order with the code. No code change is needed: the trigger fills the column for every writer, and nothing reads
-- the new objects yet. Booking and TripPlanner can read catalog.v_country once it is applied; a consumer that
-- switches from names to codes is its own PR after this one (root contract catalog.country.v1).
--
-- Recipe / X1. One BEGIN … COMMIT, run by DB Migrate as cis_owner (login db_migrator). Part A runs as cis_owner. Part
-- B uses the X1 S22 catalog recipe (CONTEXT.md): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE
-- catalog_owner; the views and the grant; SET LOCAL ROLE cis_owner; REVOKE CREATE. Never RESET ROLE, no SECURITY
-- DEFINER, no role DDL. The conftest replay applies only part A (it skips 245 and 253-258, which part B needs);
-- tests/integration/test_aa851_migration_279.py applies 253 + 256 + 257 + 258 + 279 the DB Migrate way on the
-- RDS-like state and rolls back.
--
-- Rollback (a NEW forward migration): appended view columns cannot be removed by CREATE OR REPLACE, so
-- v_destination.country_iso2 stays (readers ignore it); under the catalog recipe REVOKE SELECT ON catalog.v_country
-- FROM booking, tripplanner and DROP VIEW catalog.v_country; DROP VIEW shared.v_country_unmapped; DROP TRIGGER
-- raw_tours_country_iso2 ON silver_aa_internal.raw_tours; DROP TRIGGER destinations_country_iso2 ON
-- shared.destinations; only after v_destination no longer reads it, ALTER TABLE … DROP COLUMN country_iso2 on both
-- tables; DROP FUNCTION shared.set_country_iso2(), shared.country_iso2(text); DROP TABLE shared.countries.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── Part A: shared.countries, the resolver, the country_iso2 columns and the orphan report (cis_owner) ─────────────
DO $$
DECLARE
    cols text;
    t    text;
BEGIN
    IF to_regrole('cis_app') IS NULL OR to_regrole('aa_app_user') IS NULL OR to_regrole('catalog_owner') IS NULL THEN
        RAISE EXCEPTION 'migration 279: roles cis_app, aa_app_user and catalog_owner must exist';
    END IF;
    IF NOT has_schema_privilege(current_user, 'shared', 'CREATE') THEN
        RAISE EXCEPTION 'migration 279: % may not create in shared; run it through DB Migrate (cis_owner)',
            current_user;
    END IF;
    IF to_regclass('shared.countries') IS NOT NULL THEN
        SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
          FROM pg_attribute a WHERE a.attrelid = 'shared.countries'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
        IF cols IS DISTINCT FROM 'iso2 character(2), iso3 character(3), numeric_code character(3), name text, '
                                 'iso_name text, aliases text[]' THEN
            RAISE EXCEPTION 'migration 279: shared.countries exists with other columns: %', cols;
        END IF;
    END IF;
    FOREACH t IN ARRAY ARRAY['silver_aa_internal.raw_tours', 'shared.destinations'] LOOP
        IF to_regclass(t) IS NULL THEN
            RAISE EXCEPTION 'migration 279: % is missing', t;
        END IF;
        SELECT format_type(a.atttypid, a.atttypmod) INTO cols FROM pg_attribute a
         WHERE a.attrelid = t::regclass AND a.attname = 'country_iso2' AND NOT a.attisdropped;
        IF cols IS NOT NULL AND cols <> 'character(2)' THEN
            RAISE EXCEPTION 'migration 279: %.country_iso2 exists as %', t, cols;
        END IF;
    END LOOP;
END $$;

-- ── 1. The ISO 3166-1 country table ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.countries (
    iso2         character(2) PRIMARY KEY,
    iso3         character(3) NOT NULL,
    numeric_code character(3) NOT NULL,
    name         text NOT NULL,
    iso_name     text NOT NULL,
    aliases      text[] NOT NULL DEFAULT '{}'::text[],
    CONSTRAINT countries_iso3_key UNIQUE (iso3),
    CONSTRAINT countries_numeric_code_key UNIQUE (numeric_code),
    CONSTRAINT countries_name_key UNIQUE (name),
    CONSTRAINT countries_iso2_check CHECK (iso2 ~ '^[A-Z]{2}$'),
    CONSTRAINT countries_iso3_check CHECK (iso3 ~ '^[A-Z]{3}$'),
    CONSTRAINT countries_numeric_code_check CHECK (numeric_code ~ '^[0-9]{3}$'),
    CONSTRAINT countries_names_check CHECK (length(btrim(name)) > 0 AND length(btrim(iso_name)) > 0),
    CONSTRAINT countries_aliases_check CHECK (aliases::text = lower(aliases::text))
);

COMMENT ON TABLE shared.countries IS
    'AA-851 (CIS 279, data standards X5 / DM-2.4): ISO 3166-1, one row per entry (249, Debian iso-codes 4.16.0). '
    'The one country table of the ecosystem, keyed by iso2: new country columns are country_iso2 char(2) keyed to it '
    '(NAM-11). Reference data, no tenant column, no personal data. Other apps read catalog.v_country. '
    'booking.countries stays Booking''s list of markets it sells, keyed by the same iso2.';
COMMENT ON COLUMN shared.countries.name IS
    'Common English short name (iso-codes common_name, e.g. Vietnam, South Korea, Laos, Taiwan), else the ISO short '
    'name. The spelling AA uses in raw_tours.country.';
COMMENT ON COLUMN shared.countries.iso_name IS 'ISO 3166-1 English short name (e.g. Viet Nam, Korea, Republic of).';
COMMENT ON COLUMN shared.countries.aliases IS
    'Other lower-case spellings shared.country_iso2() resolves: the ISO official name, common English names, and the '
    'spellings AA meets in source data (services/places/guards.py _ALIASES; tibet -> CN).';

INSERT INTO shared.countries (iso2, iso3, numeric_code, name, iso_name, aliases) VALUES
    ('AD', 'AND', '020', 'Andorra', 'Andorra', ARRAY['principality of andorra']::text[]),
    ('AE', 'ARE', '784', 'United Arab Emirates', 'United Arab Emirates', '{}'::text[]),
    ('AF', 'AFG', '004', 'Afghanistan', 'Afghanistan', ARRAY['islamic republic of afghanistan']::text[]),
    ('AG', 'ATG', '028', 'Antigua and Barbuda', 'Antigua and Barbuda', '{}'::text[]),
    ('AI', 'AIA', '660', 'Anguilla', 'Anguilla', '{}'::text[]),
    ('AL', 'ALB', '008', 'Albania', 'Albania', ARRAY['republic of albania']::text[]),
    ('AM', 'ARM', '051', 'Armenia', 'Armenia', ARRAY['republic of armenia']::text[]),
    ('AO', 'AGO', '024', 'Angola', 'Angola', ARRAY['republic of angola']::text[]),
    ('AQ', 'ATA', '010', 'Antarctica', 'Antarctica', '{}'::text[]),
    ('AR', 'ARG', '032', 'Argentina', 'Argentina', ARRAY['argentine republic']::text[]),
    ('AS', 'ASM', '016', 'American Samoa', 'American Samoa', '{}'::text[]),
    ('AT', 'AUT', '040', 'Austria', 'Austria', ARRAY['republic of austria']::text[]),
    ('AU', 'AUS', '036', 'Australia', 'Australia', '{}'::text[]),
    ('AW', 'ABW', '533', 'Aruba', 'Aruba', '{}'::text[]),
    ('AX', 'ALA', '248', 'Åland Islands', 'Åland Islands', '{}'::text[]),
    ('AZ', 'AZE', '031', 'Azerbaijan', 'Azerbaijan', ARRAY['republic of azerbaijan']::text[]),
    ('BA', 'BIH', '070', 'Bosnia and Herzegovina', 'Bosnia and Herzegovina',
     ARRAY['republic of bosnia and herzegovina']::text[]),
    ('BB', 'BRB', '052', 'Barbados', 'Barbados', '{}'::text[]),
    ('BD', 'BGD', '050', 'Bangladesh', 'Bangladesh', ARRAY['people''s republic of bangladesh']::text[]),
    ('BE', 'BEL', '056', 'Belgium', 'Belgium', ARRAY['kingdom of belgium']::text[]),
    ('BF', 'BFA', '854', 'Burkina Faso', 'Burkina Faso', '{}'::text[]),
    ('BG', 'BGR', '100', 'Bulgaria', 'Bulgaria', ARRAY['republic of bulgaria']::text[]),
    ('BH', 'BHR', '048', 'Bahrain', 'Bahrain', ARRAY['kingdom of bahrain']::text[]),
    ('BI', 'BDI', '108', 'Burundi', 'Burundi', ARRAY['republic of burundi']::text[]),
    ('BJ', 'BEN', '204', 'Benin', 'Benin', ARRAY['republic of benin']::text[]),
    ('BL', 'BLM', '652', 'Saint Barthélemy', 'Saint Barthélemy', '{}'::text[]),
    ('BM', 'BMU', '060', 'Bermuda', 'Bermuda', '{}'::text[]),
    ('BN', 'BRN', '096', 'Brunei Darussalam', 'Brunei Darussalam', ARRAY['brunei']::text[]),
    ('BO', 'BOL', '068', 'Bolivia', 'Bolivia, Plurinational State of', ARRAY['plurinational state of bolivia']::text[]),
    ('BQ', 'BES', '535', 'Bonaire, Sint Eustatius and Saba', 'Bonaire, Sint Eustatius and Saba', '{}'::text[]),
    ('BR', 'BRA', '076', 'Brazil', 'Brazil', ARRAY['federative republic of brazil']::text[]),
    ('BS', 'BHS', '044', 'Bahamas', 'Bahamas', ARRAY['commonwealth of the bahamas']::text[]),
    ('BT', 'BTN', '064', 'Bhutan', 'Bhutan', ARRAY['kingdom of bhutan']::text[]),
    ('BV', 'BVT', '074', 'Bouvet Island', 'Bouvet Island', '{}'::text[]),
    ('BW', 'BWA', '072', 'Botswana', 'Botswana', ARRAY['republic of botswana']::text[]),
    ('BY', 'BLR', '112', 'Belarus', 'Belarus', ARRAY['republic of belarus']::text[]),
    ('BZ', 'BLZ', '084', 'Belize', 'Belize', '{}'::text[]),
    ('CA', 'CAN', '124', 'Canada', 'Canada', '{}'::text[]),
    ('CC', 'CCK', '166', 'Cocos (Keeling) Islands', 'Cocos (Keeling) Islands', '{}'::text[]),
    ('CD', 'COD', '180', 'Congo, The Democratic Republic of the', 'Congo, The Democratic Republic of the',
     ARRAY['democratic republic of the congo', 'dr congo']::text[]),
    ('CF', 'CAF', '140', 'Central African Republic', 'Central African Republic', '{}'::text[]),
    ('CG', 'COG', '178', 'Congo', 'Congo', ARRAY['republic of the congo']::text[]),
    ('CH', 'CHE', '756', 'Switzerland', 'Switzerland', ARRAY['swiss confederation']::text[]),
    ('CI', 'CIV', '384', 'Côte d''Ivoire', 'Côte d''Ivoire',
     ARRAY['republic of côte d''ivoire', 'ivory coast']::text[]),
    ('CK', 'COK', '184', 'Cook Islands', 'Cook Islands', '{}'::text[]),
    ('CL', 'CHL', '152', 'Chile', 'Chile', ARRAY['republic of chile']::text[]),
    ('CM', 'CMR', '120', 'Cameroon', 'Cameroon', ARRAY['republic of cameroon']::text[]),
    ('CN', 'CHN', '156', 'China', 'China', ARRAY['people''s republic of china', 'tibet']::text[]),
    ('CO', 'COL', '170', 'Colombia', 'Colombia', ARRAY['republic of colombia']::text[]),
    ('CR', 'CRI', '188', 'Costa Rica', 'Costa Rica', ARRAY['republic of costa rica']::text[]),
    ('CU', 'CUB', '192', 'Cuba', 'Cuba', ARRAY['republic of cuba']::text[]),
    ('CV', 'CPV', '132', 'Cabo Verde', 'Cabo Verde', ARRAY['republic of cabo verde', 'cape verde']::text[]),
    ('CW', 'CUW', '531', 'Curaçao', 'Curaçao', '{}'::text[]),
    ('CX', 'CXR', '162', 'Christmas Island', 'Christmas Island', '{}'::text[]),
    ('CY', 'CYP', '196', 'Cyprus', 'Cyprus', ARRAY['republic of cyprus']::text[]),
    ('CZ', 'CZE', '203', 'Czechia', 'Czechia', ARRAY['czech republic']::text[]),
    ('DE', 'DEU', '276', 'Germany', 'Germany', ARRAY['federal republic of germany']::text[]),
    ('DJ', 'DJI', '262', 'Djibouti', 'Djibouti', ARRAY['republic of djibouti']::text[]),
    ('DK', 'DNK', '208', 'Denmark', 'Denmark', ARRAY['kingdom of denmark']::text[]),
    ('DM', 'DMA', '212', 'Dominica', 'Dominica', ARRAY['commonwealth of dominica']::text[]),
    ('DO', 'DOM', '214', 'Dominican Republic', 'Dominican Republic', '{}'::text[]),
    ('DZ', 'DZA', '012', 'Algeria', 'Algeria', ARRAY['people''s democratic republic of algeria']::text[]),
    ('EC', 'ECU', '218', 'Ecuador', 'Ecuador', ARRAY['republic of ecuador']::text[]),
    ('EE', 'EST', '233', 'Estonia', 'Estonia', ARRAY['republic of estonia']::text[]),
    ('EG', 'EGY', '818', 'Egypt', 'Egypt', ARRAY['arab republic of egypt']::text[]),
    ('EH', 'ESH', '732', 'Western Sahara', 'Western Sahara', '{}'::text[]),
    ('ER', 'ERI', '232', 'Eritrea', 'Eritrea', ARRAY['the state of eritrea']::text[]),
    ('ES', 'ESP', '724', 'Spain', 'Spain', ARRAY['kingdom of spain']::text[]),
    ('ET', 'ETH', '231', 'Ethiopia', 'Ethiopia', ARRAY['federal democratic republic of ethiopia']::text[]),
    ('FI', 'FIN', '246', 'Finland', 'Finland', ARRAY['republic of finland']::text[]),
    ('FJ', 'FJI', '242', 'Fiji', 'Fiji', ARRAY['republic of fiji']::text[]),
    ('FK', 'FLK', '238', 'Falkland Islands (Malvinas)', 'Falkland Islands (Malvinas)', '{}'::text[]),
    ('FM', 'FSM', '583', 'Micronesia, Federated States of', 'Micronesia, Federated States of',
     ARRAY['federated states of micronesia', 'micronesia']::text[]),
    ('FO', 'FRO', '234', 'Faroe Islands', 'Faroe Islands', '{}'::text[]),
    ('FR', 'FRA', '250', 'France', 'France', ARRAY['french republic']::text[]),
    ('GA', 'GAB', '266', 'Gabon', 'Gabon', ARRAY['gabonese republic']::text[]),
    ('GB', 'GBR', '826', 'United Kingdom', 'United Kingdom',
     ARRAY['united kingdom of great britain and northern ireland', 'great britain', 'uk']::text[]),
    ('GD', 'GRD', '308', 'Grenada', 'Grenada', '{}'::text[]),
    ('GE', 'GEO', '268', 'Georgia', 'Georgia', '{}'::text[]),
    ('GF', 'GUF', '254', 'French Guiana', 'French Guiana', '{}'::text[]),
    ('GG', 'GGY', '831', 'Guernsey', 'Guernsey', '{}'::text[]),
    ('GH', 'GHA', '288', 'Ghana', 'Ghana', ARRAY['republic of ghana']::text[]),
    ('GI', 'GIB', '292', 'Gibraltar', 'Gibraltar', '{}'::text[]),
    ('GL', 'GRL', '304', 'Greenland', 'Greenland', '{}'::text[]),
    ('GM', 'GMB', '270', 'Gambia', 'Gambia', ARRAY['republic of the gambia']::text[]),
    ('GN', 'GIN', '324', 'Guinea', 'Guinea', ARRAY['republic of guinea']::text[]),
    ('GP', 'GLP', '312', 'Guadeloupe', 'Guadeloupe', '{}'::text[]),
    ('GQ', 'GNQ', '226', 'Equatorial Guinea', 'Equatorial Guinea', ARRAY['republic of equatorial guinea']::text[]),
    ('GR', 'GRC', '300', 'Greece', 'Greece', ARRAY['hellenic republic']::text[]),
    ('GS', 'SGS', '239', 'South Georgia and the South Sandwich Islands', 'South Georgia and the South Sandwich Islands',
     '{}'::text[]),
    ('GT', 'GTM', '320', 'Guatemala', 'Guatemala', ARRAY['republic of guatemala']::text[]),
    ('GU', 'GUM', '316', 'Guam', 'Guam', '{}'::text[]),
    ('GW', 'GNB', '624', 'Guinea-Bissau', 'Guinea-Bissau', ARRAY['republic of guinea-bissau']::text[]),
    ('GY', 'GUY', '328', 'Guyana', 'Guyana', ARRAY['republic of guyana']::text[]),
    ('HK', 'HKG', '344', 'Hong Kong', 'Hong Kong', ARRAY['hong kong special administrative region of china']::text[]),
    ('HM', 'HMD', '334', 'Heard Island and McDonald Islands', 'Heard Island and McDonald Islands', '{}'::text[]),
    ('HN', 'HND', '340', 'Honduras', 'Honduras', ARRAY['republic of honduras']::text[]),
    ('HR', 'HRV', '191', 'Croatia', 'Croatia', ARRAY['republic of croatia']::text[]),
    ('HT', 'HTI', '332', 'Haiti', 'Haiti', ARRAY['republic of haiti']::text[]),
    ('HU', 'HUN', '348', 'Hungary', 'Hungary', '{}'::text[]),
    ('ID', 'IDN', '360', 'Indonesia', 'Indonesia', ARRAY['republic of indonesia']::text[]),
    ('IE', 'IRL', '372', 'Ireland', 'Ireland', '{}'::text[]),
    ('IL', 'ISR', '376', 'Israel', 'Israel', ARRAY['state of israel']::text[]),
    ('IM', 'IMN', '833', 'Isle of Man', 'Isle of Man', '{}'::text[]),
    ('IN', 'IND', '356', 'India', 'India', ARRAY['republic of india']::text[]),
    ('IO', 'IOT', '086', 'British Indian Ocean Territory', 'British Indian Ocean Territory', '{}'::text[]),
    ('IQ', 'IRQ', '368', 'Iraq', 'Iraq', ARRAY['republic of iraq']::text[]),
    ('IR', 'IRN', '364', 'Iran', 'Iran, Islamic Republic of', ARRAY['islamic republic of iran']::text[]),
    ('IS', 'ISL', '352', 'Iceland', 'Iceland', ARRAY['republic of iceland']::text[]),
    ('IT', 'ITA', '380', 'Italy', 'Italy', ARRAY['italian republic']::text[]),
    ('JE', 'JEY', '832', 'Jersey', 'Jersey', '{}'::text[]),
    ('JM', 'JAM', '388', 'Jamaica', 'Jamaica', '{}'::text[]),
    ('JO', 'JOR', '400', 'Jordan', 'Jordan', ARRAY['hashemite kingdom of jordan']::text[]),
    ('JP', 'JPN', '392', 'Japan', 'Japan', ARRAY['okinawa']::text[]),
    ('KE', 'KEN', '404', 'Kenya', 'Kenya', ARRAY['republic of kenya']::text[]),
    ('KG', 'KGZ', '417', 'Kyrgyzstan', 'Kyrgyzstan', ARRAY['kyrgyz republic']::text[]),
    ('KH', 'KHM', '116', 'Cambodia', 'Cambodia', ARRAY['kingdom of cambodia']::text[]),
    ('KI', 'KIR', '296', 'Kiribati', 'Kiribati', ARRAY['republic of kiribati']::text[]),
    ('KM', 'COM', '174', 'Comoros', 'Comoros', ARRAY['union of the comoros']::text[]),
    ('KN', 'KNA', '659', 'Saint Kitts and Nevis', 'Saint Kitts and Nevis', '{}'::text[]),
    ('KP', 'PRK', '408', 'North Korea', 'Korea, Democratic People''s Republic of',
     ARRAY['democratic people''s republic of korea']::text[]),
    ('KR', 'KOR', '410', 'South Korea', 'Korea, Republic of', ARRAY['korea', 'republic of korea']::text[]),
    ('KW', 'KWT', '414', 'Kuwait', 'Kuwait', ARRAY['state of kuwait']::text[]),
    ('KY', 'CYM', '136', 'Cayman Islands', 'Cayman Islands', '{}'::text[]),
    ('KZ', 'KAZ', '398', 'Kazakhstan', 'Kazakhstan', ARRAY['republic of kazakhstan']::text[]),
    ('LA', 'LAO', '418', 'Laos', 'Lao People''s Democratic Republic', ARRAY['lao pdr']::text[]),
    ('LB', 'LBN', '422', 'Lebanon', 'Lebanon', ARRAY['lebanese republic']::text[]),
    ('LC', 'LCA', '662', 'Saint Lucia', 'Saint Lucia', '{}'::text[]),
    ('LI', 'LIE', '438', 'Liechtenstein', 'Liechtenstein', ARRAY['principality of liechtenstein']::text[]),
    ('LK', 'LKA', '144', 'Sri Lanka', 'Sri Lanka',
     ARRAY['democratic socialist republic of sri lanka', 'sri-landka']::text[]),
    ('LR', 'LBR', '430', 'Liberia', 'Liberia', ARRAY['republic of liberia']::text[]),
    ('LS', 'LSO', '426', 'Lesotho', 'Lesotho', ARRAY['kingdom of lesotho']::text[]),
    ('LT', 'LTU', '440', 'Lithuania', 'Lithuania', ARRAY['republic of lithuania']::text[]),
    ('LU', 'LUX', '442', 'Luxembourg', 'Luxembourg', ARRAY['grand duchy of luxembourg']::text[]),
    ('LV', 'LVA', '428', 'Latvia', 'Latvia', ARRAY['republic of latvia']::text[]),
    ('LY', 'LBY', '434', 'Libya', 'Libya', '{}'::text[]),
    ('MA', 'MAR', '504', 'Morocco', 'Morocco', ARRAY['kingdom of morocco']::text[]),
    ('MC', 'MCO', '492', 'Monaco', 'Monaco', ARRAY['principality of monaco']::text[]),
    ('MD', 'MDA', '498', 'Moldova', 'Moldova, Republic of', ARRAY['republic of moldova']::text[]),
    ('ME', 'MNE', '499', 'Montenegro', 'Montenegro', '{}'::text[]),
    ('MF', 'MAF', '663', 'Saint Martin (French part)', 'Saint Martin (French part)', '{}'::text[]),
    ('MG', 'MDG', '450', 'Madagascar', 'Madagascar', ARRAY['republic of madagascar']::text[]),
    ('MH', 'MHL', '584', 'Marshall Islands', 'Marshall Islands', ARRAY['republic of the marshall islands']::text[]),
    ('MK', 'MKD', '807', 'North Macedonia', 'North Macedonia',
     ARRAY['republic of north macedonia', 'macedonia']::text[]),
    ('ML', 'MLI', '466', 'Mali', 'Mali', ARRAY['republic of mali']::text[]),
    ('MM', 'MMR', '104', 'Myanmar', 'Myanmar', ARRAY['republic of myanmar', 'burma']::text[]),
    ('MN', 'MNG', '496', 'Mongolia', 'Mongolia', '{}'::text[]),
    ('MO', 'MAC', '446', 'Macao', 'Macao', ARRAY['macao special administrative region of china']::text[]),
    ('MP', 'MNP', '580', 'Northern Mariana Islands', 'Northern Mariana Islands',
     ARRAY['commonwealth of the northern mariana islands']::text[]),
    ('MQ', 'MTQ', '474', 'Martinique', 'Martinique', '{}'::text[]),
    ('MR', 'MRT', '478', 'Mauritania', 'Mauritania', ARRAY['islamic republic of mauritania']::text[]),
    ('MS', 'MSR', '500', 'Montserrat', 'Montserrat', '{}'::text[]),
    ('MT', 'MLT', '470', 'Malta', 'Malta', ARRAY['republic of malta']::text[]),
    ('MU', 'MUS', '480', 'Mauritius', 'Mauritius', ARRAY['republic of mauritius']::text[]),
    ('MV', 'MDV', '462', 'Maldives', 'Maldives', ARRAY['republic of maldives']::text[]),
    ('MW', 'MWI', '454', 'Malawi', 'Malawi', ARRAY['republic of malawi']::text[]),
    ('MX', 'MEX', '484', 'Mexico', 'Mexico', ARRAY['united mexican states']::text[]),
    ('MY', 'MYS', '458', 'Malaysia', 'Malaysia', '{}'::text[]),
    ('MZ', 'MOZ', '508', 'Mozambique', 'Mozambique', ARRAY['republic of mozambique']::text[]),
    ('NA', 'NAM', '516', 'Namibia', 'Namibia', ARRAY['republic of namibia']::text[]),
    ('NC', 'NCL', '540', 'New Caledonia', 'New Caledonia', '{}'::text[]),
    ('NE', 'NER', '562', 'Niger', 'Niger', ARRAY['republic of the niger']::text[]),
    ('NF', 'NFK', '574', 'Norfolk Island', 'Norfolk Island', '{}'::text[]),
    ('NG', 'NGA', '566', 'Nigeria', 'Nigeria', ARRAY['federal republic of nigeria']::text[]),
    ('NI', 'NIC', '558', 'Nicaragua', 'Nicaragua', ARRAY['republic of nicaragua']::text[]),
    ('NL', 'NLD', '528', 'Netherlands', 'Netherlands', ARRAY['kingdom of the netherlands']::text[]),
    ('NO', 'NOR', '578', 'Norway', 'Norway', ARRAY['kingdom of norway']::text[]),
    ('NP', 'NPL', '524', 'Nepal', 'Nepal', ARRAY['federal democratic republic of nepal']::text[]),
    ('NR', 'NRU', '520', 'Nauru', 'Nauru', ARRAY['republic of nauru']::text[]),
    ('NU', 'NIU', '570', 'Niue', 'Niue', '{}'::text[]),
    ('NZ', 'NZL', '554', 'New Zealand', 'New Zealand', '{}'::text[]),
    ('OM', 'OMN', '512', 'Oman', 'Oman', ARRAY['sultanate of oman']::text[]),
    ('PA', 'PAN', '591', 'Panama', 'Panama', ARRAY['republic of panama']::text[]),
    ('PE', 'PER', '604', 'Peru', 'Peru', ARRAY['republic of peru']::text[]),
    ('PF', 'PYF', '258', 'French Polynesia', 'French Polynesia', '{}'::text[]),
    ('PG', 'PNG', '598', 'Papua New Guinea', 'Papua New Guinea',
     ARRAY['independent state of papua new guinea']::text[]),
    ('PH', 'PHL', '608', 'Philippines', 'Philippines', ARRAY['republic of the philippines']::text[]),
    ('PK', 'PAK', '586', 'Pakistan', 'Pakistan', ARRAY['islamic republic of pakistan']::text[]),
    ('PL', 'POL', '616', 'Poland', 'Poland', ARRAY['republic of poland']::text[]),
    ('PM', 'SPM', '666', 'Saint Pierre and Miquelon', 'Saint Pierre and Miquelon', '{}'::text[]),
    ('PN', 'PCN', '612', 'Pitcairn', 'Pitcairn', '{}'::text[]),
    ('PR', 'PRI', '630', 'Puerto Rico', 'Puerto Rico', '{}'::text[]),
    ('PS', 'PSE', '275', 'Palestine, State of', 'Palestine, State of',
     ARRAY['the state of palestine', 'palestine']::text[]),
    ('PT', 'PRT', '620', 'Portugal', 'Portugal', ARRAY['portuguese republic']::text[]),
    ('PW', 'PLW', '585', 'Palau', 'Palau', ARRAY['republic of palau']::text[]),
    ('PY', 'PRY', '600', 'Paraguay', 'Paraguay', ARRAY['republic of paraguay']::text[]),
    ('QA', 'QAT', '634', 'Qatar', 'Qatar', ARRAY['state of qatar']::text[]),
    ('RE', 'REU', '638', 'Réunion', 'Réunion', '{}'::text[]),
    ('RO', 'ROU', '642', 'Romania', 'Romania', '{}'::text[]),
    ('RS', 'SRB', '688', 'Serbia', 'Serbia', ARRAY['republic of serbia']::text[]),
    ('RU', 'RUS', '643', 'Russian Federation', 'Russian Federation', ARRAY['russia']::text[]),
    ('RW', 'RWA', '646', 'Rwanda', 'Rwanda', ARRAY['rwandese republic']::text[]),
    ('SA', 'SAU', '682', 'Saudi Arabia', 'Saudi Arabia', ARRAY['kingdom of saudi arabia']::text[]),
    ('SB', 'SLB', '090', 'Solomon Islands', 'Solomon Islands', '{}'::text[]),
    ('SC', 'SYC', '690', 'Seychelles', 'Seychelles', ARRAY['republic of seychelles']::text[]),
    ('SD', 'SDN', '729', 'Sudan', 'Sudan', ARRAY['republic of the sudan']::text[]),
    ('SE', 'SWE', '752', 'Sweden', 'Sweden', ARRAY['kingdom of sweden']::text[]),
    ('SG', 'SGP', '702', 'Singapore', 'Singapore', ARRAY['republic of singapore']::text[]),
    ('SH', 'SHN', '654', 'Saint Helena, Ascension and Tristan da Cunha', 'Saint Helena, Ascension and Tristan da Cunha',
     '{}'::text[]),
    ('SI', 'SVN', '705', 'Slovenia', 'Slovenia', ARRAY['republic of slovenia']::text[]),
    ('SJ', 'SJM', '744', 'Svalbard and Jan Mayen', 'Svalbard and Jan Mayen', '{}'::text[]),
    ('SK', 'SVK', '703', 'Slovakia', 'Slovakia', ARRAY['slovak republic']::text[]),
    ('SL', 'SLE', '694', 'Sierra Leone', 'Sierra Leone', ARRAY['republic of sierra leone']::text[]),
    ('SM', 'SMR', '674', 'San Marino', 'San Marino', ARRAY['republic of san marino']::text[]),
    ('SN', 'SEN', '686', 'Senegal', 'Senegal', ARRAY['republic of senegal']::text[]),
    ('SO', 'SOM', '706', 'Somalia', 'Somalia', ARRAY['federal republic of somalia']::text[]),
    ('SR', 'SUR', '740', 'Suriname', 'Suriname', ARRAY['republic of suriname']::text[]),
    ('SS', 'SSD', '728', 'South Sudan', 'South Sudan', ARRAY['republic of south sudan']::text[]),
    ('ST', 'STP', '678', 'Sao Tome and Principe', 'Sao Tome and Principe',
     ARRAY['democratic republic of sao tome and principe']::text[]),
    ('SV', 'SLV', '222', 'El Salvador', 'El Salvador', ARRAY['republic of el salvador']::text[]),
    ('SX', 'SXM', '534', 'Sint Maarten (Dutch part)', 'Sint Maarten (Dutch part)', '{}'::text[]),
    ('SY', 'SYR', '760', 'Syria', 'Syrian Arab Republic', '{}'::text[]),
    ('SZ', 'SWZ', '748', 'Eswatini', 'Eswatini', ARRAY['kingdom of eswatini', 'swaziland']::text[]),
    ('TC', 'TCA', '796', 'Turks and Caicos Islands', 'Turks and Caicos Islands', '{}'::text[]),
    ('TD', 'TCD', '148', 'Chad', 'Chad', ARRAY['republic of chad']::text[]),
    ('TF', 'ATF', '260', 'French Southern Territories', 'French Southern Territories', '{}'::text[]),
    ('TG', 'TGO', '768', 'Togo', 'Togo', ARRAY['togolese republic']::text[]),
    ('TH', 'THA', '764', 'Thailand', 'Thailand', ARRAY['kingdom of thailand']::text[]),
    ('TJ', 'TJK', '762', 'Tajikistan', 'Tajikistan', ARRAY['republic of tajikistan']::text[]),
    ('TK', 'TKL', '772', 'Tokelau', 'Tokelau', '{}'::text[]),
    ('TL', 'TLS', '626', 'Timor-Leste', 'Timor-Leste',
     ARRAY['democratic republic of timor-leste', 'east timor']::text[]),
    ('TM', 'TKM', '795', 'Turkmenistan', 'Turkmenistan', '{}'::text[]),
    ('TN', 'TUN', '788', 'Tunisia', 'Tunisia', ARRAY['republic of tunisia']::text[]),
    ('TO', 'TON', '776', 'Tonga', 'Tonga', ARRAY['kingdom of tonga']::text[]),
    ('TR', 'TUR', '792', 'Türkiye', 'Türkiye', ARRAY['republic of türkiye', 'turkey']::text[]),
    ('TT', 'TTO', '780', 'Trinidad and Tobago', 'Trinidad and Tobago',
     ARRAY['republic of trinidad and tobago']::text[]),
    ('TV', 'TUV', '798', 'Tuvalu', 'Tuvalu', '{}'::text[]),
    ('TW', 'TWN', '158', 'Taiwan', 'Taiwan, Province of China', '{}'::text[]),
    ('TZ', 'TZA', '834', 'Tanzania', 'Tanzania, United Republic of', ARRAY['united republic of tanzania']::text[]),
    ('UA', 'UKR', '804', 'Ukraine', 'Ukraine', '{}'::text[]),
    ('UG', 'UGA', '800', 'Uganda', 'Uganda', ARRAY['republic of uganda']::text[]),
    ('UM', 'UMI', '581', 'United States Minor Outlying Islands', 'United States Minor Outlying Islands', '{}'::text[]),
    ('US', 'USA', '840', 'United States', 'United States', ARRAY['united states of america']::text[]),
    ('UY', 'URY', '858', 'Uruguay', 'Uruguay', ARRAY['eastern republic of uruguay']::text[]),
    ('UZ', 'UZB', '860', 'Uzbekistan', 'Uzbekistan', ARRAY['republic of uzbekistan']::text[]),
    ('VA', 'VAT', '336', 'Holy See (Vatican City State)', 'Holy See (Vatican City State)',
     ARRAY['vatican', 'vatican city', 'holy see']::text[]),
    ('VC', 'VCT', '670', 'Saint Vincent and the Grenadines', 'Saint Vincent and the Grenadines', '{}'::text[]),
    ('VE', 'VEN', '862', 'Venezuela', 'Venezuela, Bolivarian Republic of',
     ARRAY['bolivarian republic of venezuela']::text[]),
    ('VG', 'VGB', '092', 'Virgin Islands, British', 'Virgin Islands, British', ARRAY['british virgin islands']::text[]),
    ('VI', 'VIR', '850', 'Virgin Islands, U.S.', 'Virgin Islands, U.S.',
     ARRAY['virgin islands of the united states']::text[]),
    ('VN', 'VNM', '704', 'Vietnam', 'Viet Nam', ARRAY['socialist republic of viet nam']::text[]),
    ('VU', 'VUT', '548', 'Vanuatu', 'Vanuatu', ARRAY['republic of vanuatu']::text[]),
    ('WF', 'WLF', '876', 'Wallis and Futuna', 'Wallis and Futuna', '{}'::text[]),
    ('WS', 'WSM', '882', 'Samoa', 'Samoa', ARRAY['independent state of samoa']::text[]),
    ('YE', 'YEM', '887', 'Yemen', 'Yemen', ARRAY['republic of yemen']::text[]),
    ('YT', 'MYT', '175', 'Mayotte', 'Mayotte', '{}'::text[]),
    ('ZA', 'ZAF', '710', 'South Africa', 'South Africa', ARRAY['republic of south africa']::text[]),
    ('ZM', 'ZMB', '894', 'Zambia', 'Zambia', ARRAY['republic of zambia']::text[]),
    ('ZW', 'ZWE', '716', 'Zimbabwe', 'Zimbabwe', ARRAY['republic of zimbabwe']::text[])
ON CONFLICT (iso2) DO NOTHING;

-- ── 2. The free-text resolver ─────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION shared.country_iso2(p_country text) RETURNS character(2)
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT c.iso2
      FROM shared.countries c
     WHERE lower(btrim(p_country)) IN (lower(c.name), lower(c.iso_name))
        OR lower(btrim(p_country)) = ANY (c.aliases)
        OR upper(btrim(p_country)) IN (c.iso2::text, c.iso3::text)
     ORDER BY c.iso2
     LIMIT 1
$fn$;

COMMENT ON FUNCTION shared.country_iso2(text) IS
    'AA-851 (CIS 279): free-text country -> ISO 3166-1 alpha-2 (shared.countries), case- and space-insensitive on '
    'name, iso_name, aliases, iso2 or iso3; NULL when nothing matches. Every key names one country (279 guard 2).';

-- ── 3. country_iso2 on the CIS tables that carry a country ────────────────────────────────────────────────────────
ALTER TABLE silver_aa_internal.raw_tours ADD COLUMN IF NOT EXISTS country_iso2 character(2);
ALTER TABLE shared.destinations ADD COLUMN IF NOT EXISTS country_iso2 character(2);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'silver_aa_internal.raw_tours'::regclass
                                                 AND conname = 'raw_tours_country_iso2_fkey') THEN
        ALTER TABLE silver_aa_internal.raw_tours ADD CONSTRAINT raw_tours_country_iso2_fkey
            FOREIGN KEY (country_iso2) REFERENCES shared.countries (iso2);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'shared.destinations'::regclass
                                                 AND conname = 'destinations_country_iso2_fkey') THEN
        ALTER TABLE shared.destinations ADD CONSTRAINT destinations_country_iso2_fkey
            FOREIGN KEY (country_iso2) REFERENCES shared.countries (iso2);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS raw_tours_country_iso2_idx ON silver_aa_internal.raw_tours (country_iso2);
CREATE INDEX IF NOT EXISTS destinations_country_iso2_idx ON shared.destinations (country_iso2);

COMMENT ON COLUMN silver_aa_internal.raw_tours.country_iso2 IS
    'AA-851 (CIS 279, NAM-11): ISO 3166-1 alpha-2 of country (shared.countries). Set by the trigger '
    'raw_tours_country_iso2 from country (shared.country_iso2) unless written explicitly; NULL = unmapped '
    '(shared.v_country_unmapped). country stays the display text.';
COMMENT ON COLUMN shared.destinations.country_iso2 IS
    'AA-851 (CIS 279, NAM-11): ISO 3166-1 alpha-2 of country (shared.countries). Set by the trigger '
    'destinations_country_iso2 from country (shared.country_iso2) unless written explicitly; NULL = unmapped '
    '(shared.v_country_unmapped). country stays the display text and part of the uniqueness key.';

CREATE OR REPLACE FUNCTION shared.set_country_iso2() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.country_iso2 IS NULL THEN
            NEW.country_iso2 := shared.country_iso2(NEW.country);
        END IF;
    ELSIF NEW.country IS DISTINCT FROM OLD.country AND NEW.country_iso2 IS NOT DISTINCT FROM OLD.country_iso2 THEN
        NEW.country_iso2 := shared.country_iso2(NEW.country);
    END IF;
    RETURN NEW;
END
$fn$;

COMMENT ON FUNCTION shared.set_country_iso2() IS
    'AA-851 (CIS 279): BEFORE INSERT OR UPDATE OF country trigger of raw_tours and shared.destinations: fills a NULL '
    'country_iso2 on INSERT, re-derives it when country changes and country_iso2 was left as it was; an explicit '
    'value is kept, an unknown name leaves NULL.';

DROP TRIGGER IF EXISTS raw_tours_country_iso2 ON silver_aa_internal.raw_tours;
CREATE TRIGGER raw_tours_country_iso2 BEFORE INSERT OR UPDATE OF country ON silver_aa_internal.raw_tours
    FOR EACH ROW EXECUTE FUNCTION shared.set_country_iso2();
DROP TRIGGER IF EXISTS destinations_country_iso2 ON shared.destinations;
CREATE TRIGGER destinations_country_iso2 BEFORE INSERT OR UPDATE OF country ON shared.destinations
    FOR EACH ROW EXECUTE FUNCTION shared.set_country_iso2();

-- ── 4. Backfill (the new trigger does not fire: country is not in the SET list) ───────────────────────────────────
UPDATE silver_aa_internal.raw_tours SET country_iso2 = shared.country_iso2(country)
 WHERE country_iso2 IS NULL AND country IS NOT NULL AND shared.country_iso2(country) IS NOT NULL;
UPDATE shared.destinations SET country_iso2 = shared.country_iso2(country)
 WHERE country_iso2 IS NULL AND country IS NOT NULL AND shared.country_iso2(country) IS NOT NULL;

-- ── 5. The orphan report ──────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW shared.v_country_unmapped WITH (security_invoker = true) AS
SELECT 'silver_aa_internal.raw_tours.country'::text AS source, r.country, count(*) AS row_count
  FROM silver_aa_internal.raw_tours r
 WHERE r.country IS NOT NULL AND r.country_iso2 IS NULL
 GROUP BY r.country
UNION ALL
SELECT 'shared.destinations.country'::text, d.country, count(*)
  FROM shared.destinations d
 WHERE d.country IS NOT NULL AND d.country_iso2 IS NULL
 GROUP BY d.country;

COMMENT ON VIEW shared.v_country_unmapped IS
    'AA-851 (CIS 279): the country orphan report — each free-text country of raw_tours / shared.destinations whose '
    'country_iso2 is NULL (shared.country_iso2 found no match), with its row count. Expected empty; a row means an '
    'alias to add (new migration) or a country_iso2 to set by hand.';

-- ── 6. Grants ─────────────────────────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON shared.countries, shared.v_country_unmapped FROM PUBLIC;
REVOKE ALL ON shared.countries, shared.v_country_unmapped FROM cis_app, aa_app_user, catalog_owner;
REVOKE ALL ON FUNCTION shared.country_iso2(text), shared.set_country_iso2() FROM PUBLIC;
REVOKE ALL ON FUNCTION shared.country_iso2(text), shared.set_country_iso2() FROM cis_app, aa_app_user, catalog_owner;
GRANT SELECT ON shared.countries, shared.v_country_unmapped TO cis_app;
GRANT EXECUTE ON FUNCTION shared.country_iso2(text) TO cis_app;
GRANT SELECT ON shared.countries TO catalog_owner;

-- The trigger runs as the writer (not SECURITY DEFINER, MIG-6) and calls the resolver, which reads shared.countries
-- as that writer: every other role that may write raw_tours or shared.destinations (INSERT at table or column level,
-- UPDATE at table level or on country) gets SELECT on shared.countries and EXECUTE on the resolver. On Dev that is
-- cis_app alone (schema reference 24/10); the loop is what makes a writer the file did not foresee keep working.
-- PUBLIC and aa_app_user (read-only, AA-859) are never given anything: guard 2 refuses them as writers.
DO $$
DECLARE
    w text;
BEGIN
    FOR w IN
        SELECT DISTINCT pg_get_userbyid(a.grantee)
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid IN ('silver_aa_internal.raw_tours'::regclass, 'shared.destinations'::regclass)
           AND a.grantee NOT IN (0, c.relowner) AND a.grantee <> 'aa_app_user'::regrole
           AND a.privilege_type IN ('INSERT', 'UPDATE')
        UNION
        SELECT pg_get_userbyid(a.grantee)
          FROM pg_attribute att JOIN pg_class c ON c.oid = att.attrelid
         CROSS JOIN LATERAL aclexplode(att.attacl) a
         WHERE att.attrelid IN ('silver_aa_internal.raw_tours'::regclass, 'shared.destinations'::regclass)
           AND a.grantee NOT IN (0, c.relowner) AND a.grantee <> 'aa_app_user'::regrole
           AND (a.privilege_type = 'INSERT' OR (a.privilege_type = 'UPDATE' AND att.attname = 'country'))
    LOOP
        EXECUTE format('GRANT SELECT ON shared.countries TO %I', w);
        EXECUTE format('GRANT EXECUTE ON FUNCTION shared.country_iso2(text) TO %I', w);
    END LOOP;
END $$;

-- ── Guard 2 (part A) ──────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    privs    text;
    bad      text;
    unmapped text;
    writers  oid[];
BEGIN
    IF (SELECT count(*) FROM shared.countries) <> 249 THEN
        RAISE EXCEPTION 'migration 279: shared.countries has % rows, expected 249',
            (SELECT count(*) FROM shared.countries);
    END IF;
    SELECT string_agg(k || ' -> ' || codes, ', ' ORDER BY k) INTO bad FROM (
        SELECT k, string_agg(iso2, '/' ORDER BY iso2) AS codes
          FROM (SELECT DISTINCT c.iso2::text AS iso2, k
                  FROM shared.countries c
                 CROSS JOIN LATERAL unnest(ARRAY[lower(c.name), lower(c.iso_name), lower(c.iso2), lower(c.iso3)]
                                           || c.aliases) AS k) x
         GROUP BY k HAVING count(*) > 1) y;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 279: country lookup keys that name more than one country: %', bad;
    END IF;
    SELECT string_agg(n, ', ' ORDER BY n) INTO bad
      FROM unnest(ARRAY['Bhutan', 'Cambodia', 'China', 'India', 'Indonesia', 'Japan', 'Kyrgyzstan', 'Laos',
                        'Malaysia', 'Mongolia', 'Myanmar', 'Nepal', 'Pakistan', 'Philippines', 'South Korea',
                        'Sri Lanka', 'Taiwan', 'Thailand', 'Uzbekistan', 'Vietnam']) n
     WHERE shared.country_iso2(n) IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 279: AA tour countries (chk_raw_tours_country) that do not resolve: %', bad;
    END IF;
    SELECT string_agg(c, ', ') INTO bad FROM unnest(ARRAY[
        'silver_aa_internal.raw_tours:raw_tours_country_iso2_fkey',
        'shared.destinations:destinations_country_iso2_fkey']) c
     WHERE NOT EXISTS (SELECT 1 FROM pg_constraint k
                        WHERE k.conrelid = split_part(c, ':', 1)::regclass AND k.conname = split_part(c, ':', 2)
                          AND k.convalidated);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 279: foreign keys missing or not validated: %', bad;
    END IF;
    IF (SELECT count(*) FROM pg_trigger
         WHERE NOT tgisinternal AND tgfoid = 'shared.set_country_iso2()'::regprocedure
           AND ((tgrelid = 'silver_aa_internal.raw_tours'::regclass AND tgname = 'raw_tours_country_iso2')
                OR (tgrelid = 'shared.destinations'::regclass AND tgname = 'destinations_country_iso2'))) <> 2 THEN
        RAISE EXCEPTION 'migration 279: the country_iso2 triggers are missing';
    END IF;
    IF EXISTS (SELECT 1 FROM silver_aa_internal.raw_tours
                WHERE country_iso2 IS NULL AND shared.country_iso2(country) IS NOT NULL)
       OR EXISTS (SELECT 1 FROM shared.destinations
                   WHERE country_iso2 IS NULL AND shared.country_iso2(country) IS NOT NULL) THEN
        RAISE EXCEPTION 'migration 279: the backfill left a resolvable country without country_iso2';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc
                WHERE oid IN ('shared.country_iso2(text)'::regprocedure, 'shared.set_country_iso2()'::regprocedure)
                  AND (prosecdef OR proconfig IS NULL OR NOT proconfig @> ARRAY['search_path=pg_catalog, pg_temp']
                       OR has_function_privilege('public', oid, 'EXECUTE'))) THEN
        RAISE EXCEPTION 'migration 279: the country functions must be SECURITY INVOKER, pin search_path and give '
                        'PUBLIC no EXECUTE';
    END IF;
    -- The trigger runs as the writer: every role that may write raw_tours / shared.destinations (table or column
    -- level, as the grant loop above) reaches the resolver and its table; cis_app, the runtime writer, always holds
    -- the two grants. PUBLIC and aa_app_user may not write them at all.
    IF NOT has_function_privilege('cis_app', 'shared.country_iso2(text)', 'EXECUTE')
       OR NOT has_table_privilege('cis_app', 'shared.countries', 'SELECT') THEN
        RAISE EXCEPTION 'migration 279: cis_app (the writer the trigger runs as) needs EXECUTE on '
                        'shared.country_iso2(text) and SELECT on shared.countries';
    END IF;
    SELECT array_agg(DISTINCT g) INTO writers FROM (
        SELECT a.grantee AS g
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid IN ('silver_aa_internal.raw_tours'::regclass, 'shared.destinations'::regclass)
           AND a.grantee <> c.relowner AND a.privilege_type IN ('INSERT', 'UPDATE')
        UNION ALL
        SELECT a.grantee
          FROM pg_attribute att JOIN pg_class c ON c.oid = att.attrelid
         CROSS JOIN LATERAL aclexplode(att.attacl) a
         WHERE att.attrelid IN ('silver_aa_internal.raw_tours'::regclass, 'shared.destinations'::regclass)
           AND a.grantee <> c.relowner
           AND (a.privilege_type = 'INSERT' OR (a.privilege_type = 'UPDATE' AND att.attname = 'country'))) w;
    writers := coalesce(writers, '{}');
    IF 0::oid = ANY (writers) OR 'aa_app_user'::regrole::oid = ANY (writers) THEN
        RAISE EXCEPTION 'migration 279: PUBLIC or aa_app_user may write raw_tours / shared.destinations';
    END IF;
    SELECT string_agg(g::regrole::text, ', ' ORDER BY g::regrole::text) INTO bad
      FROM unnest(writers) g
     WHERE NOT has_schema_privilege(g, 'shared', 'USAGE')
        OR NOT has_table_privilege(g, 'shared.countries', 'SELECT')
        OR NOT has_function_privilege(g, 'shared.country_iso2(text)', 'EXECUTE');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 279: role(s) % may write raw_tours / shared.destinations but cannot resolve a '
                        'country (USAGE on shared, SELECT on shared.countries, EXECUTE on shared.country_iso2; the '
                        'trigger runs as the writer)', bad;
    END IF;
    -- … and nobody else: EXECUTE on the resolver only for the writers, on the trigger function for no one, SELECT on
    -- shared.countries only for the writers and catalog_owner (no PUBLIC, no aa_app_user, no consumer).
    SELECT string_agg(x, ', ' ORDER BY x) INTO bad FROM (
        SELECT p.proname || ':' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS x
          FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a
         WHERE p.oid IN ('shared.country_iso2(text)'::regprocedure, 'shared.set_country_iso2()'::regprocedure)
           AND a.grantee <> p.proowner
           AND (p.oid = 'shared.set_country_iso2()'::regprocedure
                OR a.grantee <> ALL (writers || 'cis_app'::regrole::oid))
        UNION ALL
        SELECT 'countries:' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid = 'shared.countries'::regclass AND a.grantee <> c.relowner
           AND a.grantee <> ALL (writers || ARRAY['cis_app'::regrole::oid, 'catalog_owner'::regrole::oid])) y;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 279: grants on the country objects beyond the writers: %', bad;
    END IF;

    SELECT string_agg(r || ':' || o || ':' || p, ', ' ORDER BY r, o, p) INTO privs FROM (
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r,
               c.relname::text AS o, a.privilege_type AS p
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid IN ('shared.countries'::regclass, 'shared.v_country_unmapped'::regclass)
           AND (a.grantee = 0 OR a.grantee IN ('cis_app'::regrole, 'aa_app_user'::regrole,
                                               'catalog_owner'::regrole))) x;
    IF privs IS DISTINCT FROM
         'catalog_owner:countries:SELECT, cis_app:countries:SELECT, cis_app:v_country_unmapped:SELECT' THEN
        RAISE EXCEPTION 'migration 279: unexpected privileges on shared.countries / v_country_unmapped: %', privs;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute a
                WHERE a.attacl IS NOT NULL
                  AND a.attrelid IN ('shared.countries'::regclass, 'shared.v_country_unmapped'::regclass)) THEN
        RAISE EXCEPTION 'migration 279: column-level grants on shared.countries / v_country_unmapped';
    END IF;

    SELECT string_agg(source || ' ' || quote_literal(country) || ' x' || row_count, ', '
                      ORDER BY source, country) INTO unmapped
      FROM shared.v_country_unmapped;
    RAISE NOTICE 'migration 279: raw_tours mapped % / %, destinations mapped % / %; unmapped: %',
        (SELECT count(country_iso2) FROM silver_aa_internal.raw_tours),
        (SELECT count(country) FROM silver_aa_internal.raw_tours),
        (SELECT count(country_iso2) FROM shared.destinations),
        (SELECT count(country) FROM shared.destinations),
        COALESCE(unmapped, 'none');
END $$;

-- ── Part B: catalog.v_country + catalog.v_destination.country_iso2 (X1 S22 catalog recipe) ───────────────────────
DO $$
DECLARE
    cols text;
    v256 text := 'source_system text, source_id text, destination_id uuid, name text, country text, '
                 'lat double precision, lng double precision, cover_photo_path text, cover_image_url text, '
                 'photo_count bigint, created_at timestamp with time zone, updated_at timestamp with time zone, '
                 'geo_status text, located_by text, precision text, shape_kind text, shape_status text, '
                 'shape_source text, length_km double precision, min_lat double precision, min_lng double precision, '
                 'max_lat double precision, max_lng double precision, shape_lo jsonb';
BEGIN
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') IS DISTINCT FROM 'cis_owner' THEN
        RAISE EXCEPTION 'migration 279: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    IF to_regrole('catalog_owner') IS NULL OR to_regrole('booking') IS NULL OR to_regrole('tripplanner') IS NULL THEN
        RAISE EXCEPTION 'migration 279: roles catalog_owner, booking and tripplanner must exist (contracts rule 5)';
    END IF;
    IF NOT has_schema_privilege('catalog_owner', 'shared', 'USAGE')
       OR NOT has_table_privilege('catalog_owner', 'shared.countries', 'SELECT')
       OR NOT has_table_privilege('catalog_owner', 'shared.destinations', 'SELECT') THEN
        RAISE EXCEPTION 'migration 279: catalog_owner cannot read shared.countries / shared.destinations';
    END IF;
    IF to_regclass('catalog.v_destination') IS NULL
       OR (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'catalog.v_destination'::regclass)
          <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 279: catalog.v_destination is missing or not catalog_owner''s';
    END IF;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_destination'::regclass AND a.attnum > 0
       AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM v256 AND cols IS DISTINCT FROM v256 || ', country_iso2 character(2)' THEN
        RAISE EXCEPTION 'migration 279: catalog.v_destination is not 256''s (apply 256 first): %', cols;
    END IF;
    IF to_regclass('catalog.v_country') IS NOT NULL
       AND (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = to_regclass('catalog.v_country'))
           <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 279: catalog.v_country exists and is not catalog_owner''s';
    END IF;
END $$;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 7. The country contract view ──────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_country WITH (security_barrier = true) AS
SELECT c.iso2,
       c.iso3,
       c.numeric_code,
       c.name,
       c.iso_name
  FROM shared.countries c;

COMMENT ON VIEW catalog.v_country IS
    'AA-851 (CIS 279, contract catalog.country.v1): ISO 3166-1, one row per entry (249), key iso2. name = common '
    'English short name (the spelling AA uses), iso_name = ISO short name. Join catalog.v_destination.country_iso2 '
    'on iso2 instead of matching names. Columns are append-only. Read by booking and tripplanner.';

REVOKE ALL ON catalog.v_country FROM PUBLIC;
GRANT SELECT ON catalog.v_country TO booking, tripplanner;

-- ── 8. Destinations + country_iso2 (256's statement, one column appended) ─────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_destination WITH (security_barrier = true) AS
SELECT 'cis'::text      AS source_system,
       d.id::text       AS source_id,
       d.id             AS destination_id,
       d.name,
       d.country,
       d.lat,
       d.lng,
       photos.cover_path AS cover_photo_path,
       d.cover_image_url,
       COALESCE(photos.n, 0) AS photo_count,
       d.created_at,
       GREATEST(d.created_at, d.located_at, photos.last_update) AS updated_at,
       d.geo_status,
       d.located_by,
       d.geo_precision  AS precision,
       -- 256 (appended)
       s.kind           AS shape_kind,
       s.status         AS shape_status,
       s.source         AS shape_source,
       s.length_km::double precision AS length_km,
       COALESCE(s.min_lat, d.lat) AS min_lat,
       COALESCE(s.min_lng, d.lng) AS min_lng,
       COALESCE(s.max_lat, d.lat) AS max_lat,
       COALESCE(s.max_lng, d.lng) AS max_lng,
       s.geom_lo        AS shape_lo,
       -- 279 (appended)
       d.country_iso2
  FROM shared.destinations d
  LEFT JOIN geo.place_shape s ON s.destination_id = d.id AND d.geo_precision = 'line'
  LEFT JOIN LATERAL (
      SELECT count(*) AS n, max(p.updated_at) AS last_update,
             (array_agg(p.path) FILTER (WHERE p.position = 1))[1] AS cover_path
        FROM shared.v_destination_photos p
       WHERE p.destination_id = d.id
  ) photos ON true;

-- CREATE OR REPLACE keeps the existing grants; restated, unguarded (as 256).
GRANT SELECT ON catalog.v_destination TO aa_app_user, tripplanner, booking;

-- ── Closing checks as catalog_owner ───────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    cols text;
BEGIN
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_country'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'iso2 character(2), iso3 character(3), numeric_code character(3), name text, '
                             'iso_name text' THEN
        RAISE EXCEPTION 'migration 279: catalog.v_country has unexpected columns: %', cols;
    END IF;
    SELECT a.attname || ' ' || format_type(a.atttypid, a.atttypmod) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_destination'::regclass AND a.attnum > 0
       AND NOT a.attisdropped
     ORDER BY a.attnum DESC LIMIT 1;
    IF cols IS DISTINCT FROM 'country_iso2 character(2)' THEN
        RAISE EXCEPTION 'migration 279: catalog.v_destination does not end with country_iso2: %', cols;
    END IF;
    IF (SELECT count(*) FROM catalog.v_country) <> 249 THEN
        RAISE EXCEPTION 'migration 279: catalog.v_country does not show the 249 countries';
    END IF;
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Guards on the result (as cis_owner) ───────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    privs text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class
                WHERE oid IN ('catalog.v_country'::regclass, 'catalog.v_destination'::regclass)
                  AND (pg_get_userbyid(relowner) <> 'catalog_owner'
                       OR NOT COALESCE(reloptions, '{}') @> ARRAY['security_barrier=true'])) THEN
        RAISE EXCEPTION 'migration 279: catalog.v_country / v_destination must be catalog_owner''s and '
                        'security_barrier';
    END IF;
    SELECT string_agg(o || ':' || r || ':' || p, ', ' ORDER BY o, r, p) INTO privs FROM (
        SELECT c.relname::text AS o,
               CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r, a.privilege_type AS p
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid IN ('catalog.v_country'::regclass, 'catalog.v_destination'::regclass)
           AND a.grantee <> c.relowner) x;
    IF privs IS DISTINCT FROM 'v_country:booking:SELECT, v_country:tripplanner:SELECT, '
                              'v_destination:aa_app_user:SELECT, v_destination:booking:SELECT, '
                              'v_destination:tripplanner:SELECT' THEN
        RAISE EXCEPTION 'migration 279: unexpected grants on catalog.v_country / v_destination: %', privs;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attacl IS NOT NULL
                                            AND attrelid IN ('catalog.v_country'::regclass,
                                                             'catalog.v_destination'::regclass)) THEN
        RAISE EXCEPTION 'migration 279: column grants on catalog.v_country / v_destination';
    END IF;
    IF has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 279: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('279', now(), 'AA-851: shared.countries (ISO 3166-1, 249 rows), country_iso2 on raw_tours and '
                      'shared.destinations (trigger + backfill, orphan report shared.v_country_unmapped), '
                      'catalog.v_country and catalog.v_destination.country_iso2')
ON CONFLICT (version) DO NOTHING;

COMMIT;
