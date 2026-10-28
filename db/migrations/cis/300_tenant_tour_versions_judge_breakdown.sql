-- Migration 300: AA-795 — gold_aa_internal.tenant_tour_versions.judge_breakdown: why a T2 version scored what it did.
--
-- Why. A T2 version keeps one number (quality_score). The judge's reasons are nowhere an admin can read them:
-- shared.llm_call_log.quality_signal holds numbers only, and shared.job.result is runner state (retention deletes it,
-- a re-run overwrites it). Report 12 (S234) F-f: persist the judge result per version. F-g: record the brand claims
-- of the saved text that the A1 source does not support ("children aged seven to sixteen", "consent-based").
--
-- What. One nullable jsonb column, no default, no index (read by version id only), no CHECK (the shape is the app's:
-- services/content_generation/t2_judge_breakdown.build): {"version", "judged", "brand_fit", "cross_brand_distinct",
-- "mission_present", "judge_score", "validate_score", "final_score", "score_source", "gate", "mission_source",
-- "binding", "feedback", "attempt", "brand_claims": {"version", "checked", "supported", "unsupported": [...]}}.
-- NULL for tenant edits, for a version whose breakdown failed to build (fail-open) and on every row written before
-- this file. Additive: no data change, no grant change (cis_app and aa_app_user hold table-level grants, which cover a
-- new column; RLS policies are row filters and are unchanged). Not related to generation_meta (CIS 297, how the
-- version was WRITTEN: ids and hashes only); this column is how it was SCORED and carries the judge's feedback text.
--
-- Tenant exposure. Admin-only. The tenant reads use `SELECT ttv.*`; the AA-795 code PR adds `judge_breakdown` to
-- api/routers/_tenant_projection.TENANT_HIDDEN_VERSION_FIELDS (the key also matches TENANT_FORBIDDEN_KEY_RE "judge",
-- so the key-walk test of every tenant tour-version read covers it). Between this apply and that deploy a tenant read
-- may carry the key with a NULL value only (no deployed code writes it yet), so ship the code PR right after the apply.
--
-- Order with the code. Apply BEFORE the code deploys: the T2 job's save UPDATE names this column, and without it every
-- T2 save fails (the job retries, then the version is marked failed). Apply through AA-CIS-Infra DB Migrate (byte copy
-- in db/migrations/cis/). It only needs the table (CIS 001 on Dev). The code PR sets readiness.REQUIRED_CIS_SCHEMA to
-- 300 (300 is above the highest applied version, so no OUT_OF_ORDER_CIS entry is needed).
--
-- Number. 297 (AA-920 WM-25) and 298 (catalog.v_tour_place_name) were reserved in S255; 300 is the next free number.
--
-- Preflight (read-only; expected: table present = 1, column present = 0):
--   SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--            WHERE n.nspname = 'gold_aa_internal' AND c.relname = 'tenant_tour_versions') AS table_present,
--          (SELECT count(*) FROM information_schema.columns
--            WHERE table_schema = 'gold_aa_internal' AND table_name = 'tenant_tour_versions'
--              AND column_name = 'judge_breakdown') AS present;
--
-- Rollback (a NEW forward migration, after the code that writes the column is reverted):
--   ALTER TABLE gold_aa_internal.tenant_tour_versions DROP COLUMN judge_breakdown;
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of the table.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('gold_aa_internal.tenant_tour_versions') IS NULL THEN
        RAISE EXCEPTION 'migration 300: gold_aa_internal.tenant_tour_versions is missing (CIS 001)';
    END IF;
END $$;

ALTER TABLE gold_aa_internal.tenant_tour_versions
    ADD COLUMN IF NOT EXISTS judge_breakdown jsonb;

COMMENT ON COLUMN gold_aa_internal.tenant_tour_versions.judge_breakdown IS
    'AA-795 (CIS 300): the kept draft''s T2 judge verdict (brand_fit, cross_brand_distinct, mission_present, '
    'judge_score, validate_score, gate, binding axis, feedback) and the brand-claim fidelity check of the saved text '
    'against the A1 source (brand_claims). NULL for tenant edits and before 300. Admin-only: hidden from every tenant '
    'read (_tenant_projection).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('300', now(), 'AA-795: tenant_tour_versions.judge_breakdown (T2 judge verdict + brand-claim check, admin-only)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
