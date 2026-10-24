-- Migration 276: AA-978 (CRM-P1) — the CIS membership directory (shared.tenant_members) and its append-only event
-- feed (shared.tenant_membership_event), the storage behind contract tenant.membership.v1.
--
-- Why. Root ADR 0006b decision 4 / ADR 0010 decision 5 and contract tenant.membership.v1 (root
-- docs/contracts/tenant.membership.v1.openapi.yaml): CIS is the directory of agencies and of who belongs to them; the
-- partner CRM (AA-Partner) learns "identity (iss, sub) belongs to agency X, Content studio role R" and every agency
-- lifecycle change over HTTP (/tenant/membership/v1, M2M scope cis.tenant/read). Today CIS has no membership table
-- (schema reference 24/10/2026: no tenant_member*), and nothing records when an agency is locked, unlocked or
-- offboarded in a form another app can follow. The routes arrive with the AA-978 code PR; this file is storage only.
--
-- What.
--   1. shared.tenant_members (data standards DM-1.5 kernel list): membership_id uuid PK; tenant_id FK shared.tenants;
--      cognito_iss / cognito_sub (pii:online_id; NULL exactly while invited: the identity binds at activation, ADR
--      0006b decision 5); content_studio_role owner | editor | viewer (never a CRM role: no column for one);
--      status invited | active | removed; invitation_id (required while invited); created_at / created_by /
--      updated_at / removed_at / removed_by. No e-mail and no name column (AA-813 addendum: only when a reader needs
--      it). One live (not removed) row per (tenant_id, cognito_iss, cognito_sub) (partial unique index), an index on
--      (cognito_iss, cognito_sub) for the identity lookup.
--   2. shared.tenant_membership_event: the feed. seq bigint identity PK; event_id uuid UNIQUE; txid xid8 DEFAULT
--      pg_current_xact_id() (the writing transaction, for the feed's snapshot horizon); type, one of the 8 contract
--      enums; tenant_id (no FK: the event outlives a hard-deleted tenant row, and test cleanups delete tenants);
--      membership jsonb (the contract Membership shape, ids only; set exactly for membership.* events);
--      occurred_at. Index (txid, seq): the feed reads `WHERE txid < pg_snapshot_xmin(pg_current_snapshot())
--      AND (txid, seq) > cursor ORDER BY txid, seq`. Ordering by txid first is what makes the cursor safe: every
--      transaction that can still commit has txid >= the horizon, so a late commit always sorts after the cursor
--      (ordering by seq alone would skip an event whose transaction took its xid after a served one but its seq
--      before it).
--   3. Triggers that write the feed (AFTER, FOR EACH ROW; plpgsql, NOT SECURITY DEFINER (MIG-6), search_path pinned):
--        shared.tenant_members  INSERT  invited -> membership.invited, active -> membership.activated;
--                               UPDATE  status to active -> membership.activated, to removed -> membership.removed,
--                                       else a content_studio_role change -> membership.role_changed;
--        shared.tenants         INSERT  tenant.created (then tenant.locked / tenant.deleted when inserted so);
--                               UPDATE OF is_active, cancelled_at, when the agency state changes:
--                                       state = deleted (cancelled_at set) | locked (is_active false) | active;
--                                       -> deleted: tenant.deleted, -> locked: tenant.locked, -> active:
--                                       tenant.unlocked (also after a restore of an offboarded tenant).
--      This catches every write path in api/routers/admin.py (create, PATCH is_active, offboard, restore) and any
--      later one without touching them. A posts_per_week / plan / key change fires nothing (column list + WHEN).
--   4. Guards (BEFORE triggers):
--        tenant_members  INSERT never as removed; UPDATE: membership_id, tenant_id, invitation_id, created_* never
--                        change, removed is final, active never goes back to invited, the identity is bound once
--                        (invited -> active) and never changes after; DELETE only of a removed row 90 days after
--                        removed_at, or when the tenant is offboarded (cancelled_at set) or gone: the AA-839
--                        erasure and the DM-7 retention. A silent DELETE of a live member would revoke nobody in
--                        the CRM.
--        membership_event  INSERT only from the triggers above (pg_trigger_depth() >= 2); UPDATE never; TRUNCATE
--                        never; DELETE only 90 days after occurred_at or when the tenant is offboarded or gone
--                        (DM-7 row S250 R2: retention 90 days, and the tenant erasure).
--      All raise restrict_violation (23001).
--   5. Grants. REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner first (it also takes away the DML that
--      the Dev default ACL of cis_owner gives cis_app on every new table in shared, CIS 245; SCHEDULE S250 §5 point
--      3), then cis_app: tenant_members SELECT, INSERT, UPDATE, DELETE (DELETE for the erasure; the guard limits
--      it); tenant_membership_event SELECT, INSERT (INSERT because the triggers run as the writing role), DELETE
--      (retention / erasure; the guard limits it). Nothing on the identity sequence (an identity column's nextval
--      does not check sequence privileges). Nothing for aa_app_user (AA-859 invariant: no tenant-pool privilege on a
--      relation without RLS) or catalog_owner (catalog.v_tenant_member is deferred: the CRM reads over HTTP, root
--      ADR 0008a decision 1, AA-813 addendum option 2). No RLS: cis_app is the only reader (rls_catalogue_rules
--      rule a allowlist, like shared.tenants). EXECUTE on the four functions revoked from PUBLIC (a firing trigger
--      does not check EXECUTE).
--      Trigger privileges (SCHEDULE §5 AA-978). The triggers run as the role that writes shared.tenants /
--      tenant_members, so that role needs INSERT on the event table. On Dev only cis_app (and the owner and the
--      master, a member of cis_app) may write shared.tenants (schema reference 24/10: grant cis_app only;
--      aa_app_user has no privilege there), and cis_app gets INSERT here. Guard 2 refuses the file if any role with
--      INSERT or UPDATE on shared.tenants (table or column level) could not insert an event, so a later grant to a
--      new writer must come with the event grant.
--   6. Register 276.
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before: roles cis_app, aa_app_user, catalog_owner exist; the runner may create in shared; shared.tenants has
--      is_active boolean and cancelled_at timestamptz; the two tables, if present, have exactly this file's columns;
--   2. after: every named constraint validated; the seven triggers; the indexes; privileges exactly as in point 5
--      for PUBLIC, cis_app, aa_app_user and catalog_owner (no column-level grant); every writer of shared.tenants
--      can insert an event; the four functions are not SECURITY DEFINER, pin search_path and give PUBLIC no EXECUTE;
--   3. behaviour (a probe tenant in a sub-block that is always rolled back): create / lock / unlock / offboard /
--      restore emit the right tenant.* events; invite / activate / role change / remove emit the membership.* events
--      with the contract Membership shape; a direct event insert, an event update and the delete of a live member
--      are refused; a second live row of one identity violates the unique index.
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: both NULL):
--   SELECT to_regclass('shared.tenant_members') AS members, to_regclass('shared.tenant_membership_event') AS events;
--
-- Locks. CREATE TRIGGER on shared.tenants takes SHARE ROW EXCLUSIVE until COMMIT (blocks tenant writes for the few
-- milliseconds of the file; reads go on). lock_timeout 5s: fail fast and re-run when idle. Apply through AA-CIS-Infra
-- DB Migrate (byte copy in db/migrations/cis/) with the job tables idle (DM-11.4). Re-running is a no-op apart from
-- the guards.
--
-- Order. Independent of 275 (AA-977), applied after it (keys in order). Nothing reads these objects until the AA-978
-- code PR (/tenant/membership/v1, the Tenant 360 member routes) deploys, and that code needs them: merge this file's
-- PR, copy to Infra, DB Migrate check -> apply, merge the schema-reference bot PR, then merge and deploy the code PR.
-- From the apply on, every tenant create / lock / unlock / offboard / restore writes one event row (a handful a
-- month on Dev).
--
-- Undo (a NEW forward migration, before the code is deployed): DROP TRIGGER tenants_membership_feed_ins /
-- tenants_membership_feed_upd ON shared.tenants; DROP TABLE shared.tenant_membership_event; DROP TABLE
-- shared.tenant_members; DROP FUNCTION shared.tenant_membership_emit_tenant(), shared.tenant_membership_emit_member(),
-- shared.tenant_members_guard(), shared.tenant_membership_event_guard().
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243). DB Migrate runs cis/ files as cis_owner, the owner
-- of shared (245).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── Guard 1: roles, runner rights, shared.tenants shape, re-run shape ──────────────────────────────────────────────
DO $$
DECLARE
    owner_ns    name;
    cols        text;
    mem_expect  text := 'membership_id uuid, tenant_id uuid, cognito_iss text, cognito_sub text, content_studio_role '
                        'text, status text, invitation_id uuid, created_at timestamp with time zone, created_by text, '
                        'updated_at timestamp with time zone, removed_at timestamp with time zone, removed_by text';
    ev_expect   text := 'seq bigint, event_id uuid, txid xid8, type text, tenant_id uuid, membership jsonb, '
                        'occurred_at timestamp with time zone';
