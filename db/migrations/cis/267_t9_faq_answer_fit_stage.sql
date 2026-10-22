-- Migration 267: AA-779 (S247) — Model Gateway stage t9_faq_answer_fit: the optional check that each final T9 blog
-- FAQ answer answers its question (services/acp_content_writing/faq_answer_fit.py, ADR 0011).
--
-- Why. On the live 8-blog checkpoint (S247, 31 FAQ pairs, 3-judge panel) 3 answers did not answer their question
-- (a country's altitude answered with one town's elevation; "What is <place> called in English?" never naming
-- one; a writer-invented question about one institute answered with another). The deterministic subject test
-- (quality_gates.faq_answer_problem) passed all three. The code calls this stage only when the worker env
-- T9_FAQ_LLM_FILTER is 'shadow' or 'on' (default off; the same flag as stage t9_faq_filter, migration 264), one
-- call per blog piece over all its FAQ pairs. A drop-only step: it never holds or regenerates a piece.
--
-- Row: t9_faq_answer_fit  role validate (ADR 0008: a classification whose output nobody scores; a 'judge' stage must
-- be non-Anthropic, ADR 0006 §5), provider claude, model 'sonnet' (round-3 eval: batched Sonnet passed every bar, isolated Haiku missed held-out recall), account_route acc3 (the legacy key fails
-- over to acc1 by itself), no fallback model (on any failure the code keeps the FAQ unchanged), no shadow.
-- SAFE_DEFAULTS mirrors it (shared/llm_client/role_config.py), so the flag also works before this row exists.
-- Cost when the flag is on: ≈ $0.002 per blog (≤ 5 pairs, ~1.2k tokens in, ≤ 200 out on Haiku 4.5).
--
-- NUMBER: 267 — 265 and 266 are AA-859 wave 4 (RLS); this file does not depend on them. ORDER: apply only AFTER 264
-- (t9_faq_filter) and AA-859 wave 4's 265 and 266. The readiness check (api/core/readiness.py) compares
-- max(version::int) of shared.schema_versions with REQUIRED_CIS_SCHEMA: with 267 applied first, max = 267 and code
-- that later needs 265 or 266 would report ready while they are missing. The row is optional (SAFE_DEFAULTS mirrors
-- it), so holding 267 back costs nothing.
--
-- Idempotent: ON CONFLICT DO NOTHING (an admin change of the row is never overwritten). No deploy needed for the
-- row itself: the gateway reads it per call (20 s cache). Locks: one INSERT.
-- Rollback: DELETE FROM shared.llm_role_config WHERE stage = 't9_faq_answer_fit';
--           DELETE FROM shared.schema_versions WHERE version = '267';
-- (or set T9_FAQ_LLM_FILTER=off on the worker task def: the code then never calls the stage).

BEGIN;

INSERT INTO shared.llm_role_config
    (stage, role, provider, model_id, account_route, is_active, fallback_model_ids,
     shadow_model_id, shadow_sample_pct, updated_by)
VALUES
    ('t9_faq_answer_fit', 'validate', 'claude', 'sonnet', 'acc3', true, ARRAY[]::text[], NULL, 0,
     'migration-267-aa779')
ON CONFLICT (stage) DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.llm_role_config WHERE stage = 't9_faq_answer_fit' AND role = 'validate') THEN
        RAISE EXCEPTION 'migration 267: stage row t9_faq_answer_fit missing or not validate';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('267', now(), 'AA-779: llm_role_config t9_faq_answer_fit (validate, claude sonnet acc3, no fallback, no shadow)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
