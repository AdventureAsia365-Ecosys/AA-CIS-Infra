-- Migration crm-038: AA-959 CRM-29a Module 10 workflow engine + tasks (design v3 M10, §2.2 A-09 / A-17, WF-10, R2, R9,
-- R20, R44 step 1, Fix B8, Fix C3; data-privacy-integrations §2.5 `task` columns and §2.9 group H; BYO errata S247
-- §1 "CRM-29a workflows": nudges to travellers go from the agency's mailbox, held while it is disconnected) — the
-- agency's workflow rules, one run per rule and subject, and the task columns the Tasks page and the engine need.
--
-- Owner: AA-Partner (api/migrations/038_crm_workflows_tasks.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Sync bot, Migration Copy Guard). Key crm-038, after crm-037 (AA-964); if main moves,
-- renumber: file name, this header, Guard 0, the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS.
--
-- What (DM-7.1: crm.workflow_rule and crm.workflow_run already have their rows in root data standards Part B §7, the
-- agency-configuration row and the trip row; no root PR is needed for this file):
--   1. crm.workflow_rule (base template): one automation of the agency (A-17). name (agency text, no client data by
--      design: a rule runs for many trips), template_key / template_version (the AA library template it was installed
--      from, app/workflows/library.py; NULL = built from scratch), the trigger (trigger_kind stage_enter | event |
--      date_anchor | special_date | manual, trigger_value: the stage, the event name, the date anchor or the special
--      date; NULL for manual = a task list an agent applies by hand, R9), trigger_offset_days (date and special-date
--      triggers: days from the anchor, -400..400), conditions (a JSON object of codes the API validates: stages,
--      trip styles, lead sources, party with children, AA lines, Stage 3 incomplete; the tags seam of CRM-29b),
--      steps (a JSON array of 1..20 actions: create_task, send_email, send_text, set_field, wait), status
--      active | paused | archived, version (+1 on every edit; a run keeps the version it started on). One live rule
--      per library template (partial unique index). crm_app has no DELETE: a rule is archived; the agency erase
--      deletes it.
--   2. crm.workflow_run (base template): one run of one rule for one subject, the trip (stage, event, date triggers,
--      manual apply) or the client (special dates: birthday, passport expiry, trip anniversary) — exactly one of
--      trip_id / traveler_id. trigger_key is the run's idempotency key and always names its subject (stage:<history
--      id>, event:<event id>, date:<trip id>:<anchor>:<offset>:<anchor date>, special:<code>:<client or trip id>:<date>,
--      manual:<id>:<trip id>): UNIQUE (tenant, rule, trigger_key), so a tick that runs twice starts nothing twice
--      (card E) and two trips or clients on one date each get their run. status active -> completed | stopped | failed;
--      step_index (the next step), next_at (when the next step is due: a run started by a member's action waits the
--      Undo window first, Fix B8; a wait step sets it later), stop_reason (a code: trip_cancelled, trip_lost,
--      trip_trashed, archived, undone, stopped_by_member, rule_archived ...), log (a JSON array of the steps done:
--      step, action, outcome code, ids; never a name, an address or a text; at most 16 kB). Stopped by the trip cancel
--      (app.cancellation CANCEL_HOOKS, Fix C3) and by Undo of the stage move that started it. Hold guard on trip_id /
--      traveler_id; crm_app has no DELETE (the erase only).
--   3. crm.task: traveler_id (a client task with no trip: special dates; a task names a trip or a client, never both,
--      so the hold rule of crm.erase_held needs no new branch), title_enc (the title of a custom task: a member's own
--      task or a workflow's "create task" step; vault DEK, pii:free_text; present exactly for the kind family
--      custom_<hex>, whose suffix keeps crm-005's "one open task per (trip, kind)" for every other kind, R20),
--      workflow_run_id (the run that opened it). The crm-005 hold guard trigger is re-created to guard traveler_id too.
--   4. crm.tenant_settings.task_digest (default false): the morning digest of open tasks to each member, counts only
--      (no client data, AA system mail, errata S247 §3 item 3); the owner switches it on.
--   5. crm.erase_subject: the crm-033 text, plus: trip scope crm.workflow_run after crm.task; traveller scope
--      crm.task and crm.workflow_run of the client; agency scope crm.workflow_run then crm.workflow_rule after
--      crm.task. Nothing else changes.
--   6. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles) on both new tables; no reader grant (the AI, insights
--      and support readers never see a rule or a run).
--
-- Class: contract (root ADR 0017 d3): new columns, a CHECK and a re-created trigger on an existing table (crm.task),
-- a new column on crm.tenant_settings, rows in crm.status_transition, a replaced function. So no migrate directive:
-- MIG-4 order, this migration-only PR first, the Infra copy (Migration Sync bot), a manual DB Migrate apply, the
-- bot/db-schema-reference PR, then the AA-959 code PR (adds crm-038 to REQUIRED_SCHEMA_VERSIONS). The code before it
-- never names the new objects; every existing task row has a kind outside custom_* and no title, so the new CHECK
-- holds and the old INSERTs (no title, no traveller, no run) keep working.
--
-- Order: after crm-036 (AA-958). Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.
-- Idempotent (IF NOT EXISTS, DROP … IF EXISTS before each ADD / CREATE, ON CONFLICT DO NOTHING, CREATE OR REPLACE).
-- Rollback: a forward crm- file (MIG-14) after the AA-959 code is reverted: crm.erase_subject back to the crm-033
-- text, ALTER TABLE crm.task DROP COLUMN workflow_run_id, title_enc, traveler_id (custom tasks first moved to the
-- trash and purged), DROP TABLE crm.workflow_run, crm.workflow_rule, the status_transition rows,
-- ALTER TABLE crm.tenant_settings DROP COLUMN task_digest.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ── Guard 0: runs as the owner, after crm-036 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-038: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-036') THEN
        RAISE EXCEPTION 'crm-038: crm-036 (AA-958 messaging) lands first';
    END IF;
    IF to_regprocedure('crm.erase_subject(text,uuid,uuid,boolean)') IS NULL
       OR to_regclass('crm.support_session') IS NULL
       OR to_regclass('crm.task') IS NULL
       OR to_regprocedure('crm.guard_held_change()') IS NULL THEN
        RAISE EXCEPTION 'crm-038: crm.erase_subject (crm-033), crm.support_session, crm.task or crm.guard_held_change missing';
    END IF;
