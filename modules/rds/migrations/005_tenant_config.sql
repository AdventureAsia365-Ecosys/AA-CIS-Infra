-- ============================================================
-- Migration 005: Tenant Config Tables
-- PRD v4: tenant_brand_rules, tenant_seo_config, tenant_export_config
-- Applied: 20/04/2026
-- ============================================================

BEGIN;

-- ── tenant_brand_rules ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.tenant_brand_rules (
    id              SERIAL PRIMARY KEY,
    tenant_id       TEXT NOT NULL REFERENCES shared.tenants(tenant_id),
    system_prompt   TEXT,
    style_guide     TEXT,
    forbidden_words JSONB DEFAULT '[]',
    custom_validators JSONB DEFAULT '[]',
    version         INT DEFAULT 1,
    is_active       BOOLEAN DEFAULT TRUE,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS tenant_brand_rules_active_idx
  ON shared.tenant_brand_rules (tenant_id)
  WHERE is_active = TRUE;

-- ── tenant_seo_config ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.tenant_seo_config (
    id              SERIAL PRIMARY KEY,
    tenant_id       TEXT NOT NULL REFERENCES shared.tenants(tenant_id),
    seo_provider    TEXT DEFAULT 'dataforseo'
                    CHECK (seo_provider IN ('dataforseo', 'custom', 'disabled')),
    custom_keywords JSONB DEFAULT '[]',
    target_market   JSONB DEFAULT '{}',
    overrides       JSONB DEFAULT '{}',
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS tenant_seo_config_unique_idx
  ON shared.tenant_seo_config (tenant_id);

-- ── tenant_export_config ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.tenant_export_config (
    id              SERIAL PRIMARY KEY,
    tenant_id       TEXT NOT NULL REFERENCES shared.tenants(tenant_id),
    webhook_url     TEXT,
    export_format   TEXT DEFAULT 'json'
                    CHECK (export_format IN ('json', 'csv', 'xml')),
    field_mapping   JSONB DEFAULT '{}',
    auth_header     TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS tenant_export_config_unique_idx
  ON shared.tenant_export_config (tenant_id);

-- ── Grant app_user access ─────────────────────────────────────
GRANT SELECT, INSERT, UPDATE ON shared.tenant_brand_rules TO app_user;
GRANT SELECT, INSERT, UPDATE ON shared.tenant_seo_config TO app_user;
GRANT SELECT, INSERT, UPDATE ON shared.tenant_export_config TO app_user;
GRANT USAGE ON SEQUENCE shared.tenant_brand_rules_id_seq TO app_user;
GRANT USAGE ON SEQUENCE shared.tenant_seo_config_id_seq TO app_user;
GRANT USAGE ON SEQUENCE shared.tenant_export_config_id_seq TO app_user;

-- ── Seed default config for aa_internal ──────────────────────
INSERT INTO shared.tenant_brand_rules
    (tenant_id, system_prompt, style_guide, forbidden_words, is_active)
VALUES (
    'aa_internal',
    'You are an expert travel content writer for Adventure Asia. Write in an engaging, active voice that inspires travellers.',
    'Use title case for tour names. Subtitles must be descriptive clauses, not city lists. Summaries 80-150 words.',
    '["guaranteed", "best in class", "world-class", "unparalleled", "once in a lifetime"]',
    TRUE
) ON CONFLICT DO NOTHING;

INSERT INTO shared.tenant_seo_config
    (tenant_id, seo_provider, target_market)
VALUES (
    'aa_internal',
    'dataforseo',
    '{"primary": "en_US", "secondary": ["en_AU", "en_UK"]}'
) ON CONFLICT DO NOTHING;

INSERT INTO shared.tenant_export_config
    (tenant_id, export_format)
VALUES (
    'aa_internal',
    'json'
) ON CONFLICT DO NOTHING;

-- Seed for test B2B tenant
INSERT INTO shared.tenant_brand_rules
    (tenant_id, system_prompt, style_guide, forbidden_words, is_active)
VALUES (
    'wl_tenant_b2b_test',
    'Write professional tour content for WorldLux travel brand.',
    'Use formal tone. Highlight luxury aspects. Avoid casual language.',
    '["cheap", "budget", "affordable", "basic"]',
    TRUE
) ON CONFLICT DO NOTHING;

INSERT INTO shared.tenant_seo_config
    (tenant_id, seo_provider, target_market)
VALUES (
    'wl_tenant_b2b_test',
    'custom',
    '{"primary": "en_UK"}'
) ON CONFLICT DO NOTHING;

COMMIT;
