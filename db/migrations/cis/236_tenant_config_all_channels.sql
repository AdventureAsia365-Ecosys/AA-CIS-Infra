-- Migration 236: AA-840 — acp_shared.tenant_config.channels accepts all 8 Slate Channels.
--
-- Migration 101 (AA-323) allowed only blog/facebook/tiktok/email. AA-449 widened the app side to
-- 8 Channels (api/routers/admin.py _VALID_CHANNELS, services/acp_planning/models.py Channel,
-- services/acp_shared/slate.py CHANNEL_BARS), but this CHECK was never widened: saving linkedin,
-- instagram, landing_page or ads from the admin Tenant 360 Planning config form passed the API
-- validation and then failed in the database.
--
-- Since AA-840 the T7 Slate proposes only for the Channels in this column (no row = every
-- Channel), so the column must be able to hold every Channel the Slate knows.
--
-- Widening only: every existing row (one on Dev, channels = {blog}) still satisfies it.
-- Applied on Dev via the AA-CIS-Infra "DB Migrate" workflow (identical copy in
-- db/migrations/cis/). The app code does not need it to run; without it, an admin save that
-- includes one of the 4 new Channels keeps failing as it does today.

BEGIN;

ALTER TABLE acp_shared.tenant_config DROP CONSTRAINT IF EXISTS tenant_config_channels_valid;
ALTER TABLE acp_shared.tenant_config ADD CONSTRAINT tenant_config_channels_valid CHECK (
    channels <@ ARRAY['blog', 'linkedin', 'facebook', 'instagram', 'tiktok', 'email',
                      'landing_page', 'ads']::text[]
);

ALTER TABLE acp_shared.tenant_config ALTER COLUMN channels
    SET DEFAULT ARRAY['blog', 'linkedin', 'facebook', 'instagram', 'tiktok', 'email',
                      'landing_page', 'ads']::text[];

COMMENT ON COLUMN acp_shared.tenant_config.channels IS
    'AA-840 — the Channels the T7 Slate proposes for this tenant (no row = every Channel). '
    'Set from admin Tenant 360 > Planning config.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('236', now(), 'AA-840: tenant_config.channels CHECK widened to the 8 Slate Channels '
        '(was blog/facebook/tiktok/email since 101); the Slate now reads this column')
ON CONFLICT (version) DO NOTHING;

COMMIT;
