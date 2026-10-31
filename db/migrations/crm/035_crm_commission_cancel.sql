-- Migration crm-035: AA-957 CRM-27 Module 13 commission + one-action trip cancellation (design v3 M13, C12, R17, R21;
-- data-privacy-integrations §2.7 `commission`, §3.1 FX rules, §3.3 delete block, §3.4 one-action cancellation).
--
-- Owner: AA-Partner (api/migrations/035_crm_commission_cancel.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Sync bot, Migration Copy Guard). Key crm-035, after crm-034 (AA-956); if main moves,
-- renumber: file name, this header, guard 0, the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS (code PR).
--
-- What:
--   1. crm.commission (base template): the follow-up of the commission an agency supplier owes on one confirmed agency
--      line. The expected amount is NOT stored here: it is the head of the line's commission_expected money chain
--      (frozen at the confirmation day's rate, R17 booking_date). Status expected -> claimed -> received, or
--      written_off / cancelled; due_on; the claim (claimed_at, claim_ref = the agency's own reference to the
--      supplier); the receipt (received_amount + currency + received_on + reference and its frozen FX block, basis
--      receipt_date, R17 E), short_amount (original currency only), fx_difference_base (only when the original
--      amounts match: an FX move never reads as underpaid). close_reason for written_off / cancelled; keep_on_cancel
--      (the supplier still pays after a trip cancel); overdue_alerted_at (the hourly owner task, once).
--      One live (not cancelled) row per line. Margin field (design §4.6 `commission.*`): the RESTRICTIVE policy
--      commission_margin_roles FOR SELECT TO crm_app (owner / agent, or a job / seed actor), as booking_line_money.
--      crm_app: SELECT, and UPDATE of the follow-up columns only; rows are inserted by crm.commission_sync and the
--      receipt written by crm.commission_receive (SECURITY DEFINER). Guard crm.guard_commission (SQLSTATE CRM46):
--      the identity (tenant, trip, line) never changes, a received / written_off / cancelled row is sealed, the
--      receipt columns change only through crm.commission_receive.
--   2. crm.trip_cancellation (base template): one per trip, the C12 run: pending while Booking has not cancelled the
--      trip's AA bookings (the trip keeps its stage: never "cancelled" early, card R), done when the stage moved.
--      Reason code (the trip's cancel reasons), the stage it left, the AA bookings asked, the effect counts of the run
--      (codes and numbers only). crm_app: SELECT only (no DELETE: the row leaves with its trip); rows are written by
--      two SECURITY DEFINER functions, as crm.commission is: crm.trip_cancellation_open(trip, reason, effects) (owner /
--      agent member; the database reads the stage left and the live AA bookings itself and decides pending / done, so
--      no session can write a "done" cancellation while an AA booking is live) and crm.trip_cancellation_finish(trip)
--      (pending -> done only once no AA booking of the trip is live and the trip is cancelled).
--   3. crm.aa_request.kind + 'cancel' (POST /bookings/{id}/cancel of booking.b2b.v1, one per Booking booking).
--   4. crm.booking_line_money.kind + 'cancellation_cost' (the fee Booking charged for a cancelled AA booking, card E:
--      "the fee becomes a cost line"), written by crm.booking_line_aa_cancel_fee (SECURITY DEFINER, a job actor only,
--      an AA line only): at the line's quote FX lock when the fee is in the cost's currency, else the platform rate of
--      the fee day. The margin policy already hides it from the assistant.
--   5. crm.agency_supplier.commission_due_days (nullable, 0..365): how many days after the service the supplier pays
--      its commission (NULL = 30), the default due date of a new commission row.
--   6. crm.commission_sync(trip) (SECURITY DEFINER, EXECUTE crm_app): creates the expected rows of confirmed agency
--      lines with a positive expected commission (not on a lost / cancelled trip or one with a pending cancellation),
--      cancels expected rows whose line was cancelled or trashed (unless keep_on_cancel) or whose expected commission
--      is now 0 / gone, and mirrors every row into crm.trip_commitment (kind commission; written_off -> cancelled).
--      Returns counts only.
--   7. crm.commission_receive(...) (SECURITY DEFINER, EXECUTE crm_app; owner / agent member only): the receipt.
--   8. Erasure without a replaced crm.erase_subject (the crm-029 / crm-034 pattern): crm.commission cascades from its
--      trip and its line, crm.trip_cancellation from its trip.
--
-- Class: contract (root ADR 0017 d3): widened CHECKs on two existing tables, new columns and grants, rows in
-- crm.status_transition. MIG-4 order: this migration-only PR, the Infra copy (Migration Sync bot), a manual DB
-- Migrate apply, the bot/db-schema-reference PR, then the AA-957 code PR (adds crm-035 to REQUIRED_SCHEMA_VERSIONS).
-- Code before AA-957 never names the new tables, kinds or column.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS,
-- DROP … IF EXISTS before each ADD / CREATE, ON CONFLICT DO NOTHING, CREATE OR REPLACE).
-- Rollback: a forward crm- file after the AA-957 code is reverted: DROP TABLE crm.commission, crm.trip_cancellation;
-- DROP the six functions; DELETE the 'cancel' requests and the 'cancellation_cost' rows (with app.erasing) and put
-- both CHECKs back; DROP COLUMN crm.agency_supplier.commission_due_days; DELETE the status_transition rows.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ── Guard 0: runs as the owner, after crm-034 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-035: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-034') THEN
        RAISE EXCEPTION 'crm-035: crm-034 (AA-956 ops release) lands first';
    END IF;
    IF to_regclass('crm.booking_line_money') IS NULL OR to_regclass('crm.aa_request') IS NULL
       OR to_regclass('crm.trip_commitment') IS NULL
       OR to_regprocedure('crm.fx_resolve(text,text,date)') IS NULL THEN
        RAISE EXCEPTION 'crm-035: crm.booking_line_money, crm.aa_request, crm.trip_commitment or crm.fx_resolve missing';
    END IF;
END $$;

-- ── 1. crm.commission ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.commission (
    commission_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id              UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                           REFERENCES crm.tenant (tenant_id),
    trip_id                UUID NOT NULL,
    booking_line_id        UUID NOT NULL,
    status                 TEXT NOT NULL DEFAULT 'expected',
    due_on                 DATE NOT NULL,
    claimed_at             TIMESTAMPTZ,
    claim_ref              TEXT,
    received_amount        NUMERIC(14, 2),
    received_currency      CHAR(3),
    received_on            DATE,
    received_ref           TEXT,
    base_currency          CHAR(3),
    received_amount_base   NUMERIC(14, 2),
    fx_rate                NUMERIC(20, 10),
    fx_rate_date           DATE,
    fx_source              TEXT,
    fx_basis               TEXT,
    stale_days             SMALLINT,
    expected_amount        NUMERIC(14, 2),
    expected_currency      CHAR(3),
    expected_amount_base   NUMERIC(14, 2),
    short_amount           NUMERIC(14, 2),
    fx_difference_base     NUMERIC(14, 2),
    close_reason           TEXT,
    note                   TEXT,
    keep_on_cancel         BOOLEAN NOT NULL DEFAULT false,
    overdue_alerted_at     TIMESTAMPTZ,
    decided_by             TEXT,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by             TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at             TIMESTAMPTZ,
    deleted_by             TEXT,
    purge_after            TIMESTAMPTZ,
    CONSTRAINT commission_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT commission_line_fk FOREIGN KEY (tenant_id, booking_line_id)
        REFERENCES crm.booking_line (tenant_id, booking_line_id) ON DELETE CASCADE,
    CONSTRAINT commission_status_chk CHECK (status IN ('expected', 'claimed', 'received', 'written_off', 'cancelled')),
    CONSTRAINT commission_claim_chk CHECK (
        (status <> 'claimed' OR claimed_at IS NOT NULL)
        AND (claim_ref IS NULL OR (char_length(btrim(claim_ref)) BETWEEN 1 AND 80 AND claim_ref !~ '[[:cntrl:]]'))
    ),
    CONSTRAINT commission_receipt_chk CHECK (
        ((status = 'received') = (received_amount IS NOT NULL))
        AND (num_nulls(received_amount, received_currency, received_on, base_currency, received_amount_base, fx_rate,
                       fx_rate_date, fx_source, fx_basis, stale_days) IN (0, 10))
        AND (received_amount IS NULL OR (received_amount > 0 AND received_currency ~ '^[A-Z]{3}$'
             AND base_currency ~ '^[A-Z]{3}$' AND fx_rate > 0
             AND received_amount_base = round(received_amount * fx_rate, 2)
             AND (base_currency <> received_currency OR fx_rate = 1)
             AND fx_source IN ('platform_daily', 'manual') AND fx_basis = 'receipt_date'
             AND stale_days BETWEEN 0 AND 366))
        AND (received_ref IS NULL OR (char_length(btrim(received_ref)) BETWEEN 1 AND 80 AND received_ref !~ '[[:cntrl:]]'))
        AND (num_nulls(expected_amount, expected_currency) IN (0, 2))
        AND (expected_currency IS NULL OR expected_currency ~ '^[A-Z]{3}$')
        AND (expected_amount IS NULL OR received_amount IS NOT NULL)
        AND (short_amount IS NULL OR short_amount > 0)
    ),
    CONSTRAINT commission_close_chk CHECK (
        ((status IN ('written_off', 'cancelled')) = (close_reason IS NOT NULL))
        AND (close_reason IS NULL OR close_reason IN ('line_cancelled', 'no_commission', 'trip_cancelled',
                                                      'supplier_refused', 'too_small', 'other'))
        AND (status <> 'written_off' OR close_reason IN ('supplier_refused', 'too_small', 'other'))
        AND (status <> 'cancelled' OR close_reason IN ('line_cancelled', 'no_commission', 'trip_cancelled'))
        AND (note IS NULL OR (char_length(btrim(note)) BETWEEN 1 AND 500 AND note !~ '[[:cntrl:]]'))
        AND (decided_by IS NULL OR char_length(decided_by) <= 120)
    ),
    CONSTRAINT commission_trash_chk CHECK (
        deleted_at IS NULL AND deleted_by IS NULL AND purge_after IS NULL
    )
);
-- The live row per line (a cancelled row stays as history; a later positive expected commission makes a new row).
CREATE UNIQUE INDEX IF NOT EXISTS commission_line_live_uq ON crm.commission (tenant_id, booking_line_id)
    WHERE status <> 'cancelled' AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS commission_tenant_id_uq ON crm.commission (tenant_id, commission_id);
CREATE INDEX IF NOT EXISTS commission_trip_idx ON crm.commission (trip_id);
CREATE INDEX IF NOT EXISTS commission_line_idx ON crm.commission (tenant_id, booking_line_id);
CREATE INDEX IF NOT EXISTS commission_open_idx ON crm.commission (tenant_id, due_on)
    WHERE status IN ('expected', 'claimed');

ALTER TABLE crm.commission ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.commission FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.commission;
CREATE POLICY tenant_isolation ON crm.commission
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
-- Margin field (§4.6): the same rule as booking_line_money_margin_roles (crm-014).
DROP POLICY IF EXISTS commission_margin_roles ON crm.commission;
CREATE POLICY commission_margin_roles ON crm.commission AS RESTRICTIVE FOR SELECT TO crm_app
    USING (
        COALESCE(current_setting('app.member_role', true), '') IN ('owner', 'agent')
        OR (COALESCE(current_setting('app.member_role', true), '') = ''
            AND COALESCE(current_setting('app.actor', true), '') ~ '^(job|seed):')
    );

REVOKE ALL ON crm.commission FROM crm_app;
GRANT SELECT ON crm.commission TO crm_app;
GRANT UPDATE (status, claimed_at, claim_ref, due_on, close_reason, note, keep_on_cancel, overdue_alerted_at,
              decided_by) ON crm.commission TO crm_app;

CREATE OR REPLACE TRIGGER commission_set_updated_at
    BEFORE UPDATE ON crm.commission
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();

INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('commission', 'expected', 'claimed'),
    ('commission', 'expected', 'received'),
    ('commission', 'expected', 'written_off'),
    ('commission', 'expected', 'cancelled'),
    ('commission', 'claimed', 'expected'),
    ('commission', 'claimed', 'received'),
    ('commission', 'claimed', 'written_off')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER commission_status_transition
    BEFORE UPDATE OF status ON crm.commission
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();

CREATE OR REPLACE FUNCTION crm.guard_commission() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    o jsonb := to_jsonb(OLD) - 'updated_at';
    n jsonb := to_jsonb(NEW) - 'updated_at';
    c text;
BEGIN
    IF current_user = 'crm_owner' AND current_setting('app.erasing', true) = 'on' THEN
        RETURN NEW;  -- crm.erase_subject
    END IF;
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id OR NEW.trip_id IS DISTINCT FROM OLD.trip_id
       OR NEW.booking_line_id IS DISTINCT FROM OLD.booking_line_id OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION 'crm: commission_guard (a commission keeps its agency, trip and line)' USING ERRCODE = 'CRM46';
    END IF;
    IF OLD.status IN ('received', 'written_off', 'cancelled') AND n IS DISTINCT FROM o THEN
        RAISE EXCEPTION 'crm: commission_guard (a % commission is closed)', OLD.status USING ERRCODE = 'CRM46';
    END IF;
    -- The receipt columns move only inside crm.commission_receive (crm_owner with app.commission_receipt on).
    IF NOT (current_user = 'crm_owner' AND current_setting('app.commission_receipt', true) = 'on') THEN
        FOREACH c IN ARRAY ARRAY['received_amount', 'received_currency', 'received_on', 'received_ref', 'base_currency',
                                 'received_amount_base', 'fx_rate', 'fx_rate_date', 'fx_source', 'fx_basis',
                                 'stale_days', 'expected_amount', 'expected_currency', 'expected_amount_base',
                                 'short_amount', 'fx_difference_base'] LOOP
            IF (n->c) IS DISTINCT FROM (o->c) THEN
                RAISE EXCEPTION 'crm: commission_guard (record the money through crm.commission_receive)'
                    USING ERRCODE = 'CRM46';
            END IF;
        END LOOP;
        IF NEW.status = 'received' AND OLD.status <> 'received' THEN
            RAISE EXCEPTION 'crm: commission_guard (record the money through crm.commission_receive)'
                USING ERRCODE = 'CRM46';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_commission() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_commission() IS 'AA-957 (crm-035): BEFORE UPDATE guard of crm.commission (CRM46 commission_guard): agency, trip, line and creation never change; a received / written_off / cancelled row is closed; the receipt columns (and the move to received) only through crm.commission_receive (crm_owner with app.commission_receipt on); crm.erase_subject passes.';
CREATE OR REPLACE TRIGGER commission_guard
    BEFORE UPDATE ON crm.commission
    FOR EACH ROW EXECUTE FUNCTION crm.guard_commission();

COMMENT ON TABLE crm.commission IS 'AA-957 (crm-035; design v3 M13, R17, R21): the follow-up of the commission an agency supplier owes on one confirmed agency line (one live row per line). The expected amount is the head of the line''s commission_expected money chain (crm.booking_line_money, frozen at the confirmation day), never copied here until the receipt. Status expected -> claimed -> received | written_off; expected -> cancelled (line cancelled, no commission, trip cancelled). Overdue is derived (open and due_on before today). Rows from crm.commission_sync, the receipt from crm.commission_receive. Margin field: crm_app reads it only as owner / agent or a job / seed actor (commission_margin_roles). conf:commercial.';
COMMENT ON COLUMN crm.commission.due_on IS 'when the supplier should have paid: the line''s last service day + the supplier''s commission_due_days (default 30); the agency may change it';
COMMENT ON COLUMN crm.commission.claim_ref IS 'conf:commercial; the agency''s own reference of its claim to the supplier (an invoice number), never a person''s data';
COMMENT ON COLUMN crm.commission.received_ref IS 'conf:commercial; the agency''s own reference of the money received (a bank reference), never card or account numbers';
COMMENT ON COLUMN crm.commission.short_amount IS 'expected - received in the original currency, only when the receipt is in the expected currency and below it (R17: an FX move is never "underpaid")';
COMMENT ON COLUMN crm.commission.fx_difference_base IS 'expected base - received base, only when the original-currency amounts are equal (R17 §3.1 item 4)';
COMMENT ON COLUMN crm.commission.expected_amount IS 'the expected commission (original currency) at the receipt, copied by crm.commission_receive for the comparison';
COMMENT ON COLUMN crm.commission.note IS 'conf:commercial; the agency''s note on a write-off; never a person''s data';

-- ── 2. crm.trip_cancellation ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.trip_cancellation (
    trip_cancellation_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                          REFERENCES crm.tenant (tenant_id),
    trip_id               UUID NOT NULL,
    status                TEXT NOT NULL DEFAULT 'pending',
    reason_code           TEXT NOT NULL,
    from_stage            TEXT NOT NULL,
    aa_bookings           SMALLINT NOT NULL DEFAULT 0,
    effects               JSONB NOT NULL DEFAULT '{}'::jsonb,
    finished_at           TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at            TIMESTAMPTZ,
    deleted_by            TEXT,
    purge_after           TIMESTAMPTZ,
    CONSTRAINT trip_cancellation_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT trip_cancellation_status_chk CHECK (status IN ('pending', 'done')),
    CONSTRAINT trip_cancellation_finished_chk CHECK ((status = 'done') = (finished_at IS NOT NULL)),
    CONSTRAINT trip_cancellation_values_chk CHECK (
        reason_code IN ('client_request', 'client_illness', 'travel_advisory', 'force_majeure', 'supplier_failure',
                        'aa_cancelled', 'payment_not_received', 'duplicate', 'other')
        AND from_stage IN ('booked', 'pre_departure', 'travelling')
        AND aa_bookings BETWEEN 0 AND 200
        AND jsonb_typeof(effects) = 'object' AND octet_length(effects::text) <= 4096
    ),
    CONSTRAINT trip_cancellation_trash_chk CHECK (
        deleted_at IS NULL AND deleted_by IS NULL AND purge_after IS NULL
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS trip_cancellation_trip_uq ON crm.trip_cancellation (tenant_id, trip_id);
CREATE UNIQUE INDEX IF NOT EXISTS trip_cancellation_tenant_id_uq ON crm.trip_cancellation (tenant_id, trip_cancellation_id);
CREATE INDEX IF NOT EXISTS trip_cancellation_pending_idx ON crm.trip_cancellation (tenant_id, created_at)
    WHERE status = 'pending';

ALTER TABLE crm.trip_cancellation ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.trip_cancellation FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.trip_cancellation;
CREATE POLICY tenant_isolation ON crm.trip_cancellation
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

-- Writes only through crm.trip_cancellation_open / crm.trip_cancellation_finish (below), as crm.commission.
REVOKE ALL ON crm.trip_cancellation FROM crm_app;
GRANT SELECT ON crm.trip_cancellation TO crm_app;

CREATE OR REPLACE TRIGGER trip_cancellation_set_updated_at
    BEFORE UPDATE ON crm.trip_cancellation
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('trip_cancellation', 'pending', 'done')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER trip_cancellation_status_transition
    BEFORE UPDATE OF status ON crm.trip_cancellation
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();

CREATE OR REPLACE FUNCTION crm.guard_trip_cancellation() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF current_user = 'crm_owner' AND current_setting('app.erasing', true) = 'on' THEN
        RETURN NEW;
    END IF;
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id OR NEW.trip_id IS DISTINCT FROM OLD.trip_id
       OR NEW.reason_code IS DISTINCT FROM OLD.reason_code OR NEW.from_stage IS DISTINCT FROM OLD.from_stage
       OR NEW.created_at IS DISTINCT FROM OLD.created_at OR NEW.created_by IS DISTINCT FROM OLD.created_by
       OR (OLD.status = 'done' AND (to_jsonb(NEW) - 'updated_at') IS DISTINCT FROM (to_jsonb(OLD) - 'updated_at')) THEN
        RAISE EXCEPTION 'crm: trip_cancellation_guard (a cancellation keeps its trip, reason and start; a done one is closed)'
            USING ERRCODE = 'CRM46';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_trip_cancellation() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_trip_cancellation() IS 'AA-957 (crm-035): BEFORE UPDATE guard of crm.trip_cancellation (CRM46): trip, reason, stage left and creation never change; a done row is closed; crm.erase_subject passes.';
CREATE OR REPLACE TRIGGER trip_cancellation_guard
    BEFORE UPDATE ON crm.trip_cancellation
    FOR EACH ROW EXECUTE FUNCTION crm.guard_trip_cancellation();

-- The only writers of crm.trip_cancellation (crm_app has SELECT only): open decides pending / done from the live AA
-- bookings; finish closes a pending one once Booking cancelled them all and the trip moved.
CREATE OR REPLACE FUNCTION crm.trip_cancellation_open(p_trip uuid, p_reason text, p_effects jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_role text := COALESCE(current_setting('app.member_role', true), '');
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    v_stage text;
    v_aa integer;
    v_status text;
BEGIN
    IF v_role NOT IN ('owner', 'agent') THEN
        RAISE EXCEPTION 'crm: role_forbidden (owner or agent cancels a trip)' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'crm: trip_cancellation_open needs app.tenant_id' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT t.stage INTO v_stage FROM crm.trip t WHERE t.trip_id = p_trip AND t.deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (trip %)', p_trip USING ERRCODE = 'CRM13';
    END IF;
    IF v_stage NOT IN ('booked', 'pre_departure', 'travelling') THEN
        RAISE EXCEPTION 'crm: transition_not_allowed (only a booked, pre-departure or travelling trip is cancelled)'
            USING ERRCODE = 'check_violation';
    END IF;
    SELECT count(DISTINCT l.bk_booking_id)::integer INTO v_aa
      FROM crm.booking_line l
     WHERE l.trip_id = p_trip AND l.supplier_kind = 'aa' AND l.bk_booking_id IS NOT NULL AND l.status <> 'cancelled'
       AND l.deleted_at IS NULL;
    v_status := CASE WHEN v_aa > 0 THEN 'pending' ELSE 'done' END;
    INSERT INTO crm.trip_cancellation (tenant_id, trip_id, status, reason_code, from_stage, aa_bookings, effects,
                                       finished_at)
    VALUES (v_tenant, p_trip, v_status, p_reason, v_stage, LEAST(v_aa, 200), COALESCE(p_effects, '{}'::jsonb),
            CASE WHEN v_status = 'done' THEN now() END);
    RETURN jsonb_build_object('status', v_status, 'aa_bookings', v_aa);
END;
$$;
REVOKE ALL ON FUNCTION crm.trip_cancellation_open(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.trip_cancellation_open(uuid, text, jsonb) TO crm_app;
COMMENT ON FUNCTION crm.trip_cancellation_open(uuid, text, jsonb) IS 'AA-957 (crm-035, C12, card R): the one row of a trip cancel for the agency of app.tenant_id. The database reads the stage left (booked, pre_departure or travelling, else 23514 transition_not_allowed) and counts the live AA bookings (bk_booking_id, line not cancelled): any -> pending (the trip keeps its stage until Booking cancelled them), none -> done. Returns {status, aa_bookings}. Owner / agent member only (42501 role_forbidden); unknown trip CRM13; a second cancel of the trip 23505. SECURITY DEFINER (crm_app has SELECT only); EXECUTE crm_app.';

CREATE OR REPLACE FUNCTION crm.trip_cancellation_finish(p_trip uuid) RETURNS boolean
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_role text := COALESCE(current_setting('app.member_role', true), '');
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_status text;
BEGIN
    IF NOT (v_role IN ('owner', 'agent') OR (v_role = '' AND v_actor ~ '^job:')) THEN
        RAISE EXCEPTION 'crm: role_forbidden (the Booking sync or an owner / agent finishes a trip cancel)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT x.status INTO v_status FROM crm.trip_cancellation x WHERE x.trip_id = p_trip FOR UPDATE;
    IF NOT FOUND OR v_status <> 'pending' THEN
        RETURN false;
    END IF;
    IF EXISTS (SELECT 1 FROM crm.booking_line l
                WHERE l.trip_id = p_trip AND l.supplier_kind = 'aa' AND l.bk_booking_id IS NOT NULL
                  AND l.status <> 'cancelled' AND l.deleted_at IS NULL)
       OR NOT EXISTS (SELECT 1 FROM crm.trip t WHERE t.trip_id = p_trip AND t.stage = 'cancelled') THEN
        RETURN false;  -- card R: never done while AA still holds a booking of the trip
    END IF;
    UPDATE crm.trip_cancellation SET status = 'done', finished_at = now() WHERE trip_id = p_trip;
    RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION crm.trip_cancellation_finish(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.trip_cancellation_finish(uuid) TO crm_app;
COMMENT ON FUNCTION crm.trip_cancellation_finish(uuid) IS 'AA-957 (crm-035, C12, card R): pending -> done for the trip cancel of the agency of app.tenant_id, only once no AA booking of the trip is live and the trip stage is cancelled; returns whether it changed (false: no pending row, or not finished yet). A job: actor without a member role, or an owner / agent member (42501 otherwise). SECURITY DEFINER (crm_app has SELECT only); EXECUTE crm_app.';

COMMENT ON TABLE crm.trip_cancellation IS 'AA-957 (crm-035; design v3 C12, §3.5 "Cancellation"): the one-action cancel of a trip. pending while Booking has not cancelled the trip''s AA bookings (crm.aa_request kind cancel; the trip keeps its stage, never "cancelled" early); done once the stage moved to cancelled. effects: the counts of the run (codes and numbers only). One per trip.';

-- ── 3. crm.aa_request.kind + cancel ──────────────────────────────────────────────────────────────
ALTER TABLE crm.aa_request DROP CONSTRAINT IF EXISTS aa_request_kind_chk;
ALTER TABLE crm.aa_request ADD CONSTRAINT aa_request_kind_chk
    CHECK (kind IN ('quote', 'requote', 'hold', 'confirm', 'release', 'refresh', 'cancel'));

-- ── 4. crm.booking_line_money.kind + cancellation_cost ───────────────────────────────────────────
ALTER TABLE crm.booking_line_money DROP CONSTRAINT IF EXISTS booking_line_money_kind_chk;
ALTER TABLE crm.booking_line_money ADD CONSTRAINT booking_line_money_kind_chk
    CHECK (kind IN ('cost', 'sell', 'commission_expected', 'cancellation_cost'));

CREATE OR REPLACE FUNCTION crm.booking_line_aa_cancel_fee(p_line uuid, p_amount numeric, p_currency text, p_on date)
    RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_role text := COALESCE(current_setting('app.member_role', true), '');
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_kind text;
    v_base text;
    v_rate numeric;
    v_rate_date date;
    v_source text;
    v_basis text;
    v_stale integer := 0;
    v_cost record;
    v_fx record;
    v_head record;
    v_amount numeric := round(p_amount, 2);
    v_id uuid;
BEGIN
    IF NOT (v_role = '' AND v_actor ~ '^job:') THEN
        RAISE EXCEPTION 'crm: margin_forbidden (an AA cancellation fee comes from the Booking sync job only)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_amount IS NULL OR p_amount < 0 OR p_currency IS NULL OR p_currency !~ '^[A-Z]{3}$' OR p_on IS NULL THEN
        RAISE EXCEPTION 'crm: money_invalid (amount >= 0, an ISO currency and the fee day)' USING ERRCODE = 'check_violation';
    END IF;
    SELECT l.supplier_kind INTO v_kind FROM crm.booking_line l WHERE l.booking_line_id = p_line FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (booking_line %)', p_line USING ERRCODE = 'CRM13';
    END IF;
    IF v_kind <> 'aa' THEN
        RAISE EXCEPTION 'crm: line_not_editable (only an AA line has an AA cancellation fee)' USING ERRCODE = 'CRM26';
    END IF;
    v_base := COALESCE((SELECT ts.base_currency FROM crm.tenant_settings ts), 'USD');
    -- The line's quote FX lock (its cost head, same currency) when there is one: the fee is in the quote currency.
    SELECT m.* INTO v_cost
      FROM crm.booking_line_money m
     WHERE m.booking_line_id = p_line AND m.kind = 'cost' AND m.currency = p_currency AND m.fx_rate IS NOT NULL
       AND m.base_currency = v_base
       AND NOT EXISTS (SELECT 1 FROM crm.booking_line_money n WHERE n.supersedes_id = m.booking_line_money_id);
    IF v_cost.booking_line_money_id IS NOT NULL THEN
        v_rate := v_cost.fx_rate;
        v_rate_date := v_cost.fx_rate_date;
        v_source := v_cost.fx_source;
        v_basis := v_cost.fx_basis;
        v_stale := v_cost.stale_days;
    ELSE
        SELECT r.rate, r.rate_date, r.fx_source, r.stale_days INTO v_fx FROM crm.fx_resolve(p_currency, v_base, p_on) r;
        IF v_fx.rate IS NULL THEN
            RAISE EXCEPTION 'crm: fx_rate_missing:% (no rate % -> % within 30 days of %)', p_currency, p_currency,
                v_base, p_on USING ERRCODE = 'CRM25';
        END IF;
        v_rate := v_fx.rate;
        v_rate_date := p_on;
        v_source := v_fx.fx_source;
        v_basis := 'booking_date';
        v_stale := LEAST(v_fx.stale_days, 366);
    END IF;
    SELECT m.* INTO v_head
      FROM crm.booking_line_money m
     WHERE m.booking_line_id = p_line AND m.kind = 'cancellation_cost'
       AND NOT EXISTS (SELECT 1 FROM crm.booking_line_money n WHERE n.supersedes_id = m.booking_line_money_id);
    IF v_head.booking_line_money_id IS NOT NULL AND v_head.amount = v_amount AND v_head.currency = p_currency THEN
        RETURN v_head.booking_line_money_id;  -- the same answer again (a replayed cancel): nothing changes
    END IF;
    INSERT INTO crm.booking_line_money (booking_line_id, kind, amount, currency, base_currency, amount_base, fx_rate,
                                        fx_rate_date, fx_source, fx_basis, stale_days, supersedes_id)
    VALUES (p_line, 'cancellation_cost', v_amount, p_currency, v_base, round(v_amount * v_rate, 2), v_rate,
            v_rate_date, v_source, v_basis, v_stale, v_head.booking_line_money_id)
    RETURNING booking_line_money_id INTO v_id;
    RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION crm.booking_line_aa_cancel_fee(uuid, numeric, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.booking_line_aa_cancel_fee(uuid, numeric, text, date) TO crm_app;
COMMENT ON FUNCTION crm.booking_line_aa_cancel_fee(uuid, numeric, text, date) IS 'AA-957 (crm-035, C12, card E "the fee becomes a cost line"): writes the fee Booking charged for cancelling an AA booking as the cancellation_cost head of an AA line of the agency of app.tenant_id, frozen at once: at the line''s quote FX lock (its cost head in the same currency and base) or else crm.fx_resolve of the fee day (CRM25 when none). Nothing when the head already has this amount and currency. Only a job: actor without a member role (42501 margin_forbidden otherwise); an agency line CRM26; unknown line CRM13. SECURITY DEFINER; EXECUTE crm_app.';

-- ── 5. crm.agency_supplier.commission_due_days ───────────────────────────────────────────────────
ALTER TABLE crm.agency_supplier ADD COLUMN IF NOT EXISTS commission_due_days SMALLINT;
ALTER TABLE crm.agency_supplier DROP CONSTRAINT IF EXISTS agency_supplier_commission_due_chk;
ALTER TABLE crm.agency_supplier ADD CONSTRAINT agency_supplier_commission_due_chk
    CHECK (commission_due_days IS NULL OR commission_due_days BETWEEN 0 AND 365);
COMMENT ON COLUMN crm.agency_supplier.commission_due_days IS 'conf:commercial; AA-957 (crm-035): days after the service the supplier pays its commission (NULL = 30): the default due date of a commission';

-- ── 6. crm.commission_sync ───────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.commission_sync(p_trip uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    v_created integer := 0;
    v_cancelled integer := 0;
    v_n integer;
    v_open boolean;
BEGIN
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'crm: commission_sync needs app.tenant_id' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM crm.trip t WHERE t.trip_id = p_trip) THEN
        RAISE EXCEPTION 'crm: subject_not_found (trip %)', p_trip USING ERRCODE = 'CRM13';
    END IF;
    -- a. Expected rows whose line was cancelled or trashed (unless kept at the trip cancel: the supplier still pays).
    UPDATE crm.commission c
       SET status = 'cancelled', close_reason = 'line_cancelled', decided_by = 'system:commission_sync'
      FROM crm.booking_line l
     WHERE c.trip_id = p_trip AND c.status = 'expected' AND NOT c.keep_on_cancel
       AND l.booking_line_id = c.booking_line_id AND (l.status = 'cancelled' OR l.deleted_at IS NOT NULL);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_cancelled := v_cancelled + v_n;
    -- b. Expected rows whose line's expected commission is now 0 or gone.
    UPDATE crm.commission c
       SET status = 'cancelled', close_reason = 'no_commission', decided_by = 'system:commission_sync'
     WHERE c.trip_id = p_trip AND c.status = 'expected'
       AND NOT EXISTS (SELECT 1 FROM crm.booking_line_money m
                        WHERE m.booking_line_id = c.booking_line_id AND m.kind = 'commission_expected'
                          AND m.amount > 0
                          AND NOT EXISTS (SELECT 1 FROM crm.booking_line_money n
                                           WHERE n.supersedes_id = m.booking_line_money_id));
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_cancelled := v_cancelled + v_n;
    -- c. New expected rows: confirmed agency lines with a positive expected commission and no live row, on a trip that
    --    is still going ahead.
    SELECT t.stage NOT IN ('lost', 'cancelled') AND t.deleted_at IS NULL
           AND NOT EXISTS (SELECT 1 FROM crm.trip_cancellation x WHERE x.trip_id = t.trip_id AND x.status = 'pending')
      INTO v_open
      FROM crm.trip t WHERE t.trip_id = p_trip;
    IF v_open THEN
        INSERT INTO crm.commission (tenant_id, trip_id, booking_line_id, due_on, created_by)
        SELECT v_tenant, l.trip_id, l.booking_line_id,
               COALESCE(l.service_to, l.service_from, t.end_date, t.start_date, l.confirmed_at::date, current_date)
                 + COALESCE(s.commission_due_days, 30),
               'system:commission_sync'
          FROM crm.booking_line l
          JOIN crm.trip t ON t.trip_id = l.trip_id
          JOIN crm.agency_supplier s ON s.agency_supplier_id = l.agency_supplier_id
         WHERE l.trip_id = p_trip AND l.supplier_kind = 'agency' AND l.status = 'confirmed' AND l.deleted_at IS NULL
           AND EXISTS (SELECT 1 FROM crm.booking_line_money m
                        WHERE m.booking_line_id = l.booking_line_id AND m.kind = 'commission_expected'
                          AND m.amount > 0
                          AND NOT EXISTS (SELECT 1 FROM crm.booking_line_money n
                                           WHERE n.supersedes_id = m.booking_line_money_id))
           AND NOT EXISTS (SELECT 1 FROM crm.commission c
                            WHERE c.booking_line_id = l.booking_line_id AND c.status <> 'cancelled'
                              AND c.deleted_at IS NULL)
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_created = ROW_COUNT;
    END IF;
    -- d. The delete block (crm.trip_delete_blockers reads claimed / received commitments).
    INSERT INTO crm.trip_commitment (tenant_id, trip_id, kind, line_status, source_ref, checked_at)
    SELECT v_tenant, c.trip_id, 'commission',
           CASE WHEN c.status = 'written_off' THEN 'cancelled' ELSE c.status END,
           c.commission_id::text, now()
      FROM crm.commission c WHERE c.trip_id = p_trip
    ON CONFLICT (tenant_id, kind, source_ref) DO UPDATE
       SET line_status = EXCLUDED.line_status, checked_at = now()
     WHERE crm.trip_commitment.line_status IS DISTINCT FROM EXCLUDED.line_status;
    RETURN jsonb_build_object('created', v_created, 'cancelled', v_cancelled);
END;
$$;
REVOKE ALL ON FUNCTION crm.commission_sync(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.commission_sync(uuid) TO crm_app;
COMMENT ON FUNCTION crm.commission_sync(uuid) IS 'AA-957 (crm-035, M13, R18): the commission rows of one trip of the agency of app.tenant_id: expected rows whose line is cancelled / trashed (unless keep_on_cancel) -> cancelled line_cancelled; expected rows whose line''s commission_expected head is 0 or gone -> cancelled no_commission; a new expected row (due = last service day + the supplier''s commission_due_days, default 30) for each confirmed agency line with a positive commission_expected head and no live row, unless the trip is lost, cancelled, trashed or has a pending cancellation; every row mirrored into crm.trip_commitment kind commission (written_off -> cancelled). SECURITY DEFINER so a confirm by the assistant (who cannot read money, R18) still creates the row; returns counts only. Unknown trip CRM13. EXECUTE crm_app.';

-- ── 7. crm.commission_receive ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.commission_receive(p_commission uuid, p_amount numeric, p_currency text, p_on date,
                                                  p_ref text) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_role text := COALESCE(current_setting('app.member_role', true), '');
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_row record;
    v_exp record;
    v_base text;
    v_fx record;
    v_amount numeric := round(p_amount, 2);
    v_short numeric;
    v_diff numeric;
    v_received_base numeric;
BEGIN
    IF v_role NOT IN ('owner', 'agent') THEN
        RAISE EXCEPTION 'crm: margin_forbidden (owner or agent records a commission received)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 OR p_amount > 999999999999.99 OR p_currency IS NULL
       OR p_currency !~ '^[A-Z]{3}$' OR p_on IS NULL THEN
        RAISE EXCEPTION 'crm: money_invalid (amount > 0, an ISO currency and the day it arrived)'
            USING ERRCODE = 'check_violation';
    END IF;
    SELECT c.* INTO v_row FROM crm.commission c WHERE c.commission_id = p_commission FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (commission %)', p_commission USING ERRCODE = 'CRM13';
    END IF;
    IF v_row.status NOT IN ('expected', 'claimed') THEN
        RAISE EXCEPTION 'crm: commission_closed (a % commission takes no money)', v_row.status USING ERRCODE = 'CRM46';
    END IF;
    v_base := COALESCE((SELECT ts.base_currency FROM crm.tenant_settings ts), 'USD');
    SELECT r.rate, r.fx_source, r.stale_days INTO v_fx FROM crm.fx_resolve(p_currency, v_base, p_on) r;
    IF v_fx.rate IS NULL THEN
        RAISE EXCEPTION 'crm: fx_rate_missing:% (no rate % -> % within 30 days of %)', p_currency, p_currency, v_base,
            p_on USING ERRCODE = 'CRM25';
    END IF;
    v_received_base := round(v_amount * v_fx.rate, 2);
    SELECT m.amount, m.currency, m.amount_base, m.base_currency INTO v_exp
      FROM crm.booking_line_money m
     WHERE m.booking_line_id = v_row.booking_line_id AND m.kind = 'commission_expected'
       AND NOT EXISTS (SELECT 1 FROM crm.booking_line_money n WHERE n.supersedes_id = m.booking_line_money_id);
    IF v_exp.currency IS NOT NULL AND v_exp.currency = p_currency AND v_amount < v_exp.amount THEN
        v_short := v_exp.amount - v_amount;
    END IF;
    IF v_exp.currency IS NOT NULL AND v_exp.currency = p_currency AND v_amount = v_exp.amount
       AND v_exp.amount_base IS NOT NULL AND v_exp.base_currency = v_base THEN
        v_diff := v_exp.amount_base - v_received_base;
    END IF;
    PERFORM set_config('app.commission_receipt', 'on', true);
    UPDATE crm.commission
       SET status = 'received', received_amount = v_amount, received_currency = p_currency, received_on = p_on,
           received_ref = NULLIF(btrim(COALESCE(p_ref, '')), ''), base_currency = v_base,
           received_amount_base = v_received_base, fx_rate = v_fx.rate, fx_rate_date = p_on,
           fx_source = v_fx.fx_source, fx_basis = 'receipt_date', stale_days = LEAST(v_fx.stale_days, 366),
           expected_amount = v_exp.amount, expected_currency = v_exp.currency,
           expected_amount_base = CASE WHEN v_exp.base_currency = v_base THEN v_exp.amount_base END,
           short_amount = v_short, fx_difference_base = v_diff, decided_by = v_actor
     WHERE commission_id = p_commission;
    PERFORM set_config('app.commission_receipt', '', true);
    UPDATE crm.trip_commitment SET line_status = 'received', checked_at = now()
     WHERE kind = 'commission' AND source_ref = p_commission::text;
    RETURN jsonb_build_object('received_amount_base', v_received_base, 'base_currency', v_base,
                              'stale_days', LEAST(v_fx.stale_days, 366));
END;
$$;
REVOKE ALL ON FUNCTION crm.commission_receive(uuid, numeric, text, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.commission_receive(uuid, numeric, text, date, text) TO crm_app;
COMMENT ON FUNCTION crm.commission_receive(uuid, numeric, text, date, text) IS 'AA-957 (crm-035, M13, R17 E): records the money an agency supplier paid on one expected / claimed commission of the agency of app.tenant_id: frozen at the receipt day''s rate (crm.fx_resolve: override, platform, latest earlier day within 30 days; basis receipt_date; CRM25 fx_rate_missing when none), so a receipt in another currency uses the receipt-date rate; short_amount only in the original currency (receipt in the expected currency and below it); fx_difference_base only when the original amounts are equal; the commitment reads received (delete block). Owner / agent member only (42501 margin_forbidden); a closed row CRM46; unknown CRM13. SECURITY DEFINER; EXECUTE crm_app.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-035', now(), 'AA-957 CRM-27: crm.commission (expected vs received, receipt-date FX, margin policy), crm.trip_cancellation (pending until Booking cancels), aa_request kind cancel, booking_line_money kind cancellation_cost, agency_supplier.commission_due_days, crm.commission_sync / commission_receive / booking_line_aa_cancel_fee')
ON CONFLICT (version) DO NOTHING;

COMMIT;
