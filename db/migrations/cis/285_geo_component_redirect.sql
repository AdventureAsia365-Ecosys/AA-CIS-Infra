-- Migration 285: AA-990 (D1, S252) — automatic component-id redirects for TripPlanner saved pins.
--
-- Why. TripPlanner pins a tour component by id (tripplanner.trip_events payload {"component_id"}). A CIS place
-- rebuild keeps an id only on an unambiguous one-to-one pair (AA-989 carry_over_ids); every other previous id is
-- deleted with its geo.tour_place row, and the pins on it dangle (S252 live Dev: 322 of 371 pins after the S1 v2
-- place re-sync). CIS computes, for every dropped id, the component that took its place (components.redirect_dropped:
-- destination → place card → spelling + country → link name + country, generic names only in the same locality).
-- Until now nothing could hand that map to TripPlanner: CIS has no grant on tripplanner.*, and the only path was an
-- AA-CIS-Infra run-script after each re-sync wave. This migration makes it a catalog contract, like
-- catalog.v_destination_redirect (257) for merged destinations.
--
-- What:
--   1. geo.component_redirect — one row per dropped component id (PK old_id): new_id (the component of the same
--      place at the time of the rebuild), source_id, rule (destination / card / spelling / link_name), created_at.
--      Written only by place_extract (services/places/store.write_redirects) in the SAME transaction as the
--      geo.tour_place DELETE + INSERT of that source: the rows of every id the rebuild serves (again) are deleted, the
--      redirects of the ids it dropped are upserted. new_id is not a foreign key: geo.tour_place is DELETE + INSERT
--      per source on every rebuild. A later rebuild that drops new_id adds new_id → newer id, so a reader follows
--      the chain (TripPlanner: ≤ 5 hops, cycle-safe, together with tripplanner.component_id_map).
--   2. catalog.v_component_redirect (component_id → new_component_id, every row; security_barrier) for TripPlanner:
--      a pinned id with no catalog.v_tour_component row is looked up here. Built with the X1 S22 catalog recipe
--      (as 257): owner catalog_owner, SELECT to tripplanner only (Booking does not pin components).
--   3. Privileges: cis_app SELECT / INSERT / UPDATE / DELETE; catalog_owner SELECT (the view reads it); nothing for
--      tripplanner, booking, aa_app_user or PUBLIC (geo is CIS-internal). No RLS: no tenant_id, platform data, like
--      every geo.* table.
--   4. Register 285.
--
-- Guards (RAISE, nothing changes): 0. before: geo.tour_place, schema catalog owned by cis_owner (245).
--   1. after: the table with its named CHECKs, the view's owner and its exact grant, cis_app DML, catalog_owner
--   SELECT, no consumer privilege on the table, catalog_owner without CREATE on schema catalog.
--
-- Recipe. Schema catalog belongs to cis_owner and its views to catalog_owner (X1 S22): GRANT CREATE ON SCHEMA catalog
-- TO catalog_owner; SET LOCAL ROLE catalog_owner; the view; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs
-- the file as cis_owner (login db_migrator). The conftest replay skips this file (the recipe needs 245);
-- tests/integration/test_aa990_migration_285.py applies it the DB Migrate way.
--
-- Order. Apply BEFORE the CIS code that writes the table deploys (place_extract would fail on a missing relation).
-- TripPlanner (component_ids.id_map, AA-990) reads the view on every assembly read: deploy it only after this apply.
--
-- Locks: one new table, one new view — nothing existing is rewritten. lock_timeout 5s. Re-running is a no-op.
-- The SQL applied on Dev is the byte-identical copy in AA-CIS-Infra db/migrations/cis/ (Copy Guard). After apply:
-- the DB Schema Dump workflow regenerates docs/architecture/db-schema-reference.md.
--
-- Rollback: DROP VIEW catalog.v_component_redirect (recipe; TripPlanner falls back to tripplanner.component_id_map
-- only); DROP TABLE geo.component_redirect (the redirects are lost: pins dropped since then dangle again — copy them
-- into tripplanner.component_id_map first with AA-CIS-Infra db/scripts/aa990_component_id_backfill.py);
-- DELETE schema_versions 285. Deploy the CIS code without store.write_redirects first.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0 ──────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('geo.tour_place') IS NULL THEN
        RAISE EXCEPTION 'migration 285: geo.tour_place does not exist';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 285: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. geo.component_redirect ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS geo.component_redirect (
    old_id      uuid         NOT NULL,
    new_id      uuid         NOT NULL,
    source_id   text         NOT NULL,
    rule        text         NOT NULL,
    created_at  timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT component_redirect_pkey PRIMARY KEY (old_id),
    CONSTRAINT component_redirect_not_self_chk CHECK (old_id <> new_id),
    CONSTRAINT component_redirect_rule_chk CHECK (rule IN ('destination', 'card', 'spelling', 'link_name'))
);
CREATE INDEX IF NOT EXISTS component_redirect_source_idx ON geo.component_redirect (source_id);
CREATE INDEX IF NOT EXISTS component_redirect_new_idx ON geo.component_redirect (new_id);

