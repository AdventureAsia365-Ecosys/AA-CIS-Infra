-- Migration 344: AA-1026 (AI gateway v2; tech lead decision S264, 02/11 12:30 +07) — the six TENANT (T-series)
-- writer stages may fall back outside AWS when every AWS path is blocked: allowed_scopes {aws_only, vendor_direct} and
-- the OpenAI API model `gpt-6-luna-openai` as the LAST fallback of their route, the pattern migration 327 applied to
-- the A-series writers (decision T-3, S263).
--
-- Why. Every tenant writer stage routes only Claude (sonnet-5-5 / haiku-5-5). Claude is served on acc3 (refused since
-- 29/10, access_state access_denied) or on the Anthropic API (anthropic-direct, no key yet, switched off), so a tenant
-- cannot write at all today: the live t8_angle_gen and t9_write rows are 'refused'. The OpenAI API connection
-- (openai-direct) answers, with its 10 USD monthly hard-stop budget (327). The tech lead's call (S264): "add OpenAI
-- as the last fallback" for the tenant writers, the same rule as T-3 ("outside only when the AWS paths are blocked")
-- and ADR 0009 decision 14's "AWS first, outside last" (root #440).
--
-- DATA SCOPE WIDENED (on purpose, these six stages only). Since migration 311 every T-stage writer is aws_only (ADR
-- 0009 decision 5: tenant writer stages stay aws_only until AA-820, the tenant terms). This file sets
-- {aws_only, vendor_direct} on exactly the six stages below, so their content (tour text, the tenant's brand settings
-- and briefs) may reach a vendor API outside AWS, but only after every AWS deployment of the route failed:
--   - the OpenAI API (GPT-6 Luna on openai-direct), the last rung;
--   - the Anthropic API (anthropic-direct), the same model behind acc3, once its key is stored and the connection
--     switched on (migration 306 seeded those deployment rows; the warm path ADR 0009 decision 5 approved for Claude
--     writers).
-- The tenant terms (AA-Partner portal /terms §3, /privacy §5) and the root AI Use Register name both APIs as a capped
-- fallback for writing in the same change set (AA-820, ADR 0009 decision 10: tenant stages use only makers named
-- there). Every other T-stage keeps its scopes; TripPlanner (tp_*) and the CRM are not touched.
--
-- What. For each of
--   stage                 route before (live; tests/unit/snapshots/aa1026_routes_after_339.json)
--   t2_flag_fix           haiku-5-5                  ->  haiku-5-5, gpt-6-luna-openai
--   t2_generate           sonnet-5-5, haiku-5-5      ->  sonnet-5-5, gpt-6-luna-openai
--   t2_itinerary_nudge    haiku-5-5                  ->  haiku-5-5, gpt-6-luna-openai
--   t8_angle_gen          sonnet-5-5, haiku-5-5      ->  sonnet-5-5, gpt-6-luna-openai
--   t9_repair             haiku-5-5, sonnet-5-5      ->  haiku-5-5, gpt-6-luna-openai
--   t9_write              sonnet-5-5, haiku-5-5      ->  sonnet-5-5, gpt-6-luna-openai
-- when it is a writer row on an Anthropic primary: allowed_scopes {aws_only, vendor_direct}; `gpt-6-luna-openai`
-- appended as the last fallback (moved to the end when already in the route); and, as 327 did for
-- supply_content_writer, every fallback reached inside AWS that follows a model which also has a deployment outside
-- AWS is dropped. The gateway tries EVERY deployment of a model (acc3, then anthropic-direct) before the route's next
-- model (vendor_route.deployment_plan, LLMClient._call_plan), so with vendor_direct allowed, a [sonnet-5-5, haiku-5-5]
-- route would call the Anthropic API (outside AWS) before haiku-5-5 on acc3 (inside): T-3 forbids that, and the admin
-- route PATCH refuses the same interleaving (api/routers/admin_llm_ops.py, _check_aws_before_vendor). So the Sonnet ->
-- Haiku degrade of t2_generate / t8_angle_gen / t9_write and the Haiku -> Sonnet step of t9_repair go: each route
-- becomes [<its Anthropic primary>, gpt-6-luna-openai] = acc3, then the Anthropic API (when switched on), then GPT-6
-- Luna on the OpenAI API. Primary, shadow (none on these rows), role, is_active: unchanged.
--
-- Behaviour on Dev. While acc3 refuses: the acc3 hop is refused at once by the connection circuit (0 USD), the
-- Anthropic API has no key (switched off, not planned), and the call is answered by GPT-6 Luna on the OpenAI API
-- (catalog price 0.10 / 0.50 USD per 1M tokens, migration 170: well under a cent per piece, inside the 10 USD monthly
-- hard stop of 327; the tenant AI budget of 321 applies as before). Judge stages are unchanged: while acc3 refuses
-- they answer on Nova Lite (acc2, 333) before their own OpenAI API hop, so a GPT-written piece is normally scored by
-- another maker. While acc3 answers, nothing changes but the lost Sonnet <-> Haiku degrade (a throttled acc3 model
-- now falls to the Anthropic API / OpenAI API instead of the other Claude tier on acc3). The ladder (ADR 0009
-- decision 12: writers stay on Anthropic until non-inferiority) is skipped for this last rung, knowingly, as for 327:
-- it is the tech lead's S264 call for a blocked AWS path; the tenant reviews every piece before it is published (T10
-- / T11, AI notice).
--
-- Guards (RAISE rolls the whole file back):
--   before: the registry tables (304, 307), allowed_scopes (311), served_roles (322), 327 registered;
--           gpt-6-luna-openai is an enabled OpenAI row callable by llm_client with a deployment on openai-direct;
--           openai-direct is a kind 'openai' vendor_direct connection that serves the writer role (served_roles NULL
--           or naming 'writer'; else the gateway would leave the hop out, migration 338's role_not_served).
--   which:  a listed stage changes only when it is a writer row whose primary is an Anthropic catalog model other than
--           the OpenAI hop; otherwise it is skipped with a NOTICE (no row on this database, another role, re-routed).
--   after:  every row this file changed is a listed writer stage; its primary, shadow and role are what they were;
--           its scopes are {aws_only, vendor_direct}; its fallbacks end ONCE on gpt-6-luna-openai and, without it,
--           are the old ones in their order with only AWS fallbacks behind a vendor-capable model removed; no listed
--           stage calls a vendor API before an AWS deployment of a later model; every row NOT changed here (every
--           other stage, TripPlanner and the other T-stages included) is byte-for-byte what it was; every stage
--           allowed vendor_direct is one of 327's A-series writers, one of this file's tenant writers, or names a model
--           reached only outside AWS (311's rule); no writer route names an acc2-only chat model (ADR 0009 d14).
--   NOTICE: the stages changed and the stages skipped.
-- No contract-smoke order gate (unlike 331-333): the smoke proves judge / validate parsers on acc2. The writer hop is
-- proven live after the apply by one t9_write call through the gateway that ends on openai-direct (ledger row status
-- ok, connection_key openai-direct), as the A-series writers of 327 were.
--
-- Class: contract (root ADR 0017 d3: UPDATE of existing routing rows, scope widened), no "-- migrate:" directive.
-- MIG-4 order: (1) this migration-only PR merges to AA-CIS-App main, with the root PR (AI Use Register v1.2, ADR 0009
-- decision 5 amendment) and the AA-Partner PR (tenant terms / privacy) merged first or together; (2) the byte copy in
-- AA-CIS-Infra db/migrations/cis/ merges (Copy Guard green); (3) Infra Migration Apply with the job tables idle
-- (DM-11.4); (4) the bot/db-schema-reference PR merges. No code depends on it (the gateway reads the route). After
-- apply: POST /admin/writing-memory/releases/reverify-scan (t2_generate / t9_write routes changed outside the admin
-- PATCH that triggers it); the root route page (tools/docs/gen_llm_routes.py dump / import).
--
-- Rollback (a NEW forward migration): on the rows updated_by 'migration-344-aa1026', allowed_scopes back to
-- {aws_only} and fallback_model_ids back to the "route before" column above (or the admin route PATCH per stage,
-- with a break-glass reason). Keep the AA-CIS-Infra copy byte-identical.
--
-- X1. One BEGIN … COMMIT block, no role switch (DB Migrate runs cis/ files as cis_owner, the owner of every table
-- here). Grants: none (existing tables; allowed_scopes stays migration-only, 311). DM-7.1: no new table.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    actor  constant text   := 'migration-344-aa1026';
    hop    constant text   := 'gpt-6-luna-openai';
    stages constant text[] := ARRAY['t2_flag_fix', 't2_generate', 't2_itinerary_nudge', 't8_angle_gen', 't9_repair',
                                    't9_write'];
    a_writers constant text[] := ARRAY['s1_generate', 's1_flag_fix', 's1_itinerary_nudge', 'a0_column_map',
                                       'supply_content_writer'];          -- opened by 327
    scopes constant text[] := ARRAY['aws_only', 'vendor_direct'];
    before   jsonb;                -- the listed rows, as they were
    others   jsonb;                -- every other row, as it was
    outside  text[];               -- models with a deployment outside AWS (any row, enabled or not)
    inside   text[];               -- models with a deployment inside AWS; a model without a row counts as inside
    changed  text[] := ARRAY[]::text[];
    skipped  text[] := ARRAY[]::text[];
    r        record;
    chain    text[];
    kept     text[];
    seen_vendor boolean;
    k        text;
    j        int;
    bad      text;
    i        int;
BEGIN
    -- ── 0. Guard: predecessors ───────────────────────────────────────────────────────────────────────────────────
    IF to_regclass('shared.llm_role_config') IS NULL OR to_regclass('shared.llm_model_catalog') IS NULL
       OR to_regclass('shared.llm_model_deployment') IS NULL OR to_regclass('shared.llm_provider_connection') IS NULL
       OR to_regclass('shared.llm_model_alias') IS NULL THEN
        RAISE EXCEPTION 'migration 344: a registry table is missing (llm_role_config, llm_model_catalog, '
                        'llm_model_deployment, llm_provider_connection, llm_model_alias): apply 304 and 307';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'shared.llm_role_config'::regclass AND attname = 'allowed_scopes'
                      AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 344: shared.llm_role_config.allowed_scopes is missing: apply 311 first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'shared.llm_provider_connection'::regclass AND attname = 'served_roles'
                      AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 344: shared.llm_provider_connection.served_roles is missing: apply 322 first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '327') THEN
        RAISE EXCEPTION 'migration 344: apply 327 first (the Converse keys and the OpenAI API budget)';
    END IF;
    IF NOT EXISTS (SELECT 1
                     FROM shared.llm_model_catalog m
                     JOIN shared.llm_model_deployment d
                       ON d.model_key = m.model_key AND d.connection_key = 'openai-direct'
                    WHERE m.model_key = hop AND m.enabled AND m.provider = 'openai'
                      AND 'llm_client' = ANY (m.callable_via)) THEN
        RAISE EXCEPTION 'migration 344: % (an enabled OpenAI API row callable by llm_client, deployed on '
                        'openai-direct) is missing', hop;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_provider_connection
                    WHERE connection_key = 'openai-direct' AND kind = 'openai' AND data_scope = 'vendor_direct'
                      AND (served_roles IS NULL OR 'writer' = ANY (served_roles))) THEN
        RAISE EXCEPTION 'migration 344: connection openai-direct is not a kind openai, vendor_direct row serving the '
                        'writer role';
    END IF;
    -- The hop is reached ONLY outside AWS (else it would not be the "outside last" rung).
    IF EXISTS (SELECT 1 FROM shared.llm_model_deployment d
                 JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key
                WHERE d.model_key = hop AND c.data_scope = 'aws_only') THEN
        RAISE EXCEPTION 'migration 344: % has a deployment inside AWS: it is not an outside-only last rung', hop;
    END IF;

    SELECT coalesce(array_agg(DISTINCT d.model_key) FILTER (WHERE c.data_scope <> 'aws_only'), ARRAY[]::text[]),
           coalesce(array_agg(DISTINCT d.model_key) FILTER (WHERE c.data_scope = 'aws_only'), ARRAY[]::text[])
      INTO outside, inside
      FROM shared.llm_model_deployment d
      JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key;

    SELECT coalesce(jsonb_object_agg(stage, jsonb_build_object(
               'role', role, 'model_id', model_id, 'fallbacks', to_jsonb(fallback_model_ids),
               'shadow', shadow_model_id, 'scopes', to_jsonb(allowed_scopes))), '{}'::jsonb)
      INTO before
      FROM shared.llm_role_config WHERE stage = ANY (stages);
    SELECT coalesce(jsonb_object_agg(stage, to_jsonb(rc) - 'updated_at'), '{}'::jsonb)
      INTO others
      FROM shared.llm_role_config rc WHERE NOT (stage = ANY (stages));

    -- ── 1. Each listed tenant writer: both scopes, AWS fallbacks behind a vendor-capable model dropped, hop last ──
    FOR i IN 1 .. cardinality(stages) LOOP
        SELECT rc.stage, rc.role, rc.model_id, rc.shadow_model_id, rc.allowed_scopes,
               coalesce(rc.fallback_model_ids, ARRAY[]::text[]) AS f
          INTO r
          FROM shared.llm_role_config rc WHERE rc.stage = stages[i];
        IF NOT FOUND OR r.role <> 'writer' OR r.model_id = hop
           OR NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog m
                           WHERE m.model_key = r.model_id AND coalesce(m.family, m.vendor) = 'anthropic') THEN
            skipped := skipped || stages[i];
            CONTINUE;
        END IF;
        chain := ARRAY[r.model_id] || array_remove(r.f, hop);
        kept := ARRAY[]::text[];
        seen_vendor := r.model_id = ANY (outside);
        FOR j IN 2 .. coalesce(cardinality(chain), 1) LOOP
            k := chain[j];
            -- a model inside AWS (or one the registry does not describe: the gateway calls it on acc3) behind a model
            -- with a deployment outside AWS would be called after that vendor API: T-3 drops it (as 327)
            IF seen_vendor AND (k = ANY (inside) OR NOT (k = ANY (outside))) THEN
                CONTINUE;
            END IF;
            kept := kept || k;
            seen_vendor := seen_vendor OR k = ANY (outside);
        END LOOP;
        kept := kept || hop;
        IF r.f = kept AND r.allowed_scopes = scopes THEN
            skipped := skipped || stages[i];                    -- already in place (a re-apply)
            CONTINUE;
        END IF;
        UPDATE shared.llm_role_config
           SET allowed_scopes     = scopes,
               fallback_model_ids = kept,
               updated_at         = now(),
               updated_by         = actor
         WHERE stage = stages[i];
        changed := changed || stages[i];
    END LOOP;

    -- ── 2. Guard: the routes as decided ──────────────────────────────────────────────────────────────────────────
    SELECT string_agg(rc.stage, ', ' ORDER BY rc.stage) INTO bad
      FROM shared.llm_role_config rc
     WHERE rc.updated_by = actor AND (rc.role <> 'writer' OR NOT (rc.stage = ANY (stages)));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 344: rows of this file that are not a listed tenant writer stage: %', bad;
    END IF;

    -- Primary, shadow and role unchanged; both scopes; the hop once and last; the other fallbacks are the old ones in
    -- order, with only AWS fallbacks behind a vendor-capable model left out.
    SELECT string_agg(rc.stage, ', ' ORDER BY rc.stage) INTO bad
      FROM shared.llm_role_config rc
     WHERE rc.stage = ANY (changed)
       AND (rc.model_id IS DISTINCT FROM before -> rc.stage ->> 'model_id'
            OR rc.role IS DISTINCT FROM before -> rc.stage ->> 'role'
            OR rc.shadow_model_id IS DISTINCT FROM before -> rc.stage ->> 'shadow'
            OR rc.allowed_scopes IS DISTINCT FROM scopes
            OR cardinality(rc.fallback_model_ids) = 0
            OR rc.fallback_model_ids[cardinality(rc.fallback_model_ids)] <> hop
            OR (SELECT count(*) FROM unnest(rc.fallback_model_ids) AS f WHERE f = hop) <> 1
            OR rc.model_id = ANY (rc.fallback_model_ids)
            OR EXISTS (                                   -- a kept fallback that was not in the old route
                   SELECT 1 FROM unnest(rc.fallback_model_ids) AS f
                    WHERE f <> hop
                      AND NOT (f = ANY (ARRAY(SELECT jsonb_array_elements_text(
                                                  coalesce(before -> rc.stage -> 'fallbacks', '[]'::jsonb))))))
            OR EXISTS (                                   -- an old fallback left out that is not an AWS model
                   SELECT 1 FROM jsonb_array_elements_text(
                                     coalesce(before -> rc.stage -> 'fallbacks', '[]'::jsonb)) AS o (key)
                    WHERE o.key <> hop AND o.key <> rc.model_id
                      AND NOT (o.key = ANY (rc.fallback_model_ids))
                      AND o.key = ANY (outside) AND NOT (o.key = ANY (inside))));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 344: tenant writer routes changed beyond the scopes, the dropped AWS fallbacks and '
                        'the OpenAI API hop last: %', bad;
    END IF;

    -- T-3 on the whole route: no listed stage calls a vendor API before an AWS deployment of a later model.
    SELECT string_agg(DISTINCT c.stage || ':' || a.key || '>' || b.key, ', ') INTO bad
      FROM (SELECT rc.stage, ARRAY[rc.model_id] || coalesce(rc.fallback_model_ids, ARRAY[]::text[]) AS chain
              FROM shared.llm_role_config rc WHERE rc.stage = ANY (changed)) c
     CROSS JOIN LATERAL unnest(c.chain) WITH ORDINALITY AS a (key, ord)
     CROSS JOIN LATERAL unnest(c.chain) WITH ORDINALITY AS b (key, ord)
     WHERE a.key = ANY (outside) AND b.ord > a.ord
       AND (b.key = ANY (inside) OR NOT (b.key = ANY (outside)));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 344: tenant writers that would call a vendor API before an AWS deployment of a '
                        'later model: %', bad;
    END IF;

    -- Every other row (other T-stages, TripPlanner, the A-series, the judges) is exactly what it was.
    SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO bad
      FROM jsonb_each(others) AS o (key, value)
      LEFT JOIN shared.llm_role_config rc ON rc.stage = o.key
     WHERE rc.stage IS NULL OR to_jsonb(rc) - 'updated_at' IS DISTINCT FROM o.value;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 344: rows outside the six tenant writers changed: %', bad;
    END IF;

    -- 311's rule with the decided additions: vendor_direct only on 327's A-series writers, this file's tenant writers,
    -- or a route naming a model reached only outside AWS.
    SELECT string_agg(rc.stage, ', ' ORDER BY rc.stage) INTO bad
      FROM shared.llm_role_config rc
     WHERE 'vendor_direct' = ANY (coalesce(rc.allowed_scopes, ARRAY[]::text[]))
       AND NOT (rc.stage = ANY (a_writers)) AND NOT (rc.stage = ANY (stages))
       AND NOT EXISTS (SELECT 1
                         FROM unnest(ARRAY[rc.model_id, rc.shadow_model_id]
                                     || coalesce(rc.fallback_model_ids, ARRAY[]::text[])) AS k2 (key)
                        WHERE k2.key = ANY (outside) AND NOT (k2.key = ANY (inside)));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 344: stages allowed vendor_direct outside the decided set: %', bad;
    END IF;

    -- Writers never route to an acc2-only chat model (ADR 0009 decision 14).
    SELECT string_agg(DISTINCT rc.stage || ':' || k3.key, ', ') INTO bad
      FROM shared.llm_role_config rc
     CROSS JOIN LATERAL unnest(ARRAY[rc.model_id, rc.shadow_model_id] || rc.fallback_model_ids) AS k3 (key)
     WHERE rc.role = 'writer'
       AND EXISTS (SELECT 1 FROM shared.llm_model_deployment d
                    WHERE d.model_key = k3.key AND d.connection_key = 'acc2')
       AND NOT EXISTS (SELECT 1 FROM shared.llm_model_deployment d
                        WHERE d.model_key = k3.key AND d.connection_key <> 'acc2')
       AND EXISTS (SELECT 1 FROM shared.llm_model_catalog m WHERE m.model_key = k3.key AND m.api_style = 'converse');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 344: writer routes naming an acc2-only chat model: %', bad;
    END IF;

    RAISE NOTICE 'migration 344: tenant writers opened to the OpenAI API as their last fallback: %',
        coalesce(nullif(array_to_string(changed, ', '), ''), '(none)');
    IF cardinality(skipped) > 0 THEN
        RAISE NOTICE 'migration 344: listed stages left as they are (no row, not a writer on an Anthropic primary, or '
                     'already in place): %', array_to_string(skipped, ', ');
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('344', now(), 'AA-1026 (S264): the six tenant writer stages (t2_flag_fix, t2_generate, t2_itinerary_nudge, '
                      't8_angle_gen, t9_repair, t9_write) vendor_direct with gpt-6-luna-openai as their last fallback '
                      '(AWS first, outside last)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
