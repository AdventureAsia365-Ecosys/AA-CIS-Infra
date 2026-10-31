-- Migration 322: AA-1017 (AI gateway v2, registry v2 part 2; root ADR 0009 §2, design decision D9) — the connection
-- registry holds every paid provider kind, with a secret guard per kind, and the admin can no longer move a secret or
-- an endpoint.
--
-- Why. shared.llm_provider_connection (migration 304) knew only the LLM kinds (bedrock, anthropic, openai,
-- azure_openai, mock). Jev (TypeSafe), DataForSEO and Geoapify were configured by env vars and code constants (base
-- URL, timeout, low-balance thresholds, the daily credit limit), and Bedrock Guardrails (the CRM scrubber) nowhere.
-- ADR 0009 §2 makes them connection rows, and D9 (S261, approved) makes the secret NAME and the endpoint
-- migration-only: an admin edit (cis_app had column UPDATE on secret_name and base_url, migration 310) must never be
-- able to point a row at another kind's secret or send a key to another host.
--
-- What.
--   1. Widened / replaced CHECKs (dropped and re-added NOT VALID, then validated; every existing row passes):
--      kind      + typesafe, dataforseo, geoapify, bedrock_guardrails;
--      auth_mode per kind: typesafe / geoapify api_key, dataforseo basic_auth (login + password), bedrock_guardrails
--                task_role or assume_role (AWS credentials, no secret); the LLM kinds unchanged;
--      secret_name per kind: the LLM kinds keep ^aa-llm/<env>/<name>$; typesafe only aa-cis/<env>/typesafe, dataforseo
--                only aa-cis/<env>/dataforseo, geoapify only aa-cis/<env>/geoapify (each kind its own secret, today's
--                names); bedrock_guardrails none (task_role CHECK of 304);
--      base_url  per kind host: anthropic api.anthropic.com, openai api.openai.com, azure_openai <resource>.openai.
--                azure.com, typesafe api.typesafe.ai, dataforseo api.dataforseo.com, geoapify api.geoapify.com
--                (https, no port, no query: the 304 shape); bedrock, mock and bedrock_guardrails take none. Until now
--                the host list lived only in code (connections.BASE_URL_ALLOWLIST);
--      credential_env: still only OPENAI_API_KEY, and now only on an openai row (the code rule of S2, in the DB);
--      key_source: basic_auth needs a secret like api_key when enabled.
--   2. New columns (nullable or with a constant default; a catalog-only change on a 5-row table):
--      failure_domain (the payer / account / scope that can block the row; backfilled with the derivation the
--      AA-1018 report uses today: <kind>:<account_id | account_id_env | connection_key>:<data_scope>),
--      served_roles text[] (the roles it may serve: writer, judge, validate, embed, decide, data, guard; backfilled:
--      assume-role Bedrock all four LLM roles, task-role Bedrock (acc2) embed + judge + validate per the tech lead's
--      S261 decision, vendor APIs writer + judge + validate; NOT read for routing yet: no route changes),
--      access_state (unknown | ok | access_denied | quota_exhausted | unconfigured, default unknown; written by the
--      breaker / probe in AA-1018 part 2), last_probe_at, balance_source (none | provider_api | topups_minus_spend |
--      daily_credit_window | cost_explorer), daily_credit_limit, low_balance_usd.
--   3. Seed rows (ON CONFLICT DO NOTHING, an existing row is never overwritten), with today's values so nothing
--      changes: typesafe (Jev; https://api.typesafe.ai, timeout 3 s, 2 retries = 3 attempts, low balance 3 USD,
--      secret aa-cis/dev/typesafe), dataforseo (https://api.dataforseo.com/v3, low balance 10 USD, secret
--      aa-cis/dev/dataforseo), geoapify (https://api.geoapify.com/v1, 2,500 credits a day, secret aa-cis/dev/geoapify),
--      all three enabled (they are in use today), and bedrock-guardrails (task role, us-west-1) DISABLED. None of them
--      has a deployment row; the LLM dispatch never routes to these kinds (shared/llm_client/connections.LLM_KINDS).
--   4. Grants (D9): REVOKE cis_app UPDATE on secret_name, base_url and credential_env; GRANT cis_app UPDATE on
--      access_state, last_probe_at (the gateway writes them) and daily_credit_limit, low_balance_usd (limits stay
--      admin-editable). Identity, kind, failure_domain, served_roles and balance_source stay migration-only.
--   5. The table comment says it holds every paid provider kind (ADR 0009 §2: the wider meaning is documented, the
--      table is not renamed).
--   6. Register 322.
--
-- Behaviour. The route snapshot (S262 plan Q0) gains exactly four 'cn|' lines (the seeded rows); every LLM row, every
-- deployment, route, catalog and alias row is unchanged. The code PR that follows reads Jev's URL / timeout, the
-- Jev and DataForSEO low-balance thresholds and the Geoapify daily credit limit from these rows (env and constants
-- stay the fallback); the seeded values equal today's, so the behaviour is the same. Until that code ships, the old
-- code reads only the LLM kinds from the registry (it ignores the new rows: no deployment names them); the admin edit
-- of secret_name / base_url answers 503 "needs migration" (permission denied) instead of saving.
--
-- RISKY (auth / secrets / schema; S241 D-13): an independent review of this file is required before merge.
-- Class: contract (root ADR 0017 d3), so no "-- migrate: expand" header: replaced CHECKs, a REVOKE and seeded rows.
-- Order (ADR 0017 d1, MIG-4): (1) after 320 / 321 (their PR merges first), this migration-only PR merges to
-- AA-CIS-App main; (2) the byte copy in AA-CIS-Infra db/migrations/cis/ merges; (3) a manual DB Migrate apply of
-- 320, 321, 322; (4) the bot/db-schema-reference PR merges; (5) only then the AA-1017 code PR merges (readiness 322).
-- Secret names: unchanged (the three aa-cis/dev secrets exist and are read as today); docs/security/secrets-register
-- needs no rename.
--
-- Rollback (a NEW forward migration, after the code is reverted):
--   DELETE the four seeded rows (no FK points at them: no deployment, health, policy or reconcile row);
--   restore the 304 CHECKs (kind, auth_mode, secret_name, base_url, key_source) and the 304 credential_env CHECK;
--   GRANT UPDATE (secret_name, base_url) back to cis_app only with a new D9 decision;
--   ALTER TABLE ... DROP COLUMN for the seven columns                                            (a destructive file)
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the table's owner.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.llm_provider_connection') IS NULL THEN
        RAISE EXCEPTION 'migration 322: shared.llm_provider_connection is missing (apply 304 first)';
    END IF;
