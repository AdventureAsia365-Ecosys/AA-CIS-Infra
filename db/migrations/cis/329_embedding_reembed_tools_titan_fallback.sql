-- Migration 329: AA-1026 D5 + T-15 (AI gateway v2, S263) — the re-embed tools (shadow column, swap, rollback, drop),
-- the ready fallback embedding model of another vendor (Amazon Titan Text Embeddings V2 on acc2, us-west-2, disabled),
-- the coverage guard of the embedding space registry (328) and the TripPlanner view of its search column's space.
--
-- Why. 328 says which space every vector column is in. Moving a column to another space (another model, another
-- dimension) must never mix two spaces in one column and must be reversible: new vectors go to a shadow column,
-- the whole swap group swaps in one transaction once the shadow is full, the old column is kept for a rollback.
-- Swapping by column RENAME needs care: a view binds a column by number, not by name, so a renamed column would keep
-- feeding the old vectors to catalog.v_component_embedding / v_tour_component (TripPlanner search) and
-- acp_contract.v_trip_registry; the swap rebuilds the dependent views from their own definition.
-- The fallback model: the only embedding model on acc2 in us-west-1 is Cohere Embed v4 (aws bedrock
-- list-foundation-models, 01/11/2026). Titan Text Embeddings V2 (Amazon, another vendor) is on demand on acc2 in
-- us-west-2 (allowed by the organization region SCP; the ECS task role allows bedrock:InvokeModel on any resource,
-- migration 238's note). It answers at most 1024 dimensions, so it is its own space (titan-embed-text-v2/1024/v1,
-- standby in 328) and a column moves to it only by a re-embed + swap. Price: AWS Price List API, offer AmazonBedrock,
-- usage type USW2-TitanEmbeddingV2-Text-input-tokens = 0.00002 USD per 1K tokens (0.02 per 1M), read 01/11/2026.
--
-- What.
--   1. Functions (SECURITY INVOKER, owner cis_owner, EXECUTE revoked from PUBLIC and cis_app, which the schema's
--      default privileges grant; called by the table owner through DB Migrate run-script, never by the app role).
--      The same default privileges gave cis_app DML on the two 328 tables: revoked (SELECT stays).
--        shared.embedding_dependent_views(regclass, smallint[])  the views that read the columns, with their depth;
--        shared.embedding_prepare_shadow(schema, table, column, space_key [, column_type])  ADD COLUMN
--            <column>__shadow vector(<dimension>) and record it (column_type is for tests without pgvector), and
--            the trigger <column>__shadow_reset: a writer that rewrites a row's serving vector (UPDATE, or INSERT …
--            ON CONFLICT DO UPDATE, e.g. a T9 piece rewritten) empties that row's shadow vector, so the fill re-reads
--            it like a new row and the swap never promotes a vector of text that is gone. The swap and drop_shadow
--            remove the trigger, the rollback puts it back (the shadow is back);
--        shared.embedding_swap(swap_group [, allow_missing])  every column of the group: refuses while a row has
--            a vector but no shadow vector (the re-embed job resumes), drops the dependent views, renames
--            column -> column__prev and column__shadow -> column (NOT NULL and the single-column indexes follow:
--            <index> -> <index>__prev, <index>__shadow -> <index>), recreates the views from their definition with
--            their options, grants, comments and owner, records space / previous in the registry;
--        shared.embedding_rollback(swap_group [, allow_missing])  the inverse while column__prev exists (the new
--            vectors go back to the shadow column; rows written after the swap have no old vector: refused unless
--            allow_missing, which leaves a NOT NULL column nullable);
--        shared.embedding_drop_shadow(schema, table, column)  abandons a shadow (e.g. after the T-15 test);
--        shared.embedding_drop_previous(swap_group)  drops the kept old vectors (destructive-ops procedure).
--   2. Coverage guard: every vector column of a base table in the CIS schemas is registered (except __shadow /
--      __prev), every registered column exists with the dimension of its space, and the columns of a swap group share
--      a space. Checked only where pgvector exists (the CI integration Postgres has none).
--   3. The fallback model, off behind its connection (switching = one audited admin PATCH + a re-embed, no code):
--        connection acc2-usw2: Bedrock, task role, region us-west-2, aws_only, served_roles {embed}, failure domain
--            bedrock:acc2:aws_only (the same account as acc2: it adds a vendor, not an account), monthly budget 5 USD,
--            DISABLED;
--        catalog titan-embed-text-v2: vendor / family amazon, api_style embed, callable_via {embed},
--            bedrock_profile_ids {"acc2-usw2": "amazon.titan-embed-text-v2:0"} (an on-demand model id, no inference
--            profile), price in 0.02 out 0 per 1M tokens, enabled (a priced row; nothing routes to it);
--        deployment titan-embed-text-v2 on acc2-usw2, priority 20, api_style embed, enabled: it is unusable while its
--            connection is off (vendor_route.deployment_plan keeps enabled deployments on enabled connections only),
--            and cis_app may switch a connection (PATCH /admin/llm-connections/acc2-usw2, audited) but has no UPDATE
--            on deployments, so a disabled deployment would need an owner run-script in an incident.
--      Guard: no stage route, shadow or alias names titan-embed-text-v2.
--   4. catalog.v_embedding_space_v1 (security_barrier, owner catalog_owner, SELECT to tripplanner only): the space of
--      geo.tour_place.embedding (the column TripPlanner searches through catalog.v_component_embedding), so its
--      search embeds the query in that space or falls back to keyword search. Contract v1: columns only appended.
--   5. Register 329.
--
-- Behaviour. No stage changes model; no vector, column or index changes until someone runs a function. The route
-- snapshot (S262 plan Q0) gains exactly one 'cn|', one 'ct|' and one 'dp|' line. The daily probe skips the disabled
-- connection; the re-embed probe (job embedding_reembed, mode probe) calls it once the runbook switches it on.
--
-- RISKY (DDL tools over live vector columns, a catalog view grant, routing rows; S241 D-13): an independent review of
-- this file is required before merge. Class: contract (root ADR 0017 d3: DO blocks, REVOKE, INSERT into routing
-- tables, the catalog.* recipe), so no "-- migrate: expand" header. Order (MIG-4): after 328 (expand, auto-applied);
-- (1) this PR merges to AA-CIS-App main; (2) the byte copy in AA-CIS-Infra db/migrations/cis/ merges; (3) a manual
-- DB Migrate apply; (4) the bot/db-schema-reference PR merges. The code works before and after (registry mirror).
--
-- Rollback (a NEW forward migration): DROP VIEW catalog.v_embedding_space_v1 (recipe as here); DELETE the deployment,
-- catalog and connection rows of titan-embed-text-v2 / acc2-usw2 (delete their llm_provider_health rows first if a
-- probe ran); DROP the ten functions. Only after any re-embed was swapped back (embedding_rollback) or dropped.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).
--
-- X1. One BEGIN … COMMIT block. DB Migrate runs cis/ files as cis_owner; the catalog view uses the X1 S22 recipe
-- (as 323): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE catalog_owner; the view; back to
-- cis_owner; REVOKE CREATE.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '328') THEN
        RAISE EXCEPTION 'migration 329: apply 328 (embedding space registry) first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '322') THEN
        RAISE EXCEPTION 'migration 329: apply 322 (connection registry v2) first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_model_family WHERE family_key = 'amazon') THEN
        RAISE EXCEPTION 'migration 329: model family amazon is missing (320)';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 329: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. the re-embed tools ────────────────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION shared.embedding_dependent_views(p_table regclass, p_attnums smallint[])
