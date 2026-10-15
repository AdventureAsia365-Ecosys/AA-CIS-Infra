-- Migration tp-011: AA-827 — guest token stored as sha256 only (EXPAND).
-- Lock-sensitive: tripplanner.sessions (48 kB; brief ACCESS EXCLUSIVE, metadata-only DDL).
-- New code writes sha256(token) to guest_token_hash and stops writing plaintext guest_token (= id::text).
-- tp-012 nulls the legacy values; DROP COLUMN is a later contract file (MIG-7, >=14 days, destructive).
-- No new grant: role tripplanner already has table DML on sessions. Re-running is a no-op.
BEGIN;
ALTER TABLE tripplanner.sessions ADD COLUMN IF NOT EXISTS guest_token_hash bytea;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'sessions_guest_token_hash_len_chk'
                   AND conrelid = 'tripplanner.sessions'::regclass) THEN
    ALTER TABLE tripplanner.sessions ADD CONSTRAINT sessions_guest_token_hash_len_chk
      CHECK (guest_token_hash IS NULL OR octet_length(guest_token_hash) = 32) NOT VALID;
    ALTER TABLE tripplanner.sessions VALIDATE CONSTRAINT sessions_guest_token_hash_len_chk;
  END IF;
END $$;
ALTER TABLE tripplanner.sessions ALTER COLUMN guest_token DROP NOT NULL;
COMMENT ON COLUMN tripplanner.sessions.guest_token_hash IS 'conf:credential — sha256 of the BFF guest cookie token (AA-827); the token itself is never stored';
COMMENT ON COLUMN tripplanner.sessions.guest_token IS 'conf:credential — DEPRECATED (AA-827): legacy plaintext id::text, no longer written; nulled by tp-012, dropped by a later contract migration';
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-011', now(), 'AA-827: sessions.guest_token_hash (sha256, bytea); guest_token nullable')
ON CONFLICT (version) DO NOTHING;
COMMIT;
