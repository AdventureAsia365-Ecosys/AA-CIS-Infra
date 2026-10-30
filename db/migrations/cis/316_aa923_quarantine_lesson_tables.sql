-- Migration 316: AA-923 (WM-34, data standards DM-3.9) — quarantine the two retired learning tables in schema
-- `retired`: shared.pipeline_lessons (the AA-132 lessons loop) and acp_shared.acp_output_rules (the N8 output rules).
-- Reversible: nothing is dropped, no row changes.
--
-- Why. App ADR 0010 (governed writing memory) superseded both. AA-915 froze the lessons loop; the AA-923 code PR
-- removed every reader and writer (the /v1/rules router, api/services/acp_post_processor.py,
-- services/acp_produce/rule_adapter.py, services/content_generation/pipeline_lessons.py and the flag_fix write-back),
-- and tests/unit/test_aa923_retired_lesson_paths.py keeps every runtime file from naming them again. DM-3.9: a dead
-- table goes candidate -> quarantine (ALTER … SET SCHEMA retired, no grant) -> drop after >= 14 days, the CIS 294 /
-- 296 path of AA-850 wave 1.
--
-- DRY RUN (read-only, before the apply): scripts/aa923/wm34_dry_run.py through the S3-mediated ECS exec (cis_app);
-- its output goes into the AA-923 Linear comment and must say `verdict ready=true` (both tables present, no dependent
-- view, no inbound foreign key, no acp_output_rules row of a tenant other than the platform). The census of the
-- AA-850 audit (28/10/2026) counted 0 / 0 / 0 inserts / updates / deletes on both since the stats reset.
--
-- What (one transaction, run by DB Migrate as the owner of the CIS schemas, cis_owner since X1 S20/S21):
--   1. Guard, per table: present in its source schema, or already in `retired` (a re-run is a no-op), or absent
--      everywhere (a fresh replay: no repo migration creates acp_output_rules, and the CIS CI replay must apply this
--      file as committed); no view and no foreign key from outside the two depends on it; acp_output_rules holds no
--      row of a tenant other than the platform (once quarantined, the AA-839 erasure no longer reaches it). Outbound
--      FKs stay (acp_output_rules.source_hitl_id was dropped by CIS 121; none is expected).
--   2. ALTER TABLE … SET SCHEMA retired (the schema exists since CIS 294). Indexes, constraints, owned sequences and
--      policies move with the table. The comment gets the prefix `[AA-923 quarantine <date> from <schema>; drop not
--      before <date + 14>]` so the way back is in the catalog.
--   3. Every privilege on the two tables (and their owned sequence) is revoked from every grantee except the owner,
--      PUBLIC included: a forgotten reader now fails loudly (42501) instead of reading stale rows.
--   4. Post-check: each table that existed is in `retired` with no ACL entry other than the owner's, and no app role
--      (membership included) holds a privilege on it.
--
-- Class: contract (root ADR 0017 d3): ALTER TABLE … SET SCHEMA, REVOKE and comments on pre-existing objects. MIG-4:
-- migration-only PR, agent review, manual DB Migrate check -> apply while the job tables are idle, AFTER the AA-923
-- code PR is deployed (the deployed code must not read either table). No readiness bump (no code needs this file).
-- Same PR: tests/integration/rls_catalogue_rules.py (the rule-a allowlist names retired.acp_output_rules instead of
-- acp_shared.acp_output_rules) and services/erasure/inventory.py (the acp_output_rules entry leaves TENANT_TABLES);
-- AA-CIS-Infra: the byte copy db/rls_catalogue_rules.py in the same change window (its Migration Copy Guard checks it).
--
-- Number. 315 (AA-923 WM-32) is the highest on its branch; renumber at merge to main max + 1 (file name, this header,
-- the registration below, the tests).
--
-- Restore (a NEW forward migration, per table):
--   ALTER TABLE retired.<name> SET SCHEMA <from>;  then re-grant what the DRY RUN listed (on Dev cis_app DELETE,
--   INSERT, SELECT, UPDATE on each) and strip the comment prefix.
-- Drop: a later migration, not before the date in the comments, after a second DRY RUN (`-- migrate: destructive`,
-- RDS snapshot first).

BEGIN;

SET LOCAL lock_timeout = '5s';

-- 1. Guard ---------------------------------------------------------------------------------------------------------
DO $$
DECLARE
    w      jsonb := '[{"from": "shared", "name": "pipeline_lessons"}, {"from": "acp_shared", "name": "acp_output_rules"}]';
    e      jsonb;
    src    regclass;
    wave   oid[] := '{}';
    dep    text;
    n      bigint;
