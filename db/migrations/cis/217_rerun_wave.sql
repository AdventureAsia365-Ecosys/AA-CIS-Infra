-- Migration 217: AA-727 — a rerun wave as an object.
--
-- A wave (rerun of a country / a set of tours through A1→A3) used to be tracked by hand: the
-- Thailand wave (S212) stopped silently with 19 tours stuck and the first manual count was wrong.
-- A wave row records the expected tour set BEFORE the run; the report (services/waves/report.py)
-- derives every tour's state from what already exists (shared.job by payload tour_id inside the
-- wave's time window, published_tours, review_queue, decision_log, llm_call_log, dfs_call_log),
-- so no pipeline code has to write wave ids.
--
-- status: open → complete (every expected tour reached a terminal state once the wave's jobs
-- finished) | incomplete (jobs finished but some tours did not — alert raised once) | closed
-- (an admin closed it; closed_at also ends the job window).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate
-- workflow); keep the two identical.

BEGIN;

CREATE TABLE IF NOT EXISTS shared.rerun_wave (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name               TEXT NOT NULL,
    country            TEXT,
    expected_tour_ids  UUID[] NOT NULL CHECK (cardinality(expected_tour_ids) > 0),
    status             TEXT NOT NULL DEFAULT 'open'
                       CHECK (status IN ('open', 'complete', 'incomplete', 'closed')),
    notes              TEXT,
    created_by         TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at          TIMESTAMPTZ,
    last_checked_at    TIMESTAMPTZ,
    last_check         JSONB
);

CREATE INDEX IF NOT EXISTS idx_rerun_wave_open ON shared.rerun_wave(created_at DESC) WHERE status = 'open';

COMMENT ON TABLE shared.rerun_wave IS
    'AA-727 — rerun wave: expected tour set written before the run; report/check derive tour '
    'states from shared.job (payload tour_id, wave window), published_tours and review_queue.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('217', now(), 'AA-727: shared.rerun_wave — rerun wave as an object (expected set + status)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
