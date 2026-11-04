-- Migration 364: AA-1035 (R2 slice 1, S267) — shared.staff_tenant_assignment (which staff member looks after which
-- tenant) and shared.staff_view_as_session (the read-only "view as tenant" access log, schema only).
--
-- Why. Root ADR 0019 d4: "New shared.staff_tenant_assignment (owner, backup or support; one owner per tenant). Every
-- {tenant_id} route uses the require_tenant_scope dependency" (api/core/tenant_scope.py): a customer_success manager
-- sees only the tenants assigned to them, support also the pool of tenants without an owner. d5: "View as tenant" is
-- read-only, at most 60 minutes, needs a reason or ticket, and is logged in shared.staff_view_as_session. The view-as
-- endpoint and banner come in R2 slice 2; the table is created now so the log exists before anything writes it.
-- The DM-7.1 retention rows are in the root repo (merged before this copy).
--
-- What.
--   1. shared.staff_tenant_assignment (admin_user_id -> shared.admin_users(id) ON DELETE CASCADE, tenant_id ->
--      shared.tenants(tenant_id) ON DELETE CASCADE, kind owner | backup | support, created_at, created_by; PK
--      (admin_user_id, tenant_id): one assignment per person and tenant). A partial unique index allows at most one
--      'owner' per tenant. No rows: an admin assigns through the API (PUT /admin/tenants/{tenant_id}/assignments/
--      {admin_user_id}, audited).
--   2. shared.staff_view_as_session (session_id, admin_user_id -> shared.admin_users(id) ON DELETE RESTRICT so the
--      log outlives a disabled account, tenant_id -> shared.tenants ON DELETE CASCADE, reason 3-500 chars,
--      ticket_ref, started_at, expires_at at most 60 minutes after the start, ended_at, end_reason ended | expired |
--      revoked). Two lookup indexes. No rows.
--   3. A guard trigger keeps the session log append-only in the database, whoever writes: UPDATE only ends an open
--      session (ended_at / end_reason set once, every other column unchanged); DELETE only the rows of an
--      offboarded or deleted tenant (shared.tenant_account_closed, CIS 353: the AA-839 erasure and the FK cascade
--      from shared.tenants); TRUNCATE refused.
--   4. Grants. REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner first: the Dev default ACL of cis_owner
--      in shared (CIS 245) gives cis_app DELETE, INSERT, SELECT, UPDATE on every new table, so a plain GRANT would
--      not narrow anything (as CIS 353 item 11). Then cis_app: SELECT, INSERT, DELETE on the assignment table (a
--      change of kind is a delete + insert in one transaction; no UPDATE); SELECT, INSERT, UPDATE, DELETE on the
--      session log, the guard limiting UPDATE and DELETE as above. DELETE is needed because the AA-839 erasure
--      deletes the tenant's rows explicitly as cis_app (services/erasure/inventory.py, action delete; Postgres
--      checks the privilege even for 0 rows); no endpoint deletes a session. Nothing for aa_app_user or
--      catalog_owner. No RLS, like shared.staff_app_grant / shared.staff_crm_grant: staff tables, read only by the
--      staff API, never by a tenant role (rls_catalogue_rules rule a allowlist).
--   5. Register 364.
--
-- Class: contract (root ADR 0017 d3). The content is additive (two new tables, their constraints, indexes, guard
-- trigger, grants and comments; the FKs only add the internal RI triggers on shared.admin_users and shared.tenants;
-- no row in an existing table except the schema_versions registration), but the file needs what the expand lint
-- refuses: REVOKE ALL (see 4) and CREATE OR REPLACE / DROP TRIGGER IF EXISTS (a re-run is a no-op). It ships with
-- the contract files 362 / 363 in one migration-only PR (MIG-4), so the class costs nothing; applied after them
-- (strict number order) once every job table is idle.
--
-- Behaviour on apply: none. The code reads the assignment table only from the R2 code PR (readiness requires 362-364).
--
-- Rollback (a new forward migration, after the code is reverted; destructive file, DRY RUN first):
--   DROP TABLE shared.staff_view_as_session; DROP TABLE shared.staff_tenant_assignment;
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.staff_tenant_assignment (
    admin_user_id  uuid        NOT NULL,
    tenant_id      uuid        NOT NULL,
    kind           text        NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     text        NOT NULL,
    CONSTRAINT staff_tenant_assignment_pkey PRIMARY KEY (admin_user_id, tenant_id),
    CONSTRAINT staff_tenant_assignment_admin_user_id_fkey FOREIGN KEY (admin_user_id)
        REFERENCES shared.admin_users (id) ON DELETE CASCADE,
    CONSTRAINT staff_tenant_assignment_tenant_id_fkey FOREIGN KEY (tenant_id)
        REFERENCES shared.tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT staff_tenant_assignment_kind_chk CHECK (kind IN ('owner', 'backup', 'support')),
    CONSTRAINT staff_tenant_assignment_created_by_chk CHECK (char_length(created_by) BETWEEN 1 AND 64)
);

