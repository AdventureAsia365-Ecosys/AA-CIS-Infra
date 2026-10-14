-- Migration tp-010: AA-805 — AI Phase 0: narration cache + daily model-spend counter.
--
-- narration_cache: /trip/{id}/narrate reuses a narration for an identical itinerary instead of
-- calling the model again. Key = sha256 over (mode, prompt version, each day's component id, name,
-- text and source tour day) — computed in backend/assembly/narration_cache.py. The text comes only
-- from catalog content (no traveller data), so one entry serves every trip with that itinerary.
-- Only narrations that used the model are stored; entries expire by created_at
-- (NARRATION_CACHE_TTL_HOURS, read-side).
--
-- llm_spend_daily: the TripPlanner gateway (backend/shared/llm_gateway.py) adds every priced tp_*
-- call here and refuses new model calls once today's total reaches TP_DAILY_SPEND_CAP_USD. Kept in
-- this schema because the `tripplanner` role only has INSERT on shared.llm_call_log (CIS
-- migration 173); shared.llm_call_log stays the billing source of truth. Calls with no catalog
-- price add 0 USD and count in unpriced_calls.
--
-- Role `tripplanner` exists (tp-001), so the grants are not wrapped in IF EXISTS (schema-ownership
-- rule 5). Applied through AA-CIS-Infra DB Migrate (owner `tripplanner`), key tp-010. Re-running is
-- a no-op.

BEGIN;

CREATE TABLE IF NOT EXISTS tripplanner.narration_cache (
    itinerary_hash TEXT PRIMARY KEY,               -- sha256 hex, see narration_cache.py
    mode           TEXT NOT NULL,                  -- compose | renarrate
    narration      TEXT NOT NULL,
    source         TEXT NOT NULL,                  -- llm | mixed (master-only is never cached)
    days           INT  NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    hits           INT  NOT NULL DEFAULT 0,
    last_hit_at    TIMESTAMPTZ,

    CONSTRAINT narration_cache_mode_chk CHECK (mode IN ('compose', 'renarrate')),
    CONSTRAINT narration_cache_source_chk CHECK (source IN ('llm', 'mixed'))
);
CREATE INDEX IF NOT EXISTS narration_cache_created_at_idx ON tripplanner.narration_cache (created_at);

COMMENT ON TABLE tripplanner.narration_cache IS
    'AA-805: narration reused for an identical itinerary (hash of catalog content, no user data). Safe to TRUNCATE.';

CREATE TABLE IF NOT EXISTS tripplanner.llm_spend_daily (
    day            DATE    NOT NULL,               -- UTC day
    stage          TEXT    NOT NULL,               -- tp_compose, tp_search_embed, ...
    cost_usd       NUMERIC NOT NULL DEFAULT 0,
    calls          INT     NOT NULL DEFAULT 0,     -- every logged attempt, failed ones included
    unpriced_calls INT     NOT NULL DEFAULT 0,     -- calls whose model had no catalog price
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (day, stage)
);

COMMENT ON TABLE tripplanner.llm_spend_daily IS
    'AA-805: TripPlanner model spend per UTC day and stage, for the TP_DAILY_SPEND_CAP_USD hard stop. Billing truth is shared.llm_call_log.';

GRANT SELECT, INSERT, UPDATE ON tripplanner.narration_cache TO tripplanner;
GRANT SELECT, INSERT, UPDATE ON tripplanner.llm_spend_daily TO tripplanner;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-010', now(), 'AA-805: tripplanner.narration_cache + tripplanner.llm_spend_daily (AI Phase 0 cache and daily spend cap)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
