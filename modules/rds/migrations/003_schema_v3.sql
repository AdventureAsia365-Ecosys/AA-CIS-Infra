-- =============================================================================
-- AA-CIS Database Schema v3.0
-- Tour Content Automation Platform — PRD v4.0 Medallion + Multi-tenant
-- Engine:   PostgreSQL 15
-- DB Name:  aa_cis_dev
-- Updated:  20/04/2026
-- Engineer: Pham Quoc Nghiep
--
-- ARCHITECTURE: Schema-per-tenant Medallion
--   shared.*                    → System tables (tenants, lessons, pipeline_runs)
--   silver_{tenant_id}.*        → Silver layer per tenant (cleaned & enriched)
--   gold_{tenant_id}.*          → Gold layer per tenant (published, business-ready)
--
-- Phase 1: tenant_id = 'aa_internal'
--   → schemas: shared, silver_aa_internal, gold_aa_internal
--
-- Phase 2+: add new tenant → CREATE SCHEMA silver_{id}; CREATE SCHEMA gold_{id};
--   → RLS enforced via SET LOCAL app.tenant_id per transaction
--
-- BRONZE LAYER: S3 only — no DB tables
--   s3://aa-cis-bronze-{account}/raw-inbox/{tenant}/{batch}/
--   s3://aa-cis-bronze-{account}/raw-archive/{tenant}/{date}/
-- =============================================================================

-- =============================================================================
-- CLEANUP — Drop everything (dev only)
-- =============================================================================

-- Drop tenant schemas first
DO $$
DECLARE
    schema_name TEXT;
BEGIN
    FOR schema_name IN
        SELECT nspname FROM pg_namespace
        WHERE nspname LIKE 'silver_%' OR nspname LIKE 'gold_%'
    LOOP
        EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', schema_name);
        RAISE NOTICE 'Dropped schema: %', schema_name;
    END LOOP;
END $$;

-- Drop shared schema
DROP SCHEMA IF EXISTS shared CASCADE;

-- Drop legacy flat tables from v2
DROP TABLE IF EXISTS webhook_deliveries      CASCADE;
DROP TABLE IF EXISTS content_exports         CASCADE;
DROP TABLE IF EXISTS published_tours         CASCADE;
DROP TABLE IF EXISTS review_queue            CASCADE;
DROP TABLE IF EXISTS quality_scores          CASCADE;
DROP TABLE IF EXISTS generated_content       CASCADE;
DROP TABLE IF EXISTS seo_context             CASCADE;
DROP TABLE IF EXISTS raw_tours               CASCADE;
DROP TABLE IF EXISTS raw_sources             CASCADE;
DROP TABLE IF EXISTS pipeline_runs           CASCADE;
DROP TABLE IF EXISTS lessons_registry        CASCADE;
DROP TABLE IF EXISTS tenant_export_config    CASCADE;
DROP TABLE IF EXISTS tenant_brand_rules      CASCADE;
DROP TABLE IF EXISTS tenant_seo_config       CASCADE;
DROP TABLE IF EXISTS tenants                 CASCADE;
DROP TABLE IF EXISTS schema_versions         CASCADE;

-- Drop legacy v1 tables
DROP TABLE IF EXISTS tenant_api_logs         CASCADE;
DROP TABLE IF EXISTS tenant_tour_versions    CASCADE;
DROP TABLE IF EXISTS tenant_configs          CASCADE;
DROP TABLE IF EXISTS published_tour_versions CASCADE;
DROP TABLE IF EXISTS seo_contexts            CASCADE;

-- Drop ENUMs
DROP TYPE IF EXISTS plan_tier_enum           CASCADE;
DROP TYPE IF EXISTS seo_provider_enum        CASCADE;
DROP TYPE IF EXISTS export_format_enum       CASCADE;
DROP TYPE IF EXISTS pipeline_status_enum     CASCADE;
DROP TYPE IF EXISTS content_status_enum      CASCADE;
DROP TYPE IF EXISTS review_status_enum       CASCADE;
DROP TYPE IF EXISTS webhook_status_enum      CASCADE;

