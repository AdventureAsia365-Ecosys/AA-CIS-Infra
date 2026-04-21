-- =============================================================================
-- Migration 008: RLS for gold_aa_internal + silver_aa_internal schemas
-- Project: AA-CIS (Adventure Asia Content Intelligence System)
-- Date: 21/04/2026
-- Author: Pham Quoc Nghiep
-- Sprint: S9 — Load Test B2B + Go-live
-- =============================================================================
-- Context:
--   S7 applied RLS only on shared.pipeline_runs.
--   S9 discovered gold_aa_internal and silver_aa_internal tables had no RLS,
--   allowing cross-tenant data access via aa_app_user role.
--   This migration closes that gap and makes RLS reproducible.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. gold_aa_internal — all 3 tables
-- -----------------------------------------------------------------------------

ALTER TABLE gold_aa_internal.published_tours ENABLE ROW LEVEL SECURITY;
ALTER TABLE gold_aa_internal.published_tours FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON gold_aa_internal.published_tours;
CREATE POLICY tenant_isolation ON gold_aa_internal.published_tours
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

ALTER TABLE gold_aa_internal.content_exports ENABLE ROW LEVEL SECURITY;
ALTER TABLE gold_aa_internal.content_exports FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON gold_aa_internal.content_exports;
CREATE POLICY tenant_isolation ON gold_aa_internal.content_exports
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

ALTER TABLE gold_aa_internal.webhook_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE gold_aa_internal.webhook_deliveries FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON gold_aa_internal.webhook_deliveries;
CREATE POLICY tenant_isolation ON gold_aa_internal.webhook_deliveries
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- -----------------------------------------------------------------------------
-- 2. silver_aa_internal — tables with tenant_id column
-- Note: raw_sources and review_queue excluded (no tenant_id column)
-- -----------------------------------------------------------------------------

ALTER TABLE silver_aa_internal.raw_tours ENABLE ROW LEVEL SECURITY;
ALTER TABLE silver_aa_internal.raw_tours FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON silver_aa_internal.raw_tours;
CREATE POLICY tenant_isolation ON silver_aa_internal.raw_tours
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

ALTER TABLE silver_aa_internal.seo_context ENABLE ROW LEVEL SECURITY;
ALTER TABLE silver_aa_internal.seo_context FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON silver_aa_internal.seo_context;
CREATE POLICY tenant_isolation ON silver_aa_internal.seo_context
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

ALTER TABLE silver_aa_internal.generated_content ENABLE ROW LEVEL SECURITY;
ALTER TABLE silver_aa_internal.generated_content FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON silver_aa_internal.generated_content;
CREATE POLICY tenant_isolation ON silver_aa_internal.generated_content
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

ALTER TABLE silver_aa_internal.quality_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE silver_aa_internal.quality_scores FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON silver_aa_internal.quality_scores;
CREATE POLICY tenant_isolation ON silver_aa_internal.quality_scores
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- -----------------------------------------------------------------------------
-- 3. Grants for aa_app_user (NOBYPASSRLS role used by application)
-- -----------------------------------------------------------------------------

GRANT USAGE ON SCHEMA gold_aa_internal TO aa_app_user;
GRANT SELECT ON ALL TABLES IN SCHEMA gold_aa_internal TO aa_app_user;

GRANT USAGE ON SCHEMA silver_aa_internal TO aa_app_user;
GRANT SELECT ON ALL TABLES IN SCHEMA silver_aa_internal TO aa_app_user;

GRANT USAGE ON SCHEMA shared TO aa_app_user;
GRANT SELECT ON ALL TABLES IN SCHEMA shared TO aa_app_user;

-- -----------------------------------------------------------------------------
-- 4. Verify — should show rowsecurity=true for all 7 tables
-- -----------------------------------------------------------------------------
-- Run manually to confirm:
--
-- SELECT schemaname, tablename, rowsecurity
-- FROM pg_tables
-- WHERE schemaname IN ('gold_aa_internal', 'silver_aa_internal')
-- ORDER BY schemaname, tablename;
--
-- Expected:
--   gold_aa_internal.content_exports     → true
--   gold_aa_internal.published_tours     → true
--   gold_aa_internal.webhook_deliveries  → true
--   silver_aa_internal.generated_content → true
--   silver_aa_internal.quality_scores    → true
--   silver_aa_internal.raw_sources       → false (no tenant_id)
--   silver_aa_internal.raw_tours         → true
--   silver_aa_internal.review_queue      → false (no tenant_id)
--   silver_aa_internal.seo_context       → true
-- -----------------------------------------------------------------------------

COMMIT;