END $$;

-- ── 1. crm.workflow_rule ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.workflow_rule (
    workflow_rule_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                        REFERENCES crm.tenant (tenant_id),
    name                TEXT NOT NULL,
    template_key        TEXT,
    template_version    SMALLINT,
    trigger_kind        TEXT NOT NULL,
    trigger_value       TEXT,
    trigger_offset_days SMALLINT NOT NULL DEFAULT 0,
    conditions          JSONB NOT NULL DEFAULT '{}'::jsonb,
    steps               JSONB NOT NULL,
    status              TEXT NOT NULL DEFAULT 'active',
    version             INTEGER NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    deleted_by          TEXT,
    purge_after         TIMESTAMPTZ,
    CONSTRAINT workflow_rule_tenant_id_uq UNIQUE (tenant_id, workflow_rule_id),
    CONSTRAINT workflow_rule_name_chk CHECK (
        length(name) BETWEEN 1 AND 120 AND name = btrim(name) AND name !~ '[[:cntrl:]]'),
    CONSTRAINT workflow_rule_template_chk CHECK (
        (template_key IS NULL) = (template_version IS NULL)
        AND (template_key IS NULL OR template_key ~ '^[a-z][a-z0-9_]{1,40}$')
        AND (template_version IS NULL OR template_version BETWEEN 1 AND 999)),
    CONSTRAINT workflow_rule_trigger_chk CHECK (
        trigger_kind IN ('stage_enter', 'event', 'date_anchor', 'special_date', 'manual')
        AND (trigger_kind = 'manual') = (trigger_value IS NULL)
        AND (trigger_value IS NULL OR trigger_value ~ '^[a-z][a-z0-9_]{0,30}(\.[a-z][a-z0-9_]{0,30})?$')
        AND trigger_offset_days BETWEEN -400 AND 400
        AND (trigger_kind IN ('date_anchor', 'special_date') OR trigger_offset_days = 0)),
    CONSTRAINT workflow_rule_conditions_chk CHECK (
        jsonb_typeof(conditions) = 'object' AND octet_length(conditions::text) <= 4000),
    CONSTRAINT workflow_rule_steps_chk CHECK (
        jsonb_typeof(steps) = 'array' AND jsonb_array_length(steps) BETWEEN 1 AND 20
        AND octet_length(steps::text) <= 16000),
    CONSTRAINT workflow_rule_status_chk CHECK (status IN ('active', 'paused', 'archived')),
    CONSTRAINT workflow_rule_version_chk CHECK (version >= 1),
    CONSTRAINT workflow_rule_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS workflow_rule_template_uq ON crm.workflow_rule (tenant_id, template_key)
    WHERE template_key IS NOT NULL AND status <> 'archived' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS workflow_rule_trigger_idx ON crm.workflow_rule (tenant_id, trigger_kind, trigger_value)
    WHERE status = 'active' AND deleted_at IS NULL;

ALTER TABLE crm.workflow_rule ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.workflow_rule FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.workflow_rule;
CREATE POLICY tenant_isolation ON crm.workflow_rule
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE OR REPLACE TRIGGER workflow_rule_set_updated_at
    BEFORE UPDATE ON crm.workflow_rule
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('workflow_rule', 'active', 'paused'),
    ('workflow_rule', 'paused', 'active'),
    ('workflow_rule', 'active', 'archived'),
    ('workflow_rule', 'paused', 'archived')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER workflow_rule_status_transition
    BEFORE UPDATE OF status ON crm.workflow_rule
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();
REVOKE DELETE, TRUNCATE ON crm.workflow_rule FROM crm_app;

COMMENT ON TABLE crm.workflow_rule IS 'AA-959 (crm-038, design v3 M10, A-17): one automation of the agency: a trigger (stage entered, a trip event, a date of the trip, a special date of a client, or manual = a task list applied by hand, R9), conditions (codes) and 1..20 steps (create_task, send_email, send_text, set_field, wait), validated by app/workflows/model.py. name and the step titles are agency text, no client data by design. status active | paused | archived (no DELETE for crm_app; the agency erase deletes rules). version +1 per edit.';
COMMENT ON COLUMN crm.workflow_rule.template_key IS 'AA-959 (crm-038): the AA library template the rule was installed from (app/workflows/library.py), with template_version; NULL = built by the agency. One live rule per template.';
COMMENT ON COLUMN crm.workflow_rule.trigger_value IS 'AA-959 (crm-038): stage_enter: the stage; event: the trip event name (crm.metric_event names, message.received / message.sent); date_anchor: departure | return | stage_entered | last_activity | hold_expiry; special_date: birthday | passport_expiry | trip_anniversary; NULL for manual.';
COMMENT ON COLUMN crm.workflow_rule.steps IS 'AA-959 (crm-038): the ordered actions, ids and codes plus the agency''s own task titles (no client data by design).';

-- ── 2. crm.workflow_run ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.workflow_run (
    workflow_run_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    workflow_rule_id UUID NOT NULL,
    rule_version     INTEGER NOT NULL,
    trip_id          UUID REFERENCES crm.trip (trip_id),
    traveler_id      UUID REFERENCES crm.traveler (traveler_id),
    trigger_key      TEXT NOT NULL,
    status           TEXT NOT NULL DEFAULT 'active',
    step_index       SMALLINT NOT NULL DEFAULT 0,
    next_at          TIMESTAMPTZ,
    stop_reason      TEXT,
    log              JSONB NOT NULL DEFAULT '[]'::jsonb,
    finished_at      TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT workflow_run_tenant_id_uq UNIQUE (tenant_id, workflow_run_id),
    CONSTRAINT workflow_run_rule_fk FOREIGN KEY (tenant_id, workflow_rule_id)
        REFERENCES crm.workflow_rule (tenant_id, workflow_rule_id),
    CONSTRAINT workflow_run_trigger_uq UNIQUE (tenant_id, workflow_rule_id, trigger_key),
    CONSTRAINT workflow_run_subject_chk CHECK (num_nonnulls(trip_id, traveler_id) = 1),
    CONSTRAINT workflow_run_trigger_key_chk CHECK (trigger_key ~ '^[a-z][a-z0-9_]{0,20}:[A-Za-z0-9_.:-]{1,120}$'),
    CONSTRAINT workflow_run_status_chk CHECK (status IN ('active', 'completed', 'stopped', 'failed')),
    CONSTRAINT workflow_run_state_chk CHECK (
        (status = 'active') = (finished_at IS NULL) AND (status = 'active') = (next_at IS NOT NULL)
        AND step_index BETWEEN 0 AND 20 AND rule_version >= 1),
    CONSTRAINT workflow_run_stop_chk CHECK (
        (stop_reason IS NULL) = (status IN ('active', 'completed'))
        AND (stop_reason IS NULL OR stop_reason ~ '^[a-z][a-z0-9_]{1,40}$')),
    CONSTRAINT workflow_run_log_chk CHECK (jsonb_typeof(log) = 'array' AND octet_length(log::text) <= 16000),
    CONSTRAINT workflow_run_never_trashed_chk CHECK (deleted_at IS NULL),
    CONSTRAINT workflow_run_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS workflow_run_due_idx ON crm.workflow_run (tenant_id, next_at) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS workflow_run_trip_idx ON crm.workflow_run (trip_id) WHERE trip_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS workflow_run_traveler_idx ON crm.workflow_run (traveler_id) WHERE traveler_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS workflow_run_rule_idx ON crm.workflow_run (tenant_id, workflow_rule_id, status);

ALTER TABLE crm.workflow_run ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.workflow_run FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.workflow_run;
CREATE POLICY tenant_isolation ON crm.workflow_run
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE OR REPLACE TRIGGER workflow_run_set_updated_at
    BEFORE UPDATE ON crm.workflow_run
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('workflow_run', 'active', 'completed'),
    ('workflow_run', 'active', 'stopped'),
    ('workflow_run', 'active', 'failed')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER workflow_run_status_transition
    BEFORE UPDATE OF status ON crm.workflow_run
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();
CREATE OR REPLACE TRIGGER workflow_run_hold_guard
    BEFORE DELETE OR UPDATE ON crm.workflow_run
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_change('trip_id', 'traveler_id');
REVOKE DELETE, TRUNCATE ON crm.workflow_run FROM crm_app;

COMMENT ON TABLE crm.workflow_run IS 'AA-959 (crm-038, design v3 M10, R30 seam): one run of one workflow rule for one trip or one client. trigger_key = the idempotency key (UNIQUE per rule): a tick that runs twice starts nothing twice. status active -> completed | stopped | failed; step_index / next_at = the next step and when it is due (a run a member''s action started waits the Undo window, Fix B8); stop_reason a code (trip_cancelled, undone, archived, ...); log = the steps done as codes and ids only. Stopped by the trip cancel (Fix C3). No DELETE for crm_app: crm.erase_subject only.';
COMMENT ON COLUMN crm.workflow_run.log IS 'AA-959 (crm-038): [{step, action, outcome, at, task_id?, message_id?}] codes and ids only, never a name, an address or a text.';
COMMENT ON COLUMN crm.workflow_run.trigger_key IS 'AA-959 (crm-038): stage:<history id> | event:<event id> | date:<trip id>:<anchor>:<offset>:<anchor date> | special:<code>:<client or trip id>:<date> | manual:<id>:<trip id>; the key always names its subject, so two trips or clients on one date never share a key.';

-- ── 3. crm.task: client tasks, custom titles, the run that opened a task ──────────────────────────
ALTER TABLE crm.task ADD COLUMN IF NOT EXISTS traveler_id UUID REFERENCES crm.traveler (traveler_id);
ALTER TABLE crm.task ADD COLUMN IF NOT EXISTS title_enc BYTEA;
ALTER TABLE crm.task ADD COLUMN IF NOT EXISTS workflow_run_id UUID REFERENCES crm.workflow_run (workflow_run_id);
ALTER TABLE crm.task DROP CONSTRAINT IF EXISTS task_subject_chk;
ALTER TABLE crm.task ADD CONSTRAINT task_subject_chk CHECK (trip_id IS NULL OR traveler_id IS NULL);
ALTER TABLE crm.task DROP CONSTRAINT IF EXISTS task_title_chk;
ALTER TABLE crm.task ADD CONSTRAINT task_title_chk CHECK (
    (kind LIKE 'custom\_%') = (title_enc IS NOT NULL) AND COALESCE(octet_length(title_enc), 30) >= 30);
CREATE INDEX IF NOT EXISTS task_traveler_idx ON crm.task (traveler_id) WHERE traveler_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS task_run_idx ON crm.task (workflow_run_id) WHERE workflow_run_id IS NOT NULL;
DROP TRIGGER IF EXISTS task_hold_guard ON crm.task;
CREATE TRIGGER task_hold_guard
    BEFORE DELETE OR UPDATE ON crm.task
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_change('trip_id', 'traveler_id');

COMMENT ON COLUMN crm.task.title_enc IS 'pii:free_text — AA-959 (crm-038): the title of a custom task (kind custom_<hex>: a member''s own task or a workflow''s create-task step), sealed under the vault DEK; NULL for every coded kind (the web words those).';
COMMENT ON COLUMN crm.task.traveler_id IS 'AA-959 (crm-038): a client task without a trip (special dates); a task names a trip or a client, never both.';
COMMENT ON COLUMN crm.task.workflow_run_id IS 'AA-959 (crm-038): the workflow run that opened the task (NULL: a member, a module rule or an AA event did).';

-- ── 4. crm.tenant_settings.task_digest ───────────────────────────────────────────────────────────
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS task_digest BOOLEAN NOT NULL DEFAULT false;
COMMENT ON COLUMN crm.tenant_settings.task_digest IS 'AA-959 (crm-038, design WF-10): the owner switched on the morning digest (each member''s open task counts, no client data, AA system mail).';

-- ── 5. crm.erase_subject: the crm-033 text + the workflow tables ──────────────────────────────────
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
    -- the lifecycle counts and the holds (ids and codes only), and (crm-026, AA-967) the portability export records
    -- and the data-request log (ids, codes, hashes and dates only; the offboarding code deletes the export objects).
    c_keep CONSTANT text[] := ARRAY['tenant', 'tenant_key', 'audit_event', 'audit_export_tenant',
                                    'audit_export_manifest', 'erasure_request', 'lifecycle_run', 'legal_hold',
                                    'export_job', 'data_request'];
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
        -- crm-024: the refund requests (they name payments) before the payments, the invoice lines and invoices after
        -- them (payments name invoices) and before the schedule rows and proposals.
        -- crm-025: the signed evidence (terms_acceptance, signature_event) has no key on the trip and stays (DM-7
        -- claim-period exception); the receipt counts it (*_kept). crm.lifecycle_purge_expired deletes it later.
        -- crm-038: the trip's workflow runs after its tasks (a task names the run that opened it).
        v_counts := jsonb_build_object(
            'terms_acceptance_kept', (SELECT count(*) FROM crm.terms_acceptance WHERE trip_id = p_subject),
            'signature_event_kept', (SELECT count(*) FROM crm.signature_event WHERE trip_id = p_subject));
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['metric_event', 'trip_id = $1', ''],
            ['signature_request', 'trip_id = $1', ''],
            ['otp_challenge', 'trip_id = $1', ''],
            ['traveler_access', 'trip_id = $1', ''],
            ['refund_request', 'trip_id = $1', ''],
            ['payment', 'trip_id = $1', ''],
            ['invoice_line', 'trip_id = $1', ''],
            ['invoice', 'trip_id = $1', ''],
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
            ['workflow_run', 'trip_id = $1', ''],
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
        -- crm-025: also the signatures they signed as a guardian (their access signed them); the signed evidence
        -- (terms_acceptance, signature_event) stays (DM-7 claim-period exception) and the receipt counts it.
        -- crm-038: the client's own tasks (special dates) and workflow runs, the tasks first.
        v_counts := jsonb_build_object(
            'terms_acceptance_kept', (SELECT count(*) FROM crm.terms_acceptance WHERE traveler_id = p_subject),
            'signature_event_kept', (SELECT count(*) FROM crm.signature_event
                                      WHERE traveler_id = p_subject OR signer_traveler_id = p_subject));
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['proposal', 'accepted_name_enc IS NOT NULL AND link_id IN (SELECT l.link_id FROM crm.client_link l '
                         'WHERE l.traveler_id = $1)', 'accepted_name_enc = NULL, accepted_name_erased_at = now()'],
            ['signature_request', 'traveler_id = $1 OR signer_traveler_id = $1', ''],
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
            ['task', 'traveler_id = $1', ''],
            ['workflow_run', 'traveler_id = $1', ''],
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
        -- crm-024: refund requests, payments, invoice lines, invoices before the schedule rows; the payment methods and
        -- the invoice number sequence with the agency's settings.
        -- crm-025: the signed evidence (terms_acceptance, signature_event) leaves with the agency, before the
        -- signatures and the agreement versions.
        -- crm-027: the AA incident flags with the Booking feed records; the calendar feeds before the members.
        -- crm-033: the support sessions, then the grants (a grant names its owner) before the members.
        -- crm-038: the workflow runs after the tasks, then the rules (a run names its rule).
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['membership_inbox', ''], ['inbox_events', ''], ['booking_feed_state', ''], ['incident_flag', ''],
            ['metric_event', ''],
            ['terms_acceptance', ''], ['signature_event', ''], ['signature_request', ''], ['otp_challenge', ''], ['traveler_access', ''],
            ['refund_request', ''], ['payment', ''], ['invoice_line', ''], ['invoice', ''],
            ['payment_schedule', ''], ['selection', ''], ['option_rule', ''], ['option', ''], ['option_block', ''],
            ['proposal_day', ''], ['prep_pack_selection', ''], ['proposal', ''], ['agreement_doc', ''],
            ['dispatch_attempt', ''], ['dispatch_queue', ''], ['message', ''], ['conversation', ''],
            ['trip_commitment', ''], ['aa_request', ''], ['booking_line_money', ''], ['booking_line', ''],
            ['agency_supplier', ''], ['document', ''], ['traveler_health', ''],
            ['note', ''], ['task', ''], ['workflow_run', ''], ['workflow_rule', ''], ['trip_stage_history', ''], ['trip_party', ''], ['trip_traveler', ''],
            ['traveler_relation', ''], ['consent', ''], ['meeting_slot', ''], ['form_submission', ''],
            ['client_link', ''], ['profile_history', ''],
            ['traveler_profile', ''], ['placeholder_map', 'optional'], ['llm_call', ''], ['trip', ''],
            ['traveler', 'unlink'], ['traveler', ''], ['intake_form', ''], ['form_definition', ''],
            ['saved_reply', ''], ['message_template', ''], ['mail_import', ''], ['ingest_address', ''], ['channel_account', ''],
            ['integration_credential', ''], ['fx_rate_override', ''], ['calendar_feed', ''],
            ['support_session', ''], ['support_grant', ''],
            ['payment_provider_account', ''], ['invoice_sequence', ''], ['tenant_settings', ''],
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

COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope), by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge), by AA-945 (crm-015) to mail (trip, traveller and agency scopes: message, conversation; agency scope: saved_reply, mail_import, ingest_address, channel_account; new scope conversation for the trash purge), by AA-946 (crm-016) to the lifecycle tables (trip and agency scopes: signature_request, otp_challenge, traveler_access, payment, payment_schedule, proposal; traveller scope: signature_request, otp_challenge, traveler_access, and the typed acceptance name of the proposals their links carried (accepted_name_enc := NULL); agency scope: agreement_doc) by AA-947 (crm-017) to the AA lines (trip, booking_line and agency scopes: aa_request; agency scope: inbox_events, booking_feed_state) by AA-949 (crm-019) to the proposal builder (trip and agency scopes: selection, option_rule, option, option_block, proposal_day) by AA-950 (crm-021) to crm.metric_event (trip and agency scopes) by AA-951 (crm-022) to crm.prep_pack_selection (trip and agency scopes) and crm.message_template (agency scope) by AA-993 G4b (crm-023) to crm.dispatch_attempt (trip, traveller and agency scopes, before crm.dispatch_queue) and by AA-952 (crm-024) to the invoices and payments (trip and agency scopes: crm.refund_request before crm.payment, crm.invoice_line and crm.invoice after it and before crm.payment_schedule; agency scope: crm.payment_provider_account, crm.invoice_sequence) and by AA-955 (crm-025) to the signed evidence (agency scope: crm.terms_acceptance, crm.signature_event; trip and traveller scopes KEEP them, DM-7 claim-period exception, and count them as terms_acceptance_kept / signature_event_kept; traveller scope also erases the signatures the traveller signed as a guardian) and by AA-967 (crm-026) to the keep list of the agency scope (crm.export_job, crm.data_request: receipts without personal data) and by AA-961 (crm-027) to the agency scope (crm.incident_flag, crm.calendar_feed) and by AA-971 (crm-033) to the agency scope (crm.support_session, then crm.support_grant) and by AA-959 (crm-038) to the workflow tables (trip scope: crm.workflow_run after crm.task; traveller scope: crm.task and crm.workflow_run of the client; agency scope: crm.workflow_run then crm.workflow_rule after crm.task): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, conversation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-038', now(), 'AA-959 CRM-29a: crm.workflow_rule (agency automations) and crm.workflow_run (one run per rule and subject, idempotent trigger key); crm.task traveler_id, title_enc (custom tasks), workflow_run_id; crm.tenant_settings.task_digest; crm.erase_subject + workflow tables')
ON CONFLICT (version) DO NOTHING;

COMMIT;
