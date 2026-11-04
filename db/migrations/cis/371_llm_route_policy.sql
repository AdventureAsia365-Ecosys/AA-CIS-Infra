-- migrate: expand
-- Migration 371: AA-1042 (S268, AI gateway route control center: Route trace, Alerts, Quality guard) — the per-stage
-- route alert thresholds and the hold-for-review switch of content written by a fallback model.
--
-- Why. Tech lead decision S267: "every fallback is logged, traced and alerted". The gateway now tags every attempt row
-- of one request with the same route trace id (shared.llm_call_log.quality_signal ->> 'route_trace', no new ledger
-- column), the job kind llm_route_watch (shared.job, every 15 min + a daily digest) raises the fallback / last model /
-- primary back / cost shift alerts, and content written by a fallback model is marked in QA. The thresholds and the
-- hold switch are data so an admin tunes them per stage on AI gateway > Trace without a deploy.
--
-- What.
--   1. shared.llm_route_policy, PK stage ('*' = the defaults of every stage without its own row):
--        fallback_alert_pct    alert when at least this share (1-100 %) of a stage's requests in the watch window
--                              was served by a fallback rung; NULL = the '*' row, else the code default (20);
--        min_requests          the fallback rate alerts only from this many requests in the window (1-10000);
--                              NULL = '*' row, else 5;
--        alert_last_rung       alert when a request reached the last model of the stage's route (NULL = '*' row,
--                              else true);
--        cost_shift_usd        alert when fallback-served requests cost at least this much more than the primary
--                              would have in the last 24 h (0.01-10000 USD); NULL = '*' row, else 1.00;
--        hold_fallback_writes  content written by a fallback model is HELD for review (A1: Review Queue; T9: the
--                              admin-only held label, the tenant still receives the piece) instead of only marked;
--                              NULL = '*' row, else false (off by default, tech lead S267);
--        notes, updated_at, updated_by.
--   2. GRANT cis_app SELECT, INSERT, UPDATE, DELETE (GET / PUT / DELETE /admin/ai-gateway/route-policy/{stage}).
--   3. Register 371.
--
-- Behaviour. None on apply: no row = the code defaults (fallback >= 20 % of >= 5 requests, last model on, cost
-- shift 1 USD, hold off). Before this file is applied the code reads no row (it catches the missing table) and the
-- policy writes answer 503.
--
-- Class: expand (root ADR 0017 d3): one new table, its constraints, a grant on it and comments; no FK, no existing
-- object changes, no seed row, no DO block. Retention row (DM-7.1): root data standards Part B section 7, in the
-- root PR of this change.
--
-- Number. 368 is the highest on main (04/11); 369-372 are held by the parallel lanes of S268 (orchestrator hint):
-- renumber to main max + 1 when this lands first.
--
-- Rollback (a new forward migration, after the code is reverted): DROP TABLE shared.llm_route_policy; (a destructive
-- file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.llm_route_policy (
    stage                 text          NOT NULL,
    fallback_alert_pct    smallint,
    min_requests          integer,
    alert_last_rung       boolean,
    cost_shift_usd        numeric(10,2),
    hold_fallback_writes  boolean,
    notes                 text,
    updated_at            timestamptz   NOT NULL DEFAULT now(),
    updated_by            text          NOT NULL DEFAULT 'migration:371',
    CONSTRAINT llm_route_policy_pkey PRIMARY KEY (stage),
    CONSTRAINT llm_route_policy_stage_check CHECK (stage = '*' OR stage ~ '^[a-z0-9][a-z0-9_.-]{0,63}$'),
    CONSTRAINT llm_route_policy_pct_check CHECK (fallback_alert_pct IS NULL OR fallback_alert_pct BETWEEN 1 AND 100),
    CONSTRAINT llm_route_policy_min_check CHECK (min_requests IS NULL OR min_requests BETWEEN 1 AND 10000),
    CONSTRAINT llm_route_policy_cost_check CHECK (cost_shift_usd IS NULL OR cost_shift_usd BETWEEN 0.01 AND 10000),
    CONSTRAINT llm_route_policy_notes_check CHECK (notes IS NULL OR length(notes) <= 500),
    CONSTRAINT llm_route_policy_updated_by_check CHECK (length(updated_by) <= 128)
);

COMMENT ON TABLE shared.llm_route_policy IS
    'AA-1042 (CIS 371): per LLM stage (or * = the defaults) the route alert thresholds of the llm_route_watch job '
    '(fallback rate, last model reached, cost shift) and whether content written by a fallback model is held for '
    'review. Read by shared/llm_client/route_watch.py (30 s cache per process); edited by PUT / DELETE '
    '/admin/ai-gateway/route-policy/{stage}. No row = the code defaults.';
COMMENT ON COLUMN shared.llm_route_policy.fallback_alert_pct IS
    'AA-1042 (371): alert when at least this share (%) of the stage''s requests in the 60 min watch window was served '
    'by a fallback rung (not the first attempt). NULL = the * row, else 20.';
COMMENT ON COLUMN shared.llm_route_policy.min_requests IS
    'AA-1042 (371): the fallback rate alerts only from this many requests in the window. NULL = the * row, else 5.';
COMMENT ON COLUMN shared.llm_route_policy.alert_last_rung IS
    'AA-1042 (371): alert when a request reached the last model of the stage''s route. NULL = the * row, else true.';
COMMENT ON COLUMN shared.llm_route_policy.cost_shift_usd IS
    'AA-1042 (371): alert when fallback-served requests cost at least this many USD more than the primary would have '
    '(its 7 day average) over the last 24 h. NULL = the * row, else 1.00.';
COMMENT ON COLUMN shared.llm_route_policy.hold_fallback_writes IS
    'AA-1042 (371): content written by a fallback model is held for review (A1 Review Queue, T9 admin-only held '
    'label; the tenant still receives it) instead of only marked. NULL = the * row, else false.';

GRANT SELECT, INSERT, UPDATE, DELETE ON shared.llm_route_policy TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('371', now(), 'AA-1042: shared.llm_route_policy (route alert thresholds and the fallback hold switch per '
                      'stage)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