-- =============================================================================
-- CREATE SCHEMAS
-- =============================================================================
CREATE SCHEMA shared;

-- Phase 1: aa_internal tenant schemas
CREATE SCHEMA silver_aa_internal;
CREATE SCHEMA gold_aa_internal;

-- =============================================================================
-- ENUMs (global)
-- =============================================================================
CREATE TYPE plan_tier_enum      AS ENUM ('internal', 'starter', 'growth', 'business', 'enterprise');
CREATE TYPE seo_provider_enum   AS ENUM ('dataforseo', 'custom', 'disabled');
CREATE TYPE export_format_enum  AS ENUM ('json', 'csv', 'xml');

CREATE TYPE pipeline_status_enum AS ENUM (
    'ingested',
    'seo_pending',
    'seo_done',
    'gen_pending',
    'gen_done',
    'validating',
    'hitl_required',
    'hitl_approved',
    'hitl_rejected',
    'published',
    'failed'
);

CREATE TYPE content_status_enum AS ENUM (
    'draft',
    'passed',
    'hitl',
    'approved',
    'rejected',
    'published'
);

CREATE TYPE review_status_enum AS ENUM (
    'pending',
    'approved',
    'rejected',
    'skipped'
);

CREATE TYPE webhook_status_enum AS ENUM (
    'pending',
    'delivered',
    'failed',
    'retrying'
);

-- =============================================================================
-- SHARED SCHEMA — System tables (cross-tenant)
-- =============================================================================

-- tenants — Master tenant registry
CREATE TABLE shared.tenants (
    tenant_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(255)   NOT NULL,
    slug            VARCHAR(100)   NOT NULL UNIQUE,  -- used as schema suffix: silver_{slug}
    plan_tier       plan_tier_enum NOT NULL DEFAULT 'internal',
    api_key_hash    VARCHAR(255),
    rate_limit_rpm  INTEGER        NOT NULL DEFAULT 60,
    is_active       BOOLEAN        NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  shared.tenants IS 'Master tenant registry. slug used as schema suffix: silver_{slug}, gold_{slug}';
COMMENT ON COLUMN shared.tenants.slug IS 'e.g. aa_internal → schemas: silver_aa_internal, gold_aa_internal';

-- Seed: Adventure Asia internal tenant
INSERT INTO shared.tenants (tenant_id, name, slug, plan_tier, is_active)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'Adventure Asia Internal',
    'aa_internal',
    'internal',
    TRUE
);

-- tenant_seo_config
CREATE TABLE shared.tenant_seo_config (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID              NOT NULL REFERENCES shared.tenants(tenant_id) ON DELETE CASCADE,
    seo_provider    seo_provider_enum NOT NULL DEFAULT 'dataforseo',
    custom_keywords JSONB,
    target_market   JSONB,
    overrides       JSONB,
    updated_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id)
);

INSERT INTO shared.tenant_seo_config (tenant_id, seo_provider, target_market)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'dataforseo',
    '{"countries": ["AU", "UK", "US"], "age_range": [40, 60], "language": "en"}'
);

-- tenant_brand_rules
CREATE TABLE shared.tenant_brand_rules (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID        NOT NULL REFERENCES shared.tenants(tenant_id) ON DELETE CASCADE,
    system_prompt     TEXT,
    style_guide       TEXT,
    forbidden_words   JSONB       DEFAULT '[]',
    custom_validators JSONB       DEFAULT '[]',
    version           INTEGER     NOT NULL DEFAULT 1,
    is_active         BOOLEAN     NOT NULL DEFAULT TRUE,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, is_active)
);

INSERT INTO shared.tenant_brand_rules (tenant_id, forbidden_words)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    '["deals", "cheap", "book now", "instant booking", "discount"]'
);

