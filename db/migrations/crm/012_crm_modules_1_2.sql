-- Migration crm-012: AA-943 (partner CRM, design v3 card CRM-15) — Modules 1 + 2 complete: every trip stage edge with
-- the Proposal gate, undo of a move, cancellation, the date-rule columns, Stage 2 completeness, the Stage 2 signed link
-- and call slots (R15), and the erasure / hold rule extended to the two new tables.
--
-- Owner: AA-Partner (api/migrations/012_crm_modules_1_2.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-012 (crm-013 = AA-978, crm-014 = AA-944, crm-015 = AA-945; each of
-- those that replaces crm.erase_subject starts from the text below, S250 schedule §1).
--
-- Why. Design v3 §2.7 F1 / F2 (Stage 2 form sent or filled in from a call, "Get planning info" below 80 %, the gate to
-- Proposal: Stage 2 >= 80 % or a logged override, else 409 stage2_incomplete), §3.3 group D (all nine stages defined in
-- CRM-15, Fix B5; waiting_on, Fix B1), §3.5 (stage transitions, cancelled from booked / pre_departure / travelling, lost
-- before booked, the date rule with reason date_rule_gate_unmet and an urgent task, Fix B4; Undo, Fix B8), group E
-- (client_link: revoked_at, reissued_from, Fix B11), group G (meeting_slot, R15), R31 (conditional forms: the server
-- drops hidden-branch answers and counts them in form_submission.hidden_answers_dropped, crm-005). Card R: Qualifying ->
-- Proposal under 80 % without an override -> 409 stage2_incomplete. Card E: Booked with Stage 3 missing on the departure
-- date -> Travelling + an urgent task; Undo within 10 s cancels the auto-sent planning form.
--
-- What:
--   1. crm.status_transition rows for trip (Fix B5, design §3.5): qualifying -> proposal, proposal -> qualifying,
--      proposal -> booked, proposal -> lost, booked -> pre_departure, booked -> travelling, pre_departure ->
--      travelling, travelling -> completed, booked | pre_departure | travelling -> cancelled. lost stays reachable only
--      before booked (inquiry, qualifying, proposal). No other reverse edge: a move is taken back by Undo (item 2b).
--   2. crm.enforce_stage_transition() (crm-005) replaced. On a stage change of crm.trip:
--      a. Gates (defence in depth behind the API's 409; the API decides first and writes the override reason):
--           qualifying -> proposal   needs trip.intake_completeness->>'s2' >= 80, or app.gate_override = 'stage2';
--           proposal -> booked       needs app.gate_override = 'booking' (computable from CRM-18 / CRM-24a; until
--                                     then an override with the reason manual_booking);
--           booked -> pre_departure  needs app.gate_override = 'stage3' (computable from CRM-25; reason manual_stage3).
--         A refused gate raises SQLSTATE CRM19 ('stage2_incomplete' / 'gate_unmet:<gate>').
--      b. Undo: while app.stage_undo = <history id>, the change must be the exact reverse of that crm.trip_stage_history
--         row, which must be the trip's latest row, at most 15 s old (the API offers 10 s), not itself an undo, not a
--         move into cancelled (the cancel flow has its own effects and no undo), and written by the same actor
--         (app.actor = its created_by: only the member who moved undoes; a job move has no undo). The edge table and
--         the gates are not consulted for it. Anything else raises SQLSTATE CRM20 ('undo_not_allowed').
--         Every other change: the edge must be a row of crm.status_transition (check_violation, as in crm-005).
--   3. crm.trip: intake_completeness jsonb {s1, s2, s3} (integers 0..100, crm.completeness_ok), cancel_reason_code
--      (fixed list, set exactly when stage = cancelled), last_activity_at (the board's "quiet > 3 days" flag; bumped by
--      the API on a move, note, task or submission). Existing rows get {0, 0, 0} and now(): FORCE RLS hides every row
--      from this file, so there is no backfill (same as crm-011); the API recomputes completeness on the next change.
--      Indexes for the board's quiet flag and for the hourly date-rule job.
--   4. crm.trip_stage_history (append-only, still): override_reason_code (fixed list; override = true exactly when it
--      is set), undo_of (the history row an undo reverts; same-agency key; reason_code undo), batch_id (one id per bulk
--      move). A BEFORE INSERT trigger (crm.pin_stage_history_insert) pins at = now() and created_by = app.actor for
--      every role but crm_owner (the crm-007 audit pattern), so the undo rule's age and actor read what the database
--      wrote, and checks that undo_of names a row of the same trip.
--   5. crm.task.priority normal | urgent (default normal): the date rule's urgent task (Fix B4).
--   6. crm.tenant_settings: timezone (IANA name, default Asia/Ho_Chi_Minh; the database checks the shape only, the API
--      checks it against pg_timezone_names), stage2_auto_send (default false), call_slot_rules (R15: weekly windows,
--      slot length, horizon; '{}' = no slots offered; crm.call_slot_rules_ok).
--   7. crm.client_link (base template; design group E, lane §2 "client_link"): a signed link to a client page. Today
--      purpose stage2_form only (the Stage 2 planning form, C-02); CRM-20 / CRM-21 / CRM-24 add purposes. token_hash =
--      SHA-256 of a random 32-byte token (the token itself is never stored), expires_at (at most 30 days; the API uses
--      14), status sent -> opened -> submitted, or expired / revoked, with revoked_at and reissued_from (Fix B11),
--      dispatch_id = the crm.dispatch_queue row that carried it (SET NULL when that row is erased). SELECT-only policy
--      client_link_token_lookup TO crm_app keyed on app.client_link_hash (hex), live links only: set only by
--      app.tenancy.client_link_tx() (AA-943 S3), the invitation_token_lookup pattern of crm-008. crm_app never deletes
--      a link (status moves only).
--   8. crm.meeting_slot (base template; R15): a call slot of the agency: trip and / or traveller, starts_at,
--      duration_min, status requested -> confirmed -> done, or cancelled; source form (with the form_submission that
--      asked for it) or agent. One live slot per agency start time (partial UNIQUE). No PII. crm_app never deletes
--      one. Calendar sync is AA-961 (CRM-30).
--   9. crm.form_submission for Stage 2 / 3: intake_form_id is required for stage s1 only; client_link_id (the link a
--      client submitted through; with trip_id and traveler_id, one composite same-agency key to the link's own trip and
--      traveller); outcome adds applied (a Stage 2 / 3 answer set written to the profile).
--  10. Same-agency keys (crm-006 rule 7b) for every new reference: UNIQUE (tenant_id, id) on crm.dispatch_queue,
--      crm.form_submission and crm.trip_stage_history, and composite foreign keys from the new columns and tables.
--  11. The hold rule and erasure (crm-010 items 4, 10) extended to the new tables:
--      a. crm.erase_held (4e): a trip erase also reaches the travellers named on the trip's links and slots; a
--         traveller erase also reaches the trips of their links and slots, and every slot it deletes.
--      b. crm.erase_subject: trip scope unlinks the trip's submissions (trip_id and client_link_id := NULL) first, then
--         deletes its links and slots; traveller scope deletes their slots (also those booked by their submissions)
--         first and their links after their submissions; the agency erase deletes both tables. Everything else is the
--         crm-010 text unchanged.
--      c. crm.guard_held_change (4h) on both tables: trip_id and traveler_id are guarded.
--      crm.lifecycle_purge_expired (crm-010 item 11) is not replaced: it purges llm_call and placeholder_map only, and
--      neither new table is reached by it.
--   No NOLOGIN reader gets anything on the new tables or columns (client_link carries a credential hash).
--
-- Order: after crm-011 (AA-941), which needs crm-008 and crm-010; Guard 0 refuses to run before crm-011 is registered.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); before the AA-943 code
-- deploys nothing reads these objects, and the code merges only after this file is applied (S249 lesson).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-011 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-012: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-011') THEN
        RAISE EXCEPTION 'crm-012: crm-011 is not registered (the L1 console, AA-941, lands first)';
    END IF;
    IF to_regclass('crm.dispatch_queue') IS NULL OR to_regprocedure('crm.erase_subject(text,uuid,uuid,boolean)') IS NULL
    THEN
        RAISE EXCEPTION 'crm-012: crm.dispatch_queue / crm.erase_subject are missing (crm-010)';
    END IF;
END $$;

-- ── 1. Trip stage edges ──────────────────────────────────────────────────────────────────────────
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('trip', 'qualifying', 'proposal'),
    ('trip', 'proposal', 'qualifying'),
    ('trip', 'proposal', 'booked'),
    ('trip', 'proposal', 'lost'),
    ('trip', 'booked', 'pre_departure'),
    ('trip', 'booked', 'travelling'),
    ('trip', 'pre_departure', 'travelling'),
    ('trip', 'travelling', 'completed'),
    ('trip', 'booked', 'cancelled'),
    ('trip', 'pre_departure', 'cancelled'),
    ('trip', 'travelling', 'cancelled')
ON CONFLICT DO NOTHING;

-- ── 3. crm.trip columns (before the trigger function, which reads intake_completeness) ───────────
CREATE OR REPLACE FUNCTION crm.completeness_ok(p jsonb) RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    k text;
    v numeric;
BEGIN
    IF p IS NULL OR jsonb_typeof(p) <> 'object' OR (p - 's1' - 's2' - 's3') <> '{}'::jsonb THEN
        RETURN false;
    END IF;
    FOREACH k IN ARRAY ARRAY['s1', 's2', 's3'] LOOP
        IF jsonb_typeof(p -> k) IS DISTINCT FROM 'number' THEN
            RETURN false;
        END IF;
        v := (p ->> k)::numeric;
        IF v < 0 OR v > 100 OR v <> trunc(v) THEN
            RETURN false;
        END IF;
    END LOOP;
    RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION crm.completeness_ok(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.completeness_ok(jsonb) TO crm_app;
COMMENT ON FUNCTION crm.completeness_ok(jsonb) IS 'AA-943 (crm-012): the shape of crm.trip.intake_completeness: exactly the keys s1, s2, s3, each an integer 0..100. Used by trip_intake_completeness_chk (crm_app needs EXECUTE to write the table).';

ALTER TABLE crm.trip ADD COLUMN IF NOT EXISTS intake_completeness JSONB NOT NULL
    DEFAULT '{"s1": 0, "s2": 0, "s3": 0}'::jsonb;
ALTER TABLE crm.trip ADD COLUMN IF NOT EXISTS cancel_reason_code TEXT;
ALTER TABLE crm.trip ADD COLUMN IF NOT EXISTS last_activity_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE crm.trip DROP CONSTRAINT IF EXISTS trip_intake_completeness_chk;
ALTER TABLE crm.trip ADD CONSTRAINT trip_intake_completeness_chk CHECK (crm.completeness_ok(intake_completeness));
ALTER TABLE crm.trip DROP CONSTRAINT IF EXISTS trip_cancel_reason_chk;
ALTER TABLE crm.trip ADD CONSTRAINT trip_cancel_reason_chk CHECK (
    (stage = 'cancelled') = (cancel_reason_code IS NOT NULL)
    AND (cancel_reason_code IS NULL OR cancel_reason_code IN (
        'client_request', 'client_illness', 'travel_advisory', 'force_majeure', 'supplier_failure', 'aa_cancelled',
        'payment_not_received', 'duplicate', 'other'
    ))
);
CREATE INDEX IF NOT EXISTS trip_quiet_idx ON crm.trip (tenant_id, stage, last_activity_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS trip_date_rule_idx ON crm.trip (tenant_id, stage, start_date)
    WHERE deleted_at IS NULL AND stage IN ('booked', 'pre_departure', 'travelling');
COMMENT ON COLUMN crm.trip.intake_completeness IS 'AA-943 (crm-012): Stage 1 / 2 / 3 completeness in percent {s1, s2, s3} (app.intake.completeness); s2 >= 80 opens the gate to Proposal (crm.enforce_stage_transition)';
COMMENT ON COLUMN crm.trip.cancel_reason_code IS 'AA-943 (crm-012, C12): why the trip was cancelled, set by the cancel flow exactly when stage = cancelled';
COMMENT ON COLUMN crm.trip.last_activity_at IS 'AA-943 (crm-012): the latest move, note, task change or submission on the trip; the board flags a trip quiet for more than 3 days';

-- ── 4. crm.trip_stage_history columns ────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'crm.trip_stage_history'::regclass AND conname = 'trip_stage_history_tenant_id_uq') THEN
        ALTER TABLE crm.trip_stage_history ADD CONSTRAINT trip_stage_history_tenant_id_uq UNIQUE (tenant_id, history_id);
    END IF;
END $$;
ALTER TABLE crm.trip_stage_history ADD COLUMN IF NOT EXISTS override_reason_code TEXT;
ALTER TABLE crm.trip_stage_history ADD COLUMN IF NOT EXISTS undo_of UUID;
ALTER TABLE crm.trip_stage_history ADD COLUMN IF NOT EXISTS batch_id UUID;
ALTER TABLE crm.trip_stage_history DROP CONSTRAINT IF EXISTS trip_stage_history_override_chk;
ALTER TABLE crm.trip_stage_history ADD CONSTRAINT trip_stage_history_override_chk CHECK (
    override = (override_reason_code IS NOT NULL)
    AND (override_reason_code IS NULL OR override_reason_code IN (
        'client_in_hurry', 'repeat_client', 'info_by_phone', 'manual_booking', 'manual_stage3', 'other'
    ))
);
ALTER TABLE crm.trip_stage_history DROP CONSTRAINT IF EXISTS trip_stage_history_undo_chk;
ALTER TABLE crm.trip_stage_history ADD CONSTRAINT trip_stage_history_undo_chk CHECK (
    (undo_of IS NULL OR (reason_code = 'undo' AND undo_of <> history_id AND override_reason_code IS NULL))
);
ALTER TABLE crm.trip_stage_history DROP CONSTRAINT IF EXISTS trip_stage_history_undo_fk;
ALTER TABLE crm.trip_stage_history ADD CONSTRAINT trip_stage_history_undo_fk FOREIGN KEY (tenant_id, undo_of)
    REFERENCES crm.trip_stage_history (tenant_id, history_id);
CREATE INDEX IF NOT EXISTS trip_stage_history_batch_idx ON crm.trip_stage_history (tenant_id, batch_id)
    WHERE batch_id IS NOT NULL;
COMMENT ON COLUMN crm.trip_stage_history.override_reason_code IS 'AA-943 (crm-012): the logged reason a gate was overridden (Stage 2 < 80 %, or the manual booking / Stage 3 gates until CRM-18 / CRM-25); override = true exactly when set';
COMMENT ON COLUMN crm.trip_stage_history.undo_of IS 'AA-943 (crm-012, Fix B8): the move this row takes back (reason_code undo), same trip';
COMMENT ON COLUMN crm.trip_stage_history.batch_id IS 'AA-943 (crm-012): one random id shared by the rows of one bulk move (its batch undo)';

CREATE OR REPLACE FUNCTION crm.pin_stage_history_insert() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    -- The undo rule (crm.enforce_stage_transition) reads at and created_by: crm_app writes neither itself.
    IF current_user <> 'crm_owner' THEN
        NEW.at := now();
        NEW.created_at := now();
        NEW.created_by := COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text);
    END IF;
    IF NEW.undo_of IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM crm.trip_stage_history h WHERE h.history_id = NEW.undo_of AND h.trip_id = NEW.trip_id
    ) THEN
        RAISE EXCEPTION 'crm: undo_not_allowed (undo_of names no move of this trip)' USING ERRCODE = 'CRM20';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.pin_stage_history_insert() FROM PUBLIC;
