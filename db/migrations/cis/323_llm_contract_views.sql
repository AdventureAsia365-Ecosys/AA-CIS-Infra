-- Migration 323: AA-642 S8 (AI gateway v2, root ADR 0009 decision 13) — the versioned contract views TripPlanner reads
-- its gateway configuration and its own spend through.
--
-- Why. TripPlanner (AA-TripPlanner-Web backend/shared/llm_gateway.py) reads shared.llm_role_config and
-- shared.llm_model_catalog directly (the grandfathered SELECT of CIS 173, the gateway-config exception of root
-- ADR 0008 decision 5) and counts its spend in tripplanner.llm_spend_daily. ADR 0009 decision 13 moves it onto the
-- shared core (shared/aa_llm, vendored) and onto two versioned catalog views, like every other cross-app read
-- (ADR 0008 decision 5): routes, models, prices and deployments of the TripPlanner stages only, and today's spend of
-- app 'tripplanner' only. Nothing else of the CIS gateway (other stages, connections, accounts, other apps' cost)
-- becomes readable. The grandfathered SELECTs stay this session (no REVOKE here): they are revoked by a later
-- migration once TripPlanner has read these views for a cycle (design README, open item D10).
--
-- What:
--   1. Column-level SELECT for catalog_owner (the NOLOGIN owner every catalog.* view runs as) on exactly the columns
--      the two views read: shared.llm_role_config (route), shared.llm_model_catalog (model, prices),
--      shared.llm_model_deployment (deployments and their price overrides), shared.llm_call_log (created_at, stage,
--      cost_usd, status, app, quality_signal). Not llm_provider_connection: accounts, roles and secret names stay
--      CIS's.
--   2. catalog.v_llm_gateway_config_v1 (security_barrier): one row per TripPlanner stage (stage LIKE 'tp\_%') and per
--      model of its chain — position 0 = llm_role_config.model_id, then fallback_model_ids in order — with the route
--      (role, is_active, account_route, allowed_scopes, shadow_model_id, shadow_sample_pct, route_updated_at), the
--      model's catalog row (in_catalog false and NULL columns when the key is not in the catalog) and its deployments
--      as a JSON array ordered by priority (connection_key, wire_id, priority, enabled and the five price overrides).
--      No alias expansion (llm_model_alias): TripPlanner calls catalog keys only.
--   3. catalog.v_llm_app_spend_today_v1 (security_barrier): today's (UTC) shared.llm_call_log rows of app 'tripplanner'
--      (coalesce(app, quality_signal->>'app'): app is the ledger v2 column of 319, NULL on older rows) per stage —
--      day, stage, calls, unpriced_calls (cost_usd NULL), failed_calls (status refused / error, or the pre-v2
--      quality_signal "failed" flag), cost_usd (sum, 0 when none) and last_call_at. Reads today's rows only, through
--      the (created_at, id) index.
--   4. SELECT on both views to tripplanner only (X2 rule g allowlist "catalog.*:tripplanner").
--   5. Register 323.
--
-- Class: CONTRACT (ADR 0017 decision 3; no expand header). Step 1 changes the ACL of four existing tables,
-- which an expand file may not. So MIG-4 applies: this migration-only PR, the Infra copy (bot/migration-copy/cis-323,
-- not auto-merged for a contract file), a manual DB Migrate apply, then the TripPlanner PR that reads the views.
-- Nothing in CIS reads them.
--
-- Guards (RAISE rolls the whole file back): before — 319 registered (llm_call_log.app / status exist), schema catalog
-- owned by cis_owner. After, as catalog_owner (the role the views run as) — both views answer. After, as cis_owner —
-- the views' exact columns, owner catalog_owner, security_barrier, tripplanner can read both, booking, aa_app_user
-- and cis_app cannot, catalog_owner has no CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 285 / 298): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE
-- catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as cis_owner (login
-- db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL. The conftest replay skips this file (the recipe
-- needs 245); tests/integration/test_aa642_migration_323.py applies it the DB Migrate way and undoes it.
--
-- Number. 323 follows the registry v2 files 320–322 (lane A3, S262); re-check the CIS head before merging.
--
-- Locks. Two new views and four column GRANTs (GRANT updates the catalog row of the table and takes no lock that blocks
-- readers or writers of the table). lock_timeout 5s, statement_timeout 1min. Idempotent (CREATE OR REPLACE,
-- re-runnable grants, ON CONFLICT DO NOTHING), one transaction, self-registering. Applied on Dev from the
-- byte-identical copy in AA-CIS-Infra db/migrations/cis/. After apply the DB Schema Dump workflow regenerates
-- docs/architecture/db-schema-reference.md.
--
-- Rollback: under the same recipe DROP VIEW catalog.v_llm_app_spend_today_v1, catalog.v_llm_gateway_config_v1 (deploy
-- TripPlanner without the view reads first, or it falls back to the shared.* tables while the grandfathered SELECTs
-- exist); REVOKE SELECT (the columns above) ON the four tables FROM catalog_owner; DELETE FROM shared.schema_versions
-- WHERE version = '323'.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '319') THEN
        RAISE EXCEPTION 'migration 323: apply 319 (ledger v2) first';
    END IF;
    IF (SELECT count(*) FROM pg_attribute
         WHERE attrelid = 'shared.llm_call_log'::regclass AND attname IN ('app', 'status')
           AND NOT attisdropped) <> 2 THEN
        RAISE EXCEPTION 'migration 323: shared.llm_call_log has no app / status column (319)';
    END IF;
    IF to_regclass('shared.llm_model_deployment') IS NULL THEN
        RAISE EXCEPTION 'migration 323: shared.llm_model_deployment missing (304)';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 323: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read for the two views (columns only) ──────────────────────────────────────────────