END $$;

-- ── 2. new columns (before the seeds and the CHECKs that read them) ──────────────────────────────────────────────

ALTER TABLE shared.llm_provider_connection
    ADD COLUMN IF NOT EXISTS failure_domain     text,
    ADD COLUMN IF NOT EXISTS served_roles       text[],
    ADD COLUMN IF NOT EXISTS access_state       text NOT NULL DEFAULT 'unknown',
    ADD COLUMN IF NOT EXISTS last_probe_at      timestamptz,
    ADD COLUMN IF NOT EXISTS balance_source     text,
    ADD COLUMN IF NOT EXISTS daily_credit_limit integer,
    ADD COLUMN IF NOT EXISTS low_balance_usd    numeric(10,2);

COMMENT ON COLUMN shared.llm_provider_connection.failure_domain IS
    'AA-1017 (ADR 0009 §5): who can block this row (<kind>:<account>:<data scope>). Migration-only.';
COMMENT ON COLUMN shared.llm_provider_connection.served_roles IS
    'AA-1017: the roles this row may serve (writer, judge, validate, embed, decide, data, guard). Not read for '
    'routing yet (D10 replaces llm_role_config.account_route with it). Migration-only.';
COMMENT ON COLUMN shared.llm_provider_connection.access_state IS
    'AA-1017 / AA-1018: unknown | ok | access_denied | quota_exhausted | unconfigured, from the last call or probe.';
COMMENT ON COLUMN shared.llm_provider_connection.last_probe_at IS
    'AA-1017 / AA-1018: when the last probe of this row ran.';
COMMENT ON COLUMN shared.llm_provider_connection.balance_source IS
    'AA-1017: where the remaining money is read: none | provider_api | topups_minus_spend | daily_credit_window | '
    'cost_explorer. Migration-only.';
