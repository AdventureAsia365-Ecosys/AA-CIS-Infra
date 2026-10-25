-- Migration crm-016: AA-946 (partner CRM, design v3 card CRM-18) — the thin full lifecycle: a text proposal the
-- client accepts on a signed link, the payment schedule and the agency's "mark paid" (manual payments), the traveller
-- portal base (one signed link and a per-person e-mail code), Stage 3 behind the deposit, e-sign v0 (typed name + the
-- code asked again), the computable booking / Stage 3 gates, and the erasure / hold rule extended to the new tables.
--
-- Owner: AA-Partner (api/migrations/016_crm_thin_lifecycle.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy DB
-- Migrate applies (Migration Copy Guard). Key crm-016. crm.erase_held and crm.erase_subject below are the crm-015 text
-- plus the lifecycle steps; a later key that replaces them starts from THIS text. crm.enforce_stage_transition is the
-- crm-012 text with the booking and Stage 3 gates made computable.
--
-- Why. Design v3 §6.3 card CRM-18 (M4 base, M7 manual, M11 base, M12 v0; checklist: text proposal + accept; schedule +
-- mark paid -> Booked; per-person OTP; Stage 3 after the deposit; e-sign v0; date ticks), §2.7 F6 / F8 / F9 / F10,
-- §2.9 (client-page rules 1, 2, 4), §3.3 groups E and F, §3.5 (stage transitions, date rule), §5.7 (e-sign flow; v0
-- has no PAdES seal yet: CRM-25). Card R: Stage 3 before the deposit -> 403 stage3_locked (the API) and CRM32 here.
-- Card E: no return date -> the trip stays Travelling and a task is raised (crm_stage_date_rule, AA-943).
--
-- What (every table name is the design's and already has its DM-7 row, root data standards Part B §7):
--   1. crm.agreement_doc (base template; design group E, M12): the agency's own booking terms and traveller waiver,
--      one row per version: kind booking_terms | waiver, version_label, body_text (the agency's terms; no client data
--      by design) and body_sha256 (set by a trigger), status draft -> published -> retired, published_at. One published
--      version per kind. A published or retired version never changes (crm.guard_sealed_row, CRM31).
--   2. crm.proposal (base template; design group E, M4 base): one version of the trip's text proposal: body_enc (vault
--      DEK, pii:free_text), currency, total_amount, deposit_amount (<= total), balance_due_on (set exactly when a
--      balance is left), terms_doc_id (the booking terms shown with it), price_hash (SHA-256 of what the client sees,
--      set at send), link_id (the client_link it went out on, SET NULL when that link is erased), status draft ->
--      sent -> accepted | superseded | withdrawn. Acceptance pins accepted_price_hash = price_hash, the terms version
--      and the typed full name (accepted_name_enc, pii:name). One accepted version per trip. Sealed after draft
--      (CRM31). A traveller erasure replaces the typed name with accepted_name_erased_at (11b).
--   3. crm.payment_schedule (base template; design group F, M7 manual): the accepted proposal's deposit and balance
--      rows (kind, amount, currency, due_on), status due -> paid | void, paid_at. One live row per (proposal, kind).
--      Sealed once paid or void (CRM31). A deposit row is never void (a deposit taken outside the CRM is marked paid
--      with its method), so an accepted proposal always keeps the way to Booked and to the portal.
--   4. crm.payment (append-only variant, crm.ledger_append_only of crm-014: DELETE only inside crm.erase_subject): one
--      manual payment the agency recorded against one schedule row (amount, currency, method, received_on). One per
--      schedule row in this card (partial payments, card payments and refunds: CRM-23).
--   5. crm.traveler_access (base template; design group E, M11 base): one traveller's portal access on one trip:
--      role lead | companion, link_id (the purpose portal client_link), status invited -> active, or revoked,
--      last_sign_in_at, stage3_submitted_at. crm.guard_traveler_access: stage3_submitted_at is set only while
--      crm.portal_unlocked(trip) holds (CRM32 stage3_locked, card R in the database): a paid deposit of the trip's
--      accepted proposal, or a move into Booked through the manual_booking override (the deposit was taken outside
--      the CRM) that was not undone.
--   6. crm.otp_challenge (base template; design group E, M11 / M12): a 6-digit e-mail code per person: purpose
--      sign_in | sign, code_hash (SHA-256 of the row id and the code; the code is never stored), attempts (<= 5),
--      expires_at (<= 10 minutes), status pending -> verified | failed | expired, and the portal session it opened
--      (session_hash, session_expires_at <= 12 hours), consumed_at for a signing code. Retention 24 hours (DM-7 row):
--      crm_app deletes expired rows (the hourly date-rule job). No hold guard: a credential row, nothing to keep.
--      The code mail (message_id) is stored with the code masked; the code itself waits in code_enc (vault DEK)
--      only while the code is pending and until the agency's mailbox sent it, so nobody at the agency can read it
--      in the Messages tab. delivery = dev_echo marks a code the Dev echo also returned in the API answer.
--   7. crm.signature_request (base template; design group E, M12 v0): one traveller's signature of one waiver
--      version: doc_sha256 pinned at signing, signed_name_enc (pii:name), the verified signing code (otp_id, SET
--      NULL when the 24-hour purge deletes the code row), evidence_sha256 (SHA-256 of the evidence record), status
--      pending -> signed | void. Sealed once signed (CRM31).
--   8. crm.client_link purposes: + proposal (the C-03 / C-04 page) and portal (the C-05 portal), both naming a
--      traveller.
--   9. crm.enforce_stage_transition (crm-012 text) with computable gates: proposal -> booked needs a paid deposit row
--      of the trip's accepted proposal, booked -> pre_departure needs intake_completeness.s3 = 100 (Stage 3 and the
--      waiver of every traveller, computed by the API); app.gate_override = booking / stage3 still lets a logged
--      override through. Refusal: CRM19 as before.
--  10. Same-agency keys (crm-006 rule 7b) for every reference.
--  11. The hold rule and erasure (crm-010 items 4, 10) extended:
--      a. crm.erase_held, the crm-015 text plus: a trip erase also reaches the travellers its portal rows name, a
--         traveller erase the trips theirs name;
--      b. crm.erase_subject, the crm-015 text plus: trip scope deletes signatures, codes, portal access, payments,
--         schedule rows and proposals first; traveller scope their signatures, codes and portal access, and the
--         name they typed to accept a proposal (accepted_name_enc := NULL, accepted_name_erased_at set: the
--         proposal of a trashed trip may outlive them while its money keeps the trip); the agency
--         erase all of them and the agreement versions. The signed-agreement and accounting exceptions of the DM-7
--         rows (kept beyond an erasure) are CRM-23 / CRM-25's: v0 erases them with the trip (Dev, synthetic data).
--      c. crm.guard_held_change (4h) on agreement_doc (agency hold), proposal, payment_schedule (trip_id),
--         traveler_access and signature_request (trip_id, traveler_id).
--   No NOLOGIN reader gets anything on the new tables.
--   crm.guard_sealed_row lets only crm.erase_subject (crm_owner with app.erasing on) change a sealed column.
--   SQLSTATEs CRM31 (row_sealed) and CRM32 (stage3_locked) are this file's; the next key
--   starts at CRM33.
--
-- Order: after crm-015 (AA-945); Guard 0 refuses to run before it is registered (erase_subject must build on the
-- crm-015 text).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); before the AA-946
-- code deploys nothing reads these objects, and the code merges only after this file is applied (S249 lesson).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-015 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-016: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-015') THEN
        RAISE EXCEPTION 'crm-016: crm-015 is not registered (CRM-17 mail, AA-945, lands first)';
    END IF;
    IF to_regclass('crm.message') IS NULL OR to_regclass('crm.client_link') IS NULL
       OR to_regprocedure('crm.ledger_append_only()') IS NULL
       OR to_regprocedure('crm.erase_subject(text,uuid,uuid,boolean)') IS NULL
       OR to_regprocedure('crm.erase_held(text,uuid,uuid)') IS NULL
       OR to_regprocedure('crm.guard_held_change()') IS NULL THEN
        RAISE EXCEPTION 'crm-016: crm.message (crm-015), crm.client_link (crm-012), crm.ledger_append_only (crm-014) or the crm-010 erase functions missing';
    END IF;