GRANT SELECT (stage, role, model_id, fallback_model_ids, account_route, is_active, updated_at, shadow_model_id,
              shadow_sample_pct, allowed_scopes)
    ON shared.llm_role_config TO catalog_owner;
GRANT SELECT (model_key, vendor, provider, api_style, bedrock_profile_ids, wire_model, max_output_tokens, enabled,
              price_in_per_mtok, price_out_per_mtok, price_cache_read_per_mtok, price_cache_write_per_mtok)
    ON shared.llm_model_catalog TO catalog_owner;
GRANT SELECT (model_key, connection_key, wire_id, priority, enabled, price_in_override, price_out_override,
              price_cache_read_override, price_cache_write_override, price_cache_write_1h_override)
    ON shared.llm_model_deployment TO catalog_owner;
GRANT SELECT (created_at, stage, cost_usd, status, app, quality_signal)
    ON shared.llm_call_log TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 2. Routes, models, prices and deployments of the TripPlanner stages ─────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_llm_gateway_config_v1 WITH (security_barrier = true) AS
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
       r.updated_at                              AS route_updated_at
  FROM shared.llm_role_config r
  CROSS JOIN LATERAL unnest(ARRAY[r.model_id] || r.fallback_model_ids) WITH ORDINALITY AS k(model_key, ord)
  LEFT JOIN shared.llm_model_catalog m ON m.model_key = k.model_key
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
 WHERE r.stage LIKE 'tp\_%';

COMMENT ON VIEW catalog.v_llm_gateway_config_v1 IS
    'AA-642 S8 (323, root ADR 0009 d13): the gateway route of each TripPlanner stage (tp_*), one row per model of '
    'its chain (position 0 = primary, then the fallbacks), with the catalog row and the deployments (JSON, by '
    'priority). TripPlanner only. Contract v1: columns are only appended; a change of meaning is a _v2 view.';

