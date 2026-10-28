-- Migration crm-023: AA-993 G4b (delivery pipeline, design S252 §2 "G4b", Q9) — the crm_dispatch send marker: one
-- crm.dispatch_attempt row is committed BEFORE the provider is called, so a crm_dispatch run that stops between the
-- send and its decision (a deploy releasing the job, a crash) never sends the message a second time: the re-run finds
-- the open attempt and holds the row as send_uncertain instead. With the marker, crm_dispatch leaves the deploy-gate
-- blocking list (app/jobs/kinds.py DEPLOY_BLOCKING_KINDS, AA-993 G5).
--
-- Owner: AA-Partner (api/migrations/023_crm_dispatch_attempt.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-023. crm.erase_subject below is the crm-022 text plus this file's
-- tenant table; a later key that replaces it starts from THIS text. crm.erase_held is unchanged (crm.dispatch_attempt
-- has no trip or traveller column: an erase that reaches its dispatch row is already held or not by that row).
-- crm.lifecycle_purge_expired is unchanged (crm-018).
--
-- Why. The provider send of crm_dispatch runs inside the transaction that holds the dispatch row lock
-- (app/dispatch/worker.py): a job released after the send and before the commit rolls the decision back, and the
-- re-claimed job sends the message again. The provider APIs take no idempotency key (app/mail/providers), and
-- asyncio.shield does not survive the process ending (design Q9). A committed marker turns "maybe sent twice" into
-- "held for a person to check" (send_uncertain), which is the only safe answer without a provider key.
--
-- What (DM-7: crm.dispatch_attempt joins the crm.dispatch_queue row of root data standards Part B §7, merged before
-- the Infra copy):
--   1. crm.dispatch_attempt (base template): one row per run of the dispatcher that passed the gate and is about to
--      call the sender, committed before the call (started_at, job_attempt). decided_at + outcome close it in the
--      transaction that decides the dispatch row (sent / held_reconnect / no_message / send_failed), or in a short
--      transaction of its own: retry (the sender raised, the job retries), not_sent (stopped before the sender was
--      called, or the row changed while it was unlocked), send_uncertain (a later run found it open). At most one open
--      attempt per dispatch row (dispatch_attempt_open_uq). Ids, counts, codes and times only: no personal data.
--      crm_app SELECT, INSERT and UPDATE (decided_at, outcome) only; a decided attempt never changes again
--      (crm.guard_dispatch_attempt, CRM38 attempt_decided); erased with its dispatch row (crm.erase_subject).
--   2. crm.dispatch_queue.gate_result: + send_uncertain (status held: the provider may have the message; a person
--      checks the agency's Sent folder; never re-queued by a mailbox reconnect).
--   3. crm.erase_subject (the crm-022 text) + dispatch_attempt in the trip, traveller and agency scopes, before
--      dispatch_queue (its foreign key has no ON DELETE action, as crm-019 explains).
--   SQLSTATE: CRM38 (the next key starts at CRM39).
--
-- Class: contract (ADR 0017 §3: the widened dispatch_queue_gate_chk and the replaced crm.erase_subject change
-- pre-existing objects), so no `-- migrate: expand` header (the runner does not know that flag before AA-993 M2a
-- either): MIG-4 order, this file's PR first, the Infra copy, a manual DB Migrate apply, then the code PR.
--
-- Order: after crm-022 (AA-951); Guard 0 refuses to run before it is registered (erase_subject builds on its text).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); the code before
-- AA-993 G4b never reads the table and never writes send_uncertain, so it runs unchanged on this schema.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-022 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-023: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-022') THEN
        RAISE EXCEPTION 'crm-023: crm-022 (AA-951 text proposal) lands first';
    END IF;
    IF to_regclass('crm.dispatch_queue') IS NULL OR to_regclass('crm.message_template') IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid = 'crm.dispatch_queue'::regclass
                        AND conname = 'dispatch_queue_tenant_id_uq')
       OR to_regprocedure('crm.erase_rows(text,text,uuid,uuid,boolean,text)') IS NULL
       OR to_regprocedure('crm.set_updated_at()') IS NULL THEN
        RAISE EXCEPTION 'crm-023: crm.dispatch_queue / crm.erase_rows (crm-010), crm.message_template (crm-022) or crm.set_updated_at (crm-002) missing';
    END IF;
END $$;

