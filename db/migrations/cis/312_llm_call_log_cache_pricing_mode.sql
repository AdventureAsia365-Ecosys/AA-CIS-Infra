-- Migration 312: AA-1002 (LLM gateway slice S6) — cost parity: the cache split and the pricing basis of every call.
--
-- Why. shared.llm_call_log stored tokens_in (the whole prompt) and cost_usd only: a cached prompt and an uncached one
-- of the same size looked the same, and a model no price source knew was silently priced at Sonnet rates with nothing
-- to tell the row apart from a real price. shared/llm_client/pricing.quote now prices one request from its full usage
-- (5-minute / 1-hour cache writes, cache reads, batch, the Haiku 5.5 long-prompt tier, US-only inference, deployment
-- price overrides) and says how it priced it.
--
-- What.
--   1. shared.llm_call_log: cache_read_tokens integer, cache_write_tokens integer (part of tokens_in), pricing_mode
--      text — 'override' | 'catalog' | 'code_table' | 'estimate', then '+batch', then '+geo_us'
--      (pricing.PRICING_MODE_RE). All nullable: NULL = not said (rows before 312, callers that pass nothing). A row
--      priced by estimate is always flagged (call_log derives it from the model when the caller is silent). CHECKs
--      (cache tokens >= 0, pricing_mode pattern) added NOT VALID then validated (every existing row is NULL).
--   2. shared.llm_call_daily: cache_read_tokens, cache_write_tokens, estimate_calls bigint NOT NULL DEFAULT 0 (a
--      constant default: no rewrite). services/retention/rollups.py fills them once both tables have the columns.
--   3. Register 312.
--   Grants unchanged: cis_app has table-level INSERT / UPDATE / SELECT on both tables; tripplanner INSERT on
--   llm_call_log (its gateway names its columns, it writes NULL here).
--
-- Behaviour. None on apply. Until it is applied the gateway writes rows without these columns (call_log falls back to
-- the pre-S6 INSERT on UndefinedColumnError) and the rollup keeps the pre-S6 statement, so code and file may ship in
-- either order.
--
-- Contract file (no expand header): CHECK constraints on an existing table, and ADD COLUMN takes an ACCESS EXCLUSIVE
-- lock on llm_call_log (~384k rows, above the expand runner's 100k threshold, MIG-10). DB Migrate apply by hand with
-- the job tables idle. The ADD COLUMNs are catalog-only (nullable / constant default); lock_timeout bounds the wait.
-- Number: 311 is slice S5's file (allowed_scopes); renumbered at merge if needed.
--
-- Rollback (a NEW forward migration, after the code is reverted; the code also runs without the columns):
--   ALTER TABLE shared.llm_call_log DROP COLUMN cache_read_tokens, DROP COLUMN cache_write_tokens,
--     DROP COLUMN pricing_mode;
--   ALTER TABLE shared.llm_call_daily DROP COLUMN cache_read_tokens, DROP COLUMN cache_write_tokens,
--     DROP COLUMN estimate_calls;                                       (a destructive file)
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of both tables.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.llm_call_log') IS NULL OR to_regclass('shared.llm_call_daily') IS NULL THEN
        RAISE EXCEPTION 'migration 312: shared.llm_call_log or shared.llm_call_daily (AA-825) is missing';
    END IF;
END $$;

ALTER TABLE shared.llm_call_log
    ADD COLUMN IF NOT EXISTS cache_read_tokens  integer,
    ADD COLUMN IF NOT EXISTS cache_write_tokens integer,
    ADD COLUMN IF NOT EXISTS pricing_mode       text;

COMMENT ON COLUMN shared.llm_call_log.cache_read_tokens IS
    'AA-1002 S6: prompt tokens read from the provider cache (part of tokens_in). NULL = not reported.';
COMMENT ON COLUMN shared.llm_call_log.cache_write_tokens IS
    'AA-1002 S6: prompt tokens written to the provider cache (part of tokens_in). NULL = not reported.';
COMMENT ON COLUMN shared.llm_call_log.pricing_mode IS
    'AA-1002 S6: how cost_usd was priced: override|catalog|code_table|estimate [+batch] [+geo_us]. '
    'estimate = no price source knew the model (charged at a high fallback rate). NULL = not said.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_call_log_cache_tokens_check'
                      AND conrelid = 'shared.llm_call_log'::regclass) THEN
        ALTER TABLE shared.llm_call_log ADD CONSTRAINT llm_call_log_cache_tokens_check CHECK (
            (cache_read_tokens IS NULL OR cache_read_tokens >= 0)
            AND (cache_write_tokens IS NULL OR cache_write_tokens >= 0)) NOT VALID;
        ALTER TABLE shared.llm_call_log VALIDATE CONSTRAINT llm_call_log_cache_tokens_check;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_call_log_pricing_mode_check'
                      AND conrelid = 'shared.llm_call_log'::regclass) THEN
        ALTER TABLE shared.llm_call_log ADD CONSTRAINT llm_call_log_pricing_mode_check CHECK (
            pricing_mode IS NULL
            OR pricing_mode ~ '^(override|catalog|code_table|estimate)(\+batch)?(\+geo_us)?$') NOT VALID;
        ALTER TABLE shared.llm_call_log VALIDATE CONSTRAINT llm_call_log_pricing_mode_check;
    END IF;
END $$;

ALTER TABLE shared.llm_call_daily
    ADD COLUMN IF NOT EXISTS cache_read_tokens  bigint NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS cache_write_tokens bigint NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS estimate_calls     bigint NOT NULL DEFAULT 0;

COMMENT ON COLUMN shared.llm_call_daily.estimate_calls IS
    'AA-1002 S6: rows of the day priced by estimate (llm_call_log.pricing_mode estimate*): their cost is a guess.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('312', now(), 'AA-1002 S6: llm_call_log cache_read/write_tokens + pricing_mode; llm_call_daily cache sums + estimate_calls')
ON CONFLICT (version) DO NOTHING;

COMMIT;