BEGIN
    IF to_regrole('cis_app') IS NULL OR to_regrole('aa_app_user') IS NULL OR to_regrole('catalog_owner') IS NULL THEN
        RAISE EXCEPTION 'migration 276: roles cis_app, aa_app_user and catalog_owner must exist';
    END IF;
    SELECT pg_get_userbyid(n.nspowner) INTO owner_ns FROM pg_namespace n WHERE n.nspname = 'shared';
    IF NOT has_schema_privilege(current_user, 'shared', 'CREATE') THEN
        RAISE EXCEPTION 'migration 276: % may not create in shared (owner %); run it through DB Migrate (cis_owner)',
                        current_user, owner_ns;
    END IF;
    IF (SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
         WHERE a.attrelid = 'shared.tenants'::regclass AND a.attname = 'is_active' AND NOT a.attisdropped)
           IS DISTINCT FROM 'boolean'
       OR (SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
            WHERE a.attrelid = 'shared.tenants'::regclass AND a.attname = 'cancelled_at' AND NOT a.attisdropped)
           IS DISTINCT FROM 'timestamp with time zone' THEN
        RAISE EXCEPTION 'migration 276: shared.tenants needs is_active boolean and cancelled_at timestamptz';
    END IF;

    IF to_regclass('shared.tenant_members') IS NOT NULL THEN
        SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
          INTO cols
          FROM pg_attribute a
         WHERE a.attrelid = 'shared.tenant_members'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
        IF cols IS DISTINCT FROM mem_expect THEN
            RAISE EXCEPTION 'migration 276: shared.tenant_members exists with other columns: %', cols;
        END IF;
    END IF;
    IF to_regclass('shared.tenant_membership_event') IS NOT NULL THEN
        SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
          INTO cols
          FROM pg_attribute a
         WHERE a.attrelid = 'shared.tenant_membership_event'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
        IF cols IS DISTINCT FROM ev_expect THEN
            RAISE EXCEPTION 'migration 276: shared.tenant_membership_event exists with other columns: %', cols;
        END IF;
    END IF;
