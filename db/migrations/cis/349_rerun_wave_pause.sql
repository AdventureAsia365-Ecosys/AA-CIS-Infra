-- Migration 349: AA-1025 (S263 gateway plan, slice H2, capacity S12) — a rerun wave can be paused: shared.rerun_wave
-- gains paused_at, paused_by and pause_reason.
--
-- Why. The approved capacity plan (§2.3, §5.1) asks that a wave pause on its own when a circuit the prod line depends
-- on opens, so bulk work never competes with tenants and TripPlanner for a refusing or throttled account, and that the
-- app profile's bulk pause (shared.llm_app_profile.bulk_paused, 345) holds the waves. A wave has no paused state today
-- (status open | complete | incomplete | closed), so nobody can see that a wave waits, or why.
--
-- What.
--   1. ALTER TABLE shared.rerun_wave ADD COLUMN (all nullable, no default):
--        paused_at     when the wave was paused (NULL = running);
--        paused_by     who paused it: 'capacity' (the worker: a prod guard circuit refuses or the app's bulk pause is
--                      on; it resumes the wave by itself when neither holds any more), else the staff actor;
--        pause_reason  why, in words (<= 500 characters).
--      The status stays 'open' while paused: the deploy gate, the retention scheduler and the writing-memory miner
--      keep treating a paused wave as open (its expected set must not be split across two images), and the wave
--      check does not end a paused wave as incomplete while its jobs wait in the queue.
--      CHECKs: paused_at and paused_by are set together; the text lengths.
--   2. Register 349.
--
-- Behaviour. None on apply: every wave stays unpaused. The worker writes the columns once the code PR is deployed;
-- before that the code catches the missing columns and pauses nothing. shared.rerun_wave is small (~25 rows) and not
-- a hot table (Infra owners.yaml expand_hot_tables): ADD COLUMN without a default and CHECKs on all-NULL columns take
-- a short ACCESS EXCLUSIVE lock.
--
-- Class: contract (root ADR 0017 d3): new columns and constraints on an existing table. No readiness raise in this
-- migration-only PR (MIG-4); on Dev, Infra Migration Apply applies it once every job table is idle (root ADR 0017a).
-- Order: after 348 (same PR, batch cis 348-349).
--
-- Rollback (a new forward migration, after the code is reverted): ALTER TABLE shared.rerun_wave DROP COLUMN
-- pause_reason, DROP COLUMN paused_by, DROP COLUMN paused_at; (a destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

ALTER TABLE shared.rerun_wave
    ADD COLUMN IF NOT EXISTS paused_at    timestamptz,
    ADD COLUMN IF NOT EXISTS paused_by    text,
    ADD COLUMN IF NOT EXISTS pause_reason text;

ALTER TABLE shared.rerun_wave DROP CONSTRAINT IF EXISTS rerun_wave_pause_pair_check;
ALTER TABLE shared.rerun_wave ADD CONSTRAINT rerun_wave_pause_pair_check
    CHECK ((paused_at IS NULL) = (paused_by IS NULL));
ALTER TABLE shared.rerun_wave DROP CONSTRAINT IF EXISTS rerun_wave_pause_text_check;
ALTER TABLE shared.rerun_wave ADD CONSTRAINT rerun_wave_pause_text_check
    CHECK ((paused_by IS NULL OR length(paused_by) <= 128) AND (pause_reason IS NULL OR length(pause_reason) <= 500));

COMMENT ON COLUMN shared.rerun_wave.paused_at IS
    'AA-1025 H2 (349): when the wave was paused (NULL = running). The status stays open while paused; the bulk job '
    'kinds wait in the queue (shared/llm_client/capacity.py).';
COMMENT ON COLUMN shared.rerun_wave.paused_by IS
    'AA-1025 H2 (349): capacity = paused by the worker (a prod guard circuit refuses, or the app bulk pause is on); '
    'it resumes the wave by itself when neither holds. Else the staff actor.';
COMMENT ON COLUMN shared.rerun_wave.pause_reason IS
    'AA-1025 H2 (349): why the wave is paused, in words (<= 500 characters).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('349', now(), 'AA-1025 H2: shared.rerun_wave paused_at / paused_by / pause_reason (a wave pauses while a '
                      'prod guard circuit refuses or the bulk pause is on)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
