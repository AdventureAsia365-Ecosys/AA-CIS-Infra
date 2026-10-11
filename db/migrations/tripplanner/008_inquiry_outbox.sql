-- Migration tp-008: AA-676 — inquiry.submitted outbox (TripPlanner → AA-Booking) + contact consent.
--
-- ADR 0001 decision 6: apps on the shared acc2 RDS hand data over through a transactional outbox,
-- never by writing each other's schemas. "Send to advisor" appends one row here IN THE SAME
-- TRANSACTION as the `sent` trip event, so a hand-off is never lost or doubled. AA-Booking reads
-- the rows through tripplanner.v_inquiry_outbox and records what it consumed in its own schema
-- (booking.inbox_events, keyed by idempotency_key) — it never updates this table. Contract:
-- AA-Ecosys docs/contracts/inquiry.submitted.v1.json.
--
-- The grant to AA-Booking's DB role is added when that role exists (AA-678); until then only the
-- tripplanner role reads it.
--
-- Contact consent: the registration form now asks for it explicitly; stored on the customer and
-- carried in the payload.
--
-- Applied through AA-CIS-Infra DB Migrate (owner `tripplanner`), key tp-008.

BEGIN;

CREATE TABLE IF NOT EXISTS tripplanner.outbox (
    id              BIGSERIAL PRIMARY KEY,
    event           TEXT NOT NULL,                 -- e.g. inquiry.submitted
    schema_version  INT  NOT NULL,
    idempotency_key TEXT NOT NULL UNIQUE,          -- inquiry.submitted: <trip_id>:<handoff_id>
    aggregate_id    UUID NOT NULL,                 -- trip_id
    payload         JSONB NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT outbox_event_chk CHECK (event IN ('inquiry.submitted'))
);
CREATE INDEX IF NOT EXISTS outbox_event_id_idx ON tripplanner.outbox (event, id);

COMMENT ON TABLE tripplanner.outbox IS
    'AA-676: append-only transactional outbox. Consumers read v_inquiry_outbox and keep their own cursor/inbox; never UPDATE/DELETE here.';

CREATE OR REPLACE VIEW tripplanner.v_inquiry_outbox AS
SELECT id, schema_version, idempotency_key, aggregate_id AS trip_id, payload, created_at
FROM tripplanner.outbox
WHERE event = 'inquiry.submitted';

-- Default privileges on schema tripplanner cover new tables (003/004 notes); the BIGSERIAL sequence
-- and the view are granted explicitly so the Lambda role can insert and read regardless.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tripplanner') THEN
        GRANT SELECT, INSERT ON tripplanner.outbox TO tripplanner;
        GRANT USAGE, SELECT ON SEQUENCE tripplanner.outbox_id_seq TO tripplanner;
        GRANT SELECT ON tripplanner.v_inquiry_outbox TO tripplanner;
    END IF;
END $$;

ALTER TABLE tripplanner.customers
    ADD COLUMN IF NOT EXISTS contact_consent    BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS contact_consent_at TIMESTAMPTZ;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-008', now(), 'AA-676: tripplanner.outbox + v_inquiry_outbox (inquiry.submitted) + customer contact consent')
ON CONFLICT (version) DO NOTHING;

COMMIT;
