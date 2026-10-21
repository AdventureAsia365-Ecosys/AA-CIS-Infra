-- Migration 259: AA-803 (S246) — Claude Haiku 5.5 and Claude Sonnet 5.5 in the model catalog; the
-- legacy 'sonnet' row stops naming the LEGACY Sonnet 4.5 profile on acc2.
--
-- Why. The S246 Bedrock check (root repo docs/audits/2026-10-21-S246-bedrock-models/) lists
-- anthropic.claude-haiku-5-5 and anthropic.claude-sonnet-5-5 as ACTIVE inference profiles on acc1, acc2
-- and acc3. Neither is in the catalog, so no stage can be trialled on them: 9 stages run Haiku 4.5
-- ($1 / $5 per MTok) and 8 run Sonnet 4.6 ($3 / $15). The admin catalog PATCH only edits price /
-- enabled (catalog.py _CATALOG_EDITABLE_FIELDS): a new row and its profile ids are a migration.
--
-- New rows (Converse adapter, the same path as sonnet-5 / opus-5-5):
--   * haiku-5-5   {"acc3", "acc1": "global.anthropic.claude-haiku-5-5"}   0.10 / 0.50, cache 0.01 / 0.125
--   * sonnet-5-5  {"acc3", "acc1": "global.anthropic.claude-sonnet-5-5"}  2.00 / 10.00, cache 0.20 / 2.50
-- Prices are Anthropic's first-party list prices (Haiku 5.5: prompts up to 100K tokens; $0.50 / $2.50
-- beyond, which the catalog cannot express — no stage sends prompts that long). Claude on Bedrock is
-- partner-priced: price_source says so, and the AWS Bedrock pricing page must confirm before a stage is
-- moved (admin PATCH price_in/out + price_source, no migration needed). Cache write = 1.25x input (5-min
-- TTL), cache read = 0.1x input, as pricing.py derives for the other Claude rows.
-- supports_temperature = false: both models reject a non-default temperature / top_p with a 400 (the
-- gateway then leaves temperature out, as for sonnet-5 since migration 227).
-- max_output_tokens = 128000 (the models' documented output cap; the gateway sends min(request, cap)).
-- No acc2 profile: acc2 is a channel-program account and every Claude call there is refused
-- (AA-843). The gateway's Converse path never calls acc2 anyway (client.py _call_catalog_model).
-- enabled = true, on no route: nothing calls them until a stage route or eval names them. Run the S246
-- smoke script (one tiny call per model and account through LLMClient.generate(), stage
-- adhoc_s246_models) before routing a stage; if an account refuses, PATCH enabled=false and say why.
--
-- Gateway behaviour these rows need (same PR, shared/llm_client/client.py): structured output asks with
-- tool choice `auto` + an instruction instead of a forced tool (Haiku 5.5 / Sonnet 5.5 / Opus 5.5 answer
-- a forced tool choice with a 400); no thinking field or budget_tokens is sent; no assistant prefill.
-- Deploy the app before routing a structured-output stage to either row (the rows themselves are safe
-- to add first: no route names them).
--
-- 'sonnet' (legacy key): drop the acc2 profile "us.anthropic.claude-sonnet-4-5-20250929-v1:0". Sonnet 4.5
-- is LEGACY on Bedrock and acc2 cannot call Claude. Nothing in CIS reads it (the legacy chain's acc2 T1
-- uses pricing.BEDROCK_SONNET and is off by default, AA-843); the TripPlanner gateway tries acc2 last
-- and now skips one attempt that always failed. The label drops "4.5 /".
--
-- Idempotent: INSERT ... ON CONFLICT DO NOTHING; the 'sonnet' UPDATE matches only while the acc2 key is
-- there. Guards (a human decision, not a data patch, if any fires):
--   * the 'sonnet' row must exist, and its acc2 profile (if still present) must be the Sonnet 4.5 id;
--   * an existing haiku-5-5 / sonnet-5-5 row must have exactly the profiles below.
--
-- Rollback (same decision to undo):
--   DELETE FROM shared.llm_model_catalog WHERE model_key IN ('haiku-5-5', 'sonnet-5-5')
--      AND NOT EXISTS (SELECT 1 FROM shared.llm_role_config r
--                       WHERE r.model_id IN ('haiku-5-5', 'sonnet-5-5')
--                          OR r.shadow_model_id IN ('haiku-5-5', 'sonnet-5-5')
--                          OR r.fallback_model_ids && ARRAY['haiku-5-5', 'sonnet-5-5']);
--   UPDATE shared.llm_model_catalog
--      SET bedrock_profile_ids = bedrock_profile_ids
--                                || '{"acc2": "us.anthropic.claude-sonnet-4-5-20250929-v1:0"}'::jsonb,
--          label = 'Claude Sonnet 4.5 / 4.6', updated_at = now(), updated_by = 'rollback-259'
--    WHERE model_key = 'sonnet';
--   DELETE FROM shared.schema_versions WHERE version = '259';

BEGIN;

DO $$
DECLARE
    r record;
    expected jsonb;
BEGIN
    SELECT bedrock_profile_ids INTO r FROM shared.llm_model_catalog WHERE model_key = 'sonnet';
    IF NOT FOUND THEN
        RAISE EXCEPTION '259: shared.llm_model_catalog has no sonnet row';
    END IF;
    IF r.bedrock_profile_ids ? 'acc2'
       AND r.bedrock_profile_ids ->> 'acc2' <> 'us.anthropic.claude-sonnet-4-5-20250929-v1:0' THEN
        RAISE EXCEPTION '259: sonnet acc2 profile is % (expected the Sonnet 4.5 id) — changed by hand?',
            r.bedrock_profile_ids ->> 'acc2';
    END IF;

    FOR r IN
        SELECT model_key, bedrock_profile_ids
          FROM shared.llm_model_catalog
         WHERE model_key IN ('haiku-5-5', 'sonnet-5-5')
    LOOP
        expected := jsonb_build_object(
            'acc1', 'global.anthropic.claude-' || r.model_key,
            'acc3', 'global.anthropic.claude-' || r.model_key);
        IF r.bedrock_profile_ids IS DISTINCT FROM expected THEN
            RAISE EXCEPTION '259: % already exists with bedrock_profile_ids %, expected %',
                r.model_key, r.bedrock_profile_ids, expected;
        END IF;
    END LOOP;
END $$;

INSERT INTO shared.llm_model_catalog
    (model_key, label, vendor, provider, api_style, bedrock_profile_ids, wire_model, callable_via,
     supports_temperature, max_output_tokens, price_in_per_mtok, price_out_per_mtok,
     price_cache_read_per_mtok, price_cache_write_per_mtok, price_source, enabled, blocked_reason,
     notes, updated_at, updated_by)
VALUES
    ('haiku-5-5', 'Claude Haiku 5.5', 'anthropic', 'bedrock', 'converse',
     '{"acc3": "global.anthropic.claude-haiku-5-5", "acc1": "global.anthropic.claude-haiku-5-5"}',
     NULL, '{llm_client}', false, 128000, 0.1000, 0.5000, 0.0100, 0.1250,
     'Anthropic first-party list price (prompts <= 100K tokens), S246 21/10/2026; Bedrock is '
     'partner-priced: confirm on the AWS Bedrock pricing page',
     true, NULL,
     'AA-803 (S246): acc3 + acc1 global profiles. Rejects temperature / top_p, budget_tokens and a '
     'forced tool choice (adaptive thinking on by default). Over 100K prompt tokens Anthropic charges '
     '$0.50 / $2.50, which this row does not model. Smoke test per account before routing a stage.',
     now(), 'migration-259-aa803'),
    ('sonnet-5-5', 'Claude Sonnet 5.5', 'anthropic', 'bedrock', 'converse',
     '{"acc3": "global.anthropic.claude-sonnet-5-5", "acc1": "global.anthropic.claude-sonnet-5-5"}',
     NULL, '{llm_client}', false, 128000, 2.0000, 10.0000, 0.2000, 2.5000,
     'Anthropic first-party list price, S246 21/10/2026; Bedrock is partner-priced: confirm on the AWS '
     'Bedrock pricing page',
     true, NULL,
     'AA-803 (S246): acc3 + acc1 global profiles. Rejects temperature / top_p, budget_tokens, '
     'thinking disabled and a forced tool choice. Smoke test per account before routing a stage.',
     now(), 'migration-259-aa803')
ON CONFLICT (model_key) DO NOTHING;

UPDATE shared.llm_model_catalog
   SET bedrock_profile_ids = bedrock_profile_ids - 'acc2',
       label = 'Claude Sonnet 4.6',
       notes = COALESCE(notes || ' ', '') || 'AA-803 (S246): acc2 profile (LEGACY Sonnet 4.5) removed; '
               'acc2 cannot call Claude.',
       updated_at = now(),
       updated_by = 'migration-259-aa803'
 WHERE model_key = 'sonnet'
   AND bedrock_profile_ids ? 'acc2';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('259', now(), 'AA-803: llm_model_catalog haiku-5-5 + sonnet-5-5 (acc3/acc1, enabled, no route); '
        'sonnet row drops its LEGACY Sonnet 4.5 acc2 profile')
ON CONFLICT (version) DO NOTHING;

COMMIT;
