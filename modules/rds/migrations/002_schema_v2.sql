-- =============================================================================
-- AA-CIS Database Schema v2.0
-- Tour Content Automation Platform — PRD v4.0 aligned
-- Engine:   PostgreSQL 15
-- DB Name:  aa_cis_dev
-- Updated:  18/04/2026
-- Engineer: Pham Quoc Nghiep
--
-- ARCHITECTURE: Flat shared schema + tenant_id isolation (RLS-ready)
-- Lý do không dùng schema-per-tenant ngay: Phase 1 chỉ có 1 tenant nội bộ
-- (aa_internal). Flat schema + RLS đủ cho Phase 1 và dễ migrate S7.
-- Mọi bảng có tenant_id — RLS policy có thể enable bất kỳ lúc nào.
--
-- MEDALLION LAYERS:
--   BRONZE  → S3 only (raw-inbox/, raw-archive/) — không có bảng DB
--   SILVER  → raw_sources, raw_tours, seo_context,
--             generated_content, quality_scores, review_queue
--   GOLD    → published_tours, content_exports, webhook_deliveries
--   SHARED  → tenants, tenant_seo_config, tenant_brand_rules,
--             tenant_export_config, lessons_registry, pipeline_runs
--
-- THAY ĐỔI SO VỚI v1.1 (9 bảng):
--   RENAME:  published_tour_versions → published_tours (Gold layer)
--   RENAME:  seo_contexts            → seo_context
--   SPLIT:   tenant_configs          → tenant_seo_config
--                                    + tenant_brand_rules
--                                    + tenant_export_config
--   REPLACE: tenant_tour_versions    → generated_content (versioned AI output)
--   REPLACE: tenant_api_logs         → webhook_deliveries
--   NEW:     lessons_registry, quality_scores, review_queue, content_exports
-- =============================================================================

-- Drop schema cũ nếu có (dev only — không dùng production)
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

-- Legacy tables từ v1.1 (nếu còn tồn tại)
DROP TABLE IF EXISTS tenant_api_logs         CASCADE;
DROP TABLE IF EXISTS tenant_tour_versions    CASCADE;
DROP TABLE IF EXISTS tenant_configs          CASCADE;
DROP TABLE IF EXISTS published_tour_versions CASCADE;
DROP TABLE IF EXISTS seo_contexts            CASCADE;

-- =============================================================================
-- ENUMs
-- =============================================================================

DROP TYPE IF EXISTS plan_tier_enum      CASCADE;
DROP TYPE IF EXISTS seo_provider_enum   CASCADE;
DROP TYPE IF EXISTS export_format_enum  CASCADE;
DROP TYPE IF EXISTS pipeline_status_enum CASCADE;
DROP TYPE IF EXISTS content_status_enum  CASCADE;
DROP TYPE IF EXISTS review_status_enum   CASCADE;
DROP TYPE IF EXISTS webhook_status_enum  CASCADE;

CREATE TYPE plan_tier_enum      AS ENUM ('internal', 'starter', 'growth', 'business', 'enterprise');
CREATE TYPE seo_provider_enum   AS ENUM ('dataforseo', 'custom', 'disabled');
CREATE TYPE export_format_enum  AS ENUM ('json', 'csv', 'xml');

-- Silver layer — trạng thái của từng tour trong pipeline
CREATE TYPE pipeline_status_enum AS ENUM (
    'ingested',       -- S1: Excel parsed → raw_tours
    'seo_pending',    -- S2: Chờ SEO Intelligence xử lý
    'seo_done',       -- S2: SEO context đã fetch
    'gen_pending',    -- S3: Chờ Content Gen
    'gen_done',       -- S3: Draft đã tạo
    'validating',     -- S4: Đang chạy 29 Lessons
    'hitl_required',  -- S4: Score thấp → Review Queue
    'hitl_approved',  -- S4: Human approved
    'hitl_rejected',  -- S4: Human rejected
    'published',      -- S5: Đã ghi Gold layer
    'failed'          -- Lỗi không recover
);

-- Generated content status
CREATE TYPE content_status_enum AS ENUM (
    'draft',      -- LangGraph đã tạo, chưa validate
    'passed',     -- 29 Lessons pass
    'hitl',       -- Cần human review
    'approved',   -- Human approved hoặc auto-pass
    'rejected',   -- Human rejected
    'published'   -- Đã publish lên Gold
);

-- HITL review status
CREATE TYPE review_status_enum AS ENUM (
    'pending',   -- Đang chờ reviewer
    'approved',  -- Reviewer accept
    'rejected',  -- Reviewer reject
    'skipped'    -- Timeout / auto-skip
);

-- Webhook delivery status
CREATE TYPE webhook_status_enum AS ENUM (
    'pending',    -- Chưa gửi
    'delivered',  -- HTTP 2xx
    'failed',     -- 3 lần retry đều fail
    'retrying'    -- Đang retry
);

