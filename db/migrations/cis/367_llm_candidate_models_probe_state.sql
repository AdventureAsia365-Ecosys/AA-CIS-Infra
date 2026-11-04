-- Migration 367: AA-1026 (S267, tech lead: "every stage must always have a model that answers") — the acc3 candidate
-- models as DISABLED catalog + deployment rows, and a per-deployment probe state the availability sweep writes.
--
-- Why. Since 29/10 the LLM account (acc3) refuses part of its catalogue: Claude 5.x, GPT-5.6, GPT-6 Astra, Grok and GLM
-- 5.3 have their Bedrock token quota forced to 0, GPT-6 Luna answers "not available" (AWS case open), while Claude
-- Sonnet 4.6, Haiku 4.5 and Cohere Embed v4 still answer. The tech lead asked for the list of feasible models, a $0-when-
-- refused call to each, and an alarm when a stage has no model that answers. This file is the data half: the models the
-- sweep may call, and where it writes what it saw. The code half (the sweep mode of services/jobs/llm_probe_job.py and
-- the stage coverage check) is a separate PR deployed after this apply.
--
-- What.
--   1. shared.llm_model_deployment gains the last probe outcome of each deployment (the connection already has its own
--      access_state / last_probe_at, migration 322):
--        access_state      text NOT NULL DEFAULT 'unknown': unknown | ok | access_denied | quota_exhausted | throttled |
--                          unconfigured | error (the breaker classes of the probe's answer; 'unconfigured' = the key
--                          could not be read, 'error' = any other failure);
--        last_probe_at     timestamptz: when the sweep or the daily probe last called this deployment;
--        last_probe_error  text (<= 300 characters): the provider's answer when it failed, ARNs / account IDs masked by
--                          the writer (errors.redact_ids), NULL after a success.
--      cis_app gets UPDATE on these three columns only (the probe job runs on the worker as cis_app). A disabled
--      candidate's probe never counts on the circuit breaker (shared.llm_provider_health): two refused candidates would
--      otherwise trip acc3's connection circuit and pause the models that still answer. Its outcome lives here.
--   2. Six DISABLED catalog rows (enabled false, blocked_reason says why), provider bedrock, api_style converse,
--      callable_via {llm_client}, capabilities {} (unknown = today's code rules), one acc3 global profile each.
--      Prices, USD per 1M tokens, Global cross-region on-demand standard tier billed in US West (N. California): AWS
--      Price List API, offer AmazonBedrockFoundationModels (the Marketplace "Amazon Bedrock Edition" products), region
--      us-west-1, read 04/11/2026 (usage types USW1-MP:USW1_*TokenCount_Global-Units):
--        sonnet-4-5     Claude Sonnet 4.5   global.anthropic.claude-sonnet-4-5-20250929-v1:0  in 3.00  out 15.00
--                                                                           cache read 0.30  cache write 3.75
--        opus-4-5       Claude Opus 4.5     global.anthropic.claude-opus-4-5-20251101-v1:0    in 5.00  out 25.00
--                                                                           cache read 0.50  cache write 6.25
--        opus-4-6       Claude Opus 4.6     global.anthropic.claude-opus-4-6-v1               in 5.00  out 25.00
--                                                                           cache read 0.50  cache write 6.25
--        gpt-6-sol      GPT-6 Sol           global.openai.gpt-6-sol           UNPRICED
--        gpt-6.1-sol    GPT-6.1 Sol         global.openai.gpt-6.1-sol         UNPRICED
--        gpt-6.1-terra  GPT-6.1 Terra       global.openai.gpt-6.1-terra       UNPRICED
--      UNPRICED: neither AmazonBedrock nor AmazonBedrockFoundationModels lists GPT-6 Sol / 6.1 Sol / 6.1 Terra for
--      us-west-1 on 04/11/2026 (only GPT-6 Astra). The rows stay without a price (the enabled_needs_price CHECK keeps
--      them disabled until one is set) and price_source says so; the sweep reports them as unpriced.
--      The profiles are the ones acc3 lists in us-west-1 (bedrock list-inference-profiles, 04/11/2026), with the
--      quota acc3 has on them (service quotas, applied = AWS default, > 0). Sonnet 4.5 is LEGACY in the model list.
--      Not added: Amazon Nova 2 Pro and Nova 2 Omni (acc3 has a quota but no inference profile in us-west-1 or
--      us-west-2, so there is no wire id to call).
--   3. Eight DISABLED shared.llm_model_deployment rows on connection acc3 (origin seed, enabled false):
--        the six models above, priority 10, wire_id = the catalog profile;
--        kimi-k3          global.moonshotai.kimi-k3                  priority 30 (acc2's row, 20, stays first), price
--                         overrides from the same price list, offer AmazonBedrock (USW1-moonshotai.kimi-k3-mantle-*-
--                         global-standard): in 3.00 out 15.00 cache read 0.30 cache write 3.75 (the catalog row holds
--                         the US cross-region price 3.30 / 16.50 of its acc2 row);
--        llama4-maverick  us.meta.llama4-maverick-17b-instruct-v1:0  priority 30 (acc2 first; the catalog price is the
--                         same US cross-region profile).
--      The existing kimi-k3 / llama4-maverick catalog rows are not touched (their bedrock_profile_ids keep acc2 only):
--      enabling one of these two acc3 deployments needs the catalog's acc3 profile too (the wire drift test).
--   4. Guards: no route (primary, fallback, shadow) and no alias names a new catalog key; every row of 2 and 3 is
--      disabled with its expected wire id.
--   5. Register 367.
--
-- Not here (followups): an acc3 us-west-2 connection for the on-demand models there (DeepSeek V3.2, Mistral Large 3,
-- Qwen3 235B, gpt-oss-120b): the gateway handles a region per connection already (acc2-usw2, migration 329), but the
-- acc3 invoker role allows named model ARNs only, so it needs a Terraform change on acc3 first.
--
-- IAM. The acc3 invoker role (AA-CIS-Infra accounts/acc3-bedrock/main.tf) allows named models only. The same change
-- set adds a statement for these eight profiles; until it is applied on acc3 a probe of them answers AccessDenied (IAM),
-- not the account's own model access. Apply it before the live sweep.
--
-- Behaviour. No stage, alias or route changes (guard 4); every new row is disabled, so the gateway never calls them
-- (vendor_route.deployment_plan keeps enabled deployments of enabled models on enabled connections). What sees them:
-- the admin AI providers page (catalog / deployment lists, "Test connection" with a model key) and the availability
-- sweep (llm_probe_job, mode candidates), which calls disabled deployments on purpose. The daily probe skips them.
-- The S262 route snapshot gains six 'ct|' and eight 'dp|' lines; the deployment columns are not in it.
--
-- Class: contract (root ADR 0017: ALTER of an existing table, a column grant, INSERTs into routing tables), so no
-- migrate directive line and MIG-4 order: (1) this migration-only PR merges to AA-CIS-App main; (2) the byte copy in
-- AA-CIS-Infra db/migrations/cis/ merges (Copy Guard green); (3) Infra Migration Apply applies it once every job table
-- is idle (root ADR 0017a); (4) the bot/db-schema-reference PR merges; (5) then the code PR. The code reads and writes
-- the new columns only when they exist (it falls back without them), so the order is a safety margin, not a hard
-- dependency.
--
-- Rollback (a NEW forward migration): DELETE the eight deployment rows (updated_by 'migration-367-aa1026') and their
-- llm_provider_health rows if any, then the six catalog rows; REVOKE UPDATE (access_state, last_probe_at,
-- last_probe_error) ON shared.llm_model_deployment FROM cis_app; DROP the three columns (no view reads them).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical. After the
-- apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).
--
-- X1. One BEGIN … COMMIT block, no role switch. The runner applies cis/ files as cis_owner, the owner of every table
-- here. No dynamic SQL.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '324') THEN
        RAISE EXCEPTION 'migration 367: apply 324 first (the kimi-k3 / llama4-maverick catalog rows)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_provider_connection
                    WHERE connection_key = 'acc3' AND kind = 'bedrock' AND auth_mode = 'assume_role') THEN
        RAISE EXCEPTION 'migration 367: connection acc3 (bedrock, assume_role) is missing';
    END IF;