BEGIN
    FOR e IN SELECT * FROM jsonb_array_elements(w) LOOP
        src := coalesce(to_regclass(format('%I.%I', e->>'from', e->>'name')),
                        to_regclass(format('retired.%I', e->>'name')));
        IF src IS NOT NULL THEN
            wave := wave || src::oid;
        END IF;
    END LOOP;
    IF to_regnamespace('retired') IS NULL THEN
        RAISE EXCEPTION 'migration 316: schema retired is missing (CIS 294 creates it)';
    END IF;

    FOR e IN SELECT * FROM jsonb_array_elements(w) LOOP
        src := to_regclass(format('%I.%I', e->>'from', e->>'name'));
        CONTINUE WHEN src IS NULL;                     -- already in retired (re-run) or absent (fresh replay)
        IF (SELECT relkind FROM pg_class WHERE oid = src) <> 'r' THEN
            RAISE EXCEPTION 'migration 316: % is not a table', src;
        END IF;
        SELECT string_agg(DISTINCT v.oid::regclass::text, ', ') INTO dep
          FROM pg_depend d
          JOIN pg_rewrite r ON r.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
          JOIN pg_class v ON v.oid = r.ev_class
         WHERE d.refobjid = src AND v.oid <> src AND NOT v.oid = ANY(wave);
        IF dep IS NOT NULL THEN
            RAISE EXCEPTION 'migration 316: view(s) % depend on %', dep, src;
        END IF;
        SELECT string_agg(c.conrelid::regclass::text || '.' || c.conname, ', ') INTO dep
          FROM pg_constraint c
         WHERE c.contype = 'f' AND c.confrelid = src AND c.conrelid <> src AND NOT c.conrelid = ANY(wave);
        IF dep IS NOT NULL THEN
            RAISE EXCEPTION 'migration 316: foreign key(s) % reference %', dep, src;
        END IF;
        IF e->>'name' = 'acp_output_rules'
           AND EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = src AND attname = 'tenant_id' AND NOT attisdropped)
        THEN
            EXECUTE format('SELECT count(*) FROM %s WHERE tenant_id IS NOT NULL AND tenant_id::text <> %L',
                           src, '00000000-0000-0000-0000-000000000001') INTO n;
            IF n > 0 THEN
                RAISE EXCEPTION 'migration 316: % holds % row(s) of a non-platform tenant (erase or archive them first)',
                                src, n;
            END IF;
        END IF;
    END LOOP;
END $$;

-- 2. Move ----------------------------------------------------------------------------------------------------------
ALTER TABLE IF EXISTS shared.pipeline_lessons      SET SCHEMA retired;
ALTER TABLE IF EXISTS acp_shared.acp_output_rules  SET SCHEMA retired;

DO $$
DECLARE
    m   jsonb := '{"pipeline_lessons": "shared", "acp_output_rules": "acp_shared"}';
    k   text;
    o   regclass;
    old text;
BEGIN
    FOR k IN SELECT jsonb_object_keys(m) LOOP
        o := to_regclass(format('retired.%I', k));
        CONTINUE WHEN o IS NULL;                                     -- absent (fresh replay)
        old := obj_description(o, 'pg_class');
        CONTINUE WHEN old LIKE '[AA-923 quarantine%';                -- re-run
        EXECUTE format('COMMENT ON TABLE %s IS %L', o,
                       format('[AA-923 quarantine %s from %s; drop not before %s] ', current_date, m->>k,
                              current_date + 14) || coalesce(old, ''));
    END LOOP;
END $$;

-- 3. No role but the owner keeps a way in --------------------------------------------------------------------------
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT DISTINCT c.oid::regclass AS obj, c.relkind,
               CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END AS grantee
          FROM pg_class c
          JOIN pg_namespace ns ON ns.oid = c.relnamespace
          CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE ns.nspname = 'retired' AND a.grantee <> c.relowner
           AND (c.relname IN ('pipeline_lessons', 'acp_output_rules')
                OR c.oid IN (SELECT d.objid FROM pg_depend d
                              WHERE d.classid = 'pg_class'::regclass AND d.deptype = 'a'
                                AND d.refobjid IN (SELECT to_regclass('retired.pipeline_lessons')
                                                   UNION SELECT to_regclass('retired.acp_output_rules'))))
        UNION
        SELECT DISTINCT c.oid::regclass, c.relkind,
               CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END
          FROM pg_attribute att
          JOIN pg_class c ON c.oid = att.attrelid
          JOIN pg_namespace ns ON ns.oid = c.relnamespace
          CROSS JOIN LATERAL aclexplode(att.attacl) a
         WHERE ns.nspname = 'retired' AND c.relname IN ('pipeline_lessons', 'acp_output_rules')
           AND att.attnum > 0 AND a.grantee <> c.relowner
    LOOP
        EXECUTE format('REVOKE ALL ON %s %s FROM %s',
                       CASE WHEN r.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, r.obj, r.grantee);
    END LOOP;
END $$;

-- 4. Post-check ----------------------------------------------------------------------------------------------------
DO $$
DECLARE
    app_roles text[] := ARRAY['cis_app', 'aa_app_user', 'catalog_owner', 'booking', 'tripplanner', 'crm_app'];
    k  text;
    r  text;
    o  regclass;
BEGIN
    FOREACH k IN ARRAY ARRAY['pipeline_lessons', 'acp_output_rules'] LOOP
        IF to_regclass(format('shared.%I', k)) IS NOT NULL OR to_regclass(format('acp_shared.%I', k)) IS NOT NULL THEN
            RAISE EXCEPTION 'migration 316: post-check: % is still in its source schema', k;
        END IF;
        o := to_regclass(format('retired.%I', k));
        CONTINUE WHEN o IS NULL;                                     -- absent (fresh replay)
        FOREACH r IN ARRAY app_roles LOOP
            CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r);
            IF has_table_privilege(r, o, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
               OR has_any_column_privilege(r, o, 'SELECT, INSERT, UPDATE, REFERENCES') THEN
                RAISE EXCEPTION 'migration 316: post-check: % still has a privilege on %', r, o;
            END IF;
        END LOOP;
        IF EXISTS (SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
                    WHERE c.oid = o AND a.grantee <> c.relowner) THEN
            RAISE EXCEPTION 'migration 316: post-check: privileges left on %', o;
        END IF;
    END LOOP;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('316', now(),
        'AA-923 WM-34 (DM-3.9): quarantine shared.pipeline_lessons and acp_shared.acp_output_rules in schema retired '
        '(no grants); drop after >= 14 days')
ON CONFLICT (version) DO NOTHING;

COMMIT;
