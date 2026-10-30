-- Migration 308: AA-1000 — the Model Gateway stage t10_adjudicate: the T10 tier-2 adjudicator
-- (services/acp_content_writing/seed_align/adjudicate.py).
--
-- Why. Tier 1 of AA-789 (seed alignment, deterministic, CIS #1152) cannot reach some forms of four classes: a
-- paraphrased naming note, a repeat with an implicit subject, an open WHAT / WHY / HOW FAQ answer that does not
-- address its question, and hype such as "hard to overstate". Tier 2 sends only the sentences tier 1 triggered on
-- but left alone, with a seed excerpt, to one cheap model call per attempt (at most 6 sentences); a finding counts
-- only when its two verbatim quotes (sentence and seed) check out. It never holds a piece: its strongest action is
-- one sentence repair or cut, and only in mode `repair`. The code calls this stage only when the worker env
-- T10_ADJ_MODE (or T10_ADJ_MODE_<CLASS>) is shadow or repair; default off = no call.
--
-- What. One shared.llm_role_config row: stage t10_adjudicate, role judge (ADR 0008: it scores the writer's output; a
-- judge stage is non-Anthropic), GPT-6 Luna on acc3 (the cheapest catalog model, $0.10 / $0.50 per Mtok), fallbacks
-- GPT-5.6 Luna (acc3) then GPT-6 Luna on the OpenAI API (last resort only, S235 / 224), no shadow,
-- shadow_sample_pct 0. SAFE_DEFAULTS (shared/llm_client/role_config.py) mirrors the row, so the code works before or
-- without this file. Cost when on: <= ~$0.003 per attempt (<= 6 sentences, max_tokens 4000), <= 3 attempts a piece.
--
-- Class. Additive (one new row, no change to any existing object), but NOT an expand file for the lint: it inserts
-- into an existing table and checks the result in a DO block, so it carries no expand directive and a person
-- applies it through AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/), like 267 / 291.
--
-- Number. 306 is the highest on main; 307 and 308 are claimed by other S259 lanes. This file needs nothing of them
-- (the guard below only reports a missing 306). REQUIRED_CIS_SCHEMA is NOT raised: the row is optional.
--
-- Idempotent: ON CONFLICT (stage) DO NOTHING keeps a row an admin already edited; the guard only checks that a judge
-- row with no shadow exists. Locks: one INSERT.
--
-- Preflight (read-only; expected 1 and 0):
--   SELECT (SELECT count(*) FROM shared.schema_versions WHERE version = '306') AS predecessor,
--          (SELECT count(*) FROM shared.llm_role_config WHERE stage = 't10_adjudicate') AS stage_rows;
--
-- Rollback (the code keeps working on SAFE_DEFAULTS; or set T10_ADJ_MODE=off: no call at all):
--   DELETE FROM shared.llm_role_config WHERE stage = 't10_adjudicate';
--   DELETE FROM shared.schema_versions WHERE version = '308';

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '306') THEN
        RAISE NOTICE 'migration 308: 306 is not registered (Dev applies in version order)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog WHERE model_key = 'gpt-6-luna') THEN
        RAISE EXCEPTION 'migration 308: shared.llm_model_catalog has no gpt-6-luna row (migration 170)';
    END IF;
END $$;

INSERT INTO shared.llm_role_config
    (stage, role, provider, model_id, account_route, is_active, fallback_model_ids,
     shadow_model_id, shadow_sample_pct, updated_by)
VALUES
    ('t10_adjudicate', 'judge', 'openai', 'gpt-6-luna', 'acc3', true,
     ARRAY['gpt-5.6-luna', 'gpt-6-luna-openai']::text[], NULL, 0, 'migration-308-aa1000')
ON CONFLICT (stage) DO NOTHING;

DO $$
DECLARE
    r record;
BEGIN
    SELECT role, shadow_model_id, shadow_sample_pct INTO r
      FROM shared.llm_role_config WHERE stage = 't10_adjudicate';
    IF NOT FOUND OR r.role <> 'judge' THEN
        RAISE EXCEPTION 'migration 308: stage row t10_adjudicate missing or not judge';
    END IF;
    IF r.shadow_model_id IS NOT NULL OR coalesce(r.shadow_sample_pct, 0) <> 0 THEN
        RAISE EXCEPTION 'migration 308: t10_adjudicate must have no shadow (model %, pct %)',
            r.shadow_model_id, r.shadow_sample_pct;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('308', now(), 'AA-1000: Model Gateway stage t10_adjudicate (T10 tier 2, judge, gpt-6-luna acc3, no shadow)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
