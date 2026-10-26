-- Migration crm-020: AA-979 (partner CRM, card CRM-P2b; root ADR 0010a) — Content studio invitations: the CRM delivers
-- the invitation CIS created (AA system mail, claim, accept in the partner pool), then tells CIS which partner-pool
-- identity accepted (tenant.membership.v1 1.1 activateInvitation).
--
-- Owner: AA-Partner (api/migrations/020_crm_studio_invitation.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-020. crm.erase_subject, crm.erase_held and
-- crm.lifecycle_purge_expired are NOT replaced: the new table carries no tenant_id (see 1.), so no agency scope reaches
-- it and no tenant-table check counts it.
--
-- Why. CIS is the only owner of Content studio roles (root ADR 0010 §7); only the CRM API may create partner-pool users
-- (its task role allow-list, root ADR 0006b decision 5). So a studio invitation is CIS-created and CRM-delivered. The
-- live crm.member_invitation does not fit it (design S252 critic C6): its role is NOT NULL, accept requires a CRM
-- member, crm-008 CRM02 governs it, and its tenant_id references crm.tenant, while a CIS tenant may have NO CRM agency
-- (CONTEXT.md). A person invited both to the CRM and to the studio gets two invitations.
--
-- What:
--   1. crm.studio_invitation, a PLATFORM table (no tenant_id, like crm.aa_catalog_tour / crm.membership_feed_state):
--      cis_tenant_id (the CIS tenant, no foreign key: it may have no CRM agency), cis_invitation_id (CIS's id, UNIQUE:
--      sending again re-issues the same row), the e-mail as email_enc = AES-256-GCM under a key derived (HKDF-SHA256)
--      from the invitation TOKEN, which only the mail carries (the database alone cannot open it; no agency DEK
--      exists for a studio-only tenant), token_hash (SHA-256 of the 43-character token, UNIQUE), locale (en | vi),
--      status pending -> claimed -> accepted -> activated (or expired / revoked; an expired one may be re-issued to
--      pending), expires_at (at most 30 days after it was issued), the partner-pool (iss, sub) the claim created or found,
--      the activation bookkeeping (attempts, the last error code) and who issued it. Ids, codes and times only besides
--      the sealed e-mail.
--   2. Row security, FORCE (crm_owner included): a platform actor (app.actor platform:*), the activation job
--      (job:crm_studio_activation) and the token holder (app.invite_token_hash = the row's hash, SELECT + UPDATE) reach
--      rows; nobody else, and no NOLOGIN reader has any privilege. crm_app never deletes or truncates.
--   3. crm.guard_studio_invitation_write() (every INSERT / UPDATE, SQLSTATE CRM37): an actor is required; only a
--      platform actor inserts, re-issues (token, sealed e-mail, expiry, locale; pending or expired -> pending) or
--      revokes; the token holder only claims (pending -> claimed with the identity) and accepts (claimed -> accepted)
--      or marks it expired; the job only records an attempt and moves accepted -> activated; cis_tenant_id,
--      cis_invitation_id and a bound identity never change.
--   SQLSTATE CRM37 is this file's; the next key starts at CRM38.
--
-- Order: after crm-019 (AA-949); Guard 0 refuses to run before it is registered. No table, function or policy of an
-- earlier key changes.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); until the AA-979 API
-- code deploys nothing reads or writes this table.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-019 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-020: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-019') THEN
        RAISE EXCEPTION 'crm-020: crm-019 is not registered (AA-949 proposal builder lands first)';
    END IF;
END $$;

-- ── 1. crm.studio_invitation ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.studio_invitation (
    studio_invitation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cis_tenant_id        UUID NOT NULL,
    cis_invitation_id    UUID NOT NULL,
    email_enc            BYTEA NOT NULL,
    token_hash           BYTEA NOT NULL,
    locale               TEXT NOT NULL DEFAULT 'en',
    status               TEXT NOT NULL DEFAULT 'pending',
    issued_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at           TIMESTAMPTZ NOT NULL,
    cognito_iss          TEXT,
    cognito_sub          TEXT,
    claimed_at           TIMESTAMPTZ,
    accepted_at          TIMESTAMPTZ,
    activated_at         TIMESTAMPTZ,
    activation_attempts  INTEGER NOT NULL DEFAULT 0,
    activation_error     TEXT,
    invited_by           TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT studio_invitation_cis_invitation_uq UNIQUE (cis_invitation_id),
    CONSTRAINT studio_invitation_token_uq UNIQUE (token_hash),
    CONSTRAINT studio_invitation_token_chk CHECK (octet_length(token_hash) = 32),
    -- version byte + 12-byte nonce + ciphertext of an address of at most 254 characters + 16-byte tag
    CONSTRAINT studio_invitation_email_chk CHECK (octet_length(email_enc) BETWEEN 32 AND 1100),
    CONSTRAINT studio_invitation_locale_chk CHECK (locale IN ('en', 'vi')),
    CONSTRAINT studio_invitation_status_chk CHECK (
        status IN ('pending', 'claimed', 'accepted', 'activated', 'expired', 'revoked')
    ),
    CONSTRAINT studio_invitation_expiry_chk CHECK (
        expires_at > issued_at AND expires_at <= issued_at + interval '30 days'
    ),
    CONSTRAINT studio_invitation_identity_chk CHECK (
        (cognito_iss IS NULL) = (cognito_sub IS NULL)
        AND (cognito_iss IS NULL OR (cognito_iss ~ '^https://[^/]+/[^/]+$' AND length(cognito_sub) BETWEEN 1 AND 128))
    ),
    -- a pending row has no identity yet; claimed, accepted and activated rows carry the subject the claim bound.
    CONSTRAINT studio_invitation_claim_chk CHECK (
        (status = 'pending' AND cognito_sub IS NULL AND claimed_at IS NULL)
        OR (status IN ('claimed', 'accepted', 'activated') AND cognito_sub IS NOT NULL AND claimed_at IS NOT NULL)
        OR status IN ('expired', 'revoked')
    ),
    CONSTRAINT studio_invitation_accept_chk CHECK (
        (status IN ('accepted', 'activated')) = (accepted_at IS NOT NULL)
    ),
    CONSTRAINT studio_invitation_activate_chk CHECK ((status = 'activated') = (activated_at IS NOT NULL)),
    CONSTRAINT studio_invitation_attempts_chk CHECK (activation_attempts BETWEEN 0 AND 1000),
    CONSTRAINT studio_invitation_error_chk CHECK (
        activation_error IS NULL OR activation_error ~ '^[a-z][a-z0-9_]{0,39}$'
    ),
    CONSTRAINT studio_invitation_actor_chk CHECK (char_length(invited_by) BETWEEN 1 AND 100)
);

CREATE INDEX IF NOT EXISTS studio_invitation_tenant_idx ON crm.studio_invitation (cis_tenant_id, created_at DESC);
-- The activation job's work list: accepted rows not activated yet.
CREATE INDEX IF NOT EXISTS studio_invitation_due_idx ON crm.studio_invitation (accepted_at)
    WHERE status = 'accepted';

COMMENT ON TABLE crm.studio_invitation IS 'AA-979 (crm-020, root ADR 0010a): a Content studio invitation CIS created (cis_invitation_id) and the CRM delivers (AA system mail, claim, accept in the partner pool); after accept the CRM binds the identity at CIS (tenant.membership.v1 activateInvitation) and marks it activated. Platform table: no tenant_id (the CIS tenant may have no CRM agency), FORCE RLS on the actor / token, guard CRM37. Retention (DM-7, proposed): 90 days after activated / expired / revoked.';
COMMENT ON COLUMN crm.studio_invitation.cis_tenant_id IS 'AA-979: the CIS tenant (= the CRM agency id when the agency exists); no foreign key, a studio-only tenant has no crm.tenant row';
COMMENT ON COLUMN crm.studio_invitation.email_enc IS 'pii: the invited e-mail, AES-256-GCM under a key derived (HKDF-SHA256) from the invitation token, which only the invitation mail carries (app.members.studio); the database alone cannot open it';
COMMENT ON COLUMN crm.studio_invitation.token_hash IS 'SHA-256 of the single-use invitation token; the token is only in the invitation mail';
COMMENT ON COLUMN crm.studio_invitation.cognito_sub IS 'pii:online_id; the partner-pool subject the claim step created (AdminCreateUser) or found; accept requires the caller''s token to carry it, CIS activation binds it';
COMMENT ON COLUMN crm.studio_invitation.activation_error IS 'AA-979: the error code of the last failed CIS activation (never a message or a body)';

-- ── 2. Row security ──────────────────────────────────────────────────────────────────────────────
ALTER TABLE crm.studio_invitation ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.studio_invitation FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS studio_invitation_platform ON crm.studio_invitation;
CREATE POLICY studio_invitation_platform ON crm.studio_invitation
    TO crm_owner, crm_app
    USING (COALESCE(current_setting('app.actor', true), '') LIKE 'platform:%'
           OR COALESCE(current_setting('app.actor', true), '') = 'job:crm_studio_activation')
    WITH CHECK (COALESCE(current_setting('app.actor', true), '') LIKE 'platform:%'
                OR COALESCE(current_setting('app.actor', true), '') = 'job:crm_studio_activation');

-- The claim / accept steps know only the token (its hash, hex): one row, read and moved by its holder.
DROP POLICY IF EXISTS studio_invitation_token_lookup ON crm.studio_invitation;
CREATE POLICY studio_invitation_token_lookup ON crm.studio_invitation
    FOR SELECT TO crm_app
    USING (token_hash = decode(NULLIF(current_setting('app.invite_token_hash', true), ''), 'hex'));
DROP POLICY IF EXISTS studio_invitation_token_update ON crm.studio_invitation;
CREATE POLICY studio_invitation_token_update ON crm.studio_invitation
    FOR UPDATE TO crm_app
    USING (token_hash = decode(NULLIF(current_setting('app.invite_token_hash', true), ''), 'hex'))
    WITH CHECK (token_hash = decode(NULLIF(current_setting('app.invite_token_hash', true), ''), 'hex'));

REVOKE DELETE, TRUNCATE ON crm.studio_invitation FROM crm_app;
REVOKE ALL ON crm.studio_invitation FROM crm_ai_reader, crm_insights, crm_support_reader, crm_eraser;

-- ── 3. Status moves + write guard ────────────────────────────────────────────────────────────────
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('studio_invitation', 'pending', 'claimed'),
    ('studio_invitation', 'pending', 'expired'),
    ('studio_invitation', 'pending', 'revoked'),
    ('studio_invitation', 'claimed', 'accepted'),
    ('studio_invitation', 'claimed', 'expired'),
    ('studio_invitation', 'claimed', 'revoked'),
    ('studio_invitation', 'accepted', 'activated'),
    ('studio_invitation', 'expired', 'pending')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION crm.guard_studio_invitation_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    platform boolean := actor LIKE 'platform:%';
    job boolean := actor = 'job:crm_studio_activation';
    holder boolean := actor LIKE 'invitation:%';
    unscoped boolean := actor = '' AND current_user::text <> 'crm_app';
BEGIN
    IF unscoped THEN
        RETURN NEW;  -- the owner's maintenance (DB Migrate run-script); crm_app always names its actor
    END IF;
    IF actor = '' THEN
        RAISE EXCEPTION 'crm: studio_invitation writes need app.actor' USING ERRCODE = 'CRM37';
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NOT platform OR NEW.status <> 'pending' OR NEW.cognito_sub IS NOT NULL OR NEW.activation_attempts <> 0 THEN
            RAISE EXCEPTION 'crm: only a platform actor issues a pending studio invitation' USING ERRCODE = 'CRM37';
        END IF;
        RETURN NEW;
    END IF;
    -- UPDATE: what never changes.
    IF NEW.studio_invitation_id IS DISTINCT FROM OLD.studio_invitation_id
       OR NEW.cis_tenant_id IS DISTINCT FROM OLD.cis_tenant_id
       OR NEW.cis_invitation_id IS DISTINCT FROM OLD.cis_invitation_id
       OR NEW.invited_by IS DISTINCT FROM OLD.invited_by
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR (OLD.cognito_sub IS NOT NULL AND (NEW.cognito_iss IS DISTINCT FROM OLD.cognito_iss
                                            OR NEW.cognito_sub IS DISTINCT FROM OLD.cognito_sub)) THEN
        RAISE EXCEPTION 'crm: studio_invitation tenant, CIS invitation, issuer and bound identity are fixed'
            USING ERRCODE = 'CRM37';
    END IF;
    IF platform THEN
        -- Re-issue (pending / expired -> pending with a new token, sealed e-mail, expiry, locale) or revoke.
        IF NEW.status = 'pending' AND OLD.status IN ('pending', 'expired') THEN
            IF NEW.cognito_sub IS NOT NULL OR NEW.claimed_at IS NOT NULL OR NEW.accepted_at IS NOT NULL
               OR NEW.activated_at IS NOT NULL OR NEW.activation_attempts <> OLD.activation_attempts THEN
                RAISE EXCEPTION 'crm: a re-issue changes only the token, the sealed e-mail, the expiry and the locale'
                    USING ERRCODE = 'CRM37';
            END IF;
            RETURN NEW;
        END IF;
        IF NEW.status = 'revoked' AND OLD.status IN ('pending', 'claimed') THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'crm: a platform actor re-issues or revokes a studio invitation, nothing else'
            USING ERRCODE = 'CRM37';
    END IF;
    -- From here on the sealed e-mail, the token, the expiry and the locale are fixed.
    IF NEW.email_enc IS DISTINCT FROM OLD.email_enc OR NEW.token_hash IS DISTINCT FROM OLD.token_hash
       OR NEW.expires_at IS DISTINCT FROM OLD.expires_at OR NEW.issued_at IS DISTINCT FROM OLD.issued_at
       OR NEW.locale IS DISTINCT FROM OLD.locale THEN
        RAISE EXCEPTION 'crm: only a platform re-issue changes the token, the e-mail, the expiry or the locale'
            USING ERRCODE = 'CRM37';
    END IF;
    IF job THEN
        IF NEW.status = OLD.status AND OLD.status = 'accepted'
           AND NEW.activation_attempts = OLD.activation_attempts + 1 AND NEW.activated_at IS NULL THEN
            RETURN NEW;  -- a failed attempt: the counter and the error code
        END IF;
        IF OLD.status = 'accepted' AND NEW.status = 'activated'
           AND NEW.activation_attempts = OLD.activation_attempts + 1 THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'crm: the activation job records an attempt or activates an accepted invitation'
            USING ERRCODE = 'CRM37';
    END IF;
    IF holder THEN
        IF NEW.activation_attempts <> OLD.activation_attempts OR NEW.activation_error IS DISTINCT FROM OLD.activation_error
           OR NEW.activated_at IS NOT NULL THEN
            RAISE EXCEPTION 'crm: the invitation holder never records an activation' USING ERRCODE = 'CRM37';
        END IF;
        IF (OLD.status = 'pending' AND NEW.status IN ('claimed', 'expired'))
           OR (OLD.status = 'claimed' AND NEW.status IN ('accepted', 'expired')) THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'crm: the invitation holder only claims, accepts or expires it' USING ERRCODE = 'CRM37';
    END IF;
    RAISE EXCEPTION 'crm: % may not write crm.studio_invitation', actor USING ERRCODE = 'CRM37';
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_studio_invitation_write() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_studio_invitation_write() IS 'AA-979 (crm-020): who may write crm.studio_invitation (CRM37): platform:* issues, re-issues and revokes; invitation:* (the token holder) claims, accepts or expires; job:crm_studio_activation records attempts and activates; the tenant, the CIS invitation, the issuer and a bound identity never change.';

CREATE OR REPLACE TRIGGER studio_invitation_guard
    BEFORE INSERT OR UPDATE ON crm.studio_invitation
    FOR EACH ROW EXECUTE FUNCTION crm.guard_studio_invitation_write();
CREATE OR REPLACE TRIGGER studio_invitation_set_updated_at
    BEFORE UPDATE ON crm.studio_invitation
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE OR REPLACE TRIGGER studio_invitation_status_transition
    BEFORE UPDATE OF status ON crm.studio_invitation
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    r text;
    p text;
BEGIN
    IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class
             WHERE oid = 'crm.studio_invitation'::regclass) THEN
        RAISE EXCEPTION 'crm-020: crm.studio_invitation must have ENABLE + FORCE row level security';
    END IF;
    IF (SELECT count(*) FROM pg_catalog.pg_policy WHERE polrelid = 'crm.studio_invitation'::regclass) <> 3 THEN
        RAISE EXCEPTION 'crm-020: crm.studio_invitation has exactly three policies (platform, token lookup, token update)';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_attribute WHERE attrelid = 'crm.studio_invitation'::regclass
                AND attname = 'tenant_id' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'crm-020: crm.studio_invitation is a platform table (no tenant_id: erase_subject would need it)';
    END IF;
    FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
        FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
            IF pg_catalog.has_table_privilege(r, 'crm.studio_invitation', p) THEN
                RAISE EXCEPTION 'crm-020: % has % on crm.studio_invitation', r, p;
            END IF;
        END LOOP;
    END LOOP;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.studio_invitation', 'DELETE')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.studio_invitation', 'TRUNCATE')
       OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.studio_invitation', 'UPDATE') THEN
        RAISE EXCEPTION 'crm-020: crm_app may SELECT / INSERT / UPDATE crm.studio_invitation, never DELETE / TRUNCATE';
    END IF;
    IF pg_catalog.has_function_privilege('public', 'crm.guard_studio_invitation_write()', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-020: crm.guard_studio_invitation_write() is executable by PUBLIC (SEC-4)';
    END IF;
    IF (SELECT count(*) FROM crm.status_transition WHERE table_name = 'studio_invitation') <> 8 THEN
        RAISE EXCEPTION 'crm-020: crm.studio_invitation must have its eight status moves';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-020', now(), 'AA-979: CRM-P2b Content studio invitations (crm.studio_invitation platform table: CIS invitation id, token-sealed e-mail, claim / accept / activate states, FORCE RLS on actor and token, guard CRM37)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
