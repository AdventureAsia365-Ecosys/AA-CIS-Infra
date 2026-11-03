-- Migration 350: AA-1027 (AI gateway v2, root plan S263 slice E4, gap TP-5) — append the model's
-- supports_temperature and the stage x model request parameters (shared.stage_model_params, migration 320) to
-- TripPlanner's gateway contract view catalog.v_llm_gateway_config_v1.
--
-- Why. Registry v2 (CIS 320, AA-1017; root ADR 0009 §4) lets an admin set, per (stage, catalog model), max_tokens,
-- min_output_tokens, temperature, effort and reasoning_mode; the CIS gateway applies them
-- (shared/llm_client/stage_params.py). TripPlanner reads its routes only through the contract view (323, 341) and
-- cannot see that table, so a row for tp_compose would change nothing there. Slice E4 makes the TripPlanner gateway
-- apply the row with the CIS precedence (call site, then the row, then the protocol default); for that it needs the
-- row and the catalog's supports_temperature (a sampling parameter is refused by some models), nothing else.
--
-- What:
--   1. Column-level SELECT for catalog_owner (the NOLOGIN owner of every catalog.* view):
--        shared.llm_model_catalog (supports_temperature);
--        shared.stage_model_params (stage, model_key, max_tokens, min_output_tokens, temperature, effort,
--          reasoning_mode) — not notes, created_at, updated_at, updated_by.
--   2. CREATE OR REPLACE catalog.v_llm_gateway_config_v1: the 25 columns of 341 unchanged, in order, then two appended
--      columns (contract v1: columns are only appended):
--        supports_temperature boolean  llm_model_catalog.supports_temperature (NULL when the key is not in the
--                                      catalog);
--        stage_params         jsonb    the stage_model_params row of (the route's stage, the chain model) as one
--                                      object {max_tokens, min_output_tokens, temperature, effort, reasoning_mode}
--                                      (a key is null when the row does not set it); NULL when there is no row.
--      The 341 body (deployments, deployment_routing and the connection-circuit CTEs) is repeated byte for byte; the
--      only additions are the two columns and one LEFT JOIN on stage_model_params' primary key (stage, model_key).
--   3. Register 350.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no expand header): step 1 changes the ACL of two existing tables and
-- step 2 replaces an existing view. MIG-4: this migration-only PR (with 351), the byte copy in AA-CIS-Infra
-- db/migrations/cis/, Infra Migration Apply with every job table idle (root ADR 0017a). The TripPlanner code that
-- reads the columns (AA-TripPlanner-Web llm_gateway, AA-1027 E4) also works before this file is applied: SQLSTATE
-- 42703 on the appended columns narrows its read to the 341 columns and no parameters apply. Nothing in CIS reads the
-- view. DM-7.1: no new table.
--
-- Guards (RAISE rolls the whole file back): before — 341 registered, shared.stage_model_params (320) and
-- llm_model_catalog.supports_temperature present, schema catalog owned by cis_owner. After, as catalog_owner — the
-- view answers. After, as cis_owner — the view's exact columns (341's then the two appended), owner catalog_owner,
-- security_barrier, tripplanner can read it, booking, aa_app_user, cis_app and crm_app cannot, tripplanner cannot read
-- shared.stage_model_params, catalog_owner reads no other column of stage_model_params, catalog_owner has no CREATE on
-- schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 323 / 329 / 341): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL
-- ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as cis_owner
-- (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL. The conftest replay skips this file (it
-- needs 323 and 341, skipped too); tests/integration/test_aa1027_migration_350.py applies 323, 341 then 350 the DB
-- Migrate way and undoes all three. After 350, 341 can no longer be re-run on that database (CREATE OR REPLACE VIEW
-- cannot drop the two appended columns); DB Migrate never re-runs a registered version.
--
-- Number. 346 is the highest on main (03/11); 347, 348 and 349 are held by other lanes of session S265, and 351 (the
-- TripPlanner REVOKE, AA-1027 E5) ships in this same migration-only PR. The CI migration preflight refuses 350 until
-- 347 to 349 are on main. If they do not land first, renumber 350 / 351 to the owner main max + 1 / + 2 (git grep
-- '350_' and '350' / '351_' and '351' in these files, their tests, conftest and AA-TripPlanner-Web comments); never
-- the migration:out-of-order label (a labelled file is never auto-applied).
--
-- Locks. Two column GRANTs (no lock that blocks readers or writers of the tables) and one CREATE OR REPLACE VIEW
-- (AccessExclusiveLock on the view only, held for the transaction). lock_timeout 5s, statement_timeout 1min.
-- Idempotent (CREATE OR REPLACE with the same column list, re-runnable grants, ON CONFLICT DO NOTHING), one
-- transaction, self-registering. After apply the DB Schema Dump workflow regenerates
-- docs/architecture/db-schema-reference.md.
--
-- Rollback (a NEW forward migration under the same recipe): DROP VIEW catalog.v_llm_gateway_config_v1, re-create it
-- with 341's definition and GRANT SELECT to tripplanner (TripPlanner narrows to the 341 columns on 42703); REVOKE
-- SELECT (the columns above) ON the two tables FROM catalog_owner.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '341')
       OR to_regclass('catalog.v_llm_gateway_config_v1') IS NULL THEN
        RAISE EXCEPTION 'migration 350: apply 341 (catalog.v_llm_gateway_config_v1 routing columns) first';
    END IF;
    IF to_regclass('shared.stage_model_params') IS NULL THEN
        RAISE EXCEPTION 'migration 350: shared.stage_model_params missing (320)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'shared' AND table_name = 'llm_model_catalog'
                      AND column_name = 'supports_temperature') THEN
        RAISE EXCEPTION 'migration 350: shared.llm_model_catalog.supports_temperature missing';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 350: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read for the appended columns (columns only) ───────────────────────────────────────
