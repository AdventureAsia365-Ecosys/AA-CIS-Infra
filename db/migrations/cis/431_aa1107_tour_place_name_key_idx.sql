-- migrate: expand
-- Migration 431: AA-1107 (S282, C4.3 W47 finding 2) — an index that serves catalog.v_tour_place's place-pipeline
-- lookup on geo.tour_place without evaluating geo.name_norm on every candidate row.
--
-- Why. catalog.v_tour_place (CIS 256) resolves each tour-day place through a LATERAL lookup:
--     WHERE gp.source_id = g.source_id AND gp.day_index = g.day_number AND gp.destination_id IS NOT NULL
--       AND geo.name_norm(gp.name) = geo.name_norm(g.place_name)
-- The only index is tour_place_source_idx (source_id, day_index), so every output row scanned the day's components
-- and ran geo.name_norm (a non-inlinable SQL function with a long translate) on each of them: on Dev, 0.23 ms x 1,321
-- loops = about 310 ms of the 606 ms catalog HTTP places read for 50 listed tours (S282 audit c43-w47). The stored
-- column geo.tour_place.name_norm cannot serve it: it is name_norm of the LINK name (services/places/components.py
-- Component.name_norm), not of the itinerary spelling in tour_place.name that the view compares.
--
-- What. One non-unique btree on (source_id, day_index, geo.name_norm(name)). geo.name_norm is IMMUTABLE and PARALLEL
-- SAFE (CIS 226), so an expression index is valid and the view's predicate becomes an Index Cond with the place
-- name's key computed once per lookup. No view text changes here (CIS 432 restates the view for the atoms scan).
--
-- Class: expand (root ADR 0017 d3): a new non-unique index on an existing table. geo.tour_place is ~13,400 rows
-- (2026-11-15 dump, below the 100k MIG-10 lock-risk threshold), so a plain CREATE INDEX inside the transaction is
-- allowed; it holds a SHARE lock (writers of geo.tour_place, the place_extract job, wait about a second; readers do
-- not). Idempotent (IF NOT EXISTS), self-registering. Expand files skip the idle wait; lock_timeout 5s.
--
-- Number. 429 is the highest on main (16/11/2026); 430-436 are taken by the other lanes of the S282 wave.
--
-- Rollback (a new forward migration): DROP INDEX geo.tour_place_source_day_name_norm_idx. Readers are unaffected
-- (the view's text does not name the index).

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE INDEX IF NOT EXISTS tour_place_source_day_name_norm_idx
    ON geo.tour_place (source_id, day_index, geo.name_norm(name));

COMMENT ON INDEX geo.tour_place_source_day_name_norm_idx IS
    'AA-1107 (431): catalog.v_tour_place place-pipeline lookup (source, day, name_norm of the itinerary spelling)';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('431', now(), 'AA-1107: geo.tour_place index on (source_id, day_index, geo.name_norm(name)) for catalog.v_tour_place')
ON CONFLICT (version) DO NOTHING;

COMMIT;
