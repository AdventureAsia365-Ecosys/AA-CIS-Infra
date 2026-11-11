-- Migration crm-056: AA-1071 (S275 study of a tour and travel app, root docs/research/2026-11-10-odoo-tour-travel-
-- plugin-comparison.md, items crm-28 and crm-29; behaviour only, no plugin code) — sales partners: the sub-agents,
-- referrers, freelancers and online agencies that bring the agency clients, the commission the agency owes them per
-- booked trip (a cost in the trip P&L), and the partner's own signed links: an intake link that stamps the partner on
-- the inquiry it sends, and a light view (signed link + e-mail code) of the trips it referred.
--
-- Owner: AA-Partner (api/migrations/056_crm_sales_partners.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-056: crm-055 is the highest on main; if main moves, renumber: file
-- name, this header, Guard 0, the post-checks, the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS and the tests
-- that name it (git grep '056_' and 'crm-056').
--
-- What:
--   1. crm.sales_partner (base template): kind sub_agent | referrer | freelancer | ota; name, contact e-mail and phone
--      under the vault DEK (pii:contact); commission_type percent | fixed_per_pax | net_rate, rate (a percent 0..100,
--      or an amount per traveller in the partner's currency), basis revenue | margin (percent and net_rate),
--      payout_due_days 0..365 (default 30), status active <-> inactive. Cascades from the agency's crm.tenant_settings
--      row (the agency erase deletes it). Only an owner writes it (guard CRM54).
--   2. crm.trip.sales_partner_id (+ index): the partner that brought the trip; a key on (tenant_id, sales_partner_id),
--      so a trip names a partner of its own agency only. crm.form_submission.sales_partner_id (no key): the partner
--      whose intake link sent the inquiry; crm_intake_process copies it onto the trip it creates.
--   3. crm.partner_commission (base template): what the agency owes one partner for one booked trip: a snapshot of the
--      partner's terms (type, rate, basis), basis_amount (the accepted proposal total, the trip margin before partner
--      commissions, or the pax of a per-traveller rate), amount + currency, the base-currency amount frozen at the day
--      it was computed (crm.fx_resolve; NULL without a rate), due_on (trip end, else start, + payout_due_days).
--      Status accrued -> approved -> paid; approved -> accrued (un-approve); accrued | approved -> cancelled. Written
--      only by crm.partner_commission_sync (SECURITY DEFINER; the assistant may move a trip to booked but reads no
--      money); crm_app reads it as owner / agent (RESTRICTIVE partner_commission_margin_roles) and updates only the
--      follow-up columns. Guard CRM54: the identity and the amounts never change outside the sync; approve,
--      un-approve, pay and an owner's cancel are the owner's; the cancel of a trip cancel (reason trip_cancelled) is
--      the owner's or an agent's; a paid or cancelled row is sealed. Cascades from its trip and its partner (no hold
--      guard: crm.erase_subject refuses a held trip first); an approved or paid row whose trip remains is never
--      deleted by its partner's delete (partner_commission_kept: the payout record stays; the API refuses the delete
--      first, partner_in_use).
--   4. crm.partner_commission_sync(trip): accrued rows that no longer apply are cancelled (the trip left the booked
--      stages: unbooked; its partner was removed / changed); a booked trip (booked, pre_departure, travelling,
--      completed) with a partner gets one accrued row for that partner, refreshed while it is accrued; an approved or
--      paid row is never touched; a cancelled trip is left to the cancel run (it keeps or cancels the rows). A row the
--      owner cancelled (by_owner) or a trip cancel cancelled (trip_cancelled) is a waiver: no new row for that trip and
--      partner until the trip leaves the booked stages (a crm.trip_stage_history move out of them after the waiver),
--      so a later stage move, a trash / restore or a Recalculate never brings the commission back.
--      Trigger trip_partner_commission_sync (AFTER UPDATE OF stage, sales_partner_id ON crm.trip) runs it on every
--      move and every partner change, whatever path made it (stage moves, the deposit, Undo, the bulk move).
--   5. crm.sales_partner_link (base template): one signed link per partner and purpose (intake: the agency's inquiry
--      form for that partner, intake_form_id; view: the partner's trip list), the token's SHA-256 only, active ->
--      revoked, expires within 400 days, use counters. SELECT-only lookup policy sales_partner_link_token_lookup on
--      app.partner_link_hash (TO crm_app, live links only), the way client_link is found. crm_app no DELETE.
--   6. crm.sales_partner_otp (base template): the view's e-mail sign-in code (code hash, 10 minutes, 5 attempts; the
--      code itself under the vault DEK only until the mail sender sent it) and the 12 h session it opens (hash only).
--      pending -> verified | expired | failed; verified -> expired. Purged 24 h after it was made (crm_stage_rules).
--   7. The code mail goes out from the agency's mailbox like the traveller's: crm.conversation.sales_partner_id (a
--      partner's e-mail thread: no trip, no client, no supplier, channel email; one live per partner) and
--      crm.dispatch_queue.sales_partner_id with traveler_id now nullable (exactly one of the two; a partner row is a
--      transactional e-mail without a trip; gate code partner_inactive once the partner is inactive or trashed).
--   8. crm.v_trip_pnl: sales_partner_id = the trip's, partner_commission_base = its live (accrued, approved, paid)
--      partner commissions in the agency's base currency now (the crm-051 seam, 0 until this key). Same columns.
--
-- Behaviour on apply: no partner exists until the code PR deploys, so every trip keeps a NULL partner, no commission
-- row is written and the P&L does not change. The trip trigger does nothing for a trip without a partner.
--
-- Class: contract (ALTERs of crm.trip, crm.form_submission, crm.conversation and crm.dispatch_queue, a new trigger on
-- crm.trip, rows in crm.status_transition, a replaced view). MIG-4: this migration-only PR, applied on Dev by Infra
-- Migration Apply once every job table is idle, then the code PR. DM-7.1: root data standards Part B §7 rows for the
-- four new tables come with this key. Erasure by cascade (no crm.erase_subject change): crm.sales_partner from
-- crm.tenant_settings, the link / code / commission rows from their partner, a commission from its trip too, a link
-- from its intake form; the partner's conversation and dispatch rows leave with the agency (no trip, no client).
--
-- Rollback (a NEW forward migration, after the code is reverted): restore the crm-051 view text; DROP TRIGGER
-- trip_partner_commission_sync ON crm.trip; DROP FUNCTION crm.trip_partner_commission(), crm.partner_commission_sync(uuid),
-- crm.guard_sales_partner(); delete the partner dispatch / conversation rows, then ALTER TABLE crm.dispatch_queue DROP
-- COLUMN sales_partner_id, ALTER traveler_id SET NOT NULL; ALTER TABLE crm.conversation DROP COLUMN sales_partner_id;
-- DROP TABLE crm.sales_partner_otp, crm.sales_partner_link, crm.partner_commission; ALTER TABLE crm.trip DROP COLUMN
-- sales_partner_id; ALTER TABLE crm.form_submission DROP COLUMN sales_partner_id; DROP TABLE crm.sales_partner;
-- DELETE FROM crm.status_transition WHERE table_name IN ('sales_partner', 'partner_commission', 'sales_partner_link',
-- 'sales_partner_otp').
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
        RAISE EXCEPTION 'crm-056: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-055') THEN
        RAISE EXCEPTION 'crm-056: crm-055 (AA-1070) lands first';
    END IF;
    IF to_regclass('crm.v_trip_pnl') IS NULL OR to_regclass('crm.dispatch_queue') IS NULL
       OR to_regclass('crm.conversation') IS NULL OR to_regclass('crm.form_submission') IS NULL
       OR to_regprocedure('crm.fx_resolve(text, text, date)') IS NULL
       OR to_regprocedure('crm.enforce_status_transition()') IS NULL THEN
        RAISE EXCEPTION 'crm-056: the trip P&L (crm-051), the mail tables (crm-015) or crm.fx_resolve missing';
    END IF;
END $$;

