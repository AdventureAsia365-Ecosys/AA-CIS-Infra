-- Migration 324: AA-1017 (AI gateway v2, registry v2) — five candidate chat models on the acc2 Bedrock connection,
-- as catalog + deployment rows only: the "add a model = one migration PR + DB Migrate, no app code" proof.
--
-- Why. acc3 (the LLM account) refuses every model since 29/10 (Error 002) and acc2 refuses Claude and GPT (channel
-- program account). A real call from acc2 on 31/10/2026 (root docs/audits/2026-10-31-S261-aws-bedrock-org-access/
-- model-access-matrix-2026-10-31.md, acc2 column) answered for Amazon Nova Lite / Nova 2 Lite, Meta Llama 4
-- Maverick / Scout and Moonshot Kimi K3. Registry v2 (migration 320) made the maker a data row (families amazon, meta,
-- moonshot are seeded there), so these models can be catalogued without touching gateway code: the acc2 connection
-- (task role, Converse through bedrock_satellite.native_runtime) already serves any converse row.
--
-- What.
--   1. Five shared.llm_model_catalog rows, provider bedrock, api_style converse, callable_via {llm_client}, enabled,
--      capabilities {} (unknown = today's code rules: no cachePoint for a non-Anthropic profile, forced tool choice
--      tried and remembered as rejected at runtime), max_output_tokens NULL (call sites send 4096 at most today;
--      shared.stage_model_params can cap a stage later):
--        nova-lite        Amazon Nova Lite         us.amazon.nova-lite-v1:0
--        nova-2-lite      Amazon Nova 2 Lite       us.amazon.nova-2-lite-v1:0
--        llama4-maverick  Meta Llama 4 Maverick    us.meta.llama4-maverick-17b-instruct-v1:0
--        llama4-scout     Meta Llama 4 Scout       us.meta.llama4-scout-17b-instruct-v1:0
--        kimi-k3          Moonshot Kimi K3         us.moonshotai.kimi-k3   (a reasoning model: no temperature)
--      bedrock_profile_ids names the acc2 profile only ({"acc2": "<us. profile>"}), the form of the existing acc2
--      rows (cohere-embed-v4, haiku): an inference-profile id, never an ARN or an account ID.
--      Prices (USD per 1M tokens, on-demand standard tier, US cross-region profile billed in the source region US West
--      (N. California)): AWS Price List API, offer AmazonBedrock, version 20261030160456, region us-west-1 (the data
--      behind https://aws.amazon.com/bedrock/pricing/), read 31/10/2026:
--        Nova Lite          in 0.077  out 0.308                                (USW1-NovaLite-*-tokens)
--        Nova 2 Lite        in 0.429  out 3.351  cache read 0.10725 (0.1073)   (USW1-Nova2.0Lite-*)
--        Llama 4 Maverick   in 0.24   out 0.97                                 (USW1-Llama4-Maverick-17B-*-tokens)
--        Llama 4 Scout      in 0.17   out 0.66                                 (USW1-Llama4-Scout-17B-*-tokens)
--        Kimi K3            in 3.30   out 16.50  cache read 0.33, write 4.125  (USW1-moonshotai.kimi-k3-mantle-*-
--                                                                             standard; "US CRIS" on the page)
--      Not added: Amazon Nova Micro (the price list has no us-west-1 entry and the 31/10 access matrix did not test
--      it), Nova Pro (Nova 2 Lite answers at a lower price), Z.AI / xAI / Writer (refused on acc2).
--   2. Five shared.llm_model_deployment rows on connection acc2: wire_id = the catalog profile, priority 20 (the
--      acc2 rank of migration 304), enabled, origin bedrock_profile, request_defaults {}.
--   3. Guard: no shared.llm_role_config row (route, fallback, shadow) and no shared.llm_model_alias row names a new
--      key, so no stage changes model. A stage uses one of them only after a separate route change (approval + a
--      paid trial, AA-900 ladder).
--   4. Register 324.
--
-- Behaviour. No stage, alias or route changes (guard 3). The route snapshot (S262 plan Q0) gains exactly ten lines:
-- five 'ct|' and five 'dp|'. What does see the new rows: the admin AI providers page (catalog / deployments lists),
-- POST /admin/llm-connections/acc2/test without a model_key (it picks the cheapest enabled text deployment of acc2:
-- nova-lite instead of "nothing testable"), the failure-domain report (invariant.py: acc2 now has funded converse
-- deployments) and the daily probe when LLM_DAILY_PROBE is switched on (off on Dev).
--
-- Class: contract (root ADR 0017 d3: INSERT into existing routing tables), so no "-- migrate: expand" header and MIG-4
-- order: (1) this migration-only PR merges to AA-CIS-App main after 320-323; (2) the byte copy in AA-CIS-Infra
-- db/migrations/cis/ merges (Copy Guard green); (3) a manual DB Migrate apply (check, then apply); (4) the
-- bot/db-schema-reference PR merges. No code PR depends on it (no readiness bump: nothing reads these keys by name).
--
-- Rollback (a NEW forward migration): DELETE the five deployment rows, then the five catalog rows (no health, alias,
-- stage-param or route row points at them unless someone tested them: delete those llm_provider_health rows first).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of both tables.
-- Grants: none (existing tables; cis_app keeps what 304 / 310 gave it).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '320') THEN
        RAISE EXCEPTION 'migration 324: apply 320 first (model families amazon / meta / moonshot)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_provider_connection
                    WHERE connection_key = 'acc2' AND kind = 'bedrock' AND auth_mode = 'task_role') THEN
        RAISE EXCEPTION 'migration 324: connection acc2 (bedrock, task_role) is missing';
    END IF;