END $$;

-- ── Sealed rows: one guard for every table of this file ──────────────────────────────────────────
-- Trigger arguments: the status in which the row may still change, then the sealed columns. Once OLD.status is not
-- that status, a sealed column keeps its value (status moves, the acceptance / payment / signature columns and the
-- trash columns are not in the list).
CREATE OR REPLACE FUNCTION crm.guard_sealed_row() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    o jsonb := to_jsonb(OLD);
    n jsonb := to_jsonb(NEW);
    c text;
    i int;
BEGIN
    IF o->>'status' = TG_ARGV[0] THEN
        RETURN NEW;
    END IF;
    -- crm.erase_subject (SECURITY DEFINER, crm_owner, app.erasing on for its own transaction) may clear a sealed
    -- personal value (the typed name of an acceptance). The runtime role can never be crm_owner.
    IF current_user = 'crm_owner' AND current_setting('app.erasing', true) = 'on' THEN
        RETURN NEW;
    END IF;
    FOR i IN 1 .. TG_NARGS - 1 LOOP
        c := TG_ARGV[i];
        IF (n->c) IS DISTINCT FROM (o->c) THEN
            RAISE EXCEPTION 'crm: row_sealed (% of a % % row cannot change)', c, o->>'status', TG_TABLE_NAME
                USING ERRCODE = 'CRM31';
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_sealed_row() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_sealed_row() IS 'AA-946 (crm-016): BEFORE UPDATE trigger; argument 1 = the status in which the row may change, the others = sealed columns: once the row left that status a sealed column keeps its value, else CRM31 row_sealed (a sent proposal, a paid schedule row, a published agreement, a signed signature); only crm.erase_subject (crm_owner with app.erasing on) may change one.';

