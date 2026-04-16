-- ============================================================
-- AA-CIS Database Schema v1.0
-- Migration: 001_initial_schema
-- ============================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- LAYER 0: Enum types
-- ============================================================

CREATE TYPE pipeline_status_enum AS ENUM (
    'queued', 'processing', 'done', 'failed', 'skipped'
);

CREATE TYPE audit_status_enum AS ENUM (
    'passed', 'flagged', 'failed'
);

CREATE TYPE hitl_status_enum AS ENUM (
    'pending', 'approved', 'rejected', 'revision_requested'
);

CREATE TYPE tenant_plan_enum AS ENUM (
    'basic', 'pro', 'enterprise'
);

CREATE TYPE seo_provider_enum AS ENUM (
    'dataforseo', 'custom', 'skip'
);

-- ============================================================
-- LAYER 1: RAW DATA
-- ============================================================

CREATE TABLE raw_sources (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    s3_bucket       TEXT NOT NULL,
    s3_key          TEXT NOT NULL,
    supplier_name   TEXT,
    original_filename TEXT,
    uploaded_at     TIMESTAMPTZ DEFAULT NOW(),
    status          pipeline_status_enum DEFAULT 'pending',
    row_count       INT,
    error_message   TEXT
);

CREATE TABLE raw_tours (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id               UUID REFERENCES raw_sources(id) ON DELETE SET NULL,

    -- Identity
    tour_id_external        TEXT,
    sku                     TEXT,
    country                 TEXT,

    -- Core content
    name                    TEXT NOT NULL,
    subtitle                TEXT,
    duration                TEXT,
    group_size              TEXT,
    period                  TEXT,

    -- Content blocks
    summary                 TEXT,
    description             TEXT,
    highlights              TEXT,
    itineraries             TEXT,
    inclusions              TEXT,
    exclusions              TEXT,

    -- Commercial
    provider                TEXT,
    price_raw               TEXT,
    links                   TEXT,

    -- Extended fields
    activities              TEXT,
    feature                 TEXT,
    best_time_to_go         TEXT,

    -- SEO raw from DataForSEO
    dfs_query               TEXT,
    dfs_keyword_search      TEXT,
    dfs_people_also_ask     TEXT,
    dfs_related_searches    TEXT,
    dfs_keyword_ideas       TEXT,
    dfs_keyword_suggestions TEXT,
    dfs_related_keywords    TEXT,
    dfs_competitor_angles   TEXT,

    -- ETL metadata
    source_file             TEXT,
    raw_data                JSONB,
    etl_at                  TIMESTAMPTZ DEFAULT NOW(),
    etl_version             TEXT,
    pipeline_status         pipeline_status_enum DEFAULT 'queued'
);

CREATE INDEX idx_raw_tours_source    ON raw_tours(source_id);
CREATE INDEX idx_raw_tours_country   ON raw_tours(country);
CREATE INDEX idx_raw_tours_status    ON raw_tours(pipeline_status);
CREATE INDEX idx_raw_tours_sku       ON raw_tours(sku);

-- ============================================================
-- LAYER 2: PUBLISHED (AA Internal)
-- ============================================================

CREATE TABLE published_tour_versions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    raw_tour_id         UUID NOT NULL REFERENCES raw_tours(id) ON DELETE CASCADE,
    version_number      INT NOT NULL DEFAULT 1,

    -- Rewritten content
    name                TEXT,
    subtitle            TEXT,
    summary             TEXT,
    highlights          TEXT[],
    itineraries         JSONB,
    seo_title           TEXT,
    seo_meta            TEXT,
    trip_type           TEXT,

    -- Validation result
    audit_status        audit_status_enum,
    audit_failure_codes TEXT[],
    audit_issues        TEXT,
    fields_updated      TEXT[],
    quality_score       NUMERIC(3,1) CHECK (quality_score BETWEEN 0 AND 10),

    -- Decision
    publish_ready       BOOLEAN DEFAULT FALSE,
    publish_notes       TEXT,
    hitl_status         hitl_status_enum DEFAULT 'pending',
    hitl_note           TEXT,
    hitl_by             TEXT,
    hitl_at             TIMESTAMPTZ,

    -- Pipeline metadata
    pipeline_run_id     TEXT,
    llm_model           TEXT,
    prompt_version      TEXT,
    generation_cost_usd NUMERIC(8,6),

    -- Active flag (chỉ 1 version TRUE per raw_tour)
    is_active           BOOLEAN DEFAULT FALSE,
    created_at          TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(raw_tour_id, version_number)
);

