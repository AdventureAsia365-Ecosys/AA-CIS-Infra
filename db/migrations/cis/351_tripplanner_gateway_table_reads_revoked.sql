-- Migration 351: AA-1027 (AI gateway v2, root plan S263 slice E5, gap TP-1) — TripPlanner reads the AI gateway config
-- only through its contract view: revoke the grandfathered SELECT of CIS 173 on shared.llm_role_config and
-- shared.llm_model_catalog.
--
-- Why. CIS 173 (AA-685) let the `tripplanner` role read the two gateway config tables directly. Since CIS 323 (AA-642
-- S8, root ADR 0009 decision 13) TripPlanner reads its routes through catalog.v_llm_gateway_config_v1 and kept the
-- tables only as a fallback while the view was missing; 270 (AA-712 X4) kept the grant for that reason and marked it
-- "grandfathered, removed by X4". AA-TripPlanner-Web (AA-1027 E5) removed the fallback: the gateway reads the view only
-- and fails closed to its normal degrade (basic narration, keyword search) when the view cannot be read; its guard
-- backend/tests/test_extraction_ops.py fails on any SQL string naming either table. Nothing else of TripPlanner names
-- them. So the grant is dead weight: a wider read than the contract (every route of every app, the catalog's notes,
-- blocked reasons and prices of every model) for a role that serves anonymous traffic.
--
-- What (role tripplanner only; nothing else changes):
--   1. REVOKE ALL ON shared.llm_role_config, shared.llm_model_catalog FROM tripplanner (a table-level REVOKE ALL also
--      removes any column privilege).
--   Kept, the contract (AA-CIS-Infra db/owners.yaml consumer_grants): USAGE on schema shared + INSERT on
--   shared.llm_call_log (CIS 173, TripPlanner's ledger rows); USAGE on schema catalog + SELECT on the catalog views,
--   among them catalog.v_llm_gateway_config_v1 and catalog.v_llm_app_spend_today_v1 (323, 341, 350).
--   2. Register 351.
--
-- Guards (RAISE on failure, nothing changes): afterwards tripplanner has no table privilege (SELECT, INSERT, UPDATE,
-- DELETE, TRUNCATE, REFERENCES, TRIGGER) or column privilege (SELECT, INSERT, UPDATE, REFERENCES) on either table (a
-- grant by another grantor, which cis_owner's REVOKE leaves in place, fails the apply and names the grantor); on
-- schema shared tripplanner holds INSERT on shared.llm_call_log and nothing else (the 270 guard's set minus the two
-- tables); it can still read the two contract views when they exist. Skipped with a NOTICE when the role
-- tripplanner does not exist.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no expand header): it changes the ACL of two existing tables. MIG-4: the
-- migration-only PR (with 350), the byte copy in AA-CIS-Infra db/migrations/cis/, Infra Migration Apply with every
-- job table idle (root ADR 0017a). Order (root plan E5): apply AFTER the AA-TripPlanner-Web PR that removes the table
-- fallback is deployed on both Lambdas. An older TripPlanner build reads the view first anyway (its fallback only ran
-- on a missing or ungranted view), so an earlier apply would only take away a fallback that is never used.
--
-- Number. Follows 350 in the same PR (see 350 "Number"); renumber both together if 347 to 349 do not land first.
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243). DB Migrate runs cis/ files as cis_owner, the
-- owner of both tables (245); 245's ALTER OWNER made cis_owner the grantor of 173's grants, so its REVOKE removes them.
-- AA-CIS-App tests/integration/rls_catalogue_rules.py and AA-CIS-Infra db/owners.yaml consumer_grants still list these
-- grants as grandfathered; their entries go stale (reported, not fatal) once this is applied.
--
-- Locks. REVOKE takes a brief lock on each table's ACL; lock_timeout 5s. Re-running is a no-op (REVOKE of a missing
-- privilege does nothing; ON CONFLICT DO NOTHING).
-- Undo: a NEW forward CIS migration (next free number) with GRANT SELECT ON shared.llm_role_config,
-- shared.llm_model_catalog TO tripplanner; only needed if a TripPlanner build that reads the tables is redeployed.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical. After
-- apply the DB Schema Dump workflow regenerates docs/architecture/db-schema-reference.md.

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    rel       text;
    leftover  text;
    grantors  text;
BEGIN
    IF to_regrole('tripplanner') IS NULL THEN
        RAISE NOTICE 'migration 351: role tripplanner does not exist, nothing to revoke';
        RETURN;
    END IF;

    -- 1. the two gateway config tables (each only if it exists: a fresh replay may lack one)
    FOREACH rel IN ARRAY ARRAY['shared.llm_role_config', 'shared.llm_model_catalog'] LOOP
        CONTINUE WHEN to_regclass(rel) IS NULL;
        EXECUTE format('REVOKE ALL ON %s FROM tripplanner', rel);
        IF has_table_privilege('tripplanner', rel, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
           OR EXISTS (SELECT 1 FROM pg_attribute a
                       WHERE a.attrelid = rel::regclass AND a.attnum > 0 AND NOT a.attisdropped
                         AND has_column_privilege('tripplanner', a.attrelid, a.attnum,
                                                  'SELECT, INSERT, UPDATE, REFERENCES')) THEN
            SELECT string_agg(DISTINCT pg_get_userbyid(x.grantor), ', ') INTO grantors
              FROM pg_class c, aclexplode(c.relacl) x
             WHERE c.oid = rel::regclass AND x.grantee = 'tripplanner'::regrole;
            RAISE EXCEPTION 'migration 351: tripplanner still holds a privilege on % (granted by: %)', rel,
                COALESCE(grantors, 'a column grant or a role membership');
        END IF;
    END LOOP;

    -- guard: on schema shared only the ledger INSERT is left
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO leftover
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'shared'
     WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND c.relname <> 'llm_call_log'
       AND (has_table_privilege('tripplanner', c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
            OR EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                          AND has_column_privilege('tripplanner', c.oid, a.attnum, 'SELECT, INSERT, UPDATE, REFERENCES')));
    IF leftover IS NOT NULL THEN
        RAISE EXCEPTION 'migration 351: tripplanner still holds privileges on shared.%', leftover;
    END IF;
    -- guard: the contract is untouched
    IF to_regclass('shared.llm_call_log') IS NOT NULL
       AND NOT has_table_privilege('tripplanner', 'shared.llm_call_log', 'INSERT') THEN
        RAISE EXCEPTION 'migration 351: tripplanner lost INSERT on shared.llm_call_log';
    END IF;
    FOREACH rel IN ARRAY ARRAY['catalog.v_llm_gateway_config_v1', 'catalog.v_llm_app_spend_today_v1'] LOOP
        IF to_regclass(rel) IS NOT NULL AND NOT has_table_privilege('tripplanner', rel, 'SELECT') THEN
            RAISE EXCEPTION 'migration 351: tripplanner cannot read %', rel;
        END IF;
    END LOOP;
    RAISE NOTICE 'migration 351: tripplanner reads of shared.llm_role_config and shared.llm_model_catalog revoked';
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('351', now(), 'AA-1027 E5: tripplanner reads the AI gateway config through catalog.v_llm_gateway_config_v1 '
                      'only (CIS 173 SELECT on llm_role_config / llm_model_catalog revoked)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
