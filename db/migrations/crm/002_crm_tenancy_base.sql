-- Migration crm-002: AA-933 (partner CRM, design v3 card CRM-05) — the tenancy base: crm.tenant, crm.member, the
-- status-transition rule, the base table template in use, and the readiness view.
--
-- Owner: AA-Partner (api/migrations/002_crm_tenancy_base.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-002.
--
-- Why. crm-001 set the schema's privilege model and crm.job. The API's tenant_tx() (api/app/tenancy.py) needs a tenant
-- and a membership to check, and every later card needs one table shape to copy (design v3 §3.2, Fix B6: trash
-- columns from the first migration). This file is that shape, used by its first two tables.
--
-- What:
--   1. Shared trigger functions: crm.set_updated_at() (BEFORE UPDATE on every tenant table) and
--      crm.enforce_status_transition() (status as TEXT + CHECK plus a transitions table, design v3 §3.2). Not
--      executable by PUBLIC (crm-001 default privileges; a trigger needs no EXECUTE grant to fire).
--   2. crm.status_transition: the allowed (table, from, to) moves. Platform reference data, no tenant column; crm_app
--      may only read it.
--   3. crm.tenant (one row per agency, key tenant_id) and crm.member (an agency user: the (iss, sub) of a partner-pool
--      or, on Dev before AA-939, EXTERNAL cis-portal token; role owner / agent / assistant). Both follow the base
--      template api/db/templates/tenant_table.sql: base columns tenant_id, created_at, created_by, updated_at; trash
--      columns deleted_at, deleted_by, purge_after (set together or not at all); ENABLE + FORCE RLS with one policy
--      for the CRM roles (crm_owner, crm_app and the four NOLOGIN readers; never TO PUBLIC, ecosystem catalogue rule
--      b): tenant_id = the transaction's app.tenant_id (set by tenant_tx() before anything is read). No tenant set =
--      no row. Any other role matches no policy and sees no row. FORCE makes crm_owner subject to it too.
--   4. crm.v_schema_versions: security_barrier view (owner crm_owner, CIS 269 grants it SELECT on
--      shared.schema_versions) over the crm- keys, read by /crm/health/ready. crm_app gets SELECT only: a simple view
--      is auto-updatable through its owner's rights, so the DML the default privileges give is revoked.
--   No personal data: member keeps the token's issuer and subject only (the person's e-mail and name stay in Cognito;
--   later cards add PII columns with their pii: comments and the vault rules).
--   The integration test tests/integration/test_crm002_tenancy.py checks the template on every table of schema crm
--   (catalogue guard), the cross-tenant SELECT (0 rows) and the transition rule.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Rollback: a forward crm- file
-- (MIG-14); before AA-933 deploys nothing reads these tables.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-001 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-002: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-001') THEN
        RAISE EXCEPTION 'crm-002: crm-001 is not registered';
    END IF;
    IF to_regclass('crm.job') IS NULL THEN
        RAISE EXCEPTION 'crm-002: crm.job is missing (crm-001)';
    END IF;
END $$;

-- ── 1. Shared trigger functions ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.set_updated_at() FROM PUBLIC;

CREATE OR REPLACE FUNCTION crm.enforce_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status AND NOT EXISTS (
        SELECT 1 FROM crm.status_transition t
         WHERE t.table_name = TG_TABLE_NAME AND t.from_status = OLD.status AND t.to_status = NEW.status
    ) THEN
        RAISE EXCEPTION 'crm: % status % -> % is not an allowed transition', TG_TABLE_NAME, OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.enforce_status_transition() FROM PUBLIC;

-- ── 2. Allowed status moves ──────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.status_transition (
    table_name  TEXT NOT NULL,
    from_status TEXT NOT NULL,
    to_status   TEXT NOT NULL,
    PRIMARY KEY (table_name, from_status, to_status),
    CONSTRAINT status_transition_names_chk CHECK (
        table_name ~ '^[a-z][a-z0-9_]*$' AND from_status ~ '^[a-z][a-z0-9_]*$' AND to_status ~ '^[a-z][a-z0-9_]*$'
        AND from_status <> to_status
    )
);
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON crm.status_transition FROM crm_app;

INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('tenant', 'active', 'locked'),
    ('tenant', 'locked', 'active'),
    ('member', 'invited', 'active'),
    ('member', 'invited', 'disabled'),
    ('member', 'active', 'disabled'),
    ('member', 'disabled', 'active')
ON CONFLICT DO NOTHING;

COMMENT ON TABLE crm.status_transition IS 'AA-933 (crm-002): allowed status moves per crm table, enforced by crm.enforce_status_transition(). Platform reference data, no tenant column; crm_app reads only.';

-- ── 3a. crm.tenant ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.tenant (
    tenant_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    status       TEXT NOT NULL DEFAULT 'active',
    is_synthetic BOOLEAN NOT NULL DEFAULT true,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ,
    deleted_by   TEXT,
    purge_after  TIMESTAMPTZ,
    CONSTRAINT tenant_status_chk CHECK (status IN ('active', 'locked')),
    CONSTRAINT tenant_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);