RETURNS TABLE (view_oid oid, depth integer)
LANGUAGE sql STABLE AS $fn$
    WITH RECURSIVE d(view_oid, depth) AS (
        SELECT DISTINCT r.ev_class, 1
          FROM pg_depend dep
          JOIN pg_rewrite r ON r.oid = dep.objid
         WHERE dep.classid = 'pg_rewrite'::regclass AND dep.refclassid = 'pg_class'::regclass
           AND dep.refobjid = p_table AND dep.refobjsubid = ANY (p_attnums) AND r.ev_class <> p_table
        UNION ALL
        SELECT r.ev_class, d.depth + 1
          FROM d
          JOIN pg_depend dep ON dep.refobjid = d.view_oid AND dep.classid = 'pg_rewrite'::regclass
                            AND dep.refclassid = 'pg_class'::regclass
          JOIN pg_rewrite r ON r.oid = dep.objid
         WHERE r.ev_class <> d.view_oid AND d.depth < 20
    )
    SELECT view_oid, max(depth)::integer FROM d GROUP BY view_oid
$fn$;

COMMENT ON FUNCTION shared.embedding_dependent_views(regclass, smallint[]) IS
    'AA-1026 (329): the views reading the given columns of a table, directly or through other views, with their '
    'depth (1 = reads the table). The swap drops them deepest first and recreates them shallowest first.';

-- The shadow reset: BEFORE UPDATE OF <column>, when the serving vector changes and the statement did not set the
-- shadow itself, the row's shadow vector becomes NULL (TG_ARGV[0] = the shadow column; jsonb_populate_record sets one
-- field of NEW by name and copies the others as they are). It runs as the writer (cis_app): a trigger function's
-- EXECUTE privilege is checked when the trigger is created (the table owner), not when it fires.
CREATE OR REPLACE FUNCTION shared._embedding_shadow_reset()
RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
    NEW := jsonb_populate_record(NEW, jsonb_build_object(TG_ARGV[0], NULL));
    RETURN NEW;
END
$fn$;

-- Installs (p_install) or removes the shadow reset trigger <column>__shadow_reset of p_table.
CREATE OR REPLACE FUNCTION shared._embedding_shadow_trigger(p_table regclass, p_column text, p_install boolean)
RETURNS void
LANGUAGE plpgsql AS $fn$
DECLARE
    trg text := p_column || '__shadow_reset';
    shadow text := p_column || '__shadow';
BEGIN
    IF length(trg) > 63 THEN
        RAISE EXCEPTION 'embedding shadow trigger: name % is longer than 63 characters', trg;
    END IF;
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', trg, p_table);
    IF p_install THEN
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OF %I ON %s FOR EACH ROW '
                       'WHEN (NEW.%I IS DISTINCT FROM OLD.%I AND NEW.%I IS NOT DISTINCT FROM OLD.%I) '
                       'EXECUTE FUNCTION shared._embedding_shadow_reset(%L)',
                       trg, p_column, p_table, p_column, p_column, shadow, shadow, shadow);
    END IF;
