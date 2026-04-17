-- ============================================================
-- AA-CIS Database Schema v1.1
-- Migration: 001_initial_schema
-- Architecture: Medallion (Bronze → Silver → Gold → Ops)
-- Updated: 16/04/2026
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- SCHEMAS
-- ============================================================
CREATE SCHEMA IF NOT EXISTS bronze;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;
CREATE SCHEMA IF NOT EXISTS ops;

-- ============================================================
-- ENUMS
-- ============================================================
CREATE TYPE ops.pipeline_status_enum AS ENUM (
    'queued','processing','done','failed','skipped'
);
CREATE TYPE silver.audit_status_enum AS ENUM (
    'passed','flagged','failed'
);
CREATE TYPE silver.hitl_status_enum AS ENUM (
    'pending','approved','rejected','revision_requested'
);

-- ============================================================
-- BRONZE — Raw Data
-- ============================================================
CREATE TABLE bronze.raw_sources (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    s3_bucket         TEXT NOT NULL,
    s3_key            TEXT NOT NULL,
    supplier_name     TEXT,
    original_filename TEXT,
    uploaded_at       TIMESTAMPTZ DEFAULT NOW(),
    status            ops.pipeline_status_enum DEFAULT 'pending',
    row_count         INT,
    error_message     TEXT
);

CREATE TABLE bronze.raw_tours (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id               UUID REFERENCES bronze.raw_sources(id) ON DELETE SET NULL,
    tour_id_external        TEXT,
    sku                     TEXT,
    country                 TEXT,
    name                    TEXT NOT NULL,
    subtitle                TEXT,
    duration                TEXT,
    group_size              TEXT,
    period                  TEXT,
    summary                 TEXT,
    description             TEXT,
    highlights              TEXT,
    itineraries             TEXT,
    inclusions              TEXT,
    exclusions              TEXT,
    provider                TEXT,
    price_raw               TEXT,
    links                   TEXT,
    activities              TEXT,
    feature                 TEXT,
    best_time_to_go         TEXT,
    dfs_query               TEXT,
    dfs_keyword_search      TEXT,
    dfs_people_also_ask     TEXT,
    dfs_related_searches    TEXT,
    dfs_keyword_ideas       TEXT,
    dfs_keyword_suggestions TEXT,
    dfs_related_keywords    TEXT,
    dfs_competitor_angles   TEXT,
    source_file             TEXT,
    raw_data                JSONB,
    etl_at                  TIMESTAMPTZ DEFAULT NOW(),
    etl_version             TEXT,
    pipeline_status         ops.pipeline_status_enum DEFAULT 'queued'
);

CREATE INDEX idx_raw_tours_source  ON bronze.raw_tours(source_id);
CREATE INDEX idx_raw_tours_country ON bronze.raw_tours(country);
CREATE INDEX idx_raw_tours_status  ON bronze.raw_tours(pipeline_status);
CREATE INDEX idx_raw_tours_sku     ON bronze.raw_tours(sku);

-- ============================================================
-- SILVER — Processed + Validated
-- ============================================================
CREATE TABLE silver.published_tour_versions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    raw_tour_id         UUID NOT NULL REFERENCES bronze.raw_tours(id) ON DELETE CASCADE,
    version_number      INT NOT NULL DEFAULT 1,
    name                TEXT,
    subtitle            TEXT,
    summary             TEXT,
    highlights          TEXT[],
    itineraries         JSONB,
    seo_title           TEXT,
    seo_meta            TEXT,
    trip_type           TEXT,
    audit_status        silver.audit_status_enum,
    audit_failure_codes TEXT[],
    audit_issues        TEXT,
    fields_updated      TEXT[],
    quality_score       NUMERIC(3,1) CHECK (quality_score BETWEEN 0 AND 10),
    publish_ready       BOOLEAN DEFAULT FALSE,
    publish_notes       TEXT,
    hitl_status         silver.hitl_status_enum DEFAULT 'pending',
    hitl_note           TEXT,
    hitl_by             TEXT,
    hitl_at             TIMESTAMPTZ,
    pipeline_run_id     TEXT,
    llm_model           TEXT,
    prompt_version      TEXT,
    generation_cost_usd NUMERIC(8,6),
    is_active           BOOLEAN DEFAULT FALSE,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(raw_tour_id, version_number)
);

CREATE INDEX idx_ptv_raw_tour ON silver.published_tour_versions(raw_tour_id);
CREATE INDEX idx_ptv_active   ON silver.published_tour_versions(raw_tour_id, is_active) WHERE is_active = TRUE;
CREATE INDEX idx_ptv_hitl     ON silver.published_tour_versions(hitl_status) WHERE hitl_status = 'pending';