-- tenant_export_config
CREATE TABLE shared.tenant_export_config (
    id              UUID               PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID               NOT NULL REFERENCES shared.tenants(tenant_id) ON DELETE CASCADE,
    webhook_url     VARCHAR(500),
    export_format   export_format_enum NOT NULL DEFAULT 'json',
    field_mapping   JSONB              DEFAULT '{}',
    auth_header     VARCHAR(500),
    is_active       BOOLEAN            NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id)
);

INSERT INTO shared.tenant_export_config (tenant_id, export_format)
VALUES ('00000000-0000-0000-0000-000000000001', 'json');

-- lessons_registry — 29 brand validators (system-wide)
CREATE TABLE shared.lessons_registry (
    id              SERIAL PRIMARY KEY,
    lesson_num      SMALLINT     NOT NULL UNIQUE,
    category        VARCHAR(100) NOT NULL,
    validator_fn    VARCHAR(200) NOT NULL UNIQUE,
    failure_code    VARCHAR(50)  NOT NULL UNIQUE,
    description     TEXT,
    example_before  TEXT,
    example_after   TEXT,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    version         INTEGER      NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

INSERT INTO shared.lessons_registry (lesson_num, category, validator_fn, failure_code, description) VALUES
( 1, 'structure',   'validate_v01_all_caps',            'V01', 'Name/subtitle không được ALL CAPS'),
( 2, 'structure',   'validate_v02_name_length',         'V02', 'Name ≤ 70 chars, subtitle ≤ 120 chars'),
( 3, 'brand_voice', 'validate_v03_forbidden_words',     'V03', 'Không dùng deals/cheap/instant booking'),
( 4, 'brand_voice', 'validate_v04_tone_formal',         'V04', 'Tone phải refined, không salesy'),
( 5, 'seo',         'validate_v05_primary_keyword',     'V05', 'Primary keyword trong name hoặc subtitle'),
( 6, 'seo',         'validate_v06_keyword_density',     'V06', 'Keyword density 1-3% trong summary'),
( 7, 'seo',         'validate_v07_seo_title_length',    'V07', 'SEO title 50-60 chars'),
( 8, 'seo',         'validate_v08_meta_description',    'V08', 'Meta description 150-160 chars'),
( 9, 'structure',   'validate_v09_highlights_count',    'V09', '3-7 highlights'),
(10, 'structure',   'validate_v10_highlights_format',   'V10', 'Highlight: verb-led, ≤ 12 words'),
(11, 'structure',   'validate_v11_itinerary_days',      'V11', 'Ngày itinerary match duration'),
(12, 'structure',   'validate_v12_itinerary_format',    'V12', 'Mỗi ngày có title + ≥ 2 activities'),
(13, 'brand_voice', 'validate_v13_cta_language',        'V13', 'CTA: Design This Journey'),
(14, 'brand_voice', 'validate_v14_no_price_mention',    'V14', 'Không đề cập giá tiền'),
(15, 'brand_voice', 'validate_v15_target_demographic',  'V15', 'Phù hợp 40-60 tuổi senior professionals'),
(16, 'quality',     'validate_v16_no_placeholder',      'V16', 'Không có [PLACEHOLDER] hoặc TBD'),
(17, 'quality',     'validate_v17_no_repetition',       'V17', 'Không lặp câu/ý trong cùng section'),
(18, 'quality',     'validate_v18_factual_consistency', 'V18', 'Country/destination nhất quán'),
(19, 'seo',         'validate_v19_secondary_keywords',  'V19', '≥ 2 secondary keywords trong body'),
(20, 'brand_voice', 'validate_v20_brand_vocabulary',    'V20', 'Dùng: Design/Curated/Refined/Tailored'),
(21, 'structure',   'validate_v21_summary_length',      'V21', 'Summary 80-120 words'),
(22, 'structure',   'validate_v22_description_length',  'V22', 'Description 150-250 words'),
(23, 'quality',     'validate_v23_no_generic_phrases',  'V23', 'Không có "world-class", "once in a lifetime"'),
(24, 'seo',         'validate_v24_lsi_keywords',        'V24', '≥ 1 LSI keyword trong highlights'),
(25, 'brand_voice', 'validate_v25_cultural_sensitivity','V25', 'Không có stereotypes về destinations'),
(26, 'structure',   'validate_v26_encoding_clean',      'V26', 'Không có HTML entities trong output'),
(27, 'quality',     'validate_v27_activity_specificity','V27', 'Activities phải cụ thể'),
(28, 'seo',         'validate_v28_og_tags_present',     'V28', 'og:title, og:description, og:image phải có'),
(29, 'quality',     'validate_v29_mobile_card_text',    'V29', 'mobile_card_text ≤ 60 chars, verb-led');

-- pipeline_runs — Execution tracking + billing per batch
CREATE TABLE shared.pipeline_runs (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID        NOT NULL REFERENCES shared.tenants(tenant_id),
    batch_id            UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    batch_name          VARCHAR(255),
    s3_source_path      VARCHAR(500),
    status              VARCHAR(50) NOT NULL DEFAULT 'running',
    tours_total         INTEGER     NOT NULL DEFAULT 0,
    tours_passed        INTEGER     NOT NULL DEFAULT 0,
    tours_hitl          INTEGER     NOT NULL DEFAULT 0,
    tours_failed        INTEGER     NOT NULL DEFAULT 0,
    cost_usd            DECIMAL(10,4),
    tokens_input        BIGINT,
    tokens_output       BIGINT,
    tokens_cached       BIGINT,
    langfuse_trace_url  VARCHAR(500),
    started_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at        TIMESTAMPTZ,
    error_message       TEXT
);

CREATE INDEX idx_pipeline_runs_tenant ON shared.pipeline_runs(tenant_id);
CREATE INDEX idx_pipeline_runs_batch  ON shared.pipeline_runs(batch_id);
CREATE INDEX idx_pipeline_runs_status ON shared.pipeline_runs(status);

-- =============================================================================
-- FUNCTION: create_tenant_schemas(slug)
-- Creates silver_{slug} and gold_{slug} schemas with all tables.
-- Call this when onboarding a new tenant.
-- =============================================================================
CREATE OR REPLACE FUNCTION shared.create_tenant_schemas(p_slug VARCHAR)
RETURNS VOID AS $$
DECLARE
    silver_schema TEXT := 'silver_' || p_slug;
    gold_schema   TEXT := 'gold_'   || p_slug;
BEGIN
    -- Create schemas
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', silver_schema);
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', gold_schema);

    -- ── SILVER TABLES ────────────────────────────────────────────────────────

    -- raw_sources: Bronze S3 file metadata
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.raw_sources (
            id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id       UUID        NOT NULL REFERENCES shared.tenants(tenant_id),
            batch_id        UUID        NOT NULL REFERENCES shared.pipeline_runs(batch_id),
            filename        VARCHAR(500) NOT NULL,
            s3_path         VARCHAR(500) NOT NULL,
            file_size_kb    INTEGER,
            row_count       INTEGER,
            parsed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            parse_errors    JSONB       DEFAULT %L
        )', silver_schema, '[]');

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_raw_sources_batch ON %I.raw_sources(batch_id)',
        p_slug, silver_schema);

    -- raw_tours: Immutable source data from Excel
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.raw_tours (
            tour_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id           UUID                NOT NULL REFERENCES shared.tenants(tenant_id),
            batch_id            UUID                NOT NULL REFERENCES shared.pipeline_runs(batch_id),
            source_id           UUID                REFERENCES %I.raw_sources(id),
            tour_id_external    VARCHAR(200),
            sku                 VARCHAR(200),
            provider            VARCHAR(255),
            src_name            VARCHAR(500)        NOT NULL,
            src_subtitle        VARCHAR(500),
            src_summary         TEXT,
            src_description     TEXT,
            src_highlights      JSONB               DEFAULT %L,
            src_itineraries     TEXT,
            country             VARCHAR(100),
            duration            VARCHAR(100),
            group_size          VARCHAR(100),
            period              VARCHAR(200),
            price_raw           VARCHAR(200),
            inclusions          TEXT,
            exclusions          TEXT,
            links               JSONB               DEFAULT %L,
            activities          JSONB               DEFAULT %L,
            feature             TEXT,
            best_time_to_go     VARCHAR(500),
            pipeline_status     pipeline_status_enum NOT NULL DEFAULT ''ingested'',
            ingest_at           TIMESTAMPTZ          NOT NULL DEFAULT NOW()
        )', silver_schema, silver_schema, '[]', '[]', '[]');

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_raw_tours_status ON %I.raw_tours(pipeline_status)',
        p_slug, silver_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_raw_tours_batch ON %I.raw_tours(batch_id)',
        p_slug, silver_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_raw_tours_country ON %I.raw_tours(country)',
        p_slug, silver_schema);

    -- seo_context
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.seo_context (
            id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tour_id         UUID        NOT NULL REFERENCES %I.raw_tours(tour_id),
            tenant_id       UUID        NOT NULL REFERENCES shared.tenants(tenant_id),
            keyword_search  VARCHAR(500),
            provider        seo_provider_enum NOT NULL DEFAULT ''dataforseo'',
            keyword_ideas   JSONB   DEFAULT %L,
            demographics    JSONB   DEFAULT %L,
            trends          JSONB   DEFAULT %L,
            top_keywords    JSONB   DEFAULT %L,
            cache_key       VARCHAR(500) UNIQUE,
            fetched_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            expires_at      TIMESTAMPTZ
        )', silver_schema, silver_schema, '[]', '{}', '{}', '[]');

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_seo_tour ON %I.seo_context(tour_id)',
        p_slug, silver_schema);

    -- generated_content
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.generated_content (
            id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tour_id         UUID                NOT NULL REFERENCES %I.raw_tours(tour_id),
            tenant_id       UUID                NOT NULL REFERENCES shared.tenants(tenant_id),
            version_num     SMALLINT            NOT NULL DEFAULT 1,
            aa_name         VARCHAR(500),
            aa_subtitle     VARCHAR(500),
            aa_summary      TEXT,
            aa_description  TEXT,
            aa_highlights   JSONB   DEFAULT %L,
            aa_itineraries  TEXT,
            mobile_card_text VARCHAR(80),
            seo_title       VARCHAR(70),
            seo_meta        VARCHAR(170),
            seo_keywords_used JSONB DEFAULT %L,
            og_tags         JSONB   DEFAULT %L,
            model_editorial VARCHAR(100),
            model_schema    VARCHAR(100),
            prompt_version  VARCHAR(50),
            brand_rules_version INTEGER,
            status          content_status_enum NOT NULL DEFAULT ''draft'',
            retry_count     SMALLINT            NOT NULL DEFAULT 0,
            created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
            UNIQUE(tour_id, version_num)
        )', silver_schema, silver_schema, '[]', '[]', '{}');

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_gen_content_tour ON %I.generated_content(tour_id)',
        p_slug, silver_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_gen_content_status ON %I.generated_content(status)',
        p_slug, silver_schema);

    -- quality_scores
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.quality_scores (
            id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            generated_content_id  UUID        NOT NULL REFERENCES %I.generated_content(id),
            tour_id               UUID        NOT NULL REFERENCES %I.raw_tours(tour_id),
            tenant_id             UUID        NOT NULL REFERENCES shared.tenants(tenant_id),
            score_overall         DECIMAL(5,2) NOT NULL,
            score_brand           DECIMAL(5,2),
            score_seo             DECIMAL(5,2),
            score_structure       DECIMAL(5,2),
            score_quality         DECIMAL(5,2),
            failure_codes         JSONB   DEFAULT %L,
            issues                JSONB   DEFAULT %L,
            passed_count          SMALLINT NOT NULL DEFAULT 0,
            failed_count          SMALLINT NOT NULL DEFAULT 0,
            validator_fn_version  VARCHAR(50),
            langfuse_trace_id     VARCHAR(200),
            evaluated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )', silver_schema, silver_schema, silver_schema, '[]', '[]');

    -- review_queue (HITL)
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.review_queue (
            id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tour_id               UUID                NOT NULL REFERENCES %I.raw_tours(tour_id),
            generated_content_id  UUID                NOT NULL REFERENCES %I.generated_content(id),
            tenant_id             UUID                NOT NULL REFERENCES shared.tenants(tenant_id),
            failure_summary       TEXT,
            score_overall         DECIMAL(5,2),
            step_fn_task_token    TEXT,
            step_fn_execution_arn VARCHAR(500),
            review_status         review_status_enum  NOT NULL DEFAULT ''pending'',
            reviewer_notes        TEXT,
            reviewed_by           VARCHAR(200),
            reviewed_at           TIMESTAMPTZ,
            created_at            TIMESTAMPTZ         NOT NULL DEFAULT NOW()
        )', silver_schema, silver_schema, silver_schema);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_review_status ON %I.review_queue(review_status)',
        p_slug, silver_schema);

    -- ── GOLD TABLES ──────────────────────────────────────────────────────────

    -- published_tours (immutable after publish)
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.published_tours (
            id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tour_id               UUID        NOT NULL REFERENCES %I.raw_tours(tour_id) UNIQUE,
            generated_content_id  UUID        NOT NULL REFERENCES %I.generated_content(id),
            tenant_id             UUID        NOT NULL REFERENCES shared.tenants(tenant_id),
            aa_name               VARCHAR(500) NOT NULL,
            aa_subtitle           VARCHAR(500),
            aa_summary            TEXT,
            aa_description        TEXT,
            aa_highlights         JSONB       DEFAULT %L,
            aa_itineraries        TEXT,
            mobile_card_text      VARCHAR(80),
            seo_title             VARCHAR(70),
            seo_meta              VARCHAR(170),
            seo_keywords_used     JSONB       DEFAULT %L,
            og_tags               JSONB       DEFAULT %L,
            quality_score         DECIMAL(5,2),
            quality_score_id      UUID,
            s3_gold_path          VARCHAR(500),
            approved_by           VARCHAR(200),
            published_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )', gold_schema, silver_schema, silver_schema, '[]', '[]', '{}');

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_published_at ON %I.published_tours(published_at DESC)',
        p_slug, gold_schema);

    -- content_exports
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.content_exports (
            id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id       UUID               NOT NULL REFERENCES shared.tenants(tenant_id),
            export_id       UUID               NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            format          export_format_enum NOT NULL DEFAULT ''json'',
            filter_params   JSONB              DEFAULT %L,
            field_mapping   JSONB              DEFAULT %L,
            s3_path         VARCHAR(500),
            signed_url      TEXT,
            total_tours     INTEGER,
            file_size_kb    INTEGER,
            status          VARCHAR(50)        NOT NULL DEFAULT ''pending'',
            expires_at      TIMESTAMPTZ,
            created_at      TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
            completed_at    TIMESTAMPTZ
        )', gold_schema, '{}', '{}');

    -- webhook_deliveries
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.webhook_deliveries (
            id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id       UUID                NOT NULL REFERENCES shared.tenants(tenant_id),
            tour_id         UUID                NOT NULL REFERENCES %I.raw_tours(tour_id),
            webhook_url     VARCHAR(500)        NOT NULL,
            event_type      VARCHAR(100)        NOT NULL DEFAULT ''tour.published'',
            delivery_id     UUID                NOT NULL DEFAULT gen_random_uuid(),
            payload_s3_path VARCHAR(500),
            hmac_secret_ref VARCHAR(200),
            status          webhook_status_enum NOT NULL DEFAULT ''pending'',
            http_status     SMALLINT,
            attempt_count   SMALLINT            NOT NULL DEFAULT 0,
            last_error      TEXT,
            created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
            next_retry_at   TIMESTAMPTZ,
            delivered_at    TIMESTAMPTZ
        )', gold_schema, silver_schema);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_webhook_status ON %I.webhook_deliveries(status)',
        p_slug, gold_schema);

    RAISE NOTICE 'Created schemas: %, %', silver_schema, gold_schema;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- EXECUTE: Create schemas for Phase 1 tenant