-- ── 1. crm.sales_partner ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.sales_partner (
    sales_partner_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                      REFERENCES crm.tenant (tenant_id),
    kind              TEXT NOT NULL,
    name_enc          BYTEA NOT NULL,
    contact_email_enc BYTEA,
    contact_phone_enc BYTEA,
    commission_type   TEXT NOT NULL DEFAULT 'percent',
    rate              NUMERIC(12,2) NOT NULL DEFAULT 0,
    currency          CHARACTER(3),
    basis             TEXT NOT NULL DEFAULT 'revenue',
    payout_due_days   SMALLINT NOT NULL DEFAULT 30,
    status            TEXT NOT NULL DEFAULT 'active',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,
    deleted_by        TEXT,
    purge_after       TIMESTAMPTZ,
    CONSTRAINT sales_partner_tenant_id_uq UNIQUE (tenant_id, sales_partner_id),
    CONSTRAINT sales_partner_settings_fk FOREIGN KEY (tenant_id)
        REFERENCES crm.tenant_settings (tenant_id) ON DELETE CASCADE,
    CONSTRAINT sales_partner_kind_chk CHECK (kind IN ('sub_agent', 'referrer', 'freelancer', 'ota')),
    CONSTRAINT sales_partner_terms_chk CHECK (
        commission_type IN ('percent', 'fixed_per_pax', 'net_rate')
        AND basis IN ('revenue', 'margin')
        AND rate >= 0
        AND (commission_type = 'fixed_per_pax' OR rate <= 100)
        AND ((commission_type = 'fixed_per_pax') = (currency IS NOT NULL))
        AND (currency IS NULL OR currency ~ '^[A-Z]{3}$')
        AND payout_due_days BETWEEN 0 AND 365
    ),
    CONSTRAINT sales_partner_sealed_chk CHECK (
        octet_length(name_enc) BETWEEN 29 AND 2048
        AND COALESCE(octet_length(contact_email_enc), 29) BETWEEN 29 AND 2048
        AND COALESCE(octet_length(contact_phone_enc), 29) BETWEEN 29 AND 2048
    ),
    CONSTRAINT sales_partner_status_chk CHECK (status IN ('active', 'inactive')),
    CONSTRAINT sales_partner_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS sales_partner_list_idx ON crm.sales_partner (tenant_id, status) WHERE deleted_at IS NULL;

ALTER TABLE crm.sales_partner ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.sales_partner FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.sales_partner;
CREATE POLICY tenant_isolation ON crm.sales_partner
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE OR REPLACE TRIGGER sales_partner_set_updated_at
    BEFORE UPDATE ON crm.sales_partner
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('sales_partner', 'active', 'inactive'),
    ('sales_partner', 'inactive', 'active')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER sales_partner_status_transition
    BEFORE UPDATE OF status ON crm.sales_partner
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();
COMMENT ON TABLE crm.sales_partner IS 'AA-1071 (crm-056, item crm-28): a sub-agent, referrer, freelancer or online agency that brings the agency clients, and the commission terms the agency pays it per booked trip: commission_type percent (rate % of the basis) | fixed_per_pax (rate per traveller, in currency) | net_rate (the partner keeps rate % of the basis: computed as percent, settled by deduction); basis revenue (the accepted proposal total) | margin (the trip margin before partner commissions); payout_due_days after the trip end. Written by an owner only (crm.guard_sales_partner, CRM54). Goes with the agency''s settings row. conf:commercial.';
COMMENT ON COLUMN crm.sales_partner.name_enc IS 'pii:contact; the partner''s name (a person or a business) under the agency''s vault DEK';
COMMENT ON COLUMN crm.sales_partner.contact_email_enc IS 'pii:contact; the partner''s e-mail under the vault DEK: where the view''s sign-in code goes';
COMMENT ON COLUMN crm.sales_partner.contact_phone_enc IS 'pii:contact; the partner''s phone under the vault DEK';
COMMENT ON COLUMN crm.sales_partner.rate IS 'conf:commercial; a percent (0..100) for percent / net_rate, an amount per traveller in currency for fixed_per_pax';

-- ── 2. crm.trip.sales_partner_id, crm.form_submission.sales_partner_id ───────────────────────────
ALTER TABLE crm.trip ADD COLUMN IF NOT EXISTS sales_partner_id UUID;
ALTER TABLE crm.trip DROP CONSTRAINT IF EXISTS trip_sales_partner_fk;
ALTER TABLE crm.trip ADD CONSTRAINT trip_sales_partner_fk FOREIGN KEY (tenant_id, sales_partner_id)
    REFERENCES crm.sales_partner (tenant_id, sales_partner_id);
CREATE INDEX IF NOT EXISTS trip_sales_partner_idx ON crm.trip (tenant_id, sales_partner_id)
    WHERE sales_partner_id IS NOT NULL AND deleted_at IS NULL;
COMMENT ON COLUMN crm.trip.sales_partner_id IS 'AA-1071 (crm-056): the sales partner (crm.sales_partner) that brought this trip: stamped by the partner''s intake link or set by a member; a booked trip with a partner accrues its crm.partner_commission (trigger trip_partner_commission_sync). NULL = none';

ALTER TABLE crm.form_submission ADD COLUMN IF NOT EXISTS sales_partner_id UUID;
COMMENT ON COLUMN crm.form_submission.sales_partner_id IS 'AA-1071 (crm-056): the sales partner whose intake link (crm.sales_partner_link purpose intake) sent this inquiry; crm_intake_process copies it onto the trip it creates (an open trip it attaches to keeps its own partner, or takes this one when it has none). No key: the submission is redacted on its own schedule';

-- ── 3. crm.partner_commission ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.partner_commission (
    partner_commission_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                          REFERENCES crm.tenant (tenant_id),
    trip_id               UUID NOT NULL,
    sales_partner_id      UUID NOT NULL,
    commission_type       TEXT NOT NULL,
    rate                  NUMERIC(12,2) NOT NULL,
    basis                 TEXT NOT NULL,
    basis_amount          NUMERIC(14,2) NOT NULL,
    pax                   SMALLINT,
    amount                NUMERIC(14,2) NOT NULL,
    currency              CHARACTER(3) NOT NULL,
    base_currency         CHARACTER(3),
    fx_rate               NUMERIC(20,10),
    amount_base           NUMERIC(14,2),
    computed_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    due_on                DATE,
    approved_at           TIMESTAMPTZ,
    approved_by           TEXT,
    paid_on               DATE,
    payout_ref            TEXT,
    cancel_reason         TEXT,
    status                TEXT NOT NULL DEFAULT 'accrued',
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at            TIMESTAMPTZ,
    deleted_by            TEXT,
    purge_after           TIMESTAMPTZ,
    CONSTRAINT partner_commission_tenant_id_uq UNIQUE (tenant_id, partner_commission_id),
    CONSTRAINT partner_commission_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT partner_commission_partner_fk FOREIGN KEY (tenant_id, sales_partner_id)
        REFERENCES crm.sales_partner (tenant_id, sales_partner_id) ON DELETE CASCADE,
    CONSTRAINT partner_commission_terms_chk CHECK (
        commission_type IN ('percent', 'fixed_per_pax', 'net_rate') AND basis IN ('revenue', 'margin', 'pax')
        AND rate >= 0 AND basis_amount >= 0 AND amount >= 0
        AND currency ~ '^[A-Z]{3}$' AND (base_currency IS NULL OR base_currency ~ '^[A-Z]{3}$')
        AND ((commission_type = 'fixed_per_pax') = (basis = 'pax'))
        AND (pax IS NULL OR pax BETWEEN 0 AND 999)
        AND ((amount_base IS NULL) = (fx_rate IS NULL)) AND ((fx_rate IS NULL) OR (base_currency IS NOT NULL AND fx_rate > 0))
    ),
    CONSTRAINT partner_commission_follow_up_chk CHECK (
        (status NOT IN ('approved', 'paid') OR (approved_at IS NOT NULL AND approved_by IS NOT NULL))
        AND ((status = 'paid') = (paid_on IS NOT NULL))
        AND ((status = 'cancelled') = (cancel_reason IS NOT NULL))
        AND (cancel_reason IS NULL
             OR cancel_reason IN ('unbooked', 'partner_changed', 'partner_removed', 'trip_cancelled', 'by_owner'))
        AND (payout_ref IS NULL OR (length(payout_ref) BETWEEN 1 AND 120 AND payout_ref !~ '[[:cntrl:]]'))
        AND (approved_by IS NULL OR length(approved_by) <= 120)
    ),
    CONSTRAINT partner_commission_status_chk CHECK (status IN ('accrued', 'approved', 'paid', 'cancelled')),
    CONSTRAINT partner_commission_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS partner_commission_live_uq ON crm.partner_commission (tenant_id, trip_id, sales_partner_id)
    WHERE status <> 'cancelled' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS partner_commission_partner_idx ON crm.partner_commission (tenant_id, sales_partner_id, status)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS partner_commission_trip_idx ON crm.partner_commission (tenant_id, trip_id);

ALTER TABLE crm.partner_commission ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.partner_commission FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.partner_commission;
CREATE POLICY tenant_isolation ON crm.partner_commission
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
-- Margin field (§4.6): the same rule as commission_margin_roles (crm-035).
DROP POLICY IF EXISTS partner_commission_margin_roles ON crm.partner_commission;
CREATE POLICY partner_commission_margin_roles ON crm.partner_commission AS RESTRICTIVE FOR SELECT TO crm_app
    USING (
        COALESCE(current_setting('app.member_role', true), '') IN ('owner', 'agent')
        OR (COALESCE(current_setting('app.member_role', true), '') = ''
            AND COALESCE(current_setting('app.actor', true), '') ~ '^(job|seed|sales_partner_link):')
    );
CREATE OR REPLACE TRIGGER partner_commission_set_updated_at
    BEFORE UPDATE ON crm.partner_commission
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
-- No hold guard trigger: crm_app never deletes a row (no DELETE grant), the sync never runs on a held trip (the trip's
-- own guard refuses the move first), and a guard on a row deleted by a foreign-key cascade would read the holds of
-- every agency (a referential action runs without row security), refusing an unrelated agency's erase.
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('partner_commission', 'accrued', 'approved'),
    ('partner_commission', 'approved', 'accrued'),
    ('partner_commission', 'approved', 'paid'),
    ('partner_commission', 'accrued', 'cancelled'),
    ('partner_commission', 'approved', 'cancelled')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER partner_commission_status_transition
    BEFORE UPDATE OF status ON crm.partner_commission
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();
REVOKE ALL ON crm.partner_commission FROM crm_app;
GRANT SELECT ON crm.partner_commission TO crm_app;
GRANT UPDATE (status, approved_at, approved_by, paid_on, payout_ref, cancel_reason, due_on) ON crm.partner_commission TO crm_app;
COMMENT ON TABLE crm.partner_commission IS 'AA-1071 (crm-056, item crm-28): what the agency owes one sales partner for one booked trip (one live row per trip and partner): a snapshot of the partner''s terms, basis_amount (the accepted proposal total, the trip margin before partner commissions, or the pax), amount + currency, amount_base at the rate of computed_at''s day (NULL without a rate), due_on. accrued (refreshed by crm.partner_commission_sync while the trip is booked) -> approved (owner) -> paid (owner, paid_on + payout_ref); approved -> accrued; accrued | approved -> cancelled (unbooked, partner_changed, partner_removed, trip_cancelled, by_owner). A cost in crm.v_trip_pnl. Margin field: crm_app reads it only as owner / agent or a job / seed / partner-link actor (partner_commission_margin_roles). conf:commercial.';
COMMENT ON COLUMN crm.partner_commission.payout_ref IS 'conf:commercial; the agency''s own reference of the payout (a bank or voucher reference), never card or account numbers';

-- ── 4. crm.sales_partner_link ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.sales_partner_link (
    link_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    sales_partner_id UUID NOT NULL,
    purpose          TEXT NOT NULL,
    intake_form_id   UUID REFERENCES crm.intake_form (intake_form_id) ON DELETE CASCADE,
    token_hash       BYTEA NOT NULL,
    expires_at       TIMESTAMPTZ NOT NULL,
    revoked_at       TIMESTAMPTZ,
    last_used_at     TIMESTAMPTZ,
    use_count        INTEGER NOT NULL DEFAULT 0,
    status           TEXT NOT NULL DEFAULT 'active',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT sales_partner_link_tenant_id_uq UNIQUE (tenant_id, link_id),
    CONSTRAINT sales_partner_link_partner_fk FOREIGN KEY (tenant_id, sales_partner_id)
        REFERENCES crm.sales_partner (tenant_id, sales_partner_id) ON DELETE CASCADE,
    CONSTRAINT sales_partner_link_purpose_chk CHECK (
        purpose IN ('intake', 'view') AND ((purpose = 'intake') = (intake_form_id IS NOT NULL))
    ),
    CONSTRAINT sales_partner_link_token_chk CHECK (octet_length(token_hash) = 32),
    CONSTRAINT sales_partner_link_dates_chk CHECK (
        expires_at > created_at AND expires_at <= created_at + interval '400 days'
        AND ((status = 'revoked') = (revoked_at IS NOT NULL)) AND use_count >= 0
    ),
    CONSTRAINT sales_partner_link_status_chk CHECK (status IN ('active', 'revoked')),
    CONSTRAINT sales_partner_link_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS sales_partner_link_token_uq ON crm.sales_partner_link (token_hash);
CREATE UNIQUE INDEX IF NOT EXISTS sales_partner_link_active_uq ON crm.sales_partner_link (tenant_id, sales_partner_id, purpose)
    WHERE status = 'active' AND deleted_at IS NULL;

ALTER TABLE crm.sales_partner_link ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.sales_partner_link FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.sales_partner_link;
CREATE POLICY tenant_isolation ON crm.sales_partner_link
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
-- Found by its token before any agency is known (app.tenancy.partner_link_tx), as client_link_token_lookup (crm-012).
DROP POLICY IF EXISTS sales_partner_link_token_lookup ON crm.sales_partner_link;
CREATE POLICY sales_partner_link_token_lookup ON crm.sales_partner_link FOR SELECT TO crm_app
    USING (
        token_hash = decode(NULLIF(current_setting('app.partner_link_hash', true), ''), 'hex')
        AND status = 'active' AND expires_at > now() AND deleted_at IS NULL
    );
CREATE OR REPLACE TRIGGER sales_partner_link_set_updated_at
    BEFORE UPDATE ON crm.sales_partner_link
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('sales_partner_link', 'active', 'revoked')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER sales_partner_link_status_transition
    BEFORE UPDATE OF status ON crm.sales_partner_link
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();
REVOKE DELETE ON crm.sales_partner_link FROM crm_app;
COMMENT ON TABLE crm.sales_partner_link IS 'AA-1071 (crm-056, item crm-29): a sales partner''s signed link: purpose intake (the agency''s inquiry form intake_form_id for that partner: the inquiry it sends is stamped with the partner) or view (the partner''s list of the trips it referred, after an e-mail code). The token''s SHA-256 only (conf:credential); active -> revoked; at most 400 days; one active per partner and purpose. Found by the SELECT-only policy sales_partner_link_token_lookup on app.partner_link_hash. Written by an owner, and its counters by the link''s own actor (crm.guard_sales_partner, CRM54).';
COMMENT ON COLUMN crm.sales_partner_link.token_hash IS 'conf:credential; SHA-256 of the 43-character link token (the token itself is shown once to the owner)';

-- ── 5. crm.sales_partner_otp ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.sales_partner_otp (
    otp_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    sales_partner_id   UUID NOT NULL,
    link_id            UUID NOT NULL,
    code_hash          BYTEA NOT NULL,
    code_enc           BYTEA,
    message_id         UUID,
    delivery           TEXT NOT NULL,
    attempts           SMALLINT NOT NULL DEFAULT 0,
    expires_at         TIMESTAMPTZ NOT NULL,
    verified_at        TIMESTAMPTZ,
    session_hash       BYTEA,
    session_expires_at TIMESTAMPTZ,
    status             TEXT NOT NULL DEFAULT 'pending',
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,
    deleted_by         TEXT,
    purge_after        TIMESTAMPTZ,
    CONSTRAINT sales_partner_otp_tenant_id_uq UNIQUE (tenant_id, otp_id),
    CONSTRAINT sales_partner_otp_partner_fk FOREIGN KEY (tenant_id, sales_partner_id)
        REFERENCES crm.sales_partner (tenant_id, sales_partner_id) ON DELETE CASCADE,
    CONSTRAINT sales_partner_otp_link_fk FOREIGN KEY (tenant_id, link_id)
        REFERENCES crm.sales_partner_link (tenant_id, link_id) ON DELETE CASCADE,
    CONSTRAINT sales_partner_otp_values_chk CHECK (
        octet_length(code_hash) = 32 AND COALESCE(octet_length(session_hash), 32) = 32
        AND delivery IN ('mailbox', 'dev_echo') AND attempts BETWEEN 0 AND 5
        AND expires_at <= created_at + interval '10 minutes'
        AND ((session_hash IS NULL) = (session_expires_at IS NULL))
        AND (session_expires_at IS NULL OR session_expires_at <= COALESCE(verified_at, created_at) + interval '12 hours')
        AND (status <> 'verified' OR verified_at IS NOT NULL)
    ),
    CONSTRAINT sales_partner_otp_status_chk CHECK (status IN ('pending', 'verified', 'expired', 'failed')),
    CONSTRAINT sales_partner_otp_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS sales_partner_otp_link_idx ON crm.sales_partner_otp (tenant_id, link_id, status, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS sales_partner_otp_session_uq ON crm.sales_partner_otp (session_hash)
    WHERE session_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS sales_partner_otp_message_idx ON crm.sales_partner_otp (tenant_id, message_id)
    WHERE message_id IS NOT NULL;

ALTER TABLE crm.sales_partner_otp ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.sales_partner_otp FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.sales_partner_otp;
CREATE POLICY tenant_isolation ON crm.sales_partner_otp
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE OR REPLACE TRIGGER sales_partner_otp_set_updated_at
    BEFORE UPDATE ON crm.sales_partner_otp
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('sales_partner_otp', 'pending', 'verified'),
    ('sales_partner_otp', 'pending', 'expired'),
    ('sales_partner_otp', 'pending', 'failed'),
    ('sales_partner_otp', 'verified', 'expired')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER sales_partner_otp_status_transition
    BEFORE UPDATE OF status ON crm.sales_partner_otp
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();
COMMENT ON TABLE crm.sales_partner_otp IS 'AA-1071 (crm-056, item crm-29): the e-mail sign-in code of a sales partner''s view link (SHA-256 of otp id + code, 10 minutes, 5 attempts; code_enc under the vault DEK only until the mail sender put it into the mail) and the 12 h session it opens (SHA-256 of the session cookie). pending -> verified | expired | failed; verified -> expired (sign-out). Deleted 24 hours after it was made (crm_stage_rules). conf:credential.';
COMMENT ON COLUMN crm.sales_partner_otp.code_enc IS 'conf:credential; the code under the vault DEK until the mail sender sent it (then NULL); delivery dev_echo never stores it';

-- ── 6. Write guard (SQLSTATE CRM54; crm-054 used CRM53) ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.guard_sales_partner() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    v_role text := COALESCE(NULLIF(current_setting('app.member_role', true), ''), '');
BEGIN
    -- An approved or paid partner commission is a payout record: deleting its partner never takes it while its trip
    -- remains (the API refuses the delete first, partner_in_use). Its trip's erase and the agency erase delete the
    -- trip first, so they pass. Checked before the cascade / owner pass below (a partner delete is a cascade here).
    -- (Nested: a PL/pgSQL condition is not short-circuited, OLD of another table has no trip_id.)
    IF TG_TABLE_NAME = 'partner_commission' AND TG_OP = 'DELETE' THEN
        IF OLD.status IN ('approved', 'paid')
           AND EXISTS (SELECT 1 FROM crm.trip t WHERE t.tenant_id = OLD.tenant_id AND t.trip_id = OLD.trip_id) THEN
            RAISE EXCEPTION 'crm: partner_commission_kept (an approved or paid partner commission stays while its trip does)'
                USING ERRCODE = 'CRM54';
        END IF;
    END IF;
    -- A cascade (the agency erase, a partner deleted: trigger depth > 1) and the owner role (migrations, tests, the
    -- SECURITY DEFINER sync) pass.
    IF pg_catalog.pg_trigger_depth() > 1 OR current_user = 'crm_owner' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_TABLE_NAME = 'sales_partner' THEN
        -- The partner and its commission terms are the owner's (money fields); a job / seed actor passes.
        IF v_actor !~ '^(job|seed):' AND v_role <> 'owner' THEN
            RAISE EXCEPTION 'crm: sales_partner_owner (sales partners are managed by an owner, role %)', NULLIF(v_role, '')
                USING ERRCODE = 'CRM54';
        END IF;
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_TABLE_NAME = 'sales_partner_link' THEN
        IF v_actor ~ '^sales_partner_link:' THEN
            -- The link's own page touches only its counters.
            IF TG_OP <> 'UPDATE' OR v_actor <> 'sales_partner_link:' || OLD.link_id::text
               OR (to_jsonb(NEW) - ARRAY['last_used_at', 'use_count', 'updated_at'])
                  IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['last_used_at', 'use_count', 'updated_at']) THEN
                RAISE EXCEPTION 'crm: sales_partner_link_counters (a link page updates only its own counters)'
                    USING ERRCODE = 'CRM54';
            END IF;
            RETURN NEW;
        END IF;
        IF v_actor !~ '^(job|seed):' AND v_role <> 'owner' THEN
            RAISE EXCEPTION 'crm: sales_partner_owner (partner links are issued and revoked by an owner, role %)',
                NULLIF(v_role, '') USING ERRCODE = 'CRM54';
        END IF;
        IF TG_OP = 'UPDATE' AND (NEW.token_hash IS DISTINCT FROM OLD.token_hash
            OR NEW.sales_partner_id IS DISTINCT FROM OLD.sales_partner_id OR NEW.purpose IS DISTINCT FROM OLD.purpose
            OR NEW.intake_form_id IS DISTINCT FROM OLD.intake_form_id OR NEW.expires_at IS DISTINCT FROM OLD.expires_at) THEN
            RAISE EXCEPTION 'crm: sales_partner_link_fixed (a link''s token, partner, purpose, form and expiry never change)'
                USING ERRCODE = 'CRM54';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME = 'sales_partner_otp' THEN
        -- Codes are the partner page's (its link actor) and the jobs' (the mail sender, the purge); never a member's.
        IF v_role <> '' OR v_actor !~ '^(sales_partner_link|job|seed):' THEN
            RAISE EXCEPTION 'crm: sales_partner_otp_actor (partner codes are written by the partner page and the jobs only)'
                USING ERRCODE = 'CRM54';
        END IF;
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    -- crm.partner_commission: rows are written by crm.partner_commission_sync (crm_owner, above) only.
    IF TG_OP <> 'UPDATE' THEN
        RAISE EXCEPTION 'crm: partner_commission_sync_only (partner commission rows come from crm.partner_commission_sync)'
            USING ERRCODE = 'CRM54';
    END IF;
    IF OLD.status IN ('paid', 'cancelled') THEN
        RAISE EXCEPTION 'crm: partner_commission_sealed (a % partner commission never changes)', OLD.status
            USING ERRCODE = 'CRM54';
    END IF;
    IF (to_jsonb(NEW) - ARRAY['status', 'approved_at', 'approved_by', 'paid_on', 'payout_ref', 'cancel_reason', 'due_on',
                              'updated_at'])
       IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status', 'approved_at', 'approved_by', 'paid_on', 'payout_ref',
                                               'cancel_reason', 'due_on', 'updated_at']) THEN
        RAISE EXCEPTION 'crm: partner_commission_fixed (the trip, partner, terms and amounts change only through the sync)'
            USING ERRCODE = 'CRM54';
    END IF;
    IF v_actor ~ '^(job|seed):' AND v_role = '' THEN
        RETURN NEW;
    END IF;
    IF NEW.status = 'cancelled' AND NEW.cancel_reason = 'trip_cancelled' THEN
        IF v_role NOT IN ('owner', 'agent') THEN
            RAISE EXCEPTION 'crm: partner_commission_owner (a trip cancel is an owner''s or an agent''s, role %)',
                NULLIF(v_role, '') USING ERRCODE = 'CRM54';
        END IF;
        RETURN NEW;
    END IF;
    IF v_role <> 'owner' THEN
        RAISE EXCEPTION 'crm: partner_commission_owner (partner commissions are approved, paid and cancelled by an owner, role %)',
            NULLIF(v_role, '') USING ERRCODE = 'CRM54';
    END IF;
    IF NEW.status = 'approved' AND OLD.status = 'accrued' AND NEW.approved_by IS DISTINCT FROM v_actor THEN
        RAISE EXCEPTION 'crm: partner_commission_owner (an owner approves as themselves)' USING ERRCODE = 'CRM54';
    END IF;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION crm.guard_sales_partner() IS 'AA-1071 (crm-056, SQLSTATE CRM54): crm.sales_partner and its links are written by an owner (sales_partner_owner) or a job / seed actor; a link''s token, partner, purpose, form and expiry are fixed and its own page touches only its counters (sales_partner_link_counters / _fixed); partner codes only by the partner page and jobs (sales_partner_otp_actor); crm.partner_commission rows only from crm.partner_commission_sync (partner_commission_sync_only), identity and amounts fixed (partner_commission_fixed), paid / cancelled sealed (partner_commission_sealed), an approved or paid row never deleted while its trip remains, even by its partner''s cascade (partner_commission_kept), approve / un-approve / pay / an owner''s cancel by an owner, as themselves, a trip cancel by an owner or an agent (partner_commission_owner). A cascade (depth > 1) and crm_owner pass. Invoker rights.';
DROP TRIGGER IF EXISTS sales_partner_guard ON crm.sales_partner;
CREATE TRIGGER sales_partner_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.sales_partner
    FOR EACH ROW EXECUTE FUNCTION crm.guard_sales_partner();
DROP TRIGGER IF EXISTS sales_partner_link_guard ON crm.sales_partner_link;
CREATE TRIGGER sales_partner_link_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.sales_partner_link
    FOR EACH ROW EXECUTE FUNCTION crm.guard_sales_partner();
DROP TRIGGER IF EXISTS sales_partner_otp_guard ON crm.sales_partner_otp;
CREATE TRIGGER sales_partner_otp_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.sales_partner_otp
    FOR EACH ROW EXECUTE FUNCTION crm.guard_sales_partner();
DROP TRIGGER IF EXISTS partner_commission_guard ON crm.partner_commission;
CREATE TRIGGER partner_commission_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.partner_commission
    FOR EACH ROW EXECUTE FUNCTION crm.guard_sales_partner();

-- ── 7. The partner's code mail: conversation + dispatch subject ──────────────────────────────────
ALTER TABLE crm.conversation ADD COLUMN IF NOT EXISTS sales_partner_id UUID;
ALTER TABLE crm.conversation DROP CONSTRAINT IF EXISTS conversation_sales_partner_chk;
ALTER TABLE crm.conversation ADD CONSTRAINT conversation_sales_partner_chk CHECK (
    sales_partner_id IS NULL
    OR (trip_id IS NULL AND traveler_id IS NULL AND agency_supplier_id IS NULL AND channel = 'email')
);
CREATE UNIQUE INDEX IF NOT EXISTS conversation_sales_partner_uq ON crm.conversation (tenant_id, sales_partner_id)
    WHERE sales_partner_id IS NOT NULL AND deleted_at IS NULL;
COMMENT ON COLUMN crm.conversation.sales_partner_id IS 'AA-1071 (crm-056): the sales partner (crm.sales_partner) this e-mail conversation is with: the thread of its view''s sign-in codes (no trip, no client, no supplier; one live per partner). No key (it leaves with the agency). NULL = any other conversation; never an Unmatched one';

ALTER TABLE crm.dispatch_queue ADD COLUMN IF NOT EXISTS sales_partner_id UUID;
ALTER TABLE crm.dispatch_queue ALTER COLUMN traveler_id DROP NOT NULL;
ALTER TABLE crm.dispatch_queue DROP CONSTRAINT IF EXISTS dispatch_queue_subject_chk;
ALTER TABLE crm.dispatch_queue ADD CONSTRAINT dispatch_queue_subject_chk CHECK (
    num_nonnulls(traveler_id, sales_partner_id) = 1
    AND (sales_partner_id IS NULL OR (trip_id IS NULL AND channel = 'email' AND purpose = 'transactional'))
);
-- The crm-023 gate codes plus partner_inactive (every existing row passes it: the list only grows).
ALTER TABLE crm.dispatch_queue DROP CONSTRAINT IF EXISTS dispatch_queue_gate_chk;
ALTER TABLE crm.dispatch_queue ADD CONSTRAINT dispatch_queue_gate_chk CHECK (
    (status = 'queued') = (gate_result IS NULL)
    AND (gate_result IS NULL OR gate_result IN (
        'sent', 'archived', 'traveler_trashed', 'trip_trashed', 'no_consent', 'no_sender', 'undone',
        'held_reconnect', 'send_failed', 'no_message', 'send_uncertain', 'partner_inactive'
    ))
    AND (status = 'queued') = (decided_at IS NULL)
);
COMMENT ON COLUMN crm.dispatch_queue.gate_result IS 'the decision code: sent, archived, traveler_trashed, trip_trashed, no_consent, no_sender, undone (crm-010); AA-945: held_reconnect (the sending mailbox is disconnected: held, re-queued on reconnect, never sent through SES), send_failed (the provider refused it for good), no_message (nothing to send); AA-993 G4b (crm-023): send_uncertain (held: a run stopped after calling the provider and before its decision, crm.dispatch_attempt; the provider may have the message, so it is never sent again automatically); AA-1071 (crm-056): partner_inactive (a row to a sales partner that is inactive or trashed: dropped)';
COMMENT ON COLUMN crm.dispatch_queue.sales_partner_id IS 'AA-1071 (crm-056): a transactional e-mail to a sales partner (its view''s sign-in code) instead of a client: exactly one of traveler_id / sales_partner_id; no trip. The dispatcher drops it (partner_inactive) once the partner is inactive or trashed';

-- ── 8. crm.partner_commission_sync(trip) ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.partner_commission_sync(p_trip uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    v_trip record;
    v_partner record;
    v_live record;
    v_booked boolean;
    v_cancelled integer := 0;
    v_created integer := 0;
    v_refreshed integer := 0;
    v_base text;
    v_basis numeric;
    v_currency text;
    v_pax integer;
    v_amount numeric;
    v_fx numeric;
BEGIN
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'crm: partner_commission_sync needs app.tenant_id' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT t.trip_id, t.stage, t.sales_partner_id, t.start_date, t.end_date, t.deleted_at,
           (t.party_adults + cardinality(t.party_child_ages))::integer AS pax
      INTO v_trip
      FROM crm.trip t WHERE t.tenant_id = v_tenant AND t.trip_id = p_trip;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (trip %)', p_trip USING ERRCODE = 'CRM13';
    END IF;
    -- A cancelled trip: the cancel run keeps or cancels its rows (app.cancellation); nothing here.
    IF v_trip.stage = 'cancelled' THEN
        RETURN jsonb_build_object('created', 0, 'refreshed', 0, 'cancelled', 0);
    END IF;
    v_booked := v_trip.stage IN ('booked', 'pre_departure', 'travelling', 'completed') AND v_trip.deleted_at IS NULL;
    -- a. Accrued rows that no longer apply. Approved and paid rows are the owner's to decide.
    UPDATE crm.partner_commission c
       SET status = 'cancelled',
           cancel_reason = CASE WHEN NOT v_booked THEN 'unbooked'
                                WHEN v_trip.sales_partner_id IS NULL THEN 'partner_removed'
                                ELSE 'partner_changed' END
     WHERE c.tenant_id = v_tenant AND c.trip_id = p_trip AND c.status = 'accrued' AND c.deleted_at IS NULL
       AND (NOT v_booked OR c.sales_partner_id IS DISTINCT FROM v_trip.sales_partner_id);
    GET DIAGNOSTICS v_cancelled = ROW_COUNT;
    IF NOT v_booked OR v_trip.sales_partner_id IS NULL THEN
        RETURN jsonb_build_object('created', 0, 'refreshed', 0, 'cancelled', v_cancelled);
    END IF;
    SELECT p.sales_partner_id, p.commission_type, p.rate, p.currency, p.basis, p.payout_due_days
      INTO v_partner
      FROM crm.sales_partner p WHERE p.tenant_id = v_tenant AND p.sales_partner_id = v_trip.sales_partner_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('created', 0, 'refreshed', 0, 'cancelled', v_cancelled);
    END IF;
    SELECT * INTO v_live FROM crm.partner_commission c
     WHERE c.tenant_id = v_tenant AND c.trip_id = p_trip AND c.sales_partner_id = v_partner.sales_partner_id
       AND c.status <> 'cancelled' AND c.deleted_at IS NULL
       FOR UPDATE;
    IF FOUND AND v_live.status <> 'accrued' THEN
        RETURN jsonb_build_object('created', 0, 'refreshed', 0, 'cancelled', v_cancelled);
    END IF;
    -- A waiver: the owner cancelled this partner's commission on this trip (by_owner), or a trip cancel did
    -- (trip_cancelled, the stage still booked while Booking cancels the AA bookings). No new row until the trip has
    -- left the booked stages since (a new booking): a later stage move, the stage-rules job, a trash / restore or a
    -- Recalculate never brings it back.
    IF NOT FOUND AND EXISTS (
        SELECT 1 FROM crm.partner_commission w
         WHERE w.tenant_id = v_tenant AND w.trip_id = p_trip AND w.sales_partner_id = v_partner.sales_partner_id
           AND w.status = 'cancelled' AND w.cancel_reason IN ('by_owner', 'trip_cancelled') AND w.deleted_at IS NULL
           AND NOT EXISTS (
               SELECT 1 FROM crm.trip_stage_history h
                WHERE h.tenant_id = v_tenant AND h.trip_id = p_trip AND h.created_at > w.updated_at
                  AND h.to_stage NOT IN ('booked', 'pre_departure', 'travelling', 'completed'))) THEN
        RETURN jsonb_build_object('created', 0, 'refreshed', 0, 'cancelled', v_cancelled);
    END IF;
    v_base := COALESCE((SELECT ts.base_currency::text FROM crm.tenant_settings ts WHERE ts.tenant_id = v_tenant), 'USD');
    v_pax := v_trip.pax;
    IF v_partner.commission_type = 'fixed_per_pax' THEN
        v_basis := v_pax;
        v_currency := v_partner.currency::text;
        v_amount := round(v_partner.rate * v_pax, 2);
    ELSE
        IF v_partner.basis = 'revenue' THEN
            -- The accepted proposal's total (the builder's accepted total, else the text proposal's total).
            SELECT COALESCE(pr.accepted_total_amount, pr.total_amount), pr.currency::text
              INTO v_basis, v_currency
              FROM crm.proposal pr
             WHERE pr.tenant_id = v_tenant AND pr.trip_id = p_trip AND pr.status = 'accepted' AND pr.deleted_at IS NULL
             ORDER BY pr.accepted_at DESC NULLS LAST, pr.version DESC
             LIMIT 1;
            IF v_basis IS NULL THEN
                -- No accepted proposal (a booking by hand): the issued revenue in the base currency.
                SELECT p.revenue_base INTO v_basis FROM crm.v_trip_pnl p WHERE p.tenant_id = v_tenant AND p.trip_id = p_trip;
                v_currency := v_base;
            END IF;
        ELSE
            -- The margin before partner commissions, in the base currency (never below 0).
            SELECT p.margin_base + p.partner_commission_base INTO v_basis
              FROM crm.v_trip_pnl p WHERE p.tenant_id = v_tenant AND p.trip_id = p_trip;
            v_currency := v_base;
        END IF;
        v_basis := GREATEST(COALESCE(v_basis, 0), 0);
        v_amount := round(v_basis * v_partner.rate / 100, 2);
        v_pax := NULL;
    END IF;
    SELECT fx.rate INTO v_fx FROM crm.fx_resolve(v_currency, v_base, current_date) fx;
    IF v_live.partner_commission_id IS NULL THEN
        INSERT INTO crm.partner_commission (tenant_id, trip_id, sales_partner_id, commission_type, rate, basis,
                                            basis_amount, pax, amount, currency, base_currency, fx_rate, amount_base,
                                            computed_at, due_on, created_by)
        VALUES (v_tenant, p_trip, v_partner.sales_partner_id, v_partner.commission_type, v_partner.rate,
                CASE WHEN v_partner.commission_type = 'fixed_per_pax' THEN 'pax' ELSE v_partner.basis END,
                v_basis, v_pax, v_amount, v_currency, CASE WHEN v_fx IS NULL THEN NULL ELSE v_base END, v_fx,
                CASE WHEN v_fx IS NULL THEN NULL ELSE round(v_amount * v_fx, 2) END, now(),
                COALESCE(v_trip.end_date, v_trip.start_date, current_date) + v_partner.payout_due_days,
                COALESCE(NULLIF(current_setting('app.actor', true), ''), 'system:partner_commission_sync'));
        v_created := 1;
    ELSIF (v_live.commission_type, v_live.rate, v_live.basis_amount, v_live.amount, v_live.currency, v_live.fx_rate,
           v_live.pax) IS DISTINCT FROM
          (v_partner.commission_type, v_partner.rate, v_basis, v_amount, v_currency::bpchar, v_fx, v_pax::smallint) THEN
        UPDATE crm.partner_commission c
           SET commission_type = v_partner.commission_type, rate = v_partner.rate,
               basis = CASE WHEN v_partner.commission_type = 'fixed_per_pax' THEN 'pax' ELSE v_partner.basis END,
               basis_amount = v_basis, pax = v_pax, amount = v_amount, currency = v_currency,
               base_currency = CASE WHEN v_fx IS NULL THEN NULL ELSE v_base END, fx_rate = v_fx,
               amount_base = CASE WHEN v_fx IS NULL THEN NULL ELSE round(v_amount * v_fx, 2) END,
               computed_at = now(),
               due_on = COALESCE(v_trip.end_date, v_trip.start_date, current_date) + v_partner.payout_due_days
         WHERE c.partner_commission_id = v_live.partner_commission_id;
        v_refreshed := 1;
    END IF;
    RETURN jsonb_build_object('created', v_created, 'refreshed', v_refreshed, 'cancelled', v_cancelled);
END;
$$;
REVOKE ALL ON FUNCTION crm.partner_commission_sync(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.partner_commission_sync(uuid) TO crm_app;
COMMENT ON FUNCTION crm.partner_commission_sync(uuid) IS 'AA-1071 (crm-056, item crm-28): the partner commission rows of one trip of the agency of app.tenant_id. A cancelled trip is left to the cancel run. Accrued rows of a trip that left the booked stages (unbooked) or whose partner was removed / changed are cancelled; a booked trip (booked, pre_departure, travelling, completed, not trashed) with a partner gets one accrued row for that partner, refreshed while accrued: fixed_per_pax = rate x pax in the partner''s currency; percent / net_rate = rate % of the basis: revenue = the accepted proposal''s total (accepted_total_amount, else total_amount) in its currency, else the issued revenue of crm.v_trip_pnl in the base currency; margin = v_trip_pnl margin_base + partner_commission_base (the margin before partner commissions, never below 0) in the base currency. amount_base at crm.fx_resolve of today (NULL without a rate); due_on = trip end, else start, else today, + payout_due_days. Approved and paid rows are never touched. A by_owner or trip_cancelled row is a waiver: no new row for that trip and partner until a crm.trip_stage_history move out of the booked stages after it. SECURITY DEFINER (the assistant may book a trip but reads no money); returns counts only. Unknown trip CRM13. EXECUTE crm_app.';

CREATE OR REPLACE FUNCTION crm.trip_partner_commission() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF (NEW.sales_partner_id IS NOT NULL OR OLD.sales_partner_id IS NOT NULL)
       AND (NEW.stage IS DISTINCT FROM OLD.stage OR NEW.sales_partner_id IS DISTINCT FROM OLD.sales_partner_id
            OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at) THEN
        PERFORM crm.partner_commission_sync(NEW.trip_id);
    END IF;
    RETURN NULL;
END;
$$;
COMMENT ON FUNCTION crm.trip_partner_commission() IS 'AA-1071 (crm-056): runs crm.partner_commission_sync(trip) after a trip with (or that had) a sales partner moves stage, changes partner or goes to / back from the trash, whatever path made the change. Invoker rights.';
DROP TRIGGER IF EXISTS trip_partner_commission_sync ON crm.trip;
CREATE TRIGGER trip_partner_commission_sync
    AFTER UPDATE OF stage, sales_partner_id, deleted_at ON crm.trip
    FOR EACH ROW EXECUTE FUNCTION crm.trip_partner_commission();

-- ── 9. crm.v_trip_pnl: the partner commission in the trip P&L ────────────────────────────────────
CREATE OR REPLACE VIEW crm.v_trip_pnl WITH (security_invoker = true) AS
SELECT x.*,
       (x.aa_cost_base + x.agency_cost_base + x.cancellation_cost_base + x.departure_cost_base
        + x.partner_commission_base)::numeric(14,2) AS total_cost_base,
       (x.revenue_base + x.commission_income_base
        - (x.aa_cost_base + x.agency_cost_base + x.cancellation_cost_base + x.departure_cost_base
           + x.partner_commission_base))::numeric(14,2) AS margin_base,
       CASE WHEN x.revenue_base > 0 THEN
            round((x.revenue_base + x.commission_income_base
                   - (x.aa_cost_base + x.agency_cost_base + x.cancellation_cost_base + x.departure_cost_base
                      + x.partner_commission_base)) * 100 / x.revenue_base, 2)
       END AS margin_pct,
       round((x.revenue_base + x.commission_income_base
              - (x.aa_cost_base + x.agency_cost_base + x.cancellation_cost_base + x.departure_cost_base
                 + x.partner_commission_base)) / x.pax, 2) AS margin_per_pax_base
  FROM (
    SELECT t.tenant_id, t.trip_id, t.stage, t.start_date, t.owner_member_id, t.lead_source, t.group_code,
           b.base_currency,
           (t.party_adults + cardinality(t.party_child_ages))::integer AS pax,
           t.sales_partner_id,
           r.revenue_sales_base, r.revenue_service_fee_base, r.revenue_cancellation_fee_base, r.refunds_base,
           (r.revenue_sales_base + r.revenue_service_fee_base + r.revenue_cancellation_fee_base
            - r.refunds_base)::numeric(14,2) AS revenue_base,
           r.revenue_unconverted, r.cancellation_charged,
           ln.aa_sell_base, ln.agency_sell_base,
           ln.aa_cost_quoted_base, ln.aa_cost_base, ln.aa_lines_invoiced, ln.aa_lines_mismatch,
           ln.agency_cost_planned_base, ln.agency_cost_base, ln.cost_variance_base, ln.lines_billed,
           ln.cancellation_cost_base, ln.commission_income_base, ln.lines_confirmed, ln.lines_planning,
           ln.lines_other_base,
           dp.departure_cost_base, dp.departure_costs,
           pc.partner_commission_base
      FROM crm.trip t
     CROSS JOIN LATERAL (
            SELECT COALESCE((SELECT ts.base_currency::text FROM crm.tenant_settings ts
                              WHERE ts.tenant_id = t.tenant_id), 'USD') AS base_currency
           ) b
     -- The cancellation charge of a cancelled trip (crm.cancellation_charge, crm-049, one row per trip): once a trip
     -- is cancelled with a charge, what the client owes is the charge (fee = charge_amount), net of tax by the net share
     -- of the trip's issued invoices in the charge currency (none: 1), at the rate of the cancel day. It replaces the
     -- sale invoices, their refunds and the cancellation fee invoice (that invoice bills only the charge not covered by
     -- money kept, and a kept sale invoice may still show an unpaid rest), so no fee is counted twice. Service fee
     -- invoices still count. A waived charge is 0.
     LEFT JOIN LATERAL (
            SELECT true AS charged,
                   round(round(c.charge_amount * COALESCE(ns.share, 1), 2) * fx.rate, 2) AS fee_base
              FROM crm.cancellation_charge c
             CROSS JOIN LATERAL (
                    SELECT sum(i.subtotal_amount) / NULLIF(sum(i.total_amount), 0) AS share
                      FROM crm.invoice i
                     WHERE i.tenant_id = c.tenant_id AND i.trip_id = c.trip_id AND i.deleted_at IS NULL
                       AND i.issued_at IS NOT NULL AND i.kind::text <> 'service_fee' AND i.currency = c.currency
                   ) ns
              LEFT JOIN LATERAL crm.fx_resolve(c.currency::text, b.base_currency, c.created_at::date) fx ON true
             WHERE c.tenant_id = t.tenant_id AND c.trip_id = t.trip_id AND c.deleted_at IS NULL
           ) cc ON true
     -- Revenue: issued invoices (open, payment claimed, paid, paid but unfulfillable) net of tax; refunds net of tax
     -- (the refund times the invoice's net share). An invoice kind other than a service fee or a cancellation fee
     -- (deposit, balance, adjustment, instalment, any later kind) is a sale. A trip cancelled with a charge: the charge
     -- in place of its sales, their refunds and its cancellation fee invoices (above).
     CROSS JOIN LATERAL (
            SELECT COALESCE(sum(v.net_base) FILTER (
                       WHERE v.src = 'invoice' AND v.kind NOT IN ('service_fee', 'cancellation_fee') AND NOT v.charged),
                       0)::numeric(14,2) AS revenue_sales_base,
                   COALESCE(sum(v.net_base) FILTER (WHERE v.src = 'invoice' AND v.kind = 'service_fee'), 0)::numeric(14,2)
                       AS revenue_service_fee_base,
                   (CASE WHEN COALESCE(cc.charged, false) THEN COALESCE(cc.fee_base, 0)
                         ELSE COALESCE(sum(v.net_base) FILTER (WHERE v.src = 'invoice' AND v.kind = 'cancellation_fee'), 0)
                    END)::numeric(14,2) AS revenue_cancellation_fee_base,
                   COALESCE(sum(v.net_base) FILTER (
                       WHERE v.src = 'refund' AND (v.kind = 'service_fee' OR NOT v.charged)), 0)::numeric(14,2)
                       AS refunds_base,
                   ((count(*) FILTER (WHERE v.net_base IS NULL AND (v.kind = 'service_fee' OR NOT v.charged)))
                    + CASE WHEN COALESCE(cc.charged, false) AND cc.fee_base IS NULL THEN 1 ELSE 0 END)::integer
                       AS revenue_unconverted,
                   COALESCE(cc.charged, false) AS cancellation_charged
              FROM (
                    SELECT 'invoice'::text AS src, i.kind::text AS kind, round(i.subtotal_amount * fx.rate, 2) AS net_base,
                           COALESCE(cc.charged, false) AS charged
                      FROM crm.invoice i
                      LEFT JOIN LATERAL crm.fx_resolve(i.currency::text, b.base_currency, i.issue_date) fx ON true
                     WHERE i.tenant_id = t.tenant_id AND i.trip_id = t.trip_id AND i.deleted_at IS NULL
                       AND i.issued_at IS NOT NULL
                       AND i.status IN ('open', 'payment_claimed', 'paid', 'paid_unfulfillable')
                    UNION ALL
                    SELECT 'refund', i.kind::text,
                           round(round(p.amount * i.subtotal_amount / i.total_amount, 2) * fx.rate, 2),
                           COALESCE(cc.charged, false)
                      FROM crm.payment p
                      JOIN crm.invoice i ON i.tenant_id = p.tenant_id AND i.invoice_id = p.invoice_id
                      LEFT JOIN LATERAL crm.fx_resolve(p.currency::text, b.base_currency, p.received_on) fx ON true
                     WHERE p.tenant_id = t.tenant_id AND p.trip_id = t.trip_id AND p.entry_kind = 'refund'
                       AND i.deleted_at IS NULL AND i.issued_at IS NOT NULL
                       AND i.status IN ('open', 'payment_claimed', 'paid', 'paid_unfulfillable')
                   ) v
           ) r
     -- Costs from the booking lines (confirmed lines count; planning lines are pipeline, counted apart).
     CROSS JOIN LATERAL (
            SELECT COALESCE(sum(q.sell_base) FILTER (WHERE q.supplier_kind = 'aa' AND q.status = 'confirmed'), 0)::numeric(14,2)
                       AS aa_sell_base,
                   COALESCE(sum(q.sell_base) FILTER (WHERE q.supplier_kind = 'agency' AND q.status = 'confirmed'), 0)::numeric(14,2)
                       AS agency_sell_base,
                   COALESCE(sum(q.cost_base) FILTER (WHERE q.supplier_kind = 'aa' AND q.status = 'confirmed'), 0)::numeric(14,2)
                       AS aa_cost_quoted_base,
                   COALESCE(sum(q.aa_cost) FILTER (WHERE q.supplier_kind = 'aa' AND q.status = 'confirmed'), 0)::numeric(14,2)
                       AS aa_cost_base,
                   (count(*) FILTER (WHERE q.aa_invoiced AND q.status = 'confirmed'))::integer AS aa_lines_invoiced,
                   (count(*) FILTER (WHERE q.aa_mismatch AND q.status = 'confirmed'))::integer AS aa_lines_mismatch,
                   COALESCE(sum(q.cost_base) FILTER (WHERE q.supplier_kind = 'agency' AND q.status = 'confirmed'), 0)::numeric(14,2)
                       AS agency_cost_planned_base,
                   -- Billed: the actual cost (a cancelled line the supplier still billed counts too); else planned.
                   COALESCE(sum(CASE WHEN q.billed THEN q.actual_base ELSE q.cost_base END) FILTER (
                       WHERE q.supplier_kind = 'agency' AND (q.status = 'confirmed' OR (q.status = 'cancelled' AND q.billed))),
                       0)::numeric(14,2) AS agency_cost_base,
                   COALESCE(sum(q.actual_base - COALESCE(q.cost_base, 0)) FILTER (
                       WHERE q.supplier_kind = 'agency' AND q.billed AND q.status IN ('confirmed', 'cancelled')),
                       0)::numeric(14,2) AS cost_variance_base,
                   (count(*) FILTER (WHERE q.supplier_kind = 'agency' AND q.billed))::integer AS lines_billed,
                   COALESCE(sum(q.cancel_base), 0)::numeric(14,2) AS cancellation_cost_base,
                   COALESCE(sum(q.commission_base) FILTER (WHERE q.supplier_kind = 'agency' AND q.status = 'confirmed'),
                       0)::numeric(14,2) AS commission_income_base,
                   (count(*) FILTER (WHERE q.status = 'confirmed'))::integer AS lines_confirmed,
                   (count(*) FILTER (WHERE q.status = 'planning'))::integer AS lines_planning,
                   (count(*) FILTER (WHERE q.other_base))::integer AS lines_other_base
              FROM (
                    SELECT l.booking_line_id, l.supplier_kind, l.status, h.cost_base, h.sell_base, h.commission_base,
                           h.cancel_base, h.other_base,
                           (h.actual_base IS NOT NULL AND bill.live) AS billed, h.actual_base,
                           -- An AA booking billed in full: its invoiced amount at the quote rate, spread over the
                           -- booking's confirmed lines by their quoted cost (cumulative rounding in line id order, so
                           -- the shares add up to round(invoiced x rate, 2) once per booking).
                           CASE WHEN l.supplier_kind = 'aa' AND ai.complete AND ai.currency = h.cost_currency
                                     AND bk.currencies = 1 AND NOT bk.unquoted AND bk.tot_w > 0
                                     AND h.cost_rate IS NOT NULL
                                THEN round(ai.invoiced * h.cost_rate * bk.cum_w / bk.tot_w, 2)
                                     - round(ai.invoiced * h.cost_rate * (bk.cum_w - bk.w) / bk.tot_w, 2)
                                ELSE h.cost_base END AS aa_cost,
                           (l.supplier_kind = 'aa' AND COALESCE(ai.complete, false)) AS aa_invoiced,
                           -- The booking's invoiced sum against the sum of its lines' quoted cost (one currency).
                           (l.supplier_kind = 'aa' AND COALESCE(ai.complete, false)
                            AND (ai.currency IS DISTINCT FROM h.cost_currency
                                 OR bk.currencies IS DISTINCT FROM 1::bigint OR COALESCE(bk.unquoted, true)
                                 OR ai.invoiced IS DISTINCT FROM bk.quoted)) AS aa_mismatch
                      FROM crm.booking_line l
                     CROSS JOIN LATERAL (
                            SELECT max(m.amount_base) FILTER (WHERE m.kind = 'cost' AND m.base_currency = b.base_currency)
                                       AS cost_base,
                                   max(m.amount) FILTER (WHERE m.kind = 'cost') AS cost_amount,
                                   max(m.currency::text) FILTER (WHERE m.kind = 'cost') AS cost_currency,
                                   max(m.fx_rate) FILTER (WHERE m.kind = 'cost' AND m.base_currency = b.base_currency)
                                       AS cost_rate,
                                   max(m.amount_base) FILTER (WHERE m.kind = 'sell' AND m.base_currency = b.base_currency)
                                       AS sell_base,
                                   max(m.amount_base) FILTER (
                                       WHERE m.kind = 'actual_cost' AND m.base_currency = b.base_currency) AS actual_base,
                                   max(m.amount_base) FILTER (
                                       WHERE m.kind = 'commission_expected' AND m.base_currency = b.base_currency)
                                       AS commission_base,
                                   max(m.amount_base) FILTER (
                                       WHERE m.kind = 'cancellation_cost' AND m.base_currency = b.base_currency)
                                       AS cancel_base,
                                   COALESCE(bool_or(m.fx_rate IS NOT NULL AND m.base_currency <> b.base_currency), false)
                                       AS other_base
                              FROM crm.v_booking_line_money_current m
                             WHERE m.tenant_id = l.tenant_id AND m.booking_line_id = l.booking_line_id
                           ) h
                     CROSS JOIN LATERAL (
                            SELECT EXISTS (SELECT 1 FROM crm.supplier_bill_line sl
                                             JOIN crm.supplier_bill sb ON sb.supplier_bill_id = sl.supplier_bill_id
                                            WHERE sl.tenant_id = l.tenant_id AND sl.booking_line_id = l.booking_line_id
                                              AND sb.status <> 'void') AS live
                           ) bill
                      LEFT JOIN LATERAL (
                            SELECT c.currency::text AS currency, sum((e.value ->> 'amount')::numeric) AS invoiced,
                                   bool_or(COALESCE((e.value ->> 'complete')::boolean, false)) AS complete
                              FROM crm.aa_invoice_cache c
                             CROSS JOIN LATERAL jsonb_each(c.booking_amounts) e
                             WHERE c.tenant_id = l.tenant_id AND l.bk_booking_id IS NOT NULL
                               AND e.key = l.bk_booking_id AND c.invoice_kind = 'settlement' AND c.aa_status <> 'void'
                             GROUP BY c.currency
                             ORDER BY c.currency
                             LIMIT 1
                           ) ai ON true
                     -- The confirmed AA lines of the same AA booking (several lines of one accepted proposal share
                     -- one Booking booking): their quoted cost and this line's weight for the invoiced amount.
                      LEFT JOIN LATERAL (
                            SELECT g.quoted, g.currencies, g.unquoted,
                                   CASE WHEN g.quoted > 0 THEN h.cost_amount ELSE 1 END AS w,
                                   CASE WHEN g.quoted > 0 THEN g.cum_quoted ELSE g.cum_n END AS cum_w,
                                   CASE WHEN g.quoted > 0 THEN g.quoted ELSE g.n END AS tot_w
                              FROM (
                                    SELECT sum(oc.amount) AS quoted,
                                           sum(oc.amount) FILTER (WHERE o.booking_line_id <= l.booking_line_id)
                                               AS cum_quoted,
                                           count(*) AS n,
                                           count(*) FILTER (WHERE o.booking_line_id <= l.booking_line_id) AS cum_n,
                                           count(DISTINCT oc.currency) AS currencies,
                                           bool_or(oc.amount IS NULL) AS unquoted
                                      FROM crm.booking_line o
                                      LEFT JOIN crm.v_booking_line_money_current oc
                                        ON oc.tenant_id = o.tenant_id AND oc.booking_line_id = o.booking_line_id
                                       AND oc.kind = 'cost'
                                     WHERE o.tenant_id = l.tenant_id AND o.bk_booking_id = l.bk_booking_id
                                       AND o.supplier_kind = 'aa' AND o.status = 'confirmed' AND o.deleted_at IS NULL
                                   ) g
                             WHERE l.supplier_kind = 'aa' AND l.status = 'confirmed' AND l.bk_booking_id IS NOT NULL
                           ) bk ON true
                     WHERE l.tenant_id = t.tenant_id AND l.trip_id = t.trip_id AND l.deleted_at IS NULL
                   ) q
           ) ln
     -- The trip's share of its departures' costs: per_pax = amount x the trip's pax; per_departure = split by pax over
     -- the departure's booked trips (crm.v_departure_trip), by cumulative rounding in trip id order (the shares of the
     -- booked trips add up to the cost exactly; a lead with only a quote takes none).
     CROSS JOIN LATERAL (
            SELECT COALESCE(sum(CASE WHEN d.basis = 'per_pax' THEN round(d.amount_base * s.pax, 2)
                                     ELSE round(d.amount_base * s.cum_pax / s.total_pax, 2)
                                          - round(d.amount_base * (s.cum_pax - s.pax) / s.total_pax, 2) END), 0)::numeric(14,2)
                       AS departure_cost_base,
                   count(d.departure_cost_id)::integer AS departure_costs
              FROM crm.departure_cost d
             CROSS JOIN LATERAL (
                    SELECT (t.party_adults + cardinality(t.party_child_ages))::numeric AS pax,
                           sum(o.pax) AS total_pax,
                           sum(o.pax) FILTER (WHERE o.trip_id <= t.trip_id) AS cum_pax
                      FROM crm.v_departure_trip o
                     WHERE o.tenant_id = d.tenant_id AND o.departure_ref = d.departure_ref
                   ) s
             WHERE d.tenant_id = t.tenant_id AND d.base_currency = b.base_currency AND s.total_pax > 0
               AND EXISTS (SELECT 1 FROM crm.v_departure_trip me
                            WHERE me.tenant_id = t.tenant_id AND me.trip_id = t.trip_id
                              AND me.departure_ref = d.departure_ref)
           ) dp
     -- AA-1071 (crm-056): the trip's live partner commissions (accrued, approved, paid) frozen in today's base
     -- currency (a row computed in an earlier base currency or without a rate is left out).
     CROSS JOIN LATERAL (
            SELECT COALESCE(sum(pc.amount_base) FILTER (WHERE pc.base_currency = b.base_currency), 0)::numeric(14,2)
                       AS partner_commission_base
              FROM crm.partner_commission pc
             WHERE pc.tenant_id = t.tenant_id AND pc.trip_id = t.trip_id AND pc.status <> 'cancelled'
               AND pc.deleted_at IS NULL
           ) pc
     WHERE t.deleted_at IS NULL
  ) x;
REVOKE ALL ON crm.v_trip_pnl FROM crm_app;
GRANT SELECT ON crm.v_trip_pnl TO crm_app;
REVOKE ALL ON crm.v_trip_pnl FROM crm_app;
GRANT SELECT ON crm.v_trip_pnl TO crm_app;
COMMENT ON VIEW crm.v_trip_pnl IS 'AA-1068 (crm-051, item crm-30; AA-1071 crm-056: the partner commission): the profit of each live trip in the agency''s base currency: revenue_base = issued invoices (open, payment_claimed, paid, paid_unfulfillable) net of tax by kind (sales = every kind but service_fee and cancellation_fee) minus refunds net of tax, at crm.fx_resolve of the issue / receipt day; a trip cancelled with a charge (crm.cancellation_charge, crm-049) counts the charge net of tax at the cancel day''s rate in place of its sales, their refunds and its cancellation fee invoices (cancellation_charged); costs = AA lines (the quote''s frozen cost, or the AA settlement invoice of the booking once billed in full, crm.aa_invoice_cache, at the quote rate, spread over the booking''s confirmed lines by their quoted cost; aa_lines_mismatch = the confirmed AA lines of a booking billed in full at another amount or currency than the sum of its lines'' quotes) + agency lines (actual_cost while a live supplier bill names the line, else the planned cost) + AA cancellation fees (cancellation_cost) + the departure share (crm.departure_cost by pax over the booked trips of crm.v_departure_trip) + the sales partner commission (crm.partner_commission accrued, approved or paid, amount_base in today''s base currency; sales_partner_id = the trip''s); commission_income_base = the expected supplier commission of confirmed agency lines; margin_base = revenue + commission income - costs, margin_pct of revenue, margin_per_pax_base. Confirmed lines count, planning ones are counted apart. security_invoker: money rows reach owner / agent only (crm-014), so read it only through the margin-gated API.';

-- ── Post-checks ──────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT has_table_privilege('crm_app', 'crm.sales_partner', 'INSERT')
       OR NOT has_table_privilege('crm_app', 'crm.sales_partner_link', 'UPDATE')
       OR NOT has_table_privilege('crm_app', 'crm.sales_partner_otp', 'DELETE')
       OR NOT has_table_privilege('crm_app', 'crm.partner_commission', 'SELECT')
       OR NOT has_column_privilege('crm_app', 'crm.partner_commission', 'status', 'UPDATE')
       OR NOT has_column_privilege('crm_app', 'crm.trip', 'sales_partner_id', 'UPDATE')
       OR NOT has_column_privilege('crm_app', 'crm.dispatch_queue', 'sales_partner_id', 'INSERT')
       OR NOT has_column_privilege('crm_app', 'crm.conversation', 'sales_partner_id', 'INSERT')
       OR NOT has_function_privilege('crm_app', 'crm.partner_commission_sync(uuid)', 'EXECUTE')
       OR NOT has_table_privilege('crm_app', 'crm.v_trip_pnl', 'SELECT') THEN
        RAISE EXCEPTION 'crm-056: crm_app is missing a privilege on the new objects';
    END IF;
    IF has_table_privilege('crm_app', 'crm.partner_commission', 'INSERT')
       OR has_table_privilege('crm_app', 'crm.partner_commission', 'DELETE')
       OR has_column_privilege('crm_app', 'crm.partner_commission', 'amount', 'UPDATE')
       OR has_table_privilege('crm_app', 'crm.sales_partner_link', 'DELETE') THEN
        RAISE EXCEPTION 'crm-056: crm_app may write partner commission amounts or delete a partner link';
    END IF;
    IF has_table_privilege('crm_support_reader', 'crm.sales_partner', 'SELECT')
       OR has_table_privilege('crm_ai_reader', 'crm.sales_partner', 'SELECT')
       OR has_table_privilege('crm_insights', 'crm.partner_commission', 'SELECT')
       OR has_table_privilege('crm_ai_reader', 'crm.sales_partner_otp', 'SELECT') THEN
        RAISE EXCEPTION 'crm-056: a reader role must not read the sales partner data';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-056', now(), 'AA-1071: sales partners: crm.sales_partner (commission terms, CRM54), crm.trip / crm.form_submission sales_partner_id, crm.partner_commission + crm.partner_commission_sync and the trip trigger, crm.sales_partner_link (intake / view links), crm.sales_partner_otp (view sign-in codes), partner e-mail subject on crm.conversation / crm.dispatch_queue, crm.v_trip_pnl partner commission')
ON CONFLICT (version) DO NOTHING;

COMMIT;
