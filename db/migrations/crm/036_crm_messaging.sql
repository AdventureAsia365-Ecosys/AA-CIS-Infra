-- migrate: contract
-- Migration crm-036: AA-958 CRM-28 Module 9 WhatsApp + SMS (design v3 M9, §5.4, WF-11; data-privacy-integrations
-- §2.8 group G and §6.4; BYO errata S247 §1 / §2: the agency's own Twilio only, AA holds no vendor account) — the
-- agency's text-message connection with its per-agency webhook id, the WhatsApp templates it got approved in its own
-- Twilio account, the delivery state of each outbound text message, and the 24-hour WhatsApp window and the opt-out
-- state of a conversation.
--
-- Owner: AA-Partner (api/migrations/036_crm_messaging.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy DB
-- Migrate applies (Migration Sync bot, Migration Copy Guard). Key crm-036, after crm-035 (AA-957); if main moves,
-- renumber: file name, this header, the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS.
--
-- What (DM-7.1: the three tables get their rows in root data standards Part B §7 in the root PR of this card, merged
-- before the Infra copy):
--   1. crm.messaging_connection (base template, no status column): the agency's one live text-message connection:
--      provider twilio | sandbox (sandbox = the deterministic stub the API allows on dev / test / local only, so Dev
--      checks cost $0), its credential (crm.integration_credential provider twilio, member_id NULL: the Account SID
--      as account_ref, the Auth Token sealed under the integration DEK; the credential row carries the errata §2
--      health columns), hook_id (32 random lower-case hex characters: the opaque path segment of the agency's webhook
--      URL), the SMS sender (E.164 number, alphanumeric sender id or Messaging Service SID) and the WhatsApp sender
--      (E.164), the last inbound and status callback times. The credential key cascades (ON DELETE CASCADE): a
--      disconnect deletes the credential (the only copy of the token) and the connection with it; the audit keeps
--      the history. SELECT-only lookup policy messaging_connection_hook_lookup TO crm_app keyed on
--      app.messaging_hook_id (live rows only), set only by app.tenancy.messaging_hook_tx() (the ingest_address_lookup
--      pattern of crm-015).
--   2. crm.channel_template (base template): the WhatsApp templates the agency's Twilio account holds (Content API),
--      synced by the job crm_messaging_templates: content_sid (HX…), name, language, category, approval
--      (approved | pending | rejected | paused | disabled | unsubmitted; only approved ones are ever sent), the body
--      text with its {{n}} placeholders, the variable names. Cascades from its connection.
--   3. crm.message_delivery (base template): the channel facts of one outbound SMS / WhatsApp crm.message: the
--      template it sends (content_sid) and its variables (variables_enc, mail DEK, pii:free_text), and the provider's
--      latest delivery state (provider_status queued | sending | sent | delivered | read | undelivered | failed,
--      status_rank, error_code, status_at). Card E: a status callback updates the row only when its rank is higher,
--      so out-of-order callbacks keep the latest state. Cascades from its message; crm_app never deletes one.
--   4. crm.conversation: wa_window_expires_at (the last inbound WhatsApp message + 24 h: outside it only an approved
--      template may be sent, card R 409 template_required) and opted_out_at (the client texted STOP on this channel;
--      START clears it; the dispatcher drops a queued text message no_consent while any conversation of the client on
--      that channel is opted out). Both new nullable columns without a default.
--   5. Erasure without a replaced crm.erase_subject: every new table cascades from a row the erase already deletes
--      (message_delivery from crm.message in the trip, traveller, conversation and agency scopes; the connection from
--      crm.integration_credential and the templates from the connection in the agency scope), so the agency erase's
--      "nothing left" check finds none. tests/integration/test_crm010_schema.py lists the three tables as
--      cascade-erased and checks the ON DELETE CASCADE keys. A held message is never deleted (crm.guard_message), so
--      the cascade needs no hold guard of its own.
--   6. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles); crm_app keeps the default DML of crm-001 except DELETE
--      on crm.message_delivery; no reader grant (AI, insights and support never see a connection, a template or a
--      delivery row; support sees connection health only through the credential, errata §1 CRM-13b).
--
-- Class: expand (root ADR 0017 d3): three new tables with their constraints, indexes, triggers, policies, grants and
-- comments; foreign keys from the new tables (the RI triggers they add on crm.tenant, crm.integration_credential and
-- crm.message are allowed); two new nullable columns without a default on crm.conversation (not a hot table; no code
-- reads it with SELECT * / RETURNING *); no other change to an existing object, no DO block, no CREATE OR REPLACE.
-- DB Migrate never applies a registered file twice and the test conftest skips it. The code PR carries this file and
-- raises REQUIRED_SCHEMA_VERSIONS to crm-036 (expand: one PR).
--
-- Rollback (a forward crm- file, after the code that reads it is reverted): DROP TABLE crm.message_delivery;
-- DROP TABLE crm.channel_template; DROP TABLE crm.messaging_connection; ALTER TABLE crm.conversation DROP COLUMN
-- wa_window_expires_at, DROP COLUMN opted_out_at.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- ── 1. crm.messaging_connection ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.messaging_connection (
    messaging_connection_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                            REFERENCES crm.tenant (tenant_id),
    provider                TEXT NOT NULL,
    credential_id           UUID NOT NULL,
    hook_id                 TEXT NOT NULL,
    sms_sender              TEXT,
    whatsapp_sender         TEXT,
    last_inbound_at         TIMESTAMPTZ,
    last_status_at          TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at              TIMESTAMPTZ,
    deleted_by              TEXT,
    purge_after             TIMESTAMPTZ,
    CONSTRAINT messaging_connection_tenant_id_uq UNIQUE (tenant_id, messaging_connection_id),
    CONSTRAINT messaging_connection_hook_uq UNIQUE (hook_id),
    CONSTRAINT messaging_connection_credential_fk FOREIGN KEY (tenant_id, credential_id)
        REFERENCES crm.integration_credential (tenant_id, integration_credential_id) ON DELETE CASCADE,
    CONSTRAINT messaging_connection_provider_chk CHECK (provider IN ('twilio', 'sandbox')),
    CONSTRAINT messaging_connection_hook_chk CHECK (hook_id ~ '^[0-9a-f]{32}$'),
    CONSTRAINT messaging_connection_sms_chk CHECK (
        sms_sender IS NULL
        OR sms_sender ~ '^\+[1-9][0-9]{6,14}$'
        OR sms_sender ~ '^MG[0-9a-f]{32}$'
        OR (sms_sender ~ '^[A-Za-z0-9 ]{1,11}$' AND sms_sender ~ '[A-Za-z]')
    ),
    CONSTRAINT messaging_connection_whatsapp_chk CHECK (
        whatsapp_sender IS NULL OR whatsapp_sender ~ '^\+[1-9][0-9]{6,14}$'
    ),
    CONSTRAINT messaging_connection_sender_chk CHECK (num_nonnulls(sms_sender, whatsapp_sender) >= 1),
    CONSTRAINT messaging_connection_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
-- One live connection per agency.
CREATE UNIQUE INDEX IF NOT EXISTS messaging_connection_live_uq ON crm.messaging_connection (tenant_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS messaging_connection_credential_idx ON crm.messaging_connection (tenant_id, credential_id);

ALTER TABLE crm.messaging_connection ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.messaging_connection FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.messaging_connection;
CREATE POLICY tenant_isolation ON crm.messaging_connection
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
DROP POLICY IF EXISTS messaging_connection_hook_lookup ON crm.messaging_connection;
CREATE POLICY messaging_connection_hook_lookup ON crm.messaging_connection
    FOR SELECT TO crm_app
    USING (
        hook_id = NULLIF(current_setting('app.messaging_hook_id', true), '')
        AND deleted_at IS NULL
    );
COMMENT ON POLICY messaging_connection_hook_lookup ON crm.messaging_connection IS 'AA-958 (crm-036): the one live connection whose hook id the public Twilio webhook route was called with, only while app.messaging_hook_id is set (app.tenancy.messaging_hook_tx). SELECT only; the ingest_address_lookup pattern (crm-015).';

DROP TRIGGER IF EXISTS messaging_connection_set_updated_at ON crm.messaging_connection;
CREATE TRIGGER messaging_connection_set_updated_at
    BEFORE UPDATE ON crm.messaging_connection
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();

COMMENT ON TABLE crm.messaging_connection IS 'AA-958 (crm-036; design v3 M9, §5.4; BYO errata S247 §1 / §2): the agency''s one live SMS / WhatsApp connection on its own Twilio account (provider twilio; sandbox = the deterministic stub allowed on dev / test / local only). The Account SID and the sealed Auth Token are its crm.integration_credential (provider twilio, agency level); deleting that credential (disconnect, agency erase) deletes the connection and its templates. hook_id is the opaque path segment of the per-agency webhook URL; every webhook is checked against the agency''s token (X-Twilio-Signature) before anything is stored.';
COMMENT ON COLUMN crm.messaging_connection.provider IS 'twilio (the agency''s own account) | sandbox (deterministic stub, dev / test / local only, sends nothing, costs nothing)';
COMMENT ON COLUMN crm.messaging_connection.hook_id IS '32 random lower-case hex characters: the agency''s webhook path /crm/public/v1/hooks/twilio/<hook_id>; a reference, not a secret (the request signature is the proof)';
COMMENT ON COLUMN crm.messaging_connection.sms_sender IS 'pii:contact; the agency''s SMS sender: an E.164 number, an alphanumeric sender id or a Messaging Service SID of its own Twilio account';
COMMENT ON COLUMN crm.messaging_connection.whatsapp_sender IS 'pii:contact; the agency''s WhatsApp sender number (E.164) registered in its own Twilio account';

-- ── 2. crm.channel_template ──────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.channel_template (
    channel_template_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                            REFERENCES crm.tenant (tenant_id),
    messaging_connection_id UUID NOT NULL,
    content_sid             TEXT NOT NULL,
    name                    TEXT NOT NULL,
    language                TEXT NOT NULL,
    category                TEXT,
    approval                TEXT NOT NULL,
    body                    TEXT NOT NULL,
    variables               TEXT[] NOT NULL DEFAULT '{}',
    synced_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at              TIMESTAMPTZ,
    deleted_by              TEXT,
    purge_after             TIMESTAMPTZ,
    CONSTRAINT channel_template_tenant_id_uq UNIQUE (tenant_id, channel_template_id),
    CONSTRAINT channel_template_sid_uq UNIQUE (tenant_id, content_sid),
    CONSTRAINT channel_template_connection_fk FOREIGN KEY (tenant_id, messaging_connection_id)
        REFERENCES crm.messaging_connection (tenant_id, messaging_connection_id) ON DELETE CASCADE,
    CONSTRAINT channel_template_values_chk CHECK (
        content_sid ~ '^HX[0-9a-f]{32}$'
        AND char_length(btrim(name)) BETWEEN 1 AND 200 AND name !~ '[[:cntrl:]]'
        AND language ~ '^[a-z]{2,3}([_-][A-Za-z0-9]{2,8})?$'
        AND (category IS NULL OR category ~ '^[A-Za-z_]{1,40}$')
        AND approval IN ('approved', 'pending', 'rejected', 'paused', 'disabled', 'unsubmitted')
        AND char_length(body) <= 4096
        AND cardinality(variables) <= 100
        AND array_to_string(variables, ',') ~ '^([A-Za-z0-9_]{1,40}(,[A-Za-z0-9_]{1,40})*)?$'
    ),
    CONSTRAINT channel_template_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS channel_template_connection_idx ON crm.channel_template (tenant_id, messaging_connection_id);

ALTER TABLE crm.channel_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.channel_template FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.channel_template;
CREATE POLICY tenant_isolation ON crm.channel_template
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

DROP TRIGGER IF EXISTS channel_template_set_updated_at ON crm.channel_template;
CREATE TRIGGER channel_template_set_updated_at
    BEFORE UPDATE ON crm.channel_template
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();

COMMENT ON TABLE crm.channel_template IS 'AA-958 (crm-036; design v3 M9 "approved templates"; BYO errata S247 §1 "the CRM reads approved templates"): the WhatsApp message templates of the agency''s own Twilio account (Content API), synced by crm_messaging_templates on connect, on Refresh and every night. Outside the 24-hour window only an approved one is sent. The body is the agency''s own template text with {{n}} placeholders (Meta-reviewed business text, no client data); client values go into crm.message_delivery.variables_enc. Cascades from its connection.';
COMMENT ON COLUMN crm.channel_template.content_sid IS 'the Twilio Content SID (HX + 32 hex) of the template in the agency''s account';
COMMENT ON COLUMN crm.channel_template.approval IS 'the WhatsApp approval state Twilio reports: approved | pending | rejected | paused | disabled | unsubmitted; only approved is sent';
COMMENT ON COLUMN crm.channel_template.body IS 'the template text with its {{n}} / {{name}} placeholders, as approved in the agency''s account (no client data)';
COMMENT ON COLUMN crm.channel_template.variables IS 'the placeholder names of the body, in order';

-- ── 3. crm.message_delivery ──────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.message_delivery (
    message_id       UUID PRIMARY KEY,
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    channel          TEXT NOT NULL,
    content_sid      TEXT,
    variables_enc    BYTEA,
    provider_status  TEXT,
    status_rank      SMALLINT NOT NULL DEFAULT 0,
    error_code       TEXT,
    status_at        TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT message_delivery_tenant_id_uq UNIQUE (tenant_id, message_id),
    CONSTRAINT message_delivery_message_fk FOREIGN KEY (tenant_id, message_id)
        REFERENCES crm.message (tenant_id, message_id) ON DELETE CASCADE,
    CONSTRAINT message_delivery_values_chk CHECK (
        channel IN ('sms', 'whatsapp')
        AND (content_sid IS NULL OR content_sid ~ '^HX[0-9a-f]{32}$')
        AND (variables_enc IS NULL OR (content_sid IS NOT NULL AND octet_length(variables_enc) >= 30))
        AND (provider_status IS NULL
             OR provider_status IN ('queued', 'sending', 'sent', 'delivered', 'read', 'undelivered', 'failed'))
        AND status_rank BETWEEN 0 AND 9
        AND (provider_status IS NULL) = (status_rank = 0)
        AND (provider_status IS NULL) = (status_at IS NULL)
        AND (error_code IS NULL OR error_code ~ '^[0-9]{1,6}$')
    ),
    CONSTRAINT message_delivery_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);

ALTER TABLE crm.message_delivery ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.message_delivery FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.message_delivery;
CREATE POLICY tenant_isolation ON crm.message_delivery
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
-- A row leaves with its message only (the cascade).
REVOKE DELETE ON crm.message_delivery FROM crm_app;

DROP TRIGGER IF EXISTS message_delivery_set_updated_at ON crm.message_delivery;
CREATE TRIGGER message_delivery_set_updated_at
    BEFORE UPDATE ON crm.message_delivery
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();

COMMENT ON TABLE crm.message_delivery IS 'AA-958 (crm-036; design v3 M9; card E "out-of-order status callbacks keep the latest state"): the channel facts of one outbound SMS / WhatsApp crm.message: the approved template it sends and its variables, and the provider''s latest delivery state. A status callback updates the row only when its status_rank is higher (queued 1 < sending 2 < sent 3 < undelivered / failed 4 < delivered 5 < read 6). Cascades from its message (erasure included); crm_app never deletes one.';
COMMENT ON COLUMN crm.message_delivery.content_sid IS 'the approved template (crm.channel_template.content_sid) the message sends; NULL = free text';
COMMENT ON COLUMN crm.message_delivery.variables_enc IS 'pii:free_text; the template variables as JSON {"1": "…"}, AES-256-GCM under the tenant mail DEK, AAD = tenant, message_delivery, variables_enc, message id';
COMMENT ON COLUMN crm.message_delivery.provider_status IS 'the latest delivery state the provider reported: queued | sending | sent | delivered | read | undelivered | failed';
COMMENT ON COLUMN crm.message_delivery.status_rank IS 'the order of provider_status (0 = none yet): a callback with a lower or equal rank is ignored';
COMMENT ON COLUMN crm.message_delivery.error_code IS 'the provider''s numeric error code of an undelivered / failed message (e.g. 63016: outside the WhatsApp window)';

-- ── 4. crm.conversation: the WhatsApp window and the opt-out ─────────────────────────────────────
ALTER TABLE crm.conversation ADD COLUMN IF NOT EXISTS wa_window_expires_at TIMESTAMPTZ;
ALTER TABLE crm.conversation ADD COLUMN IF NOT EXISTS opted_out_at TIMESTAMPTZ;
COMMENT ON COLUMN crm.conversation.wa_window_expires_at IS 'AA-958 (crm-036): a WhatsApp conversation''s customer-service window: the last inbound message + 24 h. Outside it only an approved template is sent (409 template_required)';
COMMENT ON COLUMN crm.conversation.opted_out_at IS 'AA-958 (crm-036): when the client texted STOP (or the provider reported an opt-out) on this SMS / WhatsApp conversation; START clears it. While set on any conversation of the client on the channel, nothing is sent on it (dispatcher no_consent)';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-036', now(), 'AA-958 CRM-28 WhatsApp + SMS: crm.messaging_connection (the agency''s own Twilio, per-agency webhook id, hook lookup policy), crm.channel_template (approved WhatsApp templates), crm.message_delivery (template + variables, latest delivery state by rank); crm.conversation.wa_window_expires_at + opted_out_at; cascading keys, no erase_subject change')
ON CONFLICT (version) DO NOTHING;

COMMIT;
