-- Migration tp-019: AA-908 (root ADR 0006 Phase 4) — traveller accounts and the session -> account link.
--
-- Owner: AA-TripPlanner-Web (key tp-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/tripplanner/019_traveller_accounts.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as tp_owner (the live owner of schema tripplanner since tp-013, XD8). Never run it from a laptop.
--
-- Why. Travellers sign in on the Cognito EXTERNAL pool (public PKCE client `tripplanner`, email code). At the first
-- sign-in the guest trip held by the browser's hashed guest token (tp-011) is attached to the account, so "My Trips"
-- lists it and the trip opens on a second device. An account is the verified Cognito identity, (iss, sub) of the
-- access token, and nothing else: no email column. The email is read from the verified access token every time it
-- is needed (the hand-off), so TripPlanner keeps no second copy that could drift from Cognito.
--
-- What (additive only; the running Lambdas never read the new objects until the AA-908 S4 deploy):
--   1. tripplanner.traveller_accounts (id, iss, sub, created_at, last_sign_in_at), UNIQUE (iss, sub). iss and sub
--      carry the DM-6.1 tag pii:online_id.
--   2. tripplanner.sessions.account_id: nullable FK to traveller_accounts(id) ON DELETE SET NULL, plus the partial
--      index sessions_account_idx (My Trips lists the sessions of one account). NULL = a guest session. The claim
--      (S4) sets it once, only where it is NULL: a session owned by an account is never moved to another one.
--      ON DELETE SET NULL is the DM-7 retention rule (root 02-data-management.md): erasing an account unlinks its
--      sessions, so the reviewed erasure step is one DELETE of the account row.
--   3. Grants: the runtime role tripplanner may SELECT, INSERT and UPDATE accounts (upsert at sign-in,
--      last_sign_in_at). No DELETE / TRUNCATE (the tp_owner default privileges gave them: revoked here): erasing an
--      account is a reviewed erasure step (DM-6.7), not a runtime path. sessions keeps its runtime DML (tp-013).
--   4. Register tp-019.
--
-- Locks: ADD COLUMN ... REFERENCES takes ACCESS EXCLUSIVE on tripplanner.sessions (a small table, see tp-011;
-- metadata-only: the column is nullable with no default) and SHARE ROW EXCLUSIVE on the new, empty
-- traveller_accounts; the plain CREATE INDEX on sessions holds SHARE for the build (small table). Writers of
-- sessions (the assembly Lambda) wait for well under a second; DB Migrate's lock_timeout bounds the wait.
--
-- Re-runnable (test_replay_twice_pg.py replays every file twice): IF NOT EXISTS everywhere, the FK added in the
-- ADD COLUMN IF NOT EXISTS, repeated grants / revokes / comments, ON CONFLICT DO NOTHING.
-- Undo: a later tp- file (ALTER TABLE tripplanner.sessions DROP COLUMN account_id; DROP TABLE
-- tripplanner.traveller_accounts), with `-- migrate: destructive`, after the S4 readers are gone.

BEGIN;

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-019: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS tripplanner.traveller_accounts (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    iss             text NOT NULL,
    sub             text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    last_sign_in_at timestamptz,
    CONSTRAINT traveller_accounts_iss_sub_key UNIQUE (iss, sub),
    CONSTRAINT traveller_accounts_iss_chk CHECK (iss ~ '^https://' AND length(iss) <= 300),
    CONSTRAINT traveller_accounts_sub_chk CHECK (length(sub) BETWEEN 1 AND 128)
);

COMMENT ON TABLE tripplanner.traveller_accounts IS
    'tp-019 (AA-908): one row per signed-in traveller, keyed by the Cognito EXTERNAL identity (iss, sub) of the verified access token. No email: it is read from the token each time.';
COMMENT ON COLUMN tripplanner.traveller_accounts.iss IS
    'pii:online_id; tp-019: issuer of the traveller''s access token (the Cognito EXTERNAL pool URL).';
COMMENT ON COLUMN tripplanner.traveller_accounts.sub IS
    'pii:online_id; tp-019: Cognito subject (user id) of the traveller, unique per issuer.';

ALTER TABLE tripplanner.sessions
    ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES tripplanner.traveller_accounts (id) ON DELETE SET NULL;

COMMENT ON COLUMN tripplanner.sessions.account_id IS
    'tp-019 (AA-908): the traveller account that claimed this guest session at sign-in; NULL = guest. Set once, never moved to another account.';

CREATE INDEX IF NOT EXISTS sessions_account_idx ON tripplanner.sessions (account_id) WHERE account_id IS NOT NULL;

REVOKE DELETE, TRUNCATE ON tripplanner.traveller_accounts FROM tripplanner;
GRANT SELECT, INSERT, UPDATE ON tripplanner.traveller_accounts TO tripplanner;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-019', now(), 'AA-908: tripplanner.traveller_accounts (iss, sub) + sessions.account_id')
ON CONFLICT (version) DO NOTHING;

COMMIT;