-- =============================================================================
SELECT shared.create_tenant_schemas('aa_internal');

-- =============================================================================
-- VIEWS (use silver_aa_internal as default for Phase 1 admin dashboard)
-- =============================================================================
CREATE OR REPLACE VIEW shared.v_pipeline_summary AS
SELECT
    rt.tour_id,
    rt.tenant_id,
    rt.batch_id,
    rt.src_name,
    rt.country,
    rt.pipeline_status,
    rt.ingest_at,
    gc.id           AS latest_content_id,
    gc.version_num  AS content_version,
    gc.status       AS content_status,
    qs.score_overall,
    qs.failure_codes,
    pt.published_at
FROM silver_aa_internal.raw_tours rt
LEFT JOIN LATERAL (
    SELECT id, version_num, status
    FROM silver_aa_internal.generated_content
    WHERE tour_id = rt.tour_id
    ORDER BY version_num DESC
    LIMIT 1
) gc ON TRUE
LEFT JOIN LATERAL (
    SELECT score_overall, failure_codes
    FROM silver_aa_internal.quality_scores
    WHERE generated_content_id = gc.id
    ORDER BY evaluated_at DESC
    LIMIT 1
) qs ON TRUE
LEFT JOIN gold_aa_internal.published_tours pt ON pt.tour_id = rt.tour_id;

