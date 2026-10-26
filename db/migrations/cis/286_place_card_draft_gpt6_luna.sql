-- Migration 286: AA-784 (S252) — place-card draft moves from GPT-5.6 Luna to GPT-6 Luna; the fact check stays on
-- Claude Haiku 4.5. Both stay `validate` stages (ADR 0008); draft and check stay on different vendors (the 222 rule).
--
-- Evidence: S252 place-card model evaluation (root docs/audits/2026-10-26-S252-place-card-model-eval/, rule fixed
-- before the paid run in design.md §7, hash in rule-freeze.txt). 30 hard place groups over 13 countries, every fact
-- labelled against web sources by a blind panel (2 labellers + referee, quoted URLs; kappa identity 0.99, verdict
-- 0.77), decisive labels re-checked adversarially; run cost $1.839 (682 llm_call_log rows).
--   pair (draft x check)            FK (wrong kept facts)       invented facts   WI  U     all 9,186 cards  gates
--   GPT-5.6 Luna x Haiku 4.5 (live) 5/125 = 4.0% (run 2: 2.4%)  7/132 = 5.3%     0   3.73  ~$16             fail 3 (FK)
--                                   (run 2: LK 4.1%)                                                         / 4 (LK)
--   GPT-6 Luna   x Haiku 4.5        0/97 = 0% (Wilson 0-3.8%)   0/107 = 0%       0   3.44  ~$13             all 8 pass
-- Four pairs passed all 8 gates, all inside the FK tie band; U ties (spread 0.39 < 0.5), WI ties (0), so the cost
-- tie-breaker picks GPT-6 Luna x Haiku 4.5. Coverage 88% of identifiable groups (79% if the 4 ambiguous groups
-- counted; GPT-6 Luna declines vague names instead of guessing). Haiku 4.5 catches 8/34 natural wrong facts (22/23
-- planted), so quality has to come from the drafter: that is why the drafter changes and the checker does not.
--
-- Fallback {gpt-5.6-luna}, not 222's {sonnet}: the check is Claude Haiku, so a Claude draft fallback makes draft
-- and check the same vendor whenever it fires (222 accepted that, S252 history.md). GPT-5.6 Luna (OpenAI vendor,
-- Bedrock acc3) keeps every card cross-vendor and is the previous live drafter, measured in the same eval (FK
-- 2.4-4.0%): a fallback card is no worse than today's. Trade-off: both keys are catalog keys, so with the catalog
-- unreadable the draft call raises (no card, no miss stored, the next build tries again) instead of drafting on the
-- legacy Sonnet. No OpenAI-platform key (S235/224: last resort only, not needed here). No shadow.
-- a3_place_card_check is NOT changed (haiku, fallback {sonnet}: still Anthropic against an OpenAI draft).
--
-- Catalog guard: gpt-6-luna (migration 170, Bedrock converse, acc3 profile) must exist and be routable. 170 seeded
-- it disabled ("Bedrock agreement not accepted on acc3 yet"); Dev already runs it (s1_source_facts 212, a3_atomize
-- 213, t10_claims 221, a3_place_dedupe 257, and the S252 eval called it), so a still-disabled row (a fresh DB) is
-- enabled here, with a NOTICE. A missing row, a non-converse row, a row without an acc3 profile or without a price
-- refuses the file (a human decision, not a data patch). The fallback gpt-5.6-luna is only reported (the route skips
-- a disabled fallback).
--
-- Deploy order: deploy the app image with place_cards.DRAFT_MAX_TOKENS = 4000 BEFORE applying 286. GPT-6 Luna reasons
-- inside max_tokens (S246: an empty reply at the production 1500); the eval ran it at 4000 (max 1,384 output tokens,
-- all end_turn). On the old image a T8 request could draft at 1500 and store a paid no_name miss. The gateway reads
-- the row per call (20 s cache). Apply in version order through AA-CIS-Infra DB Migrate (byte copy in
-- db/migrations/cis/). Idempotent: a re-run sets the same values.
--
-- Rollback (the 222 row; leave gpt-6-luna enabled: other stages route on it):
--   UPDATE shared.llm_role_config
--      SET role = 'validate', provider = 'openai', model_id = 'gpt-5.6-luna', account_route = 'acc3',
--          fallback_model_ids = ARRAY['sonnet']::text[], updated_at = now(), updated_by = 'rollback-286'
--    WHERE stage = 'a3_place_card';
--   DELETE FROM shared.schema_versions WHERE version = '286';

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    m record;
BEGIN
    SELECT enabled, api_style, bedrock_profile_ids, price_in_per_mtok, price_out_per_mtok, blocked_reason
      INTO m FROM shared.llm_model_catalog WHERE model_key = 'gpt-6-luna';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'migration 286: shared.llm_model_catalog has no gpt-6-luna row (migration 170)';
    END IF;
    IF m.api_style <> 'converse' OR NOT (m.bedrock_profile_ids ? 'acc3')
       OR m.price_in_per_mtok IS NULL OR m.price_out_per_mtok IS NULL THEN
        RAISE EXCEPTION 'migration 286: gpt-6-luna is not routable (api_style %, profiles %, price in % out %)',
            m.api_style, m.bedrock_profile_ids, m.price_in_per_mtok, m.price_out_per_mtok;
    END IF;
    IF NOT m.enabled THEN
        UPDATE shared.llm_model_catalog
           SET enabled = true, blocked_reason = NULL, updated_at = now(), updated_by = 'migration-286-aa784'
         WHERE model_key = 'gpt-6-luna';
        RAISE NOTICE 'migration 286: gpt-6-luna was disabled (%), enabled', m.blocked_reason;
    END IF;
END $$;

UPDATE shared.llm_role_config
   SET role = 'validate', provider = 'openai', model_id = 'gpt-6-luna', account_route = 'acc3',
       fallback_model_ids = ARRAY['gpt-5.6-luna']::text[], updated_at = now(),
       updated_by = 'migration-286-aa784'
 WHERE stage = 'a3_place_card';

DO $$
DECLARE
    r record;
    fb record;
BEGIN
    SELECT model_id, fallback_model_ids INTO r FROM shared.llm_role_config WHERE stage = 'a3_place_card';
    IF NOT FOUND THEN
        RAISE NOTICE 'migration 286: no a3_place_card row (220 not applied?): SAFE_DEFAULTS serve the stage';
    ELSE
        RAISE NOTICE 'migration 286: a3_place_card -> %, fallbacks %', r.model_id, r.fallback_model_ids;
    END IF;
    SELECT enabled, blocked_reason INTO fb FROM shared.llm_model_catalog WHERE model_key = 'gpt-5.6-luna';
    IF NOT FOUND THEN
        RAISE NOTICE 'migration 286: fallback gpt-5.6-luna is not in the catalog: the route skips it';
    ELSIF NOT fb.enabled THEN
        RAISE NOTICE 'migration 286: fallback gpt-5.6-luna is disabled (%): the route skips it',
            COALESCE(fb.blocked_reason, 'no reason given');
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('286', now(), 'AA-784 (S252): a3_place_card -> validate on gpt-6-luna (gpt-5.6-luna fallback, '
                      'cross-vendor with the haiku check); a3_place_card_check unchanged')
ON CONFLICT (version) DO NOTHING;

COMMIT;
