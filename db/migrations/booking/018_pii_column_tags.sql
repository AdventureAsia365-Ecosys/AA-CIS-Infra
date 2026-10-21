-- Migration bk-018: AA-877 — data standards DM-6.1 tags on the Booking columns that hold personal data, credentials
-- or commercial secrets.
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra db/migrations/booking/018_pii_column_tags.sql
-- and is applied to Dev by the DB Migrate workflow (check, then apply), as bk_owner (the live owner of schema booking
-- since bk-014). Never run it from a laptop.
--
-- Why (AA-877; data standards Part B DM-6.1, DM-3.2): every column that holds personal data carries
-- COMMENT 'pii:<class>; <free text>' (classes contact, name, address, profile, online_id, free_text, travel, payment);
-- commercial secrets carry 'conf:commercial; …', credentials and their hashes 'conf:credential; …'. The nightly schema
-- dump (AA-CIS-Infra db/schema_dump.py) collects the tags into the schema reference; they are the column inventory of
-- the RoPA (AA-886) and the erasure runbook (DM-6.7). "also pii:<class>" names further classes in the same column.
--
-- What: COMMENT ON COLUMN only. No DDL, no grant, no data. COMMENT replaces the whole comment, so a column that already
-- had a comment keeps that text verbatim after the tag (listed below). Columns already tagged by bk-008, bk-009, bk-010
-- and bk-012 are not touched: suppliers.contact_name / contact_email / contact_phone / internal_notes,
-- supplier_contracts.payment_terms / cancellation_policy / notes, trip_plans.default_channel / price_hint_* /
-- commercial_notes, hotels / hotel_room_types / services.internal_notes, supplier_rates.net_amount / notes,
-- inbox_events.payload.
-- View columns (v_customer_summary) carry the tag of their base column. A column comment survives CREATE OR REPLACE
-- VIEW but not DROP VIEW + CREATE VIEW: a later file that recreates the view must restate these four comments (the
-- Integration Tests candidate check fails otherwise).
-- Deliberately untagged (pseudonymous ids and *_by / *_ref staff keys, customers.code / external_ref, consent flags,
-- timestamps, staff_users.last_seen_at / preferences, business names and addresses, booking.job payload / result /
-- error with ids only, trip_case_legs, trip_case_countries): the allowlist with reasons is in
-- backend/tests/integration/test_bk018_pii_tags.py; the authority for the schema reference is AA-CIS-Infra
-- db/gen_schema_reference.py PII_ALLOWLIST.
-- Block C (commercial secrets) is separate from the personal data: it can be cut without touching A and B, but then
-- pricing_rules.note, policy_approvals.note and version_item_costs.supplier_note must be allowlisted instead.
-- Rule from here on (CONTEXT.md): a new personal, commercial or credential column ships its tag in the migration that
-- creates it.
--
-- Re-runnable (the Integration Tests replay every file): COMMENT is idempotent.
-- Undo: a later bk- file restores the previous comments — NULL for every column below except these, whose previous
-- text is the part after the tag: trip_cases.inquiry_snapshot (bk-002), trip_cases.pax_adults (bk-005),
-- staff_users.cis_user_id / cognito_iss / cognito_sub (bk-016), pricing_rules.target_margin / floor_margin /
-- peak_uplift_pts / card_fee_pct (bk-004).

BEGIN;

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-018: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
END $$;

-- ── A. Personal data (pii:<class>) ───────────────────────────────────────────

-- Customers (the single customer master, DM-6.2).
COMMENT ON COLUMN booking.customers.name IS 'pii:name; bk-018: customer full name.';
COMMENT ON COLUMN booking.customers.email IS 'pii:contact; bk-018: customer e-mail (lower-cased by the API).';
COMMENT ON COLUMN booking.customers.phone IS 'pii:contact; bk-018: customer phone.';
COMMENT ON COLUMN booking.customers.address IS 'pii:address; bk-018: customer postal address.';
COMMENT ON COLUMN booking.customers.gender IS 'pii:profile; bk-018: customer gender.';
COMMENT ON COLUMN booking.customers.marital_status IS 'pii:profile; bk-018: customer marital status.';
COMMENT ON COLUMN booking.customers.profession IS 'pii:profile; bk-018: customer profession.';
COMMENT ON COLUMN booking.customers.profile_media_id IS
    'pii:profile; bk-018: the customer profile photo (booking.media_files).';
