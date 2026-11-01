-- Migration 327: AA-1026 (AI gateway v2, route changes the tech lead approved in S263) — the stages still on the legacy
-- keys move to the Converse keys, the A-series writers may fall back outside AWS, and the OpenAI API connection gets
-- its monthly budget.
--
-- Why. Three decisions of the S263 gateway gap plan (root docs/audits/2026-11-01-S263-gateway-gap-audit/plan.md §1.I,
-- §3):
--   T-4 (I5, S11). 21 stages still route on the legacy keys `haiku` / `sonnet` (api_style anthropic_native, the
--       hard-coded InvokeModel chain). They never reach a second way in: the gateway sends a legacy key to Bedrock acc3
--       only (vendor_route: a legacy key never runs on an Anthropic connection), so with acc3 refused (Error 002 since
--       29/10) they have no path at all. The Converse keys of the same tier (`haiku-5-5`, `sonnet-5-5`, migration 259)
--       have the registry v2 shape: one deployment per way in (acc3 priority 10, anthropic-direct priority 100,
--       migrations 304 / 306), the per-stage data scope, the breaker and the connection budget. Config only: no
--       prompt changes, and the tech lead asked for a reachability check only ("test gọi được chưa thôi").
--   T-3 (I2). The A-series writers may go outside AWS when the AWS paths are blocked ("cho phép đi ra ngoài nếu các
--       đường aws bị chặn, vd như hiện tại có thể dùng gpt"): allowed_scopes {aws_only, vendor_direct} and the OpenAI
--       API model as the LAST fallback of the route. T-stages (tenant content), tp_* (traveller text) and the CRM keep
--       aws_only (ADR 0009 decision 5, AA-820).
--   T-2 / I3. The OpenAI API connection has no budget today: 10 USD a month, alert at 80 %, hard stop.
--
-- What.
--   1. T-4: every shared.llm_role_config row whose route (model_id, fallback_model_ids, shadow_model_id) names `haiku`
--      or `sonnet`. A legacy key is replaced by what its legacy chain ran (migration 307's alias rows: haiku = Haiku
--      4.5; sonnet = Sonnet 4.6, then Haiku 4.5), each model at the same tier on its Converse key:
--        haiku  -> haiku-5-5
--        sonnet -> sonnet-5-5, haiku-5-5        (the chain's Sonnet -> Haiku degrade, kept as an explicit fallback;
--                                                an A-series writer drops it again in item 2)
--      then duplicates are dropped (first occurrence wins), so e.g. [haiku, sonnet] -> [haiku-5-5, sonnet-5-5],
--      [sonnet, haiku] -> [sonnet-5-5, haiku-5-5], [sonnet-5-5, sonnet] -> [sonnet-5-5, haiku-5-5]. TripPlanner stages
--      (`tp_*`) map one to one (sonnet -> sonnet-5-5): their own gateway never had the Haiku degrade. A legacy shadow
--      maps one to one; a shadow that would equal the new primary is cleared (sample 0). Inactive rows move too.
--   2. T-3: the A-series Claude writers s1_generate, s1_flag_fix, s1_itinerary_nudge, a0_column_map,
--      supply_content_writer get allowed_scopes {aws_only, vendor_direct} and `gpt-6-luna-openai` as their LAST
--      fallback (moved to the end when already in the route). "Outside only when the AWS paths are blocked" must
--      hold for the whole route, but the gateway tries EVERY deployment of a model (priority order: acc3, then
--      anthropic-direct once its key exists) before the route's next model (vendor_route.deployment_plan,
--      LLMClient._call_plan). So a writer keeps no fallback reached inside AWS behind a model that also has a
--      deployment outside AWS (every Anthropic model has an anthropic-direct row, migration 306; enabled or not, as
--      the admin's reach rule counts it): such a fallback is dropped. Today that drops only supply_content_writer's
--      haiku-5-5 (the T-4 degrade of its legacy `sonnet`), so all five writers become [<one Anthropic model>,
--      gpt-6-luna-openai]: acc3, then the Anthropic API, then GPT-6 Luna on the OpenAI API. The admin route PATCH
--      refuses the same interleaving afterwards (api/routers/admin_llm_ops.py, _check_aws_before_vendor).
--      Not opened: s1_atom_writer (retired, no caller since AA-611) and every T-stage / tp_* stage.
--   3. I3: shared.llm_provider_connection 'openai-direct' monthly_budget_usd = 10 when it is NULL (an admin's value is
--      kept), and its shared.llm_connection_cost_policy row (alert_pct 80, hard_stop true) when it has none. How the
--      key reaches the task is unchanged (credential_env OPENAI_API_KEY, injected by ECS).
--   4. Register 327.
--
-- Guards (RAISE rolls the whole file back):
--   before: the registry tables (304, 317) and allowed_scopes (311) exist; haiku-5-5 and sonnet-5-5 are enabled
--           Anthropic Converse rows with an enabled acc3 deployment; gpt-6-luna-openai is an enabled OpenAI API row
--           with an openai-direct deployment; openai-direct is a vendor_direct connection.
--   after:  no route names a legacy key; every route this file changed names catalog keys only, without duplicates,
--           its primary not among its fallbacks, its shadow not its primary; each writer of item 2 ends on
--           gpt-6-luna-openai with both scopes and an Anthropic primary, and names no fallback reached inside AWS
--           behind a model with a deployment outside AWS; every stage allowed vendor_direct is one of
--           those writers or names a model reached only outside AWS (migration 311's rule); no T-stage or tp_* stage
--           was opened by this file.
--
-- Behaviour on Dev. acc3 refuses every model (Error 002), so before and after this file the moved stages make no
-- successful call through acc3; after it, the five writers can reach GPT-6 Luna on the OpenAI API (inside the
-- 10 USD budget) and, once the anthropic-direct key is plugged in, the Anthropic API ahead of it; the aws_only
-- stages (T-stages, tp_*, the checks) still never leave AWS. Prices drop (haiku 1 / 5 -> 0.1 / 0.5, sonnet 3 / 15 ->
-- 2 / 10 USD per 1M tokens). Converse rows have supports_temperature = false: a call site's temperature is dropped.
-- The SAFE_DEFAULTS of shared/llm_client/role_config.py keep the legacy keys on purpose: they serve a process that
-- cannot read the database, where only the hard-coded legacy chain works without the catalog.
--
-- Class: contract (root ADR 0017 d3: UPDATE of existing routing rows), so no "-- migrate: expand" header and MIG-4
-- order: (1) this PR (the migration plus an admin change that works with or without it) merges to AA-CIS-App main;
-- (2) the byte copy in AA-CIS-Infra db/migrations/cis/ merges (Copy Guard green); (3) a manual DB Migrate apply
-- (check, then apply) with the job tables idle (DM-11.4); (4) the bot/db-schema-reference PR merges. No code depends
-- on it. Number: 325-334 are held by other S263 lanes. After apply: POST /admin/writing-memory/releases/reverify-scan
-- (the routes of s1_generate / t2_generate / t9_write changed outside the admin PATCH that triggers it). Do not re-run
-- the AA-CIS-Infra run-script aa1002_dev_anthropic_road.py in apply mode afterwards: it opens every stage that reaches
-- an Anthropic Converse model, which now includes the T-stages.
--
-- Rollback (a NEW forward migration): set each stage's model_id / fallback_model_ids / allowed_scopes back from the
-- route snapshot taken before the apply (root docs/generated/llm-routes.snapshot.json, captured 29/10), and
-- openai-direct monthly_budget_usd back to NULL. A legacy key still works (the chain is unchanged).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow) and the
-- root route page (tools/docs/gen_llm_routes.py dump / import).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of every table here.
-- Grants: none (existing tables; allowed_scopes stays migration-only, 311).

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 0. Guard: predecessors ───────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    missing text;
BEGIN
    IF to_regclass('shared.llm_role_config') IS NULL OR to_regclass('shared.llm_model_catalog') IS NULL
       OR to_regclass('shared.llm_model_deployment') IS NULL OR to_regclass('shared.llm_provider_connection') IS NULL
       OR to_regclass('shared.llm_connection_cost_policy') IS NULL THEN
        RAISE EXCEPTION 'migration 327: a registry table is missing (llm_role_config, llm_model_catalog, '
                        'llm_model_deployment, llm_provider_connection, llm_connection_cost_policy): apply 304 and 317';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'shared.llm_role_config'::regclass AND attname = 'allowed_scopes'
                      AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 327: shared.llm_role_config.allowed_scopes is missing: apply 311 first';
    END IF;

    SELECT string_agg(k, ', ' ORDER BY k) INTO missing
      FROM unnest(ARRAY['haiku-5-5', 'sonnet-5-5']) AS k
     WHERE NOT EXISTS (SELECT 1
                         FROM shared.llm_model_catalog m
                         JOIN shared.llm_model_deployment d
                           ON d.model_key = m.model_key AND d.connection_key = 'acc3' AND d.enabled
                        WHERE m.model_key = k AND m.enabled AND m.vendor = 'anthropic' AND m.provider = 'bedrock'
                          AND m.api_style = 'converse');
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 327: Converse keys without an enabled Anthropic catalog row and acc3 deployment: %',
                        missing;
    END IF;

    IF NOT EXISTS (SELECT 1
                     FROM shared.llm_model_catalog m
                     JOIN shared.llm_model_deployment d
                       ON d.model_key = m.model_key AND d.connection_key = 'openai-direct'
                    WHERE m.model_key = 'gpt-6-luna-openai' AND m.enabled AND m.provider = 'openai') THEN
        RAISE EXCEPTION 'migration 327: gpt-6-luna-openai (enabled OpenAI API row on openai-direct) is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_provider_connection
                    WHERE connection_key = 'openai-direct' AND kind = 'openai' AND data_scope = 'vendor_direct') THEN
        RAISE EXCEPTION 'migration 327: connection openai-direct (kind openai, vendor_direct) is missing';
    END IF;
