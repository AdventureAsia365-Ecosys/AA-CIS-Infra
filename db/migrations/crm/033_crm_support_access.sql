-- Migration crm-033: AA-971 CRM-13b (design v3 §4.8 L2 / L3, §2.5 S-04, §2.8 WF-12 "AA support access", §4.9 "support
-- reads, break-glass"; root ADR 0006b decision 6, root ADR 0008a §2) — AA support access to one agency's data, only
-- inside a window the agency owner grants (L2), and AA break-glass with a reason and a short expiry (L3); both read
-- only, through the NOLOGIN reader crm_support_reader, and every read in that agency's own audit.
--
-- Owner: AA-Partner (api/migrations/033_crm_support_access.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Sync bot, Migration Copy Guard). Key crm-033.
--
-- What:
--   1. crm.support_grant: the owner's grant (Settings > Data and privacy > AA support access). One active grant per
--      agency (partial unique index), a window of 1 to 7 days from starts_at, "show identity" (F1 display names of a
--      trip's party may be shown to the support person, each time audited). Ids, codes and dates only. Status
--      active -> revoked (the owner ends it: "End now") | expired (its window passed; written lazily by whoever meets
--      it next).
--   2. crm.support_session: one AA staff member working in one agency. kind support (needs the active grant, ends no
--      later than it, copies its show_identity) or breakglass (no grant: a reason code from a fixed list, at most 1 hour,
--      identity NEVER shown: show_identity must be false). Every session names its ticket (the ops ticket pattern of crm.ops.v1) and the staff member's
--      WORKFORCE identity (iss, sub; never an e-mail). One active session per agency and kind (partial unique index):
--      one staff member at a time. Status active -> ended (the staff member) | revoked (the owner revoked the grant) |
--      expired (its window passed). owner_notified_at: when the break-glass mail to the owners went out.
--   3. crm.guard_support_access(): who may write the two tables (SQLSTATE CRM43 for a grant, CRM44 for a session):
--        grant   INSERT  an owner member for themselves (app.actor member:<id>, app.member_role owner), status active;
--                UPDATE  active -> revoked by an owner member (ended_by = the actor); active -> expired by any actor
--                        once expires_at has passed; nothing else changes;
--        session INSERT  the staff actor support:<sub> / breakglass:<sub> of the row's own kind and sub, status active;
--                        a support session needs its grant active and unexpired, ends no later than it and copies its
--                        show_identity;
--                UPDATE  active -> ended by the session's own staff actor; active -> revoked by an owner member (a
--                        support session only); active -> expired by any actor once expires_at has passed or its grant
--                        is no longer active; owner_notified_at set once (NULL -> a time) by the staff actor or a job;
--                        nothing else changes;
--        DELETE  never, except the crm_owner functions (the agency erase of crm.erase_subject).
--      crm_owner (migrations, crm.erase_subject) is not guarded. No trash: deleted_at stays NULL (CHECK).
--   4. crm_support_reader gets SELECT on named columns of four non-F1 tables, nothing else: crm.tenant (id, status,
--      name, locale), crm.tenant_settings (configuration codes and numbers; not the data-request contact, the consent
--      text or the refund threshold), crm.trip (stage, dates, party size, destination codes; not the title, the mail
--      token or the import index) and crm.trip_stage_history (codes and times). No INSERT on crm.audit_event: the
--      audit is written as crm_app after SET LOCAL ROLE NONE (app.tenancy._write_audit), so the reader needs none.
--      The guard below refuses the file if the reader holds any write privilege anywhere in crm, any privilege on an
--      F1 / vault table, or SELECT on any other relation.
--   5. crm.erase_subject: the crm-027 text, plus the agency-scope steps support_session then support_grant (before the
--      members: a grant names its owner). Nothing else changes.
--
-- Class: contract (root ADR 0017 d3): grants on existing tables (relacl), rows in crm.status_transition (an existing
-- table), a replaced function. MIG-4 order: this migration-only PR, the Infra copy (Migration Sync bot), a manual DB
-- Migrate apply, the bot/db-schema-reference PR, then the AA-971 code PR (adds crm-033 to REQUIRED_SCHEMA_VERSIONS).
-- Code before AA-971 never names the new tables; the reader grants change nothing for it (no code sets that role yet).
--
-- Order: after crm-032 (AA-964). Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.
-- Idempotent (IF NOT EXISTS, DROP … IF EXISTS before each ADD / CREATE, ON CONFLICT DO NOTHING, CREATE OR REPLACE).
-- Rollback: a forward crm- file (MIG-14) after the AA-971 code is reverted: REVOKE the reader's column grants, DROP
-- TABLE crm.support_session, crm.support_grant, DROP FUNCTION crm.guard_support_access(), DELETE the status_transition
-- rows, and crm.erase_subject back to the crm-027 text.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ── Guard 0: runs as the owner, after crm-032 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-033: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-032') THEN
        RAISE EXCEPTION 'crm-033: crm-032 (AA-964 crm.llm_call ledger v2) lands first';
    END IF;
    IF to_regprocedure('crm.erase_subject(text,uuid,uuid,boolean)') IS NULL
       OR to_regclass('crm.calendar_feed') IS NULL
       OR to_regclass('crm.trip_stage_history') IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'crm_support_reader') THEN
        RAISE EXCEPTION 'crm-033: crm.erase_subject (crm-027), crm.calendar_feed, crm.trip_stage_history or the role crm_support_reader missing';
    END IF;
