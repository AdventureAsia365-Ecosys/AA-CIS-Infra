-- migrate: expand
-- Migration tp-023: AA-1015 — per-session / per-IP limits on the AI routes (narrate, search): a durable fixed-window
-- counter shared by every Lambda container.
--
-- Why: API Gateway throttles are per route and shared by every visitor, and an in-process counter is per container
-- (up to 15 browse / 5 assembly instances), so one visitor or a bot could use a whole day's AI budget. The Lambdas
-- (backend/shared/ratelimit.py) count each AI-backed request here and refuse it with 429 once its window is full:
-- 10 narrations per hour per session, 30 searches per minute per traveller IP, twice that for a signed-in traveller
-- (capacity plan S261 §2.5; numbers in backend/config.py, env-overridable).
--
-- tripplanner.ai_rate_counter (key_hash, window_start, count), PK (key_hash, window_start):
--   key_hash      hex HMAC-SHA256 of "<scope>|<kind>|<value>" (scope narrate | search, kind session | ip | account),
--                 keyed with the edge API key, so the raw IP, session id or account never reaches the table and an
--                 IPv4 hash cannot be reversed by trying every address. No personal data is stored.
--   window_start  start of the fixed window (UTC, epoch-aligned: hour for narrate, minute for search).
--   count         requests counted in the window (an upsert adds 1; a refused request is counted too).
-- Index window_start for the purge. Retention (data standards DM-7.1, root row added before this copy): rows whose
-- window started more than 2 days ago are deleted by the jobs Lambda kind tp_retention_ai_rate_counter (DM-7.2).
--
-- Grants: the runtime role tripplanner gets SELECT, INSERT, UPDATE, DELETE (the tp_owner default privileges of tp-013
-- give the same; repeated here so the file states it). DELETE is the retention kind's (jobs Lambda, same role).
--
-- Class: expand (root ADR 0017 d3): one new table with its primary key, one index, a comment, a grant to the owner's
-- own runtime role and the registration. Nothing existing changes. The code PR that reads it carries this file
-- (expand: one PR); code that runs before it is applied fails open on the limiter (an ERROR line, no limit) and the
-- spend cap still applies.
-- Re-runnable (test_replay_twice_pg.py replays every file twice): IF NOT EXISTS, repeated grant / comment,
-- ON CONFLICT DO NOTHING.
-- Undo: a later tp- file with `-- migrate: destructive` (DROP TABLE tripplanner.ai_rate_counter), after the readers
-- are gone.
--
-- Applied through AA-CIS-Infra (byte-identical copy db/migrations/tripplanner/023_ai_rate_counter.sql, Migration Sync)
-- as tp_owner, the live owner of schema tripplanner since tp-013 (XD8). Never run it from a laptop.

BEGIN;

CREATE TABLE IF NOT EXISTS tripplanner.ai_rate_counter (
    key_hash     TEXT        NOT NULL,
    window_start TIMESTAMPTZ NOT NULL,
    count        INT         NOT NULL DEFAULT 0,

    CONSTRAINT ai_rate_counter_pkey PRIMARY KEY (key_hash, window_start),
    CONSTRAINT ai_rate_counter_count_chk CHECK (count >= 0)
);
CREATE INDEX IF NOT EXISTS ai_rate_counter_window_idx ON tripplanner.ai_rate_counter (window_start);

COMMENT ON TABLE tripplanner.ai_rate_counter IS
    'tp-023 (AA-1015): fixed-window request counters of the AI routes (narrate per session, search per IP), keyed by an HMAC of scope + kind + value (no personal data). Retention: windows older than 2 days are deleted by tp_retention_ai_rate_counter.';

GRANT SELECT, INSERT, UPDATE, DELETE ON tripplanner.ai_rate_counter TO tripplanner;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-023', now(), 'AA-1015: tripplanner.ai_rate_counter (per-session / per-IP AI route limits)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
