-- Migration 264: AA-779 (S247) — Model Gateway stage t9_faq_filter: the optional LLM filter of the real search
-- questions a T9 blog FAQ may use (services/acp_content_writing/faq_filter.py, ADR 0011).
--
-- Why. The deterministic scope filter (quality_gates.paa_for_scope) keeps questions at precision 0.64 on the S246
-- labelled set (200 questions). A blind Claude Haiku 4.5 classifier (legacy key 'haiku', stage adhoc_aa779) scored
-- precision 0.987 (Wilson LB 0.930), recall 0.724 on the same set; Nghiệp's hand check of the 30 disagreements
-- sided with the label panel 30/30. The code calls the stage only when the worker env T9_FAQ_LLM_FILTER is
-- 'shadow' or 'on' (default off), one call per blog piece.
--
-- Row: t9_faq_filter  role validate (ADR 0008: a classification whose output nobody scores; a 'judge' stage must be
-- non-Anthropic, ADR 0006 §5), provider claude, model 'haiku' (what the trial measured), account_route acc3 (the
-- legacy key fails over to acc1 by itself), no fallback model (on any failure the code keeps the deterministic
-- list), no shadow. SAFE_DEFAULTS mirrors it (shared/llm_client/role_config.py), so the flag also works before
-- this row exists.
-- Cost when the flag is on: ≈ $0.005 per blog at most (≤ 30 questions, ~1.5k tokens in, ≤ 1k out on Haiku 4.5).
--
-- ORDER: apply only AFTER 262 (AA-859, 262_tenant_brand_seo_rls.sql) and 263 (reserved, AA-859 lane). The readiness
-- check (api/core/readiness.py, /health/ready, deploy smoke, Platform Apps) compares max(version::int) of
-- shared.schema_versions with REQUIRED_CIS_SCHEMA: with 264 applied first, max = 264, and code that later needs 262
-- or 263 would report ready while they are missing. The row is optional (SAFE_DEFAULTS mirrors it), so holding 264
-- back costs nothing.
--
-- Idempotent: ON CONFLICT DO NOTHING (an admin change of the row is never overwritten). No deploy needed for the
-- row itself: the gateway reads it per call (20 s cache). Locks: one INSERT.
-- Rollback: DELETE FROM shared.llm_role_config WHERE stage = 't9_faq_filter';
--           DELETE FROM shared.schema_versions WHERE version = '264';
-- (or set T9_FAQ_LLM_FILTER=off on the worker task def: the code then never calls the stage).

BEGIN;

INSERT INTO shared.llm_role_config
    (stage, role, provider, model_id, account_route, is_active, fallback_model_ids,
     shadow_model_id, shadow_sample_pct, updated_by)
VALUES
    ('t9_faq_filter', 'validate', 'claude', 'haiku', 'acc3', true, ARRAY[]::text[], NULL, 0, 'migration-264-aa779')
ON CONFLICT (stage) DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.llm_role_config WHERE stage = 't9_faq_filter' AND role = 'validate') THEN
        RAISE EXCEPTION 'migration 264: stage row t9_faq_filter missing or not validate';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('264', now(), 'AA-779: llm_role_config t9_faq_filter (validate, claude haiku acc3, no fallback, no shadow)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
