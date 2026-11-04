-- Migration 365: AA-1029 R4 (root ADR 0005 decision 7) — AA-Booking's read of the source price text of the published
-- tours: the contract view catalog.v_tour_price_reference_v1.
--
-- Why. ADR 0005 d7: an existing free-text raw_tours.price_raw ("$1,722/person", "from USD 495") may be parsed once into
-- a REFERENCE price with a review flag. AA-1029 builds the price chain in Booking (every published master tour gets a
-- Booking trip plan, bk_trip_plan_sync); Booking keeps the text and its parsed amount on the plan for staff to review,
-- next to the price its cost sheet computes. Booking reads the CIS control plane through catalog contract views only
-- (role booking has USAGE on schema catalog, never on silver_aa_internal), like catalog.v_tour (225) and
-- catalog.v_tenant_account_v1 (357). The text is never a selling price: Booking never shows it to an agency or a
-- traveller and never puts it in its price.from.v1 view.
--
-- What:
--   1. catalog.v_tour_price_reference_v1 (security_barrier, owner catalog_owner): one row per live published tour
--      (catalog._live_tour, the served set of catalog.v_tour) whose source row has a non-blank price_raw: source_system
--      ('cis'), source_id (the catalog key of catalog.tour.v1) and price_raw as stored. catalog_owner already reads
--      silver_aa_internal.raw_tours (table SELECT, policy catalog_owner_aa_master_read: AA master rows only), so no new
--      grant on the base table. SELECT to booking only. Contract v1: columns are only appended; a change of meaning is
--      a _v2 view.
--   2. Register 365.
--
-- Behaviour. None on apply: nothing reads the view until the AA-Booking AA-1029 code is deployed, and that code
-- detects the view (42P01 / 42501 before this file: the bridge skips the reference part).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no expand header): a view under the catalog recipe and a cross-owner GRANT.
-- MIG-4: migration-only PR; on Dev applied by Infra Migration Apply once every job table is idle (root ADR 0017a).
-- DM-7.1: a view, no new table.
--
-- Guards (RAISE rolls the whole file back): before — schema catalog owned by cis_owner, catalog._live_tour present with
-- source_id and tour_id. After, as catalog_owner — the view answers. After, as cis_owner — the view's exact columns,
-- owner catalog_owner, security_barrier, booking can read it, tripplanner / aa_app_user / cis_app / crm_app cannot,
-- catalog_owner has no CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 323 / 341 / 347 / 357): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET
-- LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as cis_owner
-- (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL, no dynamic SQL. The conftest replay skips this
-- file (catalog recipe, 253's _live_tour); tests/integration/test_aa1029_migration_365.py applies it the DB Migrate way
-- and rolls back.
--
-- Number. 361 is the highest on main (04/11); 362-364 (AA-1035) and 365 are taken by parallel lanes. If the main max
-- differs when this merges, renumber to the owner main max + 1 (git grep '365_' and '365' in this file, the test and
-- conftest).
--
-- Locks. One CREATE VIEW and one GRANT. lock_timeout 5s, statement_timeout 1min. Idempotent (CREATE OR REPLACE with the
-- same column list, re-runnable grants, ON CONFLICT DO NOTHING), one transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after the Booking bridge stops reading it): DROP VIEW
-- catalog.v_tour_price_reference_v1.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 365: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    IF to_regclass('catalog._live_tour') IS NULL
       OR (SELECT count(*) FROM pg_attribute WHERE attrelid = 'catalog._live_tour'::regclass
              AND attname IN ('source_id', 'tour_id') AND NOT attisdropped) <> 2 THEN
        RAISE EXCEPTION 'migration 365: catalog._live_tour with source_id and tour_id is missing (apply 253 / 258 first)';
    END IF;
END $$;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 1. The view: one row per live tour with a source price text ──────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour_price_reference_v1 WITH (security_barrier = true) AS
SELECT 'cis'::text AS source_system,
       l.source_id,
       r.price_raw
  FROM catalog._live_tour l
  JOIN silver_aa_internal.raw_tours r ON r.tour_id = l.tour_id
 WHERE r.price_raw IS NOT NULL AND btrim(r.price_raw) <> '';

COMMENT ON VIEW catalog.v_tour_price_reference_v1 IS
    'AA-1029 (365, root ADR 0005 d7): per live published tour (catalog key of catalog.tour.v1), the free-text source '
    'price of its raw row as stored, for the AA-Booking reviewed reference price (bk_trip_plan_sync). Reference only, '
    'never a selling price. Booking only. Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_tour_price_reference_v1 TO booking;

-- ── Closing check as catalog_owner: the view answers ─────────────────────────────────────────────────────────────
DO $$
BEGIN
    RAISE NOTICE 'migration 365: as catalog_owner, % live tour(s) with a source price text',
        (SELECT count(*) FROM catalog.v_tour_price_reference_v1);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner: columns, owner, barrier, exact consumer grant ────────────────────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_tour_price_reference_v1';
    r text;
    cols text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 365: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 365: % is not security_barrier', v;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'booking')
       AND NOT pg_catalog.has_table_privilege('booking', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 365: booking cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 365: % can read % (booking only)', r, v;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'source_system,source_id,price_raw' THEN
        RAISE EXCEPTION 'migration 365: % columns are %', v, cols;
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 365: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('365', now(), 'AA-1029 R4: catalog.v_tour_price_reference_v1 (the source price text of live tours, Booking reviewed reference price; SELECT to booking only)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
