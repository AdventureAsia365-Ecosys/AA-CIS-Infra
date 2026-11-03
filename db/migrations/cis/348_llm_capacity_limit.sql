-- migrate: expand
-- Migration 348: AA-1025 (S263 gateway plan, slice H2, capacity S12) — the token-per-minute limit of a connection or
-- of one model on it, the share of it the bulk and dev lines may hold, and the circuits that guard the prod line.
--
-- Why. The approved capacity plan (docs/audits/2026-10-31-S261-llm-capacity-plan §2.2-§2.3, §5.1; root ADR 0009
-- decisions 4-5) lists three gaps before prod: the connection limiter counts requests only (max_concurrency,
-- rpm_limit, 304), never tokens, while AWS meters every Bedrock model in tokens per minute; nothing keeps a wave
-- (bulk) from taking the whole quota while tenants and TripPlanner (prod) wait; and nothing pauses a wave when a
-- circuit that prod depends on opens. The limits are data (per connection, or per model on a connection, the unit
-- AWS meters), so the tech lead sets them from the Service Quotas numbers without a deploy.
--
-- What.
--   1. shared.llm_capacity_limit, PK (connection_key, model_key):
--        connection_key  FK shared.llm_provider_connection ON DELETE CASCADE (configuration of the connection);
--        model_key       '*' = the whole connection, else one catalog model on it (checked by the admin route; not
--                        a FK because of '*');
--        tpm_limit       tokens per rolling minute reserved before a call (prompt at ~4 characters per token +
--                        max_tokens, the capacity plan's "TPM giữ chỗ"); NULL = no token limit at this level. Per
--                        process, like rpm_limit: each ECS task enforces it on its own calls (set it to the quota
--                        share of one task, capacity plan §2.2 (a));
--        bulk_pct        the share of tpm_limit the bulk line (waves, catalogue backfills) may hold, 1-100, default
--                        50; a bulk call also waits while a prod call waits on the same limit (bulk yields to prod);
--        dev_pct         the share the dev line (ad-hoc scripts, eval runs, probes) may hold, NULL = no own cap;
--        prod_guard      the connection (model_key '*') or the deployment carries the prod line: while its circuit
--                        is open the worker postpones LLM job claims, and while it still refuses the open waves are
--                        paused (shared/llm_client/capacity.py);
--        notes, updated_at, updated_by.
--      A row sets a limit, a guard or both (capacity_limit_does_something).
--   2. GRANT cis_app SELECT, INSERT, UPDATE, DELETE (the admin route PUT / DELETE /admin/ai-gateway/capacity).
--   3. Register 348.
--
-- Behaviour. None on apply: no row = no token limit and no prod guard (the gateway and the worker behave as today).
-- Before this file is applied the code reads no row (it catches the missing table) and the admin routes answer 503.
--
-- Class: expand (root ADR 0017 d3): one new table, its constraints, a grant on it and comments; the foreign key only
-- adds the internal RI triggers on shared.llm_provider_connection; no existing object changes, no seed row, no DO
-- block. Retention row (DM-7.1): root data standards Part B section 7, in the root PR of this change.
--
-- Number. 346 is the highest on main (03/11); 347 is held by a parallel lane of S265. 349 (shared.rerun_wave pause
-- columns, contract) follows in the same migration-only PR (batch cis 348-349, MIG-4: no readiness raise).
--
-- Rollback (a new forward migration, after the code is reverted): DROP TABLE shared.llm_capacity_limit; (a
-- destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.llm_capacity_limit (
    connection_key  text        NOT NULL,
    model_key       text        NOT NULL DEFAULT '*',
    tpm_limit       integer,
    bulk_pct        smallint    NOT NULL DEFAULT 50,
    dev_pct         smallint,
    prod_guard      boolean     NOT NULL DEFAULT false,
    notes           text,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      text        NOT NULL DEFAULT 'migration:348',
    CONSTRAINT llm_capacity_limit_pkey PRIMARY KEY (connection_key, model_key),
    CONSTRAINT llm_capacity_limit_connection_fkey FOREIGN KEY (connection_key)
        REFERENCES shared.llm_provider_connection (connection_key) ON DELETE CASCADE,
    CONSTRAINT llm_capacity_limit_model_check CHECK (model_key = '*' OR model_key ~ '^[a-z0-9][a-z0-9._-]{0,99}$'),
    CONSTRAINT llm_capacity_limit_tpm_check CHECK (tpm_limit IS NULL OR tpm_limit BETWEEN 1 AND 100000000),
    CONSTRAINT llm_capacity_limit_bulk_pct_check CHECK (bulk_pct BETWEEN 1 AND 100),
    CONSTRAINT llm_capacity_limit_dev_pct_check CHECK (dev_pct IS NULL OR dev_pct BETWEEN 1 AND 100),
    CONSTRAINT llm_capacity_limit_does_something CHECK (tpm_limit IS NOT NULL OR prod_guard),
    CONSTRAINT llm_capacity_limit_notes_check CHECK (notes IS NULL OR length(notes) <= 500),
    CONSTRAINT llm_capacity_limit_updated_by_check CHECK (length(updated_by) <= 128)
);

COMMENT ON TABLE shared.llm_capacity_limit IS
    'AA-1025 H2 (CIS 348, capacity S12): the token-per-minute limit of an LLM connection (model_key *) or of one '
    'model on it, the share the bulk and dev lines may hold, and whether its circuit guards the prod line. Read by '
    'shared/llm_client/capacity.py (20 s cache per process); edited by PUT / DELETE /admin/ai-gateway/capacity. No '
    'row = no limit, no guard.';
COMMENT ON COLUMN shared.llm_capacity_limit.tpm_limit IS
    'AA-1025 H2 (348): tokens per rolling minute reserved before a call (prompt chars / 4 + max_tokens), per process '
    '(each ECS task enforces its own share). A call over it waits (prod up to 65 s, bulk up to 180 s), then fails '
    'throttled (LimiterSaturated: the route moves on, a job retries with backoff). NULL = no token limit here.';
COMMENT ON COLUMN shared.llm_capacity_limit.bulk_pct IS
    'AA-1025 H2 (348): the share of tpm_limit (1-100) the bulk line may hold; a bulk call also waits while a prod '
    'call waits on the same limit (bulk yields to prod).';
COMMENT ON COLUMN shared.llm_capacity_limit.dev_pct IS
    'AA-1025 H2 (348): the share of tpm_limit (1-100) the dev line (ad-hoc, eval, probes) may hold; NULL = none.';
COMMENT ON COLUMN shared.llm_capacity_limit.prod_guard IS
    'AA-1025 H2 (348): this connection (model_key *: its connection circuit) or deployment (its circuit) carries the '
    'prod line. While the circuit is open the worker postpones LLM job claims; while it still refuses the open rerun '
    'waves are paused (shared.rerun_wave.paused_at, 349) and the bulk job kinds wait.';

GRANT SELECT, INSERT, UPDATE, DELETE ON shared.llm_capacity_limit TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('348', now(), 'AA-1025 H2: shared.llm_capacity_limit (TPM limit per connection / model, bulk and dev line '
                      'shares, prod guard circuits)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