COMMENT ON COLUMN shared.llm_provider_connection.daily_credit_limit IS
    'AA-1017: the provider credits the platform may use per UTC day (Geoapify). NULL = no daily credit limit.';
COMMENT ON COLUMN shared.llm_provider_connection.low_balance_usd IS
    'AA-1017: below this balance (USD) the low-balance alert fires (Jev, DataForSEO). NULL = the code default.';

-- ── 1. CHECKs: kind, auth mode, secret and host per kind ─────────────────────────────────────────────────────────

ALTER TABLE shared.llm_provider_connection
    DROP CONSTRAINT IF EXISTS llm_provider_connection_kind_check,
    DROP CONSTRAINT IF EXISTS llm_provider_connection_auth_mode_check,
    DROP CONSTRAINT IF EXISTS llm_provider_connection_secret_name_check,
    DROP CONSTRAINT IF EXISTS llm_provider_connection_credential_env_check,
    DROP CONSTRAINT IF EXISTS llm_provider_connection_base_url_check,
    DROP CONSTRAINT IF EXISTS llm_provider_connection_key_source_check,
    DROP CONSTRAINT IF EXISTS llm_provider_connection_failure_domain_check,
    DROP CONSTRAINT IF EXISTS llm_provider_connection_served_roles_check,
    DROP CONSTRAINT IF EXISTS llm_provider_connection_access_state_check,
    DROP CONSTRAINT IF EXISTS llm_provider_connection_balance_source_check,
    DROP CONSTRAINT IF EXISTS llm_provider_connection_daily_credit_check,
    DROP CONSTRAINT IF EXISTS llm_provider_connection_low_balance_check;

ALTER TABLE shared.llm_provider_connection
    ADD CONSTRAINT llm_provider_connection_kind_check CHECK (
        kind IN ('bedrock', 'anthropic', 'openai', 'azure_openai', 'mock',
                 'typesafe', 'dataforseo', 'geoapify', 'bedrock_guardrails')) NOT VALID,
    ADD CONSTRAINT llm_provider_connection_auth_mode_check CHECK (
        (kind = 'bedrock' AND auth_mode IN ('assume_role', 'task_role', 'bedrock_api_key'))
        OR (kind IN ('anthropic', 'openai', 'azure_openai', 'typesafe', 'geoapify') AND auth_mode = 'api_key')
        OR (kind = 'dataforseo' AND auth_mode = 'basic_auth')
        OR (kind = 'bedrock_guardrails' AND auth_mode IN ('task_role', 'assume_role'))
        OR (kind = 'mock' AND auth_mode = 'none')) NOT VALID,
    ADD CONSTRAINT llm_provider_connection_secret_name_check CHECK (
        secret_name IS NULL
        OR (kind IN ('bedrock', 'anthropic', 'openai', 'azure_openai', 'mock')
            AND secret_name ~ '^aa-llm/[a-z0-9-]+/[a-z0-9][a-z0-9-]*$')
        OR (kind = 'typesafe' AND secret_name ~ '^aa-cis/[a-z0-9-]+/typesafe$')
        OR (kind = 'dataforseo' AND secret_name ~ '^aa-cis/[a-z0-9-]+/dataforseo$')
        OR (kind = 'geoapify' AND secret_name ~ '^aa-cis/[a-z0-9-]+/geoapify$')) NOT VALID,
    ADD CONSTRAINT llm_provider_connection_credential_env_check CHECK (
        credential_env IS NULL OR (kind = 'openai' AND credential_env = 'OPENAI_API_KEY')) NOT VALID,
    ADD CONSTRAINT llm_provider_connection_base_url_check CHECK (
        base_url IS NULL
        OR (kind NOT IN ('bedrock', 'mock', 'bedrock_guardrails')
            AND base_url ~ '^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(/[A-Za-z0-9._~-]+)*/?$'
            AND ((kind = 'anthropic' AND base_url ~ '^https://api\.anthropic\.com(/|$)')
                 OR (kind = 'openai' AND base_url ~ '^https://api\.openai\.com(/|$)')
                 OR (kind = 'azure_openai' AND base_url ~ '^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?\.openai\.azure\.com(/|$)')
                 OR (kind = 'typesafe' AND base_url ~ '^https://api\.typesafe\.ai(/|$)')
                 OR (kind = 'dataforseo' AND base_url ~ '^https://api\.dataforseo\.com(/|$)')
                 OR (kind = 'geoapify' AND base_url ~ '^https://api\.geoapify\.com(/|$)')))) NOT VALID,
    ADD CONSTRAINT llm_provider_connection_key_source_check CHECK (
        auth_mode NOT IN ('api_key', 'bedrock_api_key', 'basic_auth') OR NOT enabled
        OR secret_name IS NOT NULL OR credential_env IS NOT NULL) NOT VALID,
    ADD CONSTRAINT llm_provider_connection_failure_domain_check CHECK (
        failure_domain IS NULL OR failure_domain ~ '^[A-Za-z0-9_.:-]{3,100}$') NOT VALID,
    ADD CONSTRAINT llm_provider_connection_served_roles_check CHECK (
        served_roles IS NULL OR (cardinality(served_roles) >= 1 AND served_roles <@ ARRAY[
            'writer', 'judge', 'validate', 'embed', 'decide', 'data', 'guard']::text[])) NOT VALID,
    ADD CONSTRAINT llm_provider_connection_access_state_check CHECK (
        access_state IN ('unknown', 'ok', 'access_denied', 'quota_exhausted', 'unconfigured')) NOT VALID,
    ADD CONSTRAINT llm_provider_connection_balance_source_check CHECK (
        balance_source IS NULL OR balance_source IN ('none', 'provider_api', 'topups_minus_spend',
                                                     'daily_credit_window', 'cost_explorer')) NOT VALID,
    ADD CONSTRAINT llm_provider_connection_daily_credit_check CHECK (
        daily_credit_limit IS NULL OR daily_credit_limit BETWEEN 0 AND 10000000) NOT VALID,
    ADD CONSTRAINT llm_provider_connection_low_balance_check CHECK (
        low_balance_usd IS NULL OR low_balance_usd >= 0) NOT VALID;