COMMENT ON COLUMN booking.media_files.s3_key IS
    'pii:profile; bk-018: object key of a stored file. No uploader yet; intended for the customer profile photo referenced by customers.profile_media_id.';

COMMENT ON COLUMN booking.v_customer_summary.name IS 'pii:name; bk-018: customers.name.';
COMMENT ON COLUMN booking.v_customer_summary.email IS 'pii:contact; bk-018: customers.email.';
COMMENT ON COLUMN booking.v_customer_summary.phone IS 'pii:contact; bk-018: customers.phone.';
COMMENT ON COLUMN booking.v_customer_summary.address IS 'pii:address; bk-018: customers.address.';

-- Staff (WORKFORCE identity, bk-016).
COMMENT ON COLUMN booking.staff_users.name IS 'pii:name; bk-018: staff display name.';
COMMENT ON COLUMN booking.staff_users.email IS 'pii:contact; bk-018: staff work e-mail.';
COMMENT ON COLUMN booking.staff_users.cis_user_id IS
    'pii:online_id; The Booking staff key (legacy name; every staff FK points here): CIS shared.admin_users.id for bridge-era rows, ''cog:'' || Cognito sub for rows created on a WORKFORCE sign-in (bk-016).';
COMMENT ON COLUMN booking.staff_users.cognito_iss IS
    'pii:online_id; bk-016: issuer of the linked Cognito identity (the WORKFORCE pool issuer); NULL = not linked yet.';
COMMENT ON COLUMN booking.staff_users.cognito_sub IS
    'pii:online_id; bk-016: sub of the linked Cognito identity; unique with cognito_iss; never rebound to another identity by the app.';

-- Supplier contact person (contact_name / email / phone are tagged since bk-008).
COMMENT ON COLUMN booking.suppliers.contact_title IS 'pii:profile; bk-018: job title of the supplier contact person.';

-- Trip cases: dates, party and preferences tied to the customer.
COMMENT ON COLUMN booking.trip_cases.start_date IS 'pii:travel; bk-018: travel start date of the customer.';
COMMENT ON COLUMN booking.trip_cases.end_date IS 'pii:travel; bk-018: travel end date of the customer.';
COMMENT ON COLUMN booking.trip_cases.pax IS 'pii:travel; bk-018: party size.';
COMMENT ON COLUMN booking.trip_cases.pax_adults IS
    'pii:travel; bk-005 (Q13): adults; when set, pax = pax_adults + coalesce(pax_children, 0).';
COMMENT ON COLUMN booking.trip_cases.pax_children IS 'pii:travel; bk-018: children in the party.';
COMMENT ON COLUMN booking.trip_cases.trip_style IS 'pii:travel; bk-018: travel style preference of the customer.';
COMMENT ON COLUMN booking.trip_cases.inquiry_snapshot IS
    'pii:travel; also pii:free_text (custom day notes typed by the traveller). Itinerary of the inquiry as received (days, custom_days) for staff; legs are also normalised into trip_case_legs.';

-- Free text that may name or describe a person.
COMMENT ON COLUMN booking.trip_cases.notes IS 'pii:free_text; bk-018: staff notes on the case; may name the customer.';
COMMENT ON COLUMN booking.trip_case_status_history.note IS
    'pii:free_text; bk-018: reason typed with a status change; may name the customer.';
COMMENT ON COLUMN booking.trip_case_versions.notes IS 'pii:free_text; bk-018: staff notes on the proposal version.';
COMMENT ON COLUMN booking.trip_case_versions.title IS
    'pii:free_text; bk-018: proposal title typed by staff and sent to the customer.';