-- ── 1. crm.dispatch_attempt ──────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.dispatch_attempt (
    attempt_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                 REFERENCES crm.tenant (tenant_id),
    dispatch_id  UUID NOT NULL,
    job_attempt  SMALLINT NOT NULL,
    started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_at   TIMESTAMPTZ,
    outcome      TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ,
    deleted_by   TEXT,
    purge_after  TIMESTAMPTZ,
    -- Same-agency key (crm-012 dispatch_queue_tenant_id_uq): a foreign key check ignores RLS, so a single-column key
    -- would let an attempt of one agency name another agency's dispatch row. No ON DELETE action (crm-019 rule):
    -- crm.erase_subject deletes the attempts before their dispatch rows.
    CONSTRAINT dispatch_attempt_dispatch_fk FOREIGN KEY (tenant_id, dispatch_id)
        REFERENCES crm.dispatch_queue (tenant_id, dispatch_id),
    CONSTRAINT dispatch_attempt_outcome_chk CHECK (
        (decided_at IS NULL) = (outcome IS NULL)
        AND (outcome IS NULL OR outcome IN (
            'sent', 'held_reconnect', 'no_message', 'send_failed', 'retry', 'not_sent', 'send_uncertain'
        ))
        AND (decided_at IS NULL OR decided_at >= started_at)
    ),
    CONSTRAINT dispatch_attempt_job_attempt_chk CHECK (job_attempt BETWEEN 1 AND 100),
    CONSTRAINT dispatch_attempt_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
-- One open attempt per dispatch row: a second run that would open another while one is open fails on this index.
CREATE UNIQUE INDEX IF NOT EXISTS dispatch_attempt_open_uq ON crm.dispatch_attempt (dispatch_id)
    WHERE decided_at IS NULL;
CREATE INDEX IF NOT EXISTS dispatch_attempt_dispatch_idx ON crm.dispatch_attempt (tenant_id, dispatch_id);
COMMENT ON TABLE crm.dispatch_attempt IS 'AA-993 G4b (crm-023; design S252 Q9): the crm_dispatch send marker. One row per dispatcher run that passed the gate and calls the sender, committed BEFORE the provider call; decided_at + outcome close it with the decision (sent, held_reconnect, no_message, send_failed), or alone: retry (the sender raised, the job retries), not_sent (stopped before the sender was called, or the row changed in between), send_uncertain (a later run found it still open: the dispatch row is held send_uncertain and never sent again). At most one open attempt per dispatch row. Ids, counts, codes and times only, no personal data. crm_app SELECT, INSERT, UPDATE (decided_at, outcome); a decided attempt never changes (CRM38). Erased with its dispatch row (crm.erase_subject). Retention (DM-7): with its crm.dispatch_queue row';
COMMENT ON COLUMN crm.dispatch_attempt.job_attempt IS 'AA-993 G4b (crm-023): crm.job.attempt of the run that opened it (1-based)';
COMMENT ON COLUMN crm.dispatch_attempt.outcome IS 'AA-993 G4b (crm-023): NULL while open; sent, held_reconnect, no_message, send_failed (the sender''s answer, as the dispatch row''s gate_result), retry (the sender raised; the job retries, a new attempt follows), not_sent (stopped before the sender was called), send_uncertain (found open by a later run)';

CREATE OR REPLACE FUNCTION crm.guard_dispatch_attempt() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF current_user = 'crm_owner' AND current_setting('app.erasing', true) = 'on' THEN
        RETURN NEW;
    END IF;
    IF OLD.decided_at IS NOT NULL
       OR (to_jsonb(NEW) - 'decided_at' - 'outcome' - 'updated_at')
          IS DISTINCT FROM (to_jsonb(OLD) - 'decided_at' - 'outcome' - 'updated_at') THEN
        RAISE EXCEPTION 'crm: attempt_decided (a dispatch attempt is closed once, with its decided_at and outcome)'
            USING ERRCODE = 'CRM38';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_dispatch_attempt() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_dispatch_attempt() IS 'AA-993 G4b (crm-023): BEFORE UPDATE trigger on crm.dispatch_attempt: only an open attempt changes, and only its decided_at and outcome (CRM38 attempt_decided); crm.erase_subject (crm_owner with app.erasing on) passes.';

DO $$
BEGIN
    EXECUTE 'ALTER TABLE crm.dispatch_attempt ENABLE ROW LEVEL SECURITY';
    EXECUTE 'ALTER TABLE crm.dispatch_attempt FORCE ROW LEVEL SECURITY';
    EXECUTE 'DROP POLICY IF EXISTS tenant_isolation ON crm.dispatch_attempt';
    EXECUTE 'CREATE POLICY tenant_isolation ON crm.dispatch_attempt '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)';
    EXECUTE 'CREATE OR REPLACE TRIGGER dispatch_attempt_set_updated_at BEFORE UPDATE ON crm.dispatch_attempt '
            'FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at()';
    EXECUTE 'CREATE OR REPLACE TRIGGER dispatch_attempt_decided_once BEFORE UPDATE ON crm.dispatch_attempt '
            'FOR EACH ROW EXECUTE FUNCTION crm.guard_dispatch_attempt()';
    -- crm_app: insert and read; close an attempt (decided_at, outcome) only; never delete or truncate (default
    -- privileges gave it table-wide DML: take that back).
    EXECUTE 'REVOKE UPDATE, DELETE, TRUNCATE ON crm.dispatch_attempt FROM crm_app';
    EXECUTE 'GRANT SELECT, INSERT ON crm.dispatch_attempt TO crm_app';
    EXECUTE 'GRANT UPDATE (decided_at, outcome) ON crm.dispatch_attempt TO crm_app';