CREATE UNIQUE INDEX IF NOT EXISTS staff_tenant_assignment_one_owner_key
    ON shared.staff_tenant_assignment (tenant_id) WHERE kind = 'owner';
CREATE INDEX IF NOT EXISTS staff_tenant_assignment_tenant_idx
    ON shared.staff_tenant_assignment (tenant_id);

COMMENT ON TABLE shared.staff_tenant_assignment IS
    'AA-1035 (CIS 364, root ADR 0019 d4): which AA staff member looks after which tenant. kind owner (the account '
    'manager, at most one per tenant), backup or support. Read by api/core/tenant_scope.py (customer_success sees its '
    'assigned tenants, support its assigned tenants and the pool without an owner); written only by the admin '
    'assignment routes (audited tenant.assignment_set / tenant.assignment_removed in acp_shared.audit_log).';
COMMENT ON COLUMN shared.staff_tenant_assignment.kind IS
    'AA-1035 (364): owner = the account manager (one per tenant), backup = stands in for the owner, support = the '
    'support person of the tenant.';
COMMENT ON COLUMN shared.staff_tenant_assignment.created_by IS
    'AA-1035 (364): the staff actor of the assignment, admin:<admin_users.id> (the audit actor format).';

CREATE TABLE IF NOT EXISTS shared.staff_view_as_session (
    session_id     uuid        NOT NULL DEFAULT gen_random_uuid(),
    admin_user_id  uuid        NOT NULL,
    tenant_id      uuid        NOT NULL,
    reason         text        NOT NULL,
    ticket_ref     text,
    started_at     timestamptz NOT NULL DEFAULT now(),
    expires_at     timestamptz NOT NULL,
    ended_at       timestamptz,
    end_reason     text,
    CONSTRAINT staff_view_as_session_pkey PRIMARY KEY (session_id),
    CONSTRAINT staff_view_as_session_admin_user_id_fkey FOREIGN KEY (admin_user_id)
        REFERENCES shared.admin_users (id) ON DELETE RESTRICT,
    CONSTRAINT staff_view_as_session_tenant_id_fkey FOREIGN KEY (tenant_id)
        REFERENCES shared.tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT staff_view_as_session_reason_chk CHECK (char_length(btrim(reason)) BETWEEN 3 AND 500),
    CONSTRAINT staff_view_as_session_ticket_chk CHECK (ticket_ref IS NULL OR char_length(ticket_ref) BETWEEN 1 AND 120),
    CONSTRAINT staff_view_as_session_window_chk CHECK (
        expires_at > started_at AND expires_at <= started_at + interval '60 minutes'),
    CONSTRAINT staff_view_as_session_end_chk CHECK (
        (ended_at IS NULL AND end_reason IS NULL)
        OR (ended_at IS NOT NULL AND ended_at >= started_at AND end_reason IN ('ended', 'expired', 'revoked')))
);

