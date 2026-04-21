-- =============================================================================
-- Migration 007: Seed 2 Test Tenants for S7 RLS Verification
-- Project: AA-CIS (Adventure Asia Content Intelligence System)
-- Sprint: S7 — W15-16
-- Author: Pham Quoc Nghiep
-- Date: 2026-04-20
-- =============================================================================
-- Purpose:
--   1. Insert 2 test tenants into shared.tenants
--   2. Seed tenant_brand_rules, tenant_seo_config, tenant_export_config per tenant
--   3. Verify RLS isolation: tenant A cannot see tenant B's data
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- SECTION 1: Insert 2 Test Tenants
-- ---------------------------------------------------------------------------
-- Tenant A: "WanderLux Travel" — Growth plan
-- Tenant B: "ExploreAsia Co." — Starter plan
-- api_key_hash = SHA256 of the raw key (raw keys stored only in Secrets Manager)
-- Raw keys (for testing only, rotate before prod):
--   Tenant A: wl_live_sk_test_wanderlux_2026
--   Tenant B: ea_live_sk_test_exploreasia_2026
-- ---------------------------------------------------------------------------

INSERT INTO shared.tenants (
    tenant_id,
    name,
    plan_tier,
    api_key_hash,
    rate_limit_rpm,
    is_active,
    created_at
) VALUES
(
    'a1b2c3d4-0001-4000-8000-000000000001'::uuid,
    'WanderLux Travel',
    'growth',
    encode(sha256('wl_live_sk_test_wanderlux_2026'::bytea), 'hex'),
    300,
    true,
    NOW()
),
(
    'a1b2c3d4-0002-4000-8000-000000000002'::uuid,
    'ExploreAsia Co.',
    'starter',
    encode(sha256('ea_live_sk_test_exploreasia_2026'::bytea), 'hex'),
    60,
    true,
    NOW()
)
ON CONFLICT (tenant_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- SECTION 2: Tenant Brand Rules
-- ---------------------------------------------------------------------------

INSERT INTO shared.tenant_brand_rules (
    tenant_id,
    system_prompt,
    style_guide,
    forbidden_words,
    custom_validators,
    version,
    is_active,
    updated_at
) VALUES
(
    'a1b2c3d4-0001-4000-8000-000000000001'::uuid,
    'You are a luxury travel copywriter for WanderLux Travel. Write content that evokes exclusivity, sophistication, and transformative experiences. Target affluent travellers aged 35-55.',
    'Tone: aspirational, refined, sensory-rich. Avoid superlatives like "best" or "amazing". Use specific place names and cultural details.',
    '["cheap","budget","backpacker","hostel","basic","crowded","tourist trap"]'::jsonb,
    '{"min_word_count": 150, "require_cultural_context": true}'::jsonb,
    1,
    true,
    NOW()
),
(
    'a1b2c3d4-0002-4000-8000-000000000002'::uuid,
    'You are an adventure travel writer for ExploreAsia Co. Write content that is energetic, accessible, and practical. Target independent travellers aged 25-40 on a mid-range budget.',
    'Tone: upbeat, informative, conversational. Include practical tips (transport, gear, timing). Use active verbs.',
    '["luxury","exclusive","opulent","bespoke","curated"]'::jsonb,
    '{"min_word_count": 100, "require_practical_tips": true}'::jsonb,
    1,
    true,
    NOW()
)
ON CONFLICT (tenant_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- SECTION 3: Tenant SEO Config
-- ---------------------------------------------------------------------------

INSERT INTO shared.tenant_seo_config (
    tenant_id,
    seo_provider,
    custom_keywords,
    target_market,
    overrides,
    updated_at
) VALUES
(
    'a1b2c3d4-0001-4000-8000-000000000001'::uuid,
    'dataforseo',
    '{"primary": ["luxury vietnam tours", "private vietnam experience", "high-end asia travel"], "secondary": ["boutique hotel vietnam", "private guided tours asia"]}'::jsonb,
    '{"countries": ["US", "UK", "AU"], "languages": ["en"], "currency": "USD"}'::jsonb,
    '{"max_keyword_density": 1.5, "seo_score_threshold": 75}'::jsonb,
    NOW()
),
(
    'a1b2c3d4-0002-4000-8000-000000000002'::uuid,
    'dataforseo',
    '{"primary": ["vietnam backpacking", "budget asia travel", "adventure tours vietnam"], "secondary": ["cheap vietnam travel", "affordable asia tours"]}'::jsonb,
    '{"countries": ["DE", "FR", "NL", "AU"], "languages": ["en"], "currency": "EUR"}'::jsonb,
    '{"max_keyword_density": 2.0, "seo_score_threshold": 65}'::jsonb,
    NOW()
)
ON CONFLICT (tenant_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- SECTION 4: Tenant Export Config
-- ---------------------------------------------------------------------------

INSERT INTO shared.tenant_export_config (
    tenant_id,
    webhook_url,
    export_format,
    field_mapping,
    auth_header,
    created_at
) VALUES
(
    'a1b2c3d4-0001-4000-8000-000000000001'::uuid,
    'https://webhook.wanderlux-test.invalid/cis/tours',
    'json',
    '{"aa_name": "title", "aa_subtitle": "tagline", "aa_summary": "description", "seo_title": "meta_title", "seo_meta": "meta_description"}'::jsonb,
    'Bearer wl_webhook_secret_test_2026',
    NOW()
),
(
    'a1b2c3d4-0002-4000-8000-000000000002'::uuid,
    'https://webhook.exploreasia-test.invalid/api/content',
    'csv',
    '{"aa_name": "tour_name", "aa_summary": "tour_description", "aa_highlights": "highlights_json"}'::jsonb,
    'X-API-Key: ea_webhook_secret_test_2026',
    NOW()
)
ON CONFLICT (tenant_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- SECTION 5: Create Silver schemas per test tenant (if not exists)
-- ---------------------------------------------------------------------------
-- These schemas hold Silver layer tables for each tenant.
-- In production, created by TenantConfigService.create_tenant().
-- For S7 testing, we create them manually.
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    -- Silver schema for Tenant A
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'silver_a1b2c3d4_0001') THEN
        CREATE SCHEMA silver_a1b2c3d4_0001;
        COMMENT ON SCHEMA silver_a1b2c3d4_0001 IS 'Silver layer — WanderLux Travel (test tenant A)';
    END IF;

    -- Silver schema for Tenant B
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'silver_a1b2c3d4_0002') THEN
        CREATE SCHEMA silver_a1b2c3d4_0002;
        COMMENT ON SCHEMA silver_a1b2c3d4_0002 IS 'Silver layer — ExploreAsia Co. (test tenant B)';
    END IF;

    -- Gold schema for Tenant A
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'gold_a1b2c3d4_0001') THEN
        CREATE SCHEMA gold_a1b2c3d4_0001;
        COMMENT ON SCHEMA gold_a1b2c3d4_0001 IS 'Gold layer — WanderLux Travel (test tenant A)';
    END IF;

    -- Gold schema for Tenant B
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'gold_a1b2c3d4_0002') THEN
        CREATE SCHEMA gold_a1b2c3d4_0002;
        COMMENT ON SCHEMA gold_a1b2c3d4_0002 IS 'Gold layer — ExploreAsia Co. (test tenant B)';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- SECTION 6: Seed pipeline_runs for RLS isolation testing