-- =============================================================================
-- SECTION 1: SHARED TABLES (system-level, không phụ thuộc tenant data)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. tenants — Tenant registry. Master record cho mọi B2B client.
-- Ghi chú: Phase 1 seed 1 row: tenant_id = 'aa_internal', plan_tier = 'internal'
-- -----------------------------------------------------------------------------
CREATE TABLE tenants (
    tenant_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(255)   NOT NULL,
    slug            VARCHAR(100)   NOT NULL UNIQUE,  -- dùng làm S3 prefix
    plan_tier       plan_tier_enum NOT NULL DEFAULT 'internal',
    api_key_hash    VARCHAR(255),                    -- SHA-256 của API key thực
    rate_limit_rpm  INTEGER        NOT NULL DEFAULT 60,
    is_active       BOOLEAN        NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  tenants IS 'Tenant registry. 1 row per B2B client. Phase 1: 1 row (aa_internal).';
COMMENT ON COLUMN tenants.slug IS 'URL-safe slug, used as S3 prefix: raw-inbox/{slug}/';

-- Seed tenant nội bộ AA ngay
INSERT INTO tenants (tenant_id, name, slug, plan_tier, is_active)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'Adventure Asia Internal',
    'aa-internal',
    'internal',
    TRUE
);

-- -----------------------------------------------------------------------------
-- 2. tenant_seo_config — SEO strategy per tenant
-- PRD §5.1: 3 modes: dataforseo | custom | disabled
-- -----------------------------------------------------------------------------
CREATE TABLE tenant_seo_config (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID           NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    seo_provider    seo_provider_enum NOT NULL DEFAULT 'dataforseo',
    custom_keywords JSONB,          -- [{keyword, tier: primary|secondary|lsi}]
    target_market   JSONB,          -- {countries: [], age_range: [], language: "en"}
    overrides       JSONB,          -- {min_volume: 100, exclude_intents: [...]}
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id)               -- 1 config per tenant
);

COMMENT ON COLUMN tenant_seo_config.custom_keywords IS 'Used khi seo_provider=custom. Skip DataforSEO API call.';
COMMENT ON COLUMN tenant_seo_config.target_market   IS 'Demographics target: {countries, age_range, language}';

-- Seed config cho aa-internal
INSERT INTO tenant_seo_config (tenant_id, seo_provider, target_market)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'dataforseo',
    '{"countries": ["AU", "UK", "US"], "age_range": [40, 60], "language": "en"}'
);

-- -----------------------------------------------------------------------------
-- 3. tenant_brand_rules — System prompt + style guide per tenant
-- PRD §5.2: Tenant override AA default brand rules
-- -----------------------------------------------------------------------------
CREATE TABLE tenant_brand_rules (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID        NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    system_prompt    TEXT,                           -- NULL = dùng AA default
    style_guide      TEXT,
    forbidden_words  JSONB       DEFAULT '[]',       -- ["deals", "cheap", ...]
    custom_validators JSONB      DEFAULT '[]',       -- [{fn_name, code_s3_path}]
    version          INTEGER     NOT NULL DEFAULT 1,
    is_active        BOOLEAN     NOT NULL DEFAULT TRUE,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, is_active)                     -- Chỉ 1 active version per tenant
);

COMMENT ON COLUMN tenant_brand_rules.system_prompt IS 'NULL = inherit AA default brand rules từ prompts.py';
COMMENT ON COLUMN tenant_brand_rules.custom_validators IS '[{fn_name, code_s3_path, timeout_s}]';

-- Seed: aa-internal dùng AA default (system_prompt = NULL)
INSERT INTO tenant_brand_rules (tenant_id, forbidden_words)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    '["deals", "cheap", "book now", "instant booking", "discount"]'
);

-- -----------------------------------------------------------------------------
-- 4. tenant_export_config — Webhook + export settings per tenant
-- PRD §5.3: Webhook URL, format, field mapping
-- -----------------------------------------------------------------------------
CREATE TABLE tenant_export_config (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID              NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    webhook_url     VARCHAR(500),
    export_format   export_format_enum NOT NULL DEFAULT 'json',
    field_mapping   JSONB             DEFAULT '{}',  -- {aa_name: "product_title", ...}
    auth_header     VARCHAR(500),                    -- "Bearer <token>" — encrypted at rest
    is_active       BOOLEAN           NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id)
);

COMMENT ON COLUMN tenant_export_config.field_mapping IS 'Rename output fields per tenant. {aa_name: "product_title"}';
COMMENT ON COLUMN tenant_export_config.auth_header   IS 'Stored encrypted. Use Secrets Manager ref in prod.';

-- Seed: aa-internal no webhook
INSERT INTO tenant_export_config (tenant_id, export_format)
VALUES ('00000000-0000-0000-0000-000000000001', 'json');

