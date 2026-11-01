-- Migration 329: AA-1026 D5 + T-15 (AI gateway v2, S263) — the shadow reset trigger function of a re-embed, the ready
-- fallback embedding model of another vendor (Amazon Titan Text Embeddings V2 on acc2, us-west-2, disabled), the
-- coverage guard of the embedding space registry (328) and the TripPlanner view of its search column's space.
--
-- Why. 328 says which space every vector column is in. Moving a column to another space (another model, another
-- dimension) must never mix two spaces in one column and must be reversible: new vectors go to a shadow column,
-- the whole swap group swaps in one transaction once the shadow is full, the old column is kept for a rollback.
-- The owner steps (prepare the shadow, swap, rollback, drop the shadow; the swap renames columns and rebuilds the
-- views that read them, which a view binds by number, not by name) are DDL on live tables run once per move: they live
-- in the AA-CIS-Infra run-script db/scripts/aa1026_embedding_shadow.py (DB Migrate mode=run-script, as cis_owner, DRY
-- RUN by default), not as functions here. A migration may not switch roles in dynamic SQL (the X1 role lint), and
-- the view rebuild would need it; the steps are also easier to review and rehearse as one script with a dry run.
-- The fallback model: the only embedding model on acc2 in us-west-1 is Cohere Embed v4 (aws bedrock
-- list-foundation-models, 01/11/2026). Titan Text Embeddings V2 (Amazon, another vendor) is on demand on acc2 in
-- us-west-2 (allowed by the organization region SCP; the ECS task role allows bedrock:InvokeModel on any resource,
-- migration 238's note). It answers at most 1024 dimensions, so it is its own space (titan-embed-text-v2/1024/v1,
-- standby in 328) and a column moves to it only by a re-embed + swap. Price: AWS Price List API, offer AmazonBedrock,
-- usage type USW2-TitanEmbeddingV2-Text-input-tokens = 0.00002 USD per 1K tokens (0.02 per 1M), read 01/11/2026.
--
-- What.
--   1. shared._embedding_shadow_reset() (SECURITY INVOKER, owner cis_owner, EXECUTE revoked from PUBLIC and cis_app,
--      which the schema's default privileges grant): the trigger function of <column>__shadow_reset. The run-script
--      installs that trigger at prepare: a writer that rewrites a row's serving vector (UPDATE, or INSERT … ON
--      CONFLICT DO UPDATE, e.g. a T9 piece rewritten) empties that row's shadow vector, so the fill re-reads it like a
--      new row and the swap never promotes a vector of text that is gone. A trigger needs a function object, so this
--      one function is a migration; it has no dynamic SQL. The same default privileges gave cis_app DML on the two
--      328 tables: revoked (SELECT stays). 328's source comments and three of its COMMENT ON texts still name
--      owner functions "in 329" (328 was copied to AA-CIS-Infra before the owner steps moved, so it stays as it is):
--      this file restates those three database comments; the 328 file text is history.
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
-- Behaviour. No stage changes model; no vector, column or index changes (only the run-script changes them). The
-- route snapshot (S262 plan Q0) gains exactly one 'cn|', one 'ct|' and one 'dp|' line. The daily probe skips the
-- disabled connection; the re-embed probe (job embedding_reembed, mode probe) calls it once the runbook switches it on.
--
-- RISKY (a catalog view grant, routing rows; S241 D-13): an independent review of this file is required before merge.
-- Class: contract (root ADR 0017 d3: DO blocks, REVOKE, INSERT into routing tables, the catalog.* recipe), so no
-- "-- migrate: expand" header. Order (MIG-4): after 328; (1) this PR merges to AA-CIS-App main; (2) the byte copy in
-- AA-CIS-Infra db/migrations/cis/ merges; (3) a manual DB Migrate apply; (4) the bot/db-schema-reference PR merges.
-- The code works before and after (registry mirror).
--
-- Rollback (a NEW forward migration): DROP VIEW catalog.v_embedding_space_v1 (recipe as here); DELETE the deployment,
-- catalog and connection rows of titan-embed-text-v2 / acc2-usw2 (delete their llm_provider_health rows first if a
-- probe ran); DROP FUNCTION shared._embedding_shadow_reset() once no <column>__shadow_reset trigger uses it (the
-- run-script's drop_shadow / swap remove them).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).
--
-- X1. One BEGIN … COMMIT block. DB Migrate runs cis/ files as cis_owner; the catalog view uses the X1 S22 recipe
-- (as 323): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE catalog_owner; the view; back to
-- cis_owner; REVOKE CREATE. No dynamic SQL anywhere in the file.

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

-- ── 1. the shadow reset trigger function (the only re-embed object a migration creates) ─────────────────────────────

-- The shadow reset: BEFORE UPDATE OF <column>, when the serving vector changes and the statement did not set the
-- shadow itself, the row's shadow vector becomes NULL (TG_ARGV[0] = the shadow column; jsonb_populate_record sets one
-- field of NEW by name and copies the others as they are). The Infra run-script creates and drops the triggers
-- (<column>__shadow_reset, with the WHEN clause) as the table owner. It runs as the writer (cis_app): a trigger
-- function's EXECUTE privilege is checked when the trigger is created (the table owner), not when it fires.
CREATE OR REPLACE FUNCTION shared._embedding_shadow_reset()
RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
    NEW := jsonb_populate_record(NEW, jsonb_build_object(TG_ARGV[0], NULL));
    RETURN NEW;
END
$fn$;

REVOKE ALL ON FUNCTION shared._embedding_shadow_reset() FROM PUBLIC, cis_app;

COMMENT ON FUNCTION shared._embedding_shadow_reset() IS
    'AA-1026 (329): trigger function of <column>__shadow_reset (created by AA-CIS-Infra db/scripts/'
    'aa1026_embedding_shadow.py at prepare): sets the shadow column named by TG_ARGV[0] to NULL.';

-- The registry is changed by migrations and the owner run-script only: the schema's default privileges gave cis_app
-- DML on the two 328 tables and EXECUTE on the function above.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON shared.embedding_space, shared.embedding_column FROM cis_app;

-- 328 (already copied to AA-CIS-Infra, so immutable) was written when the owner steps were planned as functions of
-- this migration; its comments in the database name functions that never existed. Restate them here.
COMMENT ON TABLE shared.embedding_column IS
    'AA-1026 D5 (CIS 328): the space of every vector column. Writers and searches read it (one space per column, one '
    'space per query); the re-embed job fills shadow_column; the owner run-script (AA-CIS-Infra db/scripts/'
    'aa1026_embedding_shadow.py, DB Migrate run-script) swaps a whole swap_group.';
COMMENT ON COLUMN shared.embedding_column.shadow_column IS
    'AA-1026 (328, 329): <column>__shadow while a re-embed into shadow_space_key runs (set by the owner run-script '
    'at prepare).';
COMMENT ON COLUMN shared.embedding_column.previous_column IS
    'AA-1026 (328, 329): <column>__prev after a swap, the old vectors kept for a rollback until the owner run-script '
    'drops them.';

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
VALUES ('329', now(), 'AA-1026 shadow reset trigger function, fallback embedding model titan-embed-text-v2 on '
                      'acc2-usw2 (connection off), catalog.v_embedding_space_v1 for TripPlanner')
ON CONFLICT (version) DO NOTHING;

COMMIT;