CREATE INDEX IF NOT EXISTS staff_view_as_session_staff_idx
    ON shared.staff_view_as_session (admin_user_id, started_at DESC);
CREATE INDEX IF NOT EXISTS staff_view_as_session_tenant_idx
    ON shared.staff_view_as_session (tenant_id, started_at DESC);

COMMENT ON TABLE shared.staff_view_as_session IS
    'AA-1035 (CIS 364, root ADR 0019 d5): one row per read-only "view as tenant" session of an AA staff member: '
    'who, which tenant, the reason or ticket, start, expiry (at most 60 minutes) and end. Append-only (guard '
    'trigger): an UPDATE only ends an open session, a DELETE only removes the rows of an offboarded or deleted tenant '
    '(AA-839 erasure, FK cascade). Schema only in R2 slice 1; the writer comes with the view-as slice.';
COMMENT ON COLUMN shared.staff_view_as_session.reason IS
    'pii:free_text; AA-1035 (364): why the staff member opened the view (typed by staff, may name a person).';
COMMENT ON COLUMN shared.staff_view_as_session.ticket_ref IS
    'AA-1035 (364): an optional support ticket reference.';

-- ── Guard: the session log is append-only (an end once; deletes only for a closed tenant) ──────────────────────────
CREATE OR REPLACE FUNCTION shared.staff_view_as_session_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
BEGIN
    IF TG_OP = 'TRUNCATE' THEN
        RAISE EXCEPTION 'shared.staff_view_as_session is append-only: TRUNCATE refused'
            USING ERRCODE = 'restrict_violation';
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.ended_at IS NOT NULL OR NEW.ended_at IS NULL
           OR (NEW.session_id, NEW.admin_user_id, NEW.tenant_id, NEW.reason, NEW.ticket_ref, NEW.started_at,
               NEW.expires_at)
              IS DISTINCT FROM
              (OLD.session_id, OLD.admin_user_id, OLD.tenant_id, OLD.reason, OLD.ticket_ref, OLD.started_at,
               OLD.expires_at) THEN
            RAISE EXCEPTION 'shared.staff_view_as_session: an UPDATE only ends an open session'
                USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
    END IF;
    -- DELETE: only the rows of an offboarded or deleted tenant (AA-839 erasure, FK cascade; DM-7.1 row).
    IF NOT shared.tenant_account_closed(OLD.tenant_id) THEN
        RAISE EXCEPTION 'shared.staff_view_as_session: a session of a live tenant is never deleted'
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN OLD;
END
$$;

DROP TRIGGER IF EXISTS staff_view_as_session_guard ON shared.staff_view_as_session;
CREATE TRIGGER staff_view_as_session_guard
    BEFORE UPDATE OR DELETE ON shared.staff_view_as_session
    FOR EACH ROW EXECUTE FUNCTION shared.staff_view_as_session_guard();
DROP TRIGGER IF EXISTS staff_view_as_session_no_truncate ON shared.staff_view_as_session;
CREATE TRIGGER staff_view_as_session_no_truncate
    BEFORE TRUNCATE ON shared.staff_view_as_session
    FOR EACH STATEMENT EXECUTE FUNCTION shared.staff_view_as_session_guard();

-- ── Grants (REVOKE first: the Dev default ACL of cis_owner in shared, CIS 245) ─────────────────────────────────────
REVOKE ALL ON shared.staff_tenant_assignment, shared.staff_view_as_session
    FROM PUBLIC, cis_app, aa_app_user, catalog_owner;
GRANT SELECT, INSERT, DELETE ON shared.staff_tenant_assignment TO cis_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.staff_view_as_session TO cis_app;
-- The trigger function runs as the writer (cis_app); nobody calls it directly.
REVOKE ALL ON FUNCTION shared.staff_view_as_session_guard() FROM PUBLIC;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('364', now(), 'AA-1035: shared.staff_tenant_assignment + shared.staff_view_as_session (root ADR 0019 d4 / d5)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