COMMENT ON VIEW shared.v_pipeline_summary IS 'Pipeline overview for aa_internal tenant. Admin Dashboard.';

CREATE OR REPLACE VIEW shared.v_batch_stats AS
SELECT
    batch_id,
    COUNT(*)                                               AS total,
    COUNT(*) FILTER (WHERE pipeline_status = 'published')  AS passed,
    COUNT(*) FILTER (WHERE pipeline_status = 'hitl_required') AS hitl,
    COUNT(*) FILTER (WHERE pipeline_status = 'failed')     AS failed
FROM silver_aa_internal.raw_tours
GROUP BY batch_id;

-- =============================================================================
-- RLS SETUP (enable at S7 when onboarding B2B tenants)
-- =============================================================================
-- Uncomment at S7:
/*
ALTER TABLE shared.pipeline_runs ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON shared.pipeline_runs
    USING (tenant_id = current_setting('app.tenant_id')::uuid);
*/

-- =============================================================================
-- SCHEMA VERSION TRACKING
-- =============================================================================
CREATE TABLE shared.schema_versions (
    version     VARCHAR(20)  PRIMARY KEY,
    description TEXT,
    applied_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

INSERT INTO shared.schema_versions (version, description) VALUES
    ('v1.0', '001_initial_schema.sql — 9 flat tables'),
    ('v1.1', 'Schema v1.1 — security fix'),
    ('v2.0', '002_schema_v2.sql — 15 flat tables, PRD v4 aligned'),
    ('v3.0', '003_schema_v3.sql — Schema-per-tenant Medallion: shared.*, silver_{slug}.*, gold_{slug}.*');

-- =============================================================================
-- SUMMARY
-- =============================================================================
-- Schemas:   shared | silver_aa_internal | gold_aa_internal
-- Shared:    tenants, tenant_seo_config, tenant_brand_rules, tenant_export_config,
--            lessons_registry (29), pipeline_runs, schema_versions
-- Silver:    raw_sources, raw_tours, seo_context, generated_content,
--            quality_scores, review_queue
-- Gold:      published_tours, content_exports, webhook_deliveries
-- Function:  shared.create_tenant_schemas(slug) — call per new tenant
-- Views:     shared.v_pipeline_summary, shared.v_batch_stats
-- RLS:       Commented out — enable at S7
-- =============================================================================
