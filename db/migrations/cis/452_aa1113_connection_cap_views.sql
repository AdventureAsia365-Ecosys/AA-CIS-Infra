-- Migration 452: AA-1113 (root ADR 0009 decisions 6 and 10) — one connection cap for every caller: the month-to-date
-- spend and the over-cap flag of each capped LLM connection, as a read contract for TripPlanner, and the flag (plus
-- the free-text mark of CIS 451) appended to TripPlanner's gateway contract view.
--
-- Why. A connection's monthly cap (shared.llm_provider_connection.monthly_budget_usd, its policy in
-- shared.llm_connection_cost_policy) is enforced by the CIS gateway only (shared/cost_guard.py
-- connection_budgets, shared/llm_client/connection_budget.py). TripPlanner's gateway reads its routes from
-- catalog.v_llm_gateway_config_v1 and could not see a cap (S283 ai-caps-gap point 2). This file publishes the same
-- rule as data, through the catalog contract path TripPlanner already uses. The CRM reads no CIS view (root ADR 0008a,
-- tech lead S284): it keeps its own monthly cap per connection as a CRM setting (crm-077), and a connection's
-- monthly_budget_usd here is the CIS share (CIS + TripPlanner) of the provider budget (CIS 453, a setting).
--
-- What:
--   1. Column-level SELECT for catalog_owner (the NOLOGIN owner of every catalog.* view), columns only:
--        shared.llm_role_config (free_text)                                   CIS 451
--        shared.llm_provider_connection (monthly_budget_usd)                  (connection_key since 341)
--        shared.llm_connection_cost_policy (connection_key, alert_pct, hard_stop)
--        shared.llm_call_log (account)                                        (cost_usd, created_at since 323)
--   2. CREATE OR REPLACE catalog.v_llm_connection_cap_v1 (new contract view, one row per connection that HAS a
--      monthly budget): connection_key, monthly_budget_usd, month_start (UTC), month_spent_usd and month_calls (the
--      shared.llm_call_log rows of this UTC month whose account is the connection: the exact sum
--      cost_guard._CONNECTION_MONTH_SPEND_SQL makes, shadow rows included), alert_pct and hard_stop (the policy row,
--      else the code defaults 80 / true, cost_guard.DEFAULT_CONNECTION_ALERT_PCT / ConnectionCostPolicy.hard_stop),
--      over_cap (spent >= budget: ConnectionBudget.reached) and stops (over_cap AND hard_stop:
--      ConnectionBudget.stops). The CIS ledger only (CIS + TripPlanner rows: the CIS share of the connection).
--      SELECT to tripplanner only; crm_app never reads it (root ADR 0008a, tech lead S284).
--   3. CREATE OR REPLACE catalog.v_llm_gateway_config_v1: 350's 27 columns unchanged, in order, then two appended
--      (contract v1: columns are only appended):
--        free_text             boolean  llm_role_config.free_text (CIS 451): the stage's prompts must be scrubbed
--                                       before any model call, the call refused when the scrub cannot run;
--        over_cap_connections  text[]   the connections of this model's deployments whose row in
--                                       v_llm_connection_cap_v1 says stops (empty array when none): the CIS gateway
--                                       leaves them out of the route (hard_stop mode; in failover_continue mode it
--                                       still leaves them out while another rung can answer).
--      The 350 body is repeated byte for byte; the additions are one MATERIALIZED CTE (the cap view read once per
--      query, not once per row) and one LEFT JOIN LATERAL.
--   4. Register 452.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): ACL changes on existing tables and schema and
-- an existing view replaced. MIG-4: migration-only PR (451 + 452), the byte copy in AA-CIS-Infra db/migrations/cis/,
-- Infra Migration Apply with every job table idle (root ADR 0017a). Consumers: none yet. TripPlanner's gateway does not
-- read the two columns or the cap view today, so TripPlanner's calls are NOT bounded by the cap until its follow-up
-- (read over_cap_connections by name, SQLSTATE 42703 before the apply keeping its 350 read; leave those deployments
-- out, refuse with budget when every rung is over cap under hard_stop). Nothing in CIS reads either view, and the CRM
-- reads neither.
-- DM-7.1: no new table.
--
-- Cost of a read. The cap view sums this UTC month's ledger rows of the capped connections (four on Dev) through
-- llm_call_log_created_id_idx (created_at, id); TripPlanner caches its gateway read 60 s. The gateway view reads the
-- cap view once per query (MATERIALIZED CTE).
--
-- Guards (RAISE rolls the whole file back): before — 350 and 451 registered, shared.llm_connection_cost_policy present,
-- schema catalog owned by cis_owner. After, as catalog_owner — both views answer. After, as cis_owner — the gateway
-- view's exact columns (350's then the two appended), both views owned by catalog_owner and security_barrier,
-- tripplanner reads both, booking / aa_app_user / cis_app / crm_app read neither, catalog_owner has no CREATE on schema
-- catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 323 / 341 / 350): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL
-- ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as cis_owner
-- (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL. The conftest replay skips this file (it
-- needs 323, 341 and 350, skipped too); tests/integration/test_aa1113_migration_452.py applies 323, 341, 350 then 452
-- the DB Migrate way and undoes them. After 452, 350 can no longer be re-run on that database (CREATE OR REPLACE VIEW
-- cannot drop appended columns); DB Migrate never re-runs a registered version.
--
-- Number. 451 (same PR) is this file's predecessor; renumber both together (git grep '452_' and 'CIS 452').
--
-- Locks. Column GRANTs (no lock that blocks readers or writers) and two CREATE OR REPLACE VIEW (AccessExclusiveLock on
-- each view only, held for the transaction). lock_timeout 5s, statement_timeout 1min. Idempotent (CREATE OR REPLACE
-- with the same column list, re-runnable grants, ON CONFLICT DO NOTHING), one transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe): DROP VIEW catalog.v_llm_gateway_config_v1, re-create it
-- with 350's definition and GRANT SELECT to tripplanner; DROP VIEW catalog.v_llm_connection_cap_v1; REVOKE the column
-- grants above FROM catalog_owner.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '350')
       OR to_regclass('catalog.v_llm_gateway_config_v1') IS NULL THEN
        RAISE EXCEPTION 'migration 452: apply 350 (catalog.v_llm_gateway_config_v1 stage params) first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'shared' AND table_name = 'llm_role_config'
                      AND column_name = 'free_text') THEN
        RAISE EXCEPTION 'migration 452: shared.llm_role_config.free_text missing (apply 451 first)';
    END IF;
    IF to_regclass('shared.llm_connection_cost_policy') IS NULL THEN
        RAISE EXCEPTION 'migration 452: shared.llm_connection_cost_policy missing (317)';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 452: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read (columns only) ────────────────────────────────────────────────────────────────