END $$;

-- ── 1. the per-deployment probe state ────────────────────────────────────────────────────────────────────────────

ALTER TABLE shared.llm_model_deployment
    ADD COLUMN IF NOT EXISTS access_state     text NOT NULL DEFAULT 'unknown',
    ADD COLUMN IF NOT EXISTS last_probe_at    timestamptz,
    ADD COLUMN IF NOT EXISTS last_probe_error text;

ALTER TABLE shared.llm_model_deployment
    DROP CONSTRAINT IF EXISTS llm_model_deployment_access_state_check,
    DROP CONSTRAINT IF EXISTS llm_model_deployment_probe_error_check;
ALTER TABLE shared.llm_model_deployment
    ADD CONSTRAINT llm_model_deployment_access_state_check CHECK (
        access_state IN ('unknown', 'ok', 'access_denied', 'quota_exhausted', 'throttled', 'unconfigured', 'error')),
    ADD CONSTRAINT llm_model_deployment_probe_error_check CHECK (
        last_probe_error IS NULL OR length(last_probe_error) <= 300);

COMMENT ON COLUMN shared.llm_model_deployment.access_state IS
    'AA-1026 (CIS 367): what the last probe of this deployment answered (llm_probe_job: daily probe or availability '
    'sweep): unknown | ok | access_denied | quota_exhausted | throttled | unconfigured | error. Not a switch: routing '
    'reads enabled and the breaker (llm_provider_health); the stage coverage check reads this as evidence.';