END
$fn$;

-- Renames the single-column indexes of p_table on p_column: strips p_strip from the end of the name, appends p_add.
CREATE OR REPLACE FUNCTION shared._embedding_rename_indexes(p_table regclass, p_column text, p_strip text,
                                                            p_add text)
RETURNS void
LANGUAGE plpgsql AS $fn$
DECLARE
    i record;
    base text;
    new_name text;
BEGIN
    FOR i IN
        SELECT ic.relname, n.nspname
          FROM pg_index x
          JOIN pg_class ic ON ic.oid = x.indexrelid
          JOIN pg_namespace n ON n.oid = ic.relnamespace
          JOIN pg_attribute a ON a.attrelid = x.indrelid AND a.attnum = x.indkey[0]
         WHERE x.indrelid = p_table AND x.indnatts = 1 AND a.attname = p_column AND NOT a.attisdropped
         ORDER BY ic.relname
    LOOP
        base := CASE WHEN p_strip <> '' AND right(i.relname, length(p_strip)) = p_strip
                     THEN left(i.relname, length(i.relname) - length(p_strip)) ELSE i.relname END;
        new_name := base || p_add;
        IF length(new_name) > 63 THEN
            RAISE EXCEPTION 'embedding swap: index name % is longer than 63 characters (rename % first)',
                            new_name, i.relname;
        END IF;
        IF new_name <> i.relname THEN
            EXECUTE format('ALTER INDEX %I.%I RENAME TO %I', i.nspname, i.relname, new_name);
        END IF;
    END LOOP;
END
$fn$;