GRANT SELECT (free_text) ON shared.llm_role_config TO catalog_owner;
GRANT SELECT (monthly_budget_usd) ON shared.llm_provider_connection TO catalog_owner;
GRANT SELECT (connection_key, alert_pct, hard_stop) ON shared.llm_connection_cost_policy TO catalog_owner;
GRANT SELECT (account) ON shared.llm_call_log TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 2. The connection cap contract view ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_llm_connection_cap_v1 WITH (security_barrier = true) AS
WITH month AS (
    SELECT date_trunc('month', now() AT TIME ZONE 'utc') AT TIME ZONE 'utc' AS start
), capped AS (
    SELECT c.connection_key, c.monthly_budget_usd
      FROM shared.llm_provider_connection c
     WHERE c.monthly_budget_usd IS NOT NULL
), spent AS (
    -- cost_guard._CONNECTION_MONTH_SPEND_SQL: this UTC month's ledger rows whose account is the connection.
    SELECT l.account, coalesce(sum(l.cost_usd), 0) AS usd, count(*)::integer AS calls
      FROM shared.llm_call_log l, month m
     WHERE l.account IN (SELECT connection_key FROM capped)
       AND l.created_at >= m.start
     GROUP BY l.account
)
SELECT c.connection_key,
       c.monthly_budget_usd,
       m.start                                                        AS month_start,
       coalesce(s.usd, 0)::numeric(14,6)                              AS month_spent_usd,
       coalesce(s.calls, 0)                                           AS month_calls,
       coalesce(p.alert_pct, 80)                                      AS alert_pct,
       coalesce(p.hard_stop, true)                                    AS hard_stop,
       (coalesce(s.usd, 0) >= c.monthly_budget_usd)                   AS over_cap,
       (coalesce(s.usd, 0) >= c.monthly_budget_usd
        AND coalesce(p.hard_stop, true))                              AS stops
  FROM capped c
 CROSS JOIN month m
  LEFT JOIN spent s ON s.account = c.connection_key
  LEFT JOIN shared.llm_connection_cost_policy p ON p.connection_key = c.connection_key;

COMMENT ON VIEW catalog.v_llm_connection_cap_v1 IS
    'AA-1113 (452, root ADR 0009 d6): one row per LLM connection with a monthly budget: this UTC month''s CIS ledger '
    'spend on it (shared.llm_call_log, account = the connection), its policy (alert_pct, hard_stop; defaults 80 / '
    'true), over_cap (spent >= budget) and stops (over_cap and hard_stop: the CIS gateway leaves the connection out). '
    'TripPlanner only (the budget is the CIS share of the connection). Contract v1: columns are only appended; a '
    'change of meaning is a _v2 view.';