END $$;

-- ── 1. catalog rows ──────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.llm_model_catalog
    (model_key, label, vendor, family, provider, api_style, bedrock_profile_ids, wire_model, callable_via,
     supports_temperature, max_output_tokens, price_in_per_mtok, price_out_per_mtok, price_cache_read_per_mtok,
     price_cache_write_per_mtok, price_source, enabled, blocked_reason, notes, capabilities, updated_by)
VALUES
    ('nova-lite', 'Amazon Nova Lite', 'amazon', 'amazon', 'bedrock', 'converse',
     '{"acc2": "us.amazon.nova-lite-v1:0"}'::jsonb, NULL, ARRAY['llm_client'], true, NULL,
     0.0770, 0.3080, NULL, NULL,
     'AWS Price List API AmazonBedrock 20261030160456, us-west-1 on-demand (aws.amazon.com/bedrock/pricing), 31/10/2026',
     true, NULL, 'acc2 trial candidate (AA-1017 migration 324); answered on acc2 31/10/2026. No stage routes to it.',
     '{}'::jsonb, 'migration-324-aa1017'),
    ('nova-2-lite', 'Amazon Nova 2 Lite', 'amazon', 'amazon', 'bedrock', 'converse',
     '{"acc2": "us.amazon.nova-2-lite-v1:0"}'::jsonb, NULL, ARRAY['llm_client'], true, NULL,
     0.4290, 3.3510, 0.1073, NULL,
     'AWS Price List API AmazonBedrock 20261030160456, us-west-1 on-demand (aws.amazon.com/bedrock/pricing), 31/10/2026',
     true, NULL, 'acc2 trial candidate (AA-1017 migration 324); answered on acc2 31/10/2026. No stage routes to it.',
     '{}'::jsonb, 'migration-324-aa1017'),
    ('llama4-maverick', 'Meta Llama 4 Maverick', 'meta', 'meta', 'bedrock', 'converse',
     '{"acc2": "us.meta.llama4-maverick-17b-instruct-v1:0"}'::jsonb, NULL, ARRAY['llm_client'], true, NULL,
     0.2400, 0.9700, NULL, NULL,
     'AWS Price List API AmazonBedrock 20261030160456, us-west-1 on-demand (aws.amazon.com/bedrock/pricing), 31/10/2026',
     true, NULL, 'acc2 trial candidate (AA-1017 migration 324); answered on acc2 31/10/2026 (inference profile only). '
                 'No stage routes to it.',
     '{}'::jsonb, 'migration-324-aa1017'),
    ('llama4-scout', 'Meta Llama 4 Scout', 'meta', 'meta', 'bedrock', 'converse',
     '{"acc2": "us.meta.llama4-scout-17b-instruct-v1:0"}'::jsonb, NULL, ARRAY['llm_client'], true, NULL,
     0.1700, 0.6600, NULL, NULL,
     'AWS Price List API AmazonBedrock 20261030160456, us-west-1 on-demand (aws.amazon.com/bedrock/pricing), 31/10/2026',
     true, NULL, 'acc2 trial candidate (AA-1017 migration 324); answered on acc2 31/10/2026 (inference profile only). '
                 'No stage routes to it.',
     '{}'::jsonb, 'migration-324-aa1017'),
    ('kimi-k3', 'Moonshot Kimi K3', 'moonshot', 'moonshot', 'bedrock', 'converse',
     '{"acc2": "us.moonshotai.kimi-k3"}'::jsonb, NULL, ARRAY['llm_client'], false, NULL,
     3.3000, 16.5000, 0.3300, 4.1250,
     'AWS Price List API AmazonBedrock 20261030160456, us-west-1 on-demand, US cross-region (aws.amazon.com/bedrock/'
     'pricing), 31/10/2026',
     true, NULL, 'acc2 trial candidate (AA-1017 migration 324); answered on acc2 31/10/2026. A reasoning model: a short '
                 'max_tokens is spent on thinking (test with 512). No stage routes to it.',
     '{}'::jsonb, 'migration-324-aa1017')