COMMENT ON COLUMN shared.llm_model_deployment.last_probe_at IS
    'AA-1026 (CIS 367): when the probe last called this deployment (NULL = never).';
COMMENT ON COLUMN shared.llm_model_deployment.last_probe_error IS
    'AA-1026 (CIS 367): the provider answer of the last failed probe (<= 300 chars, ARNs / account IDs masked); NULL '
    'after a success.';

GRANT UPDATE (access_state, last_probe_at, last_probe_error) ON shared.llm_model_deployment TO cis_app;

-- ── 2. catalog rows (disabled candidates) ────────────────────────────────────────────────────────────────────────

INSERT INTO shared.llm_model_catalog
    (model_key, label, vendor, family, provider, api_style, bedrock_profile_ids, wire_model, callable_via,
     supports_temperature, max_output_tokens, price_in_per_mtok, price_out_per_mtok, price_cache_read_per_mtok,
     price_cache_write_per_mtok, price_source, enabled, blocked_reason, notes, capabilities, updated_by)
VALUES
    ('sonnet-4-5', 'Claude Sonnet 4.5', 'anthropic', 'anthropic', 'bedrock', 'converse',
     '{"acc3": "global.anthropic.claude-sonnet-4-5-20250929-v1:0"}'::jsonb, NULL, ARRAY['llm_client'], true, NULL,
     3.0000, 15.0000, 0.3000, 3.7500,
     'AWS Price List API AmazonBedrockFoundationModels, us-west-1 Global cross-region, read 04/11/2026',
     false, 'Candidate (CIS 367): not routed. Enable after the availability sweep answers and an approved trial.',
     'acc3 candidate (AA-1026 S267 availability matrix). LEGACY in the acc3 model list (04/11/2026).',
     '{}'::jsonb, 'migration-367-aa1026'),
    ('opus-4-5', 'Claude Opus 4.5', 'anthropic', 'anthropic', 'bedrock', 'converse',
     '{"acc3": "global.anthropic.claude-opus-4-5-20251101-v1:0"}'::jsonb, NULL, ARRAY['llm_client'], true, NULL,
     5.0000, 25.0000, 0.5000, 6.2500,
     'AWS Price List API AmazonBedrockFoundationModels, us-west-1 Global cross-region, read 04/11/2026',
     false, 'Candidate (CIS 367): not routed. Enable after the availability sweep answers and an approved trial.',
     'acc3 candidate (AA-1026 S267 availability matrix).',
     '{}'::jsonb, 'migration-367-aa1026'),
    ('opus-4-6', 'Claude Opus 4.6', 'anthropic', 'anthropic', 'bedrock', 'converse',
     '{"acc3": "global.anthropic.claude-opus-4-6-v1"}'::jsonb, NULL, ARRAY['llm_client'], false, NULL,
     5.0000, 25.0000, 0.5000, 6.2500,
     'AWS Price List API AmazonBedrockFoundationModels, us-west-1 Global cross-region, read 04/11/2026',
     false, 'Candidate (CIS 367): not routed. Enable after the availability sweep answers and an approved trial.',
     'acc3 candidate (AA-1026 S267 availability matrix). Temperature support not verified: none is sent.',
     '{}'::jsonb, 'migration-367-aa1026'),
    ('gpt-6-sol', 'GPT-6 Sol (Bedrock)', 'openai', 'openai', 'bedrock', 'converse',
     '{"acc3": "global.openai.gpt-6-sol"}'::jsonb, NULL, ARRAY['llm_client'], false, NULL,
     NULL, NULL, NULL, NULL,
     'UNPRICED: no us-west-1 entry in the AWS Price List (AmazonBedrock, AmazonBedrockFoundationModels) on 04/11/2026',
     false, 'Candidate (CIS 367), unpriced: cannot be enabled before a price is set. Not routed.',
     'acc3 candidate (AA-1026 S267 availability matrix). A reasoning model: no temperature.',
     '{}'::jsonb, 'migration-367-aa1026'),
    ('gpt-6.1-sol', 'GPT-6.1 Sol (Bedrock)', 'openai', 'openai', 'bedrock', 'converse',
     '{"acc3": "global.openai.gpt-6.1-sol"}'::jsonb, NULL, ARRAY['llm_client'], false, NULL,
     NULL, NULL, NULL, NULL,
     'UNPRICED: no us-west-1 entry in the AWS Price List (AmazonBedrock, AmazonBedrockFoundationModels) on 04/11/2026',
     false, 'Candidate (CIS 367), unpriced: cannot be enabled before a price is set. Not routed.',
     'acc3 candidate (AA-1026 S267 availability matrix). A reasoning model: no temperature.',
     '{}'::jsonb, 'migration-367-aa1026'),
    ('gpt-6.1-terra', 'GPT-6.1 Terra (Bedrock)', 'openai', 'openai', 'bedrock', 'converse',
     '{"acc3": "global.openai.gpt-6.1-terra"}'::jsonb, NULL, ARRAY['llm_client'], false, NULL,
     NULL, NULL, NULL, NULL,
     'UNPRICED: no us-west-1 entry in the AWS Price List (AmazonBedrock, AmazonBedrockFoundationModels) on 04/11/2026',
     false, 'Candidate (CIS 367), unpriced: cannot be enabled before a price is set. Not routed.',
     'acc3 candidate (AA-1026 S267 availability matrix). A reasoning model: no temperature.',
     '{}'::jsonb, 'migration-367-aa1026')
