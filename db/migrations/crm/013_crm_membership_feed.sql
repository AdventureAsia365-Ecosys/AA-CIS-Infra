-- Migration crm-013: AA-978 (partner CRM, CRM-P1) — the consumer side of the CIS membership feed
-- (tenant.membership.v1): the feed's cursor, the idempotency record of every CIS event the CRM received, and the source
-- of an agency lock, so the feed only ever undoes a lock it set itself.
--
-- Owner: AA-Partner (api/migrations/013_crm_membership_feed.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-013 (S250 schedule §1: crm-012 = AA-943, crm-014 = AA-944,
-- crm-015 = AA-945). crm.erase_subject below is the crm-012 text plus one step; crm-014 / crm-015 start from THIS text.
--
-- Why. Root contract tenant.membership.v1 (AA-978; ADR 0006b decision 4, ADR 0010 decision 5): CIS is the directory of
-- agencies and of who belongs to them, and the CRM applies a membership removal and every agency lifecycle event
-- (locked, unlocked, deleted) within 60 s. The CRM uses CIS as a revocation and lifecycle source, never as a positive
-- gate (CRM-only members have no CIS row) and never as a source of CRM roles. The issue's checks: a CIS change reaches
-- the CRM within a minute; an event that tries to grant a CRM role is refused (R); removing the last owner locks the
-- agency until the AA-941 owner recovery (E).
--
-- What:
--   1. crm.tenant.lock_source (aa_ops | cis_tenant | cis_membership; NULL while the agency is not locked): who locked
--      the agency. crm.sync_tenant_lock_source() (BEFORE INSERT OR UPDATE OF status, lock_source):
--      a. leaving locked clears it, whoever moves the status (the L1 unlock, an owner recovery, offboarding);
--      b. a lock that names no source is aa_ops: the L1 console's lock (and every lock written before this file)
--         needs no code change;
--      c. only the feed's platform actor (app.actor = 'platform:feed-tenant-membership') names a cis_* source, and only
--         a platform actor names any source explicitly (SQLSTATE CRM21 lock_source_forbidden); an unscoped session (a
--         migration, an admin session: no app.actor and not crm_app) is not restricted, as in the crm-008 guards.
--      CHECK: a source only while the status is locked. Existing locked agencies keep NULL (= an AA lock, item b's
--      reading); the feed never lifts a NULL or aa_ops lock (app.cis.membership_feed).
--   2. crm.membership_feed_state: platform singleton (no tenant column, no personal data): the feed cursor (opaque,
--      from CIS), the last successful pull, the last error class and its time, and the consecutive failure count the
--      job backs off on. One row, inserted here; crm_app reads and updates it, never inserts or deletes.
--   3. crm.membership_inbox: one row per CIS event received for an agency the CRM holds, active or locked (event_id =
--      the CIS event id, PRIMARY KEY: an event is applied at most once, a replayed page is a no-op), the agency
--      (tenant_id = the CIS tenant id, which is the CRM agency id; no foreign key: the consumer writes no row for a CIS
--      tenant without a CRM agency or for an offboarding agency, so no row outlives its agency's erase), the event
--      type (NULL only for a rejected event whose type is not one of the contract's eight), the outcome (applied |
--      ignored | rejected) and a reason code. Ids and codes only: no identity, no role, no payload. Append-only tenant
--      table (the crm-003 template: tenant_id / created_at (= received) / created_by, ENABLE + FORCE RLS, one
--      tenant_isolation policy TO the six CRM roles, crm_app INSERT + SELECT only), erasable at offboarding like
--      consent / trip_stage_history / llm_call (crm.membership_inbox_append_only, the crm.erasable_append_only rule:
--      DELETE only as crm_owner inside crm.erase_subject; its own function because crm-010's Guard 1 pins that one to
--      its three tables). DM-7 row (root data standards §7, S250): deleted 90 days after it was received (window
--      proposed, not enforced yet) and, while it carries tenant_id, with its agency at offboarding (item 4).
--   4. crm.erase_subject (the crm-012 text) + one step: the agency erase deletes the agency's membership_inbox rows
--      (FORCE RLS: crm_owner sees only app.tenant_id's rows). Without it every offboarding erase would refuse with
--      CRM16 (rows left in a tenant table outside the keep list). No other scope reaches the inbox (it names no trip or
--      traveller), so crm.erase_held, crm.guard_held_change and crm.lifecycle_purge_expired are not replaced.
--   No NOLOGIN reader gets anything on the new tables. No new status_transition row (tenant active <-> locked exists
--   since crm-002).
--
-- Order: after crm-012 (AA-943); Guard 0 refuses to run before it is registered (erase_subject must build on its text).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14). Before the AA-978
-- consumer deploys nothing writes the new tables; the lock_source trigger only names the source of the L1 console's
-- lock / unlock (aa_ops, then NULL), which no deployed code reads. The consumer code merges only after this file is
-- applied (S249 lesson).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-012 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-013: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-012') THEN
        RAISE EXCEPTION 'crm-013: crm-012 is not registered (CRM-15 modules 1 + 2, AA-943, lands first)';
    END IF;
    IF to_regclass('crm.client_link') IS NULL OR to_regclass('crm.meeting_slot') IS NULL
       OR to_regprocedure('crm.erase_subject(text,uuid,uuid,boolean)') IS NULL
       OR to_regprocedure('crm.erase_rows(text,text,uuid,uuid,boolean,text)') IS NULL THEN
        RAISE EXCEPTION 'crm-013: crm.client_link / crm.meeting_slot (crm-012) or the crm-010 erase functions missing';
    END IF;
END $$;

-- ── 1. crm.tenant.lock_source ────────────────────────────────────────────────────────────────────
ALTER TABLE crm.tenant ADD COLUMN IF NOT EXISTS lock_source TEXT;
ALTER TABLE crm.tenant DROP CONSTRAINT IF EXISTS tenant_lock_source_chk;
ALTER TABLE crm.tenant ADD CONSTRAINT tenant_lock_source_chk CHECK (
    lock_source IS NULL OR (lock_source IN ('aa_ops', 'cis_tenant', 'cis_membership') AND status = 'locked')
);
COMMENT ON COLUMN crm.tenant.lock_source IS 'AA-978 (crm-013): who locked the agency while status = locked: aa_ops (the L1 console, and any lock that names no source), cis_tenant (a CIS tenant.locked / tenant.deleted event; a CIS tenant.unlocked lifts only this one), cis_membership (CIS removed the last active owner; only the AA-941 owner recovery or an AA unlock lifts it). NULL otherwise, and on agencies locked before crm-013 (read as an AA lock). Kept in step by crm.sync_tenant_lock_source.';

CREATE OR REPLACE FUNCTION crm.sync_tenant_lock_source() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    actor     text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    unscoped  boolean := actor = '' AND current_user::text <> 'crm_app';
    explicit  boolean;
BEGIN
    IF NEW.status IS DISTINCT FROM 'locked' THEN
        NEW.lock_source := NULL;  -- a: leaving locked (or never locked) clears the source, whoever moves the status
        RETURN NEW;
    END IF;
    explicit := NEW.lock_source IS NOT NULL
                AND (TG_OP = 'INSERT' OR NEW.lock_source IS DISTINCT FROM OLD.lock_source);
    IF explicit AND NOT unscoped THEN
        -- c: a cis_* source only from the feed; any source only from a platform actor.
        IF NEW.lock_source IN ('cis_tenant', 'cis_membership') AND actor <> 'platform:feed-tenant-membership' THEN
            RAISE EXCEPTION 'crm: lock_source_forbidden (only the CIS membership feed names a cis_* lock source)'
                USING ERRCODE = 'CRM21';
        END IF;
        IF actor NOT LIKE 'platform:%' THEN
            RAISE EXCEPTION 'crm: lock_source_forbidden (actor % may not name a lock source)', split_part(actor, ':', 1)
                USING ERRCODE = 'CRM21';
        END IF;
    END IF;
    IF NEW.lock_source IS NULL THEN
        NEW.lock_source := 'aa_ops';  -- b: a lock that names no source is AA's (the L1 console)
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.sync_tenant_lock_source() FROM PUBLIC;
CREATE OR REPLACE TRIGGER tenant_sync_lock_source
    BEFORE INSERT OR UPDATE OF status, lock_source ON crm.tenant
    FOR EACH ROW EXECUTE FUNCTION crm.sync_tenant_lock_source();
COMMENT ON FUNCTION crm.sync_tenant_lock_source() IS 'AA-978 (crm-013): keeps crm.tenant.lock_source in step with the status: cleared when the agency is not locked, aa_ops when a lock names no source; a cis_* source only from the actor platform:feed-tenant-membership, any explicit source only from a platform actor (CRM21 lock_source_forbidden); an unscoped session is not restricted.';

-- ── 2. crm.membership_feed_state (platform singleton) ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.membership_feed_state (
    singleton        BOOLEAN PRIMARY KEY DEFAULT true,
    feed_cursor      TEXT,
    last_ok_at       TIMESTAMPTZ,
    last_error_class TEXT,
    last_error_at    TIMESTAMPTZ,
    failures         INTEGER NOT NULL DEFAULT 0,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT membership_feed_state_singleton_chk CHECK (singleton),
    CONSTRAINT membership_feed_state_cursor_chk CHECK (feed_cursor IS NULL OR feed_cursor ~ '^[!-~]{1,200}$'),
    CONSTRAINT membership_feed_state_error_chk CHECK (
        (last_error_class IS NULL) = (last_error_at IS NULL)
        AND (last_error_class IS NULL OR last_error_class ~ '^[a-z][a-z0-9_]{0,39}$')
    ),
    CONSTRAINT membership_feed_state_failures_chk CHECK (failures BETWEEN 0 AND 1000000)
);
CREATE OR REPLACE TRIGGER membership_feed_state_set_updated_at
    BEFORE UPDATE ON crm.membership_feed_state
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
INSERT INTO crm.membership_feed_state (singleton) VALUES (true) ON CONFLICT DO NOTHING;
REVOKE INSERT, DELETE, TRUNCATE ON crm.membership_feed_state FROM crm_app;
COMMENT ON TABLE crm.membership_feed_state IS 'AA-978 (crm-013): the one consumer state of the CIS feed tenant.membership.v1 (crm_membership_pull): the opaque cursor CIS returned last (printable ASCII, <= 200), the last successful pull, the last error class and time, and the consecutive failures the job backs off on. Platform table: no tenant column, no personal data. One row; crm_app SELECT + UPDATE only.';

-- ── 3. crm.membership_inbox (append-only, erasable with the agency) ──────────────────────────────
CREATE TABLE IF NOT EXISTS crm.membership_inbox (
    event_id    UUID PRIMARY KEY,
    tenant_id   UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid,
    event_type  TEXT,
    outcome     TEXT NOT NULL,
    reason_code TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    CONSTRAINT membership_inbox_outcome_chk CHECK (outcome IN ('applied', 'ignored', 'rejected')),
    CONSTRAINT membership_inbox_type_chk CHECK (
        COALESCE(event_type IN ('tenant.created', 'tenant.locked', 'tenant.unlocked', 'tenant.deleted',
                                'membership.invited', 'membership.activated', 'membership.role_changed',
                                'membership.removed'), outcome = 'rejected')
    ),
    CONSTRAINT membership_inbox_reason_chk CHECK (reason_code ~ '^[a-z][a-z0-9_]{0,39}$')
);
CREATE INDEX IF NOT EXISTS membership_inbox_tenant_idx ON crm.membership_inbox (tenant_id, created_at DESC);
ALTER TABLE crm.membership_inbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.membership_inbox FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.membership_inbox;
CREATE POLICY tenant_isolation ON crm.membership_inbox
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
-- Its own copy of crm.erasable_append_only() (crm-010): crm-010's Guard 1 allows that function on consent /
-- trip_stage_history / llm_call only, and a re-run of crm-010 must stay a no-op.
CREATE OR REPLACE FUNCTION crm.membership_inbox_append_only() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    -- Only DELETE, only inside crm.erase_subject (it runs as crm_owner and sets app.erasing for its own transaction).
    IF TG_OP = 'DELETE' AND current_user = 'crm_owner' AND current_setting('app.erasing', true) = 'on' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'crm: % is append-only (% refused)', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'insufficient_privilege';
END;
$$;
REVOKE ALL ON FUNCTION crm.membership_inbox_append_only() FROM PUBLIC;
COMMENT ON FUNCTION crm.membership_inbox_append_only() IS 'AA-978 (crm-013): crm.membership_inbox is append-only; DELETE only as crm_owner inside crm.erase_subject (app.erasing), the crm.erasable_append_only() rule (crm-010) for this table.';
CREATE OR REPLACE TRIGGER membership_inbox_append_only
    BEFORE UPDATE OR DELETE ON crm.membership_inbox
    FOR EACH ROW EXECUTE FUNCTION crm.membership_inbox_append_only();
CREATE OR REPLACE TRIGGER membership_inbox_no_truncate
    BEFORE TRUNCATE ON crm.membership_inbox
    FOR EACH STATEMENT EXECUTE FUNCTION crm.membership_inbox_append_only();
REVOKE UPDATE, DELETE, TRUNCATE ON crm.membership_inbox FROM crm_app;
COMMENT ON TABLE crm.membership_inbox IS 'AA-978 (crm-013): one row per tenant.membership.v1 event the CRM received for an agency it holds, active or locked (event_id = the CIS event id: applied at most once, a replayed page is a no-op), with the agency (= the CIS tenant id; no foreign key; events of CIS tenants without a CRM agency and of offboarding agencies get no row), the type (NULL only when a rejected event names none of the eight), the outcome applied | ignored | rejected and a reason code. Ids and codes only. created_at = received. Append-only; erased with the agency (crm.erase_subject tenant scope); 90-day window proposed (DM-7).';
COMMENT ON COLUMN crm.membership_inbox.reason_code IS 'AA-978: why the event had its outcome (app.cis.membership_feed REASONS, e.g. member_disabled, agency_locked, agency_unlocked, no_crm_member, informational, apply_refused, or a contract reason of app.cis.contract such as crm_role_present)';

-- ── 4. crm.erase_subject with the inbox ──────────────────────────────────────────────────────────
-- The crm-012 text with one change: the agency erase deletes the agency's membership_inbox rows (file header item 4).
-- Later keys (crm-014, crm-015) start from THIS text.
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
        -- crm-013: the agency's CIS membership feed records (ids and codes) go first.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['membership_inbox', ''],
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
COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot and by AA-978 (crm-013) to membership_inbox (agency scope): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
BEGIN
    IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class
             WHERE oid = 'crm.membership_inbox'::regclass) THEN
        RAISE EXCEPTION 'crm-013: crm.membership_inbox must have ENABLE + FORCE row level security';
    END IF;
    IF (SELECT count(*) FROM pg_catalog.pg_policy WHERE polrelid = 'crm.membership_inbox'::regclass) <> 1 THEN
        RAISE EXCEPTION 'crm-013: crm.membership_inbox has exactly one policy (tenant_isolation)';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.membership_inbox', 'crm.membership_feed_state'] LOOP
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, t, p) THEN
                    RAISE EXCEPTION 'crm-013: reader % may % on %', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
        IF pg_catalog.has_table_privilege('crm_app', t, 'DELETE') OR pg_catalog.has_table_privilege('crm_app', t, 'TRUNCATE')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'SELECT') THEN
            RAISE EXCEPTION 'crm-013: crm_app must read and never delete %', t;
        END IF;
    END LOOP;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.membership_inbox', 'UPDATE')
       OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.membership_inbox', 'INSERT') THEN
        RAISE EXCEPTION 'crm-013: crm.membership_inbox is append-only for crm_app (INSERT + SELECT)';
    END IF;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.membership_feed_state', 'INSERT')
       OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.membership_feed_state', 'UPDATE') THEN
        RAISE EXCEPTION 'crm-013: crm.membership_feed_state is a singleton crm_app updates (no INSERT)';
    END IF;
    IF (SELECT count(*) FROM crm.membership_feed_state) <> 1 THEN
        RAISE EXCEPTION 'crm-013: crm.membership_feed_state must hold its one row';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-013: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-013: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.sync_tenant_lock_source()', 'crm.membership_inbox_append_only()',
                             'crm.erase_subject(text,uuid,uuid,boolean)'] LOOP
        IF pg_catalog.has_function_privilege('public', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-013: % is executable by PUBLIC (SEC-4)', t;
        END IF;
    END LOOP;
    IF position('''membership_inbox''' IN (SELECT prosrc FROM pg_catalog.pg_proc
                 WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-013: crm.erase_subject does not erase crm.membership_inbox';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-013', now(), 'AA-978: CIS membership feed consumer (crm.membership_feed_state, crm.membership_inbox, crm.tenant.lock_source + sync trigger, erase_subject erases the inbox with the agency)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