ALTER TABLE shared.llm_provider_connection VALIDATE CONSTRAINT llm_provider_connection_kind_check;
ALTER TABLE shared.llm_provider_connection VALIDATE CONSTRAINT llm_provider_connection_auth_mode_check;
ALTER TABLE shared.llm_provider_connection VALIDATE CONSTRAINT llm_provider_connection_secret_name_check;
ALTER TABLE shared.llm_provider_connection VALIDATE CONSTRAINT llm_provider_connection_credential_env_check;
ALTER TABLE shared.llm_provider_connection VALIDATE CONSTRAINT llm_provider_connection_base_url_check;
ALTER TABLE shared.llm_provider_connection VALIDATE CONSTRAINT llm_provider_connection_key_source_check;
ALTER TABLE shared.llm_provider_connection VALIDATE CONSTRAINT llm_provider_connection_failure_domain_check;
ALTER TABLE shared.llm_provider_connection VALIDATE CONSTRAINT llm_provider_connection_served_roles_check;
ALTER TABLE shared.llm_provider_connection VALIDATE CONSTRAINT llm_provider_connection_access_state_check;
ALTER TABLE shared.llm_provider_connection VALIDATE CONSTRAINT llm_provider_connection_balance_source_check;
ALTER TABLE shared.llm_provider_connection VALIDATE CONSTRAINT llm_provider_connection_daily_credit_check;
ALTER TABLE shared.llm_provider_connection VALIDATE CONSTRAINT llm_provider_connection_low_balance_check;