-- Insert 1 pipeline_run per tenant — verify tenant B cannot see tenant A's run
-- ---------------------------------------------------------------------------

INSERT INTO shared.pipeline_runs (
    tenant_id,
    batch_id,
    status,
    tours_total,
    tours_passed,
    tours_hitl,
    tours_failed,
    cost_usd,
    tokens_input,
    tokens_output,
    started_at
) VALUES
(
    'a1b2c3d4-0001-4000-8000-000000000001'::uuid,
    'batch_wanderlux_test_001',
    'completed',
    5, 4, 1, 0,
    0.42,
    12500, 8200,
    NOW() - INTERVAL '2 hours'
),
(
    'a1b2c3d4-0002-4000-8000-000000000002'::uuid,
    'batch_exploreasia_test_001',
    'completed',
    3, 3, 0, 0,
    0.18,
    7200, 4800,
    NOW() - INTERVAL '1 hour'
)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- SECTION 7: Verify — Count inserted records
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    v_tenant_count INT;
    v_brand_count INT;
    v_seo_count INT;
    v_export_count INT;
    v_run_count INT;
BEGIN
    SELECT COUNT(*) INTO v_tenant_count FROM shared.tenants
        WHERE tenant_id IN (
            'a1b2c3d4-0001-4000-8000-000000000001'::uuid,
            'a1b2c3d4-0002-4000-8000-000000000002'::uuid
        );

    SELECT COUNT(*) INTO v_brand_count FROM shared.tenant_brand_rules
        WHERE tenant_id IN (
            'a1b2c3d4-0001-4000-8000-000000000001'::uuid,
            'a1b2c3d4-0002-4000-8000-000000000002'::uuid
        );

    SELECT COUNT(*) INTO v_seo_count FROM shared.tenant_seo_config
        WHERE tenant_id IN (
            'a1b2c3d4-0001-4000-8000-000000000001'::uuid,
            'a1b2c3d4-0002-4000-8000-000000000002'::uuid
        );

    SELECT COUNT(*) INTO v_export_count FROM shared.tenant_export_config
        WHERE tenant_id IN (
            'a1b2c3d4-0001-4000-8000-000000000001'::uuid,
            'a1b2c3d4-0002-4000-8000-000000000002'::uuid
        );

    SELECT COUNT(*) INTO v_run_count FROM shared.pipeline_runs
        WHERE tenant_id IN (
            'a1b2c3d4-0001-4000-8000-000000000001'::uuid,
            'a1b2c3d4-0002-4000-8000-000000000002'::uuid
        );

    RAISE NOTICE '=== Migration 007 Verification ===';
    RAISE NOTICE 'tenants:              % / 2 expected', v_tenant_count;
    RAISE NOTICE 'tenant_brand_rules:   % / 2 expected', v_brand_count;
    RAISE NOTICE 'tenant_seo_config:    % / 2 expected', v_seo_count;
    RAISE NOTICE 'tenant_export_config: % / 2 expected', v_export_count;
    RAISE NOTICE 'pipeline_runs:        % / 2 expected', v_run_count;

    IF v_tenant_count = 2 AND v_brand_count = 2 AND v_seo_count = 2
       AND v_export_count = 2 AND v_run_count = 2 THEN
        RAISE NOTICE '=== MIGRATION 007 PASSED ===';
    ELSE
        RAISE EXCEPTION 'Migration 007 FAILED — unexpected row counts';
    END IF;
END $$;

COMMIT;
