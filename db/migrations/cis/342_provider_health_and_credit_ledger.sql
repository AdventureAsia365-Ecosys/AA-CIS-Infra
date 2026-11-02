-- migrate: expand
-- Migration 342: AA-1025 (S263 gateway plan, slices B3 and B5) — the shared circuit of the non-LLM providers and the
-- shared credit ledger of the providers without a balance API.
--
-- Why.
--   B3. Jev (TypeSafe), DataForSEO and Geoapify have no shared circuit. Jev's breaker (decide.jev_breaker_open) lives
--   in one process and trips only on a 402; an outage or a run of 5xx costs every api / worker task its own timeouts
--   (3 attempts of 3 s per decide). DataForSEO and Geoapify have none. The LLM breaker's table
--   (shared.llm_provider_health, 309) is keyed (connection_key, model_key) with model_key a foreign key to the model
--   catalog, so a provider without models cannot be written there without changing that table (a contract change on
--   a hot routing table). A table of its own, keyed by the connection, is the smaller change: same columns, same state
--   machine (shared/llm_client/breaker.py pure transitions), no change to any existing object.
--   B5. The direct vendor APIs (anthropic, openai) have no balance API the gateway may call, and nothing warns before
--   the credit runs out (the probe only sees QUOTA_EXHAUSTED once it is gone). Jev has its own ledger
--   (shared.jev_credit_topup, 209); this one is per connection, so every topups_minus_spend connection shares it.
--
-- What.
--   1. shared.provider_health, PK connection_key (FK shared.llm_provider_connection ON DELETE CASCADE: derived
--      state, it goes with its connection): the 309 columns without model_key. Written by shared/provider_circuit.py
--      on the outcome of each Jev / DataForSEO / Geoapify call; every api / worker task reads the same rows.
--   2. shared.provider_credit_topup: one row per recorded top-up or balance check of a connection.
--        kind 'topup' (amount > 0, added to the balance) or 'opening_balance' (amount >= 0, the balance read from
--        the provider's console at effective_at; the estimate starts again from the newest one);
--        effective_at (when the money arrived / the balance was read), amount_usd numeric(10,2), note (<= 500
--        chars), created_by, created_at. FK to the connection without CASCADE: a money record never disappears with a
--        registry edit. Index (connection_key, effective_at DESC).
--      The estimate (shared/provider_credit.py): the newest opening balance (or the first top-up) plus the top-ups
--      after it, minus the connection's logged spend (shared.llm_call_log) since then.
--   3. GRANT cis_app SELECT, INSERT, UPDATE, DELETE on provider_health (the api and the worker write it), SELECT,
--      INSERT, DELETE on provider_credit_topup (the admin records and deletes entries; never edited in place).
--   4. Register 342.
--
-- Behaviour. None on apply: no row = every provider circuit closed, no ledger entry = no estimate (the Providers page
-- shows "not read"). Before this file is applied the provider circuit runs per process (the code catches the missing
-- table) and the credit routes answer 503.
--
-- Class: expand (root ADR 0017 d3): two new tables, their constraints and indexes, grants on them and comments. The
-- foreign keys only add the internal RI triggers on shared.llm_provider_connection; no existing object changes, no
-- DO block. Retention rows (DM-7.1): root data standards Part B section 7, in the root PR of this change.
--
-- Number. 338 is the highest on main (02/11); 339 / 340 (lane l1) and 341 (lane l2) are held by parallel lanes of
-- S264. 343 (the balance_source of the anthropic / openai rows, contract) follows in the same migration-only PR.
--
-- Rollback (a new forward migration, after the code is reverted):
--   DROP TABLE shared.provider_credit_topup; DROP TABLE shared.provider_health;   (a destructive file, DRY RUN)
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.provider_health (
    connection_key        text        NOT NULL,
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
    CONSTRAINT provider_health_pkey PRIMARY KEY (connection_key),
    CONSTRAINT provider_health_connection_fkey FOREIGN KEY (connection_key)
        REFERENCES shared.llm_provider_connection (connection_key) ON DELETE CASCADE,
    CONSTRAINT provider_health_class_check CHECK (last_error_class IS NULL OR last_error_class IN
        ('access_denied', 'quota_exhausted', 'throttled', 'credential', 'other')),
    CONSTRAINT provider_health_failures_check CHECK (consecutive_failures >= 0),
    CONSTRAINT provider_health_streak_check CHECK (open_streak BETWEEN 0 AND 1000),
    CONSTRAINT provider_health_error_len_check CHECK (last_error IS NULL OR length(last_error) <= 300)
);

COMMENT ON TABLE shared.provider_health IS
    'AA-1025 B3 (CIS 342): circuit breaker state of a non-LLM provider connection (typesafe, dataforseo, geoapify), '
    'shared by every api / worker task. Written by shared/provider_circuit.py on call outcomes; read by the clients '
    'before a call and by GET /admin/ai-gateway/providers. No row = closed.';
COMMENT ON COLUMN shared.provider_health.circuit_open_until IS
    'AA-1025 B3 (342): NULL = closed; in the future = open (calls are refused without being sent); in the past = '
    'half-open (one probe call may try it, lease in probe_until; its success clears this column).';
COMMENT ON COLUMN shared.provider_health.last_error_class IS
    'AA-1025 B3 (342): the class of the last failure (provider_circuit.failure_class: HTTP 401 / 403 access_denied, '
    '402 quota_exhausted, 429 throttled, 5xx / timeout / transport other). It sets the threshold and open period.';

GRANT SELECT, INSERT, UPDATE, DELETE ON shared.provider_health TO cis_app;

CREATE TABLE IF NOT EXISTS shared.provider_credit_topup (
    id              bigint GENERATED ALWAYS AS IDENTITY,
    connection_key  text          NOT NULL,
    kind            text          NOT NULL DEFAULT 'topup',
    effective_at    timestamptz   NOT NULL DEFAULT now(),
    amount_usd      numeric(10,2) NOT NULL,
    note            text,
    created_by      text,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT provider_credit_topup_pkey PRIMARY KEY (id),
    CONSTRAINT provider_credit_topup_connection_fkey FOREIGN KEY (connection_key)
        REFERENCES shared.llm_provider_connection (connection_key),
    CONSTRAINT provider_credit_topup_kind_check CHECK (kind IN ('topup', 'opening_balance')),
    CONSTRAINT provider_credit_topup_amount_check CHECK (
        (kind = 'topup' AND amount_usd > 0) OR (kind = 'opening_balance' AND amount_usd >= 0)),
    CONSTRAINT provider_credit_topup_note_check CHECK (note IS NULL OR length(note) <= 500)
);

CREATE INDEX IF NOT EXISTS idx_provider_credit_topup_connection
    ON shared.provider_credit_topup (connection_key, effective_at DESC);

COMMENT ON TABLE shared.provider_credit_topup IS
    'AA-1025 B5 (CIS 342): the credit ledger of the provider connections whose balance_source is topups_minus_spend '
    '(no balance API: the direct anthropic / openai APIs). Estimate = the newest opening balance (or the first '
    'top-up) + the top-ups after it - the logged spend since then (shared/provider_credit.py). Jev keeps '
    'shared.jev_credit_topup.';
COMMENT ON COLUMN shared.provider_credit_topup.kind IS
    'AA-1025 B5 (342): topup = money added (amount > 0); opening_balance = the balance read from the provider console '
    'at effective_at (amount >= 0): the estimate restarts from the newest one.';

GRANT SELECT, INSERT, DELETE ON shared.provider_credit_topup TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('342', now(), 'AA-1025 B3 / B5: shared.provider_health (non-LLM provider circuit), '
                      'shared.provider_credit_topup (credit ledger per connection)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
