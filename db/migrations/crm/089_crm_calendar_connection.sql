-- Migration crm-089: AA-1011 part 3 (errata S247 §1 bring-your-own; design v3 R15 calendar) — a member's own Google or
-- Microsoft 365 calendar, connected by OAuth, into which the CRM pushes the member's departures and tasks one way (the
-- revocable ICS feed of crm-027 stays as the fallback).
--
-- Owner: AA-Partner (api/migrations/089_crm_calendar_connection.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy Migration Apply runs (Migration Copy Guard). Key crm-089 (owner main max crm-088 + 1); if the numbers move,
-- renumber: file name, this header, Guard 0 and the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS (code PR)
-- and the tests that name it (git grep '089_' and 'crm-089').
--
-- What (DM-7.1: crm.calendar_connection already has its place in the agency configuration row of root data standards
-- Part B §7, "while the agency is active; hard delete at offboarding"; the root PR of this change describes it):
--   1. crm.integration_credential.provider + google_calendar, microsoft_calendar: the calendar's refresh token is the
--      member's own credential row (member_id = the member), sealed under the agency integration DEK exactly like a
--      mailbox credential (Vault.encrypt_secret; never plaintext, never returned by a route). A separate provider value
--      keeps it apart from the member's Gmail / Microsoft 365 mailbox credential (one row per provider and member,
--      crm-015 integration_credential_provider_member_uq).
--   2. crm.calendar_connection (base template): one per member and provider (google | microsoft): scope mine | agency
--      (the member's own trips and tasks, or the whole agency, as the ICS feed), status active -> revoked (revoked_at,
--      revoked_by), credential_id (the same-agency key to the credential row, ON DELETE CASCADE: the push job deletes
--      the credential once it has removed the pushed events (no revoke at the provider: the OAuth client is the
--      mailbox's, and a Google revoke would cancel a Gmail mailbox on the same account), and the connection goes
--      with it;
--      the agency erase deletes the credential too), address_enc (the calendar account's address, pii:contact under
--      the mail DEK, shown on the card), and the last push: last_sync_at, last_ok_at, failure_class, event_count (the
--      CRM events in the calendar after it). Nothing about the events themselves is stored: each pushed event carries
--      its own CRM key in the calendar (a private extended property), so the push is idempotent by external event id.
--      crm.guard_calendar_connection (SQLSTATE CRM57): a member connects only their own calendar; the member, the
--      agency, the provider, the credential and the creation stamp never change; only the member or an owner changes
--      a row (revoke, scope, a new address on reconnect); a member never writes the push counters (the job's). Cascades
--      from its member too (crm-069 voice_profile pattern), so crm.erase_subject is unchanged
--      (tests/integration/test_crm010_schema.py CASCADE_ERASED lists it).
--   3. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles), crm_app SELECT + INSERT + UPDATE (no DELETE, no
--      TRUNCATE: a connection leaves only with its credential), no reader grant (AI, insights and support never see
--      it); the status move active -> revoked in crm.status_transition.
--   SQLSTATE: CRM57 calendar_connection_guard (CRM56 was the last key in use, crm-067; CRM58 is the next).
--
-- Behaviour on apply: none for running code. No credential uses the new provider values and nothing reads the table
-- until the AA-Partner code PR deploys (it raises the readiness to crm-089).
--
-- Class: contract (an ALTER of crm.integration_credential: a replaced provider CHECK; crm.status_transition rows). No
-- '-- migrate:' directive. MIG-4: this migration-only PR, applied on Dev by Infra Migration Apply once every job table
-- is idle (root ADR 0017a), then the code PR.
--
-- Rollback (a new forward migration, after the code is reverted): DELETE FROM crm.integration_credential WHERE
-- provider IN ('google_calendar', 'microsoft_calendar') as crm_owner (the connections cascade); DROP TABLE
-- crm.calendar_connection; DROP FUNCTION crm.guard_calendar_connection(); put back the crm-057 provider CHECK;
-- DELETE FROM crm.status_transition WHERE table_name = 'calendar_connection'.
--
-- Runs as crm_owner (Migration Apply / DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (IF NOT
-- EXISTS, DROP … IF EXISTS before each ADD, CREATE OR REPLACE, ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-088 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-089: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-088') THEN
        RAISE EXCEPTION 'crm-089: crm-088 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-089' AND description NOT LIKE 'AA-1011 calendar push:%') THEN
        RAISE EXCEPTION 'crm-089: the key crm-089 is already held by another migration (not AA-1011): renumber one';
    END IF;
    IF to_regclass('crm.member') IS NULL OR to_regclass('crm.integration_credential') IS NULL
       OR to_regprocedure('crm.enforce_status_transition()') IS NULL
       OR to_regprocedure('crm.set_updated_at()') IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid = 'crm.member'::regclass
                        AND conname = 'member_tenant_member_uq')
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid = 'crm.integration_credential'::regclass
                        AND conname = 'integration_credential_tenant_id_uq') THEN
        RAISE EXCEPTION 'crm-089: crm.member / crm.integration_credential (their same-agency keys) or the trigger functions are missing';
    END IF;
