-- migrate: expand
-- Migration crm-028: AA-952 CRM-23 slice 4 (design v3 §3.5 "Deposit link (C31, Fix A3, Fix A8)", §3.3 group F
-- `invoice.claimed_at`, `hold_extended_at`; card R "pay link after hold expiry -> expired page, no session", card E
-- "transfer marked received after the extended expiry -> re-hold, or a refund request if that fails") — the facts the
-- bank-transfer claim, its one Booking hold extension, the re-hold after a late payment and the overdue reminders
-- keep on an invoice.
--
-- Owner: AA-Partner (api/migrations/028_crm_invoice_claims.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-028.
--
-- What: nine nullable (or defaulted) columns on crm.invoice, nothing else. No personal data (times, Booking ids and
-- codes, counts); they leave with their invoice (crm.erase_subject deletes invoice rows, unchanged).
--   - claimed_at: the client's "I have paid" (status open -> payment_claimed; the claim text never: no free text).
--   - hold_extended_at / hold_extend_code: the one POST /holds/{id}/extend the claim asks Booking for (extended, or
--     Booking's refusal code: extend_limit, hold_expired, invalid, not_found; booking_unavailable is retried by the
--     Booking sync). Booking allows one extension per hold; the CRM asks once per invoice.
--   - rehold_requested_at / rehold_quote_id / rehold_price_hash / rehold_code: money that settles a deposit invoice
--     after its AA hold ran out waits for the Booking sync to hold the accepted AA items again (the quote it holds is
--     written down before POST /holds, so a lost answer is replayed with the same quote and Idempotency-Key); the
--     outcome (reheld, hold_live, or why not) ends it as paid, or paid_unfulfillable with a refund request.
--   - last_reminded_at / reminder_count: the overdue reminders to the agent (agent first, design U8 / E3).
--   The value lists are enforced by the API (app.payments.claims, app.booking.rehold, app.payments.reminders); a later
--   contract key may add CHECKs once the codes settle.
--
-- Class: expand (root ADR 0017 d3): ADD COLUMN only (nullable, or NOT NULL with a constant default), comments on the
-- new columns, the registration. crm.invoice is not a hot table (Infra owners.yaml expand_hot_tables). The code that
-- writes the columns ships in the same PR and raises the readiness requirement to crm-028 (app/db.py). The sealed
-- trigger (crm.guard_sealed_row) names its sealed columns, so the new ones stay writable on an issued invoice.
--
-- Order: after crm-027. Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL, no DO block.
-- Idempotent (ADD COLUMN IF NOT EXISTS, ON CONFLICT DO NOTHING). Rollback: a forward crm- file dropping the columns
-- after the code that reads them is reverted (MIG-14); the code before this key never reads them.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

ALTER TABLE crm.invoice
    ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS hold_extended_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS hold_extend_code TEXT,
    ADD COLUMN IF NOT EXISTS rehold_requested_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS rehold_quote_id TEXT,
    ADD COLUMN IF NOT EXISTS rehold_price_hash TEXT,
    ADD COLUMN IF NOT EXISTS rehold_code TEXT,
    ADD COLUMN IF NOT EXISTS last_reminded_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS reminder_count SMALLINT NOT NULL DEFAULT 0;

COMMENT ON COLUMN crm.invoice.claimed_at IS 'AA-952 (crm-028, Fix A8): when the client pressed "I have paid" on the pay link (open -> payment_claimed); the agent verifies the transfer (task verify_transfer)';
COMMENT ON COLUMN crm.invoice.hold_extended_at IS 'AA-952 (crm-028, Fix A8): when Booking extended the AA hold this invoice pays for (POST /holds/{id}/extend, once per invoice; Booking allows one per hold)';
COMMENT ON COLUMN crm.invoice.hold_extend_code IS 'AA-952 (crm-028): the outcome of that extend: extended, not_needed, or Booking''s refusal code (extend_limit, hold_expired, invalid, not_found); booking_unavailable is retried by the Booking sync';
COMMENT ON COLUMN crm.invoice.rehold_requested_at IS 'AA-952 (crm-028, card E): the payment that settled this deposit invoice arrived after its AA hold ran out: the Booking sync holds the accepted AA items again, then the invoice is paid (or paid_unfulfillable with a refund request)';
COMMENT ON COLUMN crm.invoice.rehold_quote_id IS 'AA-952 (crm-028): the Booking quote the re-hold presents (written before POST /holds, so a lost answer is replayed with the same quote and Idempotency-Key)';
COMMENT ON COLUMN crm.invoice.rehold_price_hash IS 'AA-952 (crm-028): the price_hash of rehold_quote_id';
COMMENT ON COLUMN crm.invoice.rehold_code IS 'AA-952 (crm-028): how the re-hold ended: reheld, hold_live (Booking still held it), or why not (sold_out, price_changed, price_higher, hold_expired, rehold_limit, invalid, not_found, tour_not_served, no_aa_items)';
COMMENT ON COLUMN crm.invoice.last_reminded_at IS 'AA-952 (crm-028, U8): the last overdue reminder to the agent (bell + task invoice_overdue)';
COMMENT ON COLUMN crm.invoice.reminder_count IS 'AA-952 (crm-028): overdue reminders sent for this invoice (capped by the API)';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-028', now(), 'AA-952 CRM-23 slice 4: crm.invoice claim (claimed_at), one Booking hold extension (hold_extended_at, hold_extend_code), the re-hold after a late payment (rehold_requested_at, rehold_quote_id, rehold_price_hash, rehold_code), overdue reminders (last_reminded_at, reminder_count)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