CREATE TABLE silver.seo_contexts (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    destination  TEXT NOT NULL,
    activity     TEXT,
    keywords     JSONB,
    demographics JSONB,
    fetched_at   TIMESTAMPTZ DEFAULT NOW(),
    expires_at   TIMESTAMPTZ,
    UNIQUE(destination, activity)
);

-- ============================================================
-- GOLD — Business-Ready
-- ============================================================

-- Source of truth để publish lên website adventure.asia (team nội bộ)
CREATE TABLE gold.published_catalog (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    published_version_id UUID NOT NULL REFERENCES silver.published_tour_versions(id),
    raw_tour_id          UUID NOT NULL REFERENCES bronze.raw_tours(id),
    name                 TEXT NOT NULL,
    subtitle             TEXT,
    country              TEXT,
    trip_type            TEXT,
    duration             TEXT,
    seo_title            TEXT,
    seo_meta             TEXT,
    quality_score        NUMERIC(3,1),
    status               TEXT DEFAULT 'draft', -- draft/published/unpublished/archived
    published_at         TIMESTAMPTZ,
    unpublished_at       TIMESTAMPTZ,
    published_by         TEXT,
    slug                 TEXT UNIQUE,
    external_id          TEXT,
    created_at           TIMESTAMPTZ DEFAULT NOW(),
    updated_at           TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_catalog_status  ON gold.published_catalog(status);
CREATE INDEX idx_catalog_country ON gold.published_catalog(country);
CREATE INDEX idx_catalog_slug    ON gold.published_catalog(slug);

-- B2B Tenants
CREATE TABLE gold.tenants (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name         TEXT NOT NULL,
    slug         TEXT UNIQUE NOT NULL,
    api_key_hash TEXT NOT NULL,
    plan         TEXT DEFAULT 'basic',
    is_active    BOOLEAN DEFAULT TRUE,
    created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE gold.tenant_configs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID UNIQUE REFERENCES gold.tenants(id) ON DELETE CASCADE,
    seo_provider    TEXT DEFAULT 'dataforseo',
    seo_overrides   JSONB,
    brand_voice     TEXT,
    forbidden_words TEXT[],
    custom_rules    JSONB,
    prompt_override TEXT,
    output_format   TEXT DEFAULT 'json',
    webhook_url     TEXT,
    config_guide    TEXT,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE gold.tenant_tour_versions (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID NOT NULL REFERENCES gold.tenants(id) ON DELETE CASCADE,
    published_version_id UUID NOT NULL REFERENCES silver.published_tour_versions(id),
    version_number       INT NOT NULL DEFAULT 1,
    name                 TEXT,
    subtitle             TEXT,
    summary              TEXT,
    highlights           TEXT[],
    itineraries          JSONB,
    seo_title            TEXT,
    seo_meta             TEXT,
    config_snapshot      JSONB,
    status               silver.hitl_status_enum DEFAULT 'pending',
    tenant_note          TEXT,
    decided_at           TIMESTAMPTZ,
    pipeline_run_id      TEXT,
    generation_cost_usd  NUMERIC(8,6),
    is_active            BOOLEAN DEFAULT FALSE,
    created_at           TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(tenant_id, published_version_id, version_number)
);

CREATE INDEX idx_ttv_tenant ON gold.tenant_tour_versions(tenant_id);
CREATE INDEX idx_ttv_active ON gold.tenant_tour_versions(tenant_id, is_active) WHERE is_active = TRUE;
CREATE INDEX idx_ttv_status ON gold.tenant_tour_versions(status) WHERE status = 'pending';

-- ============================================================
-- OPS — Operational Tracking
-- ============================================================
CREATE TABLE ops.pipeline_runs (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    execution_id   TEXT UNIQUE,
    source_id      UUID REFERENCES bronze.raw_sources(id),
    tenant_id      UUID REFERENCES gold.tenants(id),
    total_tours    INT DEFAULT 0,
    processed      INT DEFAULT 0,
    succeeded      INT DEFAULT 0,
    failed         INT DEFAULT 0,
    hitl_pending   INT DEFAULT 0,
    started_at     TIMESTAMPTZ DEFAULT NOW(),
    completed_at   TIMESTAMPTZ,
    status         ops.pipeline_status_enum DEFAULT 'processing',
    total_cost_usd NUMERIC(10,6),
    error_message  TEXT
);

CREATE TABLE ops.tenant_api_logs (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     UUID REFERENCES gold.tenants(id),
    endpoint      TEXT,
    tours_fetched INT,
    called_at     TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_api_logs_tenant ON ops.tenant_api_logs(tenant_id, called_at DESC);

-- ============================================================
-- SUMMARY: 10 tables / 4 schemas
-- BRONZE: raw_sources, raw_tours
-- SILVER: published_tour_versions, seo_contexts
-- GOLD:   published_catalog, tenants, tenant_configs, tenant_tour_versions
-- OPS:    pipeline_runs, tenant_api_logs
-- ============================================================
