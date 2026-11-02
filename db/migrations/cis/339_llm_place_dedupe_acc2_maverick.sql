-- Migration 339: AA-1026 slice I6, "AWS first, outside last" (tech lead approval S263, 01/11) — the last judge /
-- validate route that ends on the OpenAI API without an acc2 hop, a3_place_dedupe, gets Meta Llama 4 Maverick on acc2
-- right BEFORE that hop, so a refused acc3 (Error 002 since 29/10) is answered inside AWS.
--
-- Why. Migration 333 put an acc2 pick before the OpenAI API hop of seven judge / validate routes but left
-- a3_place_dedupe out: it asks a structured verdict (services/places/dedupe.py VERDICT_SCHEMA), which the gateway sent
-- on Converse as a forced tool choice, and its check stage a3_place_dedupe_check falls back to Nova Lite (Amazon), so
-- its acc2 pick had to be another maker. Llama 4 Scout and Maverick refuse toolChoice.tool (live, S263). Migration 337
-- records structured_output = prompt on both Llama 4 rows and the code of CIS #1245 asks such a model for the object
-- in the system prompt (no toolConfig; the reply is still checked against the schema). The live contract smoke of
-- a3_place_dedupe on llama4-maverick (acc2, prompt mode) PASSED on 02/11 (0.00021 USD). Until this file, every
-- a3_place_dedupe call that acc3 refuses leaves AWS for the OpenAI API (monthly cap 10 USD, 327).
--
-- What. One acc2 hop inserted right before the OpenAI API hop, nothing else changes (primary, the AWS fallbacks before
-- it and their order, the OpenAI API hop itself, shadow, allowed_scopes):
--
--   stage             role      route after 333                    acc2 pick (inserted)
--   a3_place_dedupe   validate  gpt-6-luna; gpt-6-luna-openai      llama4-maverick
--
--   Pick: the cheapest enabled acc2 model that (1) answers a structured request (Maverick: structured_output prompt,
--   337, proven by the smoke) and (2) is another maker than every model of the check stage's route
--   (a3_place_dedupe_check: haiku-5-5 Anthropic, nova-lite Amazon): Meta. Llama 4 Scout (Meta, cheaper) is not the
--   pick: it was never smoked in prompt mode for this stage, and the order gate below needs a passing smoke of the
--   pick. The two-maker rule of the place pair stays: dedupe {OpenAI, Meta} vs check {Anthropic, Amazon}.
--
-- Ladder (root ADR 0009 decision 12) skipped knowingly, as for 331 / 333: contract smoke only, no A/B or shadow on
--   Maverick. a3_place_dedupe is a validate stage whose verdict is checked by its own check stage (two makers must
--   agree, otherwise the pair is held for review, services/places/dedupe.py), so an acc2 verdict merges nothing alone.
--
-- Guards (RAISE rolls the whole file back):
--   before: the registry tables (304, 307, 320 capabilities, 322 failure_domain); 333 and 337 registered (337 gives the
--           pick its structured_output mode; this file reorders the route 333 left); connection acc2 is an enabled
--           bedrock / task_role / aws_only row serving validate; the pick is an enabled non-Anthropic Bedrock Converse
--           catalog row callable by llm_client with an enabled acc2 deployment; the pick can answer a structured
--           request: its catalog row does not refuse a forced tool choice, or it states a non-forced structured_output
--           mode the code knows (any / auto / prompt).
--   which:  the stage changes only when it is a validate / judge row, its fallbacks contain an OpenAI API hop (a key
--           whose deployments are all on kind 'openai' vendor_direct connections) and END on OpenAI API hops, the pick
--           is not its primary or shadow, and the pick is not already right before the first OpenAI API hop (re-apply:
--           nothing to do). Otherwise it is skipped with a NOTICE.
--   after:  only a3_place_dedupe changed; model_id, shadow and allowed_scopes are what they were; the fallbacks
--           without the pick are the old ones without the pick; the pick is there once, right before the first OpenAI
--           API hop, and every key after it is an OpenAI API hop; the stage reaches two failure domains; no writer
--           route names an acc2-only chat model; the pick's family is not a family of the check stage's route and the
--           check stage's families are not a family of the dedupe route (the place pair keeps two makers).
--   order:  the latest shared.llm_call_log row with stage 'adhoc_aa1026', quality_signal->>'contract_smoke' =
--           'a3_place_dedupe', model = the pick and connection acc2 says parser_ok = true (a later failed run cancels
--           the pass). An empty llm_call_log (a CI or local replay) skips the gate with a NOTICE.
--
-- Behaviour on Dev. While acc3 refuses: the acc3 hop is refused at once by the connection circuit (0 USD), the pair is
-- answered on acc2 (Maverick 0.24 / 0.97 USD per 1M tokens, about 0.0002 USD per pair), and the OpenAI API is reached
-- only when acc2 fails too. While acc3 answers nothing changes.
--
-- Class: contract (root ADR 0017 d3: an UPDATE of existing routing rows), no expand header. On Dev it is applied by
-- Infra Migration Apply once every job table is idle (root ADR 0017a), after the byte copy in AA-CIS-Infra
-- db/migrations/cis/ merges; MIG-4: this migration-only PR merges before the code PR of the same lane. No code needs
-- it (the code reads the route); the job place_dedupe and the contract smoke work with or without it. DM-7.1: no new
-- table. REQUIRED_CIS_SCHEMA is not raised.
--
-- Rollback (a NEW forward migration): array_remove(fallback_model_ids, 'llama4-maverick') on the row updated_by
-- 'migration-339-aa1026' (the route of 333 again), or the admin route PATCH. After apply: GET /admin/llm-availability,
-- the root route page (tools/docs/gen_llm_routes.py), the bot/db-schema-reference PR.
--
-- X1. One BEGIN … COMMIT block, no role switch (DB Migrate runs cis/ files as cis_owner). Grants: none. Locks: one
-- UPDATE of one row.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    actor  constant text := 'migration-339-aa1026';
    stage_ constant text := 'a3_place_dedupe';
    check_ constant text := 'a3_place_dedupe_check';
    pick   constant text := 'llama4-maverick';
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
    before   jsonb;
    breached text[];
    vendor   text[];          -- the OpenAI API hop keys: every deployment on a kind 'openai' vendor_direct connection
    changed  boolean := false;
    old_f    text[];
    head     text[];
    tail     text[];
    first_v  int;
    r        record;
    bad      text;