CREATE OR REPLACE FUNCTION shared.embedding_prepare_shadow(p_schema text, p_table text, p_column text,
                                                           p_space_key text, p_column_type text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
    c shared.embedding_column%ROWTYPE;
    s shared.embedding_space%ROWTYPE;
    col_type text;
    shadow text := p_column || '__shadow';
BEGIN
    SELECT * INTO c FROM shared.embedding_column
     WHERE table_schema = p_schema AND table_name = p_table AND column_name = p_column FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'embedding prepare: %.%.% is not in shared.embedding_column', p_schema, p_table, p_column;
    END IF;
    SELECT * INTO s FROM shared.embedding_space WHERE space_key = p_space_key;
    IF NOT FOUND OR s.status = 'retired' THEN
        RAISE EXCEPTION 'embedding prepare: space % is unknown or retired', p_space_key;
    END IF;
    IF c.space_key = p_space_key THEN
        RAISE EXCEPTION 'embedding prepare: %.%.% already serves %', p_schema, p_table, p_column, p_space_key;
    END IF;
    IF c.previous_column IS NOT NULL THEN
        RAISE EXCEPTION 'embedding prepare: %.%.% still keeps % (roll back or drop it first)',
                        p_schema, p_table, p_column, c.previous_column;
    END IF;
    IF c.shadow_column IS NOT NULL THEN
        IF c.shadow_space_key = p_space_key THEN
            PERFORM shared._embedding_shadow_trigger(format('%I.%I', p_schema, p_table)::regclass, p_column, true);
            RETURN c.shadow_column;                       -- prepared already: the re-embed resumes
        END IF;
        RAISE EXCEPTION 'embedding prepare: %.%.% has a shadow for % (drop it first)',
                        p_schema, p_table, p_column, c.shadow_space_key;
    END IF;
    IF p_column_type IS NULL THEN
        IF to_regtype('vector') IS NULL THEN
            RAISE EXCEPTION 'embedding prepare: pgvector is not installed';
        END IF;
        col_type := format('vector(%s)', s.dimension);
    ELSIF p_column_type ~ '^[a-z][a-z0-9_ ]*(\[\])?$' THEN
        col_type := p_column_type;                        -- tests on a Postgres without pgvector
    ELSE
        RAISE EXCEPTION 'embedding prepare: bad column type %', p_column_type;
    END IF;
    EXECUTE format('ALTER TABLE %I.%I ADD COLUMN %I %s', p_schema, p_table, shadow, col_type);
    EXECUTE format('COMMENT ON COLUMN %I.%I.%I IS %L', p_schema, p_table, shadow,
                   format('AA-1026: re-embed of %s into %s (shadow; swap with shared.embedding_swap)',
                          p_column, p_space_key));
    PERFORM shared._embedding_shadow_trigger(format('%I.%I', p_schema, p_table)::regclass, p_column, true);
    UPDATE shared.embedding_column
       SET shadow_column = shadow, shadow_space_key = p_space_key, updated_at = now(), updated_by = current_user
     WHERE table_schema = p_schema AND table_name = p_table AND column_name = p_column;
    RETURN shadow;
END
$fn$;

-- Swap (p_direction 'swap') or roll back ('rollback') every column of a swap group in one transaction.
CREATE OR REPLACE FUNCTION shared._embedding_switch(p_group text, p_direction text, p_allow_missing boolean)
RETURNS integer
LANGUAGE plpgsql AS $fn$
DECLARE
    c record;
    v record;
    tbl regclass;
    other text;
    parked text;
    other_suffix text;
    parked_suffix text;
    nn boolean;
    missing bigint;
    dim integer;
    typ text;
    attnums smallint[];
    saved jsonb := '[]'::jsonb;
    item jsonb;
    g jsonb;
    granted_create boolean;
    me text := current_user;
    n integer := 0;
BEGIN
    IF p_direction NOT IN ('swap', 'rollback') THEN
        RAISE EXCEPTION 'embedding switch: direction must be swap or rollback, not %', p_direction;
    END IF;
    other_suffix := CASE p_direction WHEN 'swap' THEN '__shadow' ELSE '__prev' END;
    parked_suffix := CASE p_direction WHEN 'swap' THEN '__prev' ELSE '__shadow' END;
    PERFORM 1 FROM shared.embedding_column WHERE swap_group = p_group FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'embedding %: no column in swap group %', p_direction, p_group;
    END IF;

    -- 1. every column of the group is ready
    FOR c IN SELECT * FROM shared.embedding_column WHERE swap_group = p_group
              ORDER BY table_schema, table_name, column_name LOOP
        other := CASE p_direction WHEN 'swap' THEN c.shadow_column ELSE c.previous_column END;
        IF other IS NULL THEN
            RAISE EXCEPTION 'embedding %: %.%.% has no % column (%)', p_direction, c.table_schema, c.table_name,
                c.column_name, other_suffix,
                CASE p_direction WHEN 'swap' THEN 'prepare and fill it first' ELSE 'nothing to roll back' END;
        END IF;
        tbl := format('%I.%I', c.table_schema, c.table_name)::regclass;
        IF (SELECT count(*) FROM pg_attribute WHERE attrelid = tbl AND NOT attisdropped
                                                AND attname IN (c.column_name, other)) <> 2 THEN
            RAISE EXCEPTION 'embedding %: %.% lacks % or %', p_direction, c.table_schema, c.table_name,
                            c.column_name, other;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = tbl AND NOT attisdropped
                                                AND attname = c.column_name || parked_suffix) THEN
            RAISE EXCEPTION 'embedding %: %.%.% already exists', p_direction, c.table_schema, c.table_name,
                            c.column_name || parked_suffix;
        END IF;
        IF p_direction = 'swap' THEN
            SELECT dimension INTO dim FROM shared.embedding_space WHERE space_key = c.shadow_space_key;
            SELECT format_type(atttypid, atttypmod) INTO typ FROM pg_attribute
             WHERE attrelid = tbl AND attname = other AND NOT attisdropped;
            IF typ LIKE 'vector(%' AND typ <> format('vector(%s)', dim) THEN
                RAISE EXCEPTION 'embedding swap: %.%.% is %, space % has dimension %', c.table_schema, c.table_name,
                                other, typ, c.shadow_space_key, dim;
            END IF;
            IF NOT p_allow_missing THEN
                EXECUTE format('SELECT count(*) FROM %s WHERE %I IS NOT NULL AND %I IS NULL', tbl, c.column_name,
                               other) INTO missing;
                IF missing > 0 THEN
                    RAISE EXCEPTION 'embedding swap: %.%: % row(s) have a vector but no shadow vector (run the '
                                    're-embed job again: it resumes)', c.table_schema, c.table_name, missing;
                END IF;
            END IF;
        END IF;
    END LOOP;

    -- 2. the dependent views: saved, then dropped deepest first
    FOR v IN
        SELECT dv.view_oid, max(dv.depth) AS depth
          FROM shared.embedding_column ec
          CROSS JOIN LATERAL shared.embedding_dependent_views(
              format('%I.%I', ec.table_schema, ec.table_name)::regclass,
              ARRAY(SELECT a.attnum FROM pg_attribute a
                     WHERE a.attrelid = format('%I.%I', ec.table_schema, ec.table_name)::regclass
                       AND NOT a.attisdropped
                       AND a.attname IN (ec.column_name, ec.shadow_column, ec.previous_column))) dv
         WHERE ec.swap_group = p_group
         GROUP BY dv.view_oid
         ORDER BY max(dv.depth) DESC, dv.view_oid
    LOOP
        IF (SELECT relkind FROM pg_class WHERE oid = v.view_oid) <> 'v' THEN
            RAISE EXCEPTION 'embedding %: % is not a plain view (rebuild it by hand)', p_direction,
                            v.view_oid::regclass;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = v.view_oid AND attacl IS NOT NULL) THEN
            RAISE EXCEPTION 'embedding %: % has column grants (rebuild it by hand)', p_direction,
                            v.view_oid::regclass;
        END IF;
        SELECT jsonb_build_object(
                   'schema', n.nspname, 'name', cl.relname, 'depth', v.depth,
                   'def', pg_get_viewdef(cl.oid), 'owner', pg_get_userbyid(cl.relowner),
                   'options', to_jsonb(cl.reloptions), 'comment', obj_description(cl.oid, 'pg_class'),
                   'columns', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', a.attname,
                                                   'comment', col_description(cl.oid, a.attnum))), '[]'::jsonb)
                                 FROM pg_attribute a
                                WHERE a.attrelid = cl.oid AND a.attnum > 0 AND NOT a.attisdropped
                                  AND col_description(cl.oid, a.attnum) IS NOT NULL),
                   'grants', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                     'grantee', CASE WHEN x.grantee = 0 THEN 'PUBLIC'
                                                     ELSE pg_get_userbyid(x.grantee) END,
                                     'privilege', x.privilege_type)), '[]'::jsonb)
                                FROM aclexplode(cl.relacl) x
                               WHERE x.grantee <> cl.relowner))
          INTO item
          FROM pg_class cl JOIN pg_namespace n ON n.oid = cl.relnamespace
         WHERE cl.oid = v.view_oid;
        saved := saved || jsonb_build_array(item);
        EXECUTE format('DROP VIEW %I.%I', item ->> 'schema', item ->> 'name');
    END LOOP;

    -- 3. the renames, column by column
    FOR c IN SELECT * FROM shared.embedding_column WHERE swap_group = p_group
              ORDER BY table_schema, table_name, column_name LOOP
        tbl := format('%I.%I', c.table_schema, c.table_name)::regclass;
        other := CASE p_direction WHEN 'swap' THEN c.shadow_column ELSE c.previous_column END;
        parked := c.column_name || parked_suffix;
        SELECT attnotnull INTO nn FROM pg_attribute WHERE attrelid = tbl AND attname = c.column_name
                                                       AND NOT attisdropped;
        -- the reset trigger names columns by number: off before the renames, back on after a rollback only
        PERFORM shared._embedding_shadow_trigger(tbl, c.column_name, false);
        PERFORM shared._embedding_rename_indexes(tbl, c.column_name, '', parked_suffix);
        EXECUTE format('ALTER TABLE %s RENAME COLUMN %I TO %I', tbl, c.column_name, parked);
        IF nn THEN
            EXECUTE format('ALTER TABLE %s ALTER COLUMN %I DROP NOT NULL', tbl, parked);
        END IF;
        EXECUTE format('ALTER TABLE %s RENAME COLUMN %I TO %I', tbl, other, c.column_name);
        PERFORM shared._embedding_rename_indexes(tbl, c.column_name, other_suffix, '');
        IF nn THEN
            EXECUTE format('SELECT count(*) FROM %s WHERE %I IS NULL', tbl, c.column_name) INTO missing;
            IF missing = 0 THEN
                EXECUTE format('ALTER TABLE %s ALTER COLUMN %I SET NOT NULL', tbl, c.column_name);
            ELSIF p_allow_missing THEN
                RAISE NOTICE 'embedding %: %.%.% stays nullable: % row(s) have no vector in it', p_direction,
                             c.table_schema, c.table_name, c.column_name, missing;
            ELSE
                RAISE EXCEPTION 'embedding %: %.%: % row(s) have no vector in % (rows written after the swap have '
                                'no old vector: pass allow_missing, then delete or re-embed them)', p_direction,
                                c.table_schema, c.table_name, missing, CASE p_direction WHEN 'swap' THEN other
                                ELSE c.previous_column END;
            END IF;
        END IF;
        IF p_direction = 'swap' THEN
            UPDATE shared.embedding_column
               SET previous_column = parked, previous_space_key = space_key,
                   space_key = shadow_space_key, shadow_column = NULL, shadow_space_key = NULL,
                   updated_at = now(), updated_by = current_user
             WHERE table_schema = c.table_schema AND table_name = c.table_name AND column_name = c.column_name;
            UPDATE shared.embedding_space SET status = 'active', updated_at = now(), updated_by = current_user
             WHERE space_key = c.shadow_space_key AND status <> 'active';
        ELSE
            UPDATE shared.embedding_column
               SET shadow_column = parked, shadow_space_key = space_key,
                   space_key = previous_space_key, previous_column = NULL, previous_space_key = NULL,
                   updated_at = now(), updated_by = current_user
             WHERE table_schema = c.table_schema AND table_name = c.table_name AND column_name = c.column_name;
            PERFORM shared._embedding_shadow_trigger(tbl, c.column_name, true);
        END IF;
        n := n + 1;
    END LOOP;

    -- 4. the views again, shallowest first, as they were (definition text resolves to the renamed columns). Each is
    -- created BY its owner (the X1 S22 catalog recipe: catalog views are catalog_owner's and the table owner is not a
    -- member of catalog_owner), with CREATE on the schema granted to that owner for the moment it needs it.
    FOR item IN SELECT x FROM jsonb_array_elements(saved) x ORDER BY (x ->> 'depth')::integer, x ->> 'schema',
                                                                    x ->> 'name' LOOP
        granted_create := (item ->> 'owner') <> me
                          AND NOT has_schema_privilege(item ->> 'owner', item ->> 'schema', 'CREATE');
        IF granted_create THEN
            EXECUTE format('GRANT CREATE ON SCHEMA %I TO %I', item ->> 'schema', item ->> 'owner');
        END IF;
        IF (item ->> 'owner') <> me THEN
            EXECUTE format('SET LOCAL ROLE %I', item ->> 'owner');
        END IF;
        EXECUTE format('CREATE VIEW %I.%I%s AS %s', item ->> 'schema', item ->> 'name',
                       CASE WHEN jsonb_typeof(item -> 'options') = 'array'
                            THEN ' WITH (' || (SELECT string_agg(o, ', ')
                                                 FROM jsonb_array_elements_text(item -> 'options') o) || ')'
                            ELSE '' END,
                       rtrim(item ->> 'def', '; ' || chr(10)));
        IF item ->> 'comment' IS NOT NULL THEN
            EXECUTE format('COMMENT ON VIEW %I.%I IS %L', item ->> 'schema', item ->> 'name', item ->> 'comment');
        END IF;
        FOR g IN SELECT x FROM jsonb_array_elements(item -> 'columns') x LOOP
            EXECUTE format('COMMENT ON COLUMN %I.%I.%I IS %L', item ->> 'schema', item ->> 'name', g ->> 'name',
                           g ->> 'comment');
        END LOOP;
        FOR g IN SELECT x FROM jsonb_array_elements(item -> 'grants') x LOOP
            EXECUTE format('GRANT %s ON %I.%I TO %s', g ->> 'privilege', item ->> 'schema', item ->> 'name',
                           CASE WHEN g ->> 'grantee' = 'PUBLIC' THEN 'PUBLIC' ELSE quote_ident(g ->> 'grantee') END);
        END LOOP;
        IF (item ->> 'owner') <> me THEN
            EXECUTE format('SET LOCAL ROLE %I', me);
        END IF;
        IF granted_create THEN
            EXECUTE format('REVOKE CREATE ON SCHEMA %I FROM %I', item ->> 'schema', item ->> 'owner');
        END IF;
    END LOOP;
    RETURN n;
