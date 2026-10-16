-- Migration 238: AA-856 (S239) — Cohere Embed v4 on acc2 moves from the US cross-region inference
-- profile `us.cohere.embed-v4:0` to the GLOBAL cross-region profile `global.cohere.embed-v4:0`
-- (shared.llm_model_catalog row 'cohere-embed-v4', bedrock_profile_ids->'acc2').
--
-- Why. Service Quotas on acc2 us-west-1 (read 16/10/2026): "Cross-region model inference requests per
-- minute for Cohere Embed V4" (L-EB8C1F30, the `us.` profile) = 20 and NOT adjustable; "Global
-- cross-region model inference requests per minute for Cohere Embed V4" (L-7089DC7D) = 20 and
-- adjustable — increase to 2,500 requested in S239 (case 179212369200770, CASE_OPENED). At 20 rpm the
-- whole TripPlanner site serves about 20 searches per minute (S239 burst: 59 search 500s, AA-833).
-- Only the global profile can be raised, so the catalog must point at it. The profile is ACTIVE on acc2
-- us-west-1 (bedrock get-inference-profile, models: cohere.embed-v4:0 regionless + us-west-1).
--
-- Why a migration. The admin catalog PATCH edits only price / enabled (admin_llm_ops.LlmCatalogPatch),
-- and a profile change is a decision that must replay on a fresh DB — same as 222 / 224 / 227 for
-- route and catalog changes. The gateways (CIS shared/llm_client, TripPlanner backend/shared/
-- llm_gateway.py) read the catalog with a 60 s cache: no deploy needed.
--
-- Who is affected. Every stage on 'cohere-embed-v4' shares the one global quota after this:
--   CIS f10_embed, a3_place_embed (ECS task role: bedrock:InvokeModel on "*" -> no IAM change);
--   TripPlanner tp_search_embed (+ tp_component_embed, no caller since AA-712 6a). The TripPlanner
--   Lambda role allows only the `us.` profile ARN today: AA-CIS-Infra branch
--   fix/aa856-tp-embed-global-iam MUST be applied BEFORE this migration, or every TripPlanner search
--   embed gets AccessDenied (keyword fallback for all searches with TripPlanner AA-856, 500 without it).
-- Same model (cohere.embed-v4:0), same vectors: stored embeddings stay comparable, nothing re-embedded.
-- Price unchanged (0.12 / 0.00 per MTok, migration 170); check the global-profile price on the
-- Bedrock pricing page at the next price review. A global profile may serve the request from any
-- commercial region (not only US): the texts are tour content and traveller search queries.
-- The in-code fallbacks (CIS embed._CATALOG_FALLBACK, TripPlanner BUILTIN_ROUTES) keep `us.`: they
-- are used only when the catalog cannot be read, and both roles keep the `us.` grant.
--
-- Idempotent: the UPDATE matches only a row not already on the global profile. Guard: refuses to run
-- when the row is missing or its acc2 profile is neither the `us.` nor the `global.` id (someone
-- changed it by hand: a human decision, not a data patch).
--
-- Rollback (same decision to undo):
--   UPDATE shared.llm_model_catalog
--      SET bedrock_profile_ids = jsonb_set(bedrock_profile_ids, '{acc2}', '"us.cohere.embed-v4:0"'),
--          updated_at = now(), updated_by = 'rollback-238'
--    WHERE model_key = 'cohere-embed-v4';

BEGIN;

DO $$
DECLARE
    v_profile text;
BEGIN
    SELECT bedrock_profile_ids ->> 'acc2' INTO v_profile
      FROM shared.llm_model_catalog
     WHERE model_key = 'cohere-embed-v4';
    IF NOT FOUND THEN
        RAISE EXCEPTION '238: shared.llm_model_catalog has no cohere-embed-v4 row';
    END IF;
    IF v_profile IS NULL OR v_profile NOT IN ('us.cohere.embed-v4:0', 'global.cohere.embed-v4:0') THEN
        RAISE EXCEPTION '238: cohere-embed-v4 acc2 profile is %, expected us. or global. cohere.embed-v4:0',
            coalesce(v_profile, 'NULL');
    END IF;
END $$;

UPDATE shared.llm_model_catalog
   SET bedrock_profile_ids = jsonb_set(bedrock_profile_ids, '{acc2}', '"global.cohere.embed-v4:0"'),
       updated_at = now(),
       updated_by = 'migration-238-aa856'
 WHERE model_key = 'cohere-embed-v4'
   AND bedrock_profile_ids ->> 'acc2' IS DISTINCT FROM 'global.cohere.embed-v4:0';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('238', now(), 'AA-856: cohere-embed-v4 acc2 profile us.cohere.embed-v4:0 -> '
        'global.cohere.embed-v4:0 (global cross-region quota L-7089DC7D is adjustable)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
