-- Migration 464: AA-1168 follow-up (S286 settings-rule audit) — the social post text an attempt sent, on its publish row.
--
-- Why. A Facebook post has no client idempotency key: when an attempt's response is lost, the retry (AA-726) finds the
-- post an earlier attempt created by its exact message in the Page feed. The message ends with the AI disclosure line,
-- which becomes an admin-editable setting (CIS 463). Rebuilt on the retry, the message would carry the wording in force
-- at the retry; after a wording change between the attempt and the retry the lookup would miss the earlier post and the
-- retry would post a duplicate. The attempt therefore stores the text it is about to send, and the retry looks for that.
--
-- What:
--   1. ALTER TABLE acp_shared.publish_log ADD COLUMN sent_message text: the exact post text the attempt sent (social
--      channels; written before the remote call by idempotency.claim, replaced by idempotency.record_sent_message when a
--      retry finds no earlier post and posts again). NULL for blog rows (WordPress finds a post by its revision slug) and for rows older than this
--      file (the retry then rebuilds the message as before).
--   2. Register 464.
--
-- PII (DM-6.1). Tenant marketing text, the same class as acp_shared.content_piece.content_text it is built from (the
-- piece text plus the disclosure line); no traveller field. Deleted with the tenant through the existing
-- acp_shared.publish_log entry of the erasure inventory (services/erasure/inventory.py).
--
-- Retention (DM-7.1). The table keeps its rule (no new table, no window change).
--
-- Behaviour on apply. None for running code: the column is NULL on every row and nothing reads it until the code PR.
-- ADD COLUMN with no default is a catalog-only change (no table rewrite). RLS on: the existing policies (cis_app ALL,
-- tenant isolation by tenant_id for aa_app_user) and the table grants cover the new column.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): it ALTERs an existing table. MIG-4: a
-- migration-only PR with 463 (one batch, cis 463-464), applied on Dev by Infra Migration Apply when every job table is
-- idle (ADR 0017a), then the code PR.
--
-- Number. Follows 463 (same PR). If the owner main max + 1 differs at merge, renumber both (see 463's header).
--
-- Locks. ALTER TABLE takes an ACCESS EXCLUSIVE lock for a catalog-only change (a few dozen rows); lock_timeout 5s, so a
-- busy table fails the apply instead of queueing publishes behind it. Re-runnable (IF NOT EXISTS).
--
-- Rollback (a new forward migration, after the code PR is reverted): ALTER TABLE ... DROP COLUMN sent_message (a
-- destructive file, DRY RUN).

BEGIN;
SET LOCAL lock_timeout = '5s';

ALTER TABLE acp_shared.publish_log
    ADD COLUMN IF NOT EXISTS sent_message text;

COMMENT ON COLUMN acp_shared.publish_log.sent_message IS
    'AA-1168 (CIS 464): the exact social post text this attempt sent (the piece text and the AI disclosure line in force '
    'then); the publish retry finds an earlier post by it. NULL for blog rows and rows older than 464.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('464', now(), 'AA-1168: publish_log.sent_message (the social post text an attempt sent, for the retry lookup)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