COMMENT ON TABLE geo.component_redirect IS
    'AA-990 (285): a component id a place rebuild dropped → the component of the same place at that rebuild (components.redirect_dropped). Written by place_extract in the transaction of the geo.tour_place rewrite: ids served again are deleted, dropped ids upserted. Chains are possible (a later rebuild dropped new_id); readers follow them. Read by TripPlanner through catalog.v_component_redirect.';
COMMENT ON COLUMN geo.component_redirect.rule IS
    'destination (same linked destination) | card (same place card) | spelling (itinerary spelling + country) | link_name (link name + country); generic names only in the same locality';

-- ── 3. Privileges (geo) ──────────────────────────────────────────────────────────────────────────
REVOKE ALL ON geo.component_redirect FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON geo.component_redirect TO cis_app;
GRANT SELECT ON geo.component_redirect TO catalog_owner;
DO $$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['tripplanner', 'booking', 'aa_app_user'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r) THEN
            EXECUTE format('REVOKE ALL ON geo.component_redirect FROM %I', r);
        END IF;
    END LOOP;
END $$;

-- ── 2. catalog.v_component_redirect (X1 S22 catalog recipe) ─────────────────────────────────────
GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

CREATE OR REPLACE VIEW catalog.v_component_redirect WITH (security_barrier = true) AS
SELECT r.old_id AS component_id, r.new_id AS new_component_id
  FROM geo.component_redirect r;
COMMENT ON VIEW catalog.v_component_redirect IS
    'AA-990 (285): a component id a place rebuild dropped → the component that took its place. A reader that finds no catalog.v_tour_component row for a pinned id looks here and follows the chain (TripPlanner: <= 5 hops, cycle-safe) to an id that is served. catalog.tour contract: appended in the next minor version.';
GRANT SELECT ON catalog.v_component_redirect TO tripplanner;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Guard 1 ──────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    r text;
    missing text;
BEGIN
    SELECT string_agg(x, ', ') INTO missing
      FROM unnest(ARRAY['component_redirect_not_self_chk', 'component_redirect_rule_chk']) AS x
     WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                        WHERE conrelid = 'geo.component_redirect'::regclass AND conname = x AND contype = 'c');
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 285: geo.component_redirect lacks CHECK constraint(s) %', missing;
    END IF;
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'catalog.v_component_redirect'::regclass)
       <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 285: catalog.v_component_redirect is not catalog_owner''s';
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 285: catalog_owner still has CREATE on schema catalog';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'tripplanner')
       AND NOT pg_catalog.has_table_privilege('tripplanner', 'catalog.v_component_redirect', 'SELECT') THEN
        RAISE EXCEPTION 'migration 285: tripplanner cannot read catalog.v_component_redirect';
    END IF;
    FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, 'catalog.v_component_redirect', 'SELECT') THEN
            RAISE EXCEPTION 'migration 285: % can read catalog.v_component_redirect (tripplanner only)', r;
        END IF;
    END LOOP;
    IF NOT pg_catalog.has_table_privilege('cis_app', 'geo.component_redirect', 'SELECT, INSERT, UPDATE, DELETE') THEN
        RAISE EXCEPTION 'migration 285: cis_app lacks DML on geo.component_redirect';
    END IF;
    IF NOT pg_catalog.has_table_privilege('catalog_owner', 'geo.component_redirect', 'SELECT') THEN
        RAISE EXCEPTION 'migration 285: catalog_owner cannot read geo.component_redirect';
    END IF;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'booking', 'aa_app_user'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, 'geo.component_redirect', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE')
        THEN
            RAISE EXCEPTION 'migration 285: % has a privilege on geo.component_redirect (geo is CIS-internal)', r;
        END IF;
    END LOOP;
END $$;

-- ── 4. Register ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('285', now(), 'AA-990: geo.component_redirect (component ids a place rebuild dropped → the component of the '
                      'same place) and catalog.v_component_redirect (tripplanner) for TripPlanner saved pins')
ON CONFLICT (version) DO NOTHING;

COMMIT;