END $$;

-- ── 1. T-4: legacy keys -> Converse keys of the same tier ───────────────────────────────────────────────────────
WITH legacy_map (legacy_key, pos, target) AS (
    VALUES ('haiku', 1, 'haiku-5-5'),
           ('sonnet', 1, 'sonnet-5-5'),
           ('sonnet', 2, 'haiku-5-5')
), touched AS (
    SELECT r.stage, (r.stage LIKE 'tp\_%') AS tp,
           ARRAY[r.model_id] || coalesce(r.fallback_model_ids, ARRAY[]::text[]) AS chain,
           CASE r.shadow_model_id WHEN 'haiku' THEN 'haiku-5-5' WHEN 'sonnet' THEN 'sonnet-5-5'
                                  ELSE r.shadow_model_id END AS shadow
      FROM shared.llm_role_config r
     WHERE r.model_id IN ('haiku', 'sonnet')
        OR coalesce(r.fallback_model_ids, ARRAY[]::text[]) && ARRAY['haiku', 'sonnet']::text[]
        OR r.shadow_model_id IN ('haiku', 'sonnet')
), expanded AS (
    SELECT t.stage, coalesce(m.target, k.key) AS key, k.ord * 10 + coalesce(m.pos, 1) AS rank
      FROM touched t
     CROSS JOIN LATERAL unnest(t.chain) WITH ORDINALITY AS k (key, ord)
      LEFT JOIN legacy_map m ON m.legacy_key = k.key AND (m.pos = 1 OR NOT t.tp)
), firsts AS (
    SELECT stage, key, min(rank) AS rank FROM expanded GROUP BY stage, key
), planned AS (
    SELECT t.stage, c.chain, t.shadow
      FROM touched t
      JOIN (SELECT stage, array_agg(key ORDER BY rank) AS chain FROM firsts GROUP BY stage) c USING (stage)
)
UPDATE shared.llm_role_config r
   SET model_id           = p.chain[1],
       fallback_model_ids = p.chain[2:cardinality(p.chain)],
       shadow_model_id    = CASE WHEN p.shadow = p.chain[1] THEN NULL ELSE p.shadow END,
       shadow_sample_pct  = CASE WHEN p.shadow IS NULL OR p.shadow = p.chain[1] THEN 0 ELSE r.shadow_sample_pct END,
       updated_at         = now(),
       updated_by         = 'migration-327-aa1026'
  FROM planned p
 WHERE p.stage = r.stage;