ON CONFLICT (model_key) DO NOTHING;

-- ── 3. deployment rows on acc3 (disabled) ────────────────────────────────────────────────────────────────────────

INSERT INTO shared.llm_model_deployment
    (model_key, connection_key, wire_id, priority, enabled, origin, notes, updated_by)
SELECT m.model_key, 'acc3', m.bedrock_profile_ids ->> 'acc3', 10, false, 'seed',
       'acc3 candidate (CIS 367, disabled): called only by the availability sweep. No stage routes to it.',
       'migration-367-aa1026'
  FROM shared.llm_model_catalog m
 WHERE m.model_key IN ('sonnet-4-5', 'opus-4-5', 'opus-4-6', 'gpt-6-sol', 'gpt-6.1-sol', 'gpt-6.1-terra')
   AND m.updated_by = 'migration-367-aa1026'
ON CONFLICT (model_key, connection_key) DO NOTHING;

INSERT INTO shared.llm_model_deployment
    (model_key, connection_key, wire_id, priority, enabled, price_in_override, price_out_override,
     price_cache_read_override, price_cache_write_override, origin, notes, updated_by)
VALUES
    ('kimi-k3', 'acc3', 'global.moonshotai.kimi-k3', 30, false, 3.0000, 15.0000, 0.3000, 3.7500, 'seed',
     'acc3 candidate (CIS 367, disabled), Global profile price (AWS Price List AmazonBedrock, us-west-1, 04/11/2026). '
     'acc2 stays first (priority 20). Enabling it needs the catalog acc3 profile too.',
     'migration-367-aa1026'),
    ('llama4-maverick', 'acc3', 'us.meta.llama4-maverick-17b-instruct-v1:0', 30, false, NULL, NULL, NULL, NULL, 'seed',
     'acc3 candidate (CIS 367, disabled), the US cross-region profile (catalog price). acc2 stays first (priority '
     '20). Enabling it needs the catalog acc3 profile too.',
     'migration-367-aa1026')