COMMENT ON COLUMN booking.trip_case_versions.approval_note IS
    'pii:free_text; bk-018: note recorded with the customer approval.';
COMMENT ON COLUMN booking.trip_case_version_itinerary.notes IS
    'pii:free_text; bk-018: notes on an itinerary item (customer requests).';
COMMENT ON COLUMN booking.notifications.title IS
    'pii:free_text; bk-018: proposal.sent rows hold the e-mail subject typed by staff; staff rows hold case codes.';
COMMENT ON COLUMN booking.notifications.message IS
    'pii:free_text; also pii:name (new inquiry rows start with the contact name; proposal.sent rows hold the e-mail body).';
COMMENT ON COLUMN booking.notifications.data IS
    'pii:contact; bk-018: proposal.sent rows carry data.to (the customer e-mail); other types carry ids and codes.';
COMMENT ON COLUMN booking.audit_logs.before IS
    'pii:free_text; also pii:name and pii:contact (customer row snapshots). Redacted, not deleted, on erasure (DM-6.7).';
COMMENT ON COLUMN booking.audit_logs.after IS
    'pii:free_text; also pii:name and pii:contact (customer row snapshots). Redacted, not deleted, on erasure (DM-6.7).';
COMMENT ON COLUMN booking.audit_logs.entity_label IS
    'pii:free_text; also pii:name (bk-018: label written at write time, usually a code; the staff name on staff rows).';
COMMENT ON COLUMN booking.audit_logs.summary IS
    'pii:free_text; also pii:name (bk-018: one-line summary written at write time; names the customer on a manual lead, "Created manual lead <name>").';
COMMENT ON COLUMN booking.inbox_events.error IS
    'pii:free_text; bk-018: processing error of a failed row; may quote the payload. Replaced by bk_retention_inbox_redact with the payload (bk-012).';

-- ── B. Credentials (conf:credential) ─────────────────────────────────────────

COMMENT ON COLUMN booking.customer_otps.otp_hash IS 'conf:credential; bk-018: hash of a one-time sign-in code (DM-6.9).';
COMMENT ON COLUMN booking.customer_sessions.refresh_token_hash IS
    'conf:credential; bk-018: hash of a customer refresh token (DM-6.9).';

-- ── C. Commercial secrets (conf:commercial), the columns bk-008 / 009 / 010 left ──

COMMENT ON COLUMN booking.pricing_rules.target_margin IS
    'conf:commercial; Gross margin on the selling price (not markup): sell = net / (1 - margin - card_fee). 0.3000 = 30%.';
COMMENT ON COLUMN booking.pricing_rules.floor_margin IS
    'conf:commercial; Effective margin below this flags the quote below_floor; a sales override there needs a reason (audited).';
COMMENT ON COLUMN booking.pricing_rules.peak_uplift_pts IS
    'conf:commercial; Added to target_margin for peak-season quotes (ADR 0005: +3 to +5 points). 0.0300 = 3 points.';
COMMENT ON COLUMN booking.pricing_rules.card_fee_pct IS
    'conf:commercial; Card/payment fee built into the price (ADR 0005: about 3%), a share of the selling price.';
COMMENT ON COLUMN booking.pricing_rules.note IS 'conf:commercial; bk-018: staff note on the pricing policy row.';
COMMENT ON COLUMN booking.policy_approvals.note IS
    'conf:commercial; bk-018: approver note on a pricing policy or FX rate row.';
COMMENT ON COLUMN booking.version_item_costs.net_amount IS
    'conf:commercial; bk-018: supplier net cost of the item, the base of the selling price.';
COMMENT ON COLUMN booking.version_item_costs.supplier_note IS
    'conf:commercial; bk-018: staff note on the supplier cost line.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-018', now(), 'AA-877: DM-6.1 pii/conf tags on Booking columns (COMMENT ON COLUMN only)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