END $$;

-- ── 1. crm.integration_credential.provider + google_calendar, microsoft_calendar ────────────────
ALTER TABLE crm.integration_credential DROP CONSTRAINT IF EXISTS integration_credential_provider_chk;
ALTER TABLE crm.integration_credential ADD CONSTRAINT integration_credential_provider_chk CHECK (
    provider IN ('twilio', 'stripe_key', 'stripe_webhook_secret', 'google', 'microsoft', 'smtp', 'esign', 'vn_gateway',
                 'google_calendar', 'microsoft_calendar')
);

-- ── 2. crm.calendar_connection ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.calendar_connection (
    calendar_connection_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                    REFERENCES crm.tenant (tenant_id),
    member_id       UUID NOT NULL,
    provider        TEXT NOT NULL,
    scope           TEXT NOT NULL DEFAULT 'mine',
    status          TEXT NOT NULL DEFAULT 'active',
    credential_id   UUID NOT NULL,
    address_enc     BYTEA NOT NULL,
    failure_class   TEXT,
    last_sync_at    TIMESTAMPTZ,
    last_ok_at      TIMESTAMPTZ,
    event_count     INTEGER NOT NULL DEFAULT 0,
    revoked_at      TIMESTAMPTZ,
    revoked_by      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ,
    deleted_by      TEXT,
    purge_after     TIMESTAMPTZ,
    CONSTRAINT calendar_connection_member_provider_uq UNIQUE (tenant_id, member_id, provider),
    CONSTRAINT calendar_connection_credential_uq UNIQUE (tenant_id, credential_id),
    CONSTRAINT calendar_connection_member_fk FOREIGN KEY (tenant_id, member_id)
        REFERENCES crm.member (tenant_id, member_id) ON DELETE CASCADE,
    CONSTRAINT calendar_connection_credential_fk FOREIGN KEY (tenant_id, credential_id)
        REFERENCES crm.integration_credential (tenant_id, integration_credential_id) ON DELETE CASCADE,
    CONSTRAINT calendar_connection_provider_chk CHECK (provider IN ('google', 'microsoft')),
    CONSTRAINT calendar_connection_scope_chk CHECK (scope IN ('mine', 'agency')),
    CONSTRAINT calendar_connection_status_chk CHECK (status IN ('active', 'revoked')),
    CONSTRAINT calendar_connection_revoked_chk CHECK (
        (status = 'revoked') = (revoked_at IS NOT NULL) AND (revoked_at IS NULL) = (revoked_by IS NULL)
    ),
    CONSTRAINT calendar_connection_address_chk CHECK (octet_length(address_enc) BETWEEN 30 AND 2048),
    CONSTRAINT calendar_connection_failure_chk CHECK (
        failure_class IS NULL OR failure_class IN
            ('auth_revoked', 'permission_missing', 'vendor_rejected', 'rate_limited', 'unreachable')
    ),
    CONSTRAINT calendar_connection_count_chk CHECK (event_count >= 0),
    CONSTRAINT calendar_connection_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS calendar_connection_status_idx ON crm.calendar_connection (tenant_id, status);
COMMENT ON TABLE crm.calendar_connection IS 'AA-1011 (crm-089; errata S247 §1 bring-your-own, design v3 R15): one member''s own Google or Microsoft 365 calendar, connected by OAuth (Google calendar.events, Graph Calendars.ReadWrite), into which the crm_calendar_push job writes the member''s departures and tasks one way (scope mine) or the agency''s (scope agency). The refresh token is the member''s crm.integration_credential row (provider google_calendar / microsoft_calendar, the integration DEK); the connection cascades from it and from its member. Disconnect sets revoked; the job then deletes the pushed events and the credential (never a revoke at the provider: the OAuth client is the mailbox''s), and the row goes with it. No event is stored here: each pushed event carries its CRM key in the calendar. crm.guard_calendar_connection (CRM57). crm_app never deletes one.';
COMMENT ON COLUMN crm.calendar_connection.address_enc IS 'pii:contact; the calendar account''s address (the ID token''s email claim at consent), AES-256-GCM under the tenant mail DEK (AAD tenant, calendar_connection, address_enc, row id)';
COMMENT ON COLUMN crm.calendar_connection.scope IS 'mine = the member''s own trips and tasks; agency = the whole agency (as crm.calendar_feed.scope)';
COMMENT ON COLUMN crm.calendar_connection.event_count IS 'the CRM events in the calendar window after the last push (counts only)';
COMMENT ON COLUMN crm.calendar_connection.failure_class IS 'why the last push failed (the integration_credential failure classes); NULL after a good push';

CREATE OR REPLACE FUNCTION crm.guard_calendar_connection() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_role text := COALESCE(current_setting('app.member_role', true), '');
BEGIN
    IF v_actor = '' THEN
        RAISE EXCEPTION 'crm: calendar_connection_guard (no actor)' USING ERRCODE = 'CRM57';
    END IF;
    IF TG_OP = 'INSERT' THEN
        -- A member connects their own calendar only (the consent was theirs).
        IF NOT (v_actor = 'member:' || NEW.member_id::text OR v_actor LIKE 'seed:%') THEN
            RAISE EXCEPTION 'crm: calendar_connection_guard (a member connects only their own calendar)'
                USING ERRCODE = 'CRM57';
        END IF;
        IF NEW.status <> 'active' THEN
            RAISE EXCEPTION 'crm: calendar_connection_guard (a connection starts active)' USING ERRCODE = 'CRM57';
        END IF;
        RETURN NEW;
    END IF;
    IF (NEW.tenant_id, NEW.member_id, NEW.provider, NEW.credential_id, NEW.created_at, NEW.created_by)
       IS DISTINCT FROM
       (OLD.tenant_id, OLD.member_id, OLD.provider, OLD.credential_id, OLD.created_at, OLD.created_by) THEN
        RAISE EXCEPTION 'crm: calendar_connection_guard (member, provider and credential are fixed; connect again)'
            USING ERRCODE = 'CRM57';
    END IF;
    IF v_actor LIKE 'member:%' THEN
        IF v_actor <> 'member:' || OLD.member_id::text AND v_role <> 'owner' THEN
            RAISE EXCEPTION 'crm: calendar_connection_guard (only the member or an owner changes a connection)'
                USING ERRCODE = 'CRM57';
        END IF;
        IF (NEW.last_sync_at, NEW.last_ok_at, NEW.event_count) IS DISTINCT FROM
           (OLD.last_sync_at, OLD.last_ok_at, OLD.event_count) THEN
            RAISE EXCEPTION 'crm: calendar_connection_guard (the push counters belong to the push job)'
                USING ERRCODE = 'CRM57';
        END IF;
    ELSIF v_actor NOT LIKE 'job:%' AND v_actor NOT LIKE 'platform:%' AND v_actor NOT LIKE 'seed:%' THEN
        RAISE EXCEPTION 'crm: calendar_connection_guard (actor % may not change a connection)', v_actor
            USING ERRCODE = 'CRM57';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_calendar_connection() FROM PUBLIC;
CREATE OR REPLACE TRIGGER calendar_connection_guard
    BEFORE INSERT OR UPDATE ON crm.calendar_connection
    FOR EACH ROW EXECUTE FUNCTION crm.guard_calendar_connection();

-- ── 3. Status move, RLS, grants, triggers ────────────────────────────────────────────────────────
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('calendar_connection', 'active', 'revoked')
ON CONFLICT DO NOTHING;

ALTER TABLE crm.calendar_connection ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.calendar_connection FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.calendar_connection;
CREATE POLICY tenant_isolation ON crm.calendar_connection
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE OR REPLACE TRIGGER calendar_connection_set_updated_at
    BEFORE UPDATE ON crm.calendar_connection
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE OR REPLACE TRIGGER calendar_connection_status_transition
    BEFORE UPDATE OF status ON crm.calendar_connection
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();
-- crm_app reads and writes; it never deletes or truncates (a connection leaves with its credential). No reader role.
REVOKE DELETE, TRUNCATE ON crm.calendar_connection FROM crm_app;
GRANT SELECT, INSERT, UPDATE ON crm.calendar_connection TO crm_app;

-- ── Post-check ────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class WHERE oid = 'crm.calendar_connection'::regclass
                    AND relrowsecurity AND relforcerowsecurity) THEN
        RAISE EXCEPTION 'crm-089: crm.calendar_connection must have FORCE ROW LEVEL SECURITY';
    END IF;
    IF position('google_calendar' IN pg_catalog.pg_get_constraintdef((SELECT oid FROM pg_catalog.pg_constraint
            WHERE conrelid = 'crm.integration_credential'::regclass
              AND conname = 'integration_credential_provider_chk'))) = 0 THEN
        RAISE EXCEPTION 'crm-089: the integration_credential provider CHECK does not list the calendar providers';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-089', now(), 'AA-1011 calendar push: crm.calendar_connection (a member''s own Google / Microsoft 365 calendar, one-way push), integration_credential providers google_calendar / microsoft_calendar')
ON CONFLICT (version) DO NOTHING;

COMMIT;
