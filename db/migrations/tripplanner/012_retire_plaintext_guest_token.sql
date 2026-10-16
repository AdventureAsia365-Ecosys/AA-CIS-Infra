-- Migration tp-012: AA-827 — retire plaintext guest_token (CONTRACT step 1: null values + tripwire).
-- Lock-sensitive: tripplanner.sessions. Every non-null guest_token equals id::text (guarded), so nulling loses nothing.
-- The deployed Lambda (AA-827 app PR) no longer writes guest_token, so the CHECK cannot break its inserts.
-- The CHECK is a fail-closed tripwire: a pre-AA-827 Lambda artifact would fail new-session inserts instead
-- of writing plaintext again, so a rollback after this file is a revert PR, not the old artifact.
-- DROP COLUMN guest_token (and its UNIQUE index) is a later contract file. Re-running is a no-op.
-- migrate: destructive
BEGIN;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM tripplanner.sessions WHERE guest_token IS NOT NULL AND guest_token <> id::text) THEN
    RAISE EXCEPTION 'tp-012: a guest_token differs from id::text; stop and investigate';
  END IF;
END $$;
UPDATE tripplanner.sessions SET guest_token = NULL WHERE guest_token IS NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'sessions_guest_token_retired_chk'
                   AND conrelid = 'tripplanner.sessions'::regclass) THEN
    ALTER TABLE tripplanner.sessions ADD CONSTRAINT sessions_guest_token_retired_chk CHECK (guest_token IS NULL) NOT VALID;
    ALTER TABLE tripplanner.sessions VALIDATE CONSTRAINT sessions_guest_token_retired_chk;
  END IF;
END $$;
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-012', now(), 'AA-827: null legacy plaintext guest_token; CHECK guest_token IS NULL')
ON CONFLICT (version) DO NOTHING;
COMMIT;