GRANT SELECT (supports_temperature) ON shared.llm_model_catalog TO catalog_owner;
GRANT SELECT (stage, model_key, max_tokens, min_output_tokens, temperature, effort, reasoning_mode)
    ON shared.stage_model_params TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 2. The view: 341's columns unchanged, then supports_temperature and stage_params ─────────────────────────────
CREATE OR REPLACE VIEW catalog.v_llm_gateway_config_v1 WITH (security_barrier = true) AS
WITH conn_ok AS (
    SELECT h.connection_key, max(h.last_ok_at) AS last_ok_at
      FROM shared.llm_provider_health h
     GROUP BY h.connection_key
), conn_signal AS (
    -- breaker._tripping: an account-wide class, a circuit on record, failed after the connection's last answer.
    SELECT h.connection_key, h.model_key, h.last_error_class, h.circuit_open_until
      FROM shared.llm_provider_health h
      JOIN conn_ok o ON o.connection_key = h.connection_key
     WHERE h.last_error_class IN ('credential', 'quota_exhausted', 'access_denied')
       AND h.circuit_open_until IS NOT NULL
       AND h.last_error_at IS NOT NULL
       AND (o.last_ok_at IS NULL OR h.last_error_at > o.last_ok_at)
), conn_denied AS (
    -- access_denied trips the connection only from 2 distinct models (breaker.CONNECTION_DENIED_MODELS).
    SELECT s.connection_key
      FROM conn_signal s
     WHERE s.last_error_class = 'access_denied'
     GROUP BY s.connection_key
    HAVING count(DISTINCT s.model_key) >= 2
), conn_circuit AS (
    SELECT s.connection_key,
           CASE WHEN bool_or(s.last_error_class = 'credential') THEN 'credential'
                WHEN bool_or(s.last_error_class = 'quota_exhausted') THEN 'quota_exhausted'
                ELSE 'access_denied' END             AS circuit_class,
           max(s.circuit_open_until)                 AS circuit_open_until
      FROM conn_signal s
     WHERE s.last_error_class <> 'access_denied'
        OR s.connection_key IN (SELECT d.connection_key FROM conn_denied d)
     GROUP BY s.connection_key
)
SELECT r.stage,
       r.role,
       r.is_active,
       r.account_route,
       r.allowed_scopes,
       r.shadow_model_id,
       r.shadow_sample_pct,
       (k.ord - 1)::integer                      AS position,
       k.model_key,
       (m.model_key IS NOT NULL)                 AS in_catalog,
       m.vendor,
       m.provider,
       m.api_style,
       m.bedrock_profile_ids,
       m.wire_model,
       m.max_output_tokens,
       m.enabled                                 AS model_enabled,
       m.price_in_per_mtok,
       m.price_out_per_mtok,
       m.price_cache_read_per_mtok,
       m.price_cache_write_per_mtok,
       COALESCE(d.deployments, '[]'::jsonb)      AS deployments,
       r.updated_at                              AS route_updated_at,
       r.route_deadline_s,
       COALESCE(g.routing, '[]'::jsonb)          AS deployment_routing,
       m.supports_temperature,
       CASE WHEN p.stage IS NULL THEN NULL
            ELSE jsonb_build_object(
                     'max_tokens', p.max_tokens,
                     'min_output_tokens', p.min_output_tokens,
                     'temperature', p.temperature,
                     'effort', p.effort,
                     'reasoning_mode', p.reasoning_mode) END AS stage_params
  FROM shared.llm_role_config r
  CROSS JOIN LATERAL unnest(ARRAY[r.model_id] || r.fallback_model_ids) WITH ORDINALITY AS k(model_key, ord)
  LEFT JOIN shared.llm_model_catalog m ON m.model_key = k.model_key
  LEFT JOIN shared.stage_model_params p ON p.stage = r.stage AND p.model_key = k.model_key
  LEFT JOIN LATERAL (
      SELECT jsonb_agg(jsonb_build_object(
                 'connection_key', x.connection_key,
                 'wire_id', x.wire_id,
                 'priority', x.priority,
                 'enabled', x.enabled,
                 'price_in_override', x.price_in_override,
                 'price_out_override', x.price_out_override,
                 'price_cache_read_override', x.price_cache_read_override,
                 'price_cache_write_override', x.price_cache_write_override,
                 'price_cache_write_1h_override', x.price_cache_write_1h_override)
             ORDER BY x.priority, x.connection_key) AS deployments
        FROM shared.llm_model_deployment x
       WHERE x.model_key = k.model_key
  ) d ON true
  LEFT JOIN LATERAL (
      SELECT jsonb_agg(jsonb_build_object(
                 'connection_key', x.connection_key,
                 'in_registry', (c.connection_key IS NOT NULL),
                 'kind', c.kind,
                 'auth_mode', c.auth_mode,
                 'account_id_env', c.account_id_env,
                 'region', c.region,
                 'data_scope', c.data_scope,
                 'served_roles', to_jsonb(c.served_roles),
                 'connection_enabled', c.enabled,
                 'access_state', c.access_state,
                 'circuit_open_until', h.circuit_open_until,
                 'probe_until', h.probe_until,
                 'last_error_class', h.last_error_class,
                 'consecutive_failures', h.consecutive_failures,
                 'connection_circuit_class', cc.circuit_class,
                 'connection_circuit_open_until', cc.circuit_open_until)
             ORDER BY x.priority, x.connection_key) AS routing
        FROM shared.llm_model_deployment x
        LEFT JOIN shared.llm_provider_connection c ON c.connection_key = x.connection_key
        LEFT JOIN shared.llm_provider_health h
               ON h.connection_key = x.connection_key AND h.model_key = x.model_key
        LEFT JOIN conn_circuit cc ON cc.connection_key = x.connection_key
       WHERE x.model_key = k.model_key
  ) g ON true
 WHERE r.stage LIKE 'tp\_%';