BEGIN
    -- ── 0. Guard: predecessors ───────────────────────────────────────────────────────────────────────────────────
    IF to_regclass('shared.llm_role_config') IS NULL OR to_regclass('shared.llm_model_catalog') IS NULL
       OR to_regclass('shared.llm_model_deployment') IS NULL OR to_regclass('shared.llm_provider_connection') IS NULL
       OR to_regclass('shared.llm_model_alias') IS NULL THEN
        RAISE EXCEPTION 'migration 339: a registry table is missing (llm_role_config, llm_model_catalog, '
                        'llm_model_deployment, llm_provider_connection, llm_model_alias): apply 304 and 307';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'shared.llm_provider_connection'::regclass AND attname = 'failure_domain'
                      AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 339: shared.llm_provider_connection.failure_domain is missing: apply 322 first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'shared.llm_model_catalog'::regclass AND attname = 'capabilities'
                      AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 339: shared.llm_model_catalog.capabilities is missing: apply 320 first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '333') THEN
        RAISE EXCEPTION 'migration 339: apply 333 first (this file reorders the route 333 leaves)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '337') THEN
        RAISE EXCEPTION 'migration 339: apply 337 first (the structured_output mode of the Llama 4 rows)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_provider_connection
                    WHERE connection_key = 'acc2' AND kind = 'bedrock' AND auth_mode = 'task_role'
                      AND data_scope = 'aws_only' AND enabled
                      AND (served_roles IS NULL OR served_roles @> ARRAY['validate']::text[])) THEN
        RAISE EXCEPTION 'migration 339: connection acc2 is not an enabled bedrock / task_role / aws_only row serving '
                        'validate';
    END IF;
    IF NOT EXISTS (SELECT 1
                     FROM shared.llm_model_catalog m
                     JOIN shared.llm_model_deployment d
                       ON d.model_key = m.model_key AND d.connection_key = 'acc2' AND d.enabled
                    WHERE m.model_key = pick AND m.enabled AND m.provider = 'bedrock' AND m.api_style = 'converse'
                      AND 'llm_client' = ANY (m.callable_via)
                      AND coalesce(m.family, m.vendor) <> 'anthropic') THEN
        RAISE EXCEPTION 'migration 339: % has no enabled non-Anthropic Converse catalog row with an enabled acc2 '
                        'deployment', pick;
    END IF;
    -- The pick answers a structured request: it takes a forced tool choice (unstated = allowed), or its row states a
    -- non-forced mode the gateway knows (client.structured_mode: any / auto / prompt).
    IF EXISTS (SELECT 1 FROM shared.llm_model_catalog m
                WHERE m.model_key = pick
                  AND m.capabilities ->> 'forced_tool_choice' = 'false'
                  AND coalesce(m.capabilities ->> 'structured_output', 'tool') NOT IN ('any', 'auto', 'prompt')) THEN
        RAISE EXCEPTION 'migration 339: % refuses a forced tool choice and states no other structured_output mode '
                        '(any / auto / prompt)', pick;
    END IF;

    SELECT coalesce(array_agg(DISTINCT d.model_key), ARRAY[]::text[]) INTO vendor
      FROM shared.llm_model_deployment d
     WHERE NOT EXISTS (SELECT 1
                         FROM shared.llm_model_deployment d2
                         JOIN shared.llm_provider_connection c2 ON c2.connection_key = d2.connection_key
                        WHERE d2.model_key = d.model_key
                          AND NOT (c2.kind = 'openai' AND c2.data_scope = 'vendor_direct'));
    IF pick = ANY (vendor) THEN
        RAISE EXCEPTION 'migration 339: the pick is an OpenAI API model';
    END IF;

    -- ── 1. Put the pick right before the stage's OpenAI API hop ──────────────────────────────────────────────────
    SELECT jsonb_build_object('model_id', model_id, 'fallbacks', to_jsonb(fallback_model_ids),
                              'shadow', shadow_model_id, 'scopes', to_jsonb(allowed_scopes))
      INTO before
      FROM shared.llm_role_config WHERE stage = stage_;

    SELECT stage, role, model_id, shadow_model_id, coalesce(fallback_model_ids, ARRAY[]::text[]) AS f
      INTO r
      FROM shared.llm_role_config WHERE stage = stage_;
    IF FOUND AND r.role IN ('judge', 'validate') AND r.model_id <> pick
       AND r.shadow_model_id IS DISTINCT FROM pick THEN
        old_f := array_remove(r.f, pick);
        first_v := (SELECT min(o) FROM unnest(old_f) WITH ORDINALITY AS t (k, o) WHERE k = ANY (vendor));
        IF first_v IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM unnest(old_f) WITH ORDINALITY AS t (k, o)
                            WHERE o >= first_v AND NOT (k = ANY (vendor))) THEN
            head := old_f[1:first_v - 1];
            tail := old_f[first_v:cardinality(old_f)];
            IF r.f IS DISTINCT FROM head || pick || tail THEN
                UPDATE shared.llm_role_config
                   SET fallback_model_ids = head || pick || tail,
                       updated_at         = now(),
                       updated_by         = actor
                 WHERE stage = stage_;
                changed := true;
            END IF;
        END IF;
    END IF;

    -- ── 2. Guard: the route as decided ───────────────────────────────────────────────────────────────────────────
    SELECT string_agg(r2.stage, ', ' ORDER BY r2.stage) INTO bad
      FROM shared.llm_role_config r2
     WHERE r2.updated_by = actor AND (r2.stage <> stage_ OR r2.role NOT IN ('judge', 'validate'));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 339: rows of this file other than the % validate row: %', stage_, bad;
    END IF;

    IF changed THEN
        SELECT string_agg(r2.stage, ', ') INTO bad
          FROM shared.llm_role_config r2
          CROSS JOIN LATERAL (SELECT array_position(r2.fallback_model_ids, pick) AS at) a
         WHERE r2.stage = stage_
           AND (r2.model_id IS DISTINCT FROM before ->> 'model_id'
                OR r2.shadow_model_id IS DISTINCT FROM before ->> 'shadow'
                OR to_jsonb(r2.allowed_scopes) IS DISTINCT FROM before -> 'scopes'
                OR to_jsonb(array_remove(r2.fallback_model_ids, pick))
                   IS DISTINCT FROM to_jsonb(array_remove(ARRAY(SELECT jsonb_array_elements_text(
                                        before -> 'fallbacks')), pick))
                OR a.at IS NULL
                OR (SELECT count(*) FROM unnest(r2.fallback_model_ids) AS f WHERE f = pick) <> 1
                OR a.at = cardinality(r2.fallback_model_ids)
                OR EXISTS (SELECT 1 FROM unnest(r2.fallback_model_ids) WITH ORDINALITY AS t (k, o)
                            WHERE (o < a.at AND k = ANY (vendor)) OR (o > a.at AND NOT (k = ANY (vendor)))));
        IF bad IS NOT NULL THEN
            RAISE EXCEPTION 'migration 339: route changed beyond the acc2 pick before the OpenAI API hop: %', bad;
        END IF;

        EXECUTE breach_sql INTO breached;
        IF stage_ = ANY (breached) THEN
            RAISE EXCEPTION 'migration 339: % is in one failure domain after the reorder', stage_;
        END IF;
    END IF;

    -- Writers never route to an acc2-only chat model (ADR 0009 decision 14).
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
        RAISE EXCEPTION 'migration 339: writer routes naming an acc2-only chat model: %', bad;
    END IF;

    -- The place pair keeps two makers: no family of one member's route (primary + fallbacks) is a family of the other.
    SELECT string_agg(DISTINCT coalesce(mx.family, mx.vendor), ', ') INTO bad
      FROM shared.llm_role_config x
      JOIN shared.llm_role_config y ON y.stage = check_
     CROSS JOIN LATERAL unnest(ARRAY[x.model_id] || x.fallback_model_ids) AS kx (key)
      JOIN shared.llm_model_catalog mx ON mx.model_key = kx.key
     WHERE x.stage = stage_
       AND EXISTS (SELECT 1
                     FROM unnest(ARRAY[y.model_id] || y.fallback_model_ids) AS ky (key)
                     JOIN shared.llm_model_catalog my ON my.model_key = ky.key
                    WHERE coalesce(my.family, my.vendor) = coalesce(mx.family, mx.vendor));
    IF changed AND bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 339: % and % would share a maker: %', stage_, check_, bad;
    END IF;

    -- ── 3. Order gate: the contract smoke passed for the stage on the pick, before the apply ────────────────────────
    IF changed THEN
        IF EXISTS (SELECT 1 FROM shared.llm_call_log) THEN
            IF NOT coalesce((SELECT (l.quality_signal ->> 'parser_ok')::boolean
                               FROM shared.llm_call_log l
                              WHERE l.stage = 'adhoc_aa1026'
                                AND l.quality_signal ->> 'contract_smoke' = stage_
                                AND l.model = pick
                                AND coalesce(l.connection_key, l.account) = 'acc2'
                              ORDER BY l.created_at DESC, l.id DESC
                              LIMIT 1), false) THEN
                RAISE EXCEPTION 'migration 339: no passing contract smoke of % on % (acc2): run the llm_contract_smoke '
                                'job live first (models override)', stage_, pick;
            END IF;
        ELSE
            RAISE NOTICE 'migration 339: shared.llm_call_log is empty (a replay): the contract smoke order gate is skipped';
        END IF;
        RAISE NOTICE 'migration 339: % gets % right before its OpenAI API hop', stage_, pick;
    ELSE
        RAISE NOTICE 'migration 339: % left as it is (no row, not judge / validate, no OpenAI API hop at the end of '
                     'the route, or the pick already in place)', stage_;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('339', now(), 'AA-1026 I6 "AWS first, outside last": a3_place_dedupe gets llama4-maverick (acc2, structured '
                      'output in the prompt) right before its OpenAI API hop')
ON CONFLICT (version) DO NOTHING;

COMMIT;