CREATE OR REPLACE TRIGGER trip_stage_history_pin_insert
    BEFORE INSERT ON crm.trip_stage_history
    FOR EACH ROW EXECUTE FUNCTION crm.pin_stage_history_insert();

-- ── 2. The stage trigger function (gates + undo) ─────────────────────────────────────────────────
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

    -- 2a. Gates (the API answers 409 first; this is the database's own check).
    IF TG_TABLE_NAME = 'trip' THEN
        v_gate := CASE
            WHEN OLD.stage = 'qualifying' AND NEW.stage = 'proposal' THEN 'stage2'
            WHEN OLD.stage = 'proposal' AND NEW.stage = 'booked' THEN 'booking'
            WHEN OLD.stage = 'booked' AND NEW.stage = 'pre_departure' THEN 'stage3'
        END;
        IF v_gate = 'stage2' AND COALESCE((NEW.intake_completeness ->> 's2')::int, 0) >= 80 THEN
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
COMMENT ON FUNCTION crm.enforce_stage_transition() IS 'AA-936 (crm-005), replaced by AA-943 (crm-012): a stage change must be an edge in crm.status_transition; on crm.trip the gates qualifying -> proposal (s2 >= 80 or app.gate_override = stage2), proposal -> booked (app.gate_override = booking), booked -> pre_departure (app.gate_override = stage3) raise CRM19; while app.stage_undo names the trip''s latest move (<= 15 s old, same actor, not an undo, not into cancelled) only its exact reverse is allowed, anything else raises CRM20.';

-- ── 5. crm.task.priority ─────────────────────────────────────────────────────────────────────────
ALTER TABLE crm.task ADD COLUMN IF NOT EXISTS priority TEXT NOT NULL DEFAULT 'normal';
ALTER TABLE crm.task DROP CONSTRAINT IF EXISTS task_priority_chk;
ALTER TABLE crm.task ADD CONSTRAINT task_priority_chk CHECK (priority IN ('normal', 'urgent'));
COMMENT ON COLUMN crm.task.priority IS 'AA-943 (crm-012): normal | urgent (the date rule''s gate-unmet task, Fix B4)';

-- ── 6. crm.tenant_settings ───────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.call_slot_rules_ok(p jsonb) RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    w jsonb;
    k text;
    v numeric;
BEGIN
    IF p IS NULL OR jsonb_typeof(p) <> 'object' OR octet_length(p::text) > 4096 THEN
        RETURN false;
    END IF;
    IF p = '{}'::jsonb THEN
        RETURN true;  -- no call slots offered
    END IF;
    IF (p - 'windows' - 'duration_min' - 'horizon_days') <> '{}'::jsonb
       OR jsonb_typeof(p -> 'windows') IS DISTINCT FROM 'array' THEN
        RETURN false;
    END IF;
    IF jsonb_array_length(p -> 'windows') NOT BETWEEN 1 AND 21 THEN
        RETURN false;
    END IF;
    FOREACH k IN ARRAY ARRAY['duration_min', 'horizon_days'] LOOP
        IF jsonb_typeof(p -> k) IS DISTINCT FROM 'number' THEN
            RETURN false;
        END IF;
        v := (p ->> k)::numeric;
        IF v <> trunc(v) OR (k = 'duration_min' AND v NOT BETWEEN 10 AND 240)
           OR (k = 'horizon_days' AND v NOT BETWEEN 1 AND 60) THEN
            RETURN false;
        END IF;
    END LOOP;
    FOR w IN SELECT * FROM jsonb_array_elements(p -> 'windows') LOOP
        IF jsonb_typeof(w) <> 'object' OR (w - 'dow' - 'start' - 'end') <> '{}'::jsonb
           OR jsonb_typeof(w -> 'dow') IS DISTINCT FROM 'number'
           OR jsonb_typeof(w -> 'start') IS DISTINCT FROM 'string'
           OR jsonb_typeof(w -> 'end') IS DISTINCT FROM 'string' THEN
            RETURN false;
        END IF;
        v := (w ->> 'dow')::numeric;
        IF v <> trunc(v) OR v NOT BETWEEN 1 AND 7
           OR (w ->> 'start') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
           OR (w ->> 'end') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
           OR (w ->> 'start') >= (w ->> 'end') THEN
            RETURN false;
        END IF;
    END LOOP;
    RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION crm.call_slot_rules_ok(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.call_slot_rules_ok(jsonb) TO crm_app;
COMMENT ON FUNCTION crm.call_slot_rules_ok(jsonb) IS 'AA-943 (crm-012, R15): the shape of crm.tenant_settings.call_slot_rules: {} (no slots), or {windows: [{dow 1-7 (ISO, Monday = 1), start HH:MM, end HH:MM, start < end}] (1-21), duration_min 10-240, horizon_days 1-60}, at most 4 KiB. Times are in the agency timezone.';

ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS timezone TEXT NOT NULL DEFAULT 'Asia/Ho_Chi_Minh';
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS stage2_auto_send BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS call_slot_rules JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_timezone_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_timezone_chk CHECK (
    length(timezone) <= 64 AND timezone ~ '^(UTC|[A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+){1,2})$'
);
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_call_slot_rules_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_call_slot_rules_chk
    CHECK (crm.call_slot_rules_ok(call_slot_rules));
COMMENT ON COLUMN crm.tenant_settings.timezone IS 'AA-943 (crm-012): the agency''s IANA timezone: "today" of the date rule, call-slot windows. The API checks it against pg_timezone_names; the database checks the shape';
COMMENT ON COLUMN crm.tenant_settings.stage2_auto_send IS 'AA-943 (crm-012): send the Stage 2 planning form automatically when a trip moves to Qualifying (default off)';
COMMENT ON COLUMN crm.tenant_settings.call_slot_rules IS 'AA-943 (crm-012, R15): the call slots the inquiry form offers (crm.call_slot_rules_ok); {} = none';

-- ── 10. Same-agency keys the new references need ─────────────────────────────────────────────────
DO $$
DECLARE
    spec text[];
BEGIN
    FOREACH spec SLICE 1 IN ARRAY ARRAY[
        ARRAY['dispatch_queue', 'dispatch_queue_tenant_id_uq', 'dispatch_id'],
        ARRAY['form_submission', 'form_submission_tenant_id_uq', 'submission_id']
    ] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                        WHERE conrelid = format('crm.%I', spec[1])::regclass AND conname = spec[2]) THEN
            EXECUTE format('ALTER TABLE crm.%I ADD CONSTRAINT %I UNIQUE (tenant_id, %I)', spec[1], spec[2], spec[3]);
        END IF;
    END LOOP;
END $$;

-- ── 7. crm.client_link ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.client_link (
    link_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                    REFERENCES crm.tenant (tenant_id),
    trip_id         UUID NOT NULL,
    traveler_id     UUID,
    purpose         TEXT NOT NULL,
    token_hash      BYTEA NOT NULL,
    status          TEXT NOT NULL DEFAULT 'sent',
    expires_at      TIMESTAMPTZ NOT NULL,
    first_opened_at TIMESTAMPTZ,
    submitted_at    TIMESTAMPTZ,
    revoked_at      TIMESTAMPTZ,
    reissued_from   UUID,
    dispatch_id     UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ,
    deleted_by      TEXT,
    purge_after     TIMESTAMPTZ,
    CONSTRAINT client_link_token_uq UNIQUE (token_hash),
    CONSTRAINT client_link_tenant_id_uq UNIQUE (tenant_id, link_id),
    -- the target of form_submission_client_link_fk: a submission through a link carries the link's trip and traveller
    CONSTRAINT client_link_subject_uq UNIQUE (tenant_id, link_id, trip_id, traveler_id),
    CONSTRAINT client_link_trip_fk FOREIGN KEY (tenant_id, trip_id) REFERENCES crm.trip (tenant_id, trip_id),
    CONSTRAINT client_link_traveler_fk FOREIGN KEY (tenant_id, traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id),
    CONSTRAINT client_link_reissued_fk FOREIGN KEY (tenant_id, reissued_from)
        REFERENCES crm.client_link (tenant_id, link_id) ON DELETE SET NULL (reissued_from),
    CONSTRAINT client_link_dispatch_fk FOREIGN KEY (tenant_id, dispatch_id)
        REFERENCES crm.dispatch_queue (tenant_id, dispatch_id) ON DELETE SET NULL (dispatch_id),
    CONSTRAINT client_link_purpose_chk CHECK (
        purpose IN ('stage2_form') AND (purpose <> 'stage2_form' OR traveler_id IS NOT NULL)
    ),
    CONSTRAINT client_link_token_chk CHECK (octet_length(token_hash) = 32),
    CONSTRAINT client_link_status_chk CHECK (status IN ('sent', 'opened', 'submitted', 'expired', 'revoked')),
    CONSTRAINT client_link_expiry_chk CHECK (
        expires_at > created_at AND expires_at <= created_at + interval '30 days'
    ),
    CONSTRAINT client_link_dates_chk CHECK (
        (status <> 'opened' OR first_opened_at IS NOT NULL)
        AND (status <> 'submitted' OR submitted_at IS NOT NULL)
        AND (status = 'revoked') = (revoked_at IS NOT NULL)
        AND (reissued_from IS NULL OR reissued_from <> link_id)
    ),
    CONSTRAINT client_link_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS client_link_trip_idx ON crm.client_link (tenant_id, trip_id);
CREATE INDEX IF NOT EXISTS client_link_traveler_idx ON crm.client_link (traveler_id) WHERE traveler_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS client_link_dispatch_idx ON crm.client_link (tenant_id, dispatch_id) WHERE dispatch_id IS NOT NULL;
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('client_link', 'sent', 'opened'),
    ('client_link', 'sent', 'submitted'),
    ('client_link', 'opened', 'submitted'),
    ('client_link', 'sent', 'expired'),
    ('client_link', 'opened', 'expired'),
    ('client_link', 'submitted', 'expired'),
    ('client_link', 'sent', 'revoked'),
    ('client_link', 'opened', 'revoked'),
    ('client_link', 'submitted', 'revoked')
ON CONFLICT DO NOTHING;
REVOKE DELETE, TRUNCATE ON crm.client_link FROM crm_app;
COMMENT ON TABLE crm.client_link IS 'AA-943 (crm-012; design v3 group E, Fix B11): a signed link to a client page on the client host (purpose stage2_form = the Stage 2 planning form C-02; later cards add purposes). Only the SHA-256 of the random token is stored; the token stays valid until expires_at (a second device or the spouse still gets in) unless revoked. client_link_token_lookup finds one live row by its hash (app.tenancy.client_link_tx). crm_app never deletes a link; erasure through crm.erase_subject.';
COMMENT ON COLUMN crm.client_link.token_hash IS 'conf:credential; SHA-256 of the link token (never the token)';
COMMENT ON COLUMN crm.client_link.dispatch_id IS 'the crm.dispatch_queue row that carried the link (NULL once that row is erased, or when the agent copied the link)';

DROP POLICY IF EXISTS client_link_token_lookup ON crm.client_link;
CREATE POLICY client_link_token_lookup ON crm.client_link
    FOR SELECT TO crm_app
    USING (
        token_hash = decode(NULLIF(current_setting('app.client_link_hash', true), ''), 'hex')
        AND status IN ('sent', 'opened', 'submitted')
        AND expires_at > now()
        AND deleted_at IS NULL
    );
COMMENT ON POLICY client_link_token_lookup ON crm.client_link IS 'AA-943 (crm-012): the one live link (not expired, revoked or trashed) whose token hash the public client route was called with, only while app.client_link_hash is set (app.tenancy.client_link_tx). SELECT only; same pattern as invitation_token_lookup (crm-008).';

-- ── 8. crm.meeting_slot ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.meeting_slot (
    slot_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    trip_id            UUID,
    traveler_id        UUID,
    starts_at          TIMESTAMPTZ NOT NULL,
    duration_min       SMALLINT NOT NULL,
    status             TEXT NOT NULL DEFAULT 'requested',
    source             TEXT NOT NULL,
    form_submission_id UUID,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,
    deleted_by         TEXT,
    purge_after        TIMESTAMPTZ,
    CONSTRAINT meeting_slot_trip_fk FOREIGN KEY (tenant_id, trip_id) REFERENCES crm.trip (tenant_id, trip_id),
    CONSTRAINT meeting_slot_traveler_fk FOREIGN KEY (tenant_id, traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id),
    CONSTRAINT meeting_slot_submission_fk FOREIGN KEY (tenant_id, form_submission_id)
        REFERENCES crm.form_submission (tenant_id, submission_id),
    CONSTRAINT meeting_slot_subject_chk CHECK (trip_id IS NOT NULL OR traveler_id IS NOT NULL),
    CONSTRAINT meeting_slot_duration_chk CHECK (duration_min BETWEEN 10 AND 240),
    CONSTRAINT meeting_slot_status_chk CHECK (status IN ('requested', 'confirmed', 'cancelled', 'done')),
    CONSTRAINT meeting_slot_source_chk CHECK (
        source IN ('form', 'agent') AND (source = 'form') = (form_submission_id IS NOT NULL)
    ),
    CONSTRAINT meeting_slot_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
-- One live call per agency start time: two inquiries that pick the same slot -> the second one gets a task instead.
CREATE UNIQUE INDEX IF NOT EXISTS meeting_slot_live_start_uq ON crm.meeting_slot (tenant_id, starts_at)
    WHERE status IN ('requested', 'confirmed') AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS meeting_slot_trip_idx ON crm.meeting_slot (tenant_id, trip_id) WHERE trip_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS meeting_slot_traveler_idx ON crm.meeting_slot (traveler_id) WHERE traveler_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS meeting_slot_submission_idx ON crm.meeting_slot (tenant_id, form_submission_id)
    WHERE form_submission_id IS NOT NULL;
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('meeting_slot', 'requested', 'confirmed'),
    ('meeting_slot', 'requested', 'cancelled'),
    ('meeting_slot', 'confirmed', 'cancelled'),
    ('meeting_slot', 'confirmed', 'done')
ON CONFLICT DO NOTHING;
REVOKE DELETE, TRUNCATE ON crm.meeting_slot FROM crm_app;
COMMENT ON TABLE crm.meeting_slot IS 'AA-943 (crm-012, R15): a call slot of the agency (C-01 slot picker or an agent), for a trip and / or a traveller: starts_at (UTC), duration_min, requested -> confirmed -> done, or cancelled. One live slot per agency start time. Ids and times only, no PII. crm_app never deletes one; erasure through crm.erase_subject. Calendar sync: AA-961 (CRM-30).';

-- ── 9. crm.form_submission for Stage 2 / 3 ───────────────────────────────────────────────────────
ALTER TABLE crm.form_submission ALTER COLUMN intake_form_id DROP NOT NULL;
ALTER TABLE crm.form_submission ADD COLUMN IF NOT EXISTS client_link_id UUID;
ALTER TABLE crm.form_submission DROP CONSTRAINT IF EXISTS form_submission_source_chk;
ALTER TABLE crm.form_submission ADD CONSTRAINT form_submission_source_chk CHECK (
    (stage <> 's1' OR intake_form_id IS NOT NULL)
    AND (client_link_id IS NULL OR (stage <> 's1' AND trip_id IS NOT NULL AND traveler_id IS NOT NULL))
);
ALTER TABLE crm.form_submission DROP CONSTRAINT IF EXISTS form_submission_outcome_chk;
ALTER TABLE crm.form_submission ADD CONSTRAINT form_submission_outcome_chk CHECK (
    (status = 'processed') = (outcome IS NOT NULL)
    AND (outcome IS NULL OR outcome IN ('created', 'attached', 'applied'))
);
ALTER TABLE crm.form_submission DROP CONSTRAINT IF EXISTS form_submission_client_link_fk;
ALTER TABLE crm.form_submission ADD CONSTRAINT form_submission_client_link_fk
    FOREIGN KEY (tenant_id, client_link_id, trip_id, traveler_id)
    REFERENCES crm.client_link (tenant_id, link_id, trip_id, traveler_id);
CREATE INDEX IF NOT EXISTS form_submission_client_link_idx ON crm.form_submission (tenant_id, client_link_id)
    WHERE client_link_id IS NOT NULL;
COMMENT ON COLUMN crm.form_submission.intake_form_id IS 'the public form a Stage 1 inquiry came through (required for stage s1; a Stage 2 / 3 answer set comes through a client_link or is filled in by a member)';
COMMENT ON COLUMN crm.form_submission.client_link_id IS 'AA-943 (crm-012): the signed link a Stage 2 / 3 answer set came through; same trip and traveller as the link (form_submission_client_link_fk)';

-- ── RLS + triggers on the new tenant tables ──────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['client_link', 'meeting_slot'] LOOP
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
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE OF status ON crm.%I '
            'FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition()', t || '_status_transition', t);
        -- 11c. Hold rule 4h: a held link or slot keeps its trip and traveller.
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON crm.%I', t || '_hold_guard', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE DELETE OR UPDATE ON crm.%I FOR EACH ROW '
                       'EXECUTE FUNCTION crm.guard_held_change(''trip_id'', ''traveler_id'')', t || '_hold_guard', t);
    END LOOP;
END $$;

-- ── 11a. crm.erase_held (crm-010 hold rule 4e) with the new tables ───────────────────────────────
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
        -- client_link, meeting_slot, form_submission (trip_id := NULL) and the trip: all carry trip_id = the trip (4d
        -- through hold_trip), and these name a traveller too.
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
                    SELECT m.traveler_id FROM crm.meeting_slot m WHERE m.trip_id = p_subject) x
             WHERE x.traveler_id IS NOT NULL AND crm.hold_traveler(x.traveler_id));
    ELSIF p_scope = 'traveler' THEN
        -- dispatch_queue, traveler_health, document, note, trip_traveler, consent, form_submission, client_link and the
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
    END IF;
    RETURN crm.hold_row(NULL, NULL);  -- subject-less data (llm_call, placeholder_map): the agency hold only
