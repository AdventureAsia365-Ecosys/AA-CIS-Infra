-- Migration 240: AA-862 (S239) — Cohere Embed v4 falls through acc2 -> acc3 when acc2 throttles.
--
-- Why. acc2 serves cohere.embed-v4:0 at 20 requests per minute (global profile quota
-- L-7089DC7D; the S239 increase request was declined). acc3 (main LLM satellite) has
-- 2,000 rpm on both the `us.` and the `global.` Cohere Embed v4 profiles, both ACTIVE. Agreed chain per
-- embed call: TripPlanner query cache -> acc2 -> acc3 -> TripPlanner keyword fallback. acc1 is not used
-- (Nghiệp, S239: acc3's 2,000 rpm is enough).
-- Same model (cohere.embed-v4:0) at the same dimensions on every account: stored vectors stay
-- comparable, nothing is re-embedded.
--
-- How. One catalog row per account, chained with fallback_model_ids:
--   * cohere-embed-v4       (unchanged) {"acc2": "global.cohere.embed-v4:0"}   primary of every route
--   * cohere-embed-v4-acc3  (new)       {"acc3": "global.cohere.embed-v4:0"}   enabled, 1st fallback
-- Both gateways try fallback_model_ids in order and move on after any exception, throttling
-- included (CIS shared/llm_client/embed.py; TripPlanner backend/shared/llm_gateway.py). A single
-- row with two accounts cannot put acc2 first: CIS picks one account per row
-- (CatalogModel.account_for), TripPlanner tries account_route, acc3, acc1, acc2 in that order, and
-- llm_role_config_account_route_check allows only acc1 / acc3 / NULL.
-- New rows copy every other column (vendor, api_style, callable_via, prices 0.12 / 0.00 per MTok,
-- price_source) from the base row, so the price stays the base row's.
--
-- Who is affected: f10_embed, a3_place_embed (CIS), tp_search_embed, tp_component_embed (TripPlanner;
-- the last has no caller since AA-712 6a). account_route stays NULL. The gateways read the catalog and
-- routes through a cache (CIS routes 20 s, catalog 300 s; TripPlanner 60 s): no deploy needed. Until a
-- CIS process reloads its catalog it skips the new fallback as "not in catalog" (acc2 only, as before).
--
-- Before apply (AA-CIS-Infra feat/aa862-cohere-embed-satellite-iam, applied by hand on acc3): the acc3
-- invoker role AA3-Bedrock-Invoker must allow bedrock:InvokeModel on the Cohere Embed v4 profiles and
-- foundation model. Without it every acc3 attempt is AccessDenied: searches still fall back to
-- keywords, but each call wastes one failed attempt. Gate: `scripts/aa856_global_profile_probe.py
-- preflight --invoke --account acc3` in the api container must report gate.apply_240 = true.
--
-- Moving back to acc2 once its quota is raised needs nothing: acc2 is already first. To stop using
-- acc3, disable the catalog row (admin PATCH enabled=false; the gateways skip a disabled fallback) or
-- empty the routes' fallback_model_ids.
--
-- Idempotent: the INSERTs skip existing rows, the UPDATE matches only routes not already on the new
-- chain. Guards (a human decision, not a data patch, if any fires):
--   * the base row 'cohere-embed-v4' must exist;
--   * every one of the four routes that exists must be model_id 'cohere-embed-v4', account_route NULL
--     and fallback_model_ids either empty (before 240) or exactly {cohere-embed-v4-acc3} (after 240);
--   * an existing 'cohere-embed-v4-acc3' row must serve only acc3.
--
-- Rollback (same decision to undo):
--   UPDATE shared.llm_role_config SET fallback_model_ids = '{}', updated_at = now(),
--          updated_by = 'rollback-240'
--    WHERE stage IN ('f10_embed', 'a3_place_embed', 'tp_search_embed', 'tp_component_embed')
--      AND fallback_model_ids = ARRAY['cohere-embed-v4-acc3']::text[];
--   DELETE FROM shared.llm_model_catalog WHERE model_key = 'cohere-embed-v4-acc3';
--   DELETE FROM shared.schema_versions WHERE version = '240';

BEGIN;

DO $$
DECLARE
    r record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog WHERE model_key = 'cohere-embed-v4') THEN
        RAISE EXCEPTION '240: shared.llm_model_catalog has no cohere-embed-v4 row';
    END IF;

    FOR r IN
        SELECT model_key, bedrock_profile_ids
          FROM shared.llm_model_catalog
         WHERE model_key = 'cohere-embed-v4-acc3'
    LOOP
        IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(r.bedrock_profile_ids) AS k)
           IS DISTINCT FROM ARRAY[right(r.model_key, 4)] THEN
            RAISE EXCEPTION '240: % already exists with bedrock_profile_ids %, expected only %',
                r.model_key, r.bedrock_profile_ids, right(r.model_key, 4);
        END IF;
    END LOOP;

    FOR r IN
        SELECT stage, model_id, account_route, fallback_model_ids
          FROM shared.llm_role_config
         WHERE stage IN ('f10_embed', 'a3_place_embed', 'tp_search_embed', 'tp_component_embed')
    LOOP
        IF r.model_id <> 'cohere-embed-v4'
           OR r.account_route IS NOT NULL
           OR NOT (r.fallback_model_ids = ARRAY[]::text[]
                   OR r.fallback_model_ids = ARRAY['cohere-embed-v4-acc3']::text[]) THEN
            RAISE EXCEPTION '240: route % is model_id=%, account_route=%, fallback_model_ids=% '
                '(expected cohere-embed-v4, NULL, {} or {cohere-embed-v4-acc3}) — changed by hand?',
                r.stage, r.model_id, coalesce(r.account_route, 'NULL'), r.fallback_model_ids;
        END IF;
    END LOOP;