END
$fn$;

CREATE OR REPLACE FUNCTION shared.embedding_swap(p_swap_group text, p_allow_missing boolean DEFAULT false)
RETURNS integer
LANGUAGE sql AS $fn$
    SELECT shared._embedding_switch(p_swap_group, 'swap', p_allow_missing)
$fn$;

CREATE OR REPLACE FUNCTION shared.embedding_rollback(p_swap_group text, p_allow_missing boolean DEFAULT false)
RETURNS integer
LANGUAGE sql AS $fn$
    SELECT shared._embedding_switch(p_swap_group, 'rollback', p_allow_missing)
$fn$;

CREATE OR REPLACE FUNCTION shared.embedding_drop_shadow(p_schema text, p_table text, p_column text)
RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
    c shared.embedding_column%ROWTYPE;
BEGIN
    SELECT * INTO c FROM shared.embedding_column
     WHERE table_schema = p_schema AND table_name = p_table AND column_name = p_column FOR UPDATE;
    IF NOT FOUND OR c.shadow_column IS NULL THEN
        RAISE EXCEPTION 'embedding drop shadow: %.%.% has no shadow column', p_schema, p_table, p_column;
    END IF;
    PERFORM shared._embedding_shadow_trigger(format('%I.%I', p_schema, p_table)::regclass, p_column, false);
    EXECUTE format('ALTER TABLE %I.%I DROP COLUMN %I', p_schema, p_table, c.shadow_column);
    UPDATE shared.embedding_column
       SET shadow_column = NULL, shadow_space_key = NULL, updated_at = now(), updated_by = current_user
     WHERE table_schema = p_schema AND table_name = p_table AND column_name = p_column;
    RETURN c.shadow_column;
