-- migrate: destructive
-- Migration 299: AA-850 (Dead Table Registry) — drop the four empty legacy ACP v1 schemas.
--
-- What. acp_gold_output, acp_silver_s2, acp_silver_s3 and acp_silver_s4 held the ACP v1 stage chain (published_content,
-- visibility_reports / competitor_inputs, ads_plan / content_calendars, blog_drafts / social_content). CIS 121 and 208
-- dropped their last tables; since then each schema is empty on Dev (0 objects in the schema reference: owner
-- cis_owner since 245, cis_app USAGE plus default privileges since 244 / 245, nothing else). No service reads or
-- writes them: the only code that still named one, the /v1/social router over acp_silver_s4.social_content (gone
-- since 121, every call failed), is removed in the same PR. The tech lead approved the drop in S255 (28/10/2026).
--
-- Guard. Each schema must hold no relation (table, view, materialized view, sequence, index, foreign table, composite
-- type), no function / procedure / aggregate, no type / domain / enum, no collation, no operator, no text search object
-- and no conversion; otherwise the whole file is refused and names what it found. An absent schema is skipped (a
-- re-run, or a database that never had it). RESTRICT (also the default) is the backstop for any other kind of object.
-- The schema ACL (cis_app USAGE) and the pg_default_acl rows FOR ROLE aa_cis_admin / cis_owner IN SCHEMA s (244, 245)
-- are not objects in the schema: they go with it.
--
-- Archive. The header `migrate: destructive` makes DB Migrate take an RDS snapshot before the apply
-- (db-migrate-299-<run>-<attempt>). There are no rows to keep; the snapshot holds the schema ACLs and default
-- privileges. Rollback: none in SQL (CREATE SCHEMA … AUTHORIZATION cis_owner plus 244's grants would rebuild them;
-- nothing needs them).
--
-- Run by DB Migrate as the owner of the CIS schemas (cis_owner, the owner of the four since 245).
-- No REQUIRED_CIS_SCHEMA bump: no code needs it.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    s     text;
    ns    oid;
    found text;
BEGIN
    FOREACH s IN ARRAY ARRAY['acp_gold_output', 'acp_silver_s2', 'acp_silver_s3', 'acp_silver_s4'] LOOP
        SELECT oid INTO ns FROM pg_namespace WHERE nspname = s;
        CONTINUE WHEN ns IS NULL;                                    -- already dropped (re-run) or never there
        SELECT string_agg(x, ', ' ORDER BY x) INTO found FROM (
            SELECT 'relation ' || relname::text AS x FROM pg_class WHERE relnamespace = ns
            UNION ALL SELECT 'function ' || proname::text FROM pg_proc WHERE pronamespace = ns
            UNION ALL SELECT 'type ' || typname::text FROM pg_type WHERE typnamespace = ns
            UNION ALL SELECT 'collation ' || collname::text FROM pg_collation WHERE collnamespace = ns
            UNION ALL SELECT 'operator ' || oprname::text FROM pg_operator WHERE oprnamespace = ns
            UNION ALL SELECT 'conversion ' || conname::text FROM pg_conversion WHERE connamespace = ns
            UNION ALL SELECT 'text search configuration ' || cfgname::text FROM pg_ts_config WHERE cfgnamespace = ns
            UNION ALL SELECT 'text search dictionary ' || dictname::text FROM pg_ts_dict WHERE dictnamespace = ns
        ) o;
        IF found IS NOT NULL THEN
            RAISE EXCEPTION 'migration 299: schema % is not empty (%): stop and re-check', s, found;
        END IF;
    END LOOP;
END $$;

DROP SCHEMA IF EXISTS acp_gold_output RESTRICT;
DROP SCHEMA IF EXISTS acp_silver_s2   RESTRICT;
DROP SCHEMA IF EXISTS acp_silver_s3   RESTRICT;
DROP SCHEMA IF EXISTS acp_silver_s4   RESTRICT;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('299', now(),
        'AA-850: drop the four empty legacy ACP v1 schemas acp_gold_output, acp_silver_s2, acp_silver_s3, acp_silver_s4')
ON CONFLICT (version) DO NOTHING;

COMMIT;