END $$;

INSERT INTO shared.llm_model_catalog
    (model_key, label, vendor, provider, api_style, bedrock_profile_ids, wire_model, callable_via,
     supports_temperature, max_output_tokens, price_in_per_mtok, price_out_per_mtok,
     price_cache_read_per_mtok, price_cache_write_per_mtok, price_source, enabled, blocked_reason,
     notes, updated_at, updated_by)
SELECT n.model_key, n.label, b.vendor, b.provider, b.api_style, n.profiles, b.wire_model,
       b.callable_via, b.supports_temperature, b.max_output_tokens, b.price_in_per_mtok,
       b.price_out_per_mtok, b.price_cache_read_per_mtok, b.price_cache_write_per_mtok,
       b.price_source, n.enabled, n.blocked_reason, n.notes, now(), 'migration-240-aa862'
  FROM shared.llm_model_catalog b
 CROSS JOIN (VALUES
       ('cohere-embed-v4-acc3', 'Cohere Embed v4 (acc3 satellite)',
        '{"acc3": "global.cohere.embed-v4:0"}'::jsonb, true, NULL::text,
        'AA-862: same model as cohere-embed-v4 on the acc3 satellite (2,000 rpm); first fallback '
        'of every embed route when acc2 (20 rpm) throttles.')
     ) AS n(model_key, label, profiles, enabled, blocked_reason, notes)
 WHERE b.model_key = 'cohere-embed-v4'
ON CONFLICT (model_key) DO NOTHING;

UPDATE shared.llm_role_config
   SET fallback_model_ids = ARRAY['cohere-embed-v4-acc3']::text[],
       updated_at = now(),
       updated_by = 'migration-240-aa862'
 WHERE stage IN ('f10_embed', 'a3_place_embed', 'tp_search_embed', 'tp_component_embed')
   AND fallback_model_ids IS DISTINCT FROM ARRAY['cohere-embed-v4-acc3']::text[];

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('240', now(), 'AA-862: cohere-embed-v4-acc3 catalog row (enabled); embed routes fall back '
        'acc2 -> acc3')
ON CONFLICT (version) DO NOTHING;

COMMIT;