-- ── 2b. backfill the LLM rows (only where not set: a re-run keeps a later migration's value) ─────────────────────

UPDATE shared.llm_provider_connection
   SET failure_domain = kind || ':' || coalesce(account_id, account_id_env, connection_key) || ':' || data_scope
 WHERE failure_domain IS NULL;

UPDATE shared.llm_provider_connection
   SET served_roles = CASE
           WHEN kind = 'bedrock' AND auth_mode = 'task_role' THEN ARRAY['embed', 'judge', 'validate']::text[]
           WHEN kind = 'bedrock' THEN ARRAY['writer', 'judge', 'validate', 'embed']::text[]
           WHEN kind IN ('anthropic', 'openai', 'azure_openai') THEN ARRAY['writer', 'judge', 'validate']::text[]
       END
 WHERE served_roles IS NULL AND kind IN ('bedrock', 'anthropic', 'openai', 'azure_openai');

UPDATE shared.llm_provider_connection
   SET balance_source = CASE WHEN kind = 'bedrock' THEN 'cost_explorer' ELSE 'none' END
 WHERE balance_source IS NULL AND kind IN ('bedrock', 'anthropic', 'openai', 'azure_openai', 'mock');

-- ── 3. seed the decide / data / guard providers (today's values) ─────────────────────────────────────────────────

INSERT INTO shared.llm_provider_connection
    (connection_key, kind, auth_mode, label, region, secret_name, base_url, data_scope, timeout_s, max_retries,
     enabled, notes, failure_domain, served_roles, balance_source, daily_credit_limit, low_balance_usd, updated_by)
VALUES
    ('typesafe', 'typesafe', 'api_key', 'Jev (TypeSafe decisions)', NULL, 'aa-cis/dev/typesafe',
     'https://api.typesafe.ai', 'vendor_direct', 3, 2, true,
     'Jev verdicts (shared/llm_client/decide.py): base URL, timeout and retries are read from this row; credit '
     'estimate = top-ups minus logged spend (no balance API).',
     'typesafe:typesafe:vendor_direct', ARRAY['decide']::text[], 'topups_minus_spend', NULL, 3.00,
     'migration-322-aa1017'),
    ('dataforseo', 'dataforseo', 'basic_auth', 'DataForSEO', NULL, 'aa-cis/dev/dataforseo',
     'https://api.dataforseo.com/v3', 'vendor_direct', NULL, NULL, true,
     'SEO data (services/seo_intelligence): the daily balance check reads its low-balance threshold from this row.',
     'dataforseo:dataforseo:vendor_direct', ARRAY['data']::text[], 'provider_api', NULL, 10.00,
     'migration-322-aa1017'),
    ('geoapify', 'geoapify', 'api_key', 'Geoapify (geocoder)', NULL, 'aa-cis/dev/geoapify',
     'https://api.geoapify.com/v1', 'vendor_direct', NULL, NULL, true,
     'Place geocoding (services/places): the daily credit guard reads its limit from this row (Free plan 3,000/day, '
     '2,500 used, the rest kept for manual checks).',
     'geoapify:geoapify:vendor_direct', ARRAY['data']::text[], 'daily_credit_window', 2500, NULL,
     'migration-322-aa1017'),
    ('bedrock-guardrails', 'bedrock_guardrails', 'task_role', 'Bedrock Guardrails (CRM scrub)', 'us-west-1', NULL,
     NULL, 'aws_only', NULL, NULL, false,
     'Off: the CRM scrubber (AA-Partner) runs on its stub; enabling Guardrails is a paid feature and a separate '
     'decision. Described here so its cost and access have a row.',
     'bedrock_guardrails:bedrock-guardrails:aws_only', ARRAY['guard']::text[], 'cost_explorer', NULL, NULL,
     'migration-322-aa1017')
ON CONFLICT (connection_key) DO NOTHING;

-- ── 4. grants (D9) ───────────────────────────────────────────────────────────────────────────────────────────────

REVOKE UPDATE (secret_name, base_url, credential_env) ON shared.llm_provider_connection FROM cis_app;
GRANT UPDATE (access_state, last_probe_at, daily_credit_limit, low_balance_usd)
    ON shared.llm_provider_connection TO cis_app;

-- ── 5. table comment ─────────────────────────────────────────────────────────────────────────────────────────────

COMMENT ON TABLE shared.llm_provider_connection IS
    'AA-1002 / AA-1017 (ADR 0009 §2): one way into a paid provider: an LLM (bedrock, anthropic, openai, azure_openai, '
    'mock), a decision service (typesafe), a data provider (dataforseo, geoapify) or a guard (bedrock_guardrails). A '
    'secret NAME only, guarded per kind; the secret name and endpoint change by migration only (D9). The LLM dispatch '
    'uses only the LLM kinds.';

-- ── 6. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('322', now(), 'AA-1017 provider connection v2: typesafe / dataforseo / geoapify / bedrock_guardrails kinds, '
                      'per-kind secret and host CHECKs, failure_domain, served_roles, access_state, limits; D9 revoke')
ON CONFLICT (version) DO NOTHING;

COMMIT;
