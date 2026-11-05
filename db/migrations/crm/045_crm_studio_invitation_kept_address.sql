-- Migration crm-045: AA-1035 R2 close-out (root ADR 0019 d5, clarifications section 3 "support: send invitations
-- again") — crm.studio_invitation keeps the invited address sealed under the CRM data key, so a studio invitation can
-- be sent again to the SAME address without anybody typing it again (crm.ops.v1 1.12 keep_address).
--
-- Owner: AA-Partner (api/migrations/045_crm_studio_invitation_kept_address.sql). AA-CIS-Infra db/migrations/crm/ holds
-- the byte copy DB Migrate applies (Migration Copy Guard). Key crm-045: crm-043 is the highest on main; crm-044 is held
-- by another lane of the same wave (the orchestrator renumbers to main max + 1 if it is not merged first).
--
-- Why. crm-020 seals the address only under a key derived from the invitation token, which only the mail carries, so
-- a send again must carry the address again; CIS never stores it (root ADR 0010a). The S267 review found that a staff
-- member who may only send invitations again (support) could therefore redirect an invitation to any address. The
-- tech lead's follow-up: "a support resend that keeps the sealed address". The address is now ALSO sealed under a data
-- key of the CRM (envelope: a fresh AES-256 key from the CRM KMS data key, GenerateDataKey with the encryption context
-- {tenant_id: the CIS tenant, purpose: mail}, the purpose the key policy already allows; AES-256-GCM, AAD = the CIS
-- invitation id), so the CRM can open it for a re-issue only. The token-derived email_enc stays (the claim path is
-- unchanged).
--
-- What.
--   1. Four nullable columns: email_kept (version ‖ nonce ‖ ciphertext ‖ tag), email_kept_dek (the wrapped data key),
--      email_kept_kek_provider (kms | local) and email_kept_kek_id (the key ARN or local key id KMS / the keyring
--      returned). All four or none (studio_invitation_kept_chk): a row issued before this file, or while the CRM had no
--      key provider, keeps none and cannot be sent again without an address (409 address_not_kept).
--   2. crm.guard_studio_invitation_write() (crm-020 text plus two rules, CRM37): only a platform actor sets the kept
--      address (issue, re-issue); the token holder may only clear it, which the claim does (the person opened the
--      invitation: it is never sent again, the address is not kept a minute longer); the job never touches it. A
--      revoke clears it in the same UPDATE (a revoked invitation is never sent again either). An expired one keeps it:
--      a pending or expired invitation is re-issued (crm-020), and a send again after the expiry is the usual one.
--   3. Register crm-045.
--
-- Behaviour on apply: none. Existing rows keep NULL; nothing reads or writes the columns until the AA-Partner code PR
-- deploys (then each new or re-issued invitation keeps its address, and the claim clears it).
--
-- Class: contract (ALTER of an existing table, a new CHECK, CREATE OR REPLACE of an existing function). MIG-4: this
-- migration-only PR, then the code PR (readiness crm-045) once it is applied on Dev. No new table: no DM-7.1 row; the
-- kept address lives exactly as long as the row (crm-020 retention) and is cleared at the claim.
--
-- Rollback (a NEW forward migration, after the code is reverted): restate crm-020's guard; ALTER TABLE
-- crm.studio_invitation DROP CONSTRAINT studio_invitation_kept_chk, DROP COLUMN email_kept, email_kept_dek,
-- email_kept_kek_provider, email_kept_kek_id (destructive: DRY RUN first).
--
-- X1. One BEGIN … COMMIT block, run by DB Migrate as crm_owner, no role DDL. Re-runnable (ADD COLUMN IF NOT EXISTS,
-- DROP CONSTRAINT IF EXISTS + ADD, CREATE OR REPLACE, ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

-- ── Guard 0: runs as the owner, after crm-020 ─────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-045: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF to_regclass('crm.studio_invitation') IS NULL
       OR to_regprocedure('crm.guard_studio_invitation_write()') IS NULL THEN
        RAISE EXCEPTION 'crm-045: crm.studio_invitation and its guard (crm-020) are missing';
    END IF;
END $$;

-- ── 1. The kept address ──────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE crm.studio_invitation
    ADD COLUMN IF NOT EXISTS email_kept              BYTEA,
    ADD COLUMN IF NOT EXISTS email_kept_dek          BYTEA,
    ADD COLUMN IF NOT EXISTS email_kept_kek_provider TEXT,
    ADD COLUMN IF NOT EXISTS email_kept_kek_id       TEXT;

ALTER TABLE crm.studio_invitation
    DROP CONSTRAINT IF EXISTS studio_invitation_kept_chk,
    ADD CONSTRAINT studio_invitation_kept_chk CHECK (
        (email_kept IS NULL AND email_kept_dek IS NULL AND email_kept_kek_provider IS NULL
         AND email_kept_kek_id IS NULL)
        OR (email_kept IS NOT NULL AND email_kept_dek IS NOT NULL AND email_kept_kek_provider IS NOT NULL
            AND email_kept_kek_id IS NOT NULL
            AND octet_length(email_kept) BETWEEN 30 AND 1100
            AND octet_length(email_kept_dek) BETWEEN 16 AND 2048
            AND email_kept_kek_provider IN ('kms', 'local')
            AND char_length(email_kept_kek_id) BETWEEN 1 AND 2048));

COMMENT ON COLUMN crm.studio_invitation.email_kept IS 'pii:contact; AA-1035 (crm-045): the invited e-mail, AES-256-GCM (AAD = cis_invitation_id) under the data key in email_kept_dek, so a send again keeps the address (crm.ops.v1 1.12 keep_address); NULL before crm-045, without a key provider and after the claim';
COMMENT ON COLUMN crm.studio_invitation.email_kept_dek IS 'AA-1035 (crm-045): the data key of email_kept, wrapped by the CRM KMS data key with the context {tenant_id: cis_tenant_id, purpose: mail}; never in clear';
COMMENT ON COLUMN crm.studio_invitation.email_kept_kek_provider IS 'AA-1035 (crm-045): kms (Dev, prod) or local (tests): the wrapper that unwraps email_kept_dek';
COMMENT ON COLUMN crm.studio_invitation.email_kept_kek_id IS 'AA-1035 (crm-045): the key id the wrapper returned for email_kept_dek (the KMS key ARN), so the unwrap names its key';

-- ── 2. The guard: crm-020 plus the kept address rule ─────────────────────────────────────────────────────────────
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
    kept_changed boolean;
    kept_cleared boolean;
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
    -- AA-1035 (crm-045): the kept address is set by a platform actor only; anybody else may only clear it.
    kept_changed := NEW.email_kept IS DISTINCT FROM OLD.email_kept
                    OR NEW.email_kept_dek IS DISTINCT FROM OLD.email_kept_dek
                    OR NEW.email_kept_kek_provider IS DISTINCT FROM OLD.email_kept_kek_provider
                    OR NEW.email_kept_kek_id IS DISTINCT FROM OLD.email_kept_kek_id;
    kept_cleared := NEW.email_kept IS NULL AND NEW.email_kept_dek IS NULL AND NEW.email_kept_kek_provider IS NULL
                    AND NEW.email_kept_kek_id IS NULL;
    IF platform THEN
        -- Re-issue (pending / expired -> pending with a new token, sealed e-mail, kept address, expiry, locale) or
        -- revoke.
        IF NEW.status = 'pending' AND OLD.status IN ('pending', 'expired') THEN
            IF NEW.cognito_sub IS NOT NULL OR NEW.claimed_at IS NOT NULL OR NEW.accepted_at IS NOT NULL
               OR NEW.activated_at IS NOT NULL OR NEW.activation_attempts <> OLD.activation_attempts THEN
                RAISE EXCEPTION 'crm: a re-issue changes only the token, the sealed e-mail, the expiry and the locale'
                    USING ERRCODE = 'CRM37';
            END IF;
            RETURN NEW;
        END IF;
        IF NEW.status = 'revoked' AND OLD.status IN ('pending', 'claimed') THEN
            IF NOT kept_cleared THEN
                RAISE EXCEPTION 'crm: a revoke clears the kept address (a revoked invitation is never sent again)'
                    USING ERRCODE = 'CRM37';
            END IF;
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'crm: a platform actor re-issues or revokes a studio invitation, nothing else'
            USING ERRCODE = 'CRM37';
    END IF;
    IF kept_changed AND NOT kept_cleared THEN
        RAISE EXCEPTION 'crm: only a platform issue or re-issue keeps the address; others may only clear it'
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
        IF kept_changed THEN
            RAISE EXCEPTION 'crm: the activation job never touches the kept address' USING ERRCODE = 'CRM37';
        END IF;
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
COMMENT ON FUNCTION crm.guard_studio_invitation_write() IS 'AA-979 (crm-020), AA-1035 (crm-045): who may write crm.studio_invitation (CRM37): platform:* issues, re-issues (with the kept address) and revokes (clearing the kept address); invitation:* (the token holder) claims, accepts or expires, and may only clear the kept address; job:crm_studio_activation records attempts and activates; the tenant, the CIS invitation, the issuer and a bound identity never change.';

-- ── Guard 1: the shape this file promises ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    col text;
BEGIN
    FOREACH col IN ARRAY ARRAY['email_kept', 'email_kept_dek', 'email_kept_kek_provider', 'email_kept_kek_id'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
                        WHERE attrelid = 'crm.studio_invitation'::regclass AND attname = col AND NOT attisdropped
                          AND NOT attnotnull) THEN
            RAISE EXCEPTION 'crm-045: crm.studio_invitation.% is missing or NOT NULL', col;
        END IF;
        IF NOT pg_catalog.has_column_privilege('crm_app', 'crm.studio_invitation', col, 'UPDATE') THEN
            RAISE EXCEPTION 'crm-045: crm_app cannot write crm.studio_invitation.%', col;
        END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid = 'crm.studio_invitation'::regclass
                     AND conname = 'studio_invitation_kept_chk' AND contype = 'c' AND convalidated) THEN
        RAISE EXCEPTION 'crm-045: studio_invitation_kept_chk is missing or not validated';
    END IF;
    IF position('a revoke clears the kept address' IN
                pg_catalog.pg_get_functiondef('crm.guard_studio_invitation_write()'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-045: crm.guard_studio_invitation_write() does not carry the kept address rule';
    END IF;
    IF pg_catalog.has_function_privilege('public', 'crm.guard_studio_invitation_write()', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-045: crm.guard_studio_invitation_write() is executable by PUBLIC (SEC-4)';
    END IF;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.studio_invitation', 'DELETE') THEN
        RAISE EXCEPTION 'crm-045: crm_app must never DELETE crm.studio_invitation';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-045', now(), 'AA-1035 R2 close-out: crm.studio_invitation keeps the invited address under the CRM data key (send again to the same address, crm.ops.v1 1.12 keep_address); the guard lets only a platform actor set it, the claim and a revoke clear it')
ON CONFLICT (version) DO NOTHING;

COMMIT;
