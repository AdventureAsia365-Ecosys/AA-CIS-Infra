-- break-glass: remove uncalibrated rungs (S271 W0, tech lead D7)
-- Migration 383: AA-900 / AA-741 (S271 writing-quality restructure, wave W0; tech lead decisions D7 and D16 chosen
-- 06/11/2026, root docs/audits/2026-11-06-S271-writing-quality-audit/decisions.md) — no writer route silently falls
-- to a model of another family, and no judge instrument silently falls to Nova Lite.
--
-- Why. D7: "the one judge allowed to hold a piece is calibrated in R1, pinned on one rung with no fallback; GPT-6 off
-- every writer route". The audit (design-review.json arch.roadmap[0] W0 and crit F4 / M6 / M7) found two kinds of
-- uncalibrated rungs on the live routes (the post-376 table, docs/generated/llm-routes.snapshot.json of 05/11):
--   1. GPT-6 Luna on the OpenAI API (gpt-6-luna-openai) at the end of 13 writer routes. When it answers, a tour or
--      blog text is written by an OpenAI model that no writer eval qualified, and then checked by the same GPT-6
--      Luna family the instrument uses (t9_repair repaired by gpt-6-luna-openai and verified by gpt-6-luna-openai:
--      invariant 6 broken). Nothing marks the piece: the ledger shows the fallback, the product does not.
--   2. Amazon Nova Lite (nova-lite, acc2) as the last rung of every judge route and of the t10_claims instrument.
--      Its measured agreement with the human labels is kappa 0.137 (eval run 08c34cb4, the writing-memory judge);
--      when it answers, a hold / pass verdict or a mined writing-memory rule comes from a model no calibration
--      backs (M7: writing_memory_mine / eval would keep mining rules from it).
--   With acc3 refusing every 5.x / GPT model since 29/10 and the Anthropic API key on (S269, route version 4: the
--   Claude 5.x rows API-first), a writer has two Claude failure domains (anthropic-direct and acc3) before it ever
--   reached the OpenAI rung, and a GPT judge has GPT-6 Luna on the OpenAI API (its vendor twin) before Nova Lite.
--
-- What (rule-based: the model is removed from every row of the role, whatever the rest of its chain; order kept):
--   1. shared.llm_role_config.fallback_model_ids: 'gpt-6-luna-openai' removed from every row whose role is writer.
--      On the post-376 table (13 rows):
--        s1_generate, supply_content_writer, t2_generate, t8_angle_gen, t9_write
--                       sonnet-5-5   sonnet-4-6, gpt-6-luna-openai         -> sonnet-4-6
--        a0_column_map, s1_flag_fix, s1_itinerary_nudge, t2_flag_fix, t2_itinerary_nudge, t9_repair,
--        segment_research, segment_research_batch
--                       haiku-5-5    haiku-4-5, gpt-6-luna-openai          -> haiku-4-5
--      Every one of them keeps a same-family rung (Sonnet 4.6 / Haiku 4.5: acc3 and the Anthropic API since 376).
--      A writer whose ONLY fallback was the removed rung (not on Dev; the replayed migrations leave s1_generate /
--      t2_generate on [haiku-5-5, gpt-6-luna-openai], and an admin could save such a chain) gets its primary's working
--      older sibling instead, the 366 rule (Sonnet 5.5 -> Sonnet 4.6, Haiku 5.5 -> Haiku 4.5); with another primary
--      the file stops (a route with no fallback is the chain rule no_fallback).
--      tp_compose / tp_extract / s1_atom_writer never named it. supply_content_writer and a0_column_map are writer
--      rows too (D7: "every writer route"), though not tour prose: the rule is per role, not per stage.
--   2. 'nova-lite' removed from every row whose role is judge, and from the validate instrument t10_claims (the F9
--      v2 claim extractor, scored as an instrument by W2). On the post-376 table (10 rows):
--        s1_judge, t2_judge, t7_debate_judge, t10_judge, writing_memory_eval, writing_memory_mine, s1_brand_audit,
--        t2_brand_audit
--                       gpt-5.6-luna gpt-6-luna, gpt-6-luna-openai, nova-lite      -> gpt-6-luna, gpt-6-luna-openai
--        t10_adjudicate, t10_claims
--                       gpt-6-luna   gpt-6-luna-openai, gpt-5.6-luna, nova-lite    -> gpt-6-luna-openai, gpt-5.6-luna
--      The two brand audits are judge rows the task list did not name: a brand-voice verdict is a judge verdict, and
--      the CI lint (tests/unit/test_aa900_w0_route_lint.py) keeps every judge row off nova-lite. s1_judge keeps its
--      route; D9 takes it off the live path in a later lane (sampling in the Writing Lab), not here.
--      Kept on purpose (validate rows, decided per row, recorded in the lint's allowlist with the same reasons):
--        t9_faq_filter, t9_faq_answer_fit  drop-only checks behind T9_FAQ_LLM_FILTER (default off): on failure the
--            code keeps the deterministic FAQ list / the answer unchanged, never a hold. Their primary is Claude, the
--            writer's family; nova-lite is the only other-maker rung there, so it adds no same-family pair. Not a
--            verifier-family hazard; W2 measures them like any detector.
--        a3_atomize, a3_place_card, a3_place_days, a3_place_dedupe_check, a3_place_locate, s1_source_facts
--            evidence producers / place checks (A3 and S1 facts), not content instruments; F10 measures their
--            precision in W1 / W2 before any change. The shared GPT family of a3_* and the instrument is recorded
--            for ADR 0020 (F4), not changed here.
--   3. degrade_mode 'queue_retry' (CIS's mode, tech lead T-21: the job stops and is re-queued once the stage runs
--      again) on every writer row this file changes whose degrade_mode is NULL (t2_generate / t9_write already have
--      it, 326; segment_research* 335). Declarative (the failure-domain report, shared/llm_client/invariant.py):
--      these rows keep two failure domains (acc3 and anthropic-direct), so no report line changes today; the mode
--      says what the product does when both are gone, which is now the case without an OpenAI rung.
--   4. One route config version (CIS 370): action external, created_by migration-383-aa900, the snapshot of the
--      routes and provider order after this file and its diff against the version in force (the 376 recipe), so the
--      ledger rows written after the apply carry the version that routes them and the admin keeps a one-click revert.
--      Like 376's, the diff also records any deployment drift not yet versioned when the file applies (a provider
--      order entry this file did not cause): the version after 383 is exact either way.
--   5. Register 383.
--   The acc3 rungs known to refuse (gpt-6-luna, gpt-5.6-luna, the 5.x Claude rows on acc3) stay: the refusal circuit
--   skips them at 0 USD (AA-1042 / lane l11). Primary, role, shadow, scopes, pii_class and is_active of every row do
--   not change; no catalog, deployment or connection row changes.
--
-- Guards (RAISE rolls the whole file back):
--   before: 370 and 376 registered; gpt-6-luna-openai is a catalog row of a non-Anthropic family and nova-lite an
--           acc2 Amazon row (the keys this file removes are the models it means); no writer row has
--           gpt-6-luna-openai as primary and no judge / instrument row has nova-lite as primary (removing a primary
--           is a route decision, not this file's).
--   after:  every row keeps everything but fallback_model_ids / degrade_mode / updated_at / updated_by; a changed
--           row's fallbacks are its old ones minus the removed key, order kept; only such rows carry this file's
--           updated_by (a sibling-filled writer: [sibling] where it had [gpt-6-luna-openai]); every changed row
--           keeps at least one fallback and a model with an enabled deployment on an
--           enabled connection in its scopes; no writer row names a model of another family than its primary's
--           (coalesce(family, vendor)); no judge / instrument row names nova-lite; the chain rules of
--           api/services/llm_route_chains.py (RAISE on a row this file changed, NOTICE on the rest).
--   NOTICE: the stages changed, the sibling-filled writers, the listed stages whose fallbacks were not the post-376
--           ones (an admin's chain: the rule is applied to it all the same), the degrade modes set, the route config
--           version.
--
-- Behaviour on Dev. A writer whose Claude rungs all fail (acc3 refusing, the Anthropic API capped or refused) now
-- fails its call instead of answering on GPT-6 Luna through the OpenAI API: the S1 / T2 / T9 jobs stop and re-queue
-- (queue_retry), the error is the gateway's route-exhausted error. A judge / t10_claims call whose GPT rungs all fail
-- (acc3 refusing, the OpenAI API capped at 10 USD a month) fails instead of answering on Nova Lite: the verdict is
-- missing (unverified), never an uncalibrated one. Spend: none added; the OpenAI API cap now serves only the GPT
-- stages. Writing-memory release fingerprints read the writer / judge routes: run the reverify scan after the apply.
--
-- Class: contract (root ADR 0017 d3: UPDATE of route config rows, INSERT of a route config version), no migrate
-- directive line. Migration-only PR (MIG-4: no code needs this file; the code already reads every column it writes).
-- On Dev Infra Migration Apply applies it once every job table is idle (root ADR 0017a). After the apply: the route
-- control preview (GET /admin/llm-route-control/preview or the Routing tab: valid, every stage serving), POST
-- /admin/writing-memory/releases/reverify-scan (writer / judge routes changed outside the admin PATCH), the
-- bot/db-schema-reference PR. DM-7.1: no new table.
--
-- Number. Main max is 382 (06/11: CIS #1347), so 383 (the migration preflight refuses any other). Renumber to main
-- max + 1 if needed: git grep '383_' and 'migration 383' / 'CIS 383' / 'migration-383' / "'383'" / 'after_383'
-- (file, tests, snapshot, actor, version, notes).
--
-- Rollback (a NEW forward migration, or the admin route control's revert to the version before this file's): put
-- 'gpt-6-luna-openai' back at the end of the 13 writer rows and 'nova-lite' back at the end of the 10 judge /
-- instrument rows updated_by 'migration-383-aa900'; degrade_mode back to NULL on the rows this file set it on (the
-- NOTICE lists them). The writer change is a decision (D7): a rollback needs the tech lead's word.
--
-- X1. One BEGIN … COMMIT block, no role switch (DB Migrate runs cis/ files as cis_owner, the owner of every table
-- here). Grants: none (existing tables).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    actor        constant text := 'migration-383-aa900';
    writer_drop  constant text := 'gpt-6-luna-openai';      -- the other-maker writer rung (S235 / 344 last resort)
    instr_drop   constant text := 'nova-lite';              -- the uncalibrated acc2 judge rung (331 / 332 / 333)
    instr_validate constant text[] := ARRAY['t10_claims']; -- validate rows scored as instruments (plus every judge)
    max_attempts constant int := 6;                         -- shared/llm_client/errors.py MAX_CHAIN_ATTEMPTS
    text_roles   constant text[] := ARRAY['writer', 'judge', 'validate'];
    pairs        constant text[] := ARRAY['a3_place_card_check', 'a3_place_card', 'a3_place_dedupe_check',
                                          'a3_place_dedupe'];
    -- the post-376 fallbacks of the rows this file is meant for (tests/unit/snapshots/aa1042_routes_after_376.json):
    -- a row whose live fallbacks differ is reported (an admin's chain), the rule applies to it all the same
    post376      constant jsonb := $p${
        "s1_generate":            ["sonnet-4-6", "gpt-6-luna-openai"],
        "supply_content_writer":  ["sonnet-4-6", "gpt-6-luna-openai"],
        "t2_generate":            ["sonnet-4-6", "gpt-6-luna-openai"],
        "t8_angle_gen":           ["sonnet-4-6", "gpt-6-luna-openai"],
        "t9_write":               ["sonnet-4-6", "gpt-6-luna-openai"],
        "a0_column_map":          ["haiku-4-5", "gpt-6-luna-openai"],
        "s1_flag_fix":            ["haiku-4-5", "gpt-6-luna-openai"],
        "s1_itinerary_nudge":     ["haiku-4-5", "gpt-6-luna-openai"],
        "t2_flag_fix":            ["haiku-4-5", "gpt-6-luna-openai"],
        "t2_itinerary_nudge":     ["haiku-4-5", "gpt-6-luna-openai"],
        "t9_repair":              ["haiku-4-5", "gpt-6-luna-openai"],
        "segment_research":       ["haiku-4-5", "gpt-6-luna-openai"],
        "segment_research_batch": ["haiku-4-5", "gpt-6-luna-openai"],
        "s1_judge":               ["gpt-6-luna", "gpt-6-luna-openai", "nova-lite"],
        "t2_judge":               ["gpt-6-luna", "gpt-6-luna-openai", "nova-lite"],
        "t7_debate_judge":        ["gpt-6-luna", "gpt-6-luna-openai", "nova-lite"],
        "t10_judge":              ["gpt-6-luna", "gpt-6-luna-openai", "nova-lite"],
        "writing_memory_eval":    ["gpt-6-luna", "gpt-6-luna-openai", "nova-lite"],
        "writing_memory_mine":    ["gpt-6-luna", "gpt-6-luna-openai", "nova-lite"],
        "s1_brand_audit":         ["gpt-6-luna", "gpt-6-luna-openai", "nova-lite"],
        "t2_brand_audit":         ["gpt-6-luna", "gpt-6-luna-openai", "nova-lite"],
        "t10_adjudicate":         ["gpt-6-luna-openai", "gpt-5.6-luna", "nova-lite"],
        "t10_claims":             ["gpt-6-luna-openai", "gpt-5.6-luna", "nova-lite"]
    }$p$::jsonb;
    before       jsonb;                 -- every row: what must not change
    old_fall     jsonb;                 -- every row: its fallbacks before this file
    old_deg      jsonb;                 -- every row: its degrade mode before this file
    old_by       jsonb;                 -- every row: its updated_by before this file (a re-apply finds its own)
    outside      text[];
    acc2_only    text[];
    twin_pairs   text[];
    -- a Claude 5.5 primary -> its working older sibling on acc3 and the Anthropic API (366 / 376)
    siblings     constant jsonb := '{"sonnet-5-5": "sonnet-4-6", "haiku-5-5": "haiku-4-5"}'::jsonb;
    changed      text[] := ARRAY[]::text[];
    filled       text[] := ARRAY[]::text[];
    degraded     text[] := ARRAY[]::text[];
    differed     text[] := ARRAY[]::text[];
    r            record;
    bad          text;
    prev_version bigint;
    prev_snap    jsonb;
    live_snap    jsonb;
    changes      jsonb;
BEGIN
    -- ── 0. Guards: predecessors and the keys this file removes ─────────────────────────────────────────────────────
    IF EXISTS (SELECT 1 FROM unnest(ARRAY['370', '376']) AS v (n)
                WHERE NOT EXISTS (SELECT 1 FROM shared.schema_versions s WHERE s.version = v.n)) THEN
        RAISE EXCEPTION 'migration 383: apply 370 and 376 first (route versions, the post-376 chains)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog m
                    WHERE m.model_key = writer_drop AND coalesce(m.family, m.vendor) <> 'anthropic') THEN
        RAISE EXCEPTION 'migration 383: % is not a catalog row of a non-Anthropic family', writer_drop;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog m
                    WHERE m.model_key = instr_drop AND coalesce(m.family, m.vendor) = 'amazon') THEN
        RAISE EXCEPTION 'migration 383: % is not the Amazon catalog row (migration 324)', instr_drop;
    END IF;
    SELECT string_agg(rc.stage, ', ' ORDER BY rc.stage) INTO bad
      FROM shared.llm_role_config rc
     WHERE (rc.role = 'writer' AND rc.model_id = writer_drop)
        OR ((rc.role = 'judge' OR rc.stage = ANY (instr_validate)) AND rc.model_id = instr_drop);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 383: routes whose PRIMARY is a rung this file removes (change them in the admin '
                        'route control first): %', bad;
    END IF;

    SELECT coalesce(jsonb_object_agg(stage, to_jsonb(rc) - 'updated_at' - 'updated_by' - 'fallback_model_ids'
                                            - 'degrade_mode'), '{}'),
           coalesce(jsonb_object_agg(stage, to_jsonb(coalesce(rc.fallback_model_ids, ARRAY[]::text[]))), '{}'),
           coalesce(jsonb_object_agg(stage, to_jsonb(rc.degrade_mode)), '{}'),
           coalesce(jsonb_object_agg(stage, to_jsonb(rc.updated_by)), '{}')
      INTO before, old_fall, old_deg, old_by
      FROM shared.llm_role_config rc;

    SELECT coalesce(array_agg(s ORDER BY s), ARRAY[]::text[]) INTO differed
      FROM jsonb_object_keys(post376) AS k (s)
     WHERE old_fall ? s AND old_fall -> s IS DISTINCT FROM post376 -> s;

    -- ── 1-2. The routes: the rung removed, order kept ──────────────────────────────────────────────────────────────
    -- A writer whose only fallback was the removed rung gets its primary's working older sibling instead (the 366
    -- rule: Sonnet 5.5 -> Sonnet 4.6, Haiku 5.5 -> Haiku 4.5); with no sibling known the guard below stops the file.
    WITH w AS (
        UPDATE shared.llm_role_config rc
           SET fallback_model_ids = CASE
                   WHEN rc.role = 'writer' AND cardinality(array_remove(rc.fallback_model_ids, writer_drop)) = 0
                        AND siblings ? rc.model_id
                   THEN ARRAY[siblings ->> rc.model_id]
                   ELSE array_remove(rc.fallback_model_ids,
                                     CASE WHEN rc.role = 'writer' THEN writer_drop ELSE instr_drop END) END,
               updated_at         = now(),
               updated_by         = actor
         WHERE (rc.role = 'writer' AND writer_drop = ANY (rc.fallback_model_ids))
            OR ((rc.role = 'judge' OR rc.stage = ANY (instr_validate)) AND instr_drop = ANY (rc.fallback_model_ids))
        RETURNING rc.stage, rc.role, rc.model_id
    )
    SELECT coalesce(array_agg(stage ORDER BY stage), ARRAY[]::text[]),
           coalesce(array_agg(stage ORDER BY stage) FILTER (
               WHERE role = 'writer' AND siblings ? model_id
                 AND old_fall -> stage = to_jsonb(ARRAY[writer_drop])), ARRAY[]::text[])
      INTO changed, filled FROM w;

    -- ── 3. The declared degrade mode of a changed writer row that has none ─────────────────────────────────────────
    WITH w AS (
        UPDATE shared.llm_role_config rc
           SET degrade_mode = 'queue_retry'
         WHERE rc.stage = ANY (changed) AND rc.role = 'writer' AND rc.degrade_mode IS NULL
        RETURNING rc.stage
    )
    SELECT coalesce(array_agg(stage ORDER BY stage), ARRAY[]::text[]) INTO degraded FROM w;

    -- ── 4. Guards: the rows ────────────────────────────────────────────────────────────────────────────────────────
    SELECT string_agg(rc.stage, ', ' ORDER BY rc.stage) INTO bad
      FROM shared.llm_role_config rc
     WHERE NOT (before ? rc.stage)
        OR to_jsonb(rc) - 'updated_at' - 'updated_by' - 'fallback_model_ids' - 'degrade_mode'
               IS DISTINCT FROM before -> rc.stage
        OR (rc.updated_by = actor AND (old_by ->> rc.stage) IS DISTINCT FROM actor AND NOT (rc.stage = ANY (changed)))
        OR (rc.stage = ANY (changed) AND NOT (rc.stage = ANY (filled))
            AND to_jsonb(rc.fallback_model_ids) IS DISTINCT FROM to_jsonb(array_remove(
                ARRAY(SELECT jsonb_array_elements_text(old_fall -> rc.stage)),
                CASE WHEN rc.role = 'writer' THEN writer_drop ELSE instr_drop END)))
        OR (rc.stage = ANY (filled) AND (old_fall -> rc.stage IS DISTINCT FROM to_jsonb(ARRAY[writer_drop])
                                         OR rc.fallback_model_ids IS DISTINCT FROM ARRAY[siblings ->> rc.model_id]))
        OR (NOT (rc.stage = ANY (changed))
            AND to_jsonb(coalesce(rc.fallback_model_ids, ARRAY[]::text[])) IS DISTINCT FROM old_fall -> rc.stage)
        OR (rc.degrade_mode IS DISTINCT FROM (old_deg ->> rc.stage) AND NOT (rc.stage = ANY (degraded)));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 383: route rows changed beyond the removed rung: %', bad;
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(before)) <> (SELECT count(*) FROM shared.llm_role_config) THEN
        RAISE EXCEPTION 'migration 383: a route row appeared or disappeared';
    END IF;

    SELECT string_agg(rc.stage, ', ' ORDER BY rc.stage) INTO bad
      FROM shared.llm_role_config rc
     WHERE rc.stage = ANY (changed) AND cardinality(coalesce(rc.fallback_model_ids, ARRAY[]::text[])) = 0;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 383: changed routes left with no fallback and no known sibling of their primary '
                        '(add a same-family rung in the admin route control first): %', bad;
    END IF;

    -- The W0 rules (the CI lint tests/unit/test_aa900_w0_route_lint.py checks the same on the route snapshots).
    SELECT string_agg(DISTINCT rc.stage || ' (' || u.key || ')', ', ') INTO bad
      FROM shared.llm_role_config rc
     CROSS JOIN LATERAL unnest(coalesce(rc.fallback_model_ids, ARRAY[]::text[])) AS u (key)
      LEFT JOIN shared.llm_model_catalog p ON p.model_key = rc.model_id
      LEFT JOIN shared.llm_model_catalog m ON m.model_key = u.key
     WHERE rc.role = 'writer'
       AND (p.model_key IS NULL OR m.model_key IS NULL
            OR coalesce(m.family, m.vendor) IS DISTINCT FROM coalesce(p.family, p.vendor));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 383: writer routes naming a model of another family than their primary: %', bad;
    END IF;
    SELECT string_agg(rc.stage, ', ' ORDER BY rc.stage) INTO bad
      FROM shared.llm_role_config rc
     WHERE (rc.role = 'judge' OR rc.stage = ANY (instr_validate))
       AND instr_drop = ANY (ARRAY[rc.model_id] || coalesce(rc.fallback_model_ids, ARRAY[]::text[]));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 383: judge / instrument routes still naming %: %', instr_drop, bad;
    END IF;

    -- Every changed row still has a model that can be called: enabled in the catalog, with an enabled deployment on
    -- an enabled connection in its scopes (circuits and refusals are runtime: the route control preview shows them).
    SELECT string_agg(rc.stage, ', ' ORDER BY rc.stage) INTO bad
      FROM shared.llm_role_config rc
     WHERE rc.stage = ANY (changed)
       AND NOT EXISTS (
           SELECT 1 FROM unnest(ARRAY[rc.model_id] || rc.fallback_model_ids) AS u (key)
             JOIN shared.llm_model_catalog m ON m.model_key = u.key AND m.enabled
             JOIN shared.llm_model_deployment d ON d.model_key = u.key AND d.enabled
             JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key AND c.enabled
            WHERE c.data_scope = ANY (coalesce(rc.allowed_scopes, ARRAY['aws_only'])));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 383: changed routes with no enabled model on an enabled connection: %', bad;
    END IF;

    -- The chain rules (api/services/llm_route_chains.py violations, as migration 376 computes them) on every active
    -- row: RAISE for a row this file changed, NOTICE for the rest (an admin's route is reported, never rewritten).
    SELECT coalesce(array_agg(x), ARRAY[]::text[]) INTO outside
      FROM (SELECT d.model_key AS x
              FROM shared.llm_model_deployment d
              JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key
             GROUP BY d.model_key
            HAVING bool_and(c.data_scope <> 'aws_only')) o;
    SELECT coalesce(array_agg(x), ARRAY[]::text[]) INTO acc2_only
      FROM (SELECT d.model_key AS x
              FROM shared.llm_model_deployment d
              JOIN shared.llm_model_catalog m ON m.model_key = d.model_key AND m.api_style <> 'embed'
             GROUP BY d.model_key
            HAVING bool_and(d.connection_key = 'acc2')) a;
    WITH base AS (
        SELECT m.model_key, coalesce(m.family, m.vendor) AS fam, m.model_key = ANY (outside) AS out_only,
               regexp_replace(
                   CASE WHEN left(w.id, length(lower(m.vendor)) + 1) = lower(m.vendor) || '.'
                        THEN substr(w.id, length(m.vendor) + 2) ELSE w.id END,
                   '(-v[0-9]+(:[0-9]+)?|:[0-9]+)$', '') AS base
          FROM shared.llm_model_catalog m
         CROSS JOIN LATERAL (
               SELECT regexp_replace(lower(btrim(x)), '^(global|us|eu|apac|jp|au|ca)\.', '') AS id
                 FROM (SELECT pr.value AS x FROM jsonb_each_text(
                           CASE WHEN jsonb_typeof(m.bedrock_profile_ids) = 'object' THEN m.bedrock_profile_ids
                                ELSE '{}'::jsonb END) AS pr
                        WHERE NOT (m.model_key = ANY (outside))
                       UNION ALL
                       SELECT m.wire_model) ids
                WHERE x IS NOT NULL AND btrim(x) <> '') w
         WHERE m.api_style <> 'embed'
    )
    SELECT coalesce(array_agg(DISTINCT v.model_key || '>' || a.model_key), ARRAY[]::text[]) INTO twin_pairs
      FROM base v JOIN base a ON a.fam = v.fam AND a.base = v.base AND a.model_key <> v.model_key
     WHERE v.out_only AND NOT a.out_only AND v.base <> '';

    FOR r IN
        WITH routes AS (
            SELECT rc.stage, rc.role, rc.shadow_model_id,
                   coalesce(rc.allowed_scopes, ARRAY['aws_only']) AS scopes,
                   coalesce(rc.fallback_model_ids, ARRAY[]::text[]) AS f,
                   ARRAY[rc.model_id] || coalesce(rc.fallback_model_ids, ARRAY[]::text[]) AS chain
              FROM shared.llm_role_config rc WHERE rc.is_active
        ), keyed AS (
            SELECT rt.*, kk.key, kk.ord, kk.key = ANY (outside) AS out_only,
                   kk.ord > 1 AND (kk.key || '>' || rt.chain[kk.ord - 1]) = ANY (twin_pairs) AS twin_slot,
                   (SELECT coalesce(m.family, m.vendor) FROM shared.llm_model_catalog m WHERE m.model_key = kk.key) AS fam
              FROM routes rt CROSS JOIN LATERAL unnest(rt.chain) WITH ORDINALITY AS kk (key, ord)
        ), attempts AS (
            SELECT rt.stage, (SELECT count(*) FROM (SELECT DISTINCT unnest(rt.chain) AS key) u
                                JOIN shared.llm_model_deployment d ON d.model_key = u.key
                                JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key
                               WHERE c.data_scope = ANY (rt.scopes)) AS n
              FROM routes rt
        )
        SELECT rt.stage, rules.rule FROM routes rt
          JOIN attempts ac ON ac.stage = rt.stage
         CROSS JOIN LATERAL (
            SELECT 'no_fallback' AS rule WHERE cardinality(rt.f) = 0
            UNION ALL
            SELECT 'aws_only_text_stage' WHERE rt.role = ANY (text_roles) AND NOT ('vendor_direct' = ANY (rt.scopes))
            UNION ALL
            SELECT 'vendor_not_last' WHERE EXISTS (
                   SELECT 1 FROM keyed a JOIN keyed b ON a.stage = b.stage AND b.ord > a.ord
                    WHERE a.stage = rt.stage AND a.out_only AND NOT a.twin_slot AND NOT b.out_only)
            UNION ALL
            SELECT 'judge_writer_family' WHERE rt.role = 'judge' AND (
                   EXISTS (SELECT 1 FROM keyed WHERE keyed.stage = rt.stage AND keyed.fam = 'anthropic')
                   OR EXISTS (SELECT 1 FROM shared.llm_model_catalog m WHERE m.model_key = rt.shadow_model_id
                                AND coalesce(m.family, m.vendor) = 'anthropic'))
            UNION ALL
            SELECT 'writer_family' WHERE rt.role = 'writer' AND EXISTS (
                   SELECT 1 FROM keyed WHERE keyed.stage = rt.stage AND keyed.fam IS DISTINCT FROM 'anthropic'
                      AND keyed.fam IS NOT NULL
                      AND NOT (keyed.ord = cardinality(rt.chain) AND keyed.out_only
                               AND 'vendor_direct' = ANY (rt.scopes)))
            UNION ALL
            SELECT 'writer_acc2' WHERE rt.role = 'writer' AND EXISTS (
                   SELECT 1 FROM keyed WHERE keyed.stage = rt.stage AND keyed.key = ANY (acc2_only))
            UNION ALL
            SELECT 'attempt_cap' WHERE ac.n > max_attempts
            UNION ALL
            SELECT 'check_pair_family' WHERE EXISTS (
                   SELECT 1 FROM generate_series(1, cardinality(pairs) / 2) AS g (n)
                     JOIN routes prod ON prod.stage = pairs[2 * g.n]
                    WHERE pairs[2 * g.n - 1] = rt.stage
                      AND EXISTS (SELECT 1 FROM keyed a JOIN keyed b ON a.fam = b.fam
                                   WHERE a.stage = rt.stage AND b.stage = prod.stage))
        ) rules
        ORDER BY 1, 2
    LOOP
        IF r.stage = ANY (changed) THEN
            RAISE EXCEPTION 'migration 383: the new route of % breaks the chain rule %', r.stage, r.rule;
        END IF;
        RAISE NOTICE 'migration 383: route % (not changed here) breaks the chain rule %', r.stage, r.rule;
    END LOOP;

    -- ── 5. The route config version (CIS 370): what this file changed, as one 'external' version ──────────────────
    SELECT current_version INTO prev_version FROM shared.llm_route_settings WHERE singleton FOR UPDATE;
    IF prev_version IS NULL THEN
        RAISE EXCEPTION 'migration 383: shared.llm_route_settings has no row (migration 370)';
    END IF;
    SELECT snapshot INTO prev_snap FROM shared.llm_route_config_version WHERE version = prev_version;
    live_snap := jsonb_build_object(
        'order_mode', (SELECT order_mode FROM shared.llm_route_settings WHERE singleton),
        'routes', coalesce((SELECT jsonb_object_agg(stage, jsonb_build_object(
                                       'model_id', model_id,
                                       'fallback_model_ids', to_jsonb(coalesce(fallback_model_ids, '{}'::text[]))))
                              FROM shared.llm_role_config), '{}'::jsonb),
        'priorities', coalesce((SELECT jsonb_object_agg(model_key, pr)
                                  FROM (SELECT model_key, jsonb_object_agg(connection_key, priority) AS pr
                                          FROM shared.llm_model_deployment GROUP BY model_key) d), '{}'::jsonb));
    -- the diff of shared/llm_client/route_versions.diff: order mode, then each stage whose chain differs, then each
    -- model whose provider order (priority, then connection key) differs; a missing side is null
    WITH chains AS (
        SELECT s.stage,
               CASE WHEN prev_snap -> 'routes' ? s.stage
                    THEN jsonb_build_array(prev_snap -> 'routes' -> s.stage -> 'model_id')
                         || coalesce(prev_snap -> 'routes' -> s.stage -> 'fallback_model_ids', '[]'::jsonb) END AS b,
               CASE WHEN live_snap -> 'routes' ? s.stage
                    THEN jsonb_build_array(live_snap -> 'routes' -> s.stage -> 'model_id')
                         || coalesce(live_snap -> 'routes' -> s.stage -> 'fallback_model_ids', '[]'::jsonb) END AS a
          FROM (SELECT jsonb_object_keys(coalesce(prev_snap -> 'routes', '{}')) AS stage
                UNION SELECT jsonb_object_keys(live_snap -> 'routes')) s
    ), orders AS (
        SELECT mk.model,
               (SELECT jsonb_agg(e.key ORDER BY (e.value)::int, e.key)
                  FROM jsonb_each_text(prev_snap -> 'priorities' -> mk.model) e) AS b,
               (SELECT jsonb_agg(e.key ORDER BY (e.value)::int, e.key)
                  FROM jsonb_each_text(live_snap -> 'priorities' -> mk.model) e) AS a
          FROM (SELECT jsonb_object_keys(coalesce(prev_snap -> 'priorities', '{}')) AS model
                UNION SELECT jsonb_object_keys(live_snap -> 'priorities')) mk
    )
    SELECT coalesce(jsonb_agg(x.c ORDER BY x.grp, x.k COLLATE "C"), '[]'::jsonb) INTO changes
      FROM (SELECT 0 AS grp, '' AS k,
                   jsonb_build_object('kind', 'order_mode', 'before', prev_snap -> 'order_mode',
                                      'after', live_snap -> 'order_mode') AS c
             WHERE (prev_snap -> 'order_mode') IS DISTINCT FROM (live_snap -> 'order_mode')
            UNION ALL
            SELECT 1, ch.stage, jsonb_build_object('kind', 'route', 'stage', ch.stage, 'before', ch.b, 'after', ch.a)
              FROM chains ch WHERE ch.b IS DISTINCT FROM ch.a
            UNION ALL
            SELECT 2, o.model, jsonb_build_object('kind', 'provider_order', 'model', o.model, 'before', o.b,
                                                  'after', o.a)
              FROM orders o WHERE o.b IS DISTINCT FROM o.a) x;
    IF jsonb_array_length(changes) > 0 THEN
        INSERT INTO shared.llm_route_config_version (version, created_by, action, note, snapshot, diff)
        VALUES (prev_version + 1, actor, 'external',
                'CIS 383 (S271 W0, tech lead D7): break-glass, uncalibrated rungs removed: GPT-6 Luna on the OpenAI '
                'API off every writer route, Nova Lite off every judge route and t10_claims.', live_snap, changes);
        UPDATE shared.llm_route_settings
           SET current_version = prev_version + 1, updated_at = now(), updated_by = actor
         WHERE singleton;
    END IF;

    RAISE NOTICE 'migration 383: rung removed on: %', coalesce(nullif(array_to_string(changed, ', '), ''), '(none)');
    IF cardinality(filled) > 0 THEN
        RAISE NOTICE 'migration 383: writers whose only fallback was the removed rung, given their primary''s older '
                     'sibling: %', array_to_string(filled, ', ');
    END IF;
    IF cardinality(degraded) > 0 THEN
        RAISE NOTICE 'migration 383: degrade_mode queue_retry set on: %', array_to_string(degraded, ', ');
    END IF;
    IF cardinality(differed) > 0 THEN
        RAISE NOTICE 'migration 383: listed stages whose fallbacks were not the post-376 ones (the rule was applied '
                     'all the same): %', array_to_string(differed, ', ');
    END IF;
    RAISE NOTICE 'migration 383: route config version %', (SELECT current_version FROM shared.llm_route_settings
                                                           WHERE singleton);
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('383', now(), 'AA-900 / AA-741 (S271 W0, tech lead D7, break-glass): gpt-6-luna-openai off every writer '
                      'route (13 on the post-376 table, degrade_mode queue_retry where none), nova-lite off every '
                      'judge route and t10_claims (10), one external route config version')
ON CONFLICT (version) DO NOTHING;

COMMIT;
