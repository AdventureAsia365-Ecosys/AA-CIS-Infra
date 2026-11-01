-- Migration 331: AA-1026 slice I6 (AI gateway v2, tech lead approval S263 01/11: "thêm đường dự phòng acc2") — every
-- platform judge / validate stage whose route reaches only acc3 gets an acc2 Bedrock model as the LAST fallback of
-- its route, so a refused acc3 (Error 002 since 29/10) no longer stops it.
--
-- Why. The failure-domain rule (shared/llm_client/invariant.py, GET /admin/llm-availability) reports a breach for every
-- stage whose usable deployments are all in one failure domain. After migration 327 the platform judge / validate
-- stages below reach Bedrock acc3 only (GPT Luna, Claude 5.5), and acc3 refuses every model since 29/10. Root ADR 0009
-- decision 14 (Accepted 31/10) lets acc2 serve chat models for judge and validate stages as a second failure domain;
-- migration 324 catalogued five acc2 models (Amazon Nova Lite / Nova 2 Lite, Meta Llama 4 Maverick / Scout, Moonshot
-- Kimi K3) with one enabled acc2 deployment each, probed alive on 31/10.
--
-- What. One fallback appended per stage (the route's order is unchanged: the AWS primary first, every existing
-- fallback next, the acc2 model last; shadow and allowed_scopes unchanged; acc2 is aws_only, so no scope change):
--
--   stage                   role      output contract (parser)                              acc2 fallback
--   s1_brand_audit          judge     json_schema brand_audit_result (Converse tool)        nova-lite
--   s1_source_facts         validate  json_schema source_day_facts (Converse tool)          nova-lite
--   a3_atomize              validate  text JSON {"atoms": [...]} (json.loads, fence ok)     nova-lite
--   a3_place_card           validate  text JSON card (place_cards._parse_json)              nova-lite
--   a3_place_card_check     validate  text JSON verdicts (place_cards._parse_json)          llama4-scout
--   a3_place_days           validate  text JSON {"days": [...]} (days.parse_llm_days)       nova-lite
--   a3_place_locate         validate  text JSON name -> [lat, lng, country, town] (locate)  nova-lite
--   a3_place_dedupe_check   validate  json_schema place_pair_verdict (Converse tool)        nova-lite
--
--   The pick is the cheapest acc2 model that meets the stage's output contract (USD per 1M tokens, migration 324):
--   Nova Lite 0.077 / 0.308 < Llama 4 Scout 0.17 / 0.66 < Llama 4 Maverick 0.24 / 0.97 < Nova 2 Lite 0.429 / 3.351 <
--   Kimi K3 3.30 / 16.50. Nova Lite takes a system prompt, tool use (the Converse structured output path of
--   client._call_bedrock_converse, with the auto-tool retry when a forced tool choice is refused) and up to 10K output
--   tokens (a3_atomize asks 4096, 8192 on its truncation retry; every other stage 4096 or less), and answers plain-text
--   JSON for the stages that parse text. Kimi K3 is a reasoning model (output spent on thinking), Nova 2 Lite and
--   Maverick cost more for the same contract. The one exception is a3_place_card_check: the place card is drafted
--   and checked by two different makers (S234, migration 286: GPT drafts, Claude checks); with Nova Lite behind the
--   draft, the check's acc2 fallback is the cheapest model of ANOTHER family, Llama 4 Scout (Meta). a3_place_dedupe_check
--   must differ from the dedupe primary's maker (OpenAI: GPT-6 Luna on acc3 and the OpenAI API): Nova Lite (Amazon).
--   Every pick is non-Anthropic, so the judge rule holds (a judge's family differs from the Anthropic writers, ADR 0009
--   decision 12; admin_llm_ops._catalog_options). Whether each pick really meets its contract is checked by the
--   contract smoke (job kind llm_contract_smoke, AA-1026 I6 code PR), one fixture per stage through the stage's own
--   prompt and parser on the acc2 deployment (cents), BEFORE this file is applied: the order gate below refuses a
--   stage whose latest smoke on its pick did not pass. A stage whose pick fails is re-picked before the apply (smoke
--   the next model with the job's "models" override, change the pick here) or dropped from this file; after the
--   apply, the admin route PATCH re-points it (any enabled non-Anthropic model is selectable for these roles).
--
-- Ladder (root ADR 0009 decision 12) skipped knowingly. The tech lead's S263 approval puts these routes live on the
--   contract smoke alone: no judge calibration, A/B or shadow rung. For the seven validate stages that is accepted
--   as is (their output is parsed and checked downstream: geocoder, card check, dedupe rules). The one judge,
--   s1_brand_audit, decides whether a tour can publish, so its acc2 verdict is held by code (AA-1026 I6 code PR,
--   brand_audit_node.hold_uncalibrated_pass): a "pass" answered on acc2 becomes manual_check +
--   BRAND_AUDIT_UNCALIBRATED_JUDGE; flagged / manual_check stand. An uncalibrated acc2 judge can flag or hold a tour,
--   never publish one. Recorded in root ADR 0009 decision 14.
--
--   Not touched: writers (they stay Claude until a qualification; the A-series writers already fall back to the
--   OpenAI API, 327); judge / validate stages that already reach a second failure domain (the judge routes ending on
--   the OpenAI API, a3_place_dedupe); embed stages; and the TENANT stages t2_brand_audit, t10_claims,
--   t9_faq_answer_fit, t9_faq_filter: ADR 0009 decision 14 keeps acc2 off tenant stages "until decision 10 and AA-820
--   are done" (tenant terms naming the makers; AA-820 is In Progress). Their fallback is the separate migration 332,
--   held for the tech lead's yes. A stage named here that no longer breaches (an admin already gave it a second
--   domain) or has no row is skipped with a NOTICE.
--
-- Guards (RAISE rolls the whole file back):
--   before: the registry tables (304, 307, 322 failure_domain) and the acc2 candidates (324) exist; connection acc2 is
--           an enabled bedrock / task_role / aws_only row whose served_roles (NULL = not set) include judge and
--           validate; every pick is an enabled Bedrock Converse catalog row callable by llm_client, not Anthropic, with
--           an enabled acc2 deployment.
--   after:  every row this file changed is a judge / validate stage of the list above, its model_id, shadow and
--           allowed_scopes are what they were, its fallbacks are the old ones plus the pick at the end (once, never
--           the primary or the shadow); it now reaches two failure domains; no writer route names an acc2-only chat
--           model; no tenant stage was changed by this file; the family of a check stage's new fallback is not a
--           family of the stage it checks (a3_place_card / a3_place_card_check, a3_place_dedupe /
--           a3_place_dedupe_check), and the other way round.
--   order:  every stage this file changes has a passing contract smoke on its pick: the LATEST shared.llm_call_log
--           row with stage 'adhoc_aa1026', quality_signal->>'contract_smoke' = the stage, model = the pick and
--           connection acc2 says parser_ok = true (a later failed run cancels an earlier pass). So the code PR (smoke +
--           brand audit hold) is deployed and the smoke ran before the apply. A database whose llm_call_log is empty
--           (a CI or local replay: no traffic to protect) skips this gate with a NOTICE.
--   NOTICE: the stages changed, and the judge / validate stages still in one failure domain.
--
-- Behaviour on Dev. While acc3 refuses, these stages make their acc3 attempts (refused at once by the connection
-- circuit after the first refusals, 0 USD) and then answer on acc2; nothing changes while acc3 answers. Prices: the
-- acc2 model is cheaper than the acc3 model it stands in for (GPT-6 Luna 0.1 / 0.5, Haiku 5.5 0.1 / 0.5). The judge
-- calibration of decision 12 (40 labelled items) is not done for Nova Lite: a brand audit answered on acc2 can flag or
-- hold a tour (manual_check, also on an unusable reply) but its pass is held as manual_check, so it publishes nothing.
--
-- Class: contract (root ADR 0017 d3: UPDATE of existing routing rows), so no expand header, and this order:
-- (0) the AA-1026 I6 code PR (contract smoke + brand audit hold) merges and deploys, and the smoke runs DRY RUN, then
-- live, on the planned models (the order gate needs its rows); (1) this migration-only PR merges to AA-CIS-App main;
-- (2) the byte copy in AA-CIS-Infra db/migrations/cis/ merges (Copy Guard green); (3) a manual DB Migrate apply (check,
-- then apply) with the job tables idle (DM-11.4); (4) the bot/db-schema-reference PR merges. REQUIRED_CIS_SCHEMA is
-- not raised: the code reads the route and works with or without this file. Number: 330 is held by AA-1031 (merge it
-- first, or relabel this PR migration:out-of-order).
--
-- Rollback (a NEW forward migration): array_remove(fallback_model_ids, '<pick>') on the rows updated_by
-- 'migration-331-aa1026', or the admin route PATCH per stage (it accepts the shorter fallback list).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: GET /admin/llm-availability (invariant.breaches drops by the stages changed), the
-- contract smoke, regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow) and the root route page
-- (tools/docs/gen_llm_routes.py dump / import).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of every table here.
-- Grants: none (existing tables).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    actor  constant text   := 'migration-331-aa1026';
    stages constant text[] := ARRAY['s1_brand_audit', 's1_source_facts', 'a3_atomize', 'a3_place_card',
                                    'a3_place_card_check', 'a3_place_days', 'a3_place_locate', 'a3_place_dedupe_check'];
    picks  constant text[] := ARRAY['nova-lite', 'nova-lite', 'nova-lite', 'nova-lite',
                                    'llama4-scout', 'nova-lite', 'nova-lite', 'nova-lite'];
    -- (checked stage, check stage): the two must stay on different makers.
    pairs  constant text[] := ARRAY['a3_place_card', 'a3_place_card_check', 'a3_place_dedupe', 'a3_place_dedupe_check'];
    -- Judge / validate stages whose usable deployments (enabled, on an enabled LLM connection the stage's scopes
    -- allow, aliases expanded) are all in ONE failure domain: the invariant of shared/llm_client/invariant.py.
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
    changed  text[] := ARRAY[]::text[];
    skipped  text[] := ARRAY[]::text[];
    bad      text;
    n        int;
    i        int;