END $$;

-- ── 1. The membership directory ────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.tenant_members (
    membership_id       uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    cognito_iss         text,
    cognito_sub         text,
    content_studio_role text NOT NULL,
    status              text NOT NULL,
    invitation_id       uuid,
    created_at          timestamp with time zone NOT NULL DEFAULT now(),
    created_by          text NOT NULL,
    updated_at          timestamp with time zone NOT NULL DEFAULT now(),
    removed_at          timestamp with time zone,
    removed_by          text,
    CONSTRAINT tenant_members_pkey PRIMARY KEY (membership_id),
    CONSTRAINT tenant_members_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES shared.tenants (tenant_id),
    CONSTRAINT tenant_members_role_check CHECK (content_studio_role IN ('owner', 'editor', 'viewer')),
    CONSTRAINT tenant_members_status_check CHECK (status IN ('invited', 'active', 'removed')),
    CONSTRAINT tenant_members_identity_check
        CHECK ((cognito_iss IS NULL) = (cognito_sub IS NULL)
               AND (status <> 'invited' OR cognito_iss IS NULL)
               AND (status <> 'active' OR cognito_iss IS NOT NULL)),
    CONSTRAINT tenant_members_identity_shape_check
        CHECK (cognito_iss IS NULL
               OR (cognito_iss LIKE 'https://%' AND char_length(cognito_iss) <= 300
                   AND char_length(cognito_sub) BETWEEN 1 AND 128)),
    CONSTRAINT tenant_members_invitation_check CHECK (status <> 'invited' OR invitation_id IS NOT NULL),
    CONSTRAINT tenant_members_removed_check
        CHECK ((status = 'removed') = (removed_at IS NOT NULL) AND (removed_at IS NULL) = (removed_by IS NULL)),
    CONSTRAINT tenant_members_actor_check
        CHECK (char_length(created_by) BETWEEN 1 AND 64
               AND (removed_by IS NULL OR char_length(removed_by) BETWEEN 1 AND 64))
);

CREATE UNIQUE INDEX IF NOT EXISTS tenant_members_live_identity_key
    ON shared.tenant_members (tenant_id, cognito_iss, cognito_sub) WHERE status <> 'removed';
CREATE INDEX IF NOT EXISTS tenant_members_identity_idx
    ON shared.tenant_members (cognito_iss, cognito_sub) WHERE cognito_iss IS NOT NULL;

COMMENT ON TABLE shared.tenant_members IS
    'AA-978 (CIS 276): who belongs to which agency (tenant) in CIS, with the Content studio role (owner / editor / '
    'viewer; never a CRM role). Keyed by the partner-pool identity (cognito_iss, cognito_sub), bound at activation. '
    'Every insert / status / role change writes shared.tenant_membership_event (contract tenant.membership.v1, served '
    'at /tenant/membership/v1 to AA-Partner). Owner CIS; cis_app only, no tenant-pool grant. No e-mail or name.';
