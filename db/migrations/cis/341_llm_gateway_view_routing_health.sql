-- Migration 341: AA-1027 (AI gateway v2, root plan S263 slice E3, gaps PC-2 / TP-2 / TP-3) — append the deployment
-- routing facts and the circuit state to TripPlanner's gateway contract view catalog.v_llm_gateway_config_v1, plus the
-- route deadline.
--
-- Why. TripPlanner (AA-TripPlanner-Web backend/shared/llm_gateway.py) reads its routes through the view of migration
-- 323 but still picks the account of each model from a code list (SUPPORTED_ACCOUNTS = acc3, acc2) and the catalog's
-- bedrock_profile_ids, not from the deployments, and it cannot see the circuit breaker of the CIS gateway
-- (shared.llm_provider_health, migration 309; shared/llm_client/breaker.py). So while the LLM account refuses every
-- call (Bedrock "Error 002", connection circuit open on Dev), each TripPlanner Lambda container still sends its own
-- doomed attempts there. Slice E3 makes TripPlanner dispatch by deployment (connection, wire id, priority), skip what
-- its connection's kind / served roles / data scope rule out, and skip a connection or deployment whose circuit is
-- open, exactly as vendor_route.deployment_plan does in CIS. For that it needs, per deployment, a few NON-SECRET facts
-- of the connection and the circuit state; no account ID, role name, ExternalId, secret name, base URL or error text.
-- route_deadline_s (migration 320, values by role since 334) is appended too: TripPlanner's E1 deadline already reads
-- it when the config row carries it and today falls back to its own default.
--
-- What:
--   1. Column-level SELECT for catalog_owner (the NOLOGIN owner of every catalog.* view):
--        shared.llm_role_config (route_deadline_s);
--        shared.llm_provider_connection (connection_key, kind, auth_mode, account_id_env, region, data_scope,
--          served_roles, enabled, access_state) — not account_id, role_name, external_id, secret_name,
--          credential_env, base_url, notes, budgets;
--        shared.llm_provider_health (connection_key, model_key, last_ok_at, last_error_at, last_error_class,
--          consecutive_failures, circuit_open_until, probe_until) — not last_error (provider text).
--      account_id_env is the NAME of an environment variable (the CHECK allows only 'BEDROCK_ACCT_PRIMARY'), never an ID.
--   2. CREATE OR REPLACE catalog.v_llm_gateway_config_v1: the 23 columns of 323 unchanged, in order, then two appended
--      columns (contract v1: columns are only appended):
--        route_deadline_s   integer  llm_role_config.route_deadline_s;
--        deployment_routing jsonb    one object per deployment of the model, in the order of `deployments` (priority,
--                                    connection_key): connection_key, in_registry (the connection row exists), kind,
--                                    auth_mode, account_id_env, region, data_scope, served_roles, connection_enabled,
--                                    access_state, the deployment's circuit (circuit_open_until, probe_until,
--                                    last_error_class, consecutive_failures; NULLs when no health row) and the
--                                    connection-level circuit (connection_circuit_class,
--                                    connection_circuit_open_until; NULL when not tripped).
--      The connection-level circuit is breaker.connection_health (AA-1018) in SQL: over all health rows of the
--      connection, the rows of class credential / quota_exhausted / access_denied with a circuit on record
--      (circuit_open_until NOT NULL: open or half-open) whose failure is newer than the connection's last answered call
--      (max last_ok_at); it trips on one credential / quota_exhausted row, or on access_denied rows of at least 2
--      distinct models (CONNECTION_DENIED_MODELS); its class is the first of credential, quota_exhausted, access_denied
--      among the tripping rows and it is open until the newest circuit_open_until of them. A tripped connection
--      circuit is "refusing" (breaker.connection_refusing) until a call on the connection answers. TripPlanner compares
--      the timestamps with its own clock (the view states no "now"), so its 60 s route cache never freezes a state.
--      Health rows of other models of the connection are read only to derive that circuit; their model keys are not
--      exposed.
--   3. Register 341.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no expand header): step 1 changes the ACL of three existing tables and
-- step 2 replaces an existing view. MIG-4: this migration-only PR, the byte copy in AA-CIS-Infra db/migrations/cis/,
-- Infra Migration Apply with every job table idle (root ADR 0017a), then the TripPlanner PR that reads the columns.
-- The TripPlanner code also works before this file is applied (SQLSTATE 42703 on the appended columns: it reads the
-- 323 columns and maps the two connections it has always called), so the order is a preference, not a hazard.
-- Nothing in CIS reads the view. DM-7.1: no new table.
--
-- Guards (RAISE rolls the whole file back): before — 323 registered (the view exists), 309 / 320 / 322 columns present,
-- schema catalog owned by cis_owner. After, as catalog_owner — the view answers. After, as cis_owner — the view's
-- exact columns (323's then the two appended), owner catalog_owner, security_barrier, tripplanner can read it, booking,
-- aa_app_user, cis_app and crm_app cannot, tripplanner still cannot read shared.llm_provider_connection /
-- shared.llm_provider_health, catalog_owner reads no other column of them, catalog_owner has no CREATE on schema
-- catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 323 / 329): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE
-- catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as cis_owner (login
-- db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL. The conftest replay skips this file (it needs 323,
-- skipped too); tests/integration/test_aa1027_migration_341.py applies 323 then 341 the DB Migrate way and undoes both.
-- After 341, migration 323 itself can no longer be re-run on that database (CREATE OR REPLACE VIEW cannot drop the two
-- appended columns); DB Migrate never re-runs a registered version.
--
-- Number. 338 is the highest on main (02/11); 339 and 340 are held by other lanes of session S264. The CI migration
-- preflight refuses 341 until 339 and 340 are on main, so this PR is queued after the PR that adds them. If they do not
-- land first, renumber to the owner main max + 1 (git grep '341_' and '341' in this file, the test and conftest);
-- never the migration:out-of-order label (a labelled file is never auto-applied).
--
-- Locks. Three column GRANTs (no lock that blocks readers or writers of the tables) and one CREATE OR REPLACE VIEW
-- (AccessExclusiveLock on the view only, held for the transaction). lock_timeout 5s, statement_timeout 1min.
-- Idempotent (CREATE OR REPLACE with the same column list, re-runnable grants, ON CONFLICT DO NOTHING), one
-- transaction, self-registering. After apply the DB Schema Dump workflow regenerates
-- docs/architecture/db-schema-reference.md.
--
-- Rollback (a NEW forward migration under the same recipe): DROP VIEW catalog.v_llm_gateway_config_v1, re-create it
-- with 323's definition and GRANT SELECT to tripplanner (TripPlanner falls back to the 323 columns on 42703); REVOKE
-- SELECT (the columns above) ON the three tables FROM catalog_owner.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '323')
       OR to_regclass('catalog.v_llm_gateway_config_v1') IS NULL THEN
        RAISE EXCEPTION 'migration 341: apply 323 (catalog.v_llm_gateway_config_v1) first';
    END IF;
    IF to_regclass('shared.llm_provider_health') IS NULL THEN
        RAISE EXCEPTION 'migration 341: shared.llm_provider_health missing (309)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'shared' AND table_name = 'llm_role_config'
                      AND column_name = 'route_deadline_s') THEN
        RAISE EXCEPTION 'migration 341: shared.llm_role_config.route_deadline_s missing (320)';
    END IF;
    IF (SELECT count(*) FROM information_schema.columns
         WHERE table_schema = 'shared' AND table_name = 'llm_provider_connection'
           AND column_name IN ('served_roles', 'access_state')) <> 2 THEN
        RAISE EXCEPTION 'migration 341: shared.llm_provider_connection has no served_roles / access_state (322)';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 341: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read for the appended columns (columns only) ───────────────────────────────────────
