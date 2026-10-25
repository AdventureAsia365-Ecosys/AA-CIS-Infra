-- Migration crm-015: AA-945 (partner CRM, design v3 card CRM-17) — Module 5 e-mail: the forward-in address of an
-- agency, the agency's own mailboxes (send-as Gmail / Microsoft 365 / SMTP), conversations and messages under the
-- tenant mail DEK, saved replies, autosaved drafts, the history import record, the per-trip threading token, and the
-- erasure / hold rule extended to the new tables.
--
-- Owner: AA-Partner (api/migrations/015_crm_mail.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy DB Migrate
-- applies (Migration Copy Guard). Key crm-015 (S250 schedule §1). crm.erase_held and crm.erase_subject below are the
-- crm-014 text plus the mail steps; a later key that replaces them starts from THIS text.
--
-- Why. Design v3 §6.3 card CRM-17 (M5, R24, Q2 4.1; checklist: SES ingest, send-as, saved replies, notes, autosaved
-- drafts, sender table, held_reconnect, forwarding code, history import), lane §2.8 group G and §6.5, as changed by the
-- BYO errata S247 §1 (ADR 0010 decision 9): send-as through Gmail, Microsoft 365 or SMTP (send only), and
-- allow_platform_sender REMOVED, so a message's sender is agency_mailbox or system only (no tenant_settings column).
-- Card R: an unknown forward-in address is discarded (no row); a revoked token holds the message (held_reconnect), it is
-- never sent through SES. Card E: a thread without References is matched by the trip token.
--
-- What:
--   1. crm.integration_credential (crm-003): member_id (NULL = an agency-level credential, else the member's own
--      mailbox; design §4.6: agent and assistant connect their own mailbox, OWN_MAILBOX_CONNECT), same-agency key to
--      crm.member; UNIQUE (tenant_id, provider) becomes UNIQUE NULLS NOT DISTINCT (tenant_id, provider, member_id);
--      UNIQUE (tenant_id, integration_credential_id) for the same-agency key below.
--   2. crm.channel_account (base template): one sending mailbox per member, or one agency-level one (member_id NULL;
--      UNIQUE NULLS NOT DISTINCT (tenant_id, member_id)). kind gmail | microsoft | smtp, address_enc (mail DEK,
--      pii:contact) + address_bidx, credential_id (same-agency key, ON DELETE SET NULL: disconnect deletes the
--      credential, the account row stays as history), status connected | needs_attention | disconnected (the errata §2
--      wizard states; connected needs a credential), last_token_check_at. crm.guard_channel_account: the credential
--      is the same member's and its provider matches the kind (gmail <-> google, microsoft <-> microsoft, smtp <->
--      smtp), else SQLSTATE CRM30 mailbox_credential_mismatch. crm_app never deletes one.
--   3. crm.ingest_address (base template): the agency's forward-in address <local_part>@<CRM_INGEST_DOMAIN>,
--      local_part UNIQUE across agencies (<slug>-<random>), one active address per agency, the Gmail forwarding
--      confirmation code (mail DEK) and when it arrived. SELECT-only policy ingest_address_lookup TO crm_app keyed on
--      app.ingest_local_part, active and live rows only: set only by app.tenancy.ingest_tx() (the intake_form_public_lookup
--      pattern of crm-005). crm_app never deletes one (a new address deactivates the old).
--   4. crm.conversation (base template): traveler_id / trip_id (both NULL = Unmatched), channel email | whatsapp | sms
--      | messenger | ig (the last two reserved), external_thread_ref_hash, last_message_at. crm_app never deletes one
--      (trash + crm.erase_subject scope conversation).
--   5. crm.message (base template): one inbound or outbound message of a conversation. subject_enc, body_enc,
--      body_html_enc, from_enc, to_enc under the tenant mail DEK (pii:free_text / pii:contact), from_bidx (the sender's
--      blind index = the traveller e-mail blind index), attachments (crm.document ids) + attachment_notes (codes of the
--      attachments not kept), rfc_message_id_hash UNIQUE per agency (dedupe of BCC + forward and of a re-import),
--      rfc_message_id_enc (the Message-ID itself, for In-Reply-To on a reply), in_reply_to_hash, references_hashes,
--      external_id UNIQUE per agency and channel (the provider's id), match_method
--      (how the ingest threaded it), status received (inbound) or draft_autosaved -> queued -> sent | held_reconnect |
--      failed (outbound; crm.status_transition rows), sender_kind agency_mailbox | system (outbound only, errata
--      S247), channel_account_id, author_member_id, failure_code, imported, occurred_at, sent_at.
--      crm.guard_message (BEFORE DELETE OR UPDATE): crm_app deletes a draft only (CRM28 message_not_deletable); the
--      content of a message that is not a draft never changes (CRM29 message_sealed: subject, bodies, addresses,
--      attachments, direction); the hold rule 4h through its conversation (no delete, trash, content change or move of
--      a held conversation's message, CRM10).
--   6. crm.saved_reply (base template): title, body_enc (mail DEK), locale en | vi, member_id NULL = agency-wide.
--   7. crm.mail_import (base template; ids and counts only): one mbox / CSV history import by a member: source_kind,
--      size_bytes (<= 25 MB), status queued -> running -> done | failed, counts, error_code.
--   8. crm.trip.mail_token: a random 12-character token per trip (default from gen_random_uuid(), existing trips
--      filled by the default), UNIQUE per agency: the subject tag [ref:<token>] the send path writes and the ingest
--      threads a mail without References by (card E).
--   9. crm.dispatch_queue (crm-010): message_id, the crm.message the row sends (same-agency key, ON DELETE SET NULL;
--      NOT VALID + VALIDATE). message_ref stays the generic reference crm-012 uses for the Stage 2 link (a client_link
--      id, which is why the plan's FK on message_ref is not possible). gate_result adds held_reconnect (the mailbox is
--      disconnected, R24), send_failed (the provider refused the message for good) and no_message.
--  10. crm.document (crm-006): uploaded_by_kind adds mail (an attachment the ingest stored).
--  11. The hold rule and erasure (crm-010 items 4, 10) extended:
--      a. crm.erase_held, the crm-014 text plus: a trip erase also reaches the travellers its conversations name, a
--         traveller erase the trips theirs name; new scope conversation (its trip / traveller).
--      b. crm.erase_subject, the crm-014 text plus: trip and traveller scopes delete the messages of their
--         conversations, then the conversations; new scope conversation (its messages, then it: the trash purge of an
--         Unmatched conversation); the agency erase deletes messages, conversations, saved replies, imports, ingest
--         addresses and channel accounts. Without these steps every offboarding refuses with CRM16.
--      c. crm.guard_held_change (4h) on conversation (trip_id, traveler_id) and crm.guard_message on message.
--   No NOLOGIN reader gets anything on the new tables (support sees connection health only, errata §1 CRM-13b).
--   SQLSTATEs CRM28-CRM30 are this file's; the next key starts at CRM31.
--
-- Order: after crm-014 (AA-944); Guard 0 refuses to run before it is registered (erase_subject must build on the
-- crm-014 text).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); before the AA-945
-- code deploys nothing reads these objects, and the code merges only after this file is applied (S249 lesson).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-014 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-015: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-014') THEN
        RAISE EXCEPTION 'crm-015: crm-014 is not registered (CRM-16 ledger, AA-944, lands first)';
    END IF;
    IF to_regclass('crm.booking_line_money') IS NULL OR to_regclass('crm.dispatch_queue') IS NULL
       OR to_regprocedure('crm.erase_subject(text,uuid,uuid,boolean)') IS NULL
       OR to_regprocedure('crm.erase_held(text,uuid,uuid)') IS NULL
       OR to_regprocedure('crm.guard_held_change()') IS NULL THEN
        RAISE EXCEPTION 'crm-015: crm.booking_line_money (crm-014), crm.dispatch_queue or the crm-010 erase functions missing';
    END IF;
END $$;

-- ── 1. crm.integration_credential: one per provider and member ───────────────────────────────────
ALTER TABLE crm.integration_credential ADD COLUMN IF NOT EXISTS member_id UUID;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'crm.integration_credential'::regclass
                      AND conname = 'integration_credential_tenant_id_uq') THEN
        ALTER TABLE crm.integration_credential
            ADD CONSTRAINT integration_credential_tenant_id_uq UNIQUE (tenant_id, integration_credential_id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'crm.integration_credential'::regclass
                      AND conname = 'integration_credential_member_fk') THEN
        ALTER TABLE crm.integration_credential
            ADD CONSTRAINT integration_credential_member_fk FOREIGN KEY (tenant_id, member_id)
                REFERENCES crm.member (tenant_id, member_id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'crm.integration_credential'::regclass
                      AND conname = 'integration_credential_provider_member_uq') THEN
        ALTER TABLE crm.integration_credential
            ADD CONSTRAINT integration_credential_provider_member_uq
                UNIQUE NULLS NOT DISTINCT (tenant_id, provider, member_id);
    END IF;
