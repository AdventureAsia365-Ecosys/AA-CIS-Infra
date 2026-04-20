-- ============================================================
-- Migration 006: Export Service + Webhook tables
-- PRD v4 S5: Gold RDS write + S3 Gold + Webhook Delivery
-- Applied: 20/04/2026
-- ============================================================

BEGIN;

-- ── gold_aa_internal.content_exports ─────────────────────────
CREATE TABLE IF NOT EXISTS gold_aa_internal.content_exports (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT NOT NULL REFERENCES shared.tenants(tenant_id),
    export_id       UUID NOT NULL DEFAULT gen_random_uuid(),
    format          TEXT NOT NULL DEFAULT 'json'
                    CHECK (format IN ('json', 'csv', 'xml')),
    filter_params   JSONB DEFAULT '{}',
    s3_path         TEXT,
    total_tours     INT DEFAULT 0,
    file_size_kb    INT DEFAULT 0,
    status          TEXT DEFAULT 'pending'
                    CHECK (status IN ('pending', 'processing', 'complete', 'failed')),
    expires_at      TIMESTAMPTZ DEFAULT NOW() + INTERVAL '7 days',
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS content_exports_tenant_idx
  ON gold_aa_internal.content_exports (tenant_id, created_at DESC);

-- ── gold_aa_internal.webhook_deliveries ──────────────────────
CREATE TABLE IF NOT EXISTS gold_aa_internal.webhook_deliveries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT NOT NULL REFERENCES shared.tenants(tenant_id),
    tour_id         UUID NOT NULL REFERENCES gold_aa_internal.published_tours(tour_id),
    webhook_url     TEXT NOT NULL,
    payload_s3_path TEXT,
    hmac_signature  TEXT,
    http_status     INT,
    attempt_count   INT DEFAULT 0,
    max_attempts    INT DEFAULT 3,
    status          TEXT DEFAULT 'pending'
                    CHECK (status IN ('pending', 'delivered', 'failed', 'retrying')),
    delivered_at    TIMESTAMPTZ,
    next_retry_at   TIMESTAMPTZ,
    error_msg       TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS webhook_deliveries_tenant_idx
  ON gold_aa_internal.webhook_deliveries (tenant_id, status);

CREATE INDEX IF NOT EXISTS webhook_deliveries_retry_idx
  ON gold_aa_internal.webhook_deliveries (next_retry_at)
  WHERE status = 'retrying';

-- ── RLS on new tables ─────────────────────────────────────────
ALTER TABLE gold_aa_internal.content_exports    ENABLE ROW LEVEL SECURITY;
ALTER TABLE gold_aa_internal.webhook_deliveries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation ON gold_aa_internal.content_exports;
CREATE POLICY tenant_isolation ON gold_aa_internal.content_exports
  USING (tenant_id = current_setting('app.tenant_id', true));

DROP POLICY IF EXISTS tenant_isolation ON gold_aa_internal.webhook_deliveries;
CREATE POLICY tenant_isolation ON gold_aa_internal.webhook_deliveries
  USING (tenant_id = current_setting('app.tenant_id', true));

-- ── Grant app_user ────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE ON gold_aa_internal.content_exports    TO app_user;
GRANT SELECT, INSERT, UPDATE ON gold_aa_internal.webhook_deliveries TO app_user;
GRANT USAGE ON SEQUENCE gold_aa_internal.content_exports_id_seq    TO app_user 2>/dev/null;

COMMIT;