CREATE INDEX idx_ptv_raw_tour     ON published_tour_versions(raw_tour_id);
CREATE INDEX idx_ptv_active       ON published_tour_versions(raw_tour_id, is_active)
    WHERE is_active = TRUE;
CREATE INDEX idx_ptv_hitl         ON published_tour_versions(hitl_status)
    WHERE hitl_status = 'pending';

-- SEO cache
CREATE TABLE seo_contexts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    destination     TEXT NOT NULL,
    activity        TEXT,
    keywords        JSONB,
    demographics    JSONB,
    fetched_at      TIMESTAMPTZ DEFAULT NOW(),
    expires_at      TIMESTAMPTZ,
    UNIQUE(destination, activity)
);

-- ============================================================
-- LAYER 3: B2B TENANT
-- ============================================================

CREATE TABLE tenants (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    slug            TEXT UNIQUE NOT NULL,
    api_key_hash    TEXT NOT NULL,
    plan            tenant_plan_enum DEFAULT 'basic',
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE tenant_configs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID UNIQUE REFERENCES tenants(id) ON DELETE CASCADE,

    -- SEO preferences
    seo_provider    seo_provider_enum DEFAULT 'dataforseo',
    seo_overrides   JSONB,

    -- Content style
    brand_voice     TEXT,
    forbidden_words TEXT[],
    custom_rules    JSONB,
    prompt_override TEXT,

    -- Output preferences
    output_format   TEXT DEFAULT 'json',
    webhook_url     TEXT,

    -- Snapshot hướng dẫn config (markdown)
    config_guide    TEXT,

    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE tenant_tour_versions (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    published_version_id    UUID NOT NULL REFERENCES published_tour_versions(id),
    version_number          INT NOT NULL DEFAULT 1,

    -- Customized output
    name                    TEXT,
    subtitle                TEXT,
    summary                 TEXT,
    highlights              TEXT[],
    itineraries             JSONB,
    seo_title               TEXT,
    seo_meta                TEXT,

    -- Config snapshot tại thời điểm generate
    config_snapshot         JSONB,

    -- Decision
    status                  hitl_status_enum DEFAULT 'pending',
    tenant_note             TEXT,
    decided_at              TIMESTAMPTZ,

    -- Pipeline
    pipeline_run_id         TEXT,
    generation_cost_usd     NUMERIC(8,6),
    is_active               BOOLEAN DEFAULT FALSE,
    created_at              TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(tenant_id, published_version_id, version_number)
);

CREATE INDEX idx_ttv_tenant       ON tenant_tour_versions(tenant_id);
CREATE INDEX idx_ttv_active       ON tenant_tour_versions(tenant_id, is_active)
    WHERE is_active = TRUE;
CREATE INDEX idx_ttv_status       ON tenant_tour_versions(status)
    WHERE status = 'pending';

-- ============================================================
-- TRACKING
-- ============================================================

CREATE TABLE pipeline_runs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    execution_id    TEXT UNIQUE,
    source_id       UUID REFERENCES raw_sources(id),
    tenant_id       UUID REFERENCES tenants(id),  -- NULL = AA internal run

    total_tours     INT DEFAULT 0,
    processed       INT DEFAULT 0,
    succeeded       INT DEFAULT 0,
    failed          INT DEFAULT 0,
    hitl_pending    INT DEFAULT 0,

    started_at      TIMESTAMPTZ DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,
    status          pipeline_status_enum DEFAULT 'processing',
    total_cost_usd  NUMERIC(10,6),
    error_message   TEXT
);

CREATE TABLE tenant_api_logs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID REFERENCES tenants(id),
    endpoint        TEXT,
    tours_fetched   INT,
    called_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_api_logs_tenant  ON tenant_api_logs(tenant_id, called_at DESC);

