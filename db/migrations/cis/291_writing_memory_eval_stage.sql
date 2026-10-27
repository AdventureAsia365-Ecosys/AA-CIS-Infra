-- Migration 291: AA-919 (WM-19) — the Model Gateway stage writing_memory_eval: the judge of the writing-memory R2
-- runner (services/writing_memory/r2.py, judge in services/writing_memory/eval_judge.py).
--
-- Why. WM-19 scope 3: "Stage memory_eval seeded with shadow_sample_pct = 0". The R2 runner re-judges the stored
-- controls and judges every regenerated candidate output with ONE current judge (cost-cuts K2 (c): judge drift must not
-- fake a win), on a stage of its own so (a) its spend is countable against the writing-memory month cap
-- (services/writing_memory/config.py MEMORY_STAGES) and the runner's per-run cap, (b) no A/B shadow call doubles it
-- (a stage reused from production, e.g. s1_judge, would carry that stage's shadow percentage), and (c) the release
-- reverify scan can fingerprint its route (services/writing_memory/releases.py JUDGE_STAGE, already read since CIS
-- 287: the fingerprint holds judge_route = NULL until this row exists).
--
-- What. One shared.llm_role_config row: stage writing_memory_eval, role judge (ADR 0008: it scores), the judge route
-- every judge stage uses (gpt-5.6-luna on acc3, fallbacks gpt-6-luna, gpt-6-luna-openai; another vendor than the
-- Anthropic writers it scores, app ADR 0010 decision 5), no shadow model, shadow_sample_pct 0. SAFE_DEFAULTS
-- (shared/llm_client/role_config.py) mirrors the row, so the app works before or without this file. No table, no
-- grant, no spend_budget row: the per-run cap (<= $10, configurable lower) and the $25 month cap are enforced in code
-- from shared.llm_call_log (services/writing_memory/r2.py, budget.py).
--
-- Order with the code. None needed: the code reads the stage per call (20 s cache) and falls back to SAFE_DEFAULTS
-- while the row is missing; REQUIRED_CIS_SCHEMA stays 287. Apply before the first live R2 run so the admin LLM
-- Settings page lists the stage and the release fingerprint carries its route. Apply through AA-CIS-Infra DB Migrate
-- (byte copy in db/migrations/cis/), in version order after 290.
--
-- Idempotent: ON CONFLICT (stage) DO NOTHING keeps a row an admin already edited; the guard only checks that a judge
-- row with no shadow exists.
--
-- Preflight (read-only; expected 1 and 0):
--   SELECT (SELECT count(*) FROM shared.schema_versions WHERE version = '290') AS predecessor,
--          (SELECT count(*) FROM shared.llm_role_config WHERE stage = 'writing_memory_eval') AS stage_rows;
--
-- Rollback (the code keeps working on SAFE_DEFAULTS):
--   DELETE FROM shared.llm_role_config WHERE stage = 'writing_memory_eval';
--   DELETE FROM shared.schema_versions WHERE version = '291';

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    -- 291 needs nothing of 290 (a NOTICE, not a refusal: the CI replay may skip a catalog-recipe predecessor).
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '290') THEN
        RAISE NOTICE 'migration 291: 290 is not registered (Dev applies in version order)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_role_config WHERE stage = 'writing_memory_mine' AND role = 'judge') THEN
        RAISE EXCEPTION 'migration 291: the writing_memory_mine judge row (280) is missing';
    END IF;
END $$;

INSERT INTO shared.llm_role_config
    (stage, role, provider, model_id, account_route, is_active, fallback_model_ids,
     shadow_model_id, shadow_sample_pct, updated_by)
VALUES
    ('writing_memory_eval', 'judge', 'openai', 'gpt-5.6-luna', 'acc3', true,
     ARRAY['gpt-6-luna', 'gpt-6-luna-openai']::text[], NULL, 0, 'migration-291-aa919')
ON CONFLICT (stage) DO NOTHING;

DO $$
DECLARE
    r record;
BEGIN
    SELECT role, shadow_model_id, shadow_sample_pct, is_active INTO r
      FROM shared.llm_role_config WHERE stage = 'writing_memory_eval';
    IF NOT FOUND OR r.role <> 'judge' THEN
        RAISE EXCEPTION 'migration 291: stage row writing_memory_eval missing or not judge';
    END IF;
    IF r.shadow_model_id IS NOT NULL OR coalesce(r.shadow_sample_pct, 0) <> 0 THEN
        RAISE EXCEPTION 'migration 291: writing_memory_eval must have no shadow (model %, pct %)',
            r.shadow_model_id, r.shadow_sample_pct;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('291', now(), 'AA-919 (WM-19): Model Gateway stage writing_memory_eval (R2 judge, judge route, no shadow)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