END
$fn$;

CREATE OR REPLACE FUNCTION shared.embedding_drop_previous(p_swap_group text)
RETURNS integer
LANGUAGE plpgsql AS $fn$
DECLARE
    c record;
    n integer := 0;
BEGIN
    FOR c IN SELECT * FROM shared.embedding_column WHERE swap_group = p_swap_group AND previous_column IS NOT NULL
              ORDER BY table_schema, table_name, column_name FOR UPDATE LOOP
        EXECUTE format('ALTER TABLE %I.%I DROP COLUMN %I', c.table_schema, c.table_name, c.previous_column);
        UPDATE shared.embedding_column
           SET previous_column = NULL, previous_space_key = NULL, updated_at = now(), updated_by = current_user
         WHERE table_schema = c.table_schema AND table_name = c.table_name AND column_name = c.column_name;
        n := n + 1;
    END LOOP;
    IF n = 0 THEN
        RAISE EXCEPTION 'embedding drop previous: swap group % keeps no previous column', p_swap_group;
    END IF;
    RETURN n;
END
$fn$;

REVOKE ALL ON FUNCTION shared.embedding_dependent_views(regclass, smallint[]) FROM PUBLIC, cis_app;
REVOKE ALL ON FUNCTION shared._embedding_shadow_reset() FROM PUBLIC, cis_app;
REVOKE ALL ON FUNCTION shared._embedding_shadow_trigger(regclass, text, boolean) FROM PUBLIC, cis_app;
REVOKE ALL ON FUNCTION shared._embedding_rename_indexes(regclass, text, text, text) FROM PUBLIC, cis_app;
REVOKE ALL ON FUNCTION shared.embedding_prepare_shadow(text, text, text, text, text) FROM PUBLIC, cis_app;
REVOKE ALL ON FUNCTION shared._embedding_switch(text, text, boolean) FROM PUBLIC, cis_app;
REVOKE ALL ON FUNCTION shared.embedding_swap(text, boolean) FROM PUBLIC, cis_app;
REVOKE ALL ON FUNCTION shared.embedding_rollback(text, boolean) FROM PUBLIC, cis_app;
REVOKE ALL ON FUNCTION shared.embedding_drop_shadow(text, text, text) FROM PUBLIC, cis_app;
REVOKE ALL ON FUNCTION shared.embedding_drop_previous(text) FROM PUBLIC, cis_app;

