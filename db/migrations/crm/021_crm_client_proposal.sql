-- Migration crm-021: AA-950 (partner CRM, design v3 card CRM-21b) — the client side of the interactive proposal: the
-- signed link's page (C-03 Keep / Swap, C-04 accept, C-12 hold expired), the one Booking hold set per published
-- version with its daily re-check limit, the acceptance of a builder version with the client's picks, "viewed" and
-- the nudge (R4), and the agency's bell (metric events addressed to a member).
--
-- Owner: AA-Partner (api/migrations/021_crm_client_proposal.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-021 (crm-020 is AA-979's crm.studio_invitation, a platform table
-- that does not touch any object of this file; the two keys apply in either order). crm.erase_subject below is the
-- crm-019 text plus crm.metric_event; a later key that replaces it starts from THIS text. crm.erase_held and
-- crm.lifecycle_purge_expired are unchanged (every new row carries trip_id: the trip scope of crm.hold_trip reaches
-- it).
--
-- Why. Design v3 §6.3 card CRM-21b (deps CRM-21a, B2, B2b; implements M3 client side, R4, R19, R26, C31), §2.7 F5
-- (client choice) / F6 (accept, hold), §2.9 (client-page rules), §3.3 group E (`proposal.hold_set_ref` UNIQUE
-- (proposal, version), `recheck_count_day`, Fix A3) and group D (`metric_event`, R4 "proposal.viewed"), §3.5 (re-checks
-- at most 3 a day per proposal, a bell on every re-hold). Card R: accept after the hold expired -> 409 hold_expired with
-- a re-quote offer; a 4th re-check in a day -> "Ask your agent", no hold (the API; recheck_count_day <= 3 below is the
-- database's backstop). Card E: an option sells out mid-session -> the block falls back to its default and the total
-- is recomputed (crm-019 already lets an option of a sent version change its availability); the same link opens on a
-- second device (the token stays valid until expires_at: nothing here binds a link to a device, Fix B11).
--
-- What:
--   1. crm.proposal (builder versions): view_count / first_viewed_at / last_viewed_at / nudged_at (R4); the hold set
--      of this version (Fix A3): hold_set_ref (= 'crm-proposal:' || proposal_id, the Booking proposal_ref; UNIQUE),
--      hold_id, hold_quote_id, hold_expires_at, hold_selection_sha256 (the picks the hold covers), hold_placed_at,
--      hold_count (holds placed for this version: the first one and every re-hold); recheck_day / recheck_count_day
--      (re-holds used on that UTC day, 0..3); hold_attempt (the counter in the Booking Idempotency-Key, one per
--      new hold request) and the in-flight attempt hold_pending_key / _at / _quote_id / _price_hash /
--      _selection_sha256 (written before POST /holds, so a hold Booking made but whose answer was lost is replayed
--      with the same key and quote and recovered, never orphaned); hold_release_id (a hold whose release Booking did
--      not answer: released again before the next hold); the acceptance of a builder version: accepted_selection_sha256 (the
--      picks the client accepted), accepted_total_amount / accepted_deposit_amount (the amounts of those picks: the
--      published total is the defaults'), accepted_hold_id. The acceptance seal (crm-016 proposal_acceptance_sealed)
--      gains the four accepted_* columns.
--   2. crm.metric_event (base template, design group D): one event of a trip (proposal.viewed, option_chosen,
--      change_requested, hold_placed, rehold, recheck_refused, option_sold_out, booking_unavailable, accepted,
--      nudge_due ...): name, detail (ids, codes, counts and product titles only: never a name, a contact or free
--      text), and for the agency's bell the member it is addressed to (bell_member_id) and when they saw it
--      (seen_at, set once). crm_app inserts and reads; it may update seen_at only (column grant), never deletes.
--   3. crm.erase_subject (the crm-019 text) + metric_event (trip and agency scopes, before the proposals); the hold
--      guard on metric_event.
--   SQLSTATEs: none new (crm-020 holds CRM37; the next key starts at CRM38).
--
-- Order: after crm-019 (AA-949); Guard 0 refuses to run before it is registered. crm-020 is independent.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); before the AA-950
-- code deploys nothing reads these objects, and the code merges only after this file is applied (S249 lesson).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-019 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-021: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-019') THEN
        RAISE EXCEPTION 'crm-021: crm-019 (AA-949 proposal builder) lands first';
    END IF;
    IF to_regclass('crm.selection') IS NULL OR to_regprocedure('crm.guard_sealed_row()') IS NULL
       OR to_regprocedure('crm.guard_held_change()') IS NULL
       OR to_regprocedure('crm.erase_rows(text,text,uuid,uuid,boolean,text)') IS NULL THEN
        RAISE EXCEPTION 'crm-021: crm.selection (crm-019), crm.guard_sealed_row (crm-016) or crm.guard_held_change / crm.erase_rows (crm-010) missing';
    END IF;
END $$;

-- ── 1. crm.proposal: viewed, the hold set, the acceptance of a builder version ──────────────────
ALTER TABLE crm.proposal
    ADD COLUMN IF NOT EXISTS view_count                INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS first_viewed_at           TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_viewed_at            TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS nudged_at                 TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS hold_set_ref              TEXT,
    ADD COLUMN IF NOT EXISTS hold_id                   TEXT,
    ADD COLUMN IF NOT EXISTS hold_quote_id             TEXT,
    ADD COLUMN IF NOT EXISTS hold_expires_at           TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS hold_selection_sha256     BYTEA,
    ADD COLUMN IF NOT EXISTS hold_placed_at            TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS hold_count                SMALLINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS recheck_day               DATE,
    ADD COLUMN IF NOT EXISTS recheck_count_day         SMALLINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS hold_attempt              SMALLINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS hold_pending_key          TEXT,
    ADD COLUMN IF NOT EXISTS hold_pending_at           TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS hold_pending_quote_id     TEXT,
    ADD COLUMN IF NOT EXISTS hold_pending_price_hash   TEXT,
    ADD COLUMN IF NOT EXISTS hold_pending_selection_sha256 BYTEA,
    ADD COLUMN IF NOT EXISTS hold_release_id           TEXT,
    ADD COLUMN IF NOT EXISTS accepted_selection_sha256 BYTEA,
    ADD COLUMN IF NOT EXISTS accepted_total_amount     NUMERIC(14, 2),
    ADD COLUMN IF NOT EXISTS accepted_deposit_amount   NUMERIC(14, 2),
    ADD COLUMN IF NOT EXISTS accepted_hold_id          TEXT;

ALTER TABLE crm.proposal DROP CONSTRAINT IF EXISTS proposal_viewed_chk;
ALTER TABLE crm.proposal ADD CONSTRAINT proposal_viewed_chk CHECK (
    view_count >= 0
    AND (first_viewed_at IS NULL) = (view_count = 0)
    AND (last_viewed_at IS NULL) = (first_viewed_at IS NULL)
    AND (last_viewed_at IS NULL OR last_viewed_at >= first_viewed_at)
    AND (nudged_at IS NULL OR first_viewed_at IS NOT NULL)
);
-- Fix A3: one hold set per version (this row), re-holds at most 3 a UTC day (the API refuses the 4th: "Ask your
-- agent"); hold columns only on a builder version.
ALTER TABLE crm.proposal DROP CONSTRAINT IF EXISTS proposal_hold_chk;
ALTER TABLE crm.proposal ADD CONSTRAINT proposal_hold_chk CHECK (
    (hold_set_ref IS NULL OR hold_set_ref = 'crm-proposal:' || proposal_id::text)
    AND (hold_id IS NULL OR hold_id ~ '^[A-Za-z0-9:_.-]{1,64}$')
    AND (hold_quote_id IS NULL OR hold_quote_id ~ '^[A-Za-z0-9:_.-]{1,64}$')
    AND (accepted_hold_id IS NULL OR accepted_hold_id ~ '^[A-Za-z0-9:_.-]{1,64}$')
    AND (hold_release_id IS NULL OR hold_release_id ~ '^[A-Za-z0-9:_.-]{1,64}$')
    AND (hold_release_id IS NULL OR hold_id IS NULL)
    AND num_nonnulls(hold_id, hold_quote_id, hold_expires_at, hold_selection_sha256, hold_placed_at) IN (0, 5)
    AND (hold_id IS NULL OR (hold_set_ref IS NOT NULL AND hold_count >= 1))
    AND coalesce(octet_length(hold_selection_sha256), 32) = 32
    AND hold_count BETWEEN 0 AND 1000
    AND recheck_count_day BETWEEN 0 AND 3
    AND (recheck_count_day = 0 OR recheck_day IS NOT NULL)
    AND (kind = 'builder' OR (hold_set_ref IS NULL AND hold_id IS NULL AND hold_count = 0 AND recheck_day IS NULL
                              AND recheck_count_day = 0 AND hold_release_id IS NULL))
);
-- The in-flight hold request (one at a time per version): its key and start, then the quote it presents once quoted.
-- Cleared when Booking answered (held or refused); kept when the answer was lost, so the next request replays it.
ALTER TABLE crm.proposal DROP CONSTRAINT IF EXISTS proposal_hold_pending_chk;
ALTER TABLE crm.proposal ADD CONSTRAINT proposal_hold_pending_chk CHECK (
    hold_attempt BETWEEN 0 AND 10000
    AND (hold_pending_key IS NULL OR hold_pending_key ~ '^crm-proposal:[0-9a-f-]{36}:v[0-9]{1,5}:a[0-9]{1,5}$')
    AND (hold_pending_key IS NULL) = (hold_pending_at IS NULL)
    AND (hold_pending_key IS NULL OR hold_attempt >= 1)
    AND num_nonnulls(hold_pending_quote_id, hold_pending_price_hash, hold_pending_selection_sha256) IN (0, 3)
    AND (hold_pending_quote_id IS NULL OR hold_pending_key IS NOT NULL)
    AND (hold_pending_quote_id IS NULL OR hold_pending_quote_id ~ '^[A-Za-z0-9:_.-]{1,64}$')
    AND (hold_pending_price_hash IS NULL OR hold_pending_price_hash ~ '^[a-f0-9]{64}$')
    AND coalesce(octet_length(hold_pending_selection_sha256), 32) = 32
    AND (kind = 'builder' OR (hold_attempt = 0 AND hold_pending_key IS NULL))
);
-- The acceptance of a builder version carries the picks and their amounts; a text version has none of them.
ALTER TABLE crm.proposal DROP CONSTRAINT IF EXISTS proposal_accepted_choice_chk;
ALTER TABLE crm.proposal ADD CONSTRAINT proposal_accepted_choice_chk CHECK (
    coalesce(octet_length(accepted_selection_sha256), 32) = 32
    AND CASE
        WHEN kind = 'builder' AND accepted_at IS NOT NULL THEN
            accepted_selection_sha256 IS NOT NULL AND accepted_total_amount > 0 AND accepted_deposit_amount > 0
            AND accepted_deposit_amount <= accepted_total_amount
        ELSE num_nonnulls(accepted_selection_sha256, accepted_total_amount, accepted_deposit_amount,
                          accepted_hold_id) = 0
    END
);
CREATE UNIQUE INDEX IF NOT EXISTS proposal_hold_set_uq ON crm.proposal (tenant_id, hold_set_ref)
    WHERE hold_set_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS proposal_nudge_idx ON crm.proposal (tenant_id, first_viewed_at)
    WHERE status = 'sent' AND nudged_at IS NULL AND first_viewed_at IS NOT NULL AND deleted_at IS NULL;

DO $$
BEGIN
    -- crm-016's acceptance seal plus the builder acceptance: written on the move sent -> accepted only.
    EXECUTE 'CREATE OR REPLACE TRIGGER proposal_acceptance_sealed BEFORE UPDATE ON crm.proposal FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_sealed_row(''sent'', ''accepted_at'', ''accepted_name_enc'', '
            '''accepted_name_erased_at'', ''accepted_price_hash'', ''accepted_terms_doc_id'', '
            '''accepted_selection_sha256'', ''accepted_total_amount'', ''accepted_deposit_amount'', '
            '''accepted_hold_id'')';
END $$;
COMMENT ON COLUMN crm.proposal.view_count IS 'AA-950 (crm-021; R4): how many times the client page read this version (a re-read within the hour counts, the metric event does not repeat)';
COMMENT ON COLUMN crm.proposal.nudged_at IS 'AA-950 (crm-021; R4): when the hourly run gave the trip owner the follow-up task (viewed 2 days ago, nothing chosen, not accepted); once per version';
COMMENT ON COLUMN crm.proposal.hold_set_ref IS 'AA-950 (crm-021; Fix A3): the Booking proposal_ref of this version''s hold set (crm-proposal:<proposal_id>; proposal_version = version): one hold set per (proposal, version), UNIQUE';
COMMENT ON COLUMN crm.proposal.hold_selection_sha256 IS 'AA-950 (crm-021): SHA-256 of the AA picks the current hold covers; a pick that changes them needs a new hold (a re-hold) before accept';
COMMENT ON COLUMN crm.proposal.hold_count IS 'AA-950 (crm-021; Fix A3): holds placed for this version, the first one included; every one after the first is a re-hold (a bell to the trip owner)';
COMMENT ON COLUMN crm.proposal.hold_attempt IS 'AA-950 (crm-021): new hold requests made for this version; the Booking Idempotency-Key is <hold_set_ref>:v<version>:a<hold_attempt>, so every new quote gets a fresh key (Booking refuses a used key with another quote)';
COMMENT ON COLUMN crm.proposal.hold_pending_key IS 'AA-950 (crm-021): the hold request in flight (set before Booking is asked, with hold_pending_at; the quote columns once quoted). Cleared when Booking answered; kept when the answer was lost, so the next request replays the same key and quote and recovers the hold Booking made';
COMMENT ON COLUMN crm.proposal.hold_release_id IS 'AA-950 (crm-021): a hold of this version whose release Booking did not answer (a timeout or a 5xx): it is no longer shown or accepted, and the next hold request releases it again first (a no-op when Booking had released it), so Booking never keeps a second set for the version';
COMMENT ON COLUMN crm.proposal.recheck_count_day IS 'AA-950 (crm-021; Fix A3, C-12): re-holds used on recheck_day (UTC, as Booking''s limit): at most 3; the 4th is refused before Booking is asked ("Ask your agent")';
COMMENT ON COLUMN crm.proposal.accepted_selection_sha256 IS 'AA-950 (crm-021): builder versions: SHA-256 of the picks the client accepted (block -> option, choose later); sealed with the acceptance';
COMMENT ON COLUMN crm.proposal.accepted_total_amount IS 'AA-950 (crm-021): builder versions: the charged total of the accepted picks (the published total_amount is the defaults''); the payment schedule follows it';

-- ── 2. crm.metric_event ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.metric_event (
    metric_event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                    REFERENCES crm.tenant (tenant_id),
    trip_id         UUID NOT NULL,
    proposal_id     UUID,
    name            TEXT NOT NULL,
    detail          JSONB NOT NULL DEFAULT '{}'::jsonb,
    bell_member_id  UUID,
    seen_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ,
    deleted_by      TEXT,
    purge_after     TIMESTAMPTZ,
    CONSTRAINT metric_event_tenant_id_uq UNIQUE (tenant_id, metric_event_id),
    CONSTRAINT metric_event_trip_fk FOREIGN KEY (tenant_id, trip_id) REFERENCES crm.trip (tenant_id, trip_id),
    CONSTRAINT metric_event_proposal_fk FOREIGN KEY (tenant_id, proposal_id, trip_id)
        REFERENCES crm.proposal (tenant_id, proposal_id, trip_id),
    CONSTRAINT metric_event_member_fk FOREIGN KEY (tenant_id, bell_member_id)
        REFERENCES crm.member (tenant_id, member_id),
    CONSTRAINT metric_event_values_chk CHECK (
        name ~ '^[a-z][a-z0-9_]{0,30}\.[a-z][a-z0-9_]{0,30}$'
        AND jsonb_typeof(detail) = 'object' AND octet_length(detail::text) <= 4000
        AND (seen_at IS NULL OR bell_member_id IS NOT NULL)
    ),
    CONSTRAINT metric_event_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS metric_event_trip_idx ON crm.metric_event (tenant_id, trip_id, created_at);
CREATE INDEX IF NOT EXISTS metric_event_bell_idx ON crm.metric_event (tenant_id, bell_member_id, created_at DESC)
    WHERE bell_member_id IS NOT NULL AND seen_at IS NULL;
CREATE INDEX IF NOT EXISTS metric_event_proposal_idx ON crm.metric_event (tenant_id, proposal_id, name)
    WHERE proposal_id IS NOT NULL;
COMMENT ON TABLE crm.metric_event IS 'AA-950 (crm-021; design v3 group D, R4, Fix A3): one event of a trip (proposal.viewed, proposal.option_chosen, proposal.change_requested, proposal.hold_placed, proposal.rehold, proposal.recheck_refused, proposal.option_sold_out, proposal.booking_unavailable, proposal.accepted, proposal.nudge_due ...). detail holds ids, codes, counts and product titles only (never a name, a contact or free text). bell_member_id: the member the agency bell shows it to (the trip owner), seen_at when they marked it seen (set once). crm_app inserts, reads and sets seen_at only; erased with its trip / agency (crm.erase_subject). Retention (DM-7, proposed): with the trip; the raw rows after the daily rollup of the metrics card (CRM-34)';
COMMENT ON COLUMN crm.metric_event.detail IS 'AA-950 (crm-021): ids, codes, counts and product titles only (the choice diff of R19: block / option titles, deltas); never personal data or free text';

CREATE OR REPLACE FUNCTION crm.guard_metric_event() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF current_user = 'crm_owner' AND current_setting('app.erasing', true) = 'on' THEN
        RETURN NEW;
    END IF;
    IF (to_jsonb(NEW) - 'seen_at' - 'updated_at') IS DISTINCT FROM (to_jsonb(OLD) - 'seen_at' - 'updated_at')
       OR (OLD.seen_at IS NOT NULL AND NEW.seen_at IS DISTINCT FROM OLD.seen_at) THEN
        RAISE EXCEPTION 'crm: row_sealed (a metric event only gets its seen_at, once)' USING ERRCODE = 'CRM31';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_metric_event() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_metric_event() IS 'AA-950 (crm-021): BEFORE UPDATE trigger on crm.metric_event: an event never changes except its seen_at, set once (CRM31 row_sealed); crm.erase_subject (crm_owner with app.erasing on) passes.';

DO $$
BEGIN
    EXECUTE 'ALTER TABLE crm.metric_event ENABLE ROW LEVEL SECURITY';
    EXECUTE 'ALTER TABLE crm.metric_event FORCE ROW LEVEL SECURITY';
    EXECUTE 'DROP POLICY IF EXISTS tenant_isolation ON crm.metric_event';
    EXECUTE 'CREATE POLICY tenant_isolation ON crm.metric_event '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)';
    EXECUTE 'CREATE OR REPLACE TRIGGER metric_event_set_updated_at BEFORE UPDATE ON crm.metric_event '
            'FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at()';
    EXECUTE 'CREATE OR REPLACE TRIGGER metric_event_sealed BEFORE UPDATE ON crm.metric_event '
            'FOR EACH ROW EXECUTE FUNCTION crm.guard_metric_event()';
    EXECUTE 'DROP TRIGGER IF EXISTS metric_event_hold_guard ON crm.metric_event';
    EXECUTE 'CREATE TRIGGER metric_event_hold_guard BEFORE DELETE OR UPDATE ON crm.metric_event FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_held_change(''trip_id'')';
    -- crm_app: insert and read; update the seen_at column only; never delete or truncate (default privileges gave
    -- it table-wide DML: take that back).
    EXECUTE 'REVOKE UPDATE, DELETE, TRUNCATE ON crm.metric_event FROM crm_app';
    EXECUTE 'GRANT SELECT, INSERT ON crm.metric_event TO crm_app';
    EXECUTE 'GRANT UPDATE (seen_at) ON crm.metric_event TO crm_app';
END $$;

-- ── 3. crm.erase_subject: the crm-019 text plus crm.metric_event ─────────────────────────────────
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
        -- crm-017: the trip's AA requests (the outage queue) before its lines.
        -- crm-019: the builder rows (picks, rules, options, blocks, days) before the proposals.
        -- crm-021: the trip's metric events (they name its proposals) first.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['metric_event', 'trip_id = $1', ''],
            ['signature_request', 'trip_id = $1', ''],
            ['otp_challenge', 'trip_id = $1', ''],
            ['traveler_access', 'trip_id = $1', ''],
            ['payment', 'trip_id = $1', ''],
            ['payment_schedule', 'trip_id = $1', ''],
            ['selection', 'trip_id = $1', ''],
            ['option_rule', 'trip_id = $1', ''],
            ['option', 'trip_id = $1', ''],
            ['option_block', 'trip_id = $1', ''],
            ['proposal_day', 'trip_id = $1', ''],
            ['proposal', 'trip_id = $1', ''],
            ['form_submission', 'trip_id = $1', 'trip_id = NULL, client_link_id = NULL'],
            ['client_link', 'trip_id = $1', ''],
            ['meeting_slot', 'trip_id = $1', ''],
            ['dispatch_queue', 'trip_id = $1', ''],
            ['message', 'conversation_id IN (SELECT c.conversation_id FROM crm.conversation c WHERE c.trip_id = $1)', ''],
            ['conversation', 'trip_id = $1', ''],
            ['trip_commitment', 'trip_id = $1', ''],
            ['aa_request', 'trip_id = $1', ''],
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
        -- crm-014: the trash purge of a planning line: its money, then the line. crm-017: its AA requests first (an
        -- agency line has none; an AA line never reaches the trash, the guard refuses it).
        v_counts := jsonb_build_object(
            'aa_request', crm.erase_rows('aa_request', 'booking_line_id = $1', p_subject, NULL, p_dry_run),
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
        -- crm-017: the Booking feed records and cursor, then the AA requests before the lines.
        -- crm-019: the builder rows before the proposals. crm-021: the metric events before the proposals and members.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['membership_inbox', ''], ['inbox_events', ''], ['booking_feed_state', ''], ['metric_event', ''],
            ['signature_request', ''], ['otp_challenge', ''], ['traveler_access', ''], ['payment', ''],
            ['payment_schedule', ''], ['selection', ''], ['option_rule', ''], ['option', ''], ['option_block', ''],
            ['proposal_day', ''], ['proposal', ''], ['agreement_doc', ''],
            ['dispatch_queue', ''], ['message', ''], ['conversation', ''],
            ['trip_commitment', ''], ['aa_request', ''], ['booking_line_money', ''], ['booking_line', ''],
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

COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope), by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge), by AA-945 (crm-015) to mail (trip, traveller and agency scopes: message, conversation; agency scope: saved_reply, mail_import, ingest_address, channel_account; new scope conversation for the trash purge), by AA-946 (crm-016) to the lifecycle tables (trip and agency scopes: signature_request, otp_challenge, traveler_access, payment, payment_schedule, proposal; traveller scope: signature_request, otp_challenge, traveler_access, and the typed acceptance name of the proposals their links carried (accepted_name_enc := NULL); agency scope: agreement_doc) by AA-947 (crm-017) to the AA lines (trip, booking_line and agency scopes: aa_request; agency scope: inbox_events, booking_feed_state) by AA-949 (crm-019) to the proposal builder (trip and agency scopes: selection, option_rule, option, option_block, proposal_day) and by AA-950 (crm-021) to crm.metric_event (trip and agency scopes): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, conversation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
BEGIN
    IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class
            WHERE oid = 'crm.metric_event'::regclass) THEN
        RAISE EXCEPTION 'crm-021: crm.metric_event must have ENABLE + FORCE row level security';
    END IF;
    IF NOT pg_catalog.has_table_privilege('crm_app', 'crm.metric_event', 'SELECT')
       OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.metric_event', 'INSERT')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.metric_event', 'UPDATE')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.metric_event', 'DELETE')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.metric_event', 'TRUNCATE')
       OR NOT pg_catalog.has_column_privilege('crm_app', 'crm.metric_event', 'seen_at', 'UPDATE')
       OR pg_catalog.has_column_privilege('crm_app', 'crm.metric_event', 'detail', 'UPDATE') THEN
        RAISE EXCEPTION 'crm-021: crm_app reads and inserts crm.metric_event and updates seen_at only';
    END IF;
    FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
        FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
            IF pg_catalog.has_table_privilege(r, 'crm.metric_event', p) THEN
                RAISE EXCEPTION 'crm-021: reader % may % on crm.metric_event', r, p;
            END IF;
        END LOOP;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-021: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-021: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.erase_subject(text,uuid,uuid,boolean)', 'crm.guard_metric_event()'] LOOP
        IF pg_catalog.has_function_privilege('public', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-021: % is executable by PUBLIC (SEC-4)', t;
        END IF;
    END LOOP;
    -- Every table an earlier key taught erase_subject, and this key's.
    FOREACH t IN ARRAY ARRAY['metric_event', 'selection', 'option_rule', 'option', 'option_block', 'proposal_day',
                             'aa_request', 'inbox_events', 'booking_feed_state', 'signature_request',
                             'otp_challenge', 'traveler_access', 'payment', 'payment_schedule', 'proposal',
                             'agreement_doc', 'message', 'conversation', 'saved_reply', 'mail_import',
                             'ingest_address', 'channel_account', 'booking_line_money', 'booking_line',
                             'agency_supplier', 'fx_rate_override', 'membership_inbox', 'client_link',
                             'meeting_slot'] LOOP
        IF position(quote_literal(t) IN (SELECT prosrc FROM pg_catalog.pg_proc
                     WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
            RAISE EXCEPTION 'crm-021: crm.erase_subject does not erase crm.%', t;
        END IF;
    END LOOP;
    IF position('accepted_name_erased_at' IN (SELECT prosrc FROM pg_catalog.pg_proc
                 WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-021: crm.erase_subject lost the crm-016 typed acceptance name step';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'proposal_acceptance_sealed'
                   AND tgrelid = 'crm.proposal'::regclass
                   AND position('accepted_selection_sha256' IN pg_catalog.encode(tgargs, 'escape')) > 0) THEN
        RAISE EXCEPTION 'crm-021: the acceptance seal must cover the builder acceptance columns';
    END IF;
    FOREACH t IN ARRAY ARRAY['proposal_sent_once', 'proposal_sealed'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = t AND tgrelid = 'crm.proposal'::regclass) THEN
            RAISE EXCEPTION 'crm-021: crm.proposal lost its % trigger (crm-019)', t;
        END IF;
    END LOOP;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-021', now(), 'AA-950: CRM-21b client proposal (proposal viewed / nudged, the hold set per version with hold_set_ref and recheck_count_day <= 3, the builder acceptance columns under the acceptance seal; crm.metric_event with the bell columns and its guard; erase_subject + metric_event)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