COMMENT ON VIEW catalog.v_llm_gateway_config_v1 IS
    'AA-642 S8 (323, root ADR 0009 d13): the gateway route of each TripPlanner stage (tp_*), one row per model of '
    'its chain (position 0 = primary, then the fallbacks), with the catalog row and the deployments (JSON, by '
    'priority). AA-1027 E3 (341): + route_deadline_s and deployment_routing (per deployment: non-secret connection '
    'facts, the deployment circuit and the connection circuit). AA-1027 E4 (350): + supports_temperature and '
    'stage_params (the shared.stage_model_params row of the stage and model, NULL when none). TripPlanner only. '
    'Contract v1: columns are only appended; a change of meaning is a _v2 view.';

-- ── Closing check as catalog_owner: the view answers ─────────────────────────────────────────────────────────────
DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM catalog.v_llm_gateway_config_v1 WHERE stage_params IS NOT NULL;
    RAISE NOTICE 'migration 350: as catalog_owner, % gateway config row(s) with stage x model params', n;
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner: columns, owner, barrier, exact consumer grant, column grants ─────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_llm_gateway_config_v1';
    r text;
    cols text;
    extra text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 350: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 350: % is not security_barrier', v;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'tripplanner')
       AND NOT pg_catalog.has_table_privilege('tripplanner', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 350: tripplanner cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 350: % can read % (tripplanner only)', r, v;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM
       'stage,role,is_active,account_route,allowed_scopes,shadow_model_id,shadow_sample_pct,position,'
       'model_key,in_catalog,vendor,provider,api_style,bedrock_profile_ids,wire_model,max_output_tokens,'
       'model_enabled,price_in_per_mtok,price_out_per_mtok,price_cache_read_per_mtok,'
       'price_cache_write_per_mtok,deployments,route_updated_at,route_deadline_s,deployment_routing,'
       'supports_temperature,stage_params' THEN
        RAISE EXCEPTION 'migration 350: % columns are %', v, cols;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'tripplanner')
       AND pg_catalog.has_any_column_privilege('tripplanner', 'shared.stage_model_params', 'SELECT') THEN
        RAISE EXCEPTION 'migration 350: tripplanner can read shared.stage_model_params directly';
    END IF;
    SELECT string_agg(a.attname, ', ' ORDER BY a.attname) INTO extra
      FROM pg_attribute a
     WHERE a.attrelid = 'shared.stage_model_params'::regclass
       AND a.attnum > 0 AND NOT a.attisdropped
       AND a.attname IN ('notes', 'created_at', 'updated_at', 'updated_by')
       AND pg_catalog.has_column_privilege('catalog_owner', a.attrelid, a.attnum, 'SELECT');
    IF extra IS NOT NULL THEN
        RAISE EXCEPTION 'migration 350: catalog_owner can read shared.stage_model_params.%', extra;
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 350: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('350', now(), 'AA-1027 E4: catalog.v_llm_gateway_config_v1 + supports_temperature, stage_params (the '
                      'stage x model request parameters) for TripPlanner; column SELECT for catalog_owner on '
                      'llm_model_catalog.supports_temperature / stage_model_params')
ON CONFLICT (version) DO NOTHING;

COMMIT;
