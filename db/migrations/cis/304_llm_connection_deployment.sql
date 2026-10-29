-- Migration 304: AA-1002 (LLM gateway slice S1) — connection registry + model deployments, widened CHECKs.
--
-- Why. Today the gateway's ways in are code constants: the Bedrock satellite account, role and ExternalId
-- (bedrock_satellite._SATELLITE_ACCOUNTS), the acc2 task-role client of embed.py, the OpenAI key injected as the env
-- var OPENAI_API_KEY, and the legacy haiku / sonnet inference profiles (bedrock_satellite._PROFILE_ID_*,
-- pricing.BEDROCK_*). A Model Key also mixes the model with the way it is called (bedrock_profile_ids keyed by
-- account). Adding a way in (another Bedrock account, the Anthropic API) is a code change plus a deploy. The approved
-- design (S258, ai-gateway) splits this into data: a connection (how to reach a provider) and a deployment (a catalog
-- model on one connection, with its wire id and priority). This file is slice S1: the schema plus a backfill that
-- describes today's paths exactly. No code routes through the new tables yet (S3 does); nothing calls a new path.
--
-- What.
--   1. Widen three CHECKs (values only added, every existing row still passes):
--        llm_model_catalog_provider_check  + anthropic, azure_openai, mock
--        llm_model_catalog_api_style_check + anthropic_messages (the Anthropic Messages adapter, S2: dispatch is by
--                                            api_style, and anthropic_native is the legacy InvokeModel body),
--                                            openai_responses (kept free for the OpenAI Responses API)
--        spend_budget_provider_check       + anthropic, azure_openai
--   2. shared.llm_model_catalog.capabilities jsonb NOT NULL DEFAULT '{}' (object). Model facts the adapters will read
--      (forced_tool, structured_output, thinking, default effort). Empty today: the code still holds them as
--      constants (client._NO_FORCED_TOOL_CHOICE_MARKERS, supports_temperature). bedrock_profile_ids is NOT touched:
--      TripPlanner's gateway SELECTs it (and account_route) and keeps doing so until slice S8.
--   3. shared.llm_provider_connection: one row per way in. kind bedrock | anthropic | openai | azure_openai | mock;
--      auth_mode assume_role | task_role | bedrock_api_key | api_key | none (paired with the kind by CHECK).
--      Credentials are never stored: an api_key connection names a Secrets Manager secret, and secret_name must
--      match ^aa-llm/<env>/<name>$ (CHECK here, the same pattern in shared/llm_client/connections.py), so a row edited
--      through the admin can never point the gateway at another app's secret (rds, typesafe, booking ...).
--      credential_env / account_id_env name an env var instead, closed lists (OPENAI_API_KEY; BEDROCK_ACCT_PRIMARY):
--      they describe today's OpenAI key and today's satellite account ID, which this public repo never writes down.
--      base_url: https only and NULL for bedrock / mock (CHECK); the per-kind host allowlist is a code constant
--      (connections.BASE_URL_ALLOWLIST), checked before any call. data_scope aws_only | vendor_direct, timeout_s,
--      max_retries, max_concurrency, rpm_limit, monthly_budget_usd (unused until S4 / S10), enabled (default false).
--   4. shared.llm_model_deployment: PK (model_key, connection_key); model_key FK -> llm_model_catalog ON DELETE
--      CASCADE (a deployment of a deleted model means nothing), connection_key FK -> llm_provider_connection
--      ON DELETE RESTRICT; wire_id (inference profile id or vendor model name), priority (lower first), enabled,
--      price overrides (NULL = the catalog price), batch_capable, request_defaults (object), origin (how the row was
--      born), notes.
--   5. Seed connections (ON CONFLICT DO NOTHING, an admin's later edit is kept):
--        acc3             bedrock / assume_role, role AA3-Bedrock-Invoker, ExternalId aa296-satellite-bedrock-acc3,
--                         us-west-1, account from env BEDROCK_ACCT_PRIMARY, aws_only, ENABLED (today's satellite)
--        acc2             bedrock / task_role, us-west-1, aws_only, ENABLED (today's Cohere embed client)
--        openai-direct    openai / api_key, key from env OPENAI_API_KEY (task definition, today), base_url
--                         https://api.openai.com/v1, vendor_direct, ENABLED (gpt-6-luna-openai, the S235 last resort)
--        anthropic-direct anthropic / api_key, secret aa-llm/dev/anthropic-direct, https://api.anthropic.com,
--                         vendor_direct, DISABLED (no adapter before S2, no secret yet)
--        bedrock-llm-org  bedrock / assume_role, role AA-LLM-Invoker on a new LLM account (account and ExternalId set
--                         when that account exists, S1-infra), us-west-1, aws_only, DISABLED
--   6. Backfill deployments = the paths today's code takes (ON CONFLICT DO NOTHING):
--        a. legacy keys first, from the code constants (the legacy chain never reads the catalog's profiles):
--             haiku  @acc3 global.anthropic.claude-haiku-4-5-20251001-v1:0  priority 10 enabled
--             sonnet @acc3 global.anthropic.claude-sonnet-4-6               priority 10 enabled
--             haiku  @acc2 us.anthropic.claude-haiku-4-5-20251001-v1:0     priority 20 disabled
--             sonnet @acc2 us.anthropic.claude-sonnet-4-5-20250929-v1:0    priority 20 disabled
--           (acc2 native Claude runs only with LLM_LEGACY_ACC2_NATIVE=on, off by default: AA-843.)
--        b. every bedrock catalog row x each acc3 / acc2 key of bedrock_profile_ids: wire_id = the profile,
--           priority acc3 10 / acc2 20 (CatalogModel.account_for order), enabled = acc3, or acc2 for an embed row
--           (a converse row on acc2 is refused by client._call_catalog_model). A key outside acc3 / acc2 is skipped.
--        c. every openai catalog row (gpt-4.1 retired, gpt-6-luna-openai) @openai-direct, wire_id = wire_model,
--           priority 10, enabled (the catalog row's own enabled flag stays the model switch, as today).
--      typesafe (Jev) stays outside the registry in S1.
--   7. Grants: REVOKE ALL from PUBLIC, cis_app, aa_app_user, catalog_owner on the two new tables, then cis_app SELECT
--      only (S1 reads; the S4 admin PATCH adds UPDATE on the connection table with its audit rows). No tripplanner
--      grant (TripPlanner does not read them before S8).
--   8. Register 304.
--
-- Guards (RAISE rolls the whole file back):
--   before: the catalog (169), role config (137) and spend budget (168) tables exist; 303 registered (NOTICE only).
--   after:  every bedrock catalog row with an acc3 / acc2 profile has a deployment on that connection; every openai
--           catalog row has one on openai-direct; every enabled acc3 deployment's wire_id equals the row's acc3 profile
--           (legacy keys: the code constant); no seeded connection breaks the secret prefix.
--
-- Order with the code. Independent. Nothing on a request path reads the new tables in S1 (the admin listing
-- GET /admin/llm-connections answers schema_ready=false before this file is applied), and no code writes the new
-- CHECK values before S2. Apply through AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/, opened by the
-- migration-sync bot) after 303, with the job tables idle (DM-11.4): this is a contract file (it changes CHECKs of
-- existing tables), not an expand file.
--
-- Number. 303 is the latest on main and in the 29/10 schema dump; no open PR or S258 worktree uses 304.
--
-- Preflight (read-only, as cis_app; expected: 3 tables, 0 new tables, 14 catalog rows on Dev 29/10, 0 rows whose
-- provider / api_style would fail the widened CHECKs):
--   SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'shared'
--             AND c.relname IN ('llm_model_catalog', 'llm_role_config', 'spend_budget')) AS tables,
--          (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'shared'
--             AND c.relname IN ('llm_provider_connection', 'llm_model_deployment')) AS new_tables,
--          (SELECT count(*) FROM shared.llm_model_catalog) AS catalog_rows,
--          (SELECT count(*) FROM shared.llm_model_catalog
--            WHERE provider NOT IN ('bedrock', 'openai', 'typesafe', 'anthropic', 'azure_openai', 'mock')
--               OR api_style NOT IN ('anthropic_native', 'converse', 'openai_chat', 'embed', 'decide',
--                                    'anthropic_messages', 'openai_responses')) AS misfits;
--
-- Rollback (a NEW forward migration, after the code that reads the tables is reverted):
--   DROP TABLE shared.llm_model_deployment; DROP TABLE shared.llm_provider_connection;   -- migrate: destructive
--   ALTER TABLE shared.llm_model_catalog DROP COLUMN capabilities;
--   the three CHECKs back to their 181 / 169 / 226 lists (only once no row uses a new value).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of shared and of
-- the three existing tables.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 0. Guard: predecessors ───────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('shared.llm_model_catalog') IS NULL OR to_regclass('shared.llm_role_config') IS NULL
       OR to_regclass('shared.spend_budget') IS NULL THEN
        RAISE EXCEPTION 'migration 304: shared.llm_model_catalog (169), shared.llm_role_config (137) or '
                        'shared.spend_budget (168) is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '303') THEN
        RAISE NOTICE 'migration 304: 303 is not registered (Dev applies in version order)';
    END IF;
END $$;

-- ── 1. Widened CHECKs (values added only) ────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.llm_model_catalog DROP CONSTRAINT IF EXISTS llm_model_catalog_provider_check;
ALTER TABLE shared.llm_model_catalog
    ADD CONSTRAINT llm_model_catalog_provider_check
    CHECK (provider IN ('bedrock', 'openai', 'typesafe', 'anthropic', 'azure_openai', 'mock'));

ALTER TABLE shared.llm_model_catalog DROP CONSTRAINT IF EXISTS llm_model_catalog_api_style_check;
ALTER TABLE shared.llm_model_catalog
    ADD CONSTRAINT llm_model_catalog_api_style_check
    CHECK (api_style IN ('anthropic_native', 'converse', 'openai_chat', 'embed', 'decide',
                         'anthropic_messages', 'openai_responses'));

ALTER TABLE shared.spend_budget DROP CONSTRAINT IF EXISTS spend_budget_provider_check;
ALTER TABLE shared.spend_budget
    ADD CONSTRAINT spend_budget_provider_check
    CHECK (provider IN ('dfs', 'bedrock', 'openai', 'jev', 'geocoder', 'anthropic', 'azure_openai'));

COMMENT ON CONSTRAINT llm_model_catalog_provider_check ON shared.llm_model_catalog IS
    'AA-1002 (CIS 304): + anthropic, azure_openai, mock (was bedrock | openai | typesafe since 169).';
COMMENT ON CONSTRAINT llm_model_catalog_api_style_check ON shared.llm_model_catalog IS
    'AA-1002 (CIS 304): + anthropic_messages (Anthropic Messages API adapter), openai_responses (reserved). '
    'anthropic_native stays the legacy Bedrock InvokeModel body of the haiku / sonnet keys.';
COMMENT ON CONSTRAINT spend_budget_provider_check ON shared.spend_budget IS
    'AA-1002 (CIS 304): + anthropic, azure_openai (was dfs | bedrock | openai | jev | geocoder since 226).';

-- ── 2. Catalog capabilities ──────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.llm_model_catalog
    ADD COLUMN IF NOT EXISTS capabilities jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE shared.llm_model_catalog DROP CONSTRAINT IF EXISTS llm_model_catalog_capabilities_check;
ALTER TABLE shared.llm_model_catalog
    ADD CONSTRAINT llm_model_catalog_capabilities_check CHECK (jsonb_typeof(capabilities) = 'object');
COMMENT ON COLUMN shared.llm_model_catalog.capabilities IS
    'AA-1002 (CIS 304): model facts the adapters read (forced_tool, structured_output, thinking, default_effort, '
    'prefill). Empty object = the code defaults (client._NO_FORCED_TOOL_CHOICE_MARKERS, supports_temperature).';

-- ── 3. Connections ───────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.llm_provider_connection (
    connection_key     text        NOT NULL,
    kind               text        NOT NULL,
    auth_mode          text        NOT NULL,
    label              text        NOT NULL,
    account_id         text,
    account_id_env     text,
    region             text,
    role_name          text,
    external_id        text,
    secret_name        text,
    credential_env     text,
    base_url           text,
    data_scope         text        NOT NULL,
    timeout_s          integer,
    max_retries        integer,
    max_concurrency    integer,
    rpm_limit          integer,
    monthly_budget_usd numeric(10,2),
    enabled            boolean     NOT NULL DEFAULT false,
    notes              text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         text        NOT NULL,
    CONSTRAINT llm_provider_connection_pkey PRIMARY KEY (connection_key),
    CONSTRAINT llm_provider_connection_key_check CHECK (connection_key ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
    CONSTRAINT llm_provider_connection_kind_check
        CHECK (kind IN ('bedrock', 'anthropic', 'openai', 'azure_openai', 'mock')),
    CONSTRAINT llm_provider_connection_auth_mode_check
        CHECK ((kind = 'bedrock' AND auth_mode IN ('assume_role', 'task_role', 'bedrock_api_key'))
            OR (kind IN ('anthropic', 'openai', 'azure_openai') AND auth_mode = 'api_key')
            OR (kind = 'mock' AND auth_mode = 'none')),
    CONSTRAINT llm_provider_connection_data_scope_check CHECK (data_scope IN ('aws_only', 'vendor_direct')),
    CONSTRAINT llm_provider_connection_account_id_check CHECK (account_id IS NULL OR account_id ~ '^[0-9]{12}$'),
    CONSTRAINT llm_provider_connection_account_id_env_check
        CHECK (account_id_env IS NULL OR account_id_env IN ('BEDROCK_ACCT_PRIMARY')),
    CONSTRAINT llm_provider_connection_region_check CHECK (region IS NULL OR region ~ '^[a-z]{2}(-[a-z]+)+-[0-9]$'),
    CONSTRAINT llm_provider_connection_role_name_check
        CHECK (role_name IS NULL OR role_name ~ '^[A-Za-z0-9+=,.@_-]{1,64}$'),
    CONSTRAINT llm_provider_connection_secret_name_check
        CHECK (secret_name IS NULL OR secret_name ~ '^aa-llm/[a-z0-9-]+/[a-z0-9][a-z0-9-]*$'),
    CONSTRAINT llm_provider_connection_credential_env_check
        CHECK (credential_env IS NULL OR credential_env IN ('OPENAI_API_KEY')),
    CONSTRAINT llm_provider_connection_base_url_check
        CHECK (base_url IS NULL
            OR (kind NOT IN ('bedrock', 'mock')
                AND base_url ~ '^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(/[A-Za-z0-9._~-]+)*/?$')),
    -- what each auth mode needs before the connection may be enabled
    CONSTRAINT llm_provider_connection_assume_role_check
        CHECK (auth_mode <> 'assume_role' OR NOT enabled
            OR (role_name IS NOT NULL AND external_id IS NOT NULL AND region IS NOT NULL
                AND (account_id IS NOT NULL OR account_id_env IS NOT NULL))),
    CONSTRAINT llm_provider_connection_task_role_check
        CHECK (auth_mode <> 'task_role'
            OR (region IS NOT NULL AND role_name IS NULL AND external_id IS NULL AND secret_name IS NULL
                AND credential_env IS NULL)),
    CONSTRAINT llm_provider_connection_key_source_check
        CHECK (auth_mode NOT IN ('api_key', 'bedrock_api_key') OR NOT enabled
            OR secret_name IS NOT NULL OR credential_env IS NOT NULL),
    CONSTRAINT llm_provider_connection_timeout_check CHECK (timeout_s IS NULL OR timeout_s BETWEEN 1 AND 900),
    CONSTRAINT llm_provider_connection_retries_check CHECK (max_retries IS NULL OR max_retries BETWEEN 0 AND 5),
    CONSTRAINT llm_provider_connection_concurrency_check
        CHECK (max_concurrency IS NULL OR max_concurrency BETWEEN 1 AND 1000),
    CONSTRAINT llm_provider_connection_rpm_check CHECK (rpm_limit IS NULL OR rpm_limit BETWEEN 1 AND 100000),
    CONSTRAINT llm_provider_connection_budget_check CHECK (monthly_budget_usd IS NULL OR monthly_budget_usd >= 0)
);

COMMENT ON TABLE shared.llm_provider_connection IS
    'AA-1002 (CIS 304): one row per way into an LLM provider (Bedrock account, vendor API). Holds no credential: '
    'a secret name (aa-llm/ prefix only) or an allowlisted env var name. Read by shared/llm_client/connections.py; '
    'not on the routing path before slice S3.';
COMMENT ON COLUMN shared.llm_provider_connection.account_id_env IS
    'AA-1002: env var holding the account ID when account_id is NULL (closed list; the public repo carries no ID).';
COMMENT ON COLUMN shared.llm_provider_connection.secret_name IS
    'AA-1002: Secrets Manager secret holding the API key, ^aa-llm/<env>/<name>$ only (CHECK + code), never a value.';
COMMENT ON COLUMN shared.llm_provider_connection.credential_env IS
    'AA-1002: env var holding the key when no secret is named (closed list: OPENAI_API_KEY until slice S9).';
COMMENT ON COLUMN shared.llm_provider_connection.base_url IS
    'AA-1002: https endpoint; NULL for bedrock / mock. The per-kind host allowlist is a code constant '
    '(connections.BASE_URL_ALLOWLIST), checked before any call.';

-- ── 4. Deployments ───────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.llm_model_deployment (
    model_key                     text          NOT NULL,
    connection_key                text          NOT NULL,
    wire_id                       text          NOT NULL,
    priority                      smallint      NOT NULL DEFAULT 100,
    enabled                       boolean       NOT NULL DEFAULT false,
    price_in_override             numeric(10,4),
    price_out_override            numeric(10,4),
    price_cache_read_override     numeric(10,4),
    price_cache_write_override    numeric(10,4),
    price_cache_write_1h_override numeric(10,4),
    batch_capable                 boolean       NOT NULL DEFAULT false,
    request_defaults              jsonb         NOT NULL DEFAULT '{}'::jsonb,
    origin                        text          NOT NULL,
    notes                         text,
    created_at                    timestamptz   NOT NULL DEFAULT now(),
    updated_at                    timestamptz   NOT NULL DEFAULT now(),
    updated_by                    text          NOT NULL,
    CONSTRAINT llm_model_deployment_pkey PRIMARY KEY (model_key, connection_key),
    CONSTRAINT llm_model_deployment_model_fkey FOREIGN KEY (model_key)
        REFERENCES shared.llm_model_catalog (model_key) ON DELETE CASCADE,
    CONSTRAINT llm_model_deployment_connection_fkey FOREIGN KEY (connection_key)
        REFERENCES shared.llm_provider_connection (connection_key) ON DELETE RESTRICT,
    CONSTRAINT llm_model_deployment_wire_id_check CHECK (length(wire_id) BETWEEN 1 AND 200),
    CONSTRAINT llm_model_deployment_priority_check CHECK (priority BETWEEN 0 AND 1000),
    CONSTRAINT llm_model_deployment_price_check
        CHECK ((price_in_override IS NULL OR price_in_override >= 0)
           AND (price_out_override IS NULL OR price_out_override >= 0)
           AND (price_cache_read_override IS NULL OR price_cache_read_override >= 0)
           AND (price_cache_write_override IS NULL OR price_cache_write_override >= 0)
           AND (price_cache_write_1h_override IS NULL OR price_cache_write_1h_override >= 0)),
    CONSTRAINT llm_model_deployment_request_defaults_check CHECK (jsonb_typeof(request_defaults) = 'object'),
    CONSTRAINT llm_model_deployment_origin_check
        CHECK (origin IN ('legacy_constant', 'bedrock_profile', 'openai_wire', 'seed', 'admin'))
);

CREATE INDEX IF NOT EXISTS llm_model_deployment_connection_idx ON shared.llm_model_deployment (connection_key);

COMMENT ON TABLE shared.llm_model_deployment IS
    'AA-1002 (CIS 304): a catalog model on one connection (wire id, priority, overrides). Backfilled from today''s '
    'paths (legacy constants, bedrock_profile_ids, openai rows). bedrock_profile_ids stays the source TripPlanner '
    'reads until slice S8. Not on the routing path before slice S3.';
COMMENT ON COLUMN shared.llm_model_deployment.origin IS
    'AA-1002: legacy_constant (code constant of the haiku / sonnet chain), bedrock_profile (a catalog '
    'bedrock_profile_ids entry), openai_wire (an openai catalog row), seed (a migration), admin (an admin edit).';

-- ── 5. Seed connections ──────────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.llm_provider_connection
    (connection_key, kind, auth_mode, label, account_id, account_id_env, region, role_name, external_id,
     secret_name, credential_env, base_url, data_scope, enabled, notes, updated_by)
VALUES
    ('acc3', 'bedrock', 'assume_role', 'Bedrock, LLM account (assume role)', NULL, 'BEDROCK_ACCT_PRIMARY',
     'us-west-1', 'AA3-Bedrock-Invoker', 'aa296-satellite-bedrock-acc3', NULL, NULL, NULL, 'aws_only', true,
     'Today''s satellite (bedrock_satellite._SATELLITE_ACCOUNTS); the account ID comes from the task env.',
     'migration-304-aa1002'),
    ('acc2', 'bedrock', 'task_role', 'Bedrock, main account (task role)', NULL, NULL,
     'us-west-1', NULL, NULL, NULL, NULL, NULL, 'aws_only', true,
     'Today''s acc2-native client (embed.py; legacy Claude only with LLM_LEGACY_ACC2_NATIVE=on).',
     'migration-304-aa1002'),
    ('openai-direct', 'openai', 'api_key', 'OpenAI API (direct)', NULL, NULL,
     NULL, NULL, NULL, NULL, 'OPENAI_API_KEY', 'https://api.openai.com/v1', 'vendor_direct', true,
     'Today''s OpenAI client (key from the task definition env). Moves to secret aa-llm/dev/openai-direct in S9.',
     'migration-304-aa1002'),
    ('anthropic-direct', 'anthropic', 'api_key', 'Anthropic API (direct)', NULL, NULL,
     NULL, NULL, NULL, 'aa-llm/dev/anthropic-direct', NULL, 'https://api.anthropic.com', 'vendor_direct', false,
     'Off: no adapter before slice S2 and no secret yet.',
     'migration-304-aa1002'),
    ('bedrock-llm-org', 'bedrock', 'assume_role', 'Bedrock, new LLM account (assume role)', NULL, NULL,
     'us-west-1', 'AA-LLM-Invoker', NULL, NULL, NULL, NULL, 'aws_only', false,
     'Off: the account ID and ExternalId are set when the account and its invoker role exist (S1-infra).',
     'migration-304-aa1002')
ON CONFLICT (connection_key) DO NOTHING;

-- ── 6. Backfill deployments (today's paths) ──────────────────────────────────────────────────────────────────────
-- a. legacy haiku / sonnet: the code constants (bedrock_satellite._PROFILE_ID_*, pricing.BEDROCK_*), first, so a
--    drifted catalog profile never wins over what the chain really invokes.
INSERT INTO shared.llm_model_deployment
    (model_key, connection_key, wire_id, priority, enabled, origin, notes, updated_by)
SELECT v.model_key, v.connection_key, v.wire_id, v.priority, v.enabled, 'legacy_constant', v.notes,
       'migration-304-aa1002'
  FROM (VALUES
        ('haiku',  'acc3', 'global.anthropic.claude-haiku-4-5-20251001-v1:0', 10, true,
         'Legacy chain (bedrock_satellite._PROFILE_ID_HAIKU).'),
        ('sonnet', 'acc3', 'global.anthropic.claude-sonnet-4-6', 10, true,
         'Legacy chain (bedrock_satellite._PROFILE_ID_SONNET).'),
        ('haiku',  'acc2', 'us.anthropic.claude-haiku-4-5-20251001-v1:0', 20, false,
         'Legacy chain acc2-native (pricing.BEDROCK_HAIKU), only with LLM_LEGACY_ACC2_NATIVE=on (AA-843).'),
        ('sonnet', 'acc2', 'us.anthropic.claude-sonnet-4-5-20250929-v1:0', 20, false,
         'Legacy chain acc2-native (pricing.BEDROCK_SONNET), only with LLM_LEGACY_ACC2_NATIVE=on (AA-843).')
       ) AS v (model_key, connection_key, wire_id, priority, enabled, notes)
  JOIN shared.llm_model_catalog m ON m.model_key = v.model_key
ON CONFLICT (model_key, connection_key) DO NOTHING;

-- b. every bedrock catalog row x each acc3 / acc2 profile (CatalogModel.account_for: acc3 before acc2)
INSERT INTO shared.llm_model_deployment
    (model_key, connection_key, wire_id, priority, enabled, origin, notes, updated_by)
SELECT m.model_key, p.key, p.value,
       CASE p.key WHEN 'acc3' THEN 10 ELSE 20 END,
       (p.key = 'acc3' OR m.api_style = 'embed'),
       'bedrock_profile',
       CASE WHEN p.key = 'acc2' AND m.api_style <> 'embed'
            THEN 'acc2 profile kept for the record; the gateway calls only acc3 for this api_style today.' END,
       'migration-304-aa1002'
  FROM shared.llm_model_catalog m
 CROSS JOIN LATERAL jsonb_each_text(m.bedrock_profile_ids) AS p (key, value)
 WHERE m.provider = 'bedrock'
   AND p.key IN ('acc3', 'acc2')
   AND p.value IS NOT NULL AND p.value <> ''
ON CONFLICT (model_key, connection_key) DO NOTHING;

-- c. every openai catalog row on the direct API (the catalog row's enabled flag stays the model switch)
INSERT INTO shared.llm_model_deployment
    (model_key, connection_key, wire_id, priority, enabled, origin, notes, updated_by)
SELECT m.model_key, 'openai-direct', COALESCE(m.wire_model, m.model_key), 10, true, 'openai_wire',
       'LLMClient._call_openai (Chat Completions).', 'migration-304-aa1002'
  FROM shared.llm_model_catalog m
 WHERE m.provider = 'openai'
ON CONFLICT (model_key, connection_key) DO NOTHING;

-- ── 7. Grants ────────────────────────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON shared.llm_provider_connection, shared.llm_model_deployment FROM PUBLIC;
REVOKE ALL ON shared.llm_provider_connection, shared.llm_model_deployment
    FROM cis_app, aa_app_user, catalog_owner;                     -- also column grants: from nothing
GRANT SELECT ON shared.llm_provider_connection, shared.llm_model_deployment TO cis_app;

-- ── 8. Guard: the backfill describes today's paths ───────────────────────────────────────────────────────────────
DO $$
DECLARE
    missing text;
    drift   text;
    bad     text;
BEGIN
    SELECT string_agg(m.model_key || '@' || p.key, ', ' ORDER BY m.model_key, p.key) INTO missing
      FROM shared.llm_model_catalog m
     CROSS JOIN LATERAL jsonb_each_text(m.bedrock_profile_ids) AS p (key, value)
     WHERE m.provider = 'bedrock' AND p.key IN ('acc3', 'acc2') AND p.value <> ''
       AND NOT EXISTS (SELECT 1 FROM shared.llm_model_deployment d
                        WHERE d.model_key = m.model_key AND d.connection_key = p.key);
    IF missing IS NULL THEN
        SELECT string_agg(m.model_key || '@openai-direct', ', ' ORDER BY m.model_key) INTO missing
          FROM shared.llm_model_catalog m
         WHERE m.provider = 'openai'
           AND NOT EXISTS (SELECT 1 FROM shared.llm_model_deployment d
                            WHERE d.model_key = m.model_key AND d.connection_key = 'openai-direct');
    END IF;
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 304: catalog paths without a deployment: %', missing;
    END IF;

    SELECT string_agg(d.model_key, ', ' ORDER BY d.model_key) INTO drift
      FROM shared.llm_model_deployment d
      JOIN shared.llm_model_catalog m ON m.model_key = d.model_key
     WHERE d.connection_key = 'acc3' AND d.enabled AND d.origin = 'bedrock_profile'
       AND d.wire_id IS DISTINCT FROM (m.bedrock_profile_ids ->> 'acc3');
    IF drift IS NOT NULL THEN
        RAISE EXCEPTION 'migration 304: acc3 deployments whose wire_id differs from bedrock_profile_ids: % '
                        '(bedrock_profile_ids is still what the gateway and TripPlanner call)', drift;
    END IF;

    SELECT string_agg(connection_key, ', ' ORDER BY connection_key) INTO bad
      FROM shared.llm_provider_connection
     WHERE secret_name IS NOT NULL AND secret_name NOT LIKE 'aa-llm/%';
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 304: connections naming a secret outside aa-llm/: %', bad;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('304', now(), 'AA-1002: llm_provider_connection + llm_model_deployment (backfilled), catalog capabilities, '
                      'provider / api_style / spend_budget CHECKs widened')
ON CONFLICT (version) DO NOTHING;

COMMIT;
