-- Migration crm-011: AA-941 (partner CRM, design v3 card CRM-13a) — the L1 platform console's two data needs: the AA
-- insights opt-out an agency asks for (Q2 3.12), and agency export / deletion requests that AA raises and the owner
-- confirms (S-01 "raise export/delete requests that the owner confirms").
--
-- Owner: AA-Partner (api/migrations/011_crm_l1_console.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-011.
--
-- Why. Design v3 §1 row S-01 (L1 console: "set the insights opt-out on the owner's request; raise export/delete
-- requests that the owner confirms"), Q2 3.12 (insights included by default, opt-out by request: an L1 action, not an
-- owner switch), §4.10 (offboarding stays the owner's decision). No new table: a new tenant table would also have to
-- join crm.erase_subject's keep list or delete steps, or the agency erase fails with CRM16.
--
-- What:
--   1. crm.tenant_entitlement.insights_opt_out BOOLEAN NOT NULL DEFAULT false. The existing trigger
--      tenant_entitlement_platform_only (crm-008, crm.guard_platform_write, every column) already makes the table
--      platform-only, so a member write is refused with CRM04 and no new guard is needed. Deliberate deviation from
--      design §3.3, which lists the flag on tenant_settings (owner-writable, would need a column guard there):
--      Q2 3.12 makes it an AA action on the owner's written request (docs/implementation-notes/AA-941.md).
--   2. crm.erasure_request.purpose TEXT NOT NULL DEFAULT 'offboard', CHECK purpose IN (offboard, export_only) and
--      export_only only for scope tenant; crm.erasure_request.owner_accepted_at TIMESTAMPTZ. No backfill (FORCE RLS
--      hides the rows from this file anyway): "awaiting the owner" is requested_by LIKE 'platform:%' AND
--      owner_accepted_at IS NULL, so every row an owner made stays valid as it is.
--   3. crm.guard_erasure_request_owner_confirm() (BEFORE INSERT OR UPDATE, every column), SQLSTATE CRM18:
--      a. requested_by starts with platform: exactly when the inserting actor is a platform actor (nobody forges an
--         AA request, AA never files one in a member's name);
--      b. a platform INSERT is scope tenant, status requested, owner_accepted_at NULL, export_waived false,
--         confirmed_by NULL; nobody inserts a row already accepted;
--      c. owner_accepted_at moves NULL -> a value only for a platform-raised row still requested, only when app.actor
--         is member:* and app.member_role = 'owner', without a status move in the same statement; it never changes
--         again;
--      d. purpose and requested_by are fixed;
--      e. while a platform-raised row is unaccepted, the only status move is to cancelled (the owner declines), and
--         confirmed_by / export_waived / dry_run_counts stay as they are except in the accepting UPDATE itself;
--      f. a purpose export_only row never moves to erasing;
--      g. a platform actor never confirms or runs a request: it never sets confirmed_by and never moves a row to
--         erasing or erased (the AA-942 platform recovery moves erasing -> failed, which stays allowed).
--      An unscoped session (no app.actor, not crm_app: a migration, the master's run-script) is not restricted, like
--      the crm-008 guards.
--
-- Order: after crm-008 (AA-939) and crm-010 (AA-942); Guard 0 refuses to run before both are registered.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14). Before AA-941 deploys
-- nothing reads the new columns; the trigger refuses only writes no deployed code makes (no code inserts a
-- platform-raised request or sets owner_accepted_at yet).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-008 and crm-010 ────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-011: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-008') THEN
        RAISE EXCEPTION 'crm-011: crm-008 is not registered (F4 roles, AA-939, lands first)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-010') THEN
        RAISE EXCEPTION 'crm-011: crm-010 is not registered (data lifecycle, AA-942, lands first)';
    END IF;
END $$;

-- ── 1. Insights opt-out (Q2 3.12) ────────────────────────────────────────────────────────────────
ALTER TABLE crm.tenant_entitlement ADD COLUMN IF NOT EXISTS insights_opt_out BOOLEAN NOT NULL DEFAULT false;
COMMENT ON COLUMN crm.tenant_entitlement.insights_opt_out IS 'AA-941 (crm-011, Q2 3.12): true = the agency is left out of AA insights (crm.v_insight_fact consumers, AA-966, must exclude it). Written only by the L1 console action on the owner''s written request (platform-only through tenant_entitlement_platform_only, CRM04); default false = included.';

-- ── 2. AA-raised data requests on crm.erasure_request ────────────────────────────────────────────
ALTER TABLE crm.erasure_request ADD COLUMN IF NOT EXISTS purpose TEXT NOT NULL DEFAULT 'offboard';
ALTER TABLE crm.erasure_request ADD COLUMN IF NOT EXISTS owner_accepted_at TIMESTAMPTZ;
ALTER TABLE crm.erasure_request DROP CONSTRAINT IF EXISTS erasure_request_purpose_chk;
ALTER TABLE crm.erasure_request ADD CONSTRAINT erasure_request_purpose_chk
    CHECK (purpose IN ('offboard', 'export_only') AND (purpose = 'offboard' OR scope = 'tenant'));
COMMENT ON COLUMN crm.erasure_request.purpose IS 'AA-941 (crm-011): offboard (export then erase, the owner flow of AA-942) | export_only (an agency export AA raised; never moves to erasing). Fixed once inserted.';
COMMENT ON COLUMN crm.erasure_request.owner_accepted_at IS 'AA-941 (crm-011): when the owner confirmed a request AA raised (requested_by platform:*); NULL on such a row = awaiting the owner. Set once, by the owner only (crm.guard_erasure_request_owner_confirm, CRM18). Always NULL on a request the owner made.';

CREATE OR REPLACE FUNCTION crm.guard_erasure_request_owner_confirm() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    actor     text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    role      text := COALESCE(NULLIF(current_setting('app.member_role', true), ''), '');
    unscoped  boolean := actor = '' AND current_user::text <> 'crm_app';
    platform  boolean := actor LIKE 'platform:%';
    accepting boolean;
BEGIN
    IF unscoped THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF platform <> (NEW.requested_by LIKE 'platform:%') THEN
            RAISE EXCEPTION 'crm: requested_by must name the inserting actor''s kind (platform requests only from AA)'
                USING ERRCODE = 'CRM18';
        END IF;
        IF NEW.owner_accepted_at IS NOT NULL THEN
            RAISE EXCEPTION 'crm: a request is never inserted already accepted' USING ERRCODE = 'CRM18';
        END IF;
        IF platform AND (NEW.scope <> 'tenant' OR NEW.status <> 'requested' OR NEW.export_waived
                         OR NEW.confirmed_by IS NOT NULL) THEN
            RAISE EXCEPTION 'crm: AA raises an agency request (scope tenant, requested, no waiver, unconfirmed) only'
                USING ERRCODE = 'CRM18';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.purpose IS DISTINCT FROM OLD.purpose OR NEW.requested_by IS DISTINCT FROM OLD.requested_by THEN
        RAISE EXCEPTION 'crm: purpose and requested_by of a request are fixed' USING ERRCODE = 'CRM18';
    END IF;
    IF OLD.owner_accepted_at IS NOT NULL AND NEW.owner_accepted_at IS DISTINCT FROM OLD.owner_accepted_at THEN
        RAISE EXCEPTION 'crm: owner_accepted_at is set once' USING ERRCODE = 'CRM18';
    END IF;
    accepting := OLD.owner_accepted_at IS NULL AND NEW.owner_accepted_at IS NOT NULL;
    IF accepting AND NOT (actor LIKE 'member:%' AND role = 'owner') THEN
        RAISE EXCEPTION 'crm: only the agency owner confirms a request AA raised' USING ERRCODE = 'CRM18';
    END IF;
    IF accepting AND (OLD.requested_by NOT LIKE 'platform:%' OR OLD.status <> 'requested'
                      OR NEW.status IS DISTINCT FROM OLD.status) THEN
        RAISE EXCEPTION 'crm: only a requested AA-raised request is confirmed, without a status move'
            USING ERRCODE = 'CRM18';
    END IF;
    IF OLD.requested_by LIKE 'platform:%' AND OLD.owner_accepted_at IS NULL AND NOT accepting THEN
        IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status <> 'cancelled' THEN
            RAISE EXCEPTION 'crm: a request AA raised waits for the owner (only a cancel moves it)'
                USING ERRCODE = 'CRM18';
        END IF;
        IF NEW.confirmed_by IS DISTINCT FROM OLD.confirmed_by OR NEW.export_waived IS DISTINCT FROM OLD.export_waived
           OR NEW.dry_run_counts IS DISTINCT FROM OLD.dry_run_counts THEN
            RAISE EXCEPTION 'crm: a request AA raised changes only when the owner confirms it' USING ERRCODE = 'CRM18';
        END IF;
    END IF;
    IF NEW.purpose = 'export_only' AND NEW.status = 'erasing' AND OLD.status IS DISTINCT FROM 'erasing' THEN
        RAISE EXCEPTION 'crm: an export-only request never erases' USING ERRCODE = 'CRM18';
    END IF;
    IF platform AND (NEW.confirmed_by IS DISTINCT FROM OLD.confirmed_by
                     OR (NEW.status IN ('erasing', 'erased') AND NEW.status IS DISTINCT FROM OLD.status)) THEN
        RAISE EXCEPTION 'crm: AA never confirms or runs an agency request' USING ERRCODE = 'CRM18';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_erasure_request_owner_confirm() FROM PUBLIC;
CREATE OR REPLACE TRIGGER erasure_request_owner_confirm
    BEFORE INSERT OR UPDATE ON crm.erasure_request
    FOR EACH ROW EXECUTE FUNCTION crm.guard_erasure_request_owner_confirm();
COMMENT ON FUNCTION crm.guard_erasure_request_owner_confirm() IS 'AA-941 (crm-011): AA raises agency export / deletion requests, only the owner confirms them (owner_accepted_at, once), an unconfirmed AA request only gets cancelled, export_only never erases, AA never confirms or runs one. SQLSTATE CRM18. Unscoped sessions are not restricted.';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                    WHERE a.attrelid = 'crm.tenant_entitlement'::regclass AND a.attname = 'insights_opt_out'
                      AND a.atttypid = 'boolean'::regtype AND a.attnotnull AND NOT a.attisdropped) THEN
        RAISE EXCEPTION 'crm-011: crm.tenant_entitlement.insights_opt_out must be BOOLEAN NOT NULL';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                    WHERE a.attrelid = 'crm.erasure_request'::regclass AND a.attname = 'purpose'
                      AND a.atttypid = 'text'::regtype AND a.attnotnull AND NOT a.attisdropped)
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                       WHERE a.attrelid = 'crm.erasure_request'::regclass AND a.attname = 'owner_accepted_at'
                         AND a.atttypid = 'timestamptz'::regtype AND NOT a.attisdropped) THEN
        RAISE EXCEPTION 'crm-011: crm.erasure_request.purpose / owner_accepted_at are missing or mistyped';
    END IF;
    -- The opt-out relies on the crm-008 platform-only trigger firing on every column of tenant_entitlement.
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger tg
                    WHERE tg.tgrelid = 'crm.tenant_entitlement'::regclass AND tg.tgname = 'tenant_entitlement_platform_only'
                      AND tg.tgfoid = 'crm.guard_platform_write()'::regprocedure
                      AND cardinality(tg.tgattr::int2[]) = 0) THEN
        RAISE EXCEPTION 'crm-011: tenant_entitlement_platform_only must guard every column of crm.tenant_entitlement';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger tg
                    WHERE tg.tgrelid = 'crm.erasure_request'::regclass AND tg.tgname = 'erasure_request_owner_confirm'
                      AND tg.tgfoid = 'crm.guard_erasure_request_owner_confirm()'::regprocedure
                      AND cardinality(tg.tgattr::int2[]) = 0 AND tg.tgtype & 4 = 4 AND tg.tgtype & 16 = 16) THEN
        RAISE EXCEPTION 'crm-011: erasure_request_owner_confirm must fire on every INSERT and UPDATE';
    END IF;
    IF pg_catalog.has_function_privilege('public', 'crm.guard_erasure_request_owner_confirm()', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-011: crm.guard_erasure_request_owner_confirm() is executable by PUBLIC (SEC-4)';
    END IF;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.erasure_request', 'DELETE')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.tenant_entitlement', 'DELETE') THEN
        RAISE EXCEPTION 'crm-011: crm_app may delete from crm.erasure_request / crm.tenant_entitlement';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-011', now(), 'AA-941: L1 console (insights opt-out, AA-raised data requests)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
