-- Migration 254: AA-847 — TripPlanner loses its grandfathered reads of silver_aa_internal.raw_tours (CIS 179) and of
-- acp_contract.tour_atoms (CIS 180).
--
-- Why. 179 let TripPlanner's tour-day extraction read raw_tours(tour_id, country); 180 let it read the place / activity
-- columns of tour_atoms. The extraction moved to CIS (AA-712 slice 6a, root ADR 0007) and TripPlanner slice 6c
-- (AA-847) moved its last raw_tours reader (backend/shared/catalog_rls.ACTIVE_TOURS_SQL, the extraction checks) to
-- catalog.v_tour. No TripPlanner code reads either table now; a guard test there (backend/tests/test_extraction_ops.py)
-- fails if one comes back. TripPlanner reads CIS content only through catalog.* (root ADR 0001).
--
-- What.
--   1. REVOKE SELECT (tour_id, country) ON silver_aa_internal.raw_tours FROM tripplanner (CIS 179).
--   2. REVOKE USAGE ON SCHEMA silver_aa_internal FROM tripplanner — only when tripplanner then holds no privilege on
--      any object of the schema (179 granted the USAGE for those two columns only); otherwise a NOTICE names the
--      remaining grants and USAGE stays.
--   3. REVOKE SELECT (atom_id, …, is_empty_marker) ON acp_contract.tour_atoms FROM tripplanner (CIS 180).
--   Kept: USAGE on schema acp_contract and the CIS 216 column grants on acp_contract.v_active_tour_atoms (no TripPlanner
--   code reads them either; revoking them is a separate decision for Nghiệp, AA-847 plan slice G).
--   4. Register 254.
--
-- Guards (RAISE on failure, nothing changes): after the revokes, tripplanner has no column privilege on raw_tours or
-- tour_atoms (has_column_privilege, every column). Skipped with a NOTICE when the role tripplanner does not exist.
--
-- Order (AA-847 plan): apply AFTER TripPlanner slice 6c is deployed on both Lambdas (it stops reading raw_tours even
-- with PLACES_SOURCE=legacy) and after the PLACES_SOURCE=cis flip and its post-flip burst. The PLACES_SOURCE=legacy
-- rollback keeps working: the legacy readers read gold_aa_internal.published_tours (still granted), not raw_tours.
-- Undo: a NEW forward CIS migration (next free number) repeating the GRANTs of 179 (USAGE on silver_aa_internal +
-- SELECT (tour_id, country) on raw_tours) and 180 (the tour_atoms column SELECT); 179/180 cannot be re-run, DB Migrate
-- skips registered versions. Only needed if a TripPlanner build from before slice 6c is redeployed.
--
-- Locks. REVOKE takes a brief lock on the two tables' ACLs; lock_timeout 5s. Re-running is a no-op (REVOKE of a missing
-- privilege does nothing; ON CONFLICT DO NOTHING).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243). DB Migrate runs cis/ files as cis_owner, the owner
-- of both tables (245); 245's ALTER OWNER made cis_owner the grantor of the 179/180 grants, so its REVOKE removes them
-- (the guard below is the backstop). AA-CIS-Infra db/rls_catalogue_rules.py
-- and db/owners.yaml consumer_grants mark the two grants "revoked by CIS 254"; their allowlist entries become stale
-- (reported, not fatal) once this is applied, and are removed in a later cleanup.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    remaining text;
    cols      text;
BEGIN
    IF to_regrole('tripplanner') IS NULL THEN
        RAISE NOTICE 'migration 254: role tripplanner does not exist, nothing to revoke';
        RETURN;
    END IF;

    REVOKE SELECT (tour_id, country) ON silver_aa_internal.raw_tours FROM tripplanner;
    REVOKE SELECT (atom_id, tour_id, owner_scope, itinerary_day, place, activity_type, action, text, season_note,
                   deleted, is_empty_marker)
        ON acp_contract.tour_atoms FROM tripplanner;

    -- 2. schema USAGE only when nothing else of the schema is granted to tripplanner
    SELECT string_agg(DISTINCT c.relname, ', ' ORDER BY c.relname) INTO remaining
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'silver_aa_internal'
     WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
       AND (has_table_privilege('tripplanner', c.oid, 'SELECT, INSERT, UPDATE, DELETE')
            OR EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                          AND has_column_privilege('tripplanner', c.oid, a.attnum, 'SELECT, INSERT, UPDATE')));
    IF remaining IS NULL THEN
        REVOKE USAGE ON SCHEMA silver_aa_internal FROM tripplanner;
    ELSE
        RAISE NOTICE 'migration 254: tripplanner keeps USAGE on silver_aa_internal (still granted: %)', remaining;
    END IF;

    -- guard: no column of raw_tours or tour_atoms is readable by tripplanner any more
    SELECT string_agg(c.relname || '.' || a.attname, ', ' ORDER BY c.relname, a.attname) INTO cols
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
     WHERE a.attrelid IN ('silver_aa_internal.raw_tours'::regclass, 'acp_contract.tour_atoms'::regclass)
       AND a.attnum > 0 AND NOT a.attisdropped
       AND has_column_privilege('tripplanner', a.attrelid, a.attnum, 'SELECT');
    IF cols IS NOT NULL THEN
        RAISE EXCEPTION 'migration 254: tripplanner can still read %', cols;
    END IF;
    RAISE NOTICE 'migration 254: tripplanner reads of raw_tours (179) and tour_atoms (180) revoked';
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('254', now(), 'AA-847: revoke tripplanner reads of raw_tours (179) and tour_atoms (180)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