-- ── 2. T-3: A-series writers may fall back outside AWS, the OpenAI API model last ──────────────────────────────
-- reach: per model, whether a deployment is inside AWS / outside it (every row, enabled or not: the switch is an
-- operation, the scope a policy). A model without a deployment row is called on acc3 by the gateway: inside AWS.
WITH reach AS (
    SELECT d.model_key,
           bool_or(c.data_scope = 'aws_only')  AS inside,
           bool_or(c.data_scope <> 'aws_only') AS outside
      FROM shared.llm_model_deployment d
      JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key
     GROUP BY d.model_key
), writers AS (
    SELECT r.stage,
           ARRAY[r.model_id] || array_remove(coalesce(r.fallback_model_ids, ARRAY[]::text[]), 'gpt-6-luna-openai')
               AS chain
      FROM shared.llm_role_config r
     WHERE r.stage IN ('s1_generate', 's1_flag_fix', 's1_itinerary_nudge', 'a0_column_map', 'supply_content_writer')
       AND r.model_id <> 'gpt-6-luna-openai'
), positions AS (
    SELECT w.stage, k.key, k.ord,
           coalesce(re.inside, true)
           AND EXISTS (SELECT 1
                         FROM unnest(w.chain) WITH ORDINALITY AS e (key, ord)
                         JOIN reach x ON x.model_key = e.key
                        WHERE e.ord < k.ord AND x.outside) AS behind_vendor
      FROM writers w
     CROSS JOIN LATERAL unnest(w.chain) WITH ORDINALITY AS k (key, ord)
      LEFT JOIN reach re ON re.model_key = k.key
), kept AS (
    SELECT stage,
           array_append(coalesce(array_agg(key ORDER BY ord) FILTER (WHERE ord > 1 AND NOT behind_vendor),
                                 ARRAY[]::text[]),
                        'gpt-6-luna-openai') AS fallbacks
      FROM positions
     GROUP BY stage
)
UPDATE shared.llm_role_config r
   SET allowed_scopes     = ARRAY['aws_only', 'vendor_direct']::text[],
       fallback_model_ids = w.fallbacks,
       updated_at         = now(),
       updated_by         = 'migration-327-aa1026'
  FROM kept w
 WHERE w.stage = r.stage
   AND (r.allowed_scopes IS DISTINCT FROM ARRAY['aws_only', 'vendor_direct']::text[]
        OR r.fallback_model_ids IS DISTINCT FROM w.fallbacks);