END;
$$;
REVOKE ALL ON FUNCTION crm.erase_held(text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.erase_held(text, uuid, uuid) TO crm_app;
COMMENT ON FUNCTION crm.erase_held(text, uuid, uuid) IS 'AA-942 (crm-010, hold rule 4e), extended by AA-943 (crm-012) to client_link and meeting_slot: true when crm.erase_subject(scope, subject, token) would delete or update a held row (every step''s rows, both rows of a relation, the clients a traveller referred, the submissions a trip unlinks, the call slots a traveller''s submissions booked); scope tenant: any active hold of the agency. crm.erase_subject refuses with CRM10 on it, dry run too. Invoker rights.';

-- ── 11b. crm.erase_subject with the new tables ───────────────────────────────────────────────────
-- The crm-010 text with three changes (file header 11b); later keys (crm-014, crm-015) start from THIS text.
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
    IF p_scope NOT IN ('trip', 'traveler', 'task', 'note', 'document', 'relation', 'tenant') THEN
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
    ELSIF p_scope = 'tenant' AND NOT p_dry_run AND v_status <> 'offboarding' THEN
        -- A dry run (the counts the owner sees before confirming) works on an active agency.
        RAISE EXCEPTION 'crm: tenant_not_offboarding (status %)', v_status USING ERRCODE = 'CRM14';
    END IF;

    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', 'on', true);
    END IF;

    IF p_scope = 'trip' THEN
        -- crm-012: the trip's submissions let go of the trip and of its links first, then the links and slots go.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['form_submission', 'trip_id = $1', 'trip_id = NULL, client_link_id = NULL'],
            ['client_link', 'trip_id = $1', ''],
            ['meeting_slot', 'trip_id = $1', ''],
            ['dispatch_queue', 'trip_id = $1', ''],
            ['trip_commitment', 'trip_id = $1', ''],
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
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['meeting_slot', 'traveler_id = $1 OR form_submission_id IN (SELECT s.submission_id '
                             'FROM crm.form_submission s WHERE s.traveler_id = $1)', ''],
            ['dispatch_queue', 'traveler_id = $1', ''],
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
    ELSE
        -- The whole agency. Memberships are deleted as a platform action (crm-008 guard_member_write lets only an
        -- unscoped or platform context delete a member); the caller's actor is restored afterwards.
        PERFORM set_config('app.actor', 'platform:crm_offboarding', true);
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['dispatch_queue', ''], ['trip_commitment', ''], ['document', ''], ['traveler_health', ''],
            ['note', ''], ['task', ''], ['trip_stage_history', ''], ['trip_party', ''], ['trip_traveler', ''],
            ['traveler_relation', ''], ['consent', ''], ['meeting_slot', ''], ['form_submission', ''],
            ['client_link', ''], ['profile_history', ''],
            ['traveler_profile', ''], ['placeholder_map', 'optional'], ['llm_call', ''], ['trip', ''],
            ['traveler', 'unlink'], ['traveler', ''], ['intake_form', ''], ['form_definition', ''],
            ['integration_credential', ''], ['tenant_settings', ''], ['member_invitation', 'optional'],
            ['owner_recovery_request', 'optional'], ['tenant_entitlement', 'optional'], ['member', '']
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
COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot: the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
BEGIN
    FOREACH t IN ARRAY ARRAY['crm.client_link', 'crm.meeting_slot'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = t::regclass) THEN
            RAISE EXCEPTION 'crm-012: % must have ENABLE + FORCE row level security', t;
        END IF;
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, t, p) THEN
                    RAISE EXCEPTION 'crm-012: reader % may % on %', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
        IF pg_catalog.has_table_privilege('crm_app', t, 'DELETE') OR pg_catalog.has_table_privilege('crm_app', t, 'TRUNCATE')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'UPDATE') THEN
            RAISE EXCEPTION 'crm-012: crm_app must update and never delete %', t;
        END IF;
    END LOOP;
    IF (SELECT polcmd FROM pg_catalog.pg_policy WHERE polrelid = 'crm.client_link'::regclass
         AND polname = 'client_link_token_lookup') IS DISTINCT FROM 'r' THEN
        RAISE EXCEPTION 'crm-012: client_link_token_lookup must be FOR SELECT';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-012: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-012: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.enforce_stage_transition()', 'crm.pin_stage_history_insert()',
                             'crm.completeness_ok(jsonb)', 'crm.call_slot_rules_ok(jsonb)',
                             'crm.erase_held(text,uuid,uuid)', 'crm.erase_subject(text,uuid,uuid,boolean)'] LOOP
        IF pg_catalog.has_function_privilege('public', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-012: % is executable by PUBLIC (SEC-4)', t;
        END IF;
    END LOOP;
    -- trip_stage_history stays append-only for crm_app (crm-010 erasable trigger).
    IF pg_catalog.has_table_privilege('crm_app', 'crm.trip_stage_history', 'UPDATE')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.trip_stage_history', 'DELETE') THEN
        RAISE EXCEPTION 'crm-012: crm.trip_stage_history is append-only but crm_app may change it';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-012', now(), 'AA-943: CRM-15 modules 1 + 2 (all trip stage edges, Proposal / booking / Stage 3 gates, undo, cancel reason, completeness, last activity, task priority, tenant timezone / Stage 2 auto-send / call slots, client_link, meeting_slot, Stage 2 submissions, erase_subject + hold rule for the new tables)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