END $$;

-- ── 1. crm.support_grant ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.support_grant (
    support_grant_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                         REFERENCES crm.tenant (tenant_id),
    status               TEXT NOT NULL DEFAULT 'active',
    show_identity        BOOLEAN NOT NULL DEFAULT false,
    starts_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at           TIMESTAMPTZ NOT NULL,
    granted_by_member_id UUID NOT NULL,
    ended_at             TIMESTAMPTZ,
    ended_by             TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at           TIMESTAMPTZ,
    deleted_by           TEXT,
    purge_after          TIMESTAMPTZ,
    CONSTRAINT support_grant_tenant_id_uq UNIQUE (tenant_id, support_grant_id),
    CONSTRAINT support_grant_member_fk FOREIGN KEY (tenant_id, granted_by_member_id)
        REFERENCES crm.member (tenant_id, member_id),
    CONSTRAINT support_grant_status_chk CHECK (status IN ('active', 'revoked', 'expired')),
    CONSTRAINT support_grant_window_chk CHECK (expires_at - starts_at BETWEEN interval '1 day' AND interval '7 days'),
    CONSTRAINT support_grant_end_chk CHECK (
        (status = 'active') = (ended_at IS NULL) AND (ended_at IS NULL) = (ended_by IS NULL)
        AND (ended_by IS NULL OR ended_by ~ '^[A-Za-z0-9:_-]{1,80}$')),
    CONSTRAINT support_grant_never_trashed_chk CHECK (deleted_at IS NULL),
    CONSTRAINT support_grant_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS support_grant_one_active_uq ON crm.support_grant (tenant_id) WHERE status = 'active';

ALTER TABLE crm.support_grant ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.support_grant FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.support_grant;
CREATE POLICY tenant_isolation ON crm.support_grant
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE OR REPLACE TRIGGER support_grant_set_updated_at
    BEFORE UPDATE ON crm.support_grant
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('support_grant', 'active', 'revoked'),
    ('support_grant', 'active', 'expired')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER support_grant_status_transition
    BEFORE UPDATE OF status ON crm.support_grant
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();
REVOKE DELETE, TRUNCATE ON crm.support_grant FROM crm_app;

COMMENT ON TABLE crm.support_grant IS 'AA-971 (crm-033, design v3 §4.8 L2): the agency owner''s grant of AA support access, 1 to 7 days, read only. One active grant per agency. show_identity: the support person may see the display names of a trip''s party (each time audited). Ids, codes and dates only. crm.guard_support_access: only an owner grants or revokes; any actor may mark it expired once its window passed.';
COMMENT ON COLUMN crm.support_grant.show_identity IS 'AA-971 (crm-033): the owner ticked "show identity": a support session of this grant may open the display names of a trip''s party (audited per read); otherwise names stay hidden.';
COMMENT ON COLUMN crm.support_grant.ended_by IS 'AA-971 (crm-033): the actor that revoked or expired the grant (member:<id>, support:<sub>, job:<kind>); an id, never a name.';

-- ── 2. crm.support_session ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.support_session (
    support_session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    kind               TEXT NOT NULL,
    support_grant_id   UUID,
    staff_iss          TEXT NOT NULL,
    staff_sub          TEXT NOT NULL,
    ticket_ref         TEXT NOT NULL,
    reason_code        TEXT,
    show_identity      BOOLEAN NOT NULL,
    status             TEXT NOT NULL DEFAULT 'active',
    started_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at         TIMESTAMPTZ NOT NULL,
    ended_at           TIMESTAMPTZ,
    ended_by           TEXT,
    owner_notified_at  TIMESTAMPTZ,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,
    deleted_by         TEXT,
    purge_after        TIMESTAMPTZ,
    CONSTRAINT support_session_grant_fk FOREIGN KEY (tenant_id, support_grant_id)
        REFERENCES crm.support_grant (tenant_id, support_grant_id),
    -- Break-glass never shows identity: the in-app path trusts the WORKFORCE sign-in plus group crm-ops, with no MFA
    -- step-up (the pool's MFA is OPTIONAL), and it skips the owner's consent. F1 display names stay out of reach
    -- until the AWS-level break-glass of design §4.8 L3 (IAM role with MFA, tenant_id session tag, the KMS condition
    -- CrmBreakGlassOneAgency) exists; a later migration may lift this for that path only.
    CONSTRAINT support_session_kind_chk CHECK (
        (kind = 'support' AND support_grant_id IS NOT NULL AND reason_code IS NULL
         AND expires_at <= started_at + interval '7 days')
        OR (kind = 'breakglass' AND support_grant_id IS NULL AND NOT show_identity AND reason_code IS NOT NULL
            AND reason_code IN ('security_incident', 'data_corruption', 'legal_request', 'owner_unreachable',
                                'service_outage')
            AND expires_at <= started_at + interval '1 hour')),
    CONSTRAINT support_session_window_chk CHECK (expires_at > started_at),
    CONSTRAINT support_session_staff_chk CHECK (
        staff_iss ~ '^https://[A-Za-z0-9.:/_-]{1,200}$' AND staff_sub ~ '^[A-Za-z0-9-]{1,64}$'),
    CONSTRAINT support_session_ticket_chk CHECK (ticket_ref ~ '^[A-Za-z][A-Za-z0-9]{0,15}-[0-9]{1,10}$'),
    CONSTRAINT support_session_status_chk CHECK (status IN ('active', 'ended', 'revoked', 'expired')),
    CONSTRAINT support_session_end_chk CHECK (
        (status = 'active') = (ended_at IS NULL) AND (ended_at IS NULL) = (ended_by IS NULL)
        AND (ended_by IS NULL OR ended_by ~ '^[A-Za-z0-9:_-]{1,80}$')),
    CONSTRAINT support_session_never_trashed_chk CHECK (deleted_at IS NULL),
    CONSTRAINT support_session_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS support_session_one_active_uq ON crm.support_session (tenant_id, kind)
    WHERE status = 'active';
CREATE INDEX IF NOT EXISTS support_session_staff_idx ON crm.support_session (tenant_id, staff_sub)
    WHERE status = 'active';
CREATE INDEX IF NOT EXISTS support_session_recent_idx ON crm.support_session (tenant_id, started_at DESC);
CREATE INDEX IF NOT EXISTS support_session_grant_idx ON crm.support_session (support_grant_id)
    WHERE support_grant_id IS NOT NULL;

ALTER TABLE crm.support_session ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.support_session FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.support_session;
CREATE POLICY tenant_isolation ON crm.support_session
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE OR REPLACE TRIGGER support_session_set_updated_at
    BEFORE UPDATE ON crm.support_session
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('support_session', 'active', 'ended'),
    ('support_session', 'active', 'revoked'),
    ('support_session', 'active', 'expired')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER support_session_status_transition
    BEFORE UPDATE OF status ON crm.support_session
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();
REVOKE DELETE, TRUNCATE ON crm.support_session FROM crm_app;

COMMENT ON TABLE crm.support_session IS 'AA-971 (crm-033, design v3 §4.8 L2 / L3): one AA staff member working read only in one agency. kind support: inside the owner''s active grant (ends no later than it, copies show_identity). kind breakglass: no grant, a reason code, at most 1 hour, identity never shown (no F1 display names: in-app break-glass has no MFA step-up; names wait for the MFA-backed AWS break-glass role), the owners mailed and AA ops alerted. One active session per agency and kind. Every read is an audit event of the agency (actor support:<sub> / breakglass:<sub>). Ids, codes and dates only.';
COMMENT ON COLUMN crm.support_session.staff_sub IS 'AA-971 (crm-033): the WORKFORCE Cognito sub of the AA staff member (a random id; the e-mail is never stored).';
COMMENT ON COLUMN crm.support_session.ticket_ref IS 'AA-971 (crm-033): the support or incident ticket the session works on (crm.ops.v1 ticket pattern); in the audit as ticket:<REF>.';
COMMENT ON COLUMN crm.support_session.reason_code IS 'AA-971 (crm-033): why break-glass was used (security_incident, data_corruption, legal_request, owner_unreachable, service_outage); NULL for a support session.';
COMMENT ON COLUMN crm.support_session.owner_notified_at IS 'AA-971 (crm-033): when the break-glass mail to the agency owners went out (NULL until it did).';

-- ── 3. The write guard ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.guard_support_access() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_owner boolean := v_actor LIKE 'member:%' AND COALESCE(current_setting('app.member_role', true), '') = 'owner';
    v_code text := CASE WHEN TG_TABLE_NAME = 'support_grant' THEN 'CRM43' ELSE 'CRM44' END;
    v_grant record;
BEGIN
    IF current_user = 'crm_owner' THEN
        -- Migrations and the crm_owner functions (crm.erase_subject: the agency erase deletes both tables).
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'crm: support_access_guard (% rows are never deleted)', TG_TABLE_NAME USING ERRCODE = v_code;
    END IF;
    IF v_actor = '' THEN
        RAISE EXCEPTION 'crm: support_access_guard (no actor)' USING ERRCODE = v_code;
    END IF;

    IF TG_TABLE_NAME = 'support_grant' THEN
        IF TG_OP = 'INSERT' THEN
            IF NOT v_owner OR v_actor <> 'member:' || NEW.granted_by_member_id::text OR NEW.status <> 'active' THEN
                RAISE EXCEPTION 'crm: support_access_guard (only an owner grants support access, for themselves)'
                    USING ERRCODE = 'CRM43';
            END IF;
            RETURN NEW;
        END IF;
        IF (NEW.tenant_id, NEW.show_identity, NEW.starts_at, NEW.expires_at, NEW.granted_by_member_id, NEW.created_at,
            NEW.created_by, NEW.deleted_at, NEW.deleted_by, NEW.purge_after)
           IS DISTINCT FROM
           (OLD.tenant_id, OLD.show_identity, OLD.starts_at, OLD.expires_at, OLD.granted_by_member_id, OLD.created_at,
            OLD.created_by, OLD.deleted_at, OLD.deleted_by, OLD.purge_after) THEN
            RAISE EXCEPTION 'crm: support_access_guard (a grant''s window and scope are fixed; grant again)'
                USING ERRCODE = 'CRM43';
        END IF;
        IF NEW.status = OLD.status THEN
            IF (NEW.ended_at, NEW.ended_by) IS DISTINCT FROM (OLD.ended_at, OLD.ended_by) THEN
                RAISE EXCEPTION 'crm: support_access_guard (the end of a grant is fixed)' USING ERRCODE = 'CRM43';
            END IF;
            RETURN NEW;
        END IF;
        IF NEW.status = 'revoked' AND v_owner AND NEW.ended_by = v_actor THEN
            RETURN NEW;
        END IF;
        IF NEW.status = 'expired' AND OLD.expires_at <= now() AND NEW.ended_by = v_actor THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'crm: support_access_guard (actor % may not set a grant %)', v_actor, NEW.status
            USING ERRCODE = 'CRM43';
    END IF;

    -- crm.support_session
    IF TG_OP = 'INSERT' THEN
        IF v_actor <> NEW.kind || ':' || NEW.staff_sub OR NEW.status <> 'active' OR NEW.owner_notified_at IS NOT NULL THEN
            RAISE EXCEPTION 'crm: support_access_guard (a session is opened by its own staff member)'
                USING ERRCODE = 'CRM44';
        END IF;
        IF NEW.kind = 'support' THEN
            SELECT status, expires_at, show_identity INTO v_grant
              FROM crm.support_grant WHERE support_grant_id = NEW.support_grant_id;
            IF NOT FOUND OR v_grant.status <> 'active' OR v_grant.expires_at <= now()
               OR NEW.expires_at > v_grant.expires_at OR NEW.show_identity IS DISTINCT FROM v_grant.show_identity THEN
                RAISE EXCEPTION 'crm: support_access_guard (a support session needs the owner''s active grant)'
                    USING ERRCODE = 'CRM44';
            END IF;
        END IF;
        RETURN NEW;
    END IF;
    IF (NEW.tenant_id, NEW.kind, NEW.support_grant_id, NEW.staff_iss, NEW.staff_sub, NEW.ticket_ref, NEW.reason_code,
        NEW.show_identity, NEW.started_at, NEW.expires_at, NEW.created_at, NEW.created_by, NEW.deleted_at,
        NEW.deleted_by, NEW.purge_after)
       IS DISTINCT FROM
       (OLD.tenant_id, OLD.kind, OLD.support_grant_id, OLD.staff_iss, OLD.staff_sub, OLD.ticket_ref, OLD.reason_code,
        OLD.show_identity, OLD.started_at, OLD.expires_at, OLD.created_at, OLD.created_by, OLD.deleted_at,
        OLD.deleted_by, OLD.purge_after) THEN
        RAISE EXCEPTION 'crm: support_access_guard (a session''s staff member, ticket and window are fixed)'
            USING ERRCODE = 'CRM44';
    END IF;
    IF NEW.owner_notified_at IS DISTINCT FROM OLD.owner_notified_at THEN
        IF OLD.owner_notified_at IS NOT NULL OR NEW.owner_notified_at IS NULL
           OR NOT (v_actor = OLD.kind || ':' || OLD.staff_sub OR v_actor LIKE 'job:%') THEN
            RAISE EXCEPTION 'crm: support_access_guard (the owner notice is recorded once)' USING ERRCODE = 'CRM44';
        END IF;
    END IF;
    IF NEW.status = OLD.status THEN
        IF (NEW.ended_at, NEW.ended_by) IS DISTINCT FROM (OLD.ended_at, OLD.ended_by) THEN
            RAISE EXCEPTION 'crm: support_access_guard (the end of a session is fixed)' USING ERRCODE = 'CRM44';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.ended_by IS DISTINCT FROM v_actor THEN
        RAISE EXCEPTION 'crm: support_access_guard (ended_by names the acting actor)' USING ERRCODE = 'CRM44';
    END IF;
    IF NEW.status = 'ended' AND v_actor = OLD.kind || ':' || OLD.staff_sub THEN
        RETURN NEW;
    END IF;
    IF NEW.status = 'revoked' AND v_owner AND OLD.kind = 'support' THEN
        RETURN NEW;
    END IF;
    IF NEW.status = 'expired' AND (OLD.expires_at <= now() OR NOT EXISTS (
            SELECT 1 FROM crm.support_grant g
             WHERE g.support_grant_id = OLD.support_grant_id AND g.status = 'active' AND g.expires_at > now())) THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'crm: support_access_guard (actor % may not set a session %)', v_actor, NEW.status
        USING ERRCODE = 'CRM44';
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_support_access() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_support_access() IS 'AA-971 (crm-033): the write rules of crm.support_grant (CRM43) and crm.support_session (CRM44): only an owner grants or revokes; a session is opened and ended by its own staff actor (support:<sub> / breakglass:<sub>), a support session only inside the active grant; an owner revokes a support session; any actor marks an expired row expired; the owner notice is recorded once; no delete outside the crm_owner functions.';
CREATE OR REPLACE TRIGGER support_grant_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.support_grant
    FOR EACH ROW EXECUTE FUNCTION crm.guard_support_access();
CREATE OR REPLACE TRIGGER support_session_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.support_session
    FOR EACH ROW EXECUTE FUNCTION crm.guard_support_access();

-- ── 4. crm_support_reader: named columns of four non-F1 tables, nothing else ─────────────────────
REVOKE ALL ON crm.support_grant, crm.support_session FROM crm_ai_reader, crm_insights, crm_support_reader, crm_eraser;
GRANT SELECT (tenant_id, status, display_name, default_locale) ON crm.tenant TO crm_support_reader;
GRANT SELECT (tenant_id, ai_enabled, ai_budget_usd, timezone, base_currency, booking_validation_level, fx_mode,
              trash_days, auto_archive_months, stage2_auto_send, invoice_due_days, service_fee_enabled,
              onboarding_later, onboarding_done, deleted_at)
    ON crm.tenant_settings TO crm_support_reader;
GRANT SELECT (trip_id, tenant_id, stage, stage_entered_at, waiting_on, start_date, end_date, month, nights,
              destinations, party_adults, party_child_ages, party_type, owner_member_id, lead_source,
              lost_reason_code, cancel_reason_code, last_inquiry_at, last_activity_at, created_at, updated_at,
              deleted_at)
    ON crm.trip TO crm_support_reader;
GRANT SELECT (history_id, tenant_id, trip_id, from_stage, to_stage, reason_code, override, override_reason_code, at,
              created_by)
    ON crm.trip_stage_history TO crm_support_reader;

DO $$
DECLARE
    r record;
    p text;
    v_allowed CONSTANT text[] := ARRAY['tenant', 'tenant_settings', 'trip', 'trip_stage_history'];
    -- The F1 / vault tables (design §4.3 Fix A1; AA-CIS-Infra db/isolation_probe.py CRM_F1_TABLES) and the other
    -- tables that hold personal data or secrets: never readable by the support reader, not even one column.
    v_f1 CONSTANT text[] := ARRAY['traveler', 'traveler_health', 'traveler_relation', 'traveler_flight', 'document',
                                  'trip_traveler', 'note', 'consent', 'form_submission', 'tenant_key',
                                  'integration_credential', 'member', 'signature_request', 'terms_acceptance',
                                  'signature_event', 'calendar_feed', 'message', 'conversation', 'placeholder_map',
                                  'otp_challenge', 'client_link', 'member_invitation'];
BEGIN
    FOR r IN SELECT c.oid, c.relname::text AS name FROM pg_catalog.pg_class c
              WHERE c.relnamespace = 'crm'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm') LOOP
        FOREACH p IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] LOOP
            IF pg_catalog.has_table_privilege('crm_support_reader', r.oid, p) THEN
                RAISE EXCEPTION 'crm-033: crm_support_reader may % on crm.% (read only)', p, r.name;
            END IF;
        END LOOP;
        IF pg_catalog.has_any_column_privilege('crm_support_reader', r.oid, 'SELECT')
           AND r.name <> ALL (v_allowed) THEN
            RAISE EXCEPTION 'crm-033: crm_support_reader may read crm.% (not on the support list)', r.name;
        END IF;
        IF r.name = ANY (v_f1) AND pg_catalog.has_any_column_privilege('crm_support_reader', r.oid, 'SELECT') THEN
            RAISE EXCEPTION 'crm-033: crm_support_reader may read the F1 table crm.%', r.name;
        END IF;
    END LOOP;
    IF pg_catalog.has_column_privilege('crm_support_reader', 'crm.trip', 'title', 'SELECT')
       OR pg_catalog.has_column_privilege('crm_support_reader', 'crm.trip', 'mail_token', 'SELECT')
       OR pg_catalog.has_column_privilege('crm_support_reader', 'crm.tenant_settings', 'data_request_contact', 'SELECT') THEN
        RAISE EXCEPTION 'crm-033: crm_support_reader may read a trip title, a mail token or the data-request contact';
    END IF;
END $$;

-- ── 5. crm.erase_subject: the crm-027 text + the two support tables (agency scope) ──────────────
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
            ['note', ''], ['task', ''], ['trip_stage_history', ''], ['trip_party', ''], ['trip_traveler', ''],
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

COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope), by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge), by AA-945 (crm-015) to mail (trip, traveller and agency scopes: message, conversation; agency scope: saved_reply, mail_import, ingest_address, channel_account; new scope conversation for the trash purge), by AA-946 (crm-016) to the lifecycle tables (trip and agency scopes: signature_request, otp_challenge, traveler_access, payment, payment_schedule, proposal; traveller scope: signature_request, otp_challenge, traveler_access, and the typed acceptance name of the proposals their links carried (accepted_name_enc := NULL); agency scope: agreement_doc) by AA-947 (crm-017) to the AA lines (trip, booking_line and agency scopes: aa_request; agency scope: inbox_events, booking_feed_state) by AA-949 (crm-019) to the proposal builder (trip and agency scopes: selection, option_rule, option, option_block, proposal_day) by AA-950 (crm-021) to crm.metric_event (trip and agency scopes) by AA-951 (crm-022) to crm.prep_pack_selection (trip and agency scopes) and crm.message_template (agency scope) by AA-993 G4b (crm-023) to crm.dispatch_attempt (trip, traveller and agency scopes, before crm.dispatch_queue) and by AA-952 (crm-024) to the invoices and payments (trip and agency scopes: crm.refund_request before crm.payment, crm.invoice_line and crm.invoice after it and before crm.payment_schedule; agency scope: crm.payment_provider_account, crm.invoice_sequence) and by AA-955 (crm-025) to the signed evidence (agency scope: crm.terms_acceptance, crm.signature_event; trip and traveller scopes KEEP them, DM-7 claim-period exception, and count them as terms_acceptance_kept / signature_event_kept; traveller scope also erases the signatures the traveller signed as a guardian) and by AA-967 (crm-026) to the keep list of the agency scope (crm.export_job, crm.data_request: receipts without personal data) and by AA-961 (crm-027) to the agency scope (crm.incident_flag, crm.calendar_feed) and by AA-971 (crm-033) to the agency scope (crm.support_session, then crm.support_grant): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, conversation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';


INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-033', now(), 'AA-971 CRM-13b: crm.support_grant (owner-granted AA support access, 1-7 days, show identity) and crm.support_session (support inside the grant / break-glass with a reason, at most 1 hour), crm.guard_support_access, crm_support_reader SELECT on named columns of tenant, tenant_settings, trip, trip_stage_history; crm.erase_subject agency scope + support tables')
ON CONFLICT (version) DO NOTHING;

COMMIT;
