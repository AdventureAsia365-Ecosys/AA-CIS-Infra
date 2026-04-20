BEGIN;

-- Step 1: Add tenant_id columns
ALTER TABLE silver_aa_internal.raw_tours
  ADD COLUMN IF NOT EXISTS tenant_id TEXT NOT NULL DEFAULT 'aa_internal';

ALTER TABLE silver_aa_internal.seo_context
  ADD COLUMN IF NOT EXISTS tenant_id TEXT NOT NULL DEFAULT 'aa_internal';

ALTER TABLE silver_aa_internal.generated_content
  ADD COLUMN IF NOT EXISTS tenant_id TEXT NOT NULL DEFAULT 'aa_internal';

ALTER TABLE silver_aa_internal.quality_scores
  ADD COLUMN IF NOT EXISTS tenant_id TEXT NOT NULL DEFAULT 'aa_internal';

-- Step 2: FK constraints
ALTER TABLE silver_aa_internal.raw_tours
  DROP CONSTRAINT IF EXISTS raw_tours_tenant_id_fk;
ALTER TABLE silver_aa_internal.raw_tours
  ADD CONSTRAINT raw_tours_tenant_id_fk
  FOREIGN KEY (tenant_id) REFERENCES shared.tenants(tenant_id);

ALTER TABLE silver_aa_internal.seo_context
  DROP CONSTRAINT IF EXISTS seo_context_tenant_id_fk;
ALTER TABLE silver_aa_internal.seo_context
  ADD CONSTRAINT seo_context_tenant_id_fk
  FOREIGN KEY (tenant_id) REFERENCES shared.tenants(tenant_id);

ALTER TABLE silver_aa_internal.generated_content
  DROP CONSTRAINT IF EXISTS generated_content_tenant_id_fk;
ALTER TABLE silver_aa_internal.generated_content
  ADD CONSTRAINT generated_content_tenant_id_fk
  FOREIGN KEY (tenant_id) REFERENCES shared.tenants(tenant_id);

ALTER TABLE silver_aa_internal.quality_scores
  DROP CONSTRAINT IF EXISTS quality_scores_tenant_id_fk;
ALTER TABLE silver_aa_internal.quality_scores
  ADD CONSTRAINT quality_scores_tenant_id_fk
  FOREIGN KEY (tenant_id) REFERENCES shared.tenants(tenant_id);

-- Step 3: Enable RLS
ALTER TABLE silver_aa_internal.raw_tours          ENABLE ROW LEVEL SECURITY;
ALTER TABLE silver_aa_internal.seo_context        ENABLE ROW LEVEL SECURITY;
ALTER TABLE silver_aa_internal.generated_content  ENABLE ROW LEVEL SECURITY;
ALTER TABLE silver_aa_internal.quality_scores     ENABLE ROW LEVEL SECURITY;
ALTER TABLE gold_aa_internal.published_tours      ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.pipeline_runs                  ENABLE ROW LEVEL SECURITY;

-- Step 4: RLS policies
DROP POLICY IF EXISTS tenant_isolation ON silver_aa_internal.raw_tours;
CREATE POLICY tenant_isolation ON silver_aa_internal.raw_tours
  USING (tenant_id = current_setting('app.tenant_id', true));

DROP POLICY IF EXISTS tenant_isolation ON silver_aa_internal.seo_context;
CREATE POLICY tenant_isolation ON silver_aa_internal.seo_context
  USING (tenant_id = current_setting('app.tenant_id', true));

DROP POLICY IF EXISTS tenant_isolation ON silver_aa_internal.generated_content;
CREATE POLICY tenant_isolation ON silver_aa_internal.generated_content
  USING (tenant_id = current_setting('app.tenant_id', true));

DROP POLICY IF EXISTS tenant_isolation ON silver_aa_internal.quality_scores;
CREATE POLICY tenant_isolation ON silver_aa_internal.quality_scores
  USING (tenant_id = current_setting('app.tenant_id', true));

DROP POLICY IF EXISTS tenant_isolation ON gold_aa_internal.published_tours;
CREATE POLICY tenant_isolation ON gold_aa_internal.published_tours
  USING (tenant_id = current_setting('app.tenant_id', true));

DROP POLICY IF EXISTS tenant_isolation ON shared.pipeline_runs;
CREATE POLICY tenant_isolation ON shared.pipeline_runs
  USING (tenant_id = current_setting('app.tenant_id', true));

-- Step 5: FORCE RLS (superuser cũng bị enforce — trừ table owner)
ALTER TABLE silver_aa_internal.raw_tours         FORCE ROW LEVEL SECURITY;
ALTER TABLE silver_aa_internal.seo_context       FORCE ROW LEVEL SECURITY;
ALTER TABLE silver_aa_internal.generated_content FORCE ROW LEVEL SECURITY;
ALTER TABLE silver_aa_internal.quality_scores    FORCE ROW LEVEL SECURITY;
ALTER TABLE gold_aa_internal.published_tours     FORCE ROW LEVEL SECURITY;
ALTER TABLE shared.pipeline_runs                 FORCE ROW LEVEL SECURITY;

-- Step 6: Seed test tenant B
INSERT INTO shared.tenants (tenant_id, name, plan_tier)
VALUES ('wl_tenant_b2b_test', 'Test B2B Tenant', 'starter')
ON CONFLICT DO NOTHING;

COMMIT;