-- ── 3. I3: the OpenAI API connection's monthly budget (10 USD, alert 80 %, hard stop) ───────────────────────────
UPDATE shared.llm_provider_connection
   SET monthly_budget_usd = 10,
       updated_at         = now(),
       updated_by         = 'migration-327-aa1026'
 WHERE connection_key = 'openai-direct'
   AND monthly_budget_usd IS NULL;

INSERT INTO shared.llm_connection_cost_policy (connection_key, alert_pct, hard_stop, notes, updated_by)
VALUES ('openai-direct', 80, true,
        'AA-1026 (S263 T-2 / I3): 10 USD a month, alert at 80 %, hard stop at 100 % (migration 327).',
        'migration-327-aa1026')
ON CONFLICT (connection_key) DO NOTHING;

-- ── 4. Guard: the routes as decided ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    bad text;
BEGIN
    SELECT string_agg(stage, ', ' ORDER BY stage) INTO bad
      FROM shared.llm_role_config
     WHERE model_id IN ('haiku', 'sonnet')
        OR coalesce(fallback_model_ids, ARRAY[]::text[]) && ARRAY['haiku', 'sonnet']::text[]
        OR shadow_model_id IN ('haiku', 'sonnet');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 327: stages still naming a legacy key: %', bad;
    END IF;

    SELECT string_agg(r.stage || ':' || k.key, ', ' ORDER BY r.stage) INTO bad
      FROM shared.llm_role_config r
     CROSS JOIN LATERAL unnest(ARRAY[r.model_id, r.shadow_model_id] || coalesce(r.fallback_model_ids, ARRAY[]::text[]))
           AS k (key)
     WHERE r.updated_by = 'migration-327-aa1026' AND k.key IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog m WHERE m.model_key = k.key);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 327: routes naming a key outside the catalog: %', bad;
    END IF;

    SELECT string_agg(stage, ', ' ORDER BY stage) INTO bad
      FROM shared.llm_role_config r
     WHERE r.updated_by = 'migration-327-aa1026'
       AND (r.model_id = ANY (coalesce(r.fallback_model_ids, ARRAY[]::text[]))
            OR cardinality(coalesce(r.fallback_model_ids, ARRAY[]::text[]))
               <> (SELECT count(DISTINCT f) FROM unnest(r.fallback_model_ids) AS f)
            OR r.shadow_model_id = r.model_id);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 327: routes with a duplicate key, the primary among its fallbacks or as its '
                        'shadow: %', bad;
    END IF;

    SELECT string_agg(r.stage, ', ' ORDER BY r.stage) INTO bad
      FROM shared.llm_role_config r
     WHERE r.stage IN ('s1_generate', 's1_flag_fix', 's1_itinerary_nudge', 'a0_column_map', 'supply_content_writer')
       AND NOT (r.allowed_scopes = ARRAY['aws_only', 'vendor_direct']::text[]
                AND r.fallback_model_ids[cardinality(r.fallback_model_ids)] = 'gpt-6-luna-openai'
                AND r.shadow_model_id IS DISTINCT FROM 'gpt-6-luna-openai'
                AND EXISTS (SELECT 1 FROM shared.llm_model_catalog m
                             WHERE m.model_key = r.model_id AND m.vendor = 'anthropic'));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 327: A-series writers not on an Anthropic primary with the OpenAI API last and both '
                        'scopes: %', bad;
    END IF;

    -- T-3: a writer leaves AWS only after every AWS deployment of its route (the gateway walks a model's deployments
    -- before the next model, so no model reached inside AWS may follow one with a deployment outside AWS).
    WITH reach AS (
        SELECT d.model_key,
               bool_or(c.data_scope = 'aws_only')  AS inside,
               bool_or(c.data_scope <> 'aws_only') AS outside
          FROM shared.llm_model_deployment d
          JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key
         GROUP BY d.model_key
    ), chains AS (
        SELECT r.stage, ARRAY[r.model_id] || coalesce(r.fallback_model_ids, ARRAY[]::text[]) AS chain
          FROM shared.llm_role_config r
         WHERE r.stage IN ('s1_generate', 's1_flag_fix', 's1_itinerary_nudge', 'a0_column_map',
                           'supply_content_writer')
    )
    SELECT string_agg(DISTINCT c.stage || ':' || a.key || '>' || b.key, ', ') INTO bad
      FROM chains c
     CROSS JOIN LATERAL unnest(c.chain) WITH ORDINALITY AS a (key, ord)
      JOIN reach ra ON ra.model_key = a.key AND ra.outside
     CROSS JOIN LATERAL unnest(c.chain) WITH ORDINALITY AS b (key, ord)
      LEFT JOIN reach rb ON rb.model_key = b.key
     WHERE b.ord > a.ord AND coalesce(rb.inside, true);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 327: writers that would call a vendor API before an AWS deployment of a later '
                        'model (model with a deployment outside AWS > later model inside AWS): %', bad;
    END IF;

    -- 311's rule, with this file's writers as the only additions: vendor_direct = a route reaching a model only
    -- outside AWS. T-stages and tp_* stages are never opened by this file.
    WITH reach AS (
        SELECT d.model_key, bool_and(c.data_scope <> 'aws_only') AS outside_only
          FROM shared.llm_model_deployment d
          JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key
         GROUP BY d.model_key
    )
    SELECT string_agg(r.stage, ', ' ORDER BY r.stage) INTO bad
      FROM shared.llm_role_config r
     WHERE 'vendor_direct' = ANY (coalesce(r.allowed_scopes, ARRAY[]::text[]))
       AND (((r.stage LIKE 't%' OR r.stage LIKE 'tp\_%') AND r.updated_by = 'migration-327-aa1026')
            OR (r.stage NOT IN ('s1_generate', 's1_flag_fix', 's1_itinerary_nudge', 'a0_column_map',
                                'supply_content_writer')
                AND NOT EXISTS (SELECT 1 FROM reach o
                                 WHERE o.outside_only
                                   AND (o.model_key = r.model_id
                                        OR o.model_key = ANY (coalesce(r.fallback_model_ids, ARRAY[]::text[]))
                                        OR o.model_key = r.shadow_model_id))));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 327: stages allowed vendor_direct outside the decided set: %', bad;
    END IF;

    SELECT string_agg(stage, ', ' ORDER BY stage) INTO bad
      FROM shared.llm_role_config WHERE updated_by = 'migration-327-aa1026';
    RAISE NOTICE 'migration 327: stages changed by this file: %', coalesce(bad, '(none)');
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('327', now(), 'AA-1026: legacy haiku / sonnet routes -> haiku-5-5 / sonnet-5-5; A-series writers vendor_direct '
                      'with gpt-6-luna-openai last; openai-direct monthly budget 10 USD (alert 80 %, hard stop)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
