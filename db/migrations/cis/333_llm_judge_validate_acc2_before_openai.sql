-- Migration 333: AA-1026 slice I6, "AWS first, outside last" (tech lead approval S263, 01/11) — every judge / validate
-- stage (platform and tenant) whose route ends on the OpenAI API direct connection gets an acc2 Bedrock model BEFORE
-- that hop, so a refused acc3 (Error 002 since 29/10) is answered inside AWS and the OpenAI API stays the last rung.
--
-- Why. Migration 327 ended the judge routes (and a3_place_dedupe) on `gpt-6-luna-openai` (GPT-6 Luna on the OpenAI
-- API, connection openai-direct, vendor_direct scope), so 331 / 332 skipped them (they already reached a second failure
-- domain). While acc3 refuses every model, each of their calls leaves AWS for the OpenAI API (monthly cap 10 USD, 327)
-- although an acc2 Bedrock model is one hop away. After 331 and 332 no judge / validate route has an acc2 hop after the
-- OpenAI API hop; the seven below have none at all (routes: tests/unit/snapshots/aa1026_routes_after_332.json, plus
-- t10_adjudicate, which that 29/10 snapshot predates: migration 308 seeds it ending on the OpenAI API, and the Dev
-- route evidence of S260 lists it with the vendor_direct scope).
--
-- What. One acc2 hop inserted right before the OpenAI API hop, nothing else changes (primary, the AWS fallbacks before
-- it and their order, the OpenAI API hop itself, shadow, allowed_scopes):
--
--   stage                 role      route after 332                                     acc2 pick (inserted)
--   s1_judge              judge     gpt-5.6-luna, gpt-6-luna, gpt-6-luna-openai          nova-lite
--   t2_judge              judge     gpt-5.6-luna, gpt-6-luna, gpt-6-luna-openai          nova-lite
--   t7_debate_judge       judge     gpt-5.6-luna, gpt-6-luna, gpt-6-luna-openai          nova-lite
--   t10_judge             judge     gpt-5.6-luna, gpt-6-luna, gpt-6-luna-openai          nova-lite
--   writing_memory_eval   judge     gpt-5.6-luna, gpt-6-luna, gpt-6-luna-openai          nova-lite
--   writing_memory_mine   judge     gpt-5.6-luna, gpt-6-luna, gpt-6-luna-openai          nova-lite
--   t10_adjudicate        judge     gpt-6-luna; gpt-5.6-luna, gpt-6-luna-openai (308)    nova-lite
--
--   Picks: the 331 rule, the cheapest acc2 model that meets the stage's output contract (Nova Lite), non-Anthropic (a
--   judge's family differs from the Anthropic writers, ADR 0009 decision 12). The contract smoke (job kind
--   llm_contract_smoke) has a case for each of the seven stages (AA-1026 code PR "stage parsers read the first complete
--   JSON value") and must pass BEFORE this file is applied: the order gate below refuses a stage whose latest smoke on
--   its pick did not pass. The live smoke of S263 (01/11) passed all seven on Nova Lite.
--
--   NOT moved (open): a3_place_dedupe (validate; gpt-6-luna, gpt-6-luna-openai). It asks a forced tool choice
--   (structured verdict, services/places/dedupe.py VERDICT_SCHEMA) and its check stage a3_place_dedupe_check falls back
--   to Nova Lite (Amazon, 331), so its acc2 pick must be another maker AND take Converse toolChoice.tool. The first
--   draft picked Llama 4 Scout (Meta); the live smoke of S263 got "ValidationException ... This model doesn't support
--   the toolConfig.toolChoice.tool field" from Bedrock. No other enabled acc2 model is known to meet both: Llama 4
--   Maverick is the same family as Scout and untested, Kimi K3 (Moonshot) is untested (a reasoning model at 3.30 /
--   16.50 USD per 1M tokens). It keeps its route until a pick passes the contract smoke (the admin's override run:
--   POST /admin/job-runner/llm-contract-smoke/run with "models": {"a3_place_dedupe": "<key>"}), then a later migration.
--
--   Catalog (step 0b): llama4-scout's capabilities gain "forced_tool_choice": false, the fact the smoke proved, so the
--   gateway asks it with tool choice `auto` + an instruction from the first call (client._forced_tool_choice_ok) and
--   the contract smoke's plan refuses it for a stage that forces a tool choice. Only when the row does not state the
--   capability already (an admin's or a later migration's value wins).
--
-- Ladder (root ADR 0009 decision 12) skipped knowingly, as for 331 / 332: format smoke only, no judge calibration, A/B
--   or shadow on Nova Lite. Unlike s1_brand_audit / t2_brand_audit (whose acc2 pass is held as manual_check), these
--   judges' acc2 verdicts are NOT held by code: while acc3 refuses, s1_judge / t2_judge (brand fit score, part of the
--   quality score), t7_debate_judge (topic ranking), t10_judge (F9: CTA / fact / integrity, blocking side),
--   t10_adjudicate (tier-2 adjudicator, off by default: T10_ADJ_MODE) and the writing memory judges answer on Nova Lite instead of GPT-6 Luna on the OpenAI API. That is the tech lead's S263
--   call ("AWS first, outside last"); a judge whose verdicts drift is re-pointed with the admin route PATCH (the OpenAI
--   API hop stays on the route, so dropping the acc2 hop restores today's behaviour). The tenant stages (t2_, t7_,
--   t10_ judge / adjudicate) are opened to acc2 by the same yes that 332 waits for (ADR 0009 decision 14 amendment).
--
-- Guards (RAISE rolls the whole file back):
--   before: the registry tables (304, 307, 320 capabilities, 322 failure_domain); 332 registered (this file reorders
--           the routes 331 / 332 leave); connection acc2 is an enabled bedrock / task_role / aws_only row serving judge
--           and validate; every pick is an enabled non-Anthropic Bedrock Converse catalog row callable by llm_client
--           with an enabled acc2 deployment, whose catalog row does not say it refuses a forced tool choice.
--   which:  a listed stage changes only when it is a judge / validate row, its fallbacks contain an OpenAI API hop (a
--           key whose deployments are all on kind 'openai' vendor_direct connections) and END on OpenAI API hops (the
--           OpenAI API is already the last rung), its pick is not its primary or shadow, and the pick is not already
--           right before the first OpenAI API hop (re-apply: nothing to do). Otherwise it is skipped with a NOTICE.
--   after:  every row this file changed is a listed judge / validate stage; model_id, shadow and allowed_scopes are
--           what they were; the fallbacks without the pick are the old ones without the pick (only the pick moved or
--           was inserted); the pick is there once, right before the first OpenAI API hop, and every key after it is an
--           OpenAI API hop; each changed stage reaches two failure domains; no writer route names an acc2-only chat
--           model; no TripPlanner stage changed (a3_place_dedupe, not listed, is covered by the first check).
--   order:  every stage changed has a passing contract smoke on its pick: the LATEST shared.llm_call_log row with stage
--           'adhoc_aa1026', quality_signal->>'contract_smoke' = the stage, model = the pick, connection acc2 says
--           parser_ok = true. An empty llm_call_log (a CI or local replay) skips the gate with a NOTICE.
--   NOTICE: the stages changed and the stages skipped.
--
-- Behaviour on Dev. While acc3 refuses: the acc3 hops are refused at once by the connection circuit (0 USD), the stage
-- answers on acc2 (Nova Lite 0.077 / 0.308 USD per 1M tokens) and the OpenAI API is only reached when acc2 fails too.
-- a3_place_card_check (Llama 4 Scout last since 331) sends no tool, so the new capability changes none of its calls. While acc3 answers nothing changes. The openai-direct monthly budget (10 USD, 327) is
-- spent only on that last rung.
--
-- Class: contract (root ADR 0017 d3: UPDATE of existing routing and catalog rows), no expand header. Order: (0) the code
-- PRs (smoke cases for the seven stages; the smoke counts a refused call as failed) deploy and the smoke runs live on
-- the seven picks; (1) 331, then 332, then this file
-- (AA-CIS-App main, then the byte copy in AA-CIS-Infra db/migrations/cis/, then a manual DB Migrate check / apply with
-- the job tables idle, DM-11.4); (2) the bot/db-schema-reference PR merges. No code depends on it (the code reads the
-- route).
--
-- Rollback (a NEW forward migration): array_remove(fallback_model_ids, '<pick>') on the rows updated_by
-- 'migration-333-aa1026' (the route of 327 / 332 again), or the admin route PATCH per stage. The llama4-scout
-- capability stays (it is a fact about the model, not a routing choice). Keep the AA-CIS-Infra copy
-- byte-identical. After apply: GET /admin/llm-availability, the root route page (tools/docs/gen_llm_routes.py).
--
-- X1. One BEGIN … COMMIT block, no role switch (DB Migrate runs cis/ files as cis_owner). Grants: none.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    actor  constant text   := 'migration-333-aa1026';
    stages constant text[] := ARRAY['s1_judge', 't2_judge', 't7_debate_judge', 't10_judge', 'writing_memory_eval',
                                    'writing_memory_mine', 't10_adjudicate'];
    picks  constant text[] := ARRAY['nova-lite', 'nova-lite', 'nova-lite', 'nova-lite', 'nova-lite',
                                    'nova-lite', 'nova-lite'];
    -- Judge / validate stages whose usable deployments are all in ONE failure domain (shared/llm_client/invariant.py).
    breach_sql constant text := $q$
        SELECT coalesce(array_agg(r.stage ORDER BY r.stage), ARRAY[]::text[])
          FROM shared.llm_role_config r
          LEFT JOIN LATERAL (
              SELECT count(DISTINCT coalesce(nullif(c.failure_domain, ''),
                                             c.kind || ':' || coalesce(c.account_id, c.account_id_env, c.connection_key)
                                             || ':' || c.data_scope)) AS domains
                FROM unnest(ARRAY[r.model_id] || r.fallback_model_ids) AS k (key)
                LEFT JOIN shared.llm_model_alias a ON a.alias_key = k.key
                JOIN shared.llm_model_deployment d ON d.model_key = coalesce(a.model_key, k.key) AND d.enabled
                JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key AND c.enabled
               WHERE c.kind IN ('bedrock', 'anthropic', 'openai', 'azure_openai', 'mock')
                 AND c.data_scope = ANY (coalesce(r.allowed_scopes, ARRAY['aws_only']::text[]))
          ) u ON true
         WHERE r.role IN ('judge', 'validate') AND coalesce(u.domains, 0) < 2
    $q$;
    before    jsonb;
    breached  text[];
    vendor    text[];          -- the OpenAI API hop keys: every deployment on a kind 'openai' vendor_direct connection
    changed   text[] := ARRAY[]::text[];
    skipped   text[] := ARRAY[]::text[];
    old_f     text[];
    head      text[];
    tail      text[];
    first_v   int;
    r         record;
    bad       text;
    i         int;