-- ── 3. The gateway view: 350's columns unchanged, then free_text and over_cap_connections ────────────────────────
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
), cap_stop AS MATERIALIZED (
    -- AA-1113 (452): the connections over their monthly cap with a hard-stop policy, read once per query.
    SELECT cap.connection_key FROM catalog.v_llm_connection_cap_v1 cap WHERE cap.stops
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
                     'reasoning_mode', p.reasoning_mode) END AS stage_params,
       r.free_text,
       COALESCE(oc.keys, ARRAY[]::text[])        AS over_cap_connections
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
  LEFT JOIN LATERAL (
      -- AA-1113 (452): this model's deployments whose connection the CIS gateway leaves out for its monthly cap.
      SELECT array_agg(DISTINCT x.connection_key ORDER BY x.connection_key) AS keys
        FROM shared.llm_model_deployment x
        JOIN cap_stop s ON s.connection_key = x.connection_key
       WHERE x.model_key = k.model_key
  ) oc ON true
 WHERE r.stage LIKE 'tp\_%';


COMMENT ON VIEW catalog.v_llm_gateway_config_v1 IS
    'AA-642 S8 (323, root ADR 0009 d13): the gateway route of each TripPlanner stage (tp_*), one row per model of '
    'its chain (position 0 = primary, then the fallbacks), with the catalog row and the deployments (JSON, by '
    'priority). AA-1027 E3 (341): + route_deadline_s and deployment_routing (per deployment: non-secret connection '
    'facts, the deployment circuit and the connection circuit). AA-1027 E4 (350): + supports_temperature and '
    'stage_params (the shared.stage_model_params row of the stage and model, NULL when none). AA-1113 (452): + '
    'free_text (scrub the prompt before any call, refuse when the scrub cannot run) and over_cap_connections (the '
    'connections of this model the CIS gateway leaves out for their monthly cap, catalog.v_llm_connection_cap_v1). '
    'TripPlanner only. Contract v1: columns are only appended; a change of meaning is a _v2 view.';

-- ── 4. The consumer (granted by the views' owner) ────────────────────────────────────────────────────────────────
GRANT SELECT ON catalog.v_llm_connection_cap_v1 TO tripplanner;

-- ── Closing check as catalog_owner: both views answer ────────────────────────────────────────────────────────────
DO $$
DECLARE
    n_cap bigint;
    n_free bigint;
BEGIN
    SELECT count(*) INTO n_cap FROM catalog.v_llm_connection_cap_v1;
    SELECT count(*) INTO n_free FROM catalog.v_llm_gateway_config_v1 WHERE free_text;
    RAISE NOTICE 'migration 452: as catalog_owner, % capped connection(s), % TripPlanner free-text route row(s)',
        n_cap, n_free;
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;


-- ── Closing check as cis_owner: columns, owners, barriers, exact consumer grants ─────────────────────────────────
DO $$
DECLARE
    gw constant text := 'catalog.v_llm_gateway_config_v1';
    cap constant text := 'catalog.v_llm_connection_cap_v1';
    v text;
    r text;
    cols text;
BEGIN
    FOREACH v IN ARRAY ARRAY[gw, cap] LOOP
        IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
            RAISE EXCEPTION 'migration 452: % is not catalog_owner''s', v;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
            RAISE EXCEPTION 'migration 452: % is not security_barrier', v;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'tripplanner')
           AND NOT pg_catalog.has_table_privilege('tripplanner', v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 452: tripplanner cannot read %', v;
        END IF;
        FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
            IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
               AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
                RAISE EXCEPTION 'migration 452: % can read %', r, v;
            END IF;
        END LOOP;
    END LOOP;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = gw::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM
       'stage,role,is_active,account_route,allowed_scopes,shadow_model_id,shadow_sample_pct,position,'
       'model_key,in_catalog,vendor,provider,api_style,bedrock_profile_ids,wire_model,max_output_tokens,'
       'model_enabled,price_in_per_mtok,price_out_per_mtok,price_cache_read_per_mtok,'
       'price_cache_write_per_mtok,deployments,route_updated_at,route_deadline_s,deployment_routing,'
       'supports_temperature,stage_params,free_text,over_cap_connections' THEN
        RAISE EXCEPTION 'migration 452: % columns are %', gw, cols;
    END IF;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = cap::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM
       'connection_key,monthly_budget_usd,month_start,month_spent_usd,month_calls,alert_pct,hard_stop,over_cap,stops' THEN
        RAISE EXCEPTION 'migration 452: % columns are %', cap, cols;
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 452: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('452', now(), 'AA-1113: catalog.v_llm_connection_cap_v1 (month spend, over_cap, stops per capped LLM '
                      'connection; tripplanner) and catalog.v_llm_gateway_config_v1 + free_text, '
                      'over_cap_connections')
ON CONFLICT (version) DO NOTHING;

COMMIT;