COMMENT ON COLUMN shared.tenant_members.cognito_iss IS
    'pii:online_id; AA-978 (276): issuer of the member''s partner-pool identity (ADR 0006 §9: the key is (iss, sub)). '
    'NULL exactly while invited; bound once at activation.';
COMMENT ON COLUMN shared.tenant_members.cognito_sub IS
    'pii:online_id; AA-978 (276): sub of the member''s partner-pool identity. Set together with cognito_iss.';
COMMENT ON COLUMN shared.tenant_members.content_studio_role IS
    'AA-978 (276): CIS Content studio role owner | editor | viewer. Not a CRM role: the CRM never derives one from it.';
COMMENT ON COLUMN shared.tenant_members.status IS
    'AA-978 (276): invited -> active -> removed (removed is final; re-adding a person is a new row).';
COMMENT ON COLUMN shared.tenant_members.created_by IS
    'Who created the row: admin:<shared.admin_users id>, seed:AA-978 or a later flow label. A label, not a name or '
    'an e-mail address.';

-- ── 2. The event feed ──────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.tenant_membership_event (
    seq         bigint GENERATED ALWAYS AS IDENTITY,
    event_id    uuid NOT NULL DEFAULT gen_random_uuid(),
    txid        xid8 NOT NULL DEFAULT pg_current_xact_id(),
    type        text NOT NULL,
    tenant_id   uuid NOT NULL,
    membership  jsonb,
    occurred_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT tenant_membership_event_pkey PRIMARY KEY (seq),
    CONSTRAINT tenant_membership_event_event_id_key UNIQUE (event_id),
    CONSTRAINT tenant_membership_event_type_check
        CHECK (type IN ('tenant.created', 'tenant.locked', 'tenant.unlocked', 'tenant.deleted', 'membership.invited',
                        'membership.activated', 'membership.role_changed', 'membership.removed')),
    CONSTRAINT tenant_membership_event_membership_check
        CHECK ((type LIKE 'membership.%') = (membership IS NOT NULL)
               AND (membership IS NULL OR jsonb_typeof(membership) = 'object'))
);

CREATE INDEX IF NOT EXISTS tenant_membership_event_feed_idx ON shared.tenant_membership_event (txid, seq);

COMMENT ON TABLE shared.tenant_membership_event IS
    'AA-978 (CIS 276): append-only feed of contract tenant.membership.v1 (agency lifecycle + membership changes), '
    'written only by the triggers on shared.tenants and shared.tenant_members. Served oldest first by (txid, seq) '
    'below the snapshot horizon pg_snapshot_xmin(pg_current_snapshot()), so no event is skipped. UPDATE / TRUNCATE '
    'never; DELETE only after 90 days or for an offboarded tenant (DM-7 retention, AA-839 erasure).';
COMMENT ON COLUMN shared.tenant_membership_event.txid IS
    'AA-978 (276): the writing transaction (pg_current_xact_id()); the feed serves a row only once every older '
    'transaction has finished.';
COMMENT ON COLUMN shared.tenant_membership_event.membership IS
    'pii:online_id; AA-978 (276): the contract Membership object (membership_id, tenant_id, identity {iss, sub} or '
    'null, content_studio_role, status, invitation_id, updated_at) for membership.* events; NULL for tenant.* events.';

-- ── 3. Functions and triggers ──────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION shared.tenant_members_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status = 'removed' THEN
            RAISE EXCEPTION 'shared.tenant_members: a membership starts invited or active (AA-978)'
                  USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' THEN
        IF (OLD.status = 'removed' AND OLD.removed_at < now() - interval '90 days')
           OR NOT EXISTS (SELECT 1 FROM shared.tenants t
                           WHERE t.tenant_id = OLD.tenant_id AND t.cancelled_at IS NULL) THEN
            RETURN OLD;
        END IF;
        RAISE EXCEPTION 'shared.tenant_members: a membership is removed (status removed), not deleted; rows go 90 days '
                        'after removal or with the offboarded tenant (AA-978)'
              USING ERRCODE = 'restrict_violation';
    END IF;
    IF NEW.membership_id IS DISTINCT FROM OLD.membership_id OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.invitation_id IS DISTINCT FROM OLD.invitation_id OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION 'shared.tenant_members: membership_id, tenant_id, invitation_id and created_* never change '
                        '(AA-978)' USING ERRCODE = 'restrict_violation';
    END IF;
    IF OLD.status = 'removed' THEN
        RAISE EXCEPTION 'shared.tenant_members: a removed membership is final (AA-978)'
              USING ERRCODE = 'restrict_violation';
    END IF;
    IF OLD.status = 'active' AND NEW.status = 'invited' THEN
        RAISE EXCEPTION 'shared.tenant_members: an active membership never goes back to invited (AA-978)'
              USING ERRCODE = 'restrict_violation';
    END IF;
    IF OLD.cognito_iss IS NOT NULL
       AND (NEW.cognito_iss IS DISTINCT FROM OLD.cognito_iss OR NEW.cognito_sub IS DISTINCT FROM OLD.cognito_sub) THEN
        RAISE EXCEPTION 'shared.tenant_members: the identity of a membership is bound once and never changes '
                        '(AA-978)' USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END