BEGIN
    -- ── 0. Guard: predecessors ───────────────────────────────────────────────────────────────────────────────────
    IF to_regclass('shared.llm_role_config') IS NULL OR to_regclass('shared.llm_model_catalog') IS NULL
       OR to_regclass('shared.llm_model_deployment') IS NULL OR to_regclass('shared.llm_provider_connection') IS NULL
       OR to_regclass('shared.llm_model_alias') IS NULL THEN
        RAISE EXCEPTION 'migration 331: a registry table is missing (llm_role_config, llm_model_catalog, '
                        'llm_model_deployment, llm_provider_connection, llm_model_alias): apply 304 and 307';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'shared.llm_provider_connection'::regclass AND attname = 'failure_domain'
                      AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 331: shared.llm_provider_connection.failure_domain is missing: apply 322 first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '324') THEN
        RAISE EXCEPTION 'migration 331: apply 324 first (the acc2 candidate models)';
    END IF;
    IF cardinality(stages) <> cardinality(picks) THEN
        RAISE EXCEPTION 'migration 331: % stages but % picks', cardinality(stages), cardinality(picks);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_provider_connection
                    WHERE connection_key = 'acc2' AND kind = 'bedrock' AND auth_mode = 'task_role'
                      AND data_scope = 'aws_only' AND enabled
                      AND (served_roles IS NULL OR served_roles @> ARRAY['judge', 'validate']::text[])) THEN
        RAISE EXCEPTION 'migration 331: connection acc2 is not an enabled bedrock / task_role / aws_only row serving '
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
        RAISE EXCEPTION 'migration 331: picks without an enabled non-Anthropic Converse catalog row and an enabled acc2 '
                        'deployment: %', bad;
    END IF;

    -- ── 1. Append the acc2 fallback to each listed stage still in one failure domain ─────────────────────────────
    SELECT coalesce(jsonb_object_agg(stage, jsonb_build_object(
               'model_id', model_id, 'fallbacks', to_jsonb(fallback_model_ids), 'shadow', shadow_model_id,
               'scopes', to_jsonb(allowed_scopes))), '{}'::jsonb)
      INTO before
      FROM shared.llm_role_config WHERE stage = ANY (stages);
    EXECUTE breach_sql INTO breached;

    FOR i IN 1 .. cardinality(stages) LOOP
        UPDATE shared.llm_role_config r
           SET fallback_model_ids = r.fallback_model_ids || picks[i],
               updated_at         = now(),
               updated_by         = actor
         WHERE r.stage = stages[i]
           AND r.role IN ('judge', 'validate')
           AND r.stage = ANY (breached)
           AND r.model_id <> picks[i]
           AND NOT (picks[i] = ANY (r.fallback_model_ids))
           AND r.shadow_model_id IS DISTINCT FROM picks[i];
        GET DIAGNOSTICS n = ROW_COUNT;
        IF n = 1 THEN
            changed := changed || stages[i];
        ELSE
            skipped := skipped || stages[i];
        END IF;
    END LOOP;

    -- ── 2. Guard: the routes as decided ──────────────────────────────────────────────────────────────────────────
    SELECT string_agg(r.stage, ', ' ORDER BY r.stage) INTO bad
      FROM shared.llm_role_config r
     WHERE r.updated_by = actor
       AND (r.role NOT IN ('judge', 'validate') OR NOT (r.stage = ANY (stages))
            OR cardinality(r.fallback_model_ids) = 0
            OR r.fallback_model_ids[cardinality(r.fallback_model_ids)] <> picks[array_position(stages, r.stage)]
            OR (SELECT count(*) FROM unnest(r.fallback_model_ids) AS f
                 WHERE f = picks[array_position(stages, r.stage)]) <> 1
            OR r.model_id = picks[array_position(stages, r.stage)]
            OR r.shadow_model_id IS NOT DISTINCT FROM picks[array_position(stages, r.stage)]);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 331: rows of this file that are not a listed judge / validate stage ending once on '
                        'its acc2 pick: %', bad;
    END IF;

    -- The AWS primary, every earlier fallback, the shadow and the scopes are what they were.
    SELECT string_agg(r.stage, ', ' ORDER BY r.stage) INTO bad
      FROM shared.llm_role_config r
     WHERE r.stage = ANY (changed)
       AND (r.model_id IS DISTINCT FROM before -> r.stage ->> 'model_id'
            OR to_jsonb(r.fallback_model_ids)
               IS DISTINCT FROM (before -> r.stage -> 'fallbacks') || to_jsonb(picks[array_position(stages, r.stage)])
            OR r.shadow_model_id IS DISTINCT FROM before -> r.stage ->> 'shadow'
            OR to_jsonb(r.allowed_scopes) IS DISTINCT FROM before -> r.stage -> 'scopes');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 331: routes changed beyond the appended fallback: %', bad;
    END IF;

    -- Every changed stage now reaches a second failure domain.
    EXECUTE breach_sql INTO breached;
    SELECT string_agg(s, ', ' ORDER BY s) INTO bad FROM unnest(changed) AS s WHERE s = ANY (breached);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 331: stages still in one failure domain after their acc2 fallback: %', bad;
    END IF;

    -- Writers never route to an acc2-only chat model (ADR 0009 decision 14); this file opens no tenant stage.
    SELECT string_agg(DISTINCT r.stage || ':' || k.key, ', ') INTO bad
      FROM shared.llm_role_config r
     CROSS JOIN LATERAL unnest(ARRAY[r.model_id, r.shadow_model_id] || r.fallback_model_ids) AS k (key)
     WHERE r.role = 'writer'
       AND EXISTS (SELECT 1 FROM shared.llm_model_deployment d
                    WHERE d.model_key = k.key AND d.connection_key = 'acc2')
       AND NOT EXISTS (SELECT 1 FROM shared.llm_model_deployment d
                        WHERE d.model_key = k.key AND d.connection_key <> 'acc2')
       AND EXISTS (SELECT 1 FROM shared.llm_model_catalog m WHERE m.model_key = k.key AND m.api_style = 'converse');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 331: writer routes naming an acc2-only chat model: %', bad;
    END IF;
    SELECT string_agg(stage, ', ' ORDER BY stage) INTO bad
      FROM shared.llm_role_config
     WHERE updated_by = actor AND (stage ~ '^t[0-9]' OR stage LIKE 'tp\_%');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 331: tenant / TripPlanner stages changed by this file (ADR 0009 decision 14): %', bad;
    END IF;

    -- A check stage and the stage it checks stay on different makers: the family a pair member gained here is not a
    -- family of the other member's route.
    FOR i IN 1 .. cardinality(pairs) / 2 LOOP
        SELECT string_agg(DISTINCT x.stage || ':' || coalesce(mx.family, mx.vendor), ', ') INTO bad
          FROM shared.llm_role_config x
          JOIN shared.llm_role_config y
            ON (x.stage, y.stage) IN ((pairs[2 * i - 1], pairs[2 * i]), (pairs[2 * i], pairs[2 * i - 1]))
          JOIN shared.llm_model_catalog mx ON mx.model_key = x.fallback_model_ids[cardinality(x.fallback_model_ids)]
         WHERE x.stage = ANY (changed)
           AND EXISTS (SELECT 1
                         FROM unnest(ARRAY[y.model_id] || y.fallback_model_ids) AS k (key)
                         JOIN shared.llm_model_catalog my ON my.model_key = k.key
                        WHERE coalesce(my.family, my.vendor) = coalesce(mx.family, mx.vendor));
        IF bad IS NOT NULL THEN
            RAISE EXCEPTION 'migration 331: a check pair would share a maker through the acc2 fallback: %', bad;
        END IF;
    END LOOP;

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
            RAISE EXCEPTION 'migration 331: no passing contract smoke on the acc2 pick (run the llm_contract_smoke job '
                            'live first, re-pick or drop a failing stage): %', bad;
        END IF;
    ELSE
        RAISE NOTICE 'migration 331: shared.llm_call_log is empty (a replay): the contract smoke order gate is skipped';
    END IF;

    RAISE NOTICE 'migration 331: stages given an acc2 fallback: %',
        coalesce(nullif(array_to_string(changed, ', '), ''), '(none)');
    IF cardinality(skipped) > 0 THEN
        RAISE NOTICE 'migration 331: listed stages left as they are (no row, not judge / validate, already in two '
                     'failure domains, or already naming the pick): %', array_to_string(skipped, ', ');
    END IF;
    RAISE NOTICE 'migration 331: judge / validate stages still in one failure domain: %',
        coalesce(nullif(array_to_string(breached, ', '), ''), '(none)');
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('331', now(), 'AA-1026 I6: platform judge / validate stages reaching only acc3 get an acc2 Bedrock model as '
                      'their last fallback (nova-lite; llama4-scout for a3_place_card_check)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
