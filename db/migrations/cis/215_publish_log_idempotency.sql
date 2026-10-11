-- Migration 215: AA-726 — idempotent T11 publish.
--
-- Before this, a publish whose remote call succeeded but whose response was lost (timeout after
-- WordPress returned 201) was recorded as 'failed', and the retry created a SECOND post on the
-- tenant's site. Two concurrent clicks did the same.
--
-- - idempotency_key: "<piece_id>:<channel>:<sha256(content_text)[:16]>" — one key per piece
--   revision and channel. Editing the text gives a new key (a deliberate re-publish).
-- - status 'requested': written BEFORE the remote API is called; requested_at is when.
-- - A partial unique index allows at most one in-flight or published row per key, so two
--   concurrent publishes of the same revision cannot both reach the remote API.
-- - The remote post id keeps using the existing external_id column.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (applied by the
-- db-migrate workflow); this copy keeps the numbering and lets the integration tests build the
-- schema. Keep the two identical.

BEGIN;

ALTER TABLE acp_shared.publish_log ADD COLUMN IF NOT EXISTS idempotency_key TEXT;
ALTER TABLE acp_shared.publish_log ADD COLUMN IF NOT EXISTS requested_at TIMESTAMPTZ;

-- Replace the status CHECK from migration 116 (auto-named) to allow 'requested'.
DO $$
DECLARE c record;
BEGIN
    FOR c IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'acp_shared.publish_log'::regclass AND contype = 'c'
          AND pg_get_constraintdef(oid) LIKE '%status%'
    LOOP
        EXECUTE format('ALTER TABLE acp_shared.publish_log DROP CONSTRAINT %I', c.conname);
    END LOOP;
END $$;

ALTER TABLE acp_shared.publish_log ADD CONSTRAINT publish_log_status_check
    CHECK (status IN ('requested', 'published', 'unpublished', 'failed'));

CREATE UNIQUE INDEX IF NOT EXISTS uq_publish_log_active_key
    ON acp_shared.publish_log(idempotency_key)
    WHERE idempotency_key IS NOT NULL AND status IN ('requested', 'published');

COMMENT ON COLUMN acp_shared.publish_log.idempotency_key IS
    'AA-726 — <piece_id>:<channel>:<sha256(content_text)[:16]>; unique while requested/published';
COMMENT ON COLUMN acp_shared.publish_log.requested_at IS
    'AA-726 — when the remote publish call was started (status requested)';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('215', now(),
    'AA-726: publish_log idempotency_key + requested status + unique in-flight/published key')
ON CONFLICT (version) DO NOTHING;

COMMIT;