GRANT SELECT (route_deadline_s) ON shared.llm_role_config TO catalog_owner;
GRANT SELECT (connection_key, kind, auth_mode, account_id_env, region, data_scope, served_roles, enabled,
              access_state)
    ON shared.llm_provider_connection TO catalog_owner;
GRANT SELECT (connection_key, model_key, last_ok_at, last_error_at, last_error_class, consecutive_failures,
              circuit_open_until, probe_until)
    ON shared.llm_provider_health TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 2. The view: 323's columns unchanged, then route_deadline_s and deployment_routing ───────────────────────────
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
       COALESCE(g.routing, '[]'::jsonb)          AS deployment_routing
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
    'facts, the deployment circuit and the connection circuit). TripPlanner only. Contract v1: columns are only '
    'appended; a change of meaning is a _v2 view.';

-- ── Closing check as catalog_owner: the view answers ─────────────────────────────────────────────────────────────
DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM catalog.v_llm_gateway_config_v1 WHERE jsonb_typeof(deployment_routing) = 'array';
    RAISE NOTICE 'migration 341: as catalog_owner, % gateway config row(s)', n;
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner: columns, owner, barrier, exact consumer grant, column grants ─────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_llm_gateway_config_v1';
    r text;
    t text;
    cols text;
    extra text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 341: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 341: % is not security_barrier', v;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'tripplanner')
       AND NOT pg_catalog.has_table_privilege('tripplanner', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 341: tripplanner cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 341: % can read % (tripplanner only)', r, v;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM
       'stage,role,is_active,account_route,allowed_scopes,shadow_model_id,shadow_sample_pct,position,'
       'model_key,in_catalog,vendor,provider,api_style,bedrock_profile_ids,wire_model,max_output_tokens,'
       'model_enabled,price_in_per_mtok,price_out_per_mtok,price_cache_read_per_mtok,'
       'price_cache_write_per_mtok,deployments,route_updated_at,route_deadline_s,deployment_routing' THEN
        RAISE EXCEPTION 'migration 341: % columns are %', v, cols;
    END IF;
    FOREACH t IN ARRAY ARRAY['shared.llm_provider_connection', 'shared.llm_provider_health'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'tripplanner')
           AND pg_catalog.has_any_column_privilege('tripplanner', t, 'SELECT') THEN
            RAISE EXCEPTION 'migration 341: tripplanner can read % directly', t;
        END IF;
    END LOOP;
    SELECT string_agg(a.attrelid::regclass || '.' || a.attname, ', ' ORDER BY a.attrelid::regclass::text, a.attname)
      INTO extra
      FROM pg_attribute a
     WHERE a.attrelid IN ('shared.llm_provider_connection'::regclass, 'shared.llm_provider_health'::regclass)
       AND a.attnum > 0 AND NOT a.attisdropped
       AND a.attname IN ('account_id', 'role_name', 'external_id', 'secret_name', 'credential_env', 'base_url',
                         'last_error')
       AND pg_catalog.has_column_privilege('catalog_owner', a.attrelid, a.attnum, 'SELECT');
    IF extra IS NOT NULL THEN
        RAISE EXCEPTION 'migration 341: catalog_owner can read %', extra;
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 341: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('341', now(), 'AA-1027 E3: catalog.v_llm_gateway_config_v1 + route_deadline_s, deployment_routing '
                      '(non-secret connection facts, deployment and connection circuit) for TripPlanner; column '
                      'SELECT for catalog_owner on llm_provider_connection / llm_provider_health')
ON CONFLICT (version) DO NOTHING;

COMMIT;