ALTER TABLE crm.tenant ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.tenant FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.tenant;
CREATE POLICY tenant_isolation ON crm.tenant
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE OR REPLACE TRIGGER tenant_set_updated_at
    BEFORE UPDATE ON crm.tenant
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE OR REPLACE TRIGGER tenant_status_transition
    BEFORE UPDATE OF status ON crm.tenant
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();

COMMENT ON TABLE crm.tenant IS 'AA-933 (crm-002): one partner agency (the CRM tenant). Base template (api/db/templates/tenant_table.sql), FORCE RLS on app.tenant_id. Dev holds synthetic agencies only (ADR 0010 decision 3; the API refuses is_synthetic = false on Dev).';
COMMENT ON COLUMN crm.tenant.is_synthetic IS 'true for every Dev agency (ADR 0010 decision 3); a real agency only after the Go-real gate (AA-980)';

-- ── 3b. crm.member ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.member (
    member_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                 REFERENCES crm.tenant (tenant_id),
    cognito_iss  TEXT NOT NULL,
    cognito_sub  TEXT NOT NULL,
    role         TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'invited',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ,
    deleted_by   TEXT,
    purge_after  TIMESTAMPTZ,
    CONSTRAINT member_identity_uq UNIQUE (tenant_id, cognito_iss, cognito_sub),
    CONSTRAINT member_iss_chk CHECK (cognito_iss ~ '^https://[^/]+/[^/]+$'),
    CONSTRAINT member_sub_chk CHECK (length(cognito_sub) BETWEEN 1 AND 128),
    CONSTRAINT member_role_chk CHECK (role IN ('owner', 'agent', 'assistant')),
    CONSTRAINT member_status_chk CHECK (status IN ('invited', 'active', 'disabled')),
    CONSTRAINT member_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);

-- tenant_tx() looks a member up by token identity inside one tenant.
CREATE INDEX IF NOT EXISTS member_identity_idx ON crm.member (cognito_iss, cognito_sub) WHERE deleted_at IS NULL;

ALTER TABLE crm.member ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.member FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.member;
CREATE POLICY tenant_isolation ON crm.member
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE OR REPLACE TRIGGER member_set_updated_at
    BEFORE UPDATE ON crm.member
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE OR REPLACE TRIGGER member_status_transition
    BEFORE UPDATE OF status ON crm.member
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();

COMMENT ON TABLE crm.member IS 'AA-933 (crm-002): an agency user and their CRM role. Identity = the verified token (iss, sub), never an e-mail lookup (ADR 0006b decision 5). Base template, FORCE RLS on app.tenant_id.';
COMMENT ON COLUMN crm.member.cognito_iss IS 'issuer of the user''s access token: partner pool, or EXTERNAL (cis-portal) on Dev before AA-939';
COMMENT ON COLUMN crm.member.cognito_sub IS 'the token''s sub: a pseudonymous id, no personal data by itself';

-- ── 4. Readiness view ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW crm.v_schema_versions WITH (security_barrier = true) AS
    SELECT version, applied_at FROM shared.schema_versions WHERE version LIKE 'crm-%';
REVOKE ALL ON crm.v_schema_versions FROM crm_app;
GRANT SELECT ON crm.v_schema_versions TO crm_app;
COMMENT ON VIEW crm.v_schema_versions IS 'AA-933 (crm-002): the registered crm- migration keys, for /crm/health/ready. Read-only for crm_app.';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    p text;
BEGIN
    FOREACH t IN ARRAY ARRAY['crm.tenant', 'crm.member'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = t::regclass) THEN
            RAISE EXCEPTION 'crm-002: % must have ENABLE + FORCE row level security', t;
        END IF;
        FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
            IF NOT pg_catalog.has_table_privilege('crm_app', t, p) THEN
                RAISE EXCEPTION 'crm-002: crm_app lacks % on % (default privileges FOR ROLE crm_owner)', p, t;
            END IF;
        END LOOP;
    END LOOP;
    FOREACH p IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
        IF pg_catalog.has_table_privilege('crm_app', 'crm.v_schema_versions', p)
           OR pg_catalog.has_table_privilege('crm_app', 'crm.status_transition', p) THEN
            RAISE EXCEPTION 'crm-002: crm_app may % on a read-only relation', p;
        END IF;
    END LOOP;
    IF NOT pg_catalog.has_table_privilege('crm_app', 'crm.v_schema_versions', 'SELECT') THEN
        RAISE EXCEPTION 'crm-002: crm_app cannot read crm.v_schema_versions';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-002: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF pg_catalog.has_function_privilege('public', 'crm.set_updated_at()', 'EXECUTE')
       OR pg_catalog.has_function_privilege('public', 'crm.enforce_status_transition()', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-002: a crm trigger function is executable by PUBLIC (SEC-4)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-002', now(), 'AA-933: crm tenancy base (tenant, member, status transitions, base table template, readiness view)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
