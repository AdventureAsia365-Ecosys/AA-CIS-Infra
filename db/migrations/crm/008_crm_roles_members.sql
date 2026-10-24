-- Migration crm-008: AA-939 (partner CRM, design v3 card CRM-11) — F4 roles: who may write a membership, the last
-- owner rule, invitations into the partner pool, owner recovery after 14 days, the plan (entitlement) columns, and the
-- refund threshold the permission matrix reads.
--
-- Owner: AA-Partner (api/migrations/008_crm_roles_members.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-008 (fixed in S249: crm-007 = AA-940, crm-009 = AA-938).
--
-- Why. Design v3 §4.6 (roles and the permission matrix; F4), §4.7 (identity: the partner pool, invitations), Q1 6.3
-- (owner leaves: AA promotes an existing member after 14 days, every member can cancel), R8 (the agency owns its
-- clients; the owner reassigns), R11 (tiers: entitlement fields only, every agency on "free"), root ADR 0006b
-- decisions 4 and 5 (roles in app data keyed by (iss, sub); single-use, expiring, hashed invitation tokens; the
-- membership binds to the token's (iss, sub), never to an e-mail lookup). The card's E test: "last owner deactivated
-- -> recovery only".
--
-- What:
--   1. UNIQUE (tenant_id, member_id) on crm.member, so the new references to a member are same-agency keys
--      (referential checks bypass FORCE RLS; crm-006 7b did the same for travellers and trips).
--   2. crm.guard_member_write() on crm.member (BEFORE INSERT OR UPDATE OR DELETE, every column; crm_app keeps the
--      DELETE privilege crm-002 asserts, so the trigger is what refuses it — a membership only moves state):
--      a. inside a member's request (app.actor = member:<id>, set by tenant_tx()) only an OWNER writes memberships
--         (app.member_role = 'owner'): an agent or assistant can never grant, change or remove a role, whatever the
--         API code does (SQLSTATE CRM02 role_write_forbidden);
--      b. an invitation being accepted (app.actor = invitation:<id>) may write exactly the member that invitation
--         names: same agency, same role, same Cognito subject, invitation in status claimed;
--      c. platform contexts (app.actor platform:* / seed:*) may write (L1 console, owner recovery, the Dev seeder);
--         a session without app.actor that is NOT crm_app (a migration, an admin session) is "unscoped" and not
--         restricted; a crm_app session without app.actor writes nothing (every API context names its actor);
--      d. the last active owner of an agency cannot stop being one (demoted, disabled, trashed) except by a platform
--         context: SQLSTATE CRM01 last_owner. Per-agency advisory lock, so two owners demoting each other at the same
--         time cannot both pass. A platform deactivation of the last owner is what leaves an agency in "recovery
--         only" (item 4);
--      e. a member's identity (member_id, tenant_id, cognito_iss, cognito_sub, created_at / created_by) is fixed
--         outside platform contexts, so no one inside an agency rebinds a row to another token subject; and no
--         DELETE by any crm_app session, whatever its actor (only an unscoped or platform admin session deletes).
--   3. crm.member_invitation (base template, F1 field: the invited e-mail): role, the e-mail encrypted by the vault
--      (email_enc) with its blind index (email_bidx, one live invitation per address per agency), the SHA-256 of the
--      single-use token (token_hash; the token itself is only in the invitation mail), expires_at (at most 30 days),
--      the Cognito (iss, sub) the claim step created or found, and the member it became. Status pending -> claimed ->
--      accepted, or revoked / expired. A SELECT-only policy invitation_token_lookup TO crm_app finds one row by
--      app.invite_token_hash (hex) before any agency is known (the claim and accept steps, app.tenancy
--      invitation_tx). crm.guard_invitation_write() (every INSERT / UPDATE) names the columns each writer may change:
--      an owner invites and withdraws, the invitation itself only moves pending -> claimed -> accepted (or expires),
--      an agent, assistant, job or actor-less crm_app session writes nothing (SQLSTATE CRM02).
--   4. crm.owner_recovery_request (base template, ids only): a platform context (L1 console, CRM-13a) opens it for an
--      existing member; eligible_at is at least 14 days after it opens (CHECK); every active member sees it and may
--      cancel while it is pending; only a platform context completes it, and not before eligible_at (SQLSTATE CRM03
--      recovery_not_due). One pending request per agency.
--   5. crm.tenant_entitlement (base template, one row per agency, R11): plan (free / core / pro, default free),
--      member_limit (default 10), allowed_features (a fixed code list). Written only by platform contexts (SQLSTATE
--      CRM04 platform_only): an agency never grants itself a feature. No row = the defaults (no backfill: FORCE RLS
--      hides crm.tenant from this file).
--   6. crm.tenant_settings.refund_owner_threshold_base (design v3 §3.3 group A, default 1000 in the agency's base
--      currency): an agent approves a refund up to it, above it only the owner (permission matrix, app.permissions).
--   No NOLOGIN reader gets any privilege on the three new tables (crm_support_reader's grants come with CRM-13b).
--   crm_app may SELECT / INSERT / UPDATE them, never DELETE or TRUNCATE (state moves only).
--
-- Order: after crm-006 (AA-937); Guard 0 refuses to run before it is registered. Independent of crm-007 (AA-940).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); before AA-939
-- deploys nothing reads these objects (the member trigger applies at once: it only refuses writes that no deployed
-- code makes — agents and assistants have no membership write path today, no code deletes a member, and every
-- context that writes one (provisioning_tx, the seeder) names its app.actor).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-006 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-008: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-006') THEN
        RAISE EXCEPTION 'crm-008: crm-006 is not registered (F1 / F2, AA-937, lands first)';
    END IF;
END $$;

-- ── 1. Same-agency key on crm.member ─────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'crm.member'::regclass AND conname = 'member_tenant_member_uq') THEN
        ALTER TABLE crm.member ADD CONSTRAINT member_tenant_member_uq UNIQUE (tenant_id, member_id);
    END IF;
END $$;

-- ── 3. crm.member_invitation (created before the member trigger, which reads it) ─────────────────
CREATE TABLE IF NOT EXISTS crm.member_invitation (
    invitation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                  REFERENCES crm.tenant (tenant_id),
    role          TEXT NOT NULL,
    email_enc     BYTEA NOT NULL,
    email_bidx    BYTEA NOT NULL,
    token_hash    BYTEA NOT NULL,
    status        TEXT NOT NULL DEFAULT 'pending',
    expires_at    TIMESTAMPTZ NOT NULL,
    cognito_iss   TEXT,
    cognito_sub   TEXT,
    claimed_at    TIMESTAMPTZ,
    accepted_at   TIMESTAMPTZ,
    member_id     UUID,
    invited_by    TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at    TIMESTAMPTZ,
    deleted_by    TEXT,
    purge_after   TIMESTAMPTZ,
    CONSTRAINT member_invitation_token_uq UNIQUE (token_hash),
    CONSTRAINT member_invitation_member_fk FOREIGN KEY (tenant_id, member_id)
        REFERENCES crm.member (tenant_id, member_id),
    CONSTRAINT member_invitation_role_chk CHECK (role IN ('owner', 'agent', 'assistant')),
    CONSTRAINT member_invitation_status_chk CHECK (status IN ('pending', 'claimed', 'accepted', 'revoked', 'expired')),
    CONSTRAINT member_invitation_token_chk CHECK (octet_length(token_hash) = 32),
    CONSTRAINT member_invitation_bidx_chk CHECK (octet_length(email_bidx) BETWEEN 8 AND 64),
    CONSTRAINT member_invitation_expiry_chk CHECK (
        expires_at > created_at AND expires_at <= created_at + interval '30 days'
    ),
    CONSTRAINT member_invitation_identity_chk CHECK (
        (cognito_iss IS NULL) = (cognito_sub IS NULL)
        AND (cognito_iss IS NULL OR (cognito_iss ~ '^https://[^/]+/[^/]+$' AND length(cognito_sub) BETWEEN 1 AND 128))
    ),
    -- claimed and accepted rows carry the subject the claim created or found; a pending row never does.
    CONSTRAINT member_invitation_claim_chk CHECK (
        (status = 'pending' AND cognito_sub IS NULL AND claimed_at IS NULL)
        OR (status IN ('claimed', 'accepted') AND cognito_sub IS NOT NULL AND claimed_at IS NOT NULL)
        OR status IN ('revoked', 'expired')
    ),
    CONSTRAINT member_invitation_accept_chk CHECK (
        (status = 'accepted') = (accepted_at IS NOT NULL AND member_id IS NOT NULL)
    ),
    CONSTRAINT member_invitation_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);

-- One live invitation per address per agency (blind index; a revoked or expired one does not count).
CREATE UNIQUE INDEX IF NOT EXISTS member_invitation_live_email_uq
    ON crm.member_invitation (tenant_id, email_bidx)
    WHERE status IN ('pending', 'claimed') AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS member_invitation_tenant_status_idx
    ON crm.member_invitation (tenant_id, status, created_at DESC);

ALTER TABLE crm.member_invitation ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.member_invitation FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.member_invitation;
CREATE POLICY tenant_isolation ON crm.member_invitation
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
-- The claim / accept steps know only the token (its hash, hex): one row, before the agency is known.
DROP POLICY IF EXISTS invitation_token_lookup ON crm.member_invitation;
CREATE POLICY invitation_token_lookup ON crm.member_invitation
    FOR SELECT TO crm_app
    USING (token_hash = decode(NULLIF(current_setting('app.invite_token_hash', true), ''), 'hex'));

CREATE OR REPLACE TRIGGER member_invitation_set_updated_at
    BEFORE UPDATE ON crm.member_invitation
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE OR REPLACE TRIGGER member_invitation_status_transition
    BEFORE UPDATE OF status ON crm.member_invitation
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();

REVOKE DELETE, TRUNCATE ON crm.member_invitation FROM crm_app;

COMMENT ON TABLE crm.member_invitation IS 'AA-939 (crm-008): an invitation into an agency (root ADR 0006b decision 5): single-use token (SHA-256 only), expires, the e-mail encrypted (vault) + blind index, the Cognito (iss, sub) the claim step created or found; accepted only by that subject. Base template, FORCE RLS; invitation_token_lookup finds one row by its token hash.';
COMMENT ON COLUMN crm.member_invitation.email_enc IS 'pii: the invited e-mail, AES-GCM under the tenant vault DEK (app.vault, AAD = tenant, member_invitation, email_enc, invitation id)';
COMMENT ON COLUMN crm.member_invitation.email_bidx IS 'pii: blind index of the normalised e-mail (one live invitation per address per agency)';
COMMENT ON COLUMN crm.member_invitation.token_hash IS 'SHA-256 of the single-use invitation token; the token is only in the invitation mail';
COMMENT ON COLUMN crm.member_invitation.cognito_sub IS 'the partner-pool subject the claim step created (AdminCreateUser) or found (the address already has an account); accept requires the caller''s token to carry it';

INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('member_invitation', 'pending', 'claimed'),
    ('member_invitation', 'pending', 'revoked'),
    ('member_invitation', 'pending', 'expired'),
    ('member_invitation', 'claimed', 'accepted'),
    ('member_invitation', 'claimed', 'revoked'),
    ('member_invitation', 'claimed', 'expired')
ON CONFLICT DO NOTHING;

-- Who may write an invitation, and which columns each writer may change (every other column is fixed for it):
--   platform contexts and unscoped sessions (a migration, an admin session: no app.actor, not crm_app): anything
--     but the role (the L1 first-owner invite);
--   member:<owner>: inserts a new pending, unbound invitation; afterwards only closes it (revoked / expired) or
--     trashes it — never its token, address, subject, expiry or the member it became;
--   invitation:<that same id> (claim / accept, app.tenancy invitation_tx): pending -> claimed (sets cognito_iss,
--     cognito_sub, claimed_at), claimed -> accepted (sets accepted_at and member_id, which must carry the claimed
--     subject and role), or pending / claimed -> expired once expires_at has passed;
--   anyone else (member:<agent / assistant>, job:, intake_form:, a crm_app session without an actor): nothing.
CREATE OR REPLACE FUNCTION crm.guard_invitation_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    member_role text := COALESCE(NULLIF(current_setting('app.member_role', true), ''), '');
    platform boolean := actor LIKE 'platform:%' OR actor LIKE 'seed:%';
    unscoped boolean := actor = '' AND current_user::text <> 'crm_app';
    may_change text[];
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.role IS DISTINCT FROM OLD.role THEN
        RAISE EXCEPTION 'crm: member_invitation.role is fixed' USING ERRCODE = 'CRM02';
    END IF;
    IF platform OR unscoped THEN
        RETURN NEW;
    END IF;
    IF actor LIKE 'member:%' THEN
        IF member_role <> 'owner' THEN
            RAISE EXCEPTION 'crm: role_write_forbidden (only the owner invites or changes an invitation)'
                USING ERRCODE = 'CRM02';
        END IF;
        IF TG_OP = 'INSERT' THEN
            IF NEW.status <> 'pending' OR NEW.cognito_sub IS NOT NULL OR NEW.member_id IS NOT NULL
               OR NEW.deleted_at IS NOT NULL THEN
                RAISE EXCEPTION 'crm: role_write_forbidden (a new invitation is pending and unbound)' USING ERRCODE = 'CRM02';
            END IF;
            RETURN NEW;
        END IF;
        IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status NOT IN ('revoked', 'expired') THEN
            RAISE EXCEPTION 'crm: role_write_forbidden (the owner only withdraws an invitation)' USING ERRCODE = 'CRM02';
        END IF;
        may_change := ARRAY['status', 'updated_at', 'deleted_at', 'deleted_by', 'purge_after'];
    ELSIF actor LIKE 'invitation:%' THEN
        IF TG_OP = 'INSERT' OR OLD.invitation_id::text <> substr(actor, length('invitation:') + 1) THEN
            RAISE EXCEPTION 'crm: role_write_forbidden (an invitation writes only itself)' USING ERRCODE = 'CRM02';
        END IF;
        IF OLD.status = 'pending' AND NEW.status = 'claimed' THEN
            may_change := ARRAY['status', 'updated_at', 'cognito_iss', 'cognito_sub', 'claimed_at'];
        ELSIF OLD.status = 'claimed' AND NEW.status = 'accepted' THEN
            may_change := ARRAY['status', 'updated_at', 'accepted_at', 'member_id'];
            IF NOT EXISTS (
                SELECT 1 FROM crm.member m
                 WHERE m.tenant_id = OLD.tenant_id AND m.member_id = NEW.member_id AND m.role = OLD.role
                   AND m.cognito_iss = OLD.cognito_iss AND m.cognito_sub = OLD.cognito_sub
            ) THEN
                RAISE EXCEPTION 'crm: role_write_forbidden (the accepted member does not carry the claimed subject)'
                    USING ERRCODE = 'CRM02';
            END IF;
        ELSIF OLD.status IN ('pending', 'claimed') AND NEW.status = 'expired' AND OLD.expires_at <= now() THEN
            may_change := ARRAY['status', 'updated_at'];
        ELSE
            RAISE EXCEPTION 'crm: role_write_forbidden (an invitation moves pending -> claimed -> accepted, or expires)'
                USING ERRCODE = 'CRM02';
        END IF;
    ELSE
        RAISE EXCEPTION 'crm: role_write_forbidden (actor % may not write invitations)',
            COALESCE(NULLIF(split_part(actor, ':', 1), ''), 'without app.actor') USING ERRCODE = 'CRM02';
    END IF;
    IF (to_jsonb(NEW) - may_change) IS DISTINCT FROM (to_jsonb(OLD) - may_change) THEN
        RAISE EXCEPTION 'crm: role_write_forbidden (this writer may change only %)', array_to_string(may_change, ', ')
            USING ERRCODE = 'CRM02';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_invitation_write() FROM PUBLIC;
CREATE OR REPLACE TRIGGER member_invitation_guard_write
    BEFORE INSERT OR UPDATE ON crm.member_invitation
    FOR EACH ROW EXECUTE FUNCTION crm.guard_invitation_write();

-- ── 2. Membership writes and the last owner ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.guard_member_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    member_role text := COALESCE(NULLIF(current_setting('app.member_role', true), ''), '');
    platform boolean := actor LIKE 'platform:%' OR actor LIKE 'seed:%';
    -- No app.actor and not the API login: a migration (crm_owner) or an admin session. crm_app always names one.
    unscoped boolean := actor = '' AND current_user::text <> 'crm_app';
    invite_ok boolean := false;
    was_owner boolean := false;
    is_owner boolean;
BEGIN
    IF actor = '' AND NOT unscoped THEN
        RAISE EXCEPTION 'crm: role_write_forbidden (an API session names its actor)' USING ERRCODE = 'CRM02';
    END IF;
    IF TG_OP = 'DELETE' THEN
        -- A membership only moves state (disabled, trashed). crm_app keeps the DELETE privilege crm-001's default
        -- privileges gave it (crm-002's Guard 1 asserts it, and a re-run of crm-002 must stay a no-op), so the refusal
        -- is here: no crm_app session deletes a member, whatever its actor; only an unscoped / platform admin session.
        IF current_user::text = 'crm_app' OR NOT (platform OR unscoped) THEN
            RAISE EXCEPTION 'crm: role_write_forbidden (a membership is never deleted inside the app)'
                USING ERRCODE = 'CRM02';
        END IF;
        RETURN OLD;
    END IF;
    -- The identity a token resolves to is fixed: nobody inside an agency rebinds a row to another subject.
    IF TG_OP = 'UPDATE' AND NOT (platform OR unscoped)
       AND (NEW.member_id, NEW.tenant_id, NEW.cognito_iss, NEW.cognito_sub, NEW.created_at, NEW.created_by)
           IS DISTINCT FROM (OLD.member_id, OLD.tenant_id, OLD.cognito_iss, OLD.cognito_sub, OLD.created_at, OLD.created_by)
    THEN
        RAISE EXCEPTION 'crm: role_write_forbidden (a member''s identity is fixed)' USING ERRCODE = 'CRM02';
    END IF;
    IF actor LIKE 'invitation:%' THEN
        -- The member this invitation names: same agency, role and subject, invitation claimed (being accepted).
        SELECT EXISTS (
            SELECT 1 FROM crm.member_invitation i
             WHERE i.invitation_id::text = substr(actor, length('invitation:') + 1)
               AND i.tenant_id = NEW.tenant_id AND i.status = 'claimed' AND i.deleted_at IS NULL
               AND i.role = NEW.role AND i.cognito_iss = NEW.cognito_iss AND i.cognito_sub = NEW.cognito_sub
        ) INTO invite_ok;
        IF NOT invite_ok THEN
            RAISE EXCEPTION 'crm: role_write_forbidden (the invitation does not name this member)' USING ERRCODE = 'CRM02';
        END IF;
    ELSIF actor LIKE 'member:%' AND member_role <> 'owner' THEN
        RAISE EXCEPTION 'crm: role_write_forbidden (only the owner changes memberships)' USING ERRCODE = 'CRM02';
    ELSIF NOT (platform OR unscoped) AND actor NOT LIKE 'member:%' THEN
        RAISE EXCEPTION 'crm: role_write_forbidden (actor % may not write memberships)', split_part(actor, ':', 1)
            USING ERRCODE = 'CRM02';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        was_owner := OLD.role = 'owner' AND OLD.status = 'active' AND OLD.deleted_at IS NULL;
        is_owner := NEW.role = 'owner' AND NEW.status = 'active' AND NEW.deleted_at IS NULL;
        IF was_owner AND NOT is_owner AND NOT (platform OR unscoped) THEN
            -- Serialise owner changes per agency; each query below takes a fresh snapshot (VOLATILE, READ COMMITTED).
            PERFORM pg_advisory_xact_lock(hashtextextended('crm.member.owner:' || NEW.tenant_id::text, 0));
            IF NOT EXISTS (
                SELECT 1 FROM crm.member m
                 WHERE m.tenant_id = NEW.tenant_id AND m.member_id <> NEW.member_id
                   AND m.role = 'owner' AND m.status = 'active' AND m.deleted_at IS NULL
            ) THEN
                RAISE EXCEPTION 'crm: last_owner (an agency keeps at least one active owner)' USING ERRCODE = 'CRM01';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_member_write() FROM PUBLIC;
-- Every write (no column list: a column added later is guarded too). crm.member has no column a non-owner updates.
-- DELETE too: crm_app still holds DELETE on crm.member (crm-002), and the trigger refuses it.
CREATE OR REPLACE TRIGGER member_guard_write
    BEFORE INSERT OR UPDATE OR DELETE ON crm.member
    FOR EACH ROW EXECUTE FUNCTION crm.guard_member_write();

COMMENT ON FUNCTION crm.guard_member_write() IS 'AA-939 (crm-008): inside a member request only an owner writes memberships (CRM02); a member''s identity (member_id, tenant_id, cognito_iss, cognito_sub) is fixed outside platform contexts; an accepting invitation writes only the member it names; no DELETE inside the app; the last active owner stays unless a platform context acts (CRM01, advisory lock per agency).';

-- ── 4. crm.owner_recovery_request (Q1 6.3) ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.owner_recovery_request (
    request_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                        REFERENCES crm.tenant (tenant_id),
    candidate_member_id UUID NOT NULL,
    reason              TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'pending',
    eligible_at         TIMESTAMPTZ NOT NULL,
    requested_by        TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    decided_at          TIMESTAMPTZ,
    decided_by          TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    deleted_by          TEXT,
    purge_after         TIMESTAMPTZ,
    CONSTRAINT owner_recovery_candidate_fk FOREIGN KEY (tenant_id, candidate_member_id)
        REFERENCES crm.member (tenant_id, member_id),
    CONSTRAINT owner_recovery_reason_chk CHECK (reason IN ('owner_left', 'owner_unreachable', 'no_owner')),
    CONSTRAINT owner_recovery_status_chk CHECK (status IN ('pending', 'cancelled', 'completed')),
    CONSTRAINT owner_recovery_wait_chk CHECK (eligible_at >= created_at + interval '14 days'),
    CONSTRAINT owner_recovery_decided_chk CHECK (
        (status = 'pending') = (decided_at IS NULL) AND (decided_at IS NULL) = (decided_by IS NULL)
    ),
    CONSTRAINT owner_recovery_actor_chk CHECK (
        requested_by ~ '^[A-Za-z0-9:_-]{1,80}$' AND (decided_by IS NULL OR decided_by ~ '^[A-Za-z0-9:_-]{1,80}$')
    ),
    CONSTRAINT owner_recovery_request_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS owner_recovery_one_pending_uq
    ON crm.owner_recovery_request (tenant_id) WHERE status = 'pending' AND deleted_at IS NULL;

ALTER TABLE crm.owner_recovery_request ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.owner_recovery_request FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.owner_recovery_request;
CREATE POLICY tenant_isolation ON crm.owner_recovery_request
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE OR REPLACE TRIGGER owner_recovery_set_updated_at
    BEFORE UPDATE ON crm.owner_recovery_request
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE OR REPLACE TRIGGER owner_recovery_status_transition
    BEFORE UPDATE OF status ON crm.owner_recovery_request
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();

INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('owner_recovery_request', 'pending', 'cancelled'),
    ('owner_recovery_request', 'pending', 'completed')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION crm.guard_owner_recovery() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    platform boolean := actor LIKE 'platform:%' OR actor LIKE 'seed:%';
    unscoped boolean := actor = '' AND current_user::text <> 'crm_app';
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NOT (platform OR unscoped) THEN
            RAISE EXCEPTION 'crm: platform_only (AA opens an owner recovery, L1 console)' USING ERRCODE = 'CRM04';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.candidate_member_id IS DISTINCT FROM OLD.candidate_member_id OR NEW.eligible_at IS DISTINCT FROM OLD.eligible_at
       OR NEW.reason IS DISTINCT FROM OLD.reason THEN
        RAISE EXCEPTION 'crm: an owner recovery request is fixed once opened' USING ERRCODE = 'CRM04';
    END IF;
    IF OLD.status <> 'pending' THEN
        RETURN NEW;  -- a decided request: the status transition trigger refuses any further move
    END IF;
    IF NEW.status = 'completed' AND OLD.status <> 'completed' THEN
        IF NOT (platform OR unscoped) THEN
            RAISE EXCEPTION 'crm: platform_only (AA completes an owner recovery)' USING ERRCODE = 'CRM04';
        END IF;
        IF now() < OLD.eligible_at THEN
            RAISE EXCEPTION 'crm: recovery_not_due (eligible at %)', OLD.eligible_at USING ERRCODE = 'CRM03';
        END IF;
    END IF;
    IF NEW.status = 'cancelled' AND OLD.status <> 'cancelled' AND NOT (platform OR unscoped OR actor LIKE 'member:%') THEN
        RAISE EXCEPTION 'crm: a member or AA cancels an owner recovery' USING ERRCODE = 'CRM04';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_owner_recovery() FROM PUBLIC;
CREATE OR REPLACE TRIGGER owner_recovery_guard
    BEFORE INSERT OR UPDATE ON crm.owner_recovery_request
    FOR EACH ROW EXECUTE FUNCTION crm.guard_owner_recovery();

REVOKE DELETE, TRUNCATE ON crm.owner_recovery_request FROM crm_app;

COMMENT ON TABLE crm.owner_recovery_request IS 'AA-939 (crm-008, Q1 6.3): AA promotes an existing member to owner after at least 14 days; every active member sees the request and may cancel it while pending; only a platform context opens and completes it (not before eligible_at). Ids and codes only.';

-- ── 5. crm.tenant_entitlement (R11: entitlement fields, every agency free) ───────────────────────
CREATE TABLE IF NOT EXISTS crm.tenant_entitlement (
    tenant_id        UUID PRIMARY KEY DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    plan             TEXT NOT NULL DEFAULT 'free',
    member_limit     INTEGER NOT NULL DEFAULT 10,
    allowed_features TEXT[] NOT NULL DEFAULT '{}',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT tenant_entitlement_plan_chk CHECK (plan IN ('free', 'core', 'pro')),
    CONSTRAINT tenant_entitlement_limit_chk CHECK (member_limit BETWEEN 1 AND 500),
    CONSTRAINT tenant_entitlement_features_chk CHECK (
        allowed_features <@ ARRAY['ai_assist', 'whatsapp_sms', 'stripe_connect', 'campaigns', 'custom_domain',
                                  'insights_export']::text[]
    ),
    CONSTRAINT tenant_entitlement_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);

ALTER TABLE crm.tenant_entitlement ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.tenant_entitlement FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.tenant_entitlement;
CREATE POLICY tenant_isolation ON crm.tenant_entitlement
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE OR REPLACE TRIGGER tenant_entitlement_set_updated_at
    BEFORE UPDATE ON crm.tenant_entitlement
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();

CREATE OR REPLACE FUNCTION crm.guard_platform_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    unscoped boolean := actor = '' AND current_user::text <> 'crm_app';
BEGIN
    IF NOT (unscoped OR actor LIKE 'platform:%' OR actor LIKE 'seed:%') THEN
        RAISE EXCEPTION 'crm: platform_only (% is written by AA, L1 console)', TG_TABLE_NAME USING ERRCODE = 'CRM04';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_platform_write() FROM PUBLIC;
CREATE OR REPLACE TRIGGER tenant_entitlement_platform_only
    BEFORE INSERT OR UPDATE ON crm.tenant_entitlement
    FOR EACH ROW EXECUTE FUNCTION crm.guard_platform_write();

REVOKE DELETE, TRUNCATE ON crm.tenant_entitlement FROM crm_app;

COMMENT ON TABLE crm.tenant_entitlement IS 'AA-939 (crm-008, R11): the agency''s plan and limits; every agency is on free (Q1 1.1). Written only by platform contexts (L1 "allow entitlements", CRM-13a); no row = the defaults.';

-- ── 6. Refund threshold (permission matrix: an agent approves refunds up to it) ──────────────────
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS refund_owner_threshold_base NUMERIC(12, 2) NOT NULL DEFAULT 1000;
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_refund_threshold_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_refund_threshold_chk
    CHECK (refund_owner_threshold_base >= 0 AND refund_owner_threshold_base <= 10000000);
COMMENT ON COLUMN crm.tenant_settings.refund_owner_threshold_base IS 'AA-939 (crm-008, design v3 §3.3 group A / §4.6): an agent approves a refund up to this amount in the agency''s base currency; above it only the owner';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
BEGIN
    FOREACH t IN ARRAY ARRAY['crm.member_invitation', 'crm.owner_recovery_request', 'crm.tenant_entitlement'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = t::regclass) THEN
            RAISE EXCEPTION 'crm-008: % must have ENABLE + FORCE row level security', t;
        END IF;
        FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE'] LOOP
            IF NOT pg_catalog.has_table_privilege('crm_app', t, p) THEN
                RAISE EXCEPTION 'crm-008: crm_app lacks % on % (default privileges FOR ROLE crm_owner)', p, t;
            END IF;
        END LOOP;
        FOREACH p IN ARRAY ARRAY['DELETE', 'TRUNCATE'] LOOP
            IF pg_catalog.has_table_privilege('crm_app', t, p) THEN
                RAISE EXCEPTION 'crm-008: crm_app may % on % (state moves only)', p, t;
            END IF;
        END LOOP;
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, t, p) THEN
                    RAISE EXCEPTION 'crm-008: % may % on %', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
    -- crm.member: no TRUNCATE for crm_app (a trigger cannot refuse it); both guards fire on every write, not on a
    -- column list, and the member guard on DELETE too (crm_app's DELETE privilege stays, crm-002).
    IF pg_catalog.has_table_privilege('crm_app', 'crm.member', 'TRUNCATE') THEN
        RAISE EXCEPTION 'crm-008: crm_app may TRUNCATE crm.member';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_trigger tg
                WHERE (tg.tgrelid, tg.tgname) IN (('crm.member'::regclass, 'member_guard_write'),
                                                  ('crm.member_invitation'::regclass, 'member_invitation_guard_write'))
                  AND cardinality(tg.tgattr::int2[]) > 0)
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger tg
                       WHERE tg.tgrelid = 'crm.member'::regclass AND tg.tgname = 'member_guard_write'
                         AND tg.tgtype & 8 = 8) THEN
        RAISE EXCEPTION 'crm-008: the member / invitation guards must fire on every write (and DELETE on crm.member)';
    END IF;
    -- New references to a member are same-agency (tenant_id, member_id) keys.
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_constraint con
                WHERE con.contype = 'f' AND con.confrelid = 'crm.member'::regclass
                  AND con.conrelid IN ('crm.member_invitation'::regclass, 'crm.owner_recovery_request'::regclass)
                  AND cardinality(con.conkey) <> 2) THEN
        RAISE EXCEPTION 'crm-008: a new reference to a member is not a (tenant_id, member_id) key';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-008: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.guard_member_write()', 'crm.guard_invitation_write()', 'crm.guard_owner_recovery()',
                             'crm.guard_platform_write()'] LOOP
        IF pg_catalog.has_function_privilege('public', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-008: % is executable by PUBLIC (SEC-4)', t;
        END IF;
    END LOOP;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-008', now(), 'AA-939: F4 roles (membership write guard, last owner, invitations, owner recovery, entitlements, refund threshold)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