END $$;
ALTER TABLE crm.integration_credential DROP CONSTRAINT IF EXISTS integration_credential_provider_uq;
CREATE INDEX IF NOT EXISTS integration_credential_member_idx ON crm.integration_credential (tenant_id, member_id)
    WHERE member_id IS NOT NULL;
COMMENT ON TABLE crm.integration_credential IS 'AA-934 (crm-003): an agency''s own vendor credential (errata S247, ADR 0010 decision 9). AA-945 (crm-015): one per provider and member (member_id NULL = agency-level; a member''s own mailbox otherwise, design §4.6). secret_enc is decrypted only in the dispatcher, webhook, mail send and health-check paths (AA-Partner lint); no route returns it. Disconnect deletes the row. Base template, FORCE RLS on app.tenant_id.';
COMMENT ON COLUMN crm.integration_credential.member_id IS 'AA-945 (crm-015): the member whose own account this is (a personal mailbox); NULL = the agency''s (owner-managed, INTEGRATIONS_MANAGE)';

-- ── 2. crm.channel_account ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.channel_account (
    channel_account_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                        REFERENCES crm.tenant (tenant_id),
    member_id           UUID,
    kind                TEXT NOT NULL,
    address_enc         BYTEA NOT NULL,
    address_bidx        BYTEA NOT NULL,
    credential_id       UUID,
    status              TEXT NOT NULL DEFAULT 'connected',
    last_token_check_at TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    deleted_by          TEXT,
    purge_after         TIMESTAMPTZ,
    CONSTRAINT channel_account_tenant_id_uq UNIQUE (tenant_id, channel_account_id),
    CONSTRAINT channel_account_member_uq UNIQUE NULLS NOT DISTINCT (tenant_id, member_id),
    CONSTRAINT channel_account_member_fk FOREIGN KEY (tenant_id, member_id) REFERENCES crm.member (tenant_id, member_id),
    CONSTRAINT channel_account_credential_fk FOREIGN KEY (tenant_id, credential_id)
        REFERENCES crm.integration_credential (tenant_id, integration_credential_id) ON DELETE SET NULL (credential_id),
    CONSTRAINT channel_account_kind_chk CHECK (kind IN ('gmail', 'microsoft', 'smtp')),
    CONSTRAINT channel_account_address_chk CHECK (octet_length(address_enc) >= 30 AND octet_length(address_bidx) = 16),
    CONSTRAINT channel_account_status_chk CHECK (status IN ('connected', 'needs_attention', 'disconnected')),
    CONSTRAINT channel_account_connected_chk CHECK (status <> 'connected' OR credential_id IS NOT NULL),
    CONSTRAINT channel_account_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS channel_account_credential_idx ON crm.channel_account (tenant_id, credential_id)
    WHERE credential_id IS NOT NULL;
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('channel_account', 'connected', 'needs_attention'),
    ('channel_account', 'connected', 'disconnected'),
    ('channel_account', 'needs_attention', 'connected'),
    ('channel_account', 'needs_attention', 'disconnected'),
    ('channel_account', 'disconnected', 'connected')
ON CONFLICT DO NOTHING;
REVOKE DELETE, TRUNCATE ON crm.channel_account FROM crm_app;
COMMENT ON TABLE crm.channel_account IS 'AA-945 (crm-015; design v3 group G, R24; errata S247 §1-2): a sending mailbox of the agency: a member''s own (member_id) or the agency-level one (member_id NULL, owner-managed). kind gmail | microsoft | smtp (send only, no IMAP); the secret lives in crm.integration_credential (credential_id). status follows the Connections wizard states: a disconnected mailbox holds every client message in held_reconnect (never sent through SES). crm_app never deletes one; erased with the agency.';
COMMENT ON COLUMN crm.channel_account.address_enc IS 'pii:contact; the mailbox address, AES-256-GCM under the tenant mail DEK (AAD tenant, channel_account, address_enc, row id)';
COMMENT ON COLUMN crm.channel_account.address_bidx IS 'blind index of the normalised mailbox address (the traveller e-mail blind index)';

-- ── 3. crm.ingest_address ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.ingest_address (
    ingest_address_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                   UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                                REFERENCES crm.tenant (tenant_id),
    local_part                  TEXT NOT NULL,
    active                      BOOLEAN NOT NULL DEFAULT true,
    forwarding_confirmation_enc BYTEA,
    forwarding_code_at          TIMESTAMPTZ,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                  TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at                  TIMESTAMPTZ,
    deleted_by                  TEXT,
    purge_after                 TIMESTAMPTZ,
    CONSTRAINT ingest_address_local_part_uq UNIQUE (local_part),
    CONSTRAINT ingest_address_local_part_chk CHECK (local_part ~ '^[a-z0-9][a-z0-9-]{6,62}[a-z0-9]$'),
    CONSTRAINT ingest_address_code_chk CHECK (
        coalesce(octet_length(forwarding_confirmation_enc), 30) >= 30
        AND (forwarding_confirmation_enc IS NULL) = (forwarding_code_at IS NULL)
    ),
    CONSTRAINT ingest_address_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS ingest_address_active_uq ON crm.ingest_address (tenant_id)
    WHERE active AND deleted_at IS NULL;
REVOKE DELETE, TRUNCATE ON crm.ingest_address FROM crm_app;
COMMENT ON TABLE crm.ingest_address IS 'AA-945 (crm-015; lane §6.5): the agency''s forward-in address <local_part>@<CRM_INGEST_DOMAIN> (local_part = <slug>-<random>, unique across agencies; one active per agency). Mail to it arrives through AA''s SES receipt rule (raw object <= 1 day under the ingest key), then the crm_mail_ingest job re-encrypts, threads and deletes it. ingest_address_lookup finds the active row of app.ingest_local_part (app.tenancy.ingest_tx). crm_app never deletes one; a new address deactivates the old.';
COMMENT ON COLUMN crm.ingest_address.forwarding_confirmation_enc IS 'conf:credential; the Gmail forwarding confirmation code captured by the ingest, AES-256-GCM under the tenant mail DEK, shown to the owner in Settings > Mailbox';

DROP POLICY IF EXISTS ingest_address_lookup ON crm.ingest_address;
CREATE POLICY ingest_address_lookup ON crm.ingest_address
    FOR SELECT TO crm_app
    USING (
        local_part = NULLIF(current_setting('app.ingest_local_part', true), '')
        AND active
        AND deleted_at IS NULL
    );
COMMENT ON POLICY ingest_address_lookup ON crm.ingest_address IS 'AA-945 (crm-015): the one active, live address whose local part the mail ingest was called with, only while app.ingest_local_part is set (app.tenancy.ingest_tx). SELECT only; same pattern as intake_form_public_lookup (crm-005).';

-- ── 4. crm.conversation ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.conversation (
    conversation_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                             REFERENCES crm.tenant (tenant_id),
    traveler_id              UUID,
    trip_id                  UUID,
    channel                  TEXT NOT NULL DEFAULT 'email',
    external_thread_ref_hash BYTEA,
    last_message_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by               TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at               TIMESTAMPTZ,
    deleted_by               TEXT,
    purge_after              TIMESTAMPTZ,
    CONSTRAINT conversation_tenant_id_uq UNIQUE (tenant_id, conversation_id),
    -- A NULL subject column skips its key (MATCH SIMPLE): both NULL = an Unmatched conversation.
    CONSTRAINT conversation_traveler_fk FOREIGN KEY (tenant_id, traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id),
    CONSTRAINT conversation_trip_fk FOREIGN KEY (tenant_id, trip_id) REFERENCES crm.trip (tenant_id, trip_id),
    CONSTRAINT conversation_channel_chk CHECK (channel IN ('email', 'whatsapp', 'sms', 'messenger', 'ig')),
    CONSTRAINT conversation_thread_ref_chk CHECK (coalesce(octet_length(external_thread_ref_hash), 32) = 32),
    CONSTRAINT conversation_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS conversation_trip_idx ON crm.conversation (tenant_id, trip_id, last_message_at DESC)
    WHERE trip_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS conversation_traveler_idx ON crm.conversation (traveler_id) WHERE traveler_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS conversation_unmatched_idx ON crm.conversation (tenant_id, last_message_at DESC)
    WHERE traveler_id IS NULL AND trip_id IS NULL AND deleted_at IS NULL;
REVOKE DELETE, TRUNCATE ON crm.conversation FROM crm_app;
COMMENT ON TABLE crm.conversation IS 'AA-945 (crm-015; design v3 group G, lane §2.8): one thread with a client on one channel (email now; whatsapp / sms with CRM-28; messenger / ig reserved). traveler_id and trip_id both NULL = Unmatched (the inbox the agent links from). No content here: the messages carry it. crm_app never deletes one; erasure through crm.erase_subject (scopes trip, traveler, conversation, tenant).';
COMMENT ON COLUMN crm.conversation.external_thread_ref_hash IS 'SHA-256 of a provider thread reference (a WhatsApp / SMS thread; e-mail threads by Message-ID hashes on crm.message)';

-- ── 5. crm.message ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.message (
    message_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                        REFERENCES crm.tenant (tenant_id),
    conversation_id     UUID NOT NULL,
    direction           TEXT NOT NULL,
    channel             TEXT NOT NULL DEFAULT 'email',
    status              TEXT NOT NULL DEFAULT 'draft_autosaved',
    sender_kind         TEXT,
    channel_account_id  UUID,
    author_member_id    UUID,
    subject_enc         BYTEA,
    body_enc            BYTEA,
    body_html_enc       BYTEA,
    from_enc            BYTEA,
    from_bidx           BYTEA,
    to_enc              BYTEA,
    attachments         UUID[] NOT NULL DEFAULT '{}',
    attachment_notes    TEXT[] NOT NULL DEFAULT '{}',
    rfc_message_id_hash BYTEA,
    rfc_message_id_enc  BYTEA,
    in_reply_to_hash    BYTEA,
    references_hashes   BYTEA[] NOT NULL DEFAULT '{}',
    external_id         TEXT,
    match_method        TEXT,
    failure_code        TEXT,
    imported            BOOLEAN NOT NULL DEFAULT false,
    occurred_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at             TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    deleted_by          TEXT,
    purge_after         TIMESTAMPTZ,
    CONSTRAINT message_tenant_id_uq UNIQUE (tenant_id, message_id),
    CONSTRAINT message_rfc_id_uq UNIQUE (tenant_id, rfc_message_id_hash),
    CONSTRAINT message_external_id_uq UNIQUE (tenant_id, channel, external_id),
    CONSTRAINT message_conversation_fk FOREIGN KEY (tenant_id, conversation_id)
        REFERENCES crm.conversation (tenant_id, conversation_id),
    CONSTRAINT message_channel_account_fk FOREIGN KEY (tenant_id, channel_account_id)
        REFERENCES crm.channel_account (tenant_id, channel_account_id) ON DELETE SET NULL (channel_account_id),
    CONSTRAINT message_author_fk FOREIGN KEY (tenant_id, author_member_id) REFERENCES crm.member (tenant_id, member_id),
    CONSTRAINT message_direction_chk CHECK (direction IN ('in', 'out')),
    CONSTRAINT message_channel_chk CHECK (channel IN ('email', 'whatsapp', 'sms')),
    CONSTRAINT message_status_chk CHECK (
        status IN ('received', 'draft_autosaved', 'queued', 'held_reconnect', 'sent', 'failed')
        AND (direction = 'in') = (status = 'received')
    ),
    -- errata S247 §1: allow_platform_sender is removed, so an outbound message leaves the agency's mailbox or is
    -- system mail; an inbound one has no sender kind.
    CONSTRAINT message_sender_kind_chk CHECK (
        (direction = 'in' AND sender_kind IS NULL)
        OR (direction = 'out' AND sender_kind IS NOT NULL AND sender_kind IN ('agency_mailbox', 'system'))
    ),
    CONSTRAINT message_enc_chk CHECK (
        coalesce(octet_length(subject_enc), 30) >= 30 AND coalesce(octet_length(body_enc), 30) >= 30
        AND coalesce(octet_length(body_html_enc), 30) >= 30 AND coalesce(octet_length(from_enc), 30) >= 30
        AND coalesce(octet_length(to_enc), 30) >= 30 AND coalesce(octet_length(rfc_message_id_enc), 30) >= 30
    ),
    CONSTRAINT message_bidx_chk CHECK (coalesce(octet_length(from_bidx), 16) = 16),
    CONSTRAINT message_hash_chk CHECK (
        coalesce(octet_length(rfc_message_id_hash), 32) = 32 AND coalesce(octet_length(in_reply_to_hash), 32) = 32
        AND cardinality(references_hashes) <= 100 AND array_position(references_hashes, NULL) IS NULL
    ),
    CONSTRAINT message_attachments_chk CHECK (
        cardinality(attachments) <= 50 AND array_position(attachments, NULL) IS NULL
        AND cardinality(attachment_notes) <= 50
        AND array_to_string(attachment_notes, ',') ~ '^([a-z][a-z0-9_]{1,40}(,[a-z][a-z0-9_]{1,40})*)?$'
    ),
    CONSTRAINT message_external_id_chk CHECK (
        external_id IS NULL OR (char_length(external_id) BETWEEN 1 AND 200 AND external_id !~ '[[:cntrl:][:space:]]')
    ),
    CONSTRAINT message_match_chk CHECK (
        match_method IS NULL OR match_method IN ('reply_header', 'trip_token', 'sender', 'manual', 'unmatched', 'compose')
    ),
    CONSTRAINT message_failure_chk CHECK (
        failure_code IS NULL OR (failure_code ~ '^[a-z][a-z0-9_]{1,40}$' AND status IN ('held_reconnect', 'failed'))
    ),
    CONSTRAINT message_sent_chk CHECK ((status = 'sent') = (sent_at IS NOT NULL)),
    CONSTRAINT message_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS message_conversation_idx ON crm.message (tenant_id, conversation_id, occurred_at);
CREATE INDEX IF NOT EXISTS message_held_idx ON crm.message (tenant_id, channel_account_id)
    WHERE status = 'held_reconnect';
CREATE INDEX IF NOT EXISTS message_from_idx ON crm.message (tenant_id, from_bidx) WHERE from_bidx IS NOT NULL;
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('message', 'draft_autosaved', 'queued'),
    -- Undo within the 10 s delay (Fix B8) gives the text back to the composer.
    ('message', 'queued', 'draft_autosaved'),
    ('message', 'queued', 'sent'),
    ('message', 'queued', 'held_reconnect'),
    ('message', 'queued', 'failed'),
    -- A reconnected mailbox re-queues; the agent may take a held message back to edit it.
    ('message', 'held_reconnect', 'queued'),
    ('message', 'held_reconnect', 'draft_autosaved'),
    ('message', 'held_reconnect', 'failed'),
    ('message', 'failed', 'queued'),
    ('message', 'failed', 'draft_autosaved')
ON CONFLICT DO NOTHING;
COMMENT ON TABLE crm.message IS 'AA-945 (crm-015; design v3 group G, R24, lane §2.8): one inbound or outbound message of a conversation. Content (subject, bodies, addresses) under the tenant mail DEK; HTML is rendered only in a sandboxed iframe (design S10). Outbound: draft_autosaved -> queued -> sent | held_reconnect | failed, sender_kind agency_mailbox | system (errata S247: no platform sender). Inbound: received. Threading: rfc_message_id_hash (unique per agency), in_reply_to_hash, references_hashes, the trip token. crm.guard_message: crm_app discards drafts only (CRM28) and never edits a message that is not a draft (CRM29). Erasure through crm.erase_subject.';
COMMENT ON COLUMN crm.message.subject_enc IS 'pii:free_text; AES-256-GCM under the tenant mail DEK (AAD tenant, message, subject_enc, row id)';
COMMENT ON COLUMN crm.message.body_enc IS 'pii:free_text; the text body, AES-256-GCM under the tenant mail DEK';
COMMENT ON COLUMN crm.message.body_html_enc IS 'pii:free_text; the HTML body when the mail had one, AES-256-GCM under the tenant mail DEK; rendered only in <iframe sandbox srcdoc>';
COMMENT ON COLUMN crm.message.from_enc IS 'pii:contact; the From address, AES-256-GCM under the tenant mail DEK';
COMMENT ON COLUMN crm.message.to_enc IS 'pii:contact; the To / Cc addresses (JSON list), AES-256-GCM under the tenant mail DEK';
COMMENT ON COLUMN crm.message.from_bidx IS 'blind index of the normalised From address (the traveller e-mail blind index): the ingest matches the sender to a client by it';
COMMENT ON COLUMN crm.message.rfc_message_id_hash IS 'SHA-256 of the normalised Message-ID (ours on a send, the sender''s on an inbound mail); unique per agency: a mail that arrives twice (BCC + forward, a re-import) is stored once';
COMMENT ON COLUMN crm.message.rfc_message_id_enc IS 'pii:contact; the Message-ID itself (it can name a mailbox or host), AES-256-GCM under the tenant mail DEK: a reply sets In-Reply-To / References to it so the client''s mail app threads it';
COMMENT ON COLUMN crm.message.attachments IS 'crm.document ids of the attachments kept (docs DEK; they carry the conversation''s trip / traveller)';
COMMENT ON COLUMN crm.message.attachment_notes IS 'codes of the attachments not kept (too_large, type_not_allowed, no_subject), shown as a note on the message';

-- ── 6. crm.saved_reply ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.saved_reply (
    saved_reply_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                   REFERENCES crm.tenant (tenant_id),
    member_id      UUID,
    locale         TEXT NOT NULL DEFAULT 'en',
    title          TEXT NOT NULL,
    body_enc       BYTEA NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by     TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at     TIMESTAMPTZ,
    deleted_by     TEXT,
    purge_after    TIMESTAMPTZ,
    CONSTRAINT saved_reply_member_fk FOREIGN KEY (tenant_id, member_id) REFERENCES crm.member (tenant_id, member_id),
    CONSTRAINT saved_reply_locale_chk CHECK (locale IN ('en', 'vi')),
    CONSTRAINT saved_reply_title_chk CHECK (char_length(btrim(title)) BETWEEN 1 AND 80 AND title !~ '[[:cntrl:]]'),
    CONSTRAINT saved_reply_body_chk CHECK (octet_length(body_enc) BETWEEN 30 AND 65536),
    CONSTRAINT saved_reply_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS saved_reply_tenant_idx ON crm.saved_reply (tenant_id, member_id, title)
    WHERE deleted_at IS NULL;
COMMENT ON TABLE crm.saved_reply IS 'AA-945 (crm-015; M5): a reusable reply text (title in clear, body under the tenant mail DEK), agency-wide (member_id NULL, owner-managed) or a member''s own. Deleted for good by its owner (agency text, no client data by design). Erased with the agency.';

COMMENT ON COLUMN crm.saved_reply.body_enc IS 'pii:free_text; the reply text (agents may write names into it), AES-256-GCM under the tenant mail DEK';

-- ── 7. crm.mail_import ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.mail_import (
    mail_import_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                    REFERENCES crm.tenant (tenant_id),
    member_id       UUID NOT NULL,
    source_kind     TEXT NOT NULL,
    size_bytes      BIGINT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'queued',
    total_count     INTEGER NOT NULL DEFAULT 0,
    imported_count  INTEGER NOT NULL DEFAULT 0,
    duplicate_count INTEGER NOT NULL DEFAULT 0,
    skipped_count   INTEGER NOT NULL DEFAULT 0,
    failed_count    INTEGER NOT NULL DEFAULT 0,
    error_code      TEXT,
    finished_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ,
    deleted_by      TEXT,
    purge_after     TIMESTAMPTZ,
    CONSTRAINT mail_import_member_fk FOREIGN KEY (tenant_id, member_id) REFERENCES crm.member (tenant_id, member_id),
    CONSTRAINT mail_import_source_chk CHECK (source_kind IN ('mbox', 'csv')),
    CONSTRAINT mail_import_size_chk CHECK (size_bytes BETWEEN 1 AND 26214400),
    CONSTRAINT mail_import_status_chk CHECK (status IN ('queued', 'running', 'done', 'failed')),
    CONSTRAINT mail_import_counts_chk CHECK (
        total_count >= 0 AND imported_count >= 0 AND duplicate_count >= 0 AND skipped_count >= 0 AND failed_count >= 0
    ),
    CONSTRAINT mail_import_error_chk CHECK (
        (error_code IS NULL OR error_code ~ '^[a-z][a-z0-9_]{1,40}$') AND (error_code IS NULL OR status = 'failed')
    ),
    CONSTRAINT mail_import_finished_chk CHECK ((status IN ('done', 'failed')) = (finished_at IS NOT NULL)),
    CONSTRAINT mail_import_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('mail_import', 'queued', 'running'),
    ('mail_import', 'queued', 'failed'),
    ('mail_import', 'running', 'done'),
    ('mail_import', 'running', 'failed')
ON CONFLICT DO NOTHING;
REVOKE DELETE, TRUNCATE ON crm.mail_import FROM crm_app;
COMMENT ON TABLE crm.mail_import IS 'AA-945 (crm-015; M5 history import): one mbox / CSV upload by a member (<= 25 MB, raw object under the ingest bucket imports/ prefix, deleted after the job, 1-day lifecycle as the backstop). Status and counts only: the imported mail lands in crm.message (imported = true). crm_app never deletes one; erased with the agency.';

-- ── 8. crm.trip.mail_token ───────────────────────────────────────────────────────────────────────
-- The default is volatile, so ADD COLUMN gives every existing trip its own token (one table rewrite, no trigger).
ALTER TABLE crm.trip ADD COLUMN IF NOT EXISTS mail_token TEXT NOT NULL
    DEFAULT substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
ALTER TABLE crm.trip DROP CONSTRAINT IF EXISTS trip_mail_token_chk;
ALTER TABLE crm.trip ADD CONSTRAINT trip_mail_token_chk CHECK (mail_token ~ '^[a-z0-9]{8,16}$');
CREATE UNIQUE INDEX IF NOT EXISTS trip_mail_token_uq ON crm.trip (tenant_id, mail_token);
COMMENT ON COLUMN crm.trip.mail_token IS 'AA-945 (crm-015, card E): the trip''s mail reference: every send writes [ref:<token>] in the subject and the ingest threads a mail without References by it. Random, unique per agency; not a secret (the client sees it)';

-- ── 9. crm.dispatch_queue: the message a row sends, and the mail gate codes ─────────────────────
ALTER TABLE crm.dispatch_queue ADD COLUMN IF NOT EXISTS message_id UUID;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'crm.dispatch_queue'::regclass AND conname = 'dispatch_queue_message_fk') THEN
        ALTER TABLE crm.dispatch_queue
            ADD CONSTRAINT dispatch_queue_message_fk FOREIGN KEY (tenant_id, message_id)
                REFERENCES crm.message (tenant_id, message_id) ON DELETE SET NULL (message_id) NOT VALID;
    END IF;
END $$;
ALTER TABLE crm.dispatch_queue VALIDATE CONSTRAINT dispatch_queue_message_fk;
CREATE INDEX IF NOT EXISTS dispatch_queue_message_idx ON crm.dispatch_queue (tenant_id, message_id)
    WHERE message_id IS NOT NULL;
ALTER TABLE crm.dispatch_queue DROP CONSTRAINT IF EXISTS dispatch_queue_gate_chk;
ALTER TABLE crm.dispatch_queue ADD CONSTRAINT dispatch_queue_gate_chk CHECK (
    (status = 'queued') = (gate_result IS NULL)
    AND (gate_result IS NULL OR gate_result IN (
        'sent', 'archived', 'traveler_trashed', 'trip_trashed', 'no_consent', 'no_sender', 'undone',
        'held_reconnect', 'send_failed', 'no_message'
    ))
    AND (status = 'queued') = (decided_at IS NULL)
);
COMMENT ON COLUMN crm.dispatch_queue.message_id IS 'AA-945 (crm-015): the crm.message this row sends (NULL for a row queued before CRM-17 or once the message is erased: such a row is held / no_message). message_ref stays the generic reference (crm-012: the Stage 2 client_link)';
COMMENT ON COLUMN crm.dispatch_queue.gate_result IS 'the decision code: sent, archived, traveler_trashed, trip_trashed, no_consent, no_sender, undone (crm-010); AA-945: held_reconnect (the sending mailbox is disconnected: held, re-queued on reconnect, never sent through SES), send_failed (the provider refused it for good), no_message (nothing to send)';

-- ── 10. crm.document: attachments stored by the mail ingest ──────────────────────────────────────
ALTER TABLE crm.document DROP CONSTRAINT IF EXISTS document_uploader_chk;
ALTER TABLE crm.document ADD CONSTRAINT document_uploader_chk
    CHECK (uploaded_by_kind IN ('member', 'traveler', 'aa_booking', 'mail'));

-- ── RLS + triggers on the new tenant tables ──────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['channel_account', 'ingest_address', 'conversation', 'message', 'saved_reply',
                             'mail_import'] LOOP
        EXECUTE format('ALTER TABLE crm.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE crm.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON crm.%I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON crm.%I '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)', t);
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON crm.%I FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at()',
            t || '_set_updated_at', t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['channel_account', 'message', 'mail_import'] LOOP
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE OF status ON crm.%I '
            'FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition()', t || '_status_transition', t);
    END LOOP;
    -- 11c. Hold rule 4h: a held conversation keeps its trip and traveller.
    EXECUTE 'DROP TRIGGER IF EXISTS conversation_hold_guard ON crm.conversation';
    EXECUTE 'CREATE TRIGGER conversation_hold_guard BEFORE DELETE OR UPDATE ON crm.conversation FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_held_change(''trip_id'', ''traveler_id'')';
END $$;

-- ── 2. The mailbox guard ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.guard_channel_account() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_provider text;
    v_member uuid;
BEGIN
    IF NEW.credential_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT c.provider, c.member_id INTO v_provider, v_member
      FROM crm.integration_credential c
     WHERE c.tenant_id = NEW.tenant_id AND c.integration_credential_id = NEW.credential_id;
    IF NOT FOUND THEN
        RETURN NEW;  -- the foreign key reports it
    END IF;
    IF v_member IS DISTINCT FROM NEW.member_id
       OR v_provider IS DISTINCT FROM (CASE NEW.kind WHEN 'gmail' THEN 'google' ELSE NEW.kind END) THEN
        RAISE EXCEPTION 'crm: mailbox_credential_mismatch (a mailbox uses its own member''s credential of its provider)'
            USING ERRCODE = 'CRM30';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_channel_account() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_channel_account() IS 'AA-945 (crm-015): a mailbox''s credential belongs to the same member (or both are agency-level) and its provider matches the kind (gmail <-> google, microsoft, smtp), else CRM30 mailbox_credential_mismatch.';
CREATE OR REPLACE TRIGGER channel_account_guard
    BEFORE INSERT OR UPDATE OF credential_id, member_id, kind ON crm.channel_account
    FOR EACH ROW EXECUTE FUNCTION crm.guard_channel_account();

-- ── 5. The message guard ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.guard_message() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_app boolean := current_user::text = 'crm_app';
    v_change text;
    v_trip uuid;
    v_traveler uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF v_app AND OLD.status <> 'draft_autosaved' THEN
            RAISE EXCEPTION 'crm: message_not_deletable (only a draft is discarded; % messages stay)', OLD.status
                USING ERRCODE = 'CRM28';
        END IF;
        v_change := 'delete';
    ELSE
        IF v_app AND OLD.status <> 'draft_autosaved' AND NEW.status <> 'draft_autosaved'
           AND (NEW.subject_enc IS DISTINCT FROM OLD.subject_enc OR NEW.body_enc IS DISTINCT FROM OLD.body_enc
                OR NEW.body_html_enc IS DISTINCT FROM OLD.body_html_enc OR NEW.from_enc IS DISTINCT FROM OLD.from_enc
                OR NEW.from_bidx IS DISTINCT FROM OLD.from_bidx OR NEW.to_enc IS DISTINCT FROM OLD.to_enc
                OR NEW.attachments IS DISTINCT FROM OLD.attachments OR NEW.direction IS DISTINCT FROM OLD.direction) THEN
            RAISE EXCEPTION 'crm: message_sealed (a % message keeps its content)', OLD.status USING ERRCODE = 'CRM29';
        END IF;
        IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
            v_change := 'trash';
        ELSIF NEW.conversation_id IS DISTINCT FROM OLD.conversation_id THEN
            v_change := 'conversation_id';
        ELSIF NEW.subject_enc IS DISTINCT FROM OLD.subject_enc OR NEW.body_enc IS DISTINCT FROM OLD.body_enc
              OR NEW.body_html_enc IS DISTINCT FROM OLD.body_html_enc OR NEW.attachments IS DISTINCT FROM OLD.attachments THEN
            v_change := 'content';
        END IF;
    END IF;
    -- Hold rule 4h through the conversation: its trip / traveller decide (4d).
    IF v_change IS NOT NULL AND EXISTS (SELECT 1 FROM crm.legal_hold h WHERE h.status = 'active') THEN
        SELECT c.trip_id, c.traveler_id INTO v_trip, v_traveler
          FROM crm.conversation c WHERE c.tenant_id = OLD.tenant_id AND c.conversation_id = OLD.conversation_id;
        IF crm.hold_row(v_trip, v_traveler) THEN
            RAISE EXCEPTION 'crm: legal_hold (% of a held message refused)', v_change USING ERRCODE = 'CRM10';
        END IF;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_message() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_message() IS 'AA-945 (crm-015): for crm_app, only a draft is deleted (CRM28 message_not_deletable) and a message that is not (and does not become) a draft keeps its content (CRM29 message_sealed); for every role, the hold rule 4h through the conversation''s trip / traveller: no delete, trash, content change or move of a held message (CRM10).';
CREATE OR REPLACE TRIGGER message_guard
    BEFORE DELETE OR UPDATE ON crm.message
    FOR EACH ROW EXECUTE FUNCTION crm.guard_message();

-- ── 11a. crm.erase_held (crm-010 hold rule 4e): the crm-014 text plus the mail scopes ───────────
CREATE OR REPLACE FUNCTION crm.erase_held(p_scope text, p_subject uuid, p_token uuid DEFAULT NULL) RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM crm.legal_hold h WHERE h.status = 'active') THEN
        RETURN false;  -- nothing is held in this agency
    END IF;
    IF p_scope = 'tenant' THEN
        RETURN true;  -- the agency erase reaches every subject: any active hold stops it
    END IF;
    IF p_subject IS NULL THEN
        RETURN crm.hold_row(NULL, NULL);
    END IF;
    IF p_scope = 'trip' THEN
        -- dispatch_queue, trip_commitment, document, note, task, trip_stage_history, trip_party, trip_traveler,
        -- client_link, meeting_slot, form_submission (trip_id := NULL), booking_line (and its money), conversation (and
        -- its messages, crm-015) and the trip: all carry trip_id = the trip (4d through hold_trip), and these name a
        -- traveller too.
        RETURN crm.hold_trip(p_subject) OR EXISTS (
            SELECT 1
              FROM (SELECT tt.traveler_id FROM crm.trip_traveler tt WHERE tt.trip_id = p_subject
                    UNION ALL
                    SELECT n.traveler_id FROM crm.note n WHERE n.trip_id = p_subject
                    UNION ALL
                    SELECT d.traveler_id FROM crm.document d WHERE d.trip_id = p_subject
                    UNION ALL
                    SELECT f.traveler_id FROM crm.form_submission f WHERE f.trip_id = p_subject
                    UNION ALL
                    SELECT q.traveler_id FROM crm.dispatch_queue q WHERE q.trip_id = p_subject
                    UNION ALL
                    SELECT l.traveler_id FROM crm.client_link l WHERE l.trip_id = p_subject
                    UNION ALL
                    SELECT m.traveler_id FROM crm.meeting_slot m WHERE m.trip_id = p_subject
                    UNION ALL
                    SELECT c.traveler_id FROM crm.conversation c WHERE c.trip_id = p_subject) x
             WHERE x.traveler_id IS NOT NULL AND crm.hold_traveler(x.traveler_id));
    ELSIF p_scope = 'traveler' THEN
        -- dispatch_queue, traveler_health, document, note, trip_traveler, consent, form_submission, client_link,
        -- conversation (and its messages, crm-015) and the traveller carry traveler_id = the traveller (4d through
        -- hold_traveler); trip_party / profile_history /
        -- traveler_profile are the traveller's own F2 rows (by token); these name a trip too; every relation from or
        -- to them (both rows); every client they referred (referrer_traveler_id := NULL rewrites that client's row);
        -- every call slot of theirs or booked by one of their submissions (it may name another traveller).
        RETURN crm.hold_traveler(p_subject)
            OR EXISTS (
                SELECT 1
                  FROM (SELECT tt.trip_id FROM crm.trip_traveler tt WHERE tt.traveler_id = p_subject
                        UNION ALL
                        SELECT n.trip_id FROM crm.note n WHERE n.traveler_id = p_subject
                        UNION ALL
                        SELECT d.trip_id FROM crm.document d WHERE d.traveler_id = p_subject
                        UNION ALL
                        SELECT f.trip_id FROM crm.form_submission f WHERE f.traveler_id = p_subject
                        UNION ALL
                        SELECT q.trip_id FROM crm.dispatch_queue q WHERE q.traveler_id = p_subject
                        UNION ALL
                        SELECT l.trip_id FROM crm.client_link l WHERE l.traveler_id = p_subject
                        UNION ALL
                        SELECT c.trip_id FROM crm.conversation c WHERE c.traveler_id = p_subject
                        UNION ALL
                        SELECT p.trip_id FROM crm.trip_party p
                         WHERE p_token IS NOT NULL AND p.traveler_token = p_token) x
                 WHERE x.trip_id IS NOT NULL AND crm.hold_trip(x.trip_id))
            OR EXISTS (
                SELECT 1 FROM crm.meeting_slot m
                 WHERE (m.traveler_id = p_subject
                        OR m.form_submission_id IN (SELECT s.submission_id FROM crm.form_submission s
                                                     WHERE s.traveler_id = p_subject))
                   AND crm.hold_row(m.trip_id, m.traveler_id))
            OR EXISTS (
                SELECT 1 FROM crm.traveler_relation rel
                 WHERE (rel.from_traveler_id = p_subject OR rel.to_traveler_id = p_subject)
                   AND (crm.hold_traveler(rel.from_traveler_id) OR crm.hold_traveler(rel.to_traveler_id)))
            OR EXISTS (
                SELECT 1 FROM crm.traveler t
                 WHERE t.referrer_traveler_id = p_subject AND crm.hold_traveler(t.traveler_id));
    ELSIF p_scope = 'task' THEN
        RETURN EXISTS (SELECT 1 FROM crm.task k WHERE k.task_id = p_subject AND crm.hold_trip(k.trip_id));
    ELSIF p_scope = 'note' THEN
        RETURN EXISTS (SELECT 1 FROM crm.note n WHERE n.note_id = p_subject AND crm.hold_row(n.trip_id, n.traveler_id));
    ELSIF p_scope = 'document' THEN
        RETURN EXISTS (SELECT 1 FROM crm.document d
                        WHERE d.document_id = p_subject AND crm.hold_row(d.trip_id, d.traveler_id));
    ELSIF p_scope = 'relation' THEN
        -- The row and its inverse (crm-006 mirrors the delete) have the same two ends.
        RETURN EXISTS (SELECT 1 FROM crm.traveler_relation rel
                        WHERE rel.relation_id = p_subject
                          AND (crm.hold_traveler(rel.from_traveler_id) OR crm.hold_traveler(rel.to_traveler_id)));
    ELSIF p_scope = 'booking_line' THEN
        -- crm-014: the line and its money carry the line's trip.
        RETURN EXISTS (SELECT 1 FROM crm.booking_line l
                        WHERE l.booking_line_id = p_subject AND crm.hold_trip(l.trip_id));
    ELSIF p_scope = 'conversation' THEN
        -- crm-015: the conversation and its messages carry the conversation's trip / traveller.
        RETURN EXISTS (SELECT 1 FROM crm.conversation c
                        WHERE c.conversation_id = p_subject AND crm.hold_row(c.trip_id, c.traveler_id));
    END IF;
    -- Subject-less data (llm_call, placeholder_map), agency_supplier (crm-014) and the agency's mail settings
    -- (crm-015: saved_reply, mail_import, ingest_address, channel_account; none names a trip or traveller): the agency
    -- hold only.
    RETURN crm.hold_row(NULL, NULL);
END;
$$;
REVOKE ALL ON FUNCTION crm.erase_held(text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.erase_held(text, uuid, uuid) TO crm_app;
COMMENT ON FUNCTION crm.erase_held(text, uuid, uuid) IS 'AA-942 (crm-010, hold rule 4e), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-944 (crm-014) to the scopes booking_line (its trip held) and agency_supplier (the agency hold) and by AA-945 (crm-015) to conversation / message (trip and traveller scopes, new scope conversation): true when crm.erase_subject(scope, subject, token) would delete or update a held row (every step''s rows, both rows of a relation, the clients a traveller referred, the submissions a trip unlinks, the call slots a traveller''s submissions booked); scope tenant: any active hold of the agency. crm.erase_subject refuses with CRM10 on it, dry run too. Invoker rights.';

-- ── 11b. crm.erase_subject: the crm-014 text plus the mail tables ────────────────────────────────
-- A later key that replaces it starts from THIS text.
CREATE OR REPLACE FUNCTION crm.erase_subject(p_scope text, p_subject uuid, p_profile_token uuid DEFAULT NULL,
                                             p_dry_run boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_counts jsonb := '{}'::jsonb;
    v_blockers text[];
    v_status text;
    v_has_token boolean;
    v_step text[];
    v_left text[] := '{}';
    r record;
    -- Tables an agency erase keeps: the agency row (status offboarded), the destroyed key rows, the audit and its
    -- export registry and chain (crm-007: they leave with the partition drops / the archive), the erasure receipts,
    -- the lifecycle counts and the holds (ids and codes only).
    c_keep CONSTANT text[] := ARRAY['tenant', 'tenant_key', 'audit_event', 'audit_export_tenant',
                                    'audit_export_manifest', 'erasure_request', 'lifecycle_run', 'legal_hold'];
BEGIN
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'crm: erase_subject needs app.tenant_id' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_dry_run IS NULL OR p_subject IS NULL THEN
        RAISE EXCEPTION 'crm: erase_subject needs a subject and dry_run true or false'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_scope NOT IN ('trip', 'traveler', 'task', 'note', 'document', 'relation', 'booking_line', 'agency_supplier',
                       'conversation', 'tenant') THEN
        RAISE EXCEPTION 'crm: erase_subject scope % is unknown', p_scope USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Hold rule 4g: serialise with hold placement. SHARE conflicts with the ROW EXCLUSIVE of an INSERT / UPDATE on
    -- crm.legal_hold: a hold placed now waits until this transaction ends; a hold being placed makes this wait, then
    -- the check below (a new snapshot: this function is VOLATILE) sees it.
    LOCK TABLE crm.legal_hold IN SHARE MODE;

    -- The subject must exist in this agency (FORCE RLS: crm_owner sees app.tenant_id's rows only).
    IF p_scope = 'trip' THEN
        -- FOR UPDATE: a row that would reference the subject (FOR KEY SHARE of its foreign key) waits until this erase
        -- ends, so nothing is attached to it between the hold check and the deletes (the hold guard triggers catch
        -- any other change).
        PERFORM 1 FROM crm.trip WHERE trip_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'traveler' THEN
        SELECT profile_token_enc IS NOT NULL INTO v_has_token FROM crm.traveler WHERE traveler_id = p_subject
           FOR UPDATE;
    ELSIF p_scope = 'task' THEN
        PERFORM 1 FROM crm.task WHERE task_id = p_subject;
    ELSIF p_scope = 'note' THEN
        PERFORM 1 FROM crm.note WHERE note_id = p_subject;
    ELSIF p_scope = 'document' THEN
        PERFORM 1 FROM crm.document WHERE document_id = p_subject;
    ELSIF p_scope = 'relation' THEN
        PERFORM 1 FROM crm.traveler_relation WHERE relation_id = p_subject;
    ELSIF p_scope = 'booking_line' THEN
        PERFORM 1 FROM crm.booking_line WHERE booking_line_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'agency_supplier' THEN
        SELECT kind INTO v_status FROM crm.agency_supplier WHERE agency_supplier_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'conversation' THEN
        PERFORM 1 FROM crm.conversation WHERE conversation_id = p_subject FOR UPDATE;
    ELSE
        IF p_subject <> v_tenant THEN
            RAISE EXCEPTION 'crm: subject_not_found (a tenant erase names the agency of app.tenant_id)'
                USING ERRCODE = 'CRM13';
        END IF;
        SELECT status INTO v_status FROM crm.tenant WHERE tenant_id = v_tenant;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (% %)', p_scope, p_subject USING ERRCODE = 'CRM13';
    END IF;

    -- Hold rule 4e: any held row among those this erase would delete or update refuses it, dry run included.
    IF crm.erase_held(p_scope, p_subject, p_profile_token) THEN
        RAISE EXCEPTION 'crm: legal_hold (an active legal hold reaches a row the erase of % % would change)',
            p_scope, p_subject USING ERRCODE = 'CRM10';
    END IF;

    IF p_scope = 'trip' THEN
        v_blockers := crm.trip_delete_blockers(p_subject);
        IF cardinality(v_blockers) > 0 THEN
            RAISE EXCEPTION 'crm: delete_blocked %', array_to_string(v_blockers, ',') USING ERRCODE = 'CRM11';
        END IF;
    ELSIF p_scope = 'traveler' THEN
        IF EXISTS (SELECT 1 FROM crm.trip_traveler tt JOIN crm.trip t ON t.trip_id = tt.trip_id
                    WHERE tt.traveler_id = p_subject AND t.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'crm: traveler_on_trip (delete or erase the client''s live trips first)'
                USING ERRCODE = 'CRM12';
        END IF;
        IF v_has_token AND p_profile_token IS NULL THEN
            RAISE EXCEPTION 'crm: profile_token_required' USING ERRCODE = 'CRM15';
        END IF;
        -- Consistency guard (the database cannot open the encrypted pointer; the caller decrypted it from this row,
        -- bound by its AAD): every party row of the token is the F2 twin of one of the traveller's own party rows
        -- (same trip, same role).
        IF p_profile_token IS NOT NULL AND EXISTS (
            SELECT 1 FROM crm.trip_party p
             WHERE p.traveler_token = p_profile_token
               AND NOT EXISTS (SELECT 1 FROM crm.trip_traveler tt
                                WHERE tt.trip_id = p.trip_id AND tt.traveler_id = p_subject AND tt.role = p.role)) THEN
            RAISE EXCEPTION 'crm: profile_token_mismatch' USING ERRCODE = 'CRM15';
        END IF;
    ELSIF p_scope = 'agency_supplier' THEN
        -- crm-014: the built-in Adventure Asia row leaves only with the agency; a supplier lines still name stays.
        IF v_status = 'aa' THEN
            RAISE EXCEPTION 'crm: aa_supplier_builtin (the Adventure Asia row leaves with the agency only)'
                USING ERRCODE = 'CRM22';
        END IF;
        IF EXISTS (SELECT 1 FROM crm.booking_line l WHERE l.agency_supplier_id = p_subject) THEN
            RAISE EXCEPTION 'crm: supplier_in_use (booking lines name this supplier)' USING ERRCODE = 'CRM27';
        END IF;
    ELSIF p_scope = 'tenant' AND NOT p_dry_run AND v_status <> 'offboarding' THEN
        -- A dry run (the counts the owner sees before confirming) works on an active agency.
        RAISE EXCEPTION 'crm: tenant_not_offboarding (status %)', v_status USING ERRCODE = 'CRM14';
    END IF;

    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', 'on', true);
    END IF;

    IF p_scope = 'trip' THEN
        -- crm-012: the trip's submissions let go of the trip and of its links first, then the links and slots go.
        -- crm-014: the trip's line money, then its lines. crm-015: the messages of its conversations, then those.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['form_submission', 'trip_id = $1', 'trip_id = NULL, client_link_id = NULL'],
            ['client_link', 'trip_id = $1', ''],
            ['meeting_slot', 'trip_id = $1', ''],
            ['dispatch_queue', 'trip_id = $1', ''],
            ['message', 'conversation_id IN (SELECT c.conversation_id FROM crm.conversation c WHERE c.trip_id = $1)', ''],
            ['conversation', 'trip_id = $1', ''],
            ['trip_commitment', 'trip_id = $1', ''],
            ['booking_line_money', 'booking_line_id IN (SELECT l.booking_line_id FROM crm.booking_line l '
                                   'WHERE l.trip_id = $1)', ''],
            ['booking_line', 'trip_id = $1', ''],
            ['document', 'trip_id = $1', ''],
            ['note', 'trip_id = $1', ''],
            ['task', 'trip_id = $1', ''],
            ['trip_stage_history', 'trip_id = $1', ''],
            ['trip_party', 'trip_id = $1', ''],
            ['trip_traveler', 'trip_id = $1', ''],
            ['trip', 'trip_id = $1', '']
        ] LOOP
            v_counts := v_counts || jsonb_build_object(
                v_step[1] || CASE WHEN v_step[3] <> '' THEN '_unlinked' ELSE '' END,
                crm.erase_rows(v_step[1], v_step[2], p_subject, NULL, p_dry_run, NULLIF(v_step[3], '')));
        END LOOP;
    ELSIF p_scope = 'traveler' THEN
        -- crm-012: their call slots (also those their submissions booked) before the submissions, their links after.
        -- crm-015: the messages of their conversations, then those.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['meeting_slot', 'traveler_id = $1 OR form_submission_id IN (SELECT s.submission_id '
                             'FROM crm.form_submission s WHERE s.traveler_id = $1)', ''],
            ['dispatch_queue', 'traveler_id = $1', ''],
            ['message', 'conversation_id IN (SELECT c.conversation_id FROM crm.conversation c '
                        'WHERE c.traveler_id = $1)', ''],
            ['conversation', 'traveler_id = $1', ''],
            ['traveler_health', 'traveler_id = $1', ''],
            ['document', 'traveler_id = $1', ''],
            ['note', 'traveler_id = $1', ''],
            ['traveler_relation', 'from_traveler_id = $1 OR to_traveler_id = $1', ''],
            ['trip_traveler', 'traveler_id = $1', ''],
            ['trip_party', 'traveler_token = $2', ''],
            ['profile_history', 'traveler_token = $2', ''],
            ['traveler_profile', 'traveler_token = $2', ''],
            ['consent', 'traveler_id = $1', ''],
            ['form_submission', 'traveler_id = $1', ''],
            ['client_link', 'traveler_id = $1', ''],
            ['traveler', 'referrer_traveler_id = $1', 'referrer_traveler_id = NULL'],
            ['traveler', 'traveler_id = $1', '']
        ] LOOP
            v_counts := v_counts || jsonb_build_object(
                v_step[1] || CASE WHEN v_step[3] <> '' THEN '_referrer_unlinked' ELSE '' END,
                crm.erase_rows(v_step[1], v_step[2], p_subject, p_profile_token, p_dry_run, NULLIF(v_step[3], '')));
        END LOOP;
    ELSIF p_scope IN ('task', 'note', 'document') THEN
        v_counts := jsonb_build_object(p_scope,
            crm.erase_rows(p_scope, p_scope || '_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'relation' THEN
        v_counts := jsonb_build_object('traveler_relation',
            crm.erase_rows('traveler_relation', 'relation_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'booking_line' THEN
        -- crm-014: the trash purge of a planning line: its money, then the line.
        v_counts := jsonb_build_object(
            'booking_line_money', crm.erase_rows('booking_line_money', 'booking_line_id = $1', p_subject, NULL, p_dry_run),
            'booking_line', crm.erase_rows('booking_line', 'booking_line_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'agency_supplier' THEN
        v_counts := jsonb_build_object('agency_supplier',
            crm.erase_rows('agency_supplier', 'agency_supplier_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'conversation' THEN
        -- crm-015: the trash purge of a conversation (an Unmatched one the agent deleted): its messages, then it. Kept
        -- attachments are documents of the trip / traveller and stay with them.
        v_counts := jsonb_build_object(
            'message', crm.erase_rows('message', 'conversation_id = $1', p_subject, NULL, p_dry_run),
            'conversation', crm.erase_rows('conversation', 'conversation_id = $1', p_subject, NULL, p_dry_run));
    ELSE
        -- The whole agency. Memberships are deleted as a platform action (crm-008 guard_member_write lets only an
        -- unscoped or platform context delete a member); the caller's actor is restored afterwards.
        PERFORM set_config('app.actor', 'platform:crm_offboarding', true);
        -- crm-013: the agency's CIS membership feed records (ids and codes) go first.
        -- crm-014: line money, lines and suppliers before the trips; the FX overrides before the members (set_by).
        -- crm-015: messages and conversations before the trips and travellers; saved replies, imports, the forward-in
        -- address and the mailboxes before the credentials and the members.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['membership_inbox', ''],
            ['dispatch_queue', ''], ['message', ''], ['conversation', ''],
            ['trip_commitment', ''], ['booking_line_money', ''], ['booking_line', ''],
            ['agency_supplier', ''], ['document', ''], ['traveler_health', ''],
            ['note', ''], ['task', ''], ['trip_stage_history', ''], ['trip_party', ''], ['trip_traveler', ''],
            ['traveler_relation', ''], ['consent', ''], ['meeting_slot', ''], ['form_submission', ''],
            ['client_link', ''], ['profile_history', ''],
            ['traveler_profile', ''], ['placeholder_map', 'optional'], ['llm_call', ''], ['trip', ''],
            ['traveler', 'unlink'], ['traveler', ''], ['intake_form', ''], ['form_definition', ''],
            ['saved_reply', ''], ['mail_import', ''], ['ingest_address', ''], ['channel_account', ''],
            ['integration_credential', ''], ['fx_rate_override', ''], ['tenant_settings', ''],
            ['member_invitation', 'optional'], ['owner_recovery_request', 'optional'],
            ['tenant_entitlement', 'optional'], ['member', '']
        ] LOOP
            CONTINUE WHEN v_step[2] = 'optional' AND to_regclass('crm.' || v_step[1]) IS NULL;
            IF v_step[2] = 'unlink' THEN
                v_counts := v_counts || jsonb_build_object('traveler_referrer_unlinked',
                    crm.erase_rows('traveler', 'referrer_traveler_id IS NOT NULL', p_subject, NULL, p_dry_run,
                                   'referrer_traveler_id = NULL'));
            ELSE
                v_counts := v_counts || jsonb_build_object(v_step[1],
                    crm.erase_rows(v_step[1], 'true', p_subject, NULL, p_dry_run));
            END IF;
        END LOOP;
        PERFORM set_config('app.actor', v_actor, true);
        -- Nothing of the agency may be left in a tenant table outside the keep list: a table added later that this
        -- function does not know fails the erase (rolled back) instead of keeping personal data silently.
        IF NOT p_dry_run THEN
            FOR r IN SELECT c.relname::text AS name
                       FROM pg_catalog.pg_class c
                       JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
                      WHERE c.relnamespace = 'crm'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
                        AND c.relname <> ALL (c_keep) AND c.relname NOT LIKE 'audit_event%'
                      ORDER BY 1 LOOP
                IF NOT (SELECT relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = ('crm.' || quote_ident(r.name))::regclass) THEN
                    v_left := v_left || r.name;  -- without FORCE RLS the owner would see every agency: refuse
                ELSE
                    EXECUTE format('SELECT EXISTS (SELECT 1 FROM crm.%I)', r.name) INTO v_has_token;
                    IF v_has_token THEN
                        v_left := v_left || r.name;
                    END IF;
                END IF;
            END LOOP;
            IF cardinality(v_left) > 0 THEN
                RAISE EXCEPTION 'crm: erase_incomplete (rows left in %)', array_to_string(v_left, ', ')
                    USING ERRCODE = 'CRM16';
            END IF;
        END IF;
    END IF;

    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', '', true);
    END IF;
    RETURN jsonb_build_object('scope', p_scope, 'dry_run', p_dry_run, 'counts', v_counts);
END;
$$;
REVOKE ALL ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) TO crm_eraser;
COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope), by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge) and by AA-945 (crm-015) to mail (trip, traveller and agency scopes: message, conversation; agency scope: saved_reply, mail_import, ingest_address, channel_account; new scope conversation for the trash purge): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, conversation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
BEGIN
    FOREACH t IN ARRAY ARRAY['crm.channel_account', 'crm.ingest_address', 'crm.conversation', 'crm.message',
                             'crm.saved_reply', 'crm.mail_import'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = t::regclass) THEN
            RAISE EXCEPTION 'crm-015: % must have ENABLE + FORCE row level security', t;
        END IF;
        -- Support sees connection health only (errata S247 §1 CRM-13b); no reader reaches mail.
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, t, p) THEN
                    RAISE EXCEPTION 'crm-015: reader % may % on %', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
        IF pg_catalog.has_table_privilege('crm_app', t, 'TRUNCATE')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'SELECT')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'INSERT')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'UPDATE') THEN
            RAISE EXCEPTION 'crm-015: crm_app must read and write % and never truncate it', t;
        END IF;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['crm.channel_account', 'crm.ingest_address', 'crm.conversation', 'crm.mail_import'] LOOP
        IF pg_catalog.has_table_privilege('crm_app', t, 'DELETE') THEN
            RAISE EXCEPTION 'crm-015: crm_app must never delete from % (erasure through crm.erase_subject)', t;
        END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy WHERE polrelid = 'crm.ingest_address'::regclass
                    AND polname = 'ingest_address_lookup' AND polpermissive AND polcmd = 'r'
                    AND polroles = ARRAY['crm_app'::regrole::oid]) THEN
        RAISE EXCEPTION 'crm-015: ingest_address_lookup must be a permissive SELECT policy TO crm_app';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-015: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                WHERE conrelid = 'crm.integration_credential'::regclass AND conname = 'integration_credential_provider_uq')
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                       WHERE conrelid = 'crm.integration_credential'::regclass
                         AND conname = 'integration_credential_provider_member_uq'
                         AND pg_catalog.pg_get_constraintdef(oid) LIKE 'UNIQUE NULLS NOT DISTINCT%') THEN
        RAISE EXCEPTION 'crm-015: crm.integration_credential is unique per (tenant, provider, member), NULLS NOT DISTINCT';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'crm.dispatch_queue'::regclass AND conname = 'dispatch_queue_message_fk'
                      AND convalidated) THEN
        RAISE EXCEPTION 'crm-015: crm.dispatch_queue.message_id must be a validated same-agency key to crm.message';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-015: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.guard_channel_account()', 'crm.guard_message()', 'crm.erase_held(text,uuid,uuid)',
                             'crm.erase_subject(text,uuid,uuid,boolean)'] LOOP
        IF pg_catalog.has_function_privilege('public', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-015: % is executable by PUBLIC (SEC-4)', t;
        END IF;
    END LOOP;
    -- Every table an earlier key taught erase_subject, and the mail tables of this one.
    FOREACH t IN ARRAY ARRAY['message', 'conversation', 'saved_reply', 'mail_import', 'ingest_address',
                             'channel_account', 'booking_line_money', 'booking_line', 'agency_supplier',
                             'fx_rate_override', 'membership_inbox', 'client_link', 'meeting_slot'] LOOP
        IF position(quote_literal(t) IN (SELECT prosrc FROM pg_catalog.pg_proc
                     WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
            RAISE EXCEPTION 'crm-015: crm.erase_subject does not erase crm.%', t;
        END IF;
    END LOOP;
    IF position('crm.conversation' IN (SELECT prosrc FROM pg_catalog.pg_proc
                 WHERE oid = 'crm.erase_held(text,uuid,uuid)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-015: crm.erase_held does not reach crm.conversation';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-015', now(), 'AA-945: CRM-17 Module 5 e-mail (integration_credential per member, channel_account, ingest_address + ingest_address_lookup, conversation, message with the mail-DEK content and held_reconnect, saved_reply, mail_import, trip.mail_token, dispatch_queue.message_id + mail gate codes, document uploaded_by mail, erase_subject + hold rule for the mail tables)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
