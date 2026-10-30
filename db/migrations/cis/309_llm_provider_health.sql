-- migrate: expand
-- Migration 309: AA-1002 (LLM gateway slice S4) — shared.llm_provider_health: the circuit breaker's shared state.
--
-- Why. The gateway tries a catalog model on its deployments (slice S3, vendor_route.deployment_plan). Without a
-- breaker every call still goes to a deployment that refuses every request (Bedrock "Error 002" on the LLM account
-- since 29/10, about 2,400 doomed attempts a week before that, AA-843), and each ECS task learns it again with its own
-- failed calls. shared/llm_client/breaker.py keeps one circuit per deployment (connection x catalog model) in this
-- table, so a circuit one task opens is skipped by every task, and the admin sees the state per connection.
--
-- What.
--   1. shared.llm_provider_health, PK (connection_key, model_key):
--        last_ok_at, last_error_at, last_error_class (access_denied / quota_exhausted / throttled / credential /
--        other), last_error (first 300 chars, never a key), consecutive_failures, circuit_open_until (NULL = closed;
--        in the future = open; in the past = half-open), open_streak (openings without a success, doubles the open
--        period), opened_at, probe_until (the one half-open probe's lease), updated_at.
--      FKs to shared.llm_provider_connection and shared.llm_model_catalog ON DELETE CASCADE: health is derived state,
--      it goes with its connection or model (no existing row can block a delete).
--   2. GRANT SELECT, INSERT, UPDATE, DELETE to cis_app (the api and the worker write it on call outcomes; the admin
--      reads it through /admin/llm-availability). No tripplanner grant (TripPlanner keeps its own gateway until S8).
--   3. Register 309.
--
-- Behaviour. None on apply: an empty table means every circuit is closed. Before this file is applied the breaker runs
-- per process (the code catches the missing table), so code and migration may ship in either order.
--
-- Class: expand (root ADR 0017 d3): one new table, its constraints, a grant on it and comments; no change to any
-- existing object (the FKs only add the internal RI triggers on the two referenced tables), no DO block.
--
-- Number. 307 is the highest on main (30/10); 308 is AA-1000's stage row (S259).
--
-- Rollback (a new forward migration, after the code is reverted or LLM_CIRCUIT_BREAKER=off):
--   DROP TABLE shared.llm_provider_health;   (a destructive file)
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.llm_provider_health (
    connection_key        text        NOT NULL,
    model_key             text        NOT NULL,
    last_ok_at            timestamptz,
    last_error_at         timestamptz,
    last_error_class      text,
    last_error            text,
    consecutive_failures  integer     NOT NULL DEFAULT 0,
    circuit_open_until    timestamptz,
    open_streak           smallint    NOT NULL DEFAULT 0,
    opened_at             timestamptz,
    probe_until           timestamptz,
    updated_at            timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT llm_provider_health_pkey PRIMARY KEY (connection_key, model_key),
    CONSTRAINT llm_provider_health_connection_fkey FOREIGN KEY (connection_key)
        REFERENCES shared.llm_provider_connection (connection_key) ON DELETE CASCADE,
    CONSTRAINT llm_provider_health_model_fkey FOREIGN KEY (model_key)
        REFERENCES shared.llm_model_catalog (model_key) ON DELETE CASCADE,
    CONSTRAINT llm_provider_health_class_check CHECK (last_error_class IS NULL OR last_error_class IN
        ('access_denied', 'quota_exhausted', 'throttled', 'credential', 'other')),
    CONSTRAINT llm_provider_health_failures_check CHECK (consecutive_failures >= 0),
    CONSTRAINT llm_provider_health_streak_check CHECK (open_streak BETWEEN 0 AND 1000),
    CONSTRAINT llm_provider_health_error_len_check CHECK (last_error IS NULL OR length(last_error) <= 300)
);

COMMENT ON TABLE shared.llm_provider_health IS
    'AA-1002 (CIS 309, gateway slice S4): circuit breaker state per deployment (connection x catalog model), shared by '
    'every api / worker task. Written by shared/llm_client/breaker.py on call outcomes; read by the routing plan and '
    'GET /admin/llm-availability. No row = closed.';
COMMENT ON COLUMN shared.llm_provider_health.circuit_open_until IS
    'AA-1002 (309): NULL = closed; in the future = open (the deployment is skipped); in the past = half-open (one '
    'probe call may try it, lease in probe_until; its success clears this column).';
COMMENT ON COLUMN shared.llm_provider_health.last_error_class IS
    'AA-1002 (309): shared/llm_client/errors.classify of the last failure, or credential (the connection key could not '
    'be read). The class sets how many failures open the circuit and for how long (breaker.RULES).';
COMMENT ON COLUMN shared.llm_provider_health.open_streak IS
    'AA-1002 (309): openings since the last success; each failed half-open probe doubles the open period (capped).';

GRANT SELECT, INSERT, UPDATE, DELETE ON shared.llm_provider_health TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('309', now(), 'AA-1002 S4: shared.llm_provider_health (circuit breaker state per deployment)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