-- ── 1. crm.agreement_doc ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.agreement_doc (
    doc_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                    REFERENCES crm.tenant (tenant_id),
    kind            TEXT NOT NULL,
    version_label   TEXT NOT NULL,
    body_text       TEXT NOT NULL,
    body_sha256     BYTEA NOT NULL,
    status          TEXT NOT NULL DEFAULT 'draft',
    published_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ,
    deleted_by      TEXT,
    purge_after     TIMESTAMPTZ,
    CONSTRAINT agreement_doc_tenant_id_uq UNIQUE (tenant_id, doc_id),
    CONSTRAINT agreement_doc_version_uq UNIQUE (tenant_id, kind, version_label),
    CONSTRAINT agreement_doc_kind_chk CHECK (kind IN ('booking_terms', 'waiver')),
    CONSTRAINT agreement_doc_label_chk CHECK (
        char_length(version_label) BETWEEN 1 AND 40 AND version_label !~ '[[:cntrl:]]'
    ),
    CONSTRAINT agreement_doc_body_chk CHECK (char_length(body_text) BETWEEN 1 AND 100000 AND octet_length(body_sha256) = 32),
    CONSTRAINT agreement_doc_status_chk CHECK (status IN ('draft', 'published', 'retired')),
    CONSTRAINT agreement_doc_published_chk CHECK ((status = 'draft') = (published_at IS NULL)),
    CONSTRAINT agreement_doc_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS agreement_doc_one_published_uq ON crm.agreement_doc (tenant_id, kind)
    WHERE status = 'published' AND deleted_at IS NULL;
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('agreement_doc', 'draft', 'published'),
    ('agreement_doc', 'published', 'retired')
ON CONFLICT DO NOTHING;
REVOKE DELETE, TRUNCATE ON crm.agreement_doc FROM crm_app;
COMMENT ON TABLE crm.agreement_doc IS 'AA-946 (crm-016; design v3 group E, M12): one version of the agency''s own booking terms or traveller waiver (kind booking_terms | waiver). body_text is the agency''s text (no client data by design), body_sha256 its SHA-256 (trigger-set), pinned by every acceptance and signature. draft -> published -> retired; one published version per kind; a published or retired version never changes (crm.guard_sealed_row, CRM31). crm_app never deletes one; erased with the agency.';
COMMENT ON COLUMN crm.agreement_doc.body_sha256 IS 'SHA-256 of body_text (UTF-8), set by crm.set_agreement_doc_sha256 on every write: a proposal acceptance and a signature pin it';
CREATE OR REPLACE FUNCTION crm.set_agreement_doc_sha256() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    NEW.body_sha256 := sha256(convert_to(NEW.body_text, 'UTF8'));
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.set_agreement_doc_sha256() FROM PUBLIC;
COMMENT ON FUNCTION crm.set_agreement_doc_sha256() IS 'AA-946 (crm-016): body_sha256 = SHA-256 of body_text (UTF-8) on every insert and update, whatever the writer sent (a generated column cannot use convert_to, which is only STABLE).';
CREATE OR REPLACE TRIGGER agreement_doc_sha256 BEFORE INSERT OR UPDATE ON crm.agreement_doc
    FOR EACH ROW EXECUTE FUNCTION crm.set_agreement_doc_sha256();

-- ── 2. crm.proposal ──────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.proposal (
    proposal_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                          REFERENCES crm.tenant (tenant_id),
    trip_id               UUID NOT NULL,
    version               INTEGER NOT NULL,
    status                TEXT NOT NULL DEFAULT 'draft',
    body_enc              BYTEA NOT NULL,
    currency              CHAR(3) NOT NULL,
    total_amount          NUMERIC(14, 2) NOT NULL,
    deposit_amount        NUMERIC(14, 2) NOT NULL,
    balance_due_on        DATE,
    terms_doc_id          UUID,
    price_hash            BYTEA,
    link_id               UUID,
    sent_at               TIMESTAMPTZ,
    accepted_at           TIMESTAMPTZ,
    accepted_name_enc     BYTEA,
    accepted_name_erased_at TIMESTAMPTZ,
    accepted_price_hash   BYTEA,
    accepted_terms_doc_id UUID,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at            TIMESTAMPTZ,
    deleted_by            TEXT,
    purge_after           TIMESTAMPTZ,
    CONSTRAINT proposal_tenant_id_uq UNIQUE (tenant_id, proposal_id),
    CONSTRAINT proposal_trip_uq UNIQUE (tenant_id, proposal_id, trip_id),
    CONSTRAINT proposal_version_uq UNIQUE (tenant_id, trip_id, version),
    CONSTRAINT proposal_trip_fk FOREIGN KEY (tenant_id, trip_id) REFERENCES crm.trip (tenant_id, trip_id),
    CONSTRAINT proposal_terms_fk FOREIGN KEY (tenant_id, terms_doc_id) REFERENCES crm.agreement_doc (tenant_id, doc_id),
    CONSTRAINT proposal_accepted_terms_fk FOREIGN KEY (tenant_id, accepted_terms_doc_id)
        REFERENCES crm.agreement_doc (tenant_id, doc_id),
    CONSTRAINT proposal_link_fk FOREIGN KEY (tenant_id, link_id)
        REFERENCES crm.client_link (tenant_id, link_id) ON DELETE SET NULL (link_id),
    CONSTRAINT proposal_version_chk CHECK (version BETWEEN 1 AND 999),
    CONSTRAINT proposal_status_chk CHECK (status IN ('draft', 'sent', 'accepted', 'superseded', 'withdrawn')),
    CONSTRAINT proposal_enc_chk CHECK (octet_length(body_enc) >= 30 AND coalesce(octet_length(accepted_name_enc), 30) >= 30),
    CONSTRAINT proposal_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT proposal_amounts_chk CHECK (
        total_amount > 0 AND deposit_amount > 0 AND deposit_amount <= total_amount
        AND (balance_due_on IS NULL) = (deposit_amount = total_amount)
    ),
    CONSTRAINT proposal_hash_chk CHECK (
        coalesce(octet_length(price_hash), 32) = 32 AND coalesce(octet_length(accepted_price_hash), 32) = 32
    ),
    CONSTRAINT proposal_sent_chk CHECK (
        (status = 'draft' OR (status = 'withdrawn' AND sent_at IS NULL)) = (price_hash IS NULL AND sent_at IS NULL)
    ),
    CONSTRAINT proposal_accepted_chk CHECK (
        (status = 'accepted') = (accepted_at IS NOT NULL)
        AND (accepted_at IS NULL) = (accepted_name_enc IS NULL AND accepted_name_erased_at IS NULL)
        AND (accepted_name_enc IS NULL OR accepted_name_erased_at IS NULL)
        AND (accepted_at IS NULL) = (accepted_price_hash IS NULL)
        AND (accepted_price_hash IS NULL OR accepted_price_hash = price_hash)
        AND (accepted_terms_doc_id IS NULL OR accepted_terms_doc_id = terms_doc_id)
        AND (accepted_at IS NULL OR terms_doc_id IS NULL OR accepted_terms_doc_id IS NOT NULL)
    ),
    CONSTRAINT proposal_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS proposal_one_accepted_uq ON crm.proposal (tenant_id, trip_id)
    WHERE status = 'accepted' AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS proposal_one_sent_uq ON crm.proposal (tenant_id, trip_id)
    WHERE status = 'sent' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS proposal_link_idx ON crm.proposal (tenant_id, link_id) WHERE link_id IS NOT NULL;
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('proposal', 'draft', 'sent'),
    ('proposal', 'draft', 'withdrawn'),
    ('proposal', 'sent', 'accepted'),
    ('proposal', 'sent', 'superseded'),
    ('proposal', 'sent', 'withdrawn')
ON CONFLICT DO NOTHING;
REVOKE DELETE, TRUNCATE ON crm.proposal FROM crm_app;
COMMENT ON TABLE crm.proposal IS 'AA-946 (crm-016; design v3 group E, M4 base): one version of a trip''s text proposal. The text is under the tenant vault DEK; total, deposit and balance date are the client''s sell amounts (no net, cost or margin here). draft -> sent (price_hash = SHA-256 of what the client sees, one sent version per trip, a new send supersedes the old) -> accepted on the signed link (typed full name, the terms version and the price hash pinned; one accepted version per trip) | superseded | withdrawn. Sealed after draft (crm.guard_sealed_row, CRM31). crm_app never deletes one; erasure through crm.erase_subject.';
COMMENT ON COLUMN crm.proposal.body_enc IS 'pii:free_text; the proposal text the agent wrote, AES-256-GCM under the tenant vault DEK (AAD tenant, proposal, body_enc, row id)';
COMMENT ON COLUMN crm.proposal.price_hash IS 'SHA-256 of the canonical record the client sees (version, currency, amounts, balance date, text hash, terms hash), set at send; acceptance must name the same hash';
COMMENT ON COLUMN crm.proposal.accepted_name_enc IS 'pii:name; the full name the client typed to accept, AES-256-GCM under the tenant vault DEK; NULL once crm.erase_subject erased the traveller who accepted (accepted_name_erased_at)';
COMMENT ON COLUMN crm.proposal.accepted_name_erased_at IS 'when crm.erase_subject (traveller scope) removed the typed acceptance name; the acceptance time, price hash and terms version stay';

-- ── 3. crm.payment_schedule ──────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.payment_schedule (
    schedule_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                    REFERENCES crm.tenant (tenant_id),
    trip_id         UUID NOT NULL,
    proposal_id     UUID NOT NULL,
    kind            TEXT NOT NULL,
    amount          NUMERIC(14, 2) NOT NULL,
    currency        CHAR(3) NOT NULL,
    due_on          DATE NOT NULL,
    status          TEXT NOT NULL DEFAULT 'due',
    paid_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ,
    deleted_by      TEXT,
    purge_after     TIMESTAMPTZ,
    CONSTRAINT payment_schedule_tenant_id_uq UNIQUE (tenant_id, schedule_id),
    CONSTRAINT payment_schedule_trip_uq UNIQUE (tenant_id, schedule_id, trip_id),
    CONSTRAINT payment_schedule_proposal_fk FOREIGN KEY (tenant_id, proposal_id, trip_id)
        REFERENCES crm.proposal (tenant_id, proposal_id, trip_id),
    CONSTRAINT payment_schedule_kind_chk CHECK (kind IN ('deposit', 'balance')),
    CONSTRAINT payment_schedule_amount_chk CHECK (amount > 0),
    CONSTRAINT payment_schedule_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT payment_schedule_status_chk CHECK (status IN ('due', 'paid', 'void')),
    CONSTRAINT payment_schedule_paid_chk CHECK ((status = 'paid') = (paid_at IS NOT NULL)),
    CONSTRAINT payment_schedule_deposit_void_chk CHECK (kind <> 'deposit' OR status <> 'void'),
    CONSTRAINT payment_schedule_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS payment_schedule_live_uq ON crm.payment_schedule (tenant_id, proposal_id, kind)
    WHERE status <> 'void' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS payment_schedule_trip_idx ON crm.payment_schedule (tenant_id, trip_id);
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('payment_schedule', 'due', 'paid'),
    ('payment_schedule', 'due', 'void')
ON CONFLICT DO NOTHING;
REVOKE DELETE, TRUNCATE ON crm.payment_schedule FROM crm_app;
COMMENT ON TABLE crm.payment_schedule IS 'AA-946 (crm-016; design v3 group F, M7 manual): the deposit and balance rows of a trip''s accepted proposal (kind, amount, currency, due date), due -> paid (the agency marked a payment received) | void (a balance row only: a deposit taken outside the CRM is marked paid with its method). One live row per proposal and kind. Sealed once paid or void (CRM31). A paid deposit of the accepted proposal opens the gate proposal -> booked (crm.enforce_stage_transition). crm_app never deletes one; erasure through crm.erase_subject.';

-- ── 4. crm.payment ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.payment (
    payment_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                    REFERENCES crm.tenant (tenant_id),
    trip_id         UUID NOT NULL,
    schedule_id     UUID NOT NULL,
    amount          NUMERIC(14, 2) NOT NULL,
    currency        CHAR(3) NOT NULL,
    method          TEXT NOT NULL,
    received_on     DATE NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    CONSTRAINT payment_tenant_id_uq UNIQUE (tenant_id, payment_id),
    CONSTRAINT payment_schedule_once_uq UNIQUE (tenant_id, schedule_id),
    CONSTRAINT payment_schedule_fk FOREIGN KEY (tenant_id, schedule_id, trip_id)
        REFERENCES crm.payment_schedule (tenant_id, schedule_id, trip_id),
    CONSTRAINT payment_amount_chk CHECK (amount > 0),
    CONSTRAINT payment_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT payment_method_chk CHECK (method IN ('bank_transfer', 'cash', 'card_offline', 'other'))
);
CREATE INDEX IF NOT EXISTS payment_trip_idx ON crm.payment (tenant_id, trip_id);
CREATE OR REPLACE TRIGGER payment_append_only BEFORE UPDATE OR DELETE ON crm.payment
    FOR EACH ROW EXECUTE FUNCTION crm.ledger_append_only();
CREATE OR REPLACE TRIGGER payment_no_truncate BEFORE TRUNCATE ON crm.payment
    FOR EACH STATEMENT EXECUTE FUNCTION crm.ledger_append_only();
REVOKE UPDATE, DELETE, TRUNCATE ON crm.payment FROM crm_app;
COMMENT ON TABLE crm.payment IS 'AA-946 (crm-016; design v3 group F, M7 manual): one payment the agency marked received against one schedule row (amount, currency, method, received_on; no card or bank data). Append-only (crm.ledger_append_only: DELETE only inside crm.erase_subject). One per schedule row in CRM-18; card payments, partial payments and refunds are CRM-23. The trip''s delete block reads the trip_commitment row (kind payment) the API writes with it.';

-- ── 5. crm.traveler_access ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.traveler_access (
    access_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                        REFERENCES crm.tenant (tenant_id),
    trip_id             UUID NOT NULL,
    traveler_id         UUID NOT NULL,
    role                TEXT NOT NULL,
    link_id             UUID,
    status              TEXT NOT NULL DEFAULT 'invited',
    last_sign_in_at     TIMESTAMPTZ,
    stage3_submitted_at TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    deleted_by          TEXT,
    purge_after         TIMESTAMPTZ,
    CONSTRAINT traveler_access_tenant_id_uq UNIQUE (tenant_id, access_id),
    CONSTRAINT traveler_access_subject_uq UNIQUE (tenant_id, access_id, trip_id, traveler_id),
    CONSTRAINT traveler_access_trip_fk FOREIGN KEY (tenant_id, trip_id) REFERENCES crm.trip (tenant_id, trip_id),
    CONSTRAINT traveler_access_traveler_fk FOREIGN KEY (tenant_id, traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id),
    CONSTRAINT traveler_access_party_fk FOREIGN KEY (trip_id, traveler_id)
        REFERENCES crm.trip_traveler (trip_id, traveler_id),
    CONSTRAINT traveler_access_link_fk FOREIGN KEY (tenant_id, link_id)
        REFERENCES crm.client_link (tenant_id, link_id) ON DELETE SET NULL (link_id),
    CONSTRAINT traveler_access_role_chk CHECK (role IN ('lead', 'companion')),
    CONSTRAINT traveler_access_status_chk CHECK (status IN ('invited', 'active', 'revoked')),
    CONSTRAINT traveler_access_sign_in_chk CHECK (status <> 'active' OR last_sign_in_at IS NOT NULL),
    CONSTRAINT traveler_access_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS traveler_access_live_uq ON crm.traveler_access (tenant_id, trip_id, traveler_id)
    WHERE status <> 'revoked' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS traveler_access_link_idx ON crm.traveler_access (tenant_id, link_id) WHERE link_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS traveler_access_traveler_idx ON crm.traveler_access (traveler_id);
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('traveler_access', 'invited', 'active'),
    ('traveler_access', 'invited', 'revoked'),
    ('traveler_access', 'active', 'revoked')
ON CONFLICT DO NOTHING;
REVOKE DELETE, TRUNCATE ON crm.traveler_access FROM crm_app;
COMMENT ON TABLE crm.traveler_access IS 'AA-946 (crm-016; design v3 group E, M11 base, R22): one traveller''s portal access on one trip: their own signed link (client_link purpose portal; a re-issue replaces link_id), role lead | companion, invited -> active (first sign-in with the e-mail code) | revoked, the last sign-in, and when they sent Stage 3. stage3_submitted_at is set only after the deposit (crm.guard_traveler_access, CRM32). crm_app never deletes one; erasure through crm.erase_subject.';

-- The portal's lock (card R): the API (app.stages.PORTAL_UNLOCKED_SQL) and the guard below read this one predicate.
CREATE OR REPLACE FUNCTION crm.portal_unlocked(p_trip uuid) RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (SELECT 1 FROM crm.payment_schedule s
                     JOIN crm.proposal p ON p.proposal_id = s.proposal_id
                    WHERE s.trip_id = p_trip AND s.kind = 'deposit' AND s.status = 'paid' AND s.deleted_at IS NULL
                      AND p.status = 'accepted' AND p.deleted_at IS NULL)
        OR EXISTS (SELECT 1 FROM crm.trip_stage_history h
                    WHERE h.trip_id = p_trip AND h.to_stage = 'booked' AND h.override_reason_code = 'manual_booking'
                      AND NOT EXISTS (SELECT 1 FROM crm.trip_stage_history u
                                       WHERE u.trip_id = p_trip AND u.undo_of = h.history_id))
$$;
REVOKE ALL ON FUNCTION crm.portal_unlocked(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.portal_unlocked(uuid) TO crm_app;
COMMENT ON FUNCTION crm.portal_unlocked(uuid) IS 'AA-946 (crm-016, card R): true when the trip''s portal Stage 3 and waiver signing are open: a paid deposit of the trip''s accepted proposal, or a move into booked with the manual_booking override (the deposit was taken outside the CRM) that was not undone. Invoker rights (RLS: one agency).';

CREATE OR REPLACE FUNCTION crm.guard_traveler_access() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NEW.stage3_submitted_at IS NOT NULL
       AND (TG_OP = 'INSERT' OR NEW.stage3_submitted_at IS DISTINCT FROM OLD.stage3_submitted_at)
       AND NOT crm.portal_unlocked(NEW.trip_id) THEN
        RAISE EXCEPTION 'crm: stage3_locked (Stage 3 opens after the deposit is paid)' USING ERRCODE = 'CRM32';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_traveler_access() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_traveler_access() IS 'AA-946 (crm-016, card R): Stage 3 is recorded (stage3_submitted_at) only while crm.portal_unlocked(trip) holds (a paid deposit of the accepted proposal, or a manual_booking override into booked that was not undone), else CRM32 stage3_locked. Invoker rights (RLS: one agency).';
CREATE OR REPLACE TRIGGER traveler_access_stage3_guard
    BEFORE INSERT OR UPDATE ON crm.traveler_access
    FOR EACH ROW EXECUTE FUNCTION crm.guard_traveler_access();

-- ── 6. crm.otp_challenge ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.otp_challenge (
    otp_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                        REFERENCES crm.tenant (tenant_id),
    access_id           UUID NOT NULL,
    trip_id             UUID NOT NULL,
    traveler_id         UUID NOT NULL,
    purpose             TEXT NOT NULL,
    code_hash           BYTEA NOT NULL,
    attempts            SMALLINT NOT NULL DEFAULT 0,
    status              TEXT NOT NULL DEFAULT 'pending',
    expires_at          TIMESTAMPTZ NOT NULL,
    verified_at         TIMESTAMPTZ,
    session_hash        BYTEA,
    session_expires_at  TIMESTAMPTZ,
    consumed_at         TIMESTAMPTZ,
    message_id          UUID,
    code_enc            BYTEA,
    delivery            TEXT NOT NULL DEFAULT 'mailbox',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    deleted_by          TEXT,
    purge_after         TIMESTAMPTZ,
    CONSTRAINT otp_challenge_tenant_id_uq UNIQUE (tenant_id, otp_id),
    CONSTRAINT otp_challenge_message_fk FOREIGN KEY (tenant_id, message_id)
        REFERENCES crm.message (tenant_id, message_id) ON DELETE SET NULL (message_id),
    CONSTRAINT otp_challenge_delivery_chk CHECK (delivery IN ('mailbox', 'dev_echo')),
    CONSTRAINT otp_challenge_code_enc_chk CHECK (
        code_enc IS NULL OR (status = 'pending' AND octet_length(code_enc) >= 30)
    ),
    CONSTRAINT otp_challenge_session_uq UNIQUE (session_hash),
    CONSTRAINT otp_challenge_access_fk FOREIGN KEY (tenant_id, access_id, trip_id, traveler_id)
        REFERENCES crm.traveler_access (tenant_id, access_id, trip_id, traveler_id),
    CONSTRAINT otp_challenge_purpose_chk CHECK (purpose IN ('sign_in', 'sign')),
    CONSTRAINT otp_challenge_hash_chk CHECK (
        octet_length(code_hash) = 32 AND coalesce(octet_length(session_hash), 32) = 32
    ),
    CONSTRAINT otp_challenge_attempts_chk CHECK (attempts BETWEEN 0 AND 5),
    CONSTRAINT otp_challenge_status_chk CHECK (status IN ('pending', 'verified', 'failed', 'expired')),
    CONSTRAINT otp_challenge_expiry_chk CHECK (
        expires_at > created_at AND expires_at <= created_at + interval '10 minutes'
    ),
    CONSTRAINT otp_challenge_verified_chk CHECK (
        (status = 'verified' OR (status = 'expired' AND verified_at IS NOT NULL)) = (verified_at IS NOT NULL)
    ),
    CONSTRAINT otp_challenge_session_chk CHECK (
        (session_hash IS NULL) = (session_expires_at IS NULL)
        AND (session_hash IS NULL OR (purpose = 'sign_in' AND verified_at IS NOT NULL
                                      AND session_expires_at <= verified_at + interval '12 hours'))
        AND (consumed_at IS NULL OR (purpose = 'sign' AND verified_at IS NOT NULL))
    ),
    CONSTRAINT otp_challenge_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS otp_challenge_access_idx ON crm.otp_challenge (tenant_id, access_id, created_at DESC);
CREATE INDEX IF NOT EXISTS otp_challenge_created_idx ON crm.otp_challenge (tenant_id, created_at);
CREATE INDEX IF NOT EXISTS otp_challenge_message_idx ON crm.otp_challenge (tenant_id, message_id)
    WHERE message_id IS NOT NULL;
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('otp_challenge', 'pending', 'verified'),
    ('otp_challenge', 'pending', 'failed'),
    ('otp_challenge', 'pending', 'expired'),
    ('otp_challenge', 'verified', 'expired')
ON CONFLICT DO NOTHING;
REVOKE TRUNCATE ON crm.otp_challenge FROM crm_app;
COMMENT ON TABLE crm.otp_challenge IS 'AA-946 (crm-016; design v3 group E, M11 / M12, §2.9 rule 1): a 6-digit e-mail code for one traveller''s portal access: purpose sign_in (opens a portal session of at most 12 hours: session_hash = SHA-256 of the session token, never the token) or sign (asked again at signing, consumed once). code_hash = SHA-256 of the row id and the code; at most 5 attempts; valid 10 minutes. Retention 24 hours (DM-7): crm_app deletes older rows (the hourly crm_stage_date_rule run). No hold guard: a credential row.';
COMMENT ON COLUMN crm.otp_challenge.code_hash IS 'conf:credential; SHA-256 of (otp_id bytes || the 6-digit code); the code itself is never stored';
COMMENT ON COLUMN crm.otp_challenge.code_enc IS 'conf:credential; the 6-digit code under the tenant vault DEK, kept only while the code is pending and its mail (message_id) is not sent yet: the mail sender puts it into the mail at send time and clears it; the stored message shows the code masked';
COMMENT ON COLUMN crm.otp_challenge.message_id IS 'the code mail (crm.message, stored with the code masked) the agency''s mailbox sends; SET NULL when that message is erased';
COMMENT ON COLUMN crm.otp_challenge.delivery IS 'mailbox (the code reached only the traveller''s e-mail) | dev_echo (PORTAL_OTP_DEV_ECHO, Dev only: the API answer carried the code too); written into the signature evidence';
COMMENT ON COLUMN crm.otp_challenge.session_hash IS 'conf:credential; SHA-256 of the portal session token a verified sign-in code opened (never the token)';

-- ── 7. crm.signature_request ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.signature_request (
    request_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                    REFERENCES crm.tenant (tenant_id),
    trip_id         UUID NOT NULL,
    traveler_id     UUID NOT NULL,
    access_id       UUID NOT NULL,
    doc_id          UUID NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    doc_sha256      BYTEA,
    signed_at       TIMESTAMPTZ,
    signed_name_enc BYTEA,
    otp_id          UUID,
    evidence_sha256 BYTEA,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ,
    deleted_by      TEXT,
    purge_after     TIMESTAMPTZ,
    CONSTRAINT signature_request_tenant_id_uq UNIQUE (tenant_id, request_id),
    CONSTRAINT signature_request_access_fk FOREIGN KEY (tenant_id, access_id, trip_id, traveler_id)
        REFERENCES crm.traveler_access (tenant_id, access_id, trip_id, traveler_id),
    CONSTRAINT signature_request_doc_fk FOREIGN KEY (tenant_id, doc_id) REFERENCES crm.agreement_doc (tenant_id, doc_id),
    CONSTRAINT signature_request_otp_fk FOREIGN KEY (tenant_id, otp_id)
        REFERENCES crm.otp_challenge (tenant_id, otp_id) ON DELETE SET NULL (otp_id),
    CONSTRAINT signature_request_status_chk CHECK (status IN ('pending', 'signed', 'void')),
    CONSTRAINT signature_request_signed_chk CHECK (
        (status = 'signed') = (signed_at IS NOT NULL)
        AND (signed_at IS NULL) = (signed_name_enc IS NULL)
        AND (signed_at IS NULL) = (doc_sha256 IS NULL)
        AND (signed_at IS NULL) = (evidence_sha256 IS NULL)
        AND (signed_at IS NOT NULL OR otp_id IS NULL)
    ),
    CONSTRAINT signature_request_hash_chk CHECK (
        coalesce(octet_length(doc_sha256), 32) = 32 AND coalesce(octet_length(evidence_sha256), 32) = 32
        AND coalesce(octet_length(signed_name_enc), 30) >= 30
    ),
    CONSTRAINT signature_request_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS signature_request_live_uq ON crm.signature_request (tenant_id, trip_id, traveler_id, doc_id)
    WHERE status <> 'void' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS signature_request_access_idx ON crm.signature_request (tenant_id, access_id);
CREATE INDEX IF NOT EXISTS signature_request_otp_idx ON crm.signature_request (tenant_id, otp_id) WHERE otp_id IS NOT NULL;
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('signature_request', 'pending', 'signed'),
    ('signature_request', 'pending', 'void')
ON CONFLICT DO NOTHING;
REVOKE DELETE, TRUNCATE ON crm.signature_request FROM crm_app;
COMMENT ON TABLE crm.signature_request IS 'AA-946 (crm-016; design v3 group E, M12 v0, §5.7): one traveller''s signature of one waiver version on one trip: pending -> signed (typed full name under the tenant vault DEK, the document hash pinned, the verified signing code, SHA-256 of the evidence record) | void. v0 = no PDF and no PAdES seal (CRM-25). Sealed once signed (CRM31). The trip''s delete block reads the trip_commitment row (kind signature) the API writes with it. crm_app never deletes one; erasure through crm.erase_subject.';
COMMENT ON COLUMN crm.signature_request.signed_name_enc IS 'pii:name; the full name the traveller typed to sign, AES-256-GCM under the tenant vault DEK';
COMMENT ON COLUMN crm.signature_request.evidence_sha256 IS 'SHA-256 of the canonical evidence record (request, trip, traveller, document hash, signing code id, signed at, typed-name hash, consent ticks)';

-- ── 8. crm.client_link purposes ──────────────────────────────────────────────────────────────────
ALTER TABLE crm.client_link DROP CONSTRAINT IF EXISTS client_link_purpose_chk;
ALTER TABLE crm.client_link ADD CONSTRAINT client_link_purpose_chk CHECK (
    purpose IN ('stage2_form', 'proposal', 'portal') AND traveler_id IS NOT NULL
);
COMMENT ON COLUMN crm.client_link.purpose IS 'the page the link opens: stage2_form (C-02, AA-943), proposal (C-03 / C-04 accept, AA-946), portal (C-05 portal sign-in, AA-946); every purpose names its traveller';

-- ── RLS, triggers and hold guards on the new tenant tables ───────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['agreement_doc', 'proposal', 'payment_schedule', 'payment', 'traveler_access',
                             'otp_challenge', 'signature_request'] LOOP
        EXECUTE format('ALTER TABLE crm.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE crm.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON crm.%I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON crm.%I '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)', t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['agreement_doc', 'proposal', 'payment_schedule', 'traveler_access', 'otp_challenge',
                             'signature_request'] LOOP
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON crm.%I FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at()',
            t || '_set_updated_at', t);
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE OF status ON crm.%I '
            'FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition()', t || '_status_transition', t);
    END LOOP;
    -- Sealed rows (CRM31): the status in which the row may change, then the columns that never change after it.
    EXECUTE 'CREATE OR REPLACE TRIGGER agreement_doc_sealed BEFORE UPDATE ON crm.agreement_doc FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_sealed_row(''draft'', ''kind'', ''version_label'', ''body_text'', '
            '''published_at'', ''tenant_id'')';
    EXECUTE 'CREATE OR REPLACE TRIGGER proposal_sealed BEFORE UPDATE ON crm.proposal FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_sealed_row(''draft'', ''trip_id'', ''version'', ''body_enc'', ''currency'', '
            '''total_amount'', ''deposit_amount'', ''balance_due_on'', ''terms_doc_id'', ''price_hash'', ''sent_at'', '
            '''tenant_id'')';
    -- The acceptance is written on the move sent -> accepted only, and never changes afterwards.
    EXECUTE 'CREATE OR REPLACE TRIGGER proposal_acceptance_sealed BEFORE UPDATE ON crm.proposal FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_sealed_row(''sent'', ''accepted_at'', ''accepted_name_enc'', '
            '''accepted_name_erased_at'', ''accepted_price_hash'', ''accepted_terms_doc_id'')';
    EXECUTE 'CREATE OR REPLACE TRIGGER payment_schedule_sealed BEFORE UPDATE ON crm.payment_schedule FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_sealed_row(''due'', ''trip_id'', ''proposal_id'', ''kind'', ''amount'', '
            '''currency'', ''due_on'', ''paid_at'', ''tenant_id'')';
    EXECUTE 'CREATE OR REPLACE TRIGGER signature_request_sealed BEFORE UPDATE ON crm.signature_request FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_sealed_row(''pending'', ''trip_id'', ''traveler_id'', ''access_id'', '
            '''doc_id'', ''doc_sha256'', ''signed_at'', ''signed_name_enc'', ''evidence_sha256'', ''tenant_id'')';
    -- 11c. Hold rule 4h.
    EXECUTE 'DROP TRIGGER IF EXISTS agreement_doc_hold_guard ON crm.agreement_doc';
    EXECUTE 'CREATE TRIGGER agreement_doc_hold_guard BEFORE DELETE OR UPDATE ON crm.agreement_doc FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_held_change()';
    FOREACH t IN ARRAY ARRAY['proposal', 'payment_schedule'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON crm.%I', t || '_hold_guard', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE DELETE OR UPDATE ON crm.%I FOR EACH ROW '
                       'EXECUTE FUNCTION crm.guard_held_change(''trip_id'')', t || '_hold_guard', t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['traveler_access', 'signature_request'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON crm.%I', t || '_hold_guard', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE DELETE OR UPDATE ON crm.%I FOR EACH ROW '
                       'EXECUTE FUNCTION crm.guard_held_change(''trip_id'', ''traveler_id'')', t || '_hold_guard', t);
    END LOOP;
END $$;

-- ── 9. The stage trigger function: computable booking and Stage 3 gates ──────────────────────────
-- The crm-012 text; only the gate block (2a) changes.
CREATE OR REPLACE FUNCTION crm.enforce_stage_transition() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_undo text := NULLIF(current_setting('app.stage_undo', true), '');
    v_override text := COALESCE(NULLIF(current_setting('app.gate_override', true), ''), '');
    v_actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    v_gate text;
    r record;
BEGIN
    IF NEW.stage IS NOT DISTINCT FROM OLD.stage THEN
        RETURN NEW;
    END IF;

    -- 2b. Undo: the exact reverse of the trip's latest move, within 15 s, by the actor who made it.
    IF v_undo IS NOT NULL THEN
        IF TG_TABLE_NAME <> 'trip' OR v_undo !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
            RAISE EXCEPTION 'crm: undo_not_allowed (app.stage_undo is not a move of this trip)' USING ERRCODE = 'CRM20';
        END IF;
        SELECT h.history_id, h.from_stage, h.to_stage, h.at, h.created_by, h.undo_of INTO r
          FROM crm.trip_stage_history h
         WHERE h.history_id = v_undo::uuid AND h.trip_id = OLD.trip_id;
        IF NOT FOUND
           OR r.undo_of IS NOT NULL
           OR r.from_stage IS NULL
           OR r.to_stage IS DISTINCT FROM OLD.stage
           OR r.from_stage IS DISTINCT FROM NEW.stage
           OR r.to_stage = 'cancelled'
           OR r.at < now() - interval '15 seconds'
           OR r.created_by IS DISTINCT FROM v_actor
           OR NOT EXISTS (SELECT 1 FROM crm.status_transition t
                           WHERE t.table_name = 'trip' AND t.from_status = r.from_stage AND t.to_status = r.to_stage)
           OR EXISTS (SELECT 1 FROM crm.trip_stage_history h
                       WHERE h.trip_id = OLD.trip_id AND h.history_id <> r.history_id AND h.at >= r.at) THEN
            RAISE EXCEPTION 'crm: undo_not_allowed (% % -> % cannot be taken back)', TG_TABLE_NAME, OLD.stage, NEW.stage
                USING ERRCODE = 'CRM20';
        END IF;
        RETURN NEW;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM crm.status_transition t
         WHERE t.table_name = TG_TABLE_NAME AND t.from_status = OLD.stage AND t.to_status = NEW.stage
    ) THEN
        RAISE EXCEPTION 'crm: % stage % -> % is not an allowed transition', TG_TABLE_NAME, OLD.stage, NEW.stage
            USING ERRCODE = 'check_violation';
    END IF;

    -- 2a. Gates (the API answers 409 first; this is the database's own check). crm-016: the booking gate is met by a
    -- paid deposit of the trip's accepted proposal, the Stage 3 gate by s3 = 100 (Stage 3 and the waiver of every
    -- traveller); an override with a logged reason still passes an unmet gate.
    IF TG_TABLE_NAME = 'trip' THEN
        v_gate := CASE
            WHEN OLD.stage = 'qualifying' AND NEW.stage = 'proposal' THEN 'stage2'
            WHEN OLD.stage = 'proposal' AND NEW.stage = 'booked' THEN 'booking'
            WHEN OLD.stage = 'booked' AND NEW.stage = 'pre_departure' THEN 'stage3'
        END;
        IF v_gate = 'stage2' AND COALESCE((NEW.intake_completeness ->> 's2')::int, 0) >= 80 THEN
            v_gate := NULL;
        ELSIF v_gate = 'booking' AND EXISTS (
            SELECT 1 FROM crm.payment_schedule s
              JOIN crm.proposal p ON p.proposal_id = s.proposal_id
             WHERE s.trip_id = NEW.trip_id AND s.kind = 'deposit' AND s.status = 'paid' AND s.deleted_at IS NULL
               AND p.status = 'accepted' AND p.deleted_at IS NULL) THEN
            v_gate := NULL;
        ELSIF v_gate = 'stage3' AND COALESCE((NEW.intake_completeness ->> 's3')::int, 0) >= 100 THEN
            v_gate := NULL;
        END IF;
        IF v_gate IS NOT NULL AND v_override <> v_gate THEN
            RAISE EXCEPTION 'crm: %', CASE v_gate WHEN 'stage2' THEN 'stage2_incomplete' ELSE 'gate_unmet:' || v_gate END
                USING ERRCODE = 'CRM19';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.enforce_stage_transition() FROM PUBLIC;
COMMENT ON FUNCTION crm.enforce_stage_transition() IS 'AA-936 (crm-005), replaced by AA-943 (crm-012) and AA-946 (crm-016): a stage change must be an edge in crm.status_transition; on crm.trip the gates qualifying -> proposal (s2 >= 80 or app.gate_override = stage2), proposal -> booked (a paid deposit of the accepted proposal, or app.gate_override = booking), booked -> pre_departure (s3 = 100, or app.gate_override = stage3) raise CRM19; while app.stage_undo names the trip''s latest move (<= 15 s old, same actor, not an undo, not into cancelled, itself an edge) only its exact reverse is allowed, anything else raises CRM20.';

-- ── 11a. crm.erase_held (crm-010 hold rule 4e): the crm-015 text plus the lifecycle tables ──────
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
        -- its messages, crm-015), proposal, payment_schedule, payment, traveler_access, otp_challenge,
        -- signature_request (crm-016) and the trip: all carry trip_id = the trip (4d through hold_trip), and these name
        -- a traveller too.
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
                    SELECT c.traveler_id FROM crm.conversation c WHERE c.trip_id = p_subject
                    UNION ALL
                    SELECT a.traveler_id FROM crm.traveler_access a WHERE a.trip_id = p_subject
                    UNION ALL
                    SELECT s.traveler_id FROM crm.signature_request s WHERE s.trip_id = p_subject
                    UNION ALL
                    SELECT o.traveler_id FROM crm.otp_challenge o WHERE o.trip_id = p_subject) x
             WHERE x.traveler_id IS NOT NULL AND crm.hold_traveler(x.traveler_id));
    ELSIF p_scope = 'traveler' THEN
        -- dispatch_queue, traveler_health, document, note, trip_traveler, consent, form_submission, client_link,
        -- conversation (and its messages, crm-015), traveler_access, otp_challenge, signature_request (crm-016) and the
        -- traveller carry traveler_id = the traveller (4d through hold_traveler); trip_party / profile_history /
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
                        SELECT a.trip_id FROM crm.traveler_access a WHERE a.traveler_id = p_subject
                        UNION ALL
                        SELECT s.trip_id FROM crm.signature_request s WHERE s.traveler_id = p_subject
                        UNION ALL
                        SELECT o.trip_id FROM crm.otp_challenge o WHERE o.traveler_id = p_subject
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
    -- Subject-less data (llm_call, placeholder_map), agency_supplier (crm-014), the agency's mail settings
    -- (crm-015: saved_reply, mail_import, ingest_address, channel_account) and agreement_doc (crm-016); none names a
    -- trip or traveller: the agency hold only.
    RETURN crm.hold_row(NULL, NULL);