ON CONFLICT (model_key) DO NOTHING;

-- ── 2. deployment rows (acc2, task role) ─────────────────────────────────────────────────────────────────────────

INSERT INTO shared.llm_model_deployment
    (model_key, connection_key, wire_id, priority, enabled, origin, notes, updated_by)
SELECT m.model_key, 'acc2', m.bedrock_profile_ids ->> 'acc2', 20, true, 'bedrock_profile',
       'acc2 trial candidate (Converse on the task role). No stage routes to it.', 'migration-324-aa1017'
  FROM shared.llm_model_catalog m
 WHERE m.model_key IN ('nova-lite', 'nova-2-lite', 'llama4-maverick', 'llama4-scout', 'kimi-k3')
   AND m.updated_by = 'migration-324-aa1017'
ON CONFLICT (model_key, connection_key) DO NOTHING;

-- ── 3. guard: catalogued and deployable, never routed ────────────────────────────────────────────────────────────

DO $$
DECLARE
    keys   text[] := ARRAY['nova-lite', 'nova-2-lite', 'llama4-maverick', 'llama4-scout', 'kimi-k3'];
    n      int;
    routed text;
BEGIN
    SELECT count(*) INTO n
      FROM shared.llm_model_catalog m
      JOIN shared.llm_model_deployment d ON d.model_key = m.model_key AND d.connection_key = 'acc2'
     WHERE m.model_key = ANY (keys) AND m.enabled AND d.enabled
       AND d.wire_id = m.bedrock_profile_ids ->> 'acc2' AND coalesce(m.family, m.vendor) = m.vendor;
    IF n <> 5 THEN
        RAISE EXCEPTION 'migration 324: expected 5 enabled catalog + acc2 deployment pairs, found % (a key already '
                        'existed with other values?)', n;
    END IF;

    SELECT string_agg(stage, ', ' ORDER BY stage) INTO routed
      FROM shared.llm_role_config
     WHERE model_id = ANY (keys) OR fallback_model_ids && keys OR shadow_model_id = ANY (keys);
    IF routed IS NOT NULL THEN
        RAISE EXCEPTION 'migration 324: stages already route to a candidate model: % (route changes are separate)',
                        routed;
    END IF;
    SELECT string_agg(alias_key || '->' || model_key, ', ' ORDER BY alias_key, position) INTO routed
      FROM shared.llm_model_alias
     WHERE model_key = ANY (keys);
    IF routed IS NOT NULL THEN
        RAISE EXCEPTION 'migration 324: aliases point at a candidate model: %', routed;
    END IF;
END $$;

-- ── 4. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('324', now(), 'AA-1017 five acc2 candidate chat models (Nova Lite, Nova 2 Lite, Llama 4 Maverick / Scout, '
                      'Kimi K3) as catalog + acc2 deployment rows; no route')
ON CONFLICT (version) DO NOTHING;

COMMIT;
