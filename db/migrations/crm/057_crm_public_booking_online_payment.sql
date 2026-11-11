-- Migration crm-057: AA-1072 (S275 study of a tour and travel app, root docs/research/2026-11-10-odoo-tour-travel-
-- plugin-comparison.md, items crm-02 and crm-03; behaviour only, no plugin code) — "Book now" on the agency's public
-- tour page and online deposit / instalment payment through the agency's own Vietnamese gateway (bring your own
-- merchant account: the agency is always the merchant, no Adventure Asia account ever holds client money).
--
-- Owner: AA-Partner (api/migrations/057_crm_public_booking_online_payment.sql). AA-CIS-Infra db/migrations/crm/ holds
-- the byte copy DB Migrate applies (Migration Copy Guard). Key crm-057: crm-056 belongs to another card of the same
-- wave and is independent (no object of it is used here); if main moves, renumber: file name, this header, Guard 0 and
-- the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS and the tests that name it (git grep '057_' and
-- 'crm-057').
--
-- What:
--   1. crm.tenant_settings.public_booking_enabled (BOOLEAN, default false): the owner's switch for "Book now" on the
--      public tour page (business-owner default: off, each agency turns it on).
--   2. crm.public_booking_attempt (base template): one "Book now" submission of the public tour page, for abuse control
--      and the agency's trace: the intake form whose key the page carried, the AA tour (catalog source id) and
--      departure, the party as counts and ages, the quote and its total, status received -> created | refused |
--      failed with a refusal code, the trip and proposal it made (ids, no keys), the client's submission id (one per
--      agency: a repeated press is the same attempt) and the SHA-256 of the client address under a server key
--      (ip_hash, a per-address ceiling without storing the address). No name, e-mail or phone (they go to the
--      traveller, encrypted). Cascades from the agency's settings row; the API deletes rows older than 90 days.
--   3. crm.integration_credential.provider + vn_gateway: the agency's own gateway credential (merchant code, hash
--      secret, mode) sealed under the agency's integration DEK, agency level.
--   4. crm.payment: method + online (money a client paid through the agency's gateway); payment_provider_ref_uq: one
--      payment per provider reference and agency (a webhook delivered twice records one payment).
--   5. crm.payment_session (base template): one hosted payment the client started for an invoice through the agency's
--      gateway: the account, the merchant transaction reference (txn_ref, random, unique across agencies: the
--      gateway's webhook names it), the amount the server computed, expiry, status open -> paid | failed | review,
--      the gateway's transaction number and response code, the crm.payment it wrote. SELECT-only lookup policy
--      payment_session_ref_lookup TO crm_app keyed on app.payment_txn_ref, set only by
--      app.tenancy.payment_session_tx() (the client_link_token_lookup pattern of crm-012). No card data ever: the
--      gateway's hosted page takes the card. Cascades from its invoice.
--
-- Behaviour on apply: none. No agency has Book now on (default false), no gateway credential or session exists, no
-- payment uses method online until the AA-Partner code PR deploys.
--
-- Class: contract (ALTER of crm.tenant_settings, widened CHECKs on crm.integration_credential and crm.payment, a new
-- unique index on crm.payment, rows in crm.status_transition). MIG-4: this migration-only PR, then the code PR once it
-- is applied on Dev. DM-7.1: the two new tables have their retention rows (root PR, merged before the Infra copy).
-- No crm.erase_subject change: both tables cascade (from tenant_settings, from invoice).
--
-- Rollback (a NEW forward migration, after the code is reverted): DROP TABLE crm.payment_session,
-- crm.public_booking_attempt; DELETE FROM crm.status_transition WHERE table_name IN ('payment_session',
-- 'public_booking_attempt'); DROP INDEX crm.payment_provider_ref_uq; put back the crm-016 method CHECK (needs no online
-- payment left) and the crm-003 provider CHECK (needs no vn_gateway credential left); ALTER TABLE crm.tenant_settings
-- DROP COLUMN public_booking_enabled.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (IF NOT EXISTS, DROP …
-- IF EXISTS before each ADD, CREATE OR REPLACE, ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

-- ── Guard 0: runs as the owner, after crm-055 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-057: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-055') THEN
        RAISE EXCEPTION 'crm-057: crm-055 (AA-1070 travel ops settings) lands first';
    END IF;
    IF to_regclass('crm.invoice') IS NULL OR to_regclass('crm.payment') IS NULL
       OR to_regclass('crm.tenant_settings') IS NULL OR to_regclass('crm.integration_credential') IS NULL
       OR to_regprocedure('crm.guard_held_travel_doc()') IS NULL
       OR to_regprocedure('crm.enforce_status_transition()') IS NULL THEN
        RAISE EXCEPTION 'crm-057: the invoices (crm-024), the vault (crm-003) or the travel ops guard (crm-054) are missing';
    END IF;
END $$;

-- ── 1. crm.tenant_settings.public_booking_enabled ────────────────────────────────────────────────
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS public_booking_enabled BOOLEAN NOT NULL DEFAULT false;
COMMENT ON COLUMN crm.tenant_settings.public_booking_enabled IS 'AA-1072 (crm-057, item crm-02): the owner''s switch for "Book now" on the public AA tour page (an intake form key in the page link names the agency). Default off: clients book through an agent until the owner turns it on';

-- ── 2. crm.public_booking_attempt ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.public_booking_attempt (
    attempt_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                         REFERENCES crm.tenant (tenant_id),
    intake_form_id       UUID NOT NULL,
    tour_source_id       TEXT NOT NULL,
    departure_id         TEXT,
    party                JSONB NOT NULL,
    currency             CHARACTER(3),
    quote_id             TEXT,
    quoted_total         NUMERIC(14,2),
    status               TEXT NOT NULL DEFAULT 'received',
    refusal_code         TEXT,
    trip_id              UUID,
    proposal_id          UUID,
    client_submission_id UUID NOT NULL,
    ip_hash              BYTEA NOT NULL,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at           TIMESTAMPTZ,
    deleted_by           TEXT,
    purge_after          TIMESTAMPTZ,
    CONSTRAINT public_booking_attempt_tenant_id_uq UNIQUE (tenant_id, attempt_id),
    CONSTRAINT public_booking_attempt_submission_uq UNIQUE (tenant_id, client_submission_id),
    CONSTRAINT public_booking_attempt_settings_fk FOREIGN KEY (tenant_id)
        REFERENCES crm.tenant_settings (tenant_id) ON DELETE CASCADE,
    CONSTRAINT public_booking_attempt_status_chk CHECK (status IN ('received', 'created', 'refused', 'failed')),
    CONSTRAINT public_booking_attempt_values_chk CHECK (
        char_length(tour_source_id) BETWEEN 1 AND 128 AND tour_source_id !~ '[[:cntrl:]]'
        AND (departure_id IS NULL OR departure_id ~ '^[A-Za-z0-9:_.-]{1,80}$')
        AND jsonb_typeof(party) = 'object' AND pg_column_size(party) <= 1024
        AND (currency IS NULL OR currency ~ '^[A-Z]{3}$')
        AND (quote_id IS NULL OR quote_id ~ '^[A-Za-z0-9:_.-]{1,80}$')
        AND (quoted_total IS NULL OR quoted_total > 0)
        AND (refusal_code IS NULL OR refusal_code ~ '^[a-z][a-z_]{0,63}$')
        AND octet_length(ip_hash) = 32
    ),
    CONSTRAINT public_booking_attempt_state_chk CHECK (
        (status = 'created') = (trip_id IS NOT NULL AND proposal_id IS NOT NULL)
        AND (status IN ('refused', 'failed')) = (refusal_code IS NOT NULL)
    ),
    CONSTRAINT public_booking_attempt_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS public_booking_attempt_created_idx ON crm.public_booking_attempt (tenant_id, created_at);
CREATE INDEX IF NOT EXISTS public_booking_attempt_ip_idx ON crm.public_booking_attempt (tenant_id, ip_hash, created_at);
ALTER TABLE crm.public_booking_attempt ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.public_booking_attempt FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.public_booking_attempt;
CREATE POLICY tenant_isolation ON crm.public_booking_attempt
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE OR REPLACE TRIGGER public_booking_attempt_set_updated_at
    BEFORE UPDATE ON crm.public_booking_attempt
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('public_booking_attempt', 'received', 'created'),
    ('public_booking_attempt', 'received', 'refused'),
    ('public_booking_attempt', 'received', 'failed')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER public_booking_attempt_status_transition
    BEFORE UPDATE OF status ON crm.public_booking_attempt
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();
CREATE OR REPLACE TRIGGER public_booking_attempt_hold_guard
    BEFORE DELETE OR UPDATE ON crm.public_booking_attempt
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_travel_doc();
COMMENT ON TABLE crm.public_booking_attempt IS 'AA-1072 (crm-057, item crm-02): one "Book now" submission of the public AA tour page (abuse control and the agency''s trace): the form key''s intake form, the AA tour and departure, the party (counts and ages), the quote, status received -> created | refused | failed, the trip and proposal it made (no keys). No name, e-mail or phone. Cascades from the agency''s tenant_settings row; rows older than 90 days are deleted by the API (app/intake/booking.py). No reader grant.';
COMMENT ON COLUMN crm.public_booking_attempt.party IS 'the party the client typed: {"adults": n, "child_ages": [ages]} (counts and ages, no names)';
COMMENT ON COLUMN crm.public_booking_attempt.ip_hash IS 'pii:online_id; HMAC-SHA-256 of the client address under the server''s rate key: the per-address ceiling without the address';
COMMENT ON COLUMN crm.public_booking_attempt.quoted_total IS 'conf:commercial; the retail total the page showed (the agency''s price on the AA quote)';
COMMENT ON COLUMN crm.public_booking_attempt.client_submission_id IS 'the page''s random id of one press of "Book now": a repeat is the same attempt';

-- ── 3. crm.integration_credential.provider + vn_gateway ──────────────────────────────────────────
ALTER TABLE crm.integration_credential DROP CONSTRAINT IF EXISTS integration_credential_provider_chk;
ALTER TABLE crm.integration_credential ADD CONSTRAINT integration_credential_provider_chk CHECK (
    provider IN ('twilio', 'stripe_key', 'stripe_webhook_secret', 'google', 'microsoft', 'smtp', 'esign', 'vn_gateway')
);

-- ── 4. crm.payment: method online, one payment per provider reference ───────────────────────────
ALTER TABLE crm.payment DROP CONSTRAINT IF EXISTS payment_method_chk;
ALTER TABLE crm.payment ADD CONSTRAINT payment_method_chk
    CHECK (method IN ('bank_transfer', 'cash', 'card_offline', 'other', 'online'));
CREATE UNIQUE INDEX IF NOT EXISTS payment_provider_ref_uq ON crm.payment (tenant_id, provider, provider_ref)
    WHERE entry_kind = 'payment' AND provider <> 'manual' AND provider_ref IS NOT NULL;
COMMENT ON INDEX crm.payment_provider_ref_uq IS 'AA-1072 (crm-057): one payment per gateway transaction and agency: a webhook delivered twice records the money once';

-- ── 5. crm.payment_session ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.payment_session (
    session_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                  REFERENCES crm.tenant (tenant_id),
    invoice_id    UUID NOT NULL,
    trip_id       UUID NOT NULL,
    account_id    UUID NOT NULL,
    provider      TEXT NOT NULL,
    txn_ref       TEXT NOT NULL,
    amount        NUMERIC(14,2) NOT NULL,
    currency      CHARACTER(3) NOT NULL,
    status        TEXT NOT NULL DEFAULT 'open',
    expires_at    TIMESTAMPTZ NOT NULL,
    provider_ref  TEXT,
    response_code TEXT,
    payment_id    UUID,
    closed_at     TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at    TIMESTAMPTZ,
    deleted_by    TEXT,
    purge_after   TIMESTAMPTZ,
    CONSTRAINT payment_session_tenant_id_uq UNIQUE (tenant_id, session_id),
    CONSTRAINT payment_session_invoice_fk FOREIGN KEY (tenant_id, invoice_id, trip_id)
        REFERENCES crm.invoice (tenant_id, invoice_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT payment_session_status_chk CHECK (status IN ('open', 'paid', 'failed', 'review')),
    CONSTRAINT payment_session_values_chk CHECK (
        provider IN ('vn_gateway', 'stripe')
        AND txn_ref ~ '^[A-Za-z0-9]{16,40}$'
        AND amount > 0 AND currency ~ '^[A-Z]{3}$'
        AND (provider_ref IS NULL OR (char_length(provider_ref) BETWEEN 1 AND 120 AND provider_ref !~ '[[:cntrl:]]'))
        AND (response_code IS NULL OR response_code ~ '^[A-Za-z0-9_]{1,32}$')
    ),
    CONSTRAINT payment_session_state_chk CHECK (
        (status = 'open') = (closed_at IS NULL)
        AND (status <> 'paid' OR payment_id IS NOT NULL)
    ),
    CONSTRAINT payment_session_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS payment_session_txn_ref_uq ON crm.payment_session (txn_ref);
CREATE INDEX IF NOT EXISTS payment_session_invoice_idx ON crm.payment_session (tenant_id, invoice_id);
ALTER TABLE crm.payment_session ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.payment_session FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.payment_session;
CREATE POLICY tenant_isolation ON crm.payment_session
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
DROP POLICY IF EXISTS payment_session_ref_lookup ON crm.payment_session;
CREATE POLICY payment_session_ref_lookup ON crm.payment_session
    FOR SELECT TO crm_app
    USING (
        txn_ref = NULLIF(current_setting('app.payment_txn_ref', true), '')
        AND deleted_at IS NULL
    );
CREATE OR REPLACE TRIGGER payment_session_set_updated_at
    BEFORE UPDATE ON crm.payment_session
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('payment_session', 'open', 'paid'),
    ('payment_session', 'open', 'failed'),
    ('payment_session', 'open', 'review'),
    ('payment_session', 'failed', 'review')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER payment_session_status_transition
    BEFORE UPDATE OF status ON crm.payment_session
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();
CREATE OR REPLACE TRIGGER payment_session_hold_guard
    BEFORE DELETE OR UPDATE ON crm.payment_session
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_travel_doc();
COMMENT ON TABLE crm.payment_session IS 'AA-1072 (crm-057, item crm-03): one hosted payment a client started for an invoice through the agency''s own gateway (the agency is the merchant): the amount the server computed, the merchant transaction reference the gateway''s signed webhook names, status open -> paid | failed | review (money arrived that could not settle the invoice: the agency checks it). No card data: the gateway''s page takes the card. Cascades from its invoice. payment_session_ref_lookup finds one row by its reference (app.tenancy.payment_session_tx). No reader grant.';
COMMENT ON COLUMN crm.payment_session.txn_ref IS 'the merchant transaction reference sent to the gateway (random, unique across agencies; the webhook names it); a reference, not a secret: the signature is the proof';
COMMENT ON COLUMN crm.payment_session.amount IS 'conf:commercial; what the session asks the client to pay (the invoice''s open amount when it started)';
COMMENT ON COLUMN crm.payment_session.provider_ref IS 'the gateway''s own transaction number from the signed webhook (the payment''s provider_ref)';
COMMENT ON POLICY payment_session_ref_lookup ON crm.payment_session IS 'AA-1072 (crm-057): the one live session whose reference the gateway webhook named, only while app.payment_txn_ref is set (app.tenancy.payment_session_tx). SELECT only; the client_link_token_lookup pattern (crm-012).';

-- ── Post-checks ──────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM crm.status_transition
                    WHERE table_name = 'payment_session' AND from_status = 'open' AND to_status = 'paid')
       OR NOT EXISTS (SELECT 1 FROM crm.status_transition
                       WHERE table_name = 'public_booking_attempt' AND from_status = 'received'
                         AND to_status = 'created') THEN
        RAISE EXCEPTION 'crm-057: a status transition is missing';
    END IF;
    IF NOT has_table_privilege('crm_app', 'crm.payment_session', 'INSERT')
       OR NOT has_table_privilege('crm_app', 'crm.public_booking_attempt', 'DELETE')
       OR NOT has_column_privilege('crm_app', 'crm.tenant_settings', 'public_booking_enabled', 'UPDATE') THEN
        RAISE EXCEPTION 'crm-057: crm_app is missing a privilege on the new objects';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-057', now(), 'AA-1072: Book now and online payment: crm.tenant_settings.public_booking_enabled, crm.public_booking_attempt, crm.payment_session (+ payment_session_ref_lookup), integration_credential provider vn_gateway, payment method online + payment_provider_ref_uq')
ON CONFLICT (version) DO NOTHING;

COMMIT;