-- The registry is changed by migrations and the functions above (the table owner) only: the schema's default
-- privileges gave cis_app DML on the two 328 tables and EXECUTE on these functions.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON shared.embedding_space, shared.embedding_column FROM cis_app;

COMMENT ON FUNCTION shared.embedding_prepare_shadow(text, text, text, text, text) IS
    'AA-1026 (329): adds <column>__shadow vector(<dimension of the space>), records it and installs the trigger '
    '<column>__shadow_reset (a rewritten serving vector empties its shadow vector). Owner only (run-script).';
COMMENT ON FUNCTION shared._embedding_shadow_reset() IS
    'AA-1026 (329): trigger function of <column>__shadow_reset: sets the shadow column named by TG_ARGV[0] to NULL.';
COMMENT ON FUNCTION shared.embedding_swap(text, boolean) IS
    'AA-1026 (329): swaps every column of a swap group to its filled shadow (old vectors kept as <column>__prev), '
    'rebuilding the dependent views. Refuses while a row has a vector but no shadow vector, unless allow_missing.';
COMMENT ON FUNCTION shared.embedding_rollback(text, boolean) IS
    'AA-1026 (329): undoes embedding_swap while <column>__prev exists (the new vectors go back to the shadow). Rows '
    'written after the swap have no old vector: refused unless allow_missing (the column then stays nullable).';
COMMENT ON FUNCTION shared.embedding_drop_shadow(text, text, text) IS
    'AA-1026 (329): drops an unswapped shadow column (an abandoned or test re-embed).';
COMMENT ON FUNCTION shared.embedding_drop_previous(text) IS
    'AA-1026 (329): drops the kept old vectors of a swap group (no rollback after this; destructive-ops procedure).';

-- ── 2. coverage guard (only where pgvector exists) ──────────────────────────────────────────────────────────────

DO $$
DECLARE
    bad text;
BEGIN
    SELECT string_agg(swap_group, ', ') INTO bad
      FROM (SELECT swap_group FROM shared.embedding_column GROUP BY swap_group
             HAVING count(DISTINCT space_key) > 1) g;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 329: swap group(s) % mix spaces', bad;
    END IF;
    IF to_regtype('vector') IS NULL THEN
        RAISE NOTICE 'migration 329: no pgvector here, column coverage not checked';
        RETURN;
    END IF;
    SELECT string_agg(format('%I.%I.%I', n.nspname, cl.relname, a.attname), ', ') INTO bad
      FROM pg_attribute a
      JOIN pg_class cl ON cl.oid = a.attrelid AND cl.relkind IN ('r', 'p')
      JOIN pg_namespace n ON n.oid = cl.relnamespace
     WHERE a.atttypid = to_regtype('vector') AND a.attnum > 0 AND NOT a.attisdropped
       AND n.nspname IN ('acp_contract', 'acp_deliver', 'acp_shared', 'catalog', 'geo', 'gold_aa_internal',
                         'shared', 'silver_aa_internal')
       AND a.attname !~ '__(shadow|prev)$'
       AND NOT EXISTS (SELECT 1 FROM shared.embedding_column ec
                        WHERE ec.table_schema = n.nspname AND ec.table_name = cl.relname
                          AND ec.column_name = a.attname);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 329: vector column(s) % have no shared.embedding_column row', bad;
    END IF;
    SELECT string_agg(format('%s.%s.%s is %s, space %s', ec.table_schema, ec.table_name, ec.column_name,
                             coalesce(format_type(a.atttypid, a.atttypmod), 'missing'), ec.space_key), '; ') INTO bad
      FROM shared.embedding_column ec
      JOIN shared.embedding_space s ON s.space_key = ec.space_key
      LEFT JOIN pg_attribute a ON a.attrelid = to_regclass(format('%I.%I', ec.table_schema, ec.table_name))
                              AND a.attname = ec.column_name AND NOT a.attisdropped
     WHERE to_regclass(format('%I.%I', ec.table_schema, ec.table_name)) IS NOT NULL
       AND (a.attname IS NULL OR format_type(a.atttypid, a.atttypmod) <> format('vector(%s)', s.dimension));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 329: registered column(s) do not match their space: %', bad;
    END IF;
END $$;

-- ── 3. the fallback model: Titan Text Embeddings V2 on acc2 in us-west-2, connection off ────────────────────────

INSERT INTO shared.llm_provider_connection
    (connection_key, kind, auth_mode, label, region, data_scope, enabled, monthly_budget_usd, failure_domain,
     served_roles, notes, updated_by)
VALUES
    ('acc2-usw2', 'bedrock', 'task_role', 'Bedrock, main account, us-west-2 (task role)', 'us-west-2', 'aws_only',
     false, 5.00, 'bedrock:acc2:aws_only', ARRAY['embed']::text[],
     'Fallback embedding model (Titan Text Embeddings V2, another vendor; not offered in us-west-1). Same account '
     'as acc2. Off until a re-embed needs it (runbook embedding-re-embed).', 'migration-329-aa1026')
ON CONFLICT (connection_key) DO NOTHING;