$fn$;

CREATE OR REPLACE FUNCTION shared.tenant_membership_event_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Depth 1 = a statement of the client; the feed triggers insert at depth 2.
        IF pg_trigger_depth() < 2 THEN
            RAISE EXCEPTION 'shared.tenant_membership_event: events are written only by the triggers on '
                            'shared.tenants and shared.tenant_members (AA-978)'
                  USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' THEN
        IF OLD.occurred_at < now() - interval '90 days'
           OR NOT EXISTS (SELECT 1 FROM shared.tenants t
                           WHERE t.tenant_id = OLD.tenant_id AND t.cancelled_at IS NULL) THEN
            RETURN OLD;
        END IF;
        RAISE EXCEPTION 'shared.tenant_membership_event: an event is deleted only 90 days after it occurred or with '
                        'the offboarded tenant (AA-978)'
              USING ERRCODE = 'restrict_violation';
    END IF;
    RAISE EXCEPTION 'shared.tenant_membership_event is append-only: % refused (AA-978)', TG_OP
          USING ERRCODE = 'restrict_violation';
END
$fn$;

CREATE OR REPLACE FUNCTION shared.tenant_membership_emit_member() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    ev text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        ev := CASE NEW.status WHEN 'invited' THEN 'membership.invited' WHEN 'active' THEN 'membership.activated' END;
    ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
        ev := CASE NEW.status WHEN 'active' THEN 'membership.activated' WHEN 'removed' THEN 'membership.removed' END;
    ELSIF NEW.content_studio_role IS DISTINCT FROM OLD.content_studio_role THEN
        ev := 'membership.role_changed';
    END IF;
    IF ev IS NOT NULL THEN
        -- The contract Membership object (ids and the identity only). Built here, not in a helper function: a
        -- function called from the trigger body needs EXECUTE for the writing role, the trigger itself does not.
        INSERT INTO shared.tenant_membership_event (type, tenant_id, membership)
        VALUES (ev, NEW.tenant_id, jsonb_build_object(
                    'membership_id', NEW.membership_id,
                    'tenant_id', NEW.tenant_id,
                    'identity', CASE WHEN NEW.cognito_iss IS NULL THEN 'null'::jsonb
                                     ELSE jsonb_build_object('iss', NEW.cognito_iss, 'sub', NEW.cognito_sub) END,
                    'content_studio_role', NEW.content_studio_role,
                    'status', NEW.status,
                    'invitation_id', NEW.invitation_id,
                    'updated_at', to_char(NEW.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));
    END IF;
    RETURN NULL;
END
$fn$;

CREATE OR REPLACE FUNCTION shared.tenant_membership_emit_tenant() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    old_state text;
    new_state text := CASE WHEN NEW.cancelled_at IS NOT NULL THEN 'deleted'
                           WHEN NOT NEW.is_active THEN 'locked' ELSE 'active' END;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO shared.tenant_membership_event (type, tenant_id) VALUES ('tenant.created', NEW.tenant_id);
        old_state := 'active';
    ELSE
        old_state := CASE WHEN OLD.cancelled_at IS NOT NULL THEN 'deleted'
                          WHEN NOT OLD.is_active THEN 'locked' ELSE 'active' END;
    END IF;
    IF new_state IS DISTINCT FROM old_state THEN
        INSERT INTO shared.tenant_membership_event (type, tenant_id)
        VALUES (CASE new_state WHEN 'deleted' THEN 'tenant.deleted' WHEN 'locked' THEN 'tenant.locked'
                               ELSE 'tenant.unlocked' END, NEW.tenant_id);
    END IF;
    RETURN NULL;
END
$fn$;

REVOKE ALL ON FUNCTION shared.tenant_members_guard(), shared.tenant_membership_event_guard(),
                       shared.tenant_membership_emit_member(), shared.tenant_membership_emit_tenant() FROM PUBLIC;

DROP TRIGGER IF EXISTS tenant_members_guard ON shared.tenant_members;
CREATE TRIGGER tenant_members_guard
    BEFORE INSERT OR UPDATE OR DELETE ON shared.tenant_members
    FOR EACH ROW EXECUTE FUNCTION shared.tenant_members_guard();
DROP TRIGGER IF EXISTS tenant_members_feed ON shared.tenant_members;
CREATE TRIGGER tenant_members_feed
    AFTER INSERT OR UPDATE ON shared.tenant_members
    FOR EACH ROW EXECUTE FUNCTION shared.tenant_membership_emit_member();

DROP TRIGGER IF EXISTS tenant_membership_event_guard ON shared.tenant_membership_event;
CREATE TRIGGER tenant_membership_event_guard
    BEFORE INSERT OR UPDATE OR DELETE ON shared.tenant_membership_event
    FOR EACH ROW EXECUTE FUNCTION shared.tenant_membership_event_guard();
DROP TRIGGER IF EXISTS tenant_membership_event_no_truncate ON shared.tenant_membership_event;
CREATE TRIGGER tenant_membership_event_no_truncate
    BEFORE TRUNCATE ON shared.tenant_membership_event
    FOR EACH STATEMENT EXECUTE FUNCTION shared.tenant_membership_event_guard();

DROP TRIGGER IF EXISTS tenants_membership_feed_ins ON shared.tenants;
CREATE TRIGGER tenants_membership_feed_ins
    AFTER INSERT ON shared.tenants
    FOR EACH ROW EXECUTE FUNCTION shared.tenant_membership_emit_tenant();
DROP TRIGGER IF EXISTS tenants_membership_feed_upd ON shared.tenants;
CREATE TRIGGER tenants_membership_feed_upd
    AFTER UPDATE OF is_active, cancelled_at ON shared.tenants
    FOR EACH ROW
    WHEN (OLD.is_active IS DISTINCT FROM NEW.is_active OR OLD.cancelled_at IS DISTINCT FROM NEW.cancelled_at)
    EXECUTE FUNCTION shared.tenant_membership_emit_tenant();

-- ── 4. Grants ──────────────────────────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON shared.tenant_members, shared.tenant_membership_event FROM PUBLIC;
REVOKE ALL ON shared.tenant_members, shared.tenant_membership_event FROM cis_app, aa_app_user, catalog_owner;
REVOKE ALL ON SEQUENCE shared.tenant_membership_event_seq_seq FROM PUBLIC;
REVOKE ALL ON SEQUENCE shared.tenant_membership_event_seq_seq FROM cis_app, aa_app_user, catalog_owner;
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.tenant_members TO cis_app;
GRANT SELECT, INSERT, DELETE ON shared.tenant_membership_event TO cis_app;

-- ── Guards 2 + 3 ───────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    m_oid   oid := 'shared.tenant_members'::regclass;
    e_oid   oid := 'shared.tenant_membership_event'::regclass;
    t_oid   oid := 'shared.tenants'::regclass;
    s_oid   oid := 'shared.tenant_membership_event_seq_seq'::regclass;
    privs   text;
    missing text;
    bad     text;
BEGIN
    -- 2. constraints, triggers, indexes
    SELECT string_agg(want, ', ' ORDER BY want) INTO missing
      FROM unnest(ARRAY['tenant_members_pkey', 'tenant_members_tenant_id_fkey', 'tenant_members_role_check',
                        'tenant_members_status_check', 'tenant_members_identity_check',
                        'tenant_members_identity_shape_check', 'tenant_members_invitation_check',
                        'tenant_members_removed_check', 'tenant_members_actor_check', 'tenant_membership_event_pkey',
                        'tenant_membership_event_event_id_key', 'tenant_membership_event_type_check',
                        'tenant_membership_event_membership_check']) AS want
     WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                        WHERE c.conrelid IN (m_oid, e_oid) AND c.conname = want AND c.convalidated);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 276: constraints missing or not validated: %', missing;
    END IF;
    SELECT string_agg(want, ', ' ORDER BY want) INTO missing
      FROM (VALUES ('tenant_members_guard', m_oid), ('tenant_members_feed', m_oid),
                   ('tenant_membership_event_guard', e_oid), ('tenant_membership_event_no_truncate', e_oid),
                   ('tenants_membership_feed_ins', t_oid), ('tenants_membership_feed_upd', t_oid)) AS w(want, rel)
     WHERE NOT EXISTS (SELECT 1 FROM pg_trigger g
                        WHERE g.tgrelid = w.rel AND g.tgname = w.want AND NOT g.tgisinternal AND g.tgenabled = 'O');
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 276: triggers missing or disabled: %', missing;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                    WHERE x.indrelid = m_oid AND c.relname = 'tenant_members_live_identity_key' AND x.indisunique
                      AND pg_get_expr(x.indpred, x.indrelid) = '(status <> ''removed''::text)')
       OR NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                       WHERE x.indrelid = m_oid AND c.relname = 'tenant_members_identity_idx')
       OR NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                       WHERE x.indrelid = e_oid AND c.relname = 'tenant_membership_event_feed_idx') THEN
        RAISE EXCEPTION 'migration 276: the indexes are missing or not as this file defines them';
    END IF;

    -- 2. privileges of the four roles that matter, table and sequence level, and no column grants
    SELECT string_agg(r || ':' || o || ':' || p, ', ' ORDER BY r COLLATE "C", o COLLATE "C", p COLLATE "C")
      INTO privs FROM (
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r,
               CASE c.oid WHEN m_oid THEN 'members' WHEN e_oid THEN 'event' ELSE 'sequence' END AS o,
               a.privilege_type AS p
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid IN (m_oid, e_oid, s_oid)
           AND (a.grantee = 0 OR a.grantee IN ('cis_app'::regrole, 'aa_app_user'::regrole,
                                               'catalog_owner'::regrole))) x;
    IF privs IS DISTINCT FROM 'cis_app:event:DELETE, cis_app:event:INSERT, cis_app:event:SELECT, '
                              'cis_app:members:DELETE, cis_app:members:INSERT, cis_app:members:SELECT, '
                              'cis_app:members:UPDATE' THEN
        RAISE EXCEPTION 'migration 276: unexpected privileges on the membership objects: %', privs;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid IN (m_oid, e_oid) AND a.attacl IS NOT NULL) THEN
        RAISE EXCEPTION 'migration 276: column-level grants on the membership objects';
    END IF;

    -- 2. every role that may write shared.tenants (table or column level) may write the event its trigger emits
    SELECT string_agg(DISTINCT g, ', ' ORDER BY g) INTO bad FROM (
        SELECT a.grantee::regrole::text AS g
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid = t_oid AND a.grantee <> 0 AND a.grantee <> c.relowner
           AND a.privilege_type IN ('INSERT', 'UPDATE')
           AND NOT has_table_privilege(a.grantee, e_oid, 'INSERT')
        UNION ALL
        SELECT a.grantee::regrole::text
          FROM pg_attribute att CROSS JOIN LATERAL aclexplode(att.attacl) a
         WHERE att.attrelid = t_oid AND att.attname IN ('is_active', 'cancelled_at') AND a.grantee <> 0
           AND a.privilege_type IN ('INSERT', 'UPDATE')
           AND NOT has_table_privilege(a.grantee, e_oid, 'INSERT')) w;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 276: role(s) % may write shared.tenants but not insert into '
                        'shared.tenant_membership_event (the feed trigger runs as the writer)', bad;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
                WHERE c.oid = t_oid AND a.grantee = 0 AND a.privilege_type IN ('INSERT', 'UPDATE')) THEN
        RAISE EXCEPTION 'migration 276: PUBLIC may write shared.tenants';
    END IF;

    -- 2. the four functions: not SECURITY DEFINER (MIG-6), search_path pinned, no EXECUTE for PUBLIC
    SELECT string_agg(f::text, ', ' ORDER BY f::text) INTO bad
      FROM unnest(ARRAY['shared.tenant_members_guard()'::regprocedure,
                        'shared.tenant_membership_event_guard()'::regprocedure,
                        'shared.tenant_membership_emit_member()'::regprocedure,
                        'shared.tenant_membership_emit_tenant()'::regprocedure]) AS f
      JOIN pg_proc p ON p.oid = f
     WHERE p.prosecdef OR NOT ('search_path=pg_catalog, pg_temp' = ANY (coalesce(p.proconfig, '{}')))
        OR has_function_privilege('public', f, 'EXECUTE');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 276: function(s) % are SECURITY DEFINER, lack the pinned search_path or give '
                        'PUBLIC EXECUTE', bad;
    END IF;