END;
$$;
REVOKE ALL ON FUNCTION crm.erase_held(text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.erase_held(text, uuid, uuid) TO crm_app;
COMMENT ON FUNCTION crm.erase_held(text, uuid, uuid) IS 'AA-942 (crm-010, hold rule 4e), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-944 (crm-014) to the scopes booking_line (its trip held) and agency_supplier (the agency hold), by AA-945 (crm-015) to conversation / message (trip and traveller scopes, new scope conversation) and by AA-946 (crm-016) to the lifecycle tables (proposal, payment_schedule, payment, traveler_access, otp_challenge, signature_request: trip and traveller scopes; agreement_doc: the agency hold): true when crm.erase_subject(scope, subject, token) would delete or update a held row (every step''s rows, both rows of a relation, the clients a traveller referred, the submissions a trip unlinks, the call slots a traveller''s submissions booked); scope tenant: any active hold of the agency. crm.erase_subject refuses with CRM10 on it, dry run too. Invoker rights.';

-- ── 11b. crm.erase_subject: the crm-015 text plus the lifecycle tables ───────────────────────────
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
        -- crm-016: signatures, codes, portal access, payments, schedule rows and proposals before the links.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['signature_request', 'trip_id = $1', ''],
            ['otp_challenge', 'trip_id = $1', ''],
            ['traveler_access', 'trip_id = $1', ''],
            ['payment', 'trip_id = $1', ''],
            ['payment_schedule', 'trip_id = $1', ''],
            ['proposal', 'trip_id = $1', ''],
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
        -- crm-015: the messages of their conversations, then those. crm-016: the name they typed to accept a proposal
        -- (the proposal's link names them; before their links go), their signatures, codes and portal access.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['proposal', 'accepted_name_enc IS NOT NULL AND link_id IN (SELECT l.link_id FROM crm.client_link l '
                         'WHERE l.traveler_id = $1)', 'accepted_name_enc = NULL, accepted_name_erased_at = now()'],
            ['signature_request', 'traveler_id = $1', ''],
            ['otp_challenge', 'traveler_id = $1', ''],
            ['traveler_access', 'traveler_id = $1', ''],
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
                v_step[1] || CASE WHEN v_step[3] = '' THEN '' WHEN v_step[1] = 'proposal' THEN '_acceptance_name_erased'
                                  ELSE '_referrer_unlinked' END,
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
        -- crm-016: signatures, codes, portal access, payments, schedule rows, proposals and agreement versions first.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['membership_inbox', ''],
            ['signature_request', ''], ['otp_challenge', ''], ['traveler_access', ''], ['payment', ''],
            ['payment_schedule', ''], ['proposal', ''], ['agreement_doc', ''],
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
COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope), by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge), by AA-945 (crm-015) to mail (trip, traveller and agency scopes: message, conversation; agency scope: saved_reply, mail_import, ingest_address, channel_account; new scope conversation for the trash purge) and by AA-946 (crm-016) to the lifecycle tables (trip and agency scopes: signature_request, otp_challenge, traveler_access, payment, payment_schedule, proposal; traveller scope: signature_request, otp_challenge, traveler_access, and the typed acceptance name of the proposals their links carried (accepted_name_enc := NULL); agency scope: agreement_doc): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, conversation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';


