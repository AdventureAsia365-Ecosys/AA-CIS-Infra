-- Migration 403: AA-1091 item 5 (root ADR 0005 decision 7) — AA-Booking's read of the STRUCTURED reference price of the
-- live published tours: the contract view catalog.v_tour_price_reference_v2.
--
-- Why. catalog.v_tour_price_reference_v1 (CIS 365) gives Booking the free-text source price of a live tour, and Booking
-- parses it on its side (bk_trip_plan_sync). CIS 402 adds the structured reference price that the customer-service
-- team reviews and enters in CIS (amount, currency, basis, review state). Booking should read that reviewed value
-- instead of its own parse, and it should also see the live tours that have no source text but a price entered by
-- staff (281 live tours have no text). v1's contract is "one row per live tour with a source price text, columns only
-- appended"; listing every live tour changes its meaning, so this is a _v2 view next to v1 (v1 stays as it is until
-- Booking stops reading it; then a later migration drops it).
--
-- What:
--   1. catalog.v_tour_price_reference_v2 (security_barrier, owner catalog_owner): one row per live published tour
--      (catalog._live_tour, the served set of catalog.v_tour):
--        source_system 'cis', source_id   the catalog key of catalog.tour.v1
--        price_raw                        the source price text as stored (NULL when blank or missing)
--        reference_amount / _currency / _basis   the structured reference price (402), NULL when none is saved
--        reference_status                 confirmed (a person confirmed it and the text has not changed since) |
--                                         needs_review (the parser had doubts, or the text changed since it was set) |
--                                         parsed (set by the parser, no doubts, nobody confirmed it yet) | NULL (none)
--        reference_origin                 parsed | staff | import (NULL when none)
--        reference_reviewed_at, reference_updated_at
--      SELECT to booking only. Contract v2: columns are only appended; a change of meaning is a _v3 view. The values are
--      reference only, never a selling price: Booking never shows them to an agency or a traveller as a contract price
--      and never puts them in its price.from.v1 view.
--   2. catalog_owner gets SELECT on silver_aa_internal.tour_reference_price (402), the table the view reads (the
--      catalog_owner_aa_master_read policy already narrows its raw_tours read to AA master rows; the price table has
--      AA master keys only).
--   3. Register 403.
--
-- Behaviour. None on apply: nothing reads the view until AA-Booking reads it (feature-detected, like v1).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no expand header): a view under the catalog recipe and a cross-owner GRANT.
-- MIG-4: migration-only PR (with 402); on Dev applied by Infra Migration Apply once every job table is idle (root ADR
-- 0017a). DM-7.1: a view, no new table.
--
-- Guards (RAISE rolls the whole file back): before — schema catalog owned by cis_owner, catalog._live_tour present with
-- source_id and tour_id, silver_aa_internal.tour_reference_price present (402). After, as catalog_owner — the view
-- answers. After, as cis_owner — the view's exact columns, owner catalog_owner, security_barrier, booking can read it,
-- tripplanner / aa_app_user / cis_app / crm_app cannot, catalog_owner has no CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 323 / 341 / 347 / 357 / 365): GRANT CREATE ON SCHEMA catalog TO catalog_owner;
-- SET LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as
-- cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL, no dynamic SQL. The conftest replay
-- skips this file (catalog recipe, 253's _live_tour); tests/integration/test_aa1091_migration_403.py applies it the
-- DB Migrate way and rolls back.
--
-- Number. 401 is the highest on main (12/11/2026); 402 is the table this view reads (same migration-only PR; renumbered from 402).
--
-- Locks. One CREATE VIEW and one GRANT. lock_timeout 5s, statement_timeout 1min. Idempotent (CREATE OR REPLACE with the
-- same column list, re-runnable grants, ON CONFLICT DO NOTHING), one transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after Booking stops reading it): DROP VIEW
-- catalog.v_tour_price_reference_v2.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 403: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    IF to_regclass('catalog._live_tour') IS NULL
       OR (SELECT count(*) FROM pg_attribute WHERE attrelid = 'catalog._live_tour'::regclass
              AND attname IN ('source_id', 'tour_id') AND NOT attisdropped) <> 2 THEN
        RAISE EXCEPTION 'migration 403: catalog._live_tour with source_id and tour_id is missing (apply 253 / 258 first)';
    END IF;
    IF to_regclass('silver_aa_internal.tour_reference_price') IS NULL THEN
        RAISE EXCEPTION 'migration 403: silver_aa_internal.tour_reference_price is missing (apply 402 first)';
    END IF;
END $$;

GRANT SELECT ON silver_aa_internal.tour_reference_price TO catalog_owner;
GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 1. The view: one row per live tour, the source text and the structured reference price ─────────────────────
CREATE OR REPLACE VIEW catalog.v_tour_price_reference_v2 WITH (security_barrier = true) AS
SELECT 'cis'::text AS source_system,
       l.source_id,
       NULLIF(btrim(r.price_raw), '') AS price_raw,
       p.amount AS reference_amount,
       p.currency AS reference_currency,
       p.basis AS reference_basis,
       CASE
           WHEN p.source_key IS NULL THEN NULL
           WHEN p.needs_review OR p.price_raw_seen IS DISTINCT FROM r.price_raw THEN 'needs_review'
           WHEN p.reviewed_at IS NOT NULL THEN 'confirmed'
           ELSE 'parsed'
       END AS reference_status,
       p.origin AS reference_origin,
       p.reviewed_at AS reference_reviewed_at,
       p.updated_at AS reference_updated_at
  FROM catalog._live_tour l
  JOIN silver_aa_internal.raw_tours r ON r.tour_id = l.tour_id
  LEFT JOIN silver_aa_internal.tour_reference_price p ON p.source_key = l.source_id;

COMMENT ON VIEW catalog.v_tour_price_reference_v2 IS
    'AA-1091 (403, root ADR 0005 d7): per live published tour (catalog key of catalog.tour.v1), the source price text and '
    'the structured reference price staff review in CIS (silver_aa_internal.tour_reference_price, 402): amount, '
    'currency, basis, status confirmed | needs_review | parsed. Reference only, never a selling price. Booking only. '
    'Contract v2: columns are only appended.';

GRANT SELECT ON catalog.v_tour_price_reference_v2 TO booking;

-- ── Closing check as catalog_owner: the view answers ─────────────────────────────────────────────────────────────
DO $$
BEGIN
    RAISE NOTICE 'migration 403: as catalog_owner, % live tour(s), % with a structured reference price',
        (SELECT count(*) FROM catalog.v_tour_price_reference_v2),
        (SELECT count(*) FROM catalog.v_tour_price_reference_v2 WHERE reference_amount IS NOT NULL);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner: columns, owner, barrier, exact consumer grant ────────────────────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_tour_price_reference_v2';
    r text;
    cols text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 403: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 403: % is not security_barrier', v;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'booking')
       AND NOT pg_catalog.has_table_privilege('booking', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 403: booking cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 403: % can read % (booking only)', r, v;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'source_system,source_id,price_raw,reference_amount,reference_currency,reference_basis,'
                             'reference_status,reference_origin,reference_reviewed_at,reference_updated_at' THEN
        RAISE EXCEPTION 'migration 403: % columns are %', v, cols;
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 403: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('403', now(), 'AA-1091: catalog.v_tour_price_reference_v2 (live tours with the structured reference price; SELECT to booking only)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
