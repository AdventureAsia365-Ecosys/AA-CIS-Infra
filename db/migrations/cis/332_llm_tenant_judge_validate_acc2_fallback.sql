-- Migration 332: AA-1026 slice I6, tenant part — the four TENANT judge / validate stages whose route reaches only acc3
-- get the acc2 Bedrock fallback that migration 331 gave the platform stages, as the LAST entry of their route.
--
-- HELD: merge only after the tech lead's yes to opening acc2 on tenant stages. Root ADR 0009 decision 14 (Accepted
-- 31/10) keeps acc2 chat models off tenant stages "until decision 10 and AA-820 are done" (decision 10: tenant stages
-- use only makers named in the AI register and the tenant terms; AA-820, the tenant terms clause, is In Progress). The
-- data stays inside AWS (acc2 is aws_only, like acc3); what changes is the maker of the model that reads tenant text
-- when acc3 refuses (Amazon instead of OpenAI / Anthropic). The yes should come with a one-line amendment of decision
-- 14 in the root ADR and the Amazon row in the AI Use Register for these stages.
--
-- What. One fallback appended per stage, nothing else changes (primary, earlier fallbacks, shadow, allowed_scopes):
--
--   stage               role      output contract (parser)                                   acc2 fallback
--   t2_brand_audit      judge     json_schema brand_audit_result (Converse tool)             nova-lite
--   t10_claims          validate  json_schema claim_rows (claim_rules.parse_rows; no caller)  nova-lite
--   t9_faq_answer_fit   validate  text JSON items (faq_answer_fit.parse_fit_verdicts)        nova-lite
--   t9_faq_filter       validate  text JSON items (faq_filter.parse_verdicts)                 nova-lite
--
--   Nova Lite is the cheapest acc2 model that meets each contract (the reasons are in migration 331's header); none of
--   these stages is half of a two-maker pair. The contract smoke (job kind llm_contract_smoke) covers all four, and
--   must pass BEFORE this file is applied (it falls back to the planned model): the order gate below refuses a stage
--   whose latest smoke on its pick did not pass. t2_brand_audit is a judge whose pass publishes a tenant rewrite: like
--   s1_brand_audit (331), its acc2 pass is held as manual_check + BRAND_AUDIT_UNCALIBRATED_JUDGE by
--   brand_audit_node.hold_uncalibrated_pass (same node), so an uncalibrated acc2 judge never publishes; the three
--   validate stages go live on the contract smoke alone (ladder rungs calibration / A/B / shadow skipped knowingly, as
--   for 331).
--
-- Guards (RAISE rolls the whole file back): the before-guards of 331, plus 331 registered; after: every row this file
-- changed is one of the four stages above, its model_id / shadow / allowed_scopes unchanged and its fallbacks the old
-- ones plus the pick at the end (once); it now reaches two failure domains; no writer route names an acc2-only chat
-- model; no TripPlanner stage was changed. Order gate (as 331): every stage changed has a passing contract smoke on its
-- pick (the LATEST shared.llm_call_log row with stage 'adhoc_aa1026', quality_signal->>'contract_smoke' = the stage,
-- model = the pick, connection acc2 says parser_ok = true); an empty llm_call_log (a replay) skips it with a NOTICE.
-- NOTICE: stages changed and judge / validate stages still in one domain.
--
-- Class: contract (UPDATE of existing routing rows), no expand header, order like 331 (the code PR deployed and the
-- smoke run live first, then this migration-only PR, Infra copy, manual DB Migrate apply with the job tables idle,
-- bot/db-schema-reference PR). No code depends on it.
-- Rollback (a NEW forward migration): array_remove(fallback_model_ids, 'nova-lite') on the rows updated_by
-- 'migration-332-aa1026', or the admin route PATCH per stage. Keep the AA-CIS-Infra copy byte-identical.
-- X1. One BEGIN … COMMIT block, no role switch (DB Migrate runs cis/ files as cis_owner). Grants: none.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    actor  constant text   := 'migration-332-aa1026';
    stages constant text[] := ARRAY['t2_brand_audit', 't10_claims', 't9_faq_answer_fit', 't9_faq_filter'];
    picks  constant text[] := ARRAY['nova-lite', 'nova-lite', 'nova-lite', 'nova-lite'];
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
        RAISE EXCEPTION 'migration 332: a registry table is missing (llm_role_config, llm_model_catalog, '
                        'llm_model_deployment, llm_provider_connection, llm_model_alias): apply 304 and 307';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'shared.llm_provider_connection'::regclass AND attname = 'failure_domain'
                      AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 332: shared.llm_provider_connection.failure_domain is missing: apply 322 first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '331') THEN
        RAISE EXCEPTION 'migration 332: apply 331 first (the platform part of the acc2 fallback)';
    END IF;
    IF cardinality(stages) <> cardinality(picks) THEN
        RAISE EXCEPTION 'migration 332: % stages but % picks', cardinality(stages), cardinality(picks);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_provider_connection
                    WHERE connection_key = 'acc2' AND kind = 'bedrock' AND auth_mode = 'task_role'
                      AND data_scope = 'aws_only' AND enabled
                      AND (served_roles IS NULL OR served_roles @> ARRAY['judge', 'validate']::text[])) THEN
        RAISE EXCEPTION 'migration 332: connection acc2 is not an enabled bedrock / task_role / aws_only row serving '
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
        RAISE EXCEPTION 'migration 332: picks without an enabled non-Anthropic Converse catalog row and an enabled acc2 '
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
        RAISE EXCEPTION 'migration 332: rows of this file that are not a listed judge / validate stage ending once on '
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
        RAISE EXCEPTION 'migration 332: routes changed beyond the appended fallback: %', bad;
    END IF;

    -- Every changed stage now reaches a second failure domain.
    EXECUTE breach_sql INTO breached;
    SELECT string_agg(s, ', ' ORDER BY s) INTO bad FROM unnest(changed) AS s WHERE s = ANY (breached);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 332: stages still in one failure domain after their acc2 fallback: %', bad;
    END IF;

    -- Writers never route to an acc2-only chat model (ADR 0009 decision 14); this file opens no TripPlanner stage.
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
        RAISE EXCEPTION 'migration 332: writer routes naming an acc2-only chat model: %', bad;
    END IF;
    SELECT string_agg(stage, ', ' ORDER BY stage) INTO bad
      FROM shared.llm_role_config
     WHERE updated_by = actor AND stage LIKE 'tp\_%';
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 332: TripPlanner stages changed by this file: %', bad;
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
            RAISE EXCEPTION 'migration 332: no passing contract smoke on the acc2 pick (run the llm_contract_smoke job '
                            'live first, re-pick or drop a failing stage): %', bad;
        END IF;
    ELSE
        RAISE NOTICE 'migration 332: shared.llm_call_log is empty (a replay): the contract smoke order gate is skipped';
    END IF;

    RAISE NOTICE 'migration 332: stages given an acc2 fallback: %',
        coalesce(nullif(array_to_string(changed, ', '), ''), '(none)');
    IF cardinality(skipped) > 0 THEN
        RAISE NOTICE 'migration 332: listed stages left as they are (no row, not judge / validate, already in two '
                     'failure domains, or already naming the pick): %', array_to_string(skipped, ', ');
    END IF;
    RAISE NOTICE 'migration 332: judge / validate stages still in one failure domain: %',
        coalesce(nullif(array_to_string(breached, ', '), ''), '(none)');
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('332', now(), 'AA-1026 I6 tenant part: t2_brand_audit, t10_claims, t9_faq_answer_fit, t9_faq_filter get the '
                      'acc2 Bedrock model nova-lite as their last fallback (ADR 0009 decision 14 amended)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