ON CONFLICT (model_key, connection_key) DO NOTHING;

-- ── 4. guards ────────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    keys   text[] := ARRAY['sonnet-4-5', 'opus-4-5', 'opus-4-6', 'gpt-6-sol', 'gpt-6.1-sol', 'gpt-6.1-terra'];
    n      int;
    routed text;
BEGIN
    SELECT count(*) INTO n
      FROM shared.llm_model_catalog m
      JOIN shared.llm_model_deployment d ON d.model_key = m.model_key AND d.connection_key = 'acc3'
     WHERE m.model_key = ANY (keys) AND NOT m.enabled AND NOT d.enabled
       AND d.wire_id = m.bedrock_profile_ids ->> 'acc3' AND m.api_style = 'converse';
    IF n <> 6 THEN
        RAISE EXCEPTION 'migration 367: expected 6 disabled catalog + acc3 deployment pairs, found % (a key already '
                        'existed with other values?)', n;
    END IF;

    SELECT count(*) INTO n
      FROM shared.llm_model_deployment
     WHERE connection_key = 'acc3' AND NOT enabled
       AND (model_key, wire_id) IN (('kimi-k3', 'global.moonshotai.kimi-k3'),
                                    ('llama4-maverick', 'us.meta.llama4-maverick-17b-instruct-v1:0'));
    IF n <> 2 THEN
        RAISE EXCEPTION 'migration 367: expected the disabled kimi-k3 / llama4-maverick acc3 deployments, found %', n;
    END IF;

    SELECT string_agg(stage, ', ' ORDER BY stage) INTO routed
      FROM shared.llm_role_config
     WHERE model_id = ANY (keys) OR fallback_model_ids && keys OR shadow_model_id = ANY (keys);
    IF routed IS NOT NULL THEN
        RAISE EXCEPTION 'migration 367: stages already route to a candidate model: % (route changes are separate)',
                        routed;
    END IF;
    SELECT string_agg(alias_key || '->' || model_key, ', ' ORDER BY alias_key, position) INTO routed
      FROM shared.llm_model_alias
     WHERE model_key = ANY (keys);
    IF routed IS NOT NULL THEN
        RAISE EXCEPTION 'migration 367: aliases point at a candidate model: %', routed;
    END IF;
END $$;

-- ── 5. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('367', now(), 'AA-1026 acc3 candidate models (Claude Sonnet 4.5, Opus 4.5 / 4.6, GPT-6 Sol, GPT-6.1 Sol / '
                      'Terra; Kimi K3 and Llama 4 Maverick on acc3) as disabled catalog + deployment rows, and the '
                      'per-deployment probe state (access_state, last_probe_at, last_probe_error)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