BEGIN
    -- ── 0. Guard: predecessors ───────────────────────────────────────────────────────────────────────────────────
    IF to_regclass('shared.llm_role_config') IS NULL OR to_regclass('shared.llm_model_catalog') IS NULL
       OR to_regclass('shared.llm_model_deployment') IS NULL OR to_regclass('shared.llm_provider_connection') IS NULL
       OR to_regclass('shared.llm_model_alias') IS NULL THEN
        RAISE EXCEPTION 'migration 333: a registry table is missing (llm_role_config, llm_model_catalog, '
                        'llm_model_deployment, llm_provider_connection, llm_model_alias): apply 304 and 307';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'shared.llm_provider_connection'::regclass AND attname = 'failure_domain'
                      AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 333: shared.llm_provider_connection.failure_domain is missing: apply 322 first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'shared.llm_model_catalog'::regclass AND attname = 'capabilities'
                      AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 333: shared.llm_model_catalog.capabilities is missing: apply 320 first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '332') THEN
        RAISE EXCEPTION 'migration 333: apply 332 first (this file reorders the routes 331 / 332 leave)';
    END IF;
    IF cardinality(stages) <> cardinality(picks) THEN
        RAISE EXCEPTION 'migration 333: % stages but % picks', cardinality(stages), cardinality(picks);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_provider_connection
                    WHERE connection_key = 'acc2' AND kind = 'bedrock' AND auth_mode = 'task_role'
                      AND data_scope = 'aws_only' AND enabled
                      AND (served_roles IS NULL OR served_roles @> ARRAY['judge', 'validate']::text[])) THEN
        RAISE EXCEPTION 'migration 333: connection acc2 is not an enabled bedrock / task_role / aws_only row serving '
                        'judge and validate';
    END IF;
    SELECT string_agg(DISTINCT p, ', ') INTO bad
      FROM unnest(picks) AS p
     WHERE NOT EXISTS (SELECT 1
                         FROM shared.llm_model_catalog m
                         JOIN shared.llm_model_deployment d
                           ON d.model_key = m.model_key AND d.connection_key = 'acc2' AND d.enabled
                        WHERE m.model_key = p AND m.enabled AND m.provider = 'bedrock' AND m.api_style = 'converse'
                          AND 'llm_client' = ANY (m.callable_via)
                          AND coalesce(m.family, m.vendor) <> 'anthropic');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 333: picks without an enabled non-Anthropic Converse catalog row and an enabled acc2 '
                        'deployment: %', bad;
    END IF;

    -- ── 0b. Catalog: Llama 4 Scout refuses a forced tool choice on Converse (live contract smoke, S263) ─────────────
    UPDATE shared.llm_model_catalog
       SET capabilities = coalesce(capabilities, '{}'::jsonb) || '{"forced_tool_choice": false}'::jsonb,
           updated_at   = now(),
           updated_by   = actor
     WHERE model_key = 'llama4-scout' AND NOT (coalesce(capabilities, '{}'::jsonb) ? 'forced_tool_choice');

    -- A pick must take the forced tool choice its stage may send: the catalog row never says it refuses one (unknown =
    -- allowed: the contract smoke of the order gate below proves the stage's own request on the pick).
    SELECT string_agg(DISTINCT p, ', ') INTO bad
      FROM unnest(picks) AS p
      JOIN shared.llm_model_catalog m ON m.model_key = p
     WHERE m.capabilities ->> 'forced_tool_choice' = 'false';
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 333: picks whose catalog row refuses a forced tool choice: %', bad;
    END IF;

    SELECT coalesce(array_agg(DISTINCT d.model_key), ARRAY[]::text[]) INTO vendor
      FROM shared.llm_model_deployment d
     WHERE NOT EXISTS (SELECT 1
                         FROM shared.llm_model_deployment d2
                         JOIN shared.llm_provider_connection c2 ON c2.connection_key = d2.connection_key
                        WHERE d2.model_key = d.model_key
                          AND NOT (c2.kind = 'openai' AND c2.data_scope = 'vendor_direct'));
    IF EXISTS (SELECT 1 FROM unnest(picks) AS p WHERE p = ANY (vendor)) THEN
        RAISE EXCEPTION 'migration 333: a pick is an OpenAI API model';
    END IF;

    -- ── 1. Put each listed stage's acc2 pick right before its OpenAI API hop ─────────────────────────────────────
    SELECT coalesce(jsonb_object_agg(stage, jsonb_build_object(
               'model_id', model_id, 'fallbacks', to_jsonb(fallback_model_ids), 'shadow', shadow_model_id,
               'scopes', to_jsonb(allowed_scopes))), '{}'::jsonb)
      INTO before
      FROM shared.llm_role_config WHERE stage = ANY (stages);

    FOR i IN 1 .. cardinality(stages) LOOP
        SELECT stage, role, model_id, shadow_model_id, coalesce(fallback_model_ids, ARRAY[]::text[]) AS f
          INTO r
          FROM shared.llm_role_config WHERE stage = stages[i];
        IF NOT FOUND OR r.role NOT IN ('judge', 'validate') OR r.model_id = picks[i]
           OR r.shadow_model_id IS NOT DISTINCT FROM picks[i] THEN
            skipped := skipped || stages[i];
            CONTINUE;
        END IF;
        old_f := array_remove(r.f, picks[i]);
        first_v := (SELECT min(o) FROM unnest(old_f) WITH ORDINALITY AS t (k, o) WHERE k = ANY (vendor));
        IF first_v IS NULL
           OR EXISTS (SELECT 1 FROM unnest(old_f) WITH ORDINALITY AS t (k, o)
                       WHERE o >= first_v AND NOT (k = ANY (vendor))) THEN
            skipped := skipped || stages[i];                    -- no OpenAI API hop, or it is not the last rung
            CONTINUE;
        END IF;
        head := old_f[1:first_v - 1];
        tail := old_f[first_v:cardinality(old_f)];
        IF r.f = head || picks[i] || tail THEN
            skipped := skipped || stages[i];                    -- already in place (a re-apply)
            CONTINUE;
        END IF;
        UPDATE shared.llm_role_config
           SET fallback_model_ids = head || picks[i] || tail,
               updated_at         = now(),
               updated_by         = actor
         WHERE stage = stages[i];
        changed := changed || stages[i];
    END LOOP;

    -- ── 2. Guard: the routes as decided ──────────────────────────────────────────────────────────────────────────
    SELECT string_agg(r2.stage, ', ' ORDER BY r2.stage) INTO bad
      FROM shared.llm_role_config r2
     WHERE r2.updated_by = actor
       AND (r2.role NOT IN ('judge', 'validate') OR NOT (r2.stage = ANY (stages)));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 333: rows of this file that are not a listed judge / validate stage: %', bad;
    END IF;

    -- Only the pick moved: primary, shadow, scopes and every other fallback (in order) are what they were; the pick is
    -- there once, right before the first OpenAI API hop, and only OpenAI API hops follow it.
    SELECT string_agg(r2.stage, ', ' ORDER BY r2.stage) INTO bad
      FROM shared.llm_role_config r2
      CROSS JOIN LATERAL (SELECT picks[array_position(stages, r2.stage)] AS pick) p
      CROSS JOIN LATERAL (SELECT array_position(r2.fallback_model_ids, p.pick) AS at) a
     WHERE r2.stage = ANY (changed)
       AND (r2.model_id IS DISTINCT FROM before -> r2.stage ->> 'model_id'
            OR r2.shadow_model_id IS DISTINCT FROM before -> r2.stage ->> 'shadow'
            OR to_jsonb(r2.allowed_scopes) IS DISTINCT FROM before -> r2.stage -> 'scopes'
            OR to_jsonb(array_remove(r2.fallback_model_ids, p.pick))
               IS DISTINCT FROM to_jsonb(array_remove(ARRAY(SELECT jsonb_array_elements_text(
                                    before -> r2.stage -> 'fallbacks')), p.pick))
            OR a.at IS NULL
            OR (SELECT count(*) FROM unnest(r2.fallback_model_ids) AS f WHERE f = p.pick) <> 1
            OR a.at = cardinality(r2.fallback_model_ids)
            OR EXISTS (SELECT 1 FROM unnest(r2.fallback_model_ids) WITH ORDINALITY AS t (k, o)
                        WHERE (o < a.at AND k = ANY (vendor)) OR (o > a.at AND NOT (k = ANY (vendor)))));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 333: routes changed beyond the acc2 pick before the OpenAI API hop: %', bad;
    END IF;

    EXECUTE breach_sql INTO breached;
    SELECT string_agg(s, ', ' ORDER BY s) INTO bad FROM unnest(changed) AS s WHERE s = ANY (breached);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 333: stages in one failure domain after the reorder: %', bad;
    END IF;

    -- Writers never route to an acc2-only chat model (ADR 0009 decision 14); this file opens no TripPlanner stage.
    SELECT string_agg(DISTINCT r2.stage || ':' || k.key, ', ') INTO bad
      FROM shared.llm_role_config r2
     CROSS JOIN LATERAL unnest(ARRAY[r2.model_id, r2.shadow_model_id] || r2.fallback_model_ids) AS k (key)
     WHERE r2.role = 'writer'
       AND EXISTS (SELECT 1 FROM shared.llm_model_deployment d
                    WHERE d.model_key = k.key AND d.connection_key = 'acc2')
       AND NOT EXISTS (SELECT 1 FROM shared.llm_model_deployment d
                        WHERE d.model_key = k.key AND d.connection_key <> 'acc2')
       AND EXISTS (SELECT 1 FROM shared.llm_model_catalog m WHERE m.model_key = k.key AND m.api_style = 'converse');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 333: writer routes naming an acc2-only chat model: %', bad;
    END IF;
    SELECT string_agg(stage, ', ' ORDER BY stage) INTO bad
      FROM shared.llm_role_config
     WHERE updated_by = actor AND stage LIKE 'tp\_%';
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 333: TripPlanner stages changed by this file: %', bad;
    END IF;

    -- ── 3. Order gate: the contract smoke passed for every stage changed here, on its pick, before the apply ─────────
    IF EXISTS (SELECT 1 FROM shared.llm_call_log) THEN
        SELECT string_agg(s.stage || ' (' || s.pick || ')', ', ' ORDER BY s.stage) INTO bad
          FROM unnest(stages, picks) AS s (stage, pick)
         WHERE s.stage = ANY (changed)
           AND NOT coalesce((SELECT (l.quality_signal ->> 'parser_ok')::boolean
                               FROM shared.llm_call_log l
                              WHERE l.stage = 'adhoc_aa1026'
                                AND l.quality_signal ->> 'contract_smoke' = s.stage
                                AND l.model = s.pick
                                AND coalesce(l.connection_key, l.account) = 'acc2'
                              ORDER BY l.created_at DESC, l.id DESC
                              LIMIT 1), false);
        IF bad IS NOT NULL THEN
            RAISE EXCEPTION 'migration 333: no passing contract smoke on the acc2 pick (run the llm_contract_smoke job '
                            'live first, re-pick or drop a failing stage): %', bad;
        END IF;
    ELSE
        RAISE NOTICE 'migration 333: shared.llm_call_log is empty (a replay): the contract smoke order gate is skipped';
    END IF;

    RAISE NOTICE 'migration 333: stages given their acc2 pick before the OpenAI API hop: %',
        coalesce(nullif(array_to_string(changed, ', '), ''), '(none)');
    IF cardinality(skipped) > 0 THEN
        RAISE NOTICE 'migration 333: listed stages left as they are (no row, not judge / validate, no OpenAI API hop '
                     'at the end of the route, or the pick already in place): %', array_to_string(skipped, ', ');
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('333', now(), 'AA-1026 I6 "AWS first, outside last": judge / validate routes ending on the OpenAI API get an '
                      'acc2 Bedrock model before that hop (nova-lite; a3_place_dedupe left as it is); llama4-scout '
                      'catalog row: forced_tool_choice false')
ON CONFLICT (version) DO NOTHING;

COMMIT;