END $$;

DO $$
DECLARE
    probe   uuid := gen_random_uuid();
    m1      uuid;
    m2      uuid;
    refused boolean;
    types   text;
    doc     jsonb;
    n       bigint;
BEGIN
    -- 3. behaviour, on a probe tenant; the block always ends in SQLSTATE ZZ276, which rolls the probe back
    BEGIN
        INSERT INTO shared.tenants (tenant_id, name, slug, plan_tier, rate_limit_rpm, is_active, posts_per_week)
        VALUES (probe, 'migration 276 probe', 'zz-migration-276-' || left(probe::text, 8),
                (SELECT e.enumlabel::plan_tier_enum FROM pg_enum e
                  WHERE e.enumtypid = 'plan_tier_enum'::regtype ORDER BY e.enumsortorder LIMIT 1), 60, true, 3);
        UPDATE shared.tenants SET posts_per_week = 4 WHERE tenant_id = probe;                  -- no event
        UPDATE shared.tenants SET is_active = false WHERE tenant_id = probe;                   -- locked
        UPDATE shared.tenants SET is_active = true WHERE tenant_id = probe;                    -- unlocked

        INSERT INTO shared.tenant_members (tenant_id, content_studio_role, status, invitation_id, created_by)
        VALUES (probe, 'editor', 'invited', gen_random_uuid(), 'migration:276') RETURNING membership_id INTO m1;
        UPDATE shared.tenant_members
           SET status = 'active', cognito_iss = 'https://issuer.example.invalid/probe', cognito_sub = 'probe-sub'
         WHERE membership_id = m1;                                                              -- activated
        UPDATE shared.tenant_members SET content_studio_role = 'owner' WHERE membership_id = m1;  -- role_changed
        UPDATE shared.tenant_members SET status = 'removed', removed_at = now(), removed_by = 'migration:276'
         WHERE membership_id = m1;                                                              -- removed
        UPDATE shared.tenants SET cancelled_at = now(), is_active = false WHERE tenant_id = probe;  -- deleted
        UPDATE shared.tenants SET cancelled_at = NULL, is_active = true WHERE tenant_id = probe;    -- unlocked

        SELECT string_agg(type, ',' ORDER BY txid, seq) INTO types
          FROM shared.tenant_membership_event WHERE tenant_id = probe;
        IF types IS DISTINCT FROM 'tenant.created,tenant.locked,tenant.unlocked,membership.invited,'
                                  'membership.activated,membership.role_changed,membership.removed,tenant.deleted,'
                                  'tenant.unlocked' THEN
            RAISE EXCEPTION 'migration 276: unexpected event sequence: %', types;
        END IF;
        SELECT membership INTO doc FROM shared.tenant_membership_event
         WHERE tenant_id = probe AND type = 'membership.removed';
        IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(doc) k)
               IS DISTINCT FROM ARRAY['content_studio_role', 'identity', 'invitation_id', 'membership_id', 'status',
                                      'tenant_id', 'updated_at']
           OR doc -> 'identity' IS DISTINCT FROM
              '{"iss": "https://issuer.example.invalid/probe", "sub": "probe-sub"}'::jsonb
           OR doc ->> 'status' <> 'removed' OR doc ->> 'content_studio_role' <> 'owner'
           OR doc ->> 'updated_at' !~ '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$' THEN
            RAISE EXCEPTION 'migration 276: the removed event does not carry the contract Membership: %', doc;
        END IF;

        refused := false;
        BEGIN
            INSERT INTO shared.tenant_membership_event (type, tenant_id) VALUES ('tenant.locked', probe);
        EXCEPTION WHEN restrict_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 276: an event could be inserted directly';
        END IF;
        refused := false;
        BEGIN
            UPDATE shared.tenant_membership_event SET type = 'tenant.locked' WHERE tenant_id = probe;
        EXCEPTION WHEN restrict_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 276: an event could be updated';
        END IF;
        refused := false;
        BEGIN
            DELETE FROM shared.tenant_membership_event WHERE tenant_id = probe;
        EXCEPTION WHEN restrict_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 276: a fresh event of a live tenant could be deleted';
        END IF;

        INSERT INTO shared.tenant_members (tenant_id, cognito_iss, cognito_sub, content_studio_role, status, created_by)
        VALUES (probe, 'https://issuer.example.invalid/probe', 'probe-sub', 'viewer', 'active', 'migration:276')
        RETURNING membership_id INTO m2;
        refused := false;
        BEGIN
            DELETE FROM shared.tenant_members WHERE membership_id = m2;
        EXCEPTION WHEN restrict_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 276: a live membership could be deleted';
        END IF;
        refused := false;
        BEGIN
            INSERT INTO shared.tenant_members (tenant_id, cognito_iss, cognito_sub, content_studio_role, status,
                                               created_by)
            VALUES (probe, 'https://issuer.example.invalid/probe', 'probe-sub', 'editor', 'active', 'migration:276');
        EXCEPTION WHEN unique_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 276: a second live membership of one identity was accepted';
        END IF;
        refused := false;
        BEGIN
            UPDATE shared.tenant_members SET status = 'active' WHERE membership_id = m1;
        EXCEPTION WHEN restrict_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 276: a removed membership could come back';
        END IF;

        RAISE EXCEPTION 'probe done' USING ERRCODE = 'ZZ276';
    EXCEPTION WHEN SQLSTATE 'ZZ276' THEN
        NULL;
    END;
    IF EXISTS (SELECT 1 FROM shared.tenants WHERE tenant_id = probe)
       OR EXISTS (SELECT 1 FROM shared.tenant_membership_event WHERE tenant_id = probe) THEN
        RAISE EXCEPTION 'migration 276: the behaviour probe was not rolled back';
    END IF;
    SELECT count(*) INTO n FROM shared.tenant_members;
    RAISE NOTICE 'migration 276: memberships present: %', n;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('276', now(), 'AA-978 CRM-P1: tenant membership directory and tenant.membership.v1 event feed')
ON CONFLICT (version) DO NOTHING;

COMMIT;
