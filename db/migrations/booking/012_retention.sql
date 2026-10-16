-- Migration bk-012: AA-825 — retention support for booking.job and booking.inbox_events (data standards DM-6.6, DM-7).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra db/migrations/booking/012_retention.sql and
-- is applied to Dev by the DB Migrate workflow (check, then apply), as aa_cis_admin. Never run it from a laptop.
--
-- Depends on bk-002 (booking.job, inbox_events.status) only.
--
-- Why: two owner-run TTL job kinds (backend/app/retention/) need them (S238 scope addition to AA-825, retention table of
-- docs/architecture/data-standards/02-data-management.md §7, windows approved in E3):
--   * bk_retention_job deletes finished jobs past their window (succeeded 30 days; failed / cancelled 90 days, archived
--     to S3 first). It walks booking.job in keyset order on (finished_at, id): job_finished_idx is that index, the same
--     name and shape as CIS shared.job (CIS migration 233) and the "finished_at index" of ADR 0003a decision 6 (X6).
--   * bk_retention_inbox_redact removes the personal data from booking.inbox_events.payload 90 days after receipt
--     (DM-6.6). The row, its idempotency_key and contract_version stay, so the pull's anti-join dedupe keeps working.
--     redacted_at records that a row was redacted (NULL = payload as received). inbox_events_redact_due_idx keeps the
--     scan for rows still to redact small once the old rows are done.
--
-- Role booking already has UPDATE on inbox_events and DELETE on job (bk-001 / bk-002 grants); no grant change, and no
-- blanket ON ALL TABLES grant (it would re-open UPDATE / DELETE on the append-only tables of bk-004 / bk-007).
-- Re-running the whole file is a no-op (IF NOT EXISTS, COMMENT, ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';

ALTER TABLE booking.inbox_events
    ADD COLUMN IF NOT EXISTS redacted_at TIMESTAMPTZ;

COMMENT ON COLUMN booking.inbox_events.redacted_at IS
    'bk-012 (AA-825, DM-6.6): when bk_retention_inbox_redact removed the personal data from payload (customer name, email, phone, custom day notes) and from a failed row''s error; NULL = payload as received.';
COMMENT ON COLUMN booking.inbox_events.payload IS
    'pii:contact; also pii:name and pii:free_text (inquiry.submitted customer.name / email / phone, itinerary.custom_days[].note). Redacted 90 days after received_at by bk_retention_inbox_redact (DM-6.6); the master record is booking.customers.';

CREATE INDEX IF NOT EXISTS inbox_events_redact_due_idx
    ON booking.inbox_events (received_at, id) WHERE redacted_at IS NULL;

CREATE INDEX IF NOT EXISTS job_finished_idx
    ON booking.job (finished_at, id) WHERE finished_at IS NOT NULL;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-012', now(), 'AA-825: retention support — booking.inbox_events.redacted_at + payload pii tag + inbox_events_redact_due_idx (DM-6.6), booking.job job_finished_idx (finished_at, id) for bk_retention_job (DM-7)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