-- -----------------------------------------------------------------------------
-- 5. lessons_registry — 29 Lessons validators, system-wide
-- PRD §3.1 shared table. Seeded với 29 lessons từ validators/v01–v29.
-- -----------------------------------------------------------------------------
CREATE TABLE lessons_registry (
    id              SERIAL PRIMARY KEY,
    lesson_num      SMALLINT    NOT NULL UNIQUE,     -- 1–29
    category        VARCHAR(100) NOT NULL,           -- brand_voice | seo | structure | ...
    validator_fn    VARCHAR(200) NOT NULL UNIQUE,    -- Python function name: validate_v01_...
    failure_code    VARCHAR(50)  NOT NULL UNIQUE,    -- V01, V02, ...
    description     TEXT,
    example_before  TEXT,
    example_after   TEXT,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    version         INTEGER     NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  lessons_registry IS '29 brand rule validators. System-wide, không customize per tenant (tenant có thể ADD thêm qua tenant_brand_rules.custom_validators).';
COMMENT ON COLUMN lessons_registry.failure_code IS 'Code trả về khi fail: V01 = ALL_CAPS, V02 = ...';

-- Seed 29 lessons (category + function name mapping)
INSERT INTO lessons_registry (lesson_num, category, validator_fn, failure_code, description) VALUES
( 1, 'structure',   'validate_v01_all_caps',            'V01', 'Name/subtitle không được ALL CAPS'),
( 2, 'structure',   'validate_v02_name_length',         'V02', 'Name ≤ 70 chars, subtitle ≤ 120 chars'),
( 3, 'brand_voice', 'validate_v03_forbidden_words',     'V03', 'Không dùng deals/cheap/instant booking'),
( 4, 'brand_voice', 'validate_v04_tone_formal',         'V04', 'Tone phải refined, không salesy'),
( 5, 'seo',         'validate_v05_primary_keyword',     'V05', 'Primary keyword phải xuất hiện trong name hoặc subtitle'),
( 6, 'seo',         'validate_v06_keyword_density',     'V06', 'Keyword density 1–3% trong summary'),
( 7, 'seo',         'validate_v07_seo_title_length',    'V07', 'SEO title 50–60 chars'),
( 8, 'seo',         'validate_v08_meta_description',    'V08', 'Meta description 150–160 chars'),
( 9, 'structure',   'validate_v09_highlights_count',    'V09', '3–7 highlights, không nhiều hơn không ít hơn'),
(10, 'structure',   'validate_v10_highlights_format',   'V10', 'Mỗi highlight: verb-led, ≤ 12 words'),
(11, 'structure',   'validate_v11_itinerary_days',      'V11', 'Số ngày trong itinerary match duration'),
(12, 'structure',   'validate_v12_itinerary_format',    'V12', 'Mỗi ngày có title + ≥ 2 activities'),
(13, 'brand_voice', 'validate_v13_cta_language',        'V13', 'CTA phải là "Design This Journey" không phải "Book Now"'),
(14, 'brand_voice', 'validate_v14_no_price_mention',    'V14', 'Content không đề cập giá tiền'),
(15, 'brand_voice', 'validate_v15_target_demographic',  'V15', 'Phù hợp cho 40–60 tuổi senior professionals'),
(16, 'quality',     'validate_v16_no_placeholder',      'V16', 'Không có [PLACEHOLDER] hoặc TBD trong output'),
(17, 'quality',     'validate_v17_no_repetition',       'V17', 'Không lặp câu/ý trong cùng section'),
(18, 'quality',     'validate_v18_factual_consistency', 'V18', 'Country/destination phải nhất quán xuyên suốt'),
(19, 'seo',         'validate_v19_secondary_keywords',  'V19', '≥ 2 secondary keywords xuất hiện trong body'),
(20, 'brand_voice', 'validate_v20_brand_vocabulary',    'V20', 'Dùng: Design/Curated/Refined/Tailored/Journey'),
(21, 'structure',   'validate_v21_summary_length',      'V21', 'Summary 80–120 words'),
(22, 'structure',   'validate_v22_description_length',  'V22', 'Description 150–250 words'),
(23, 'quality',     'validate_v23_no_generic_phrases',  'V23', 'Không có "world-class", "once in a lifetime"'),
(24, 'seo',         'validate_v24_lsi_keywords',        'V24', '≥ 1 LSI keyword trong highlights'),
(25, 'brand_voice', 'validate_v25_cultural_sensitivity','V25', 'Không có stereotypes về destinations'),
(26, 'structure',   'validate_v26_encoding_clean',      'V26', 'Không có HTML entities, markdown symbols trong output'),
(27, 'quality',     'validate_v27_activity_specificity','V27', 'Activities phải cụ thể, không chung chung'),
(28, 'seo',         'validate_v28_og_tags_present',     'V28', 'og:title, og:description, og:image phải có'),
(29, 'quality',     'validate_v29_mobile_card_text',    'V29', 'mobile_card_text ≤ 60 chars, verb-led');

-- -----------------------------------------------------------------------------
-- 6. pipeline_runs — Execution tracking + billing per batch
-- PRD §3.1 shared table. 1 row per batch submission.
-- -----------------------------------------------------------------------------
CREATE TABLE pipeline_runs (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID        NOT NULL REFERENCES tenants(tenant_id),
    batch_id            UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    batch_name          VARCHAR(255),
    s3_source_path      VARCHAR(500),               -- s3://aa-cis-bronze/raw-inbox/{tenant}/{batch}/
    status              VARCHAR(50) NOT NULL DEFAULT 'running',  -- running|completed|failed|partial
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

CREATE INDEX idx_pipeline_runs_tenant    ON pipeline_runs(tenant_id);
CREATE INDEX idx_pipeline_runs_batch     ON pipeline_runs(batch_id);
CREATE INDEX idx_pipeline_runs_status    ON pipeline_runs(status);

COMMENT ON TABLE pipeline_runs IS 'Billing + cost tracking per batch. 1 row per Excel upload.';

-- =============================================================================
-- SECTION 2: SILVER LAYER TABLES (cleaned & enriched data)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 7. raw_sources — Bronze S3 file metadata (pointer, không chứa data thực)
-- 1 row per Excel file uploaded
-- -----------------------------------------------------------------------------
CREATE TABLE raw_sources (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID        NOT NULL REFERENCES tenants(tenant_id),
    batch_id        UUID        NOT NULL REFERENCES pipeline_runs(batch_id),
    filename        VARCHAR(500) NOT NULL,
    s3_path         VARCHAR(500) NOT NULL,           -- s3://aa-cis-bronze/raw-inbox/...
    file_size_kb    INTEGER,
    row_count       INTEGER,
    parsed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    parse_errors    JSONB       DEFAULT '[]'         -- [{row, error}]
);

CREATE INDEX idx_raw_sources_batch    ON raw_sources(batch_id);
CREATE INDEX idx_raw_sources_tenant   ON raw_sources(tenant_id);

COMMENT ON TABLE raw_sources IS 'Metadata pointer về Bronze S3 file. Không lưu file content — file bất biến trên S3.';

-- -----------------------------------------------------------------------------
-- 8. raw_tours — Immutable source data từ Excel (Silver layer input)
-- Fields từ 6 file Excel thực tế + PRD §3.1 silver schema
-- KHÔNG được UPDATE sau khi insert — đây là record gốc bất biến
-- -----------------------------------------------------------------------------
CREATE TABLE raw_tours (
    tour_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID                NOT NULL REFERENCES tenants(tenant_id),
    batch_id        UUID                NOT NULL REFERENCES pipeline_runs(batch_id),
    source_id       UUID                REFERENCES raw_sources(id),

    -- Source identifiers
    tour_id_external VARCHAR(200),                  -- ID từ provider gốc
    sku             VARCHAR(200),
    provider        VARCHAR(255),

    -- Core fields (src_ prefix = raw, chưa rewrite)
    src_name        VARCHAR(500)        NOT NULL,
    src_subtitle    VARCHAR(500),
    src_summary     TEXT,
    src_description TEXT,
    src_highlights  JSONB               DEFAULT '[]',  -- [string, ...]
    src_itineraries TEXT,               -- raw itinerary text hoặc JSON string
    country         VARCHAR(100),
    duration        VARCHAR(100),       -- "8 days", "10D/9N"
    group_size      VARCHAR(100),
    period          VARCHAR(200),       -- best time to go

    -- Commercial fields
    price_raw       VARCHAR(200),       -- raw price string, không normalize
    inclusions      TEXT,
    exclusions      TEXT,
    links           JSONB               DEFAULT '[]',

    -- Extended
    activities      JSONB               DEFAULT '[]',
    feature         TEXT,
    best_time_to_go VARCHAR(500),

    -- SEO raw fields từ DataforSEO pre-fetch
    dfs_query                   VARCHAR(500),
    dfs_keyword_search          VARCHAR(500),
    dfs_people_also_ask         JSONB   DEFAULT '[]',
    dfs_related_searches        JSONB   DEFAULT '[]',
    dfs_keyword_ideas           JSONB   DEFAULT '[]',
    dfs_keyword_suggestions     JSONB   DEFAULT '[]',
    dfs_related_keywords        JSONB   DEFAULT '[]',
    dfs_competitors             JSONB   DEFAULT '[]',

    -- Pipeline tracking
    pipeline_status pipeline_status_enum NOT NULL DEFAULT 'ingested',
    ingest_at       TIMESTAMPTZ          NOT NULL DEFAULT NOW()

    -- KHÔNG có updated_at — record này bất biến sau insert
);

CREATE INDEX idx_raw_tours_tenant         ON raw_tours(tenant_id);
CREATE INDEX idx_raw_tours_batch          ON raw_tours(batch_id);
CREATE INDEX idx_raw_tours_status         ON raw_tours(pipeline_status);
CREATE INDEX idx_raw_tours_country        ON raw_tours(country);
CREATE INDEX idx_raw_tours_external       ON raw_tours(tour_id_external) WHERE tour_id_external IS NOT NULL;

COMMENT ON TABLE  raw_tours IS 'Immutable source data. DO NOT UPDATE sau khi insert. Pipeline chỉ UPDATE pipeline_status.';
COMMENT ON COLUMN raw_tours.src_highlights  IS 'Raw highlights array từ Excel';
COMMENT ON COLUMN raw_tours.price_raw       IS 'Raw string, không normalize — "From $2,400 per person"';

-- Cho phép UPDATE pipeline_status only
-- (Enforce qua application layer + code review — PostgreSQL không có column-level update restriction)

-- -----------------------------------------------------------------------------
-- 9. seo_context — DataforSEO results per tour (Silver layer)
-- Cache TTL 24h (Redis), backup tại đây
-- -----------------------------------------------------------------------------
CREATE TABLE seo_context (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tour_id         UUID        NOT NULL REFERENCES raw_tours(tour_id),
    tenant_id       UUID        NOT NULL REFERENCES tenants(tenant_id),

    -- Query used
    keyword_search  VARCHAR(500),
    provider        seo_provider_enum NOT NULL DEFAULT 'dataforseo',

    -- Results (từ DataforSEO hoặc tenant custom keywords)
    keyword_ideas   JSONB   DEFAULT '[]',    -- [{keyword, volume, relevance, trend}]
    demographics    JSONB   DEFAULT '{}',    -- {age_range, income, travel_style}
    trends          JSONB   DEFAULT '{}',    -- {monthly_searches, seasonality}
    top_keywords    JSONB   DEFAULT '[]',    -- Top 5 keywords đã chọn (scored)

    -- Cache metadata
    cache_key       VARCHAR(500) UNIQUE,    -- {tenant_id}:{country}:{activity}:{market}
    fetched_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ             -- fetched_at + 24h

    -- Không có UNIQUE(tour_id) — 1 tour có thể có nhiều seo_context nếu retry
);

CREATE INDEX idx_seo_context_tour     ON seo_context(tour_id);
CREATE INDEX idx_seo_context_tenant   ON seo_context(tenant_id);
CREATE INDEX idx_seo_context_cache    ON seo_context(cache_key);

COMMENT ON TABLE seo_context IS 'DataforSEO results. Redis L1 cache, RDS là L2 backup. TTL 24h.';

-- -----------------------------------------------------------------------------
-- 10. generated_content — AI output, versioned per tour (Silver layer)
-- Mỗi retry tạo 1 row mới (version_num tăng dần)
-- PRD §3.1 silver schema: generated_content table
-- -----------------------------------------------------------------------------
CREATE TABLE generated_content (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tour_id         UUID                NOT NULL REFERENCES raw_tours(tour_id),
    tenant_id       UUID                NOT NULL REFERENCES tenants(tenant_id),
    version_num     SMALLINT            NOT NULL DEFAULT 1,  -- 1, 2, 3 (retry)

    -- Rewritten fields (aa_ prefix = Adventure Asia output)
    aa_name         VARCHAR(500),
    aa_subtitle     VARCHAR(500),
    aa_summary      TEXT,
    aa_description  TEXT,
    aa_highlights   JSONB   DEFAULT '[]',   -- [string, ...]  max 7
    aa_itineraries  TEXT,                   -- Formatted day-by-day text
    mobile_card_text VARCHAR(80),           -- ≤ 60 chars, verb-led (V29)

    -- SEO output
    seo_title       VARCHAR(70),            -- 50–60 chars (V07)
    seo_meta        VARCHAR(170),           -- 150–160 chars (V08)
    seo_keywords_used JSONB  DEFAULT '[]',  -- Keywords thực sự được inject

    -- OG tags
    og_tags         JSONB   DEFAULT '{}',   -- {og:title, og:description, og:image}

    -- Generation metadata
    model_editorial VARCHAR(100),           -- "claude-sonnet-4-20250514"
    model_schema    VARCHAR(100),           -- "gpt-4.1" (schema enforcement)
    prompt_version  VARCHAR(50),
    brand_rules_version INTEGER,            -- tenant_brand_rules.version used

    -- Status trong pipeline
    status          content_status_enum NOT NULL DEFAULT 'draft',
    retry_count     SMALLINT            NOT NULL DEFAULT 0,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tour_id, version_num)
);

CREATE INDEX idx_gen_content_tour     ON generated_content(tour_id);
CREATE INDEX idx_gen_content_tenant   ON generated_content(tenant_id);
CREATE INDEX idx_gen_content_status   ON generated_content(status);

COMMENT ON TABLE  generated_content IS 'AI output. Mỗi retry = 1 row mới (version_num++). KHÔNG update row cũ.';
COMMENT ON COLUMN generated_content.version_num IS '1 = lần đầu, 2+ = retry sau HITL reject';

-- -----------------------------------------------------------------------------
-- 11. quality_scores — 4-layer validation results per generated_content
-- PRD §3.1 silver schema
-- -----------------------------------------------------------------------------
CREATE TABLE quality_scores (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    generated_content_id  UUID        NOT NULL REFERENCES generated_content(id),
    tour_id               UUID        NOT NULL REFERENCES raw_tours(tour_id),
    tenant_id             UUID        NOT NULL REFERENCES tenants(tenant_id),

    -- Scores
    score_overall         DECIMAL(5,2) NOT NULL,    -- 0.00–100.00
    score_brand           DECIMAL(5,2),
    score_seo             DECIMAL(5,2),
    score_structure       DECIMAL(5,2),
    score_quality         DECIMAL(5,2),

    -- Failure detail
    failure_codes         JSONB   DEFAULT '[]',     -- ["V03", "V07", ...]
    issues                JSONB   DEFAULT '[]',     -- [{code, field, detail, severity}]
    passed_count          SMALLINT NOT NULL DEFAULT 0,
    failed_count          SMALLINT NOT NULL DEFAULT 0,

    -- Metadata
    validator_fn_version  VARCHAR(50),
    langfuse_trace_id     VARCHAR(200),
    evaluated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_quality_scores_content ON quality_scores(generated_content_id);
CREATE INDEX idx_quality_scores_tour    ON quality_scores(tour_id);
CREATE INDEX idx_quality_scores_tenant  ON quality_scores(tenant_id);

COMMENT ON TABLE  quality_scores IS '4-layer validation: brand_voice + seo + structure + quality. 1 row per generated_content evaluation.';
COMMENT ON COLUMN quality_scores.failure_codes IS 'Codes từ lessons_registry.failure_code: ["V03", "V07"]';

-- -----------------------------------------------------------------------------
-- 12. review_queue — HITL queue (Silver layer)
-- Step Functions callback token stored đây để resume execution
-- PRD §3.1 silver schema
-- -----------------------------------------------------------------------------
CREATE TABLE review_queue (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tour_id               UUID                NOT NULL REFERENCES raw_tours(tour_id),
    generated_content_id  UUID                NOT NULL REFERENCES generated_content(id),
    tenant_id             UUID                NOT NULL REFERENCES tenants(tenant_id),

    -- Failure context
    failure_summary       TEXT,               -- "Failed V03 (forbidden words), V07 (SEO title length)"
    score_overall         DECIMAL(5,2),

    -- Step Functions HITL
    step_fn_task_token    TEXT,               -- Token để resume Step Functions execution
    step_fn_execution_arn VARCHAR(500),

    -- Review
    review_status         review_status_enum  NOT NULL DEFAULT 'pending',
    reviewer_notes        TEXT,
    reviewed_by           VARCHAR(200),       -- Staff username
    reviewed_at           TIMESTAMPTZ,

    created_at            TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_review_queue_tour     ON review_queue(tour_id);
CREATE INDEX idx_review_queue_tenant   ON review_queue(tenant_id);
CREATE INDEX idx_review_queue_status   ON review_queue(review_status);

COMMENT ON TABLE  review_queue IS 'HITL queue. step_fn_task_token dùng để sendTaskSuccess/sendTaskFailure về Step Functions sau khi human review xong.';
COMMENT ON COLUMN review_queue.step_fn_task_token IS 'Lưu token từ Step Functions waitForTaskToken. Expire sau 1 năm.';

-- =============================================================================
-- SECTION 3: GOLD LAYER TABLES (published, business-ready)
-- Immutable sau khi published_at được set
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 13. published_tours — Final approved content (Gold layer)
-- Immutable sau publish. B2B API reads đây.
-- PRD §3.1 gold schema
-- -----------------------------------------------------------------------------
CREATE TABLE published_tours (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tour_id               UUID        NOT NULL REFERENCES raw_tours(tour_id) UNIQUE,
    generated_content_id  UUID        NOT NULL REFERENCES generated_content(id),
    tenant_id             UUID        NOT NULL REFERENCES tenants(tenant_id),

    -- Final content (snapshot tại thời điểm publish — không reference generated_content để tránh drift)
    aa_name               VARCHAR(500) NOT NULL,
    aa_subtitle           VARCHAR(500),
    aa_summary            TEXT,
    aa_description        TEXT,
    aa_highlights         JSONB       DEFAULT '[]',
    aa_itineraries        TEXT,
    mobile_card_text      VARCHAR(80),

    -- SEO final
    seo_title             VARCHAR(70),
    seo_meta              VARCHAR(170),
    seo_keywords_used     JSONB       DEFAULT '[]',
    og_tags               JSONB       DEFAULT '{}',

    -- Quality snapshot
    quality_score         DECIMAL(5,2),
    quality_score_id      UUID        REFERENCES quality_scores(id),

    -- Gold S3 path
    s3_gold_path          VARCHAR(500),    -- s3://aa-cis-gold/published/{tenant}/{tour_id}.json

    -- Audit
    approved_by           VARCHAR(200),    -- 'auto' hoặc staff username
    published_at          TIMESTAMPTZ      NOT NULL DEFAULT NOW()

    -- Không có updated_at — IMMUTABLE
);

CREATE INDEX idx_published_tours_tenant   ON published_tours(tenant_id);
CREATE INDEX idx_published_tours_pub_at   ON published_tours(published_at DESC);

COMMENT ON TABLE  published_tours IS 'Gold layer. Immutable sau published_at. B2B REST API trả về data từ bảng này.';
COMMENT ON COLUMN published_tours.tour_id IS 'UNIQUE: mỗi raw_tour chỉ có 1 published version (latest wins).';

-- -----------------------------------------------------------------------------
-- 14. content_exports — Bulk export jobs (Gold layer)
-- PRD §5.3: POST /v1/exports → async job → S3 signed URL
-- -----------------------------------------------------------------------------
CREATE TABLE content_exports (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID              NOT NULL REFERENCES tenants(tenant_id),
    export_id       UUID              NOT NULL UNIQUE DEFAULT gen_random_uuid(),

    -- Export params
    format          export_format_enum NOT NULL DEFAULT 'json',
    filter_params   JSONB              DEFAULT '{}',   -- {date_from, date_to, countries, ...}
    field_mapping   JSONB              DEFAULT '{}',   -- Snapshot của tenant_export_config.field_mapping

    -- Output
    s3_path         VARCHAR(500),      -- s3://aa-cis-gold/exports/{tenant}/{export_id}.json
    signed_url      TEXT,              -- Pre-signed URL, expire 7 ngày
    total_tours     INTEGER,
    file_size_kb    INTEGER,

    -- Status
    status          VARCHAR(50)        NOT NULL DEFAULT 'pending',  -- pending|processing|done|failed
    expires_at      TIMESTAMPTZ,       -- signed_url expiry
    created_at      TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ
);

CREATE INDEX idx_content_exports_tenant ON content_exports(tenant_id);

COMMENT ON TABLE content_exports IS 'Bulk export jobs. Async: Lambda tạo file → S3 → update signed_url. TTL 7 ngày.';

-- -----------------------------------------------------------------------------
-- 15. webhook_deliveries — Webhook delivery log (Gold layer)
-- PRD §5.3: 3 retries, HMAC signing, idempotency
-- -----------------------------------------------------------------------------
CREATE TABLE webhook_deliveries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID              NOT NULL REFERENCES tenants(tenant_id),
    tour_id         UUID              NOT NULL REFERENCES raw_tours(tour_id),

    -- Delivery metadata
    webhook_url     VARCHAR(500)      NOT NULL,
    event_type      VARCHAR(100)      NOT NULL DEFAULT 'tour.published',
    -- Options: tour.published | tour.review_required | batch.completed

    -- Payload
    delivery_id     UUID              NOT NULL DEFAULT gen_random_uuid(), -- Idempotency key
    payload_s3_path VARCHAR(500),     -- s3://aa-cis-gold/webhooks/{tenant}/payload_{ts}.json

    -- Delivery status
    status          webhook_status_enum NOT NULL DEFAULT 'pending',
    http_status     SMALLINT,          -- 200, 400, 500, ...
    attempt_count   SMALLINT           NOT NULL DEFAULT 0,
    last_error      TEXT,

    -- Timestamps
    created_at      TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
    next_retry_at   TIMESTAMPTZ,       -- NULL khi đã delivered hoặc failed
    delivered_at    TIMESTAMPTZ
);

CREATE INDEX idx_webhook_deliveries_tenant  ON webhook_deliveries(tenant_id);
CREATE INDEX idx_webhook_deliveries_tour    ON webhook_deliveries(tour_id);
CREATE INDEX idx_webhook_deliveries_status  ON webhook_deliveries(status);
CREATE INDEX idx_webhook_deliveries_retry   ON webhook_deliveries(next_retry_at) WHERE status = 'retrying';

COMMENT ON TABLE  webhook_deliveries IS 'Webhook delivery log. Retry 3×: 30s/60s/120s backoff. HMAC signature gửi trong X-Signature header.';
COMMENT ON COLUMN webhook_deliveries.delivery_id IS 'Idempotency key gửi trong X-Delivery-ID header cho tenant dedup.';

-- =============================================================================
-- SECTION 4: RLS SETUP (enable sau khi thêm tenant thực ở S7)
-- =============================================================================

-- RLS chưa enable Phase 1 (chỉ có 1 tenant nội bộ).
-- Script dưới đây COMMENT OUT — uncomment tại S7 khi onboard tenant B2B đầu tiên.

/*
-- Enable RLS trên tất cả Silver + Gold tables
ALTER TABLE raw_sources       ENABLE ROW LEVEL SECURITY;
ALTER TABLE raw_tours         ENABLE ROW LEVEL SECURITY;
ALTER TABLE seo_context       ENABLE ROW LEVEL SECURITY;
ALTER TABLE generated_content ENABLE ROW LEVEL SECURITY;
ALTER TABLE quality_scores    ENABLE ROW LEVEL SECURITY;
ALTER TABLE review_queue      ENABLE ROW LEVEL SECURITY;
ALTER TABLE published_tours   ENABLE ROW LEVEL SECURITY;
ALTER TABLE content_exports   ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE pipeline_runs     ENABLE ROW LEVEL SECURITY;

-- Policy: mỗi app transaction SET LOCAL app.tenant_id = '{uuid}' trước khi query
CREATE POLICY tenant_isolation ON raw_sources
    USING (tenant_id = current_setting('app.tenant_id')::uuid);
-- (Repeat pattern cho tất cả các bảng trên)

-- DBA account bypass RLS
ALTER TABLE raw_tours FORCE ROW LEVEL SECURITY;
-- aa_cis_admin (DBA) là BYPASSRLS — không cần set context

-- Application user (app_user — read/write nhưng KHÔNG bypass RLS)
-- CREATE ROLE app_user LOGIN;
-- GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO app_user;
*/

-- =============================================================================
-- SECTION 5: USEFUL VIEWS
-- =============================================================================

-- View: pipeline_summary — tổng quan trạng thái từng tour
CREATE OR REPLACE VIEW v_pipeline_summary AS
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
FROM raw_tours rt
LEFT JOIN LATERAL (
    SELECT id, version_num, status
    FROM generated_content
    WHERE tour_id = rt.tour_id
    ORDER BY version_num DESC
    LIMIT 1
) gc ON TRUE
LEFT JOIN LATERAL (
    SELECT score_overall, failure_codes
    FROM quality_scores
    WHERE generated_content_id = gc.id
    ORDER BY evaluated_at DESC
    LIMIT 1
) qs ON TRUE
LEFT JOIN published_tours pt ON pt.tour_id = rt.tour_id;

COMMENT ON VIEW v_pipeline_summary IS 'Overview mỗi tour: raw status + latest content + score + published. Dùng cho Admin Dashboard.';

-- View: batch_stats — stats per batch cho pipeline_runs update
CREATE OR REPLACE VIEW v_batch_stats AS
SELECT
    batch_id,
    COUNT(*)                                            AS total,
    COUNT(*) FILTER (WHERE pipeline_status = 'published')  AS passed,
    COUNT(*) FILTER (WHERE pipeline_status = 'hitl_required') AS hitl,
    COUNT(*) FILTER (WHERE pipeline_status = 'failed')     AS failed
FROM raw_tours
GROUP BY batch_id;

COMMENT ON VIEW v_batch_stats IS 'Dùng để UPDATE pipeline_runs.tours_total/passed/hitl/failed sau mỗi batch.';

-- =============================================================================
-- SCHEMA VERSION TRACKING
-- =============================================================================

CREATE TABLE IF NOT EXISTS schema_versions (
    version     VARCHAR(20)  PRIMARY KEY,
    description TEXT,
    applied_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

INSERT INTO schema_versions (version, description) VALUES
    ('v1.0', '001_initial_schema.sql — 9 tables (flat, OpsLog 16/04)'),
    ('v1.1', 'Schema v1.1 — 10 tables (CBT v3 mention, details unknown)'),
    ('v2.0', '002_schema_v2.sql — 15 tables, PRD v4.0 aligned, Medallion layers, RLS-ready');

-- =============================================================================
-- SUMMARY
-- =============================================================================
-- Tables: 15 (+ 2 views + 1 schema_versions)
-- Shared:  tenants, tenant_seo_config, tenant_brand_rules,
--          tenant_export_config, lessons_registry, pipeline_runs
-- Silver:  raw_sources, raw_tours, seo_context,
--          generated_content, quality_scores, review_queue
-- Gold:    published_tours, content_exports, webhook_deliveries
-- ENUMs:   plan_tier, seo_provider, export_format,
--          pipeline_status (11 values), content_status (6), review_status (4), webhook_status (4)
-- Seed:    1 tenant (aa-internal) + default configs + 29 lessons
-- RLS:     Commented out — enable tại S7 khi onboard B2B tenant đầu tiên
-- =============================================================================