-- ── 3. Today's (UTC) TripPlanner spend per stage, from the shared ledger ─────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_llm_app_spend_today_v1 WITH (security_barrier = true) AS
SELECT (now() AT TIME ZONE 'UTC')::date                                         AS day,
       l.stage,
       count(*)::bigint                                                         AS calls,
       (count(*) FILTER (WHERE l.cost_usd IS NULL))::bigint                     AS unpriced_calls,
       (count(*) FILTER (WHERE l.status IN ('refused', 'error')
                            OR l.quality_signal ->> 'failed' = 'true'))::bigint AS failed_calls,
       COALESCE(sum(l.cost_usd), 0)::numeric(14,6)                              AS cost_usd,
       max(l.created_at)                                                        AS last_call_at
  FROM shared.llm_call_log l
 WHERE l.created_at >= date_trunc('day', now(), 'UTC')
   AND COALESCE(l.app, l.quality_signal ->> 'app') = 'tripplanner'
 GROUP BY l.stage;

COMMENT ON VIEW catalog.v_llm_app_spend_today_v1 IS
    'AA-642 S8 (323, root ADR 0009 d13): today''s (UTC) shared.llm_call_log spend of app tripplanner per stage '
    '(calls, unpriced and failed calls, cost_usd, last call). TripPlanner only (its fail-closed daily caps). '
    'Contract v1: columns are only appended.';

-- ── 4. The one consumer (granted by the views' owner) ───────────────────────────────────────────────────────────
GRANT SELECT ON catalog.v_llm_gateway_config_v1 TO tripplanner;
GRANT SELECT ON catalog.v_llm_app_spend_today_v1 TO tripplanner;

-- ── Closing check as catalog_owner: both views answer ────────────────────────────────────────────────────────────
DO $$
DECLARE
    n bigint;
    m bigint;
BEGIN
    SELECT count(*) INTO n FROM catalog.v_llm_gateway_config_v1;
    SELECT count(*) INTO m FROM catalog.v_llm_app_spend_today_v1;
    RAISE NOTICE 'migration 323: as catalog_owner, % gateway config row(s), % spend row(s) today', n, m;
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner: columns, owner, barrier, exact consumer grant ────────────────────────────────────
DO $$
DECLARE
    v text;
    r text;
    cols text;
    want text;
BEGIN
    FOREACH v IN ARRAY ARRAY['catalog.v_llm_gateway_config_v1', 'catalog.v_llm_app_spend_today_v1'] LOOP
        IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
            RAISE EXCEPTION 'migration 323: % is not catalog_owner''s', v;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass
                                                AND 'security_barrier=true' = ANY(reloptions)) THEN
            RAISE EXCEPTION 'migration 323: % is not security_barrier', v;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'tripplanner')
           AND NOT pg_catalog.has_table_privilege('tripplanner', v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 323: tripplanner cannot read %', v;
        END IF;
        FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
            IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
               AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
                RAISE EXCEPTION 'migration 323: % can read % (tripplanner only)', r, v;
            END IF;
        END LOOP;
        SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
          FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
        want := CASE v
            WHEN 'catalog.v_llm_gateway_config_v1' THEN
                'stage,role,is_active,account_route,allowed_scopes,shadow_model_id,shadow_sample_pct,position,'
                'model_key,in_catalog,vendor,provider,api_style,bedrock_profile_ids,wire_model,max_output_tokens,'
                'model_enabled,price_in_per_mtok,price_out_per_mtok,price_cache_read_per_mtok,'
                'price_cache_write_per_mtok,deployments,route_updated_at'
            ELSE 'day,stage,calls,unpriced_calls,failed_calls,cost_usd,last_call_at' END;
        IF cols IS DISTINCT FROM want THEN
            RAISE EXCEPTION 'migration 323: % columns are %', v, cols;
        END IF;
    END LOOP;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 323: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('323', now(), 'AA-642 S8: catalog.v_llm_gateway_config_v1 + catalog.v_llm_app_spend_today_v1 (tripplanner) '
                      '— the TripPlanner gateway contract views (root ADR 0009 d13); column SELECT for catalog_owner')
ON CONFLICT (version) DO NOTHING;

COMMIT;
