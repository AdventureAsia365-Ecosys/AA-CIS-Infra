-- Migration 270: AA-712 X4 — TripPlanner keeps only its contract reads of CIS: the catalog views and the Model Gateway.
--
-- Why. Root ADR 0001 / 0002: other apps read CIS content only through catalog.* views. TripPlanner still held the
-- grants of its first pilot, which read CIS tables directly. Since the PLACES_SOURCE=cis flip (AA-847, 22/10/2026)
-- and the X4 removal of the legacy readers (AA-TripPlanner-Web "TripPlanner reads CIS only through the catalog
-- views"), no TripPlanner code reads them: its guard backend/tests/test_extraction_ops.py fails on any
-- schema-qualified object in a backend SQL string outside catalog.*, the Model Gateway tables and its own live
-- tripplanner tables. CIS 254 already revoked raw_tours (179) and tour_atoms (180).
--
-- What (role tripplanner only; nothing else changes):
--   1. REVOKE ALL ON gold_aa_internal.published_tours           (the pilot's tenant-RLS read; granted out of band)
--      REVOKE ALL ON shared.destinations                        (CIS 201 kept SELECT; catalog.v_destination replaces it)
--      REVOKE ALL ON shared.v_destination_photos, v_tour_photos (CIS 201; catalog.v_destination_photo / v_tour_photo)
--      REVOKE ALL ON acp_contract.v_active_tour_atoms           (CIS 216 column grants; a table-level REVOKE also
--                                                                revokes the column privileges)
--   2. REVOKE USAGE ON SCHEMA gold_aa_internal / acp_contract — each only when tripplanner then holds no privilege on
--      any object of that schema (otherwise a NOTICE names what is left and USAGE stays, as 254 did for silver).
--   Kept, the contract (owners.yaml consumer_grants): USAGE on schema shared + SELECT on shared.llm_role_config and
--   shared.llm_model_catalog + INSERT on shared.llm_call_log (CIS 173, TripPlanner's own model calls); USAGE on
--   schema catalog + SELECT on the catalog views (225, 228, 253, 256, 257); EXECUTE on geo.name_norm(text) (228).
--   3. Register 270.
--
-- Guards (RAISE on failure, nothing changes): afterwards tripplanner has no table privilege (any of the seven:
-- SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER) or column privilege (SELECT, INSERT, UPDATE,
-- REFERENCES) on any relation of gold_aa_internal, silver_aa_internal, acp_contract or acp_shared, and on shared
-- exactly the three gateway relations; when step 2 revoked a schema's USAGE, has_schema_privilege must be false
-- afterwards (a USAGE granted by another grantor survives the REVOKE and fails the apply, naming the grantor); the
-- catalog reads are untouched (has_table_privilege on catalog.v_tour). Skipped with a NOTICE when the role
-- tripplanner does not exist.
--
-- Order (AA-712 X4 plan): apply AFTER the TripPlanner reader removal is deployed on both Lambdas. (The live
-- PLACES_SOURCE=cis path already reads none of these objects, so an earlier apply would only break the
-- PLACES_SOURCE=legacy rollback that the reader removal retires anyway.)
-- Undo: a NEW forward CIS migration (next free number) repeating the grants (SELECT on the four relations, the 216
-- column list on v_active_tour_atoms, USAGE on the two schemas); only needed if a TripPlanner build from before the
-- reader removal is redeployed.
--
-- Locks. REVOKE takes a brief lock on each relation's ACL; lock_timeout 5s (DB Migrate default). Re-running is a
-- no-op (REVOKE of a missing privilege does nothing; ON CONFLICT DO NOTHING).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243). DB Migrate runs cis/ files as cis_owner, the
-- owner of every object here (245); 245's ALTER OWNER made cis_owner the grantor of the earlier grants, so its REVOKE
-- removes them (the guard is the backstop: a grant by another grantor would fail the guard, not pass silently).
-- AA-CIS-App tests/integration/rls_catalogue_rules.py (canonical) and AA-CIS-Infra db/owners.yaml consumer_grants
-- mark these grants "revoked by CIS 270"; their allowlist entries go stale (reported, not fatal) once applied.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    rel        text;
    sch        text;
    remaining  text;
    leftover   text;
BEGIN
    IF to_regrole('tripplanner') IS NULL THEN
        RAISE NOTICE 'migration 270: role tripplanner does not exist, nothing to revoke';
        RETURN;
    END IF;

    -- 1. the relations (each only if it exists: a fresh replay may lack one)
    FOREACH rel IN ARRAY ARRAY['gold_aa_internal.published_tours', 'shared.destinations',
                               'shared.v_destination_photos', 'shared.v_tour_photos',
                               'acp_contract.v_active_tour_atoms'] LOOP
        IF to_regclass(rel) IS NOT NULL THEN
            EXECUTE format('REVOKE ALL ON %s FROM tripplanner', rel);
        END IF;
    END LOOP;

    -- 2. schema USAGE only when nothing else of the schema is granted to tripplanner
    FOREACH sch IN ARRAY ARRAY['gold_aa_internal', 'acp_contract'] LOOP
        CONTINUE WHEN to_regnamespace(sch) IS NULL;
        SELECT string_agg(DISTINCT c.relname, ', ' ORDER BY c.relname) INTO remaining
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = sch
         WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
           AND (has_table_privilege('tripplanner', c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
                OR EXISTS (SELECT 1 FROM pg_attribute a
                            WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                              AND has_column_privilege('tripplanner', c.oid, a.attnum, 'SELECT, INSERT, UPDATE, REFERENCES')));
        IF remaining IS NULL THEN
            EXECUTE format('REVOKE USAGE ON SCHEMA %I FROM tripplanner', sch);
            -- guard: a USAGE grant made by another grantor (out of band) survives cis_owner's REVOKE silently
            IF has_schema_privilege('tripplanner', sch, 'USAGE') THEN
                RAISE EXCEPTION 'migration 270: tripplanner still holds USAGE on schema % (granted by: %)', sch,
                    (SELECT string_agg(DISTINCT pg_get_userbyid(a.grantor), ', ')
                       FROM pg_namespace n, aclexplode(n.nspacl) a
                      WHERE n.nspname = sch AND a.grantee = 'tripplanner'::regrole AND a.privilege_type = 'USAGE');
            END IF;
        ELSE
            RAISE NOTICE 'migration 270: tripplanner keeps USAGE on % (still granted: %)', sch, remaining;
        END IF;
    END LOOP;

    -- guard: no table or column privilege left outside the contract
    SELECT string_agg(n.nspname || '.' || c.relname, ', ' ORDER BY n.nspname, c.relname) INTO leftover
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname IN ('gold_aa_internal', 'silver_aa_internal', 'acp_contract', 'acp_shared', 'shared')
       AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND NOT (n.nspname = 'shared' AND c.relname IN ('llm_role_config', 'llm_model_catalog', 'llm_call_log'))
       AND (has_table_privilege('tripplanner', c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
            OR EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                          AND has_column_privilege('tripplanner', c.oid, a.attnum, 'SELECT, INSERT, UPDATE, REFERENCES')));
    IF leftover IS NOT NULL THEN
        RAISE EXCEPTION 'migration 270: tripplanner still holds privileges on %', leftover;
    END IF;
    -- guard: the contract reads are untouched
    IF to_regclass('catalog.v_tour') IS NOT NULL AND NOT has_table_privilege('tripplanner', 'catalog.v_tour', 'SELECT') THEN
        RAISE EXCEPTION 'migration 270: tripplanner lost SELECT on catalog.v_tour';
    END IF;
    IF to_regclass('shared.llm_call_log') IS NOT NULL
       AND NOT has_table_privilege('tripplanner', 'shared.llm_call_log', 'INSERT') THEN
        RAISE EXCEPTION 'migration 270: tripplanner lost INSERT on shared.llm_call_log';
    END IF;
    RAISE NOTICE 'migration 270: tripplanner reads of published_tours, destinations, the photo views and v_active_tour_atoms revoked';
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('270', now(), 'AA-712 X4: tripplanner keeps only the catalog views and the Model Gateway grants of CIS')
ON CONFLICT (version) DO NOTHING;

COMMIT;
