-- migrate: expand
-- Migration crm-073: AA-968 (design v3 §6.3 card CRM-36, R14 consent campaigns; A-15 Marketing, C-11 preferences) —
-- the agency's marketing campaigns, their recipients and the agency's unsubscribe (suppression) list.
--
-- Owner: AA-Partner (api/migrations/073_crm_campaigns.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- Migration Apply runs (Migration Copy Guard). Key crm-073 = crm main max + 1 at merge (crm-071 and crm-072 belong to
-- other lanes of the same wave); if main moves, renumber: file name, this header, the registration below,
-- app/db.py REQUIRED_SCHEMA_VERSIONS of the code PR and the tests that name it (git grep '073_' and 'crm-073').
--
-- What (DM-7.1: root data standards Part B §7 rows added with this key):
--   1. crm.campaign (base template): one marketing e-mail campaign of the agency. Sent only from one of the agency's
--      own mailboxes (channel_account_id: a crm.channel_account the agency connected, BYO errata S247; a snapshot
--      reference, checked by the app when the campaign is scheduled and on each send day). Subject and body are the
--      agency's text, sealed under the agency's mail DEK like a message template. The AA subject of the piece (root
--      ADR 0019 d21, the content gate without an LLM): aa_tour_ids (AA tours, crm.aa_catalog_tour source ids),
--      aa_content_id (an AA campaign block, crm.aa_content kind campaign_block, snapshot reference) or brand_only
--      (brand content with no sales call to action). gate_codes = the content gate's last refusal codes (empty when
--      it passed). audience_tags = client tag codes (crm.tag applies_to client; empty = every client).
--      state draft -> scheduled -> sending -> sent, scheduled | sending -> held (hold_code: the gate refused at send
--      time, an AA tour was retired, the feature was withdrawn, the mailbox is gone) -> scheduled again,
--      draft | scheduled | held -> cancelled. A ``state`` column, not ``status``: a status column needs
--      crm.status_transition rows (an INSERT into an existing table would make this file contract); the app moves
--      it forward with conditional UPDATEs. daily_limit = the mailbox daily send limit the plan used (the platform
--      setting crm.campaign.mailbox_daily_limit or the agency's own value, read when the campaign starts).
--      recipient_count / excluded = the plan's counts (excluded: counts per code, no ids). Cascades from the agency's
--      crm.tenant_settings row (the agency erase deletes it).
--   2. crm.campaign_recipient (base template): one client of one campaign. send_on = the day (agency timezone) the
--      plan put the client on (the spread over days when the list is over the mailbox daily limit). state planned ->
--      queued (message_id + dispatch_id: the crm.message and crm.dispatch_queue rows; the dispatcher's own gate
--      decides the send) | skipped (outcome_code: no consent any more, unsubscribed, archived, no e-mail, campaign
--      cancelled). unsubscribe_hash = the SHA-256 of the one-click unsubscribe token put into the mail (the token
--      itself is only in the sealed message and in unsubscribe_url_enc, the List-Unsubscribe URL the sender adds).
--      One row per campaign and client. Cascades from the campaign and from the client (the client and agency erases,
--      the trash purge delete the client).
--      SELECT-only policy campaign_recipient_unsubscribe_lookup TO crm_app keyed on app.campaign_unsubscribe_hash
--      (hex): set only by app.tenancy.campaign_unsubscribe_tx() (the client_link_token_lookup pattern of crm-012).
--   3. crm.campaign_suppression (base template; the app only inserts and deletes rows): the agency's do-not-mail list for marketing,
--      by the blind index of the e-mail (the traveller e-mail index, never the address). Written when a client
--      unsubscribes (reason unsubscribed; bounced / complained are kept for the bounce and complaint feeds of the
--      marketing configuration set, design §5.6). It names no client: a client deleted and imported again with a
--      marketing yes stays suppressed (card R), and only the client's own "subscribe again" on the preferences page
--      removes the row. Cascades from the agency's crm.tenant_settings row (the agency erase deletes it); the client
--      erase keeps it (an HMAC that cannot be reversed, kept to honour the opt-out).
--   4. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles); crm_app keeps the default DML of crm-001; no reader
--      grant (AI context, insights and support never read them).
--
-- Class: expand (root ADR 0017 d3): three new tables with their constraints, indexes, triggers, policies and comments;
-- the foreign keys are from the new tables only; no change to an existing object, no DO block, no CREATE OR REPLACE.
-- No crm.erase_subject change (every subject key cascades). Not re-runnable by itself (plain CREATE POLICY / TRIGGER);
-- Migration Apply never applies a registered key again and the test conftest skips it. Ships as a migration-only PR,
-- applied before the code PR (MIG-4 chain).
--
-- Rollback (a forward crm- file, after the code that writes them is reverted): DROP TABLE crm.campaign_recipient,
-- crm.campaign, crm.campaign_suppression.
--
-- Runs as crm_owner (Migration Apply switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- ── 1. crm.campaign ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.campaign (
    campaign_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                         REFERENCES crm.tenant (tenant_id),
    name                 TEXT NOT NULL,
    locale               TEXT NOT NULL DEFAULT 'en',
    subject_enc          BYTEA,
    body_enc             BYTEA,
    channel_account_id   UUID,
    aa_tour_ids          TEXT[] NOT NULL DEFAULT '{}',
    aa_content_id        UUID,
    brand_only           BOOLEAN NOT NULL DEFAULT false,
    audience_tags        TEXT[] NOT NULL DEFAULT '{}',
    state                TEXT NOT NULL DEFAULT 'draft',
    hold_code            TEXT,
    gate_codes           TEXT[] NOT NULL DEFAULT '{}',
    scheduled_at         TIMESTAMPTZ,
    started_at           TIMESTAMPTZ,
    finished_at          TIMESTAMPTZ,
    daily_limit          INTEGER,
    recipient_count      INTEGER NOT NULL DEFAULT 0,
    excluded             JSONB NOT NULL DEFAULT '{}',
    version              INTEGER NOT NULL DEFAULT 1,
    created_by_member_id UUID,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at           TIMESTAMPTZ,
    deleted_by           TEXT,
    purge_after          TIMESTAMPTZ,
    CONSTRAINT campaign_tenant_id_uq UNIQUE (tenant_id, campaign_id),
    CONSTRAINT campaign_settings_fk FOREIGN KEY (tenant_id)
        REFERENCES crm.tenant_settings (tenant_id) ON DELETE CASCADE,
    CONSTRAINT campaign_values_chk CHECK (
        char_length(btrim(name)) BETWEEN 1 AND 120 AND name !~ '[[:cntrl:]]'
        AND locale IN ('en', 'vi')
        AND COALESCE(octet_length(subject_enc), 30) >= 30
        AND COALESCE(octet_length(body_enc), 30) >= 30
        AND cardinality(aa_tour_ids) <= 20 AND array_position(aa_tour_ids, NULL) IS NULL
        AND cardinality(audience_tags) <= 20 AND array_position(audience_tags, NULL) IS NULL
        AND array_to_string(audience_tags, ',') ~ '^([a-z][a-z0-9_]{0,39}(,[a-z][a-z0-9_]{0,39})*)?$'
        AND cardinality(gate_codes) <= 20
        AND array_to_string(gate_codes, ',') ~ '^([a-z][a-z0-9_]{1,40}(,[a-z][a-z0-9_]{1,40})*)?$'
        AND (daily_limit IS NULL OR daily_limit BETWEEN 1 AND 100000)
        AND recipient_count >= 0 AND version >= 1
        AND jsonb_typeof(excluded) = 'object'
    ),
    CONSTRAINT campaign_state_chk CHECK (
        state IN ('draft', 'scheduled', 'sending', 'held', 'sent', 'cancelled')
    ),
    CONSTRAINT campaign_hold_chk CHECK (
        ((state = 'held') = (hold_code IS NOT NULL))
        AND (hold_code IS NULL OR hold_code ~ '^[a-z][a-z0-9_]{1,40}$')
    ),
    CONSTRAINT campaign_schedule_chk CHECK (
        (state = 'draft' OR state = 'cancelled' OR scheduled_at IS NOT NULL)
        AND (state <> 'sent' OR finished_at IS NOT NULL)
    ),
    CONSTRAINT campaign_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
-- The tick's work list: the agency's campaigns that may send.
CREATE INDEX IF NOT EXISTS campaign_live_idx ON crm.campaign (tenant_id, state, scheduled_at)
    WHERE state IN ('scheduled', 'sending') AND deleted_at IS NULL;
-- The retired-tour pull: the campaigns that name an AA tour.
CREATE INDEX IF NOT EXISTS campaign_tours_idx ON crm.campaign USING gin (aa_tour_ids)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS campaign_list_idx ON crm.campaign (tenant_id, created_at DESC)
    WHERE deleted_at IS NULL;
ALTER TABLE crm.campaign ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.campaign FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.campaign
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER campaign_set_updated_at
    BEFORE UPDATE ON crm.campaign
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
COMMENT ON TABLE crm.campaign IS 'AA-968 (crm-073, card CRM-36, R14): one marketing e-mail campaign of the agency, sent only from one of its own mailboxes (BYO). The AA subject (root ADR 0019 d21): aa_tour_ids, aa_content_id or brand_only; gate_codes = the content gate''s last refusal. state draft -> scheduled -> sending -> sent, held (hold_code) -> scheduled, cancelled. Cascades from the agency''s tenant_settings row. No reader grant.';
COMMENT ON COLUMN crm.campaign.name IS 'the agency''s internal name of the campaign (1..120 characters; never shown to clients)';
COMMENT ON COLUMN crm.campaign.subject_enc IS 'pii:free_text; the mail subject, AES-GCM under the agency mail DEK (merge fields allowed)';
COMMENT ON COLUMN crm.campaign.body_enc IS 'pii:free_text; the mail text, AES-GCM under the agency mail DEK (merge fields allowed)';
COMMENT ON COLUMN crm.campaign.channel_account_id IS 'the agency''s own sending mailbox (crm.channel_account, snapshot reference checked by the app; never AA''s mail)';
COMMENT ON COLUMN crm.campaign.aa_tour_ids IS 'the AA tours the campaign is about (crm.aa_catalog_tour source ids, source_system cis); a retired one holds the campaign';
COMMENT ON COLUMN crm.campaign.aa_content_id IS 'the AA campaign block the text started from (crm.aa_content kind campaign_block; snapshot reference)';
COMMENT ON COLUMN crm.campaign.brand_only IS 'brand content with no sales call to action (d21): no link to a tour page or a planner allowed';
COMMENT ON COLUMN crm.campaign.audience_tags IS 'client tag codes (crm.tag applies_to client) a recipient carries at least one of; empty = every client';
COMMENT ON COLUMN crm.campaign.hold_code IS 'why a held campaign stopped: content_gate | aa_tour_retired | feature_off | no_mailbox';
COMMENT ON COLUMN crm.campaign.gate_codes IS 'the d21 content gate''s refusal codes at the last check (empty = passed)';
COMMENT ON COLUMN crm.campaign.daily_limit IS 'the mailbox daily send limit the plan used (setting crm.campaign.mailbox_daily_limit, platform or the agency''s own value)';
COMMENT ON COLUMN crm.campaign.excluded IS 'the plan''s left-out clients, counts per code (no_consent, suppressed, no_email, over_cap); no ids';

-- ── 2. crm.campaign_recipient ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.campaign_recipient (
    campaign_recipient_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                          REFERENCES crm.tenant (tenant_id),
    campaign_id           UUID NOT NULL,
    traveler_id           UUID NOT NULL,
    send_on               DATE NOT NULL,
    state                 TEXT NOT NULL DEFAULT 'planned',
    outcome_code          TEXT,
    message_id            UUID,
    dispatch_id           UUID,
    unsubscribe_hash      BYTEA,
    unsubscribe_url_enc   BYTEA,
    queued_at             TIMESTAMPTZ,
    unsubscribed_at       TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at            TIMESTAMPTZ,
    deleted_by            TEXT,
    purge_after           TIMESTAMPTZ,
    CONSTRAINT campaign_recipient_tenant_id_uq UNIQUE (tenant_id, campaign_recipient_id),
    CONSTRAINT campaign_recipient_once_uq UNIQUE (tenant_id, campaign_id, traveler_id),
    CONSTRAINT campaign_recipient_campaign_fk FOREIGN KEY (tenant_id, campaign_id)
        REFERENCES crm.campaign (tenant_id, campaign_id) ON DELETE CASCADE,
    CONSTRAINT campaign_recipient_traveler_fk FOREIGN KEY (tenant_id, traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id) ON DELETE CASCADE,
    CONSTRAINT campaign_recipient_state_chk CHECK (state IN ('planned', 'queued', 'skipped')),
    CONSTRAINT campaign_recipient_outcome_chk CHECK (
        ((state = 'skipped') = (outcome_code IS NOT NULL))
        AND (outcome_code IS NULL OR outcome_code ~ '^[a-z][a-z0-9_]{1,40}$')
    ),
    CONSTRAINT campaign_recipient_queued_chk CHECK (
        ((state = 'queued') = (message_id IS NOT NULL))
        AND ((state = 'queued') = (queued_at IS NOT NULL))
        AND ((message_id IS NULL) = (unsubscribe_hash IS NULL))
        AND ((unsubscribe_hash IS NULL) = (unsubscribe_url_enc IS NULL))
        AND COALESCE(octet_length(unsubscribe_hash), 32) = 32
        AND COALESCE(octet_length(unsubscribe_url_enc), 30) >= 30
    ),
    CONSTRAINT campaign_recipient_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
-- One live token per mail (the public unsubscribe route finds the row by it).
CREATE UNIQUE INDEX IF NOT EXISTS campaign_recipient_unsubscribe_uq ON crm.campaign_recipient (unsubscribe_hash)
    WHERE unsubscribe_hash IS NOT NULL;
-- The send day's work list and the mailbox's daily count.
CREATE INDEX IF NOT EXISTS campaign_recipient_day_idx ON crm.campaign_recipient (tenant_id, campaign_id, send_on)
    WHERE state = 'planned' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS campaign_recipient_send_on_idx ON crm.campaign_recipient (tenant_id, send_on)
    WHERE state IN ('planned', 'queued') AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS campaign_recipient_traveler_idx ON crm.campaign_recipient (tenant_id, traveler_id);
-- The sender's read: the List-Unsubscribe URL of the message it is sending.
CREATE INDEX IF NOT EXISTS campaign_recipient_message_idx ON crm.campaign_recipient (tenant_id, message_id)
    WHERE message_id IS NOT NULL;
ALTER TABLE crm.campaign_recipient ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.campaign_recipient FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.campaign_recipient
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE POLICY campaign_recipient_unsubscribe_lookup ON crm.campaign_recipient
    FOR SELECT TO crm_app
    USING (
        unsubscribe_hash = decode(NULLIF(current_setting('app.campaign_unsubscribe_hash', true), ''), 'hex')
        AND deleted_at IS NULL
    );
CREATE TRIGGER campaign_recipient_set_updated_at
    BEFORE UPDATE ON crm.campaign_recipient
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
COMMENT ON TABLE crm.campaign_recipient IS 'AA-968 (crm-073, card CRM-36): one client of one campaign. send_on = the planned day (agency timezone; the spread over days when the list is over the mailbox daily limit). state planned -> queued (message_id, dispatch_id; the dispatcher gate decides the send) | skipped (outcome_code). unsubscribe_hash = SHA-256 of the one-click token in the mail. One per campaign and client. Cascades from the campaign and the client. campaign_recipient_unsubscribe_lookup (SELECT only) finds one row by its token hash for app.tenancy.campaign_unsubscribe_tx.';
COMMENT ON COLUMN crm.campaign_recipient.send_on IS 'the day (agency timezone) the plan put this client on; the mailbox sends at most its daily limit a day';
COMMENT ON COLUMN crm.campaign_recipient.outcome_code IS 'why a skipped client got nothing: no_consent | suppressed | archived | no_email | cancelled | not_found';
COMMENT ON COLUMN crm.campaign_recipient.message_id IS 'the crm.message queued for this client (snapshot reference)';
COMMENT ON COLUMN crm.campaign_recipient.dispatch_id IS 'its crm.dispatch_queue row (snapshot reference; the gate result is there)';
COMMENT ON COLUMN crm.campaign_recipient.unsubscribe_hash IS 'conf:credential; SHA-256 of the one-click unsubscribe token (never the token)';
COMMENT ON COLUMN crm.campaign_recipient.unsubscribe_url_enc IS 'conf:credential; the List-Unsubscribe URL (with the token), AES-GCM under the agency mail DEK, read by the sender only';
COMMENT ON POLICY campaign_recipient_unsubscribe_lookup ON crm.campaign_recipient IS 'AA-968 (crm-073): the one live recipient row whose unsubscribe token hash the public unsubscribe route was called with, only while app.campaign_unsubscribe_hash is set (app.tenancy.campaign_unsubscribe_tx). SELECT only; the client_link_token_lookup pattern (crm-012).';

-- ── 3. crm.campaign_suppression ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.campaign_suppression (
    campaign_suppression_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                            REFERENCES crm.tenant (tenant_id),
    email_bidx              BYTEA NOT NULL,
    reason                  TEXT NOT NULL,
    campaign_id             UUID,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at              TIMESTAMPTZ,
    deleted_by              TEXT,
    purge_after             TIMESTAMPTZ,
    CONSTRAINT campaign_suppression_tenant_id_uq UNIQUE (tenant_id, campaign_suppression_id),
    CONSTRAINT campaign_suppression_once_uq UNIQUE (tenant_id, email_bidx),
    CONSTRAINT campaign_suppression_settings_fk FOREIGN KEY (tenant_id)
        REFERENCES crm.tenant_settings (tenant_id) ON DELETE CASCADE,
    CONSTRAINT campaign_suppression_values_chk CHECK (
        octet_length(email_bidx) = 16 AND reason IN ('unsubscribed', 'bounced', 'complained')
    ),
    CONSTRAINT campaign_suppression_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
ALTER TABLE crm.campaign_suppression ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.campaign_suppression FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.campaign_suppression
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER campaign_suppression_set_updated_at
    BEFORE UPDATE ON crm.campaign_suppression
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
COMMENT ON TABLE crm.campaign_suppression IS 'AA-968 (crm-073, card CRM-36 R "an unsubscribed contact re-imported stays suppressed"): the agency''s do-not-mail list for marketing by e-mail blind index (never the address, never a client id). reason unsubscribed (the client''s own click) | bounced | complained (the marketing feeds, design §5.6). Only the client''s own "subscribe again" removes a row. Cascades from the agency''s tenant_settings row; the client erase keeps it (a one-way HMAC, kept to honour the opt-out). No reader grant.';
COMMENT ON COLUMN crm.campaign_suppression.email_bidx IS 'pii:contact; the blind index (HMAC) of the e-mail, the traveller e-mail index of the agency';
COMMENT ON COLUMN crm.campaign_suppression.campaign_id IS 'the campaign whose mail the client unsubscribed from (snapshot reference; NULL for a feed)';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-073', now(), 'AA-968 CRM-36 campaigns: crm.campaign (BYO mailbox, d21 AA subject, state draft -> scheduled -> sending -> sent / held / cancelled), crm.campaign_recipient (send_on spread, unsubscribe token hash + lookup policy), crm.campaign_suppression (do-not-mail by e-mail blind index); cascades only, no erase_subject change')
ON CONFLICT (version) DO NOTHING;

COMMIT;