INSERT INTO shared.llm_model_catalog
    (model_key, label, vendor, family, provider, api_style, bedrock_profile_ids, wire_model, callable_via,
     supports_temperature, max_output_tokens, price_in_per_mtok, price_out_per_mtok, price_source, enabled,
     blocked_reason, notes, capabilities, updated_by)
VALUES
    ('titan-embed-text-v2', 'Amazon Titan Text Embeddings V2', 'amazon', 'amazon', 'bedrock', 'embed',
     '{"acc2-usw2": "amazon.titan-embed-text-v2:0"}'::jsonb, NULL, ARRAY['embed'], false, NULL,
     0.0200, 0.0000,
     'AWS Price List API AmazonBedrock, USW2-TitanEmbeddingV2-Text-input-tokens 0.00002 USD / 1K tokens, 01/11/2026',
     true, NULL,
     'Fallback embedding model, space titan-embed-text-v2/1024/v1 (AA-1026 migration 329). One text per request, '
     'dimensions 1024, normalize true. No stage routes to it; a column moves to it only by a re-embed + swap.',
     '{}'::jsonb, 'migration-329-aa1026')
ON CONFLICT (model_key) DO NOTHING;

INSERT INTO shared.llm_model_deployment
    (model_key, connection_key, wire_id, priority, enabled, origin, api_style, notes, updated_by)
VALUES
    ('titan-embed-text-v2', 'acc2-usw2', 'amazon.titan-embed-text-v2:0', 20, true, 'bedrock_profile', 'embed',
     'Fallback embedding model on acc2 us-west-2; unusable while connection acc2-usw2 is off (runbook '
     'embedding-re-embed switches it on).',
     'migration-329-aa1026')
ON CONFLICT (model_key, connection_key) DO NOTHING;

DO $$
DECLARE
    routed text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.llm_model_deployment d
                     JOIN shared.llm_model_catalog m ON m.model_key = d.model_key
                     JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key
                    WHERE d.model_key = 'titan-embed-text-v2' AND d.connection_key = 'acc2-usw2'
                      AND m.api_style = 'embed' AND c.kind = 'bedrock' AND c.region = 'us-west-2'
                      AND d.wire_id = m.bedrock_profile_ids ->> 'acc2-usw2') THEN
        RAISE EXCEPTION 'migration 329: titan-embed-text-v2 on acc2-usw2 is missing or differs (changed by hand?)';
    END IF;
    SELECT string_agg(stage, ', ' ORDER BY stage) INTO routed
      FROM shared.llm_role_config
     WHERE model_id = 'titan-embed-text-v2' OR 'titan-embed-text-v2' = ANY (fallback_model_ids)
        OR shadow_model_id = 'titan-embed-text-v2';
    IF routed IS NOT NULL THEN
        RAISE EXCEPTION 'migration 329: stages route to titan-embed-text-v2: % (a route change is separate)', routed;
    END IF;
    SELECT string_agg(alias_key, ', ') INTO routed FROM shared.llm_model_alias WHERE model_key = 'titan-embed-text-v2';
    IF routed IS NOT NULL THEN
        RAISE EXCEPTION 'migration 329: aliases point at titan-embed-text-v2: %', routed;
    END IF;
END $$;

-- ── 4. TripPlanner's view of its search column's space (X1 S22 catalog recipe) ──────────────────────────────────

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

CREATE OR REPLACE VIEW catalog.v_embedding_space_v1 WITH (security_barrier = true) AS
SELECT ec.table_schema,
       ec.table_name,
       ec.column_name,
       ec.space_key,
       s.model_family,
       s.model_id,
       s.model_keys,
       s.dimension,
       s.document_input_type,
       s.query_input_type,
       s.status            AS space_status,
       ec.shadow_space_key,
       ec.updated_at
  FROM shared.embedding_column ec
  JOIN shared.embedding_space s ON s.space_key = ec.space_key
 WHERE ec.table_schema = 'geo' AND ec.table_name = 'tour_place';

COMMENT ON VIEW catalog.v_embedding_space_v1 IS
    'AA-1026 (329): the embedding space of geo.tour_place.embedding (read by TripPlanner through '
    'catalog.v_component_embedding): its search embeds queries in this space or falls back to keyword search. '
    'TripPlanner only. Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_embedding_space_v1 TO tripplanner;

DO $$
BEGIN
    IF (SELECT count(*) FROM catalog.v_embedding_space_v1) <> 1 THEN      -- as catalog_owner, the view's owner
        RAISE EXCEPTION 'migration 329: catalog.v_embedding_space_v1 must show exactly the geo.tour_place row';
    END IF;
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

DO $$
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'catalog.v_embedding_space_v1'::regclass)
       <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 329: catalog.v_embedding_space_v1 is not catalog_owner''s';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'tripplanner')
       AND NOT has_table_privilege('tripplanner', 'catalog.v_embedding_space_v1', 'SELECT') THEN
        RAISE EXCEPTION 'migration 329: tripplanner cannot read catalog.v_embedding_space_v1';
    END IF;
END $$;

-- ── 5. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('329', now(), 'AA-1026 re-embed tools (shadow, swap, rollback, drop), fallback embedding model '
                      'titan-embed-text-v2 on acc2-usw2 (connection off), catalog.v_embedding_space_v1 for TripPlanner')
ON CONFLICT (version) DO NOTHING;

COMMIT;
