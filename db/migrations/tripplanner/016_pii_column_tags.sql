-- Migration tp-016: AA-877 — data standards DM-6.1 tags on the TripPlanner columns that hold personal data or
-- credentials.
--
-- Owner: AA-TripPlanner-Web (key tp-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/tripplanner/016_pii_column_tags.sql and is applied to Dev by the DB Migrate workflow (check, then apply),
-- as tp_owner (the live owner of schema tripplanner since tp-013, XD8). Never run it from a laptop.
--
-- Why (AA-877; data standards Part B DM-6.1, DM-3.2): every column that holds personal data carries
-- COMMENT 'pii:<class>; <free text>' (classes contact, name, address, profile, online_id, free_text, travel, payment);
-- credentials and their hashes carry 'conf:credential; …'. The nightly schema dump (AA-CIS-Infra db/schema_dump.py,
-- rendered by db/gen_schema_reference.py) collects the tags into the schema reference; they are the column inventory
-- of the RoPA (AA-Ecosys docs/legal/register.md, AA-886) and of the erasure runbook (DM-6.7). "also pii:<class>" names
-- further classes in the same column.
--
-- What: COMMENT ON COLUMN only. No DDL, no grant, no data. COMMENT replaces the whole comment: sessions.guest_token and
-- sessions.guest_token_hash had a tp-011 comment in the form 'conf:credential — …'; they are restated in the standard
-- form 'conf:credential; …' with the tp-011 text after the '; ' unchanged.
-- View columns (v_inquiry_outbox.payload) carry the tag of their base column. A column comment survives CREATE OR
-- REPLACE VIEW but not DROP VIEW + CREATE VIEW: a later file that recreates the view must restate the comment
-- (migrations/tests/test_tp016_pg.py fails otherwise).
-- Deliberately untagged: sessions.customer_id, trip_events.session_id / trip_id (pseudonymous ids), consent flags and
-- timestamps, the frozen catalog read model (tour_*, itinerary_components, narration_cache) and llm_spend_daily (no
-- personal data). The allowlist with reasons is in migrations/tests/test_tp016_pg.py; the authority for the schema
-- reference is AA-CIS-Infra db/gen_schema_reference.py PII_ALLOWLIST.
-- Rule from here on (CONTEXT.md): a new personal or credential column ships its tag in the migration that creates it.
--
-- Re-runnable (test_replay_twice_pg.py replays every file twice): COMMENT is idempotent.
-- Undo: a later tp- file restores the previous comments: NULL for every column below except sessions.guest_token and
-- sessions.guest_token_hash, whose tp-011 text is 'conf:credential — ' followed by the part after the tag here.

BEGIN;

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-016: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
END $$;

-- ── Personal data (pii:<class>) ──────────────────────────────────────────────

-- The traveller's contact snapshot taken at hand-off (master record: booking.customers).
COMMENT ON COLUMN tripplanner.customers.name IS 'pii:name; tp-016: traveller name given at hand-off.';
COMMENT ON COLUMN tripplanner.customers.phone IS 'pii:contact; tp-016: traveller phone given at hand-off.';
COMMENT ON COLUMN tripplanner.customers.email IS 'pii:contact; tp-016: traveller e-mail given at hand-off.';

-- inquiry.submitted rows (contract inquiry.submitted v1.2): customer.name / email / phone, the itinerary with dates,
-- custom day notes typed by the traveller.
COMMENT ON COLUMN tripplanner.outbox.payload IS
    'pii:contact; also pii:name, pii:free_text and pii:travel (inquiry.submitted customer.name / email / phone, itinerary with dates and custom day notes). 90-day redaction approved, not built until tripplanner.job (AA-861).';
COMMENT ON COLUMN tripplanner.v_inquiry_outbox.payload IS
    'pii:contact; also pii:name, pii:free_text and pii:travel (tripplanner.outbox.payload, inquiry.submitted rows).';

-- The trip being planned.
COMMENT ON COLUMN tripplanner.trip_drafts.itinerary IS
    'pii:travel; also pii:free_text (tp-016: the planned days and components; custom days carry a traveller note).';
COMMENT ON COLUMN tripplanner.trip_drafts.date_start IS 'pii:travel; tp-016: planned travel start date.';
COMMENT ON COLUMN tripplanner.trip_drafts.date_end IS 'pii:travel; tp-016: planned travel end date.';

-- Edit events: add_day carries a traveller note (up to 500 characters); every other event type carries ids only.
COMMENT ON COLUMN tripplanner.trip_events.payload IS
    'pii:free_text; also pii:travel (tp-016: add_day events carry the traveller note, up to 500 characters; other event types carry ids only).';

-- ── Credentials (conf:credential), restated in the standard form ─────────────

COMMENT ON COLUMN tripplanner.sessions.guest_token_hash IS
    'conf:credential; sha256 of the BFF guest cookie token (AA-827); the token itself is never stored';
COMMENT ON COLUMN tripplanner.sessions.guest_token IS
    'conf:credential; DEPRECATED (AA-827): legacy plaintext id::text, no longer written; nulled by tp-012, dropped by a later contract migration';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-016', now(), 'AA-877: DM-6.1 pii/conf tags on TripPlanner columns (COMMENT ON COLUMN only)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
