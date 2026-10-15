-- Migration 230: AA-819 — shared.tenants.daily_publish_limit, the per-tenant override of the daily
-- publish limit (AUP 2026-11).
--
-- Anthropic's usage policy (effective 12/11/2026 on Bedrock acc3) forbids spam and coordinated
-- inauthentic activity. T11 publishing (POST /v1/publish-log/{piece_id}/publish) gets a per-tenant
-- daily ceiling, enforced in code (services/acp_publish/daily_limit.py):
--   - code default 20 publishes per UTC day (DEFAULT_DAILY_PUBLISH_LIMIT), live as soon as the code
--     deploys, with or without this column;
--   - this column is the admin override: NULL = the code default, an integer = that tenant's own
--     limit. Set through PATCH /admin/tenants/{id} {"daily_publish_limit": n | null} (audited as
--     tenant.daily_publish_limit_changed), shown in the Tenant 360 Settings tab.
--
-- Nullable with no column default on purpose (S237 decision D3): the default lives in code, so
-- changing it never needs a migration, and the column can be applied after the code deploys (the
-- code probes pg_attribute and falls back to the default while the column is missing).
-- Positive only: blocking a tenant is suspend (is_active), never a limit of 0. The upper bound (1000,
-- a typo guard) is enforced by the API, not here.
--
-- Idempotent (ADD COLUMN IF NOT EXISTS, constraint dropped and re-added). No backfill: every
-- existing tenant keeps NULL = the default.
--
-- Rollback (the code keeps working, every tenant falls back to the default):
--   ALTER TABLE shared.tenants DROP COLUMN IF EXISTS daily_publish_limit;
--   DELETE FROM shared.schema_versions WHERE version = '230';

BEGIN;

ALTER TABLE shared.tenants ADD COLUMN IF NOT EXISTS daily_publish_limit INTEGER;

ALTER TABLE shared.tenants DROP CONSTRAINT IF EXISTS tenants_daily_publish_limit_positive;
ALTER TABLE shared.tenants
    ADD CONSTRAINT tenants_daily_publish_limit_positive
    CHECK (daily_publish_limit IS NULL OR daily_publish_limit >= 1);

COMMENT ON COLUMN shared.tenants.daily_publish_limit IS
    'AA-819: per-tenant override of the daily publish limit (publishes per UTC day). '
    'NULL = the code default (services/acp_publish/daily_limit.py, 20).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('230', now(), 'AA-819: shared.tenants.daily_publish_limit — nullable per-tenant override of the '
        'daily publish limit (NULL = code default 20/UTC day)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