-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
BEGIN
    FOREACH t IN ARRAY ARRAY['crm.agreement_doc', 'crm.proposal', 'crm.payment_schedule', 'crm.payment',
                             'crm.traveler_access', 'crm.otp_challenge', 'crm.signature_request'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = t::regclass) THEN
            RAISE EXCEPTION 'crm-016: % must have ENABLE + FORCE row level security', t;
        END IF;
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, t, p) THEN
                    RAISE EXCEPTION 'crm-016: reader % may % on %', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
        IF pg_catalog.has_table_privilege('crm_app', t, 'TRUNCATE')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'SELECT')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'INSERT') THEN
            RAISE EXCEPTION 'crm-016: crm_app must read and insert % and never truncate it', t;
        END IF;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['crm.agreement_doc', 'crm.proposal', 'crm.payment_schedule', 'crm.payment',
                             'crm.traveler_access', 'crm.signature_request'] LOOP
        IF pg_catalog.has_table_privilege('crm_app', t, 'DELETE') THEN
            RAISE EXCEPTION 'crm-016: crm_app must never delete from % (erasure through crm.erase_subject)', t;
        END IF;
    END LOOP;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.payment', 'UPDATE') THEN
        RAISE EXCEPTION 'crm-016: crm.payment is append-only for crm_app';
    END IF;
    IF NOT pg_catalog.has_table_privilege('crm_app', 'crm.otp_challenge', 'DELETE') THEN
        RAISE EXCEPTION 'crm-016: crm_app deletes expired codes (24-hour retention)';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-016: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-016: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    IF NOT pg_catalog.has_function_privilege('crm_app', 'crm.portal_unlocked(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-016: crm_app must execute crm.portal_unlocked (the API reads the portal lock with it)';
    END IF;
    IF position('accepted_name_erased_at' IN (SELECT prosrc FROM pg_catalog.pg_proc
                 WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-016: crm.erase_subject does not erase the typed acceptance name';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.guard_sealed_row()', 'crm.guard_traveler_access()', 'crm.set_agreement_doc_sha256()', 'crm.enforce_stage_transition()',
                             'crm.portal_unlocked(uuid)',
                             'crm.erase_held(text,uuid,uuid)', 'crm.erase_subject(text,uuid,uuid,boolean)'] LOOP
        IF pg_catalog.has_function_privilege('public', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-016: % is executable by PUBLIC (SEC-4)', t;
        END IF;
    END LOOP;
    -- Every table an earlier key taught erase_subject, and the lifecycle tables of this one.
    FOREACH t IN ARRAY ARRAY['signature_request', 'otp_challenge', 'traveler_access', 'payment', 'payment_schedule',
                             'proposal', 'agreement_doc', 'message', 'conversation', 'saved_reply', 'mail_import',
                             'ingest_address', 'channel_account', 'booking_line_money', 'booking_line',
                             'agency_supplier', 'fx_rate_override', 'membership_inbox', 'client_link',
                             'meeting_slot'] LOOP
        IF position(quote_literal(t) IN (SELECT prosrc FROM pg_catalog.pg_proc
                     WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
            RAISE EXCEPTION 'crm-016: crm.erase_subject does not erase crm.%', t;
        END IF;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['crm.traveler_access', 'crm.signature_request', 'crm.otp_challenge',
                             'crm.conversation'] LOOP
        IF position(t IN (SELECT prosrc FROM pg_catalog.pg_proc
                     WHERE oid = 'crm.erase_held(text,uuid,uuid)'::regprocedure)) = 0 THEN
            RAISE EXCEPTION 'crm-016: crm.erase_held does not reach %', t;
        END IF;
    END LOOP;
    IF position('payment_schedule' IN (SELECT prosrc FROM pg_catalog.pg_proc
                 WHERE oid = 'crm.enforce_stage_transition()'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-016: crm.enforce_stage_transition does not read the deposit';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-016', now(), 'AA-946: CRM-18 thin full lifecycle (agreement_doc, proposal with accept, payment_schedule + manual payment, traveler_access, otp_challenge, signature_request (e-sign v0), client_link purposes proposal / portal, computable booking and Stage 3 gates, Stage 3 locked before the deposit or a manual_booking override (CRM32, crm.portal_unlocked), code mail stored masked, sealed rows (CRM31), erase_subject + hold rule for the new tables incl. the typed acceptance name)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