END $$;

-- ── 2. crm.dispatch_queue: the gate code send_uncertain ──────────────────────────────────────────
-- The crm-015 check plus send_uncertain (every existing row passes it: the list only grows).
ALTER TABLE crm.dispatch_queue DROP CONSTRAINT IF EXISTS dispatch_queue_gate_chk;
ALTER TABLE crm.dispatch_queue ADD CONSTRAINT dispatch_queue_gate_chk CHECK (
    (status = 'queued') = (gate_result IS NULL)
    AND (gate_result IS NULL OR gate_result IN (
        'sent', 'archived', 'traveler_trashed', 'trip_trashed', 'no_consent', 'no_sender', 'undone',
        'held_reconnect', 'send_failed', 'no_message', 'send_uncertain'
    ))
    AND (status = 'queued') = (decided_at IS NULL)
);
COMMENT ON COLUMN crm.dispatch_queue.gate_result IS 'the decision code: sent, archived, traveler_trashed, trip_trashed, no_consent, no_sender, undone (crm-010); AA-945: held_reconnect (the sending mailbox is disconnected: held, re-queued on reconnect, never sent through SES), send_failed (the provider refused it for good), no_message (nothing to send); AA-993 G4b (crm-023): send_uncertain (held: a run stopped after calling the provider and before its decision, crm.dispatch_attempt; the provider may have the message, so it is never sent again automatically)';

-- ── 3. crm.erase_subject: the crm-022 text plus dispatch_attempt ────────────────────────────────
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
        -- crm-022: the version's prep packs before the proposals.
        -- crm-023: the dispatch attempts of the trip's dispatch rows before those rows.
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
            ['prep_pack_selection', 'trip_id = $1', ''],
            ['proposal', 'trip_id = $1', ''],
            ['form_submission', 'trip_id = $1', 'trip_id = NULL, client_link_id = NULL'],
            ['client_link', 'trip_id = $1', ''],
            ['meeting_slot', 'trip_id = $1', ''],
            ['dispatch_attempt', 'dispatch_id IN (SELECT q.dispatch_id FROM crm.dispatch_queue q '
                                 'WHERE q.trip_id = $1)', ''],
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
        -- crm-023: the dispatch attempts of their dispatch rows before those rows.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['proposal', 'accepted_name_enc IS NOT NULL AND link_id IN (SELECT l.link_id FROM crm.client_link l '
                         'WHERE l.traveler_id = $1)', 'accepted_name_enc = NULL, accepted_name_erased_at = now()'],
            ['signature_request', 'traveler_id = $1', ''],
            ['otp_challenge', 'traveler_id = $1', ''],
            ['traveler_access', 'traveler_id = $1', ''],
            ['meeting_slot', 'traveler_id = $1 OR form_submission_id IN (SELECT s.submission_id '
                             'FROM crm.form_submission s WHERE s.traveler_id = $1)', ''],
            ['dispatch_attempt', 'dispatch_id IN (SELECT q.dispatch_id FROM crm.dispatch_queue q '
                                 'WHERE q.traveler_id = $1)', ''],
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
        -- crm-022: the prep packs before the proposals; the message templates with the agency's mail settings.
        -- crm-023: the dispatch attempts before the dispatch rows.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['membership_inbox', ''], ['inbox_events', ''], ['booking_feed_state', ''], ['metric_event', ''],
            ['signature_request', ''], ['otp_challenge', ''], ['traveler_access', ''], ['payment', ''],
            ['payment_schedule', ''], ['selection', ''], ['option_rule', ''], ['option', ''], ['option_block', ''],
            ['proposal_day', ''], ['prep_pack_selection', ''], ['proposal', ''], ['agreement_doc', ''],
            ['dispatch_attempt', ''], ['dispatch_queue', ''], ['message', ''], ['conversation', ''],
            ['trip_commitment', ''], ['aa_request', ''], ['booking_line_money', ''], ['booking_line', ''],
            ['agency_supplier', ''], ['document', ''], ['traveler_health', ''],
            ['note', ''], ['task', ''], ['trip_stage_history', ''], ['trip_party', ''], ['trip_traveler', ''],
            ['traveler_relation', ''], ['consent', ''], ['meeting_slot', ''], ['form_submission', ''],
            ['client_link', ''], ['profile_history', ''],
            ['traveler_profile', ''], ['placeholder_map', 'optional'], ['llm_call', ''], ['trip', ''],
            ['traveler', 'unlink'], ['traveler', ''], ['intake_form', ''], ['form_definition', ''],
            ['saved_reply', ''], ['message_template', ''], ['mail_import', ''], ['ingest_address', ''], ['channel_account', ''],
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

COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope), by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge), by AA-945 (crm-015) to mail (trip, traveller and agency scopes: message, conversation; agency scope: saved_reply, mail_import, ingest_address, channel_account; new scope conversation for the trash purge), by AA-946 (crm-016) to the lifecycle tables (trip and agency scopes: signature_request, otp_challenge, traveler_access, payment, payment_schedule, proposal; traveller scope: signature_request, otp_challenge, traveler_access, and the typed acceptance name of the proposals their links carried (accepted_name_enc := NULL); agency scope: agreement_doc) by AA-947 (crm-017) to the AA lines (trip, booking_line and agency scopes: aa_request; agency scope: inbox_events, booking_feed_state) by AA-949 (crm-019) to the proposal builder (trip and agency scopes: selection, option_rule, option, option_block, proposal_day) by AA-950 (crm-021) to crm.metric_event (trip and agency scopes) by AA-951 (crm-022) to crm.prep_pack_selection (trip and agency scopes) and crm.message_template (agency scope) and by AA-993 G4b (crm-023) to crm.dispatch_attempt (trip, traveller and agency scopes, before crm.dispatch_queue): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, conversation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
BEGIN
    IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class
             WHERE oid = 'crm.dispatch_attempt'::regclass) THEN
        RAISE EXCEPTION 'crm-023: crm.dispatch_attempt must have ENABLE + FORCE row level security';
    END IF;
    FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
        FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
            IF pg_catalog.has_table_privilege(r, 'crm.dispatch_attempt', p) THEN
                RAISE EXCEPTION 'crm-023: reader % may % on crm.dispatch_attempt', r, p;
            END IF;
        END LOOP;
    END LOOP;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.dispatch_attempt', 'DELETE')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.dispatch_attempt', 'TRUNCATE')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.dispatch_attempt', 'UPDATE')
       OR NOT pg_catalog.has_column_privilege('crm_app', 'crm.dispatch_attempt', 'outcome', 'UPDATE')
       OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.dispatch_attempt', 'INSERT') THEN
        RAISE EXCEPTION 'crm-023: crm_app inserts, reads and closes crm.dispatch_attempt (decided_at, outcome), never deletes';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'dispatch_attempt_decided_once'
                   AND tgrelid = 'crm.dispatch_attempt'::regclass) THEN
        RAISE EXCEPTION 'crm-023: crm.dispatch_attempt must close once (crm.guard_dispatch_attempt)';
    END IF;
    IF position('send_uncertain' IN (SELECT pg_catalog.pg_get_constraintdef(oid) FROM pg_catalog.pg_constraint
                 WHERE conrelid = 'crm.dispatch_queue'::regclass AND conname = 'dispatch_queue_gate_chk')) = 0 THEN
        RAISE EXCEPTION 'crm-023: crm.dispatch_queue_gate_chk must allow send_uncertain';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-023: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR pg_catalog.has_function_privilege('public', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-023: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    -- Every table an earlier key taught erase_subject, and this key's.
    FOREACH t IN ARRAY ARRAY['dispatch_attempt', 'dispatch_queue', 'prep_pack_selection', 'message_template',
                             'metric_event', 'selection', 'option_rule', 'option', 'option_block', 'proposal_day',
                             'aa_request', 'inbox_events', 'booking_feed_state', 'signature_request',
                             'otp_challenge', 'traveler_access', 'payment', 'payment_schedule', 'proposal',
                             'agreement_doc', 'message', 'conversation', 'saved_reply', 'mail_import',
                             'ingest_address', 'channel_account', 'booking_line_money', 'booking_line',
                             'agency_supplier', 'fx_rate_override', 'membership_inbox', 'client_link',
                             'meeting_slot'] LOOP
        IF position(quote_literal(t) IN (SELECT prosrc FROM pg_catalog.pg_proc
                     WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
            RAISE EXCEPTION 'crm-023: crm.erase_subject does not erase crm.%', t;
        END IF;
    END LOOP;
    IF position('accepted_name_erased_at' IN (SELECT prosrc FROM pg_catalog.pg_proc
                 WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-023: crm.erase_subject lost the crm-016 typed acceptance name step';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-023', now(), 'AA-993 G4b: the crm_dispatch send marker (crm.dispatch_attempt, committed before the provider call; at most one open per dispatch row; closed once, CRM38), dispatch_queue gate code send_uncertain, erase_subject + dispatch_attempt')
ON CONFLICT (version) DO NOTHING;

COMMIT;
