-- Migration 382: AA-900 (S271 lane l11) — GPT-6 Luna gets its own output floor: capabilities.min_output_tokens = 8192
-- on the catalog rows gpt-6-luna-openai (OpenAI API) and gpt-6-luna (its AWS twin on Bedrock acc3, the same model).
--
-- Why. The gateway floors every reasoning-capable model at shared/aa_llm/tokens.py REASONING_FLOOR = 4096 output
-- tokens unless the catalog row states its own capabilities.min_output_tokens (which wins). 4096 is too low for this
-- model as a judge: in the R2 eval rerun of 06/11/2026 (08:52-09:06Z, judge gpt-6-luna-openai on openai-direct) 8 of 24
-- calls were cut at 4096 (status billed_unusable, stop reason length). The S271 gateway retry asked each of them again
-- at 8192 and every retry answered; the answered calls used 2,329-6,983 output tokens, of which 2,048-6,321 were
-- reasoning. So one call in three paid for a cut reply plus a second call.
--
-- Why 8192. It is the smallest round ceiling above the largest answered call seen (6,983, about 17 % head-room), and
-- the ceiling the retry already proved on all 8 cut calls. A ceiling is head-room, not the expected size: a complete
-- reply costs the same under 8192 as under 4096; only a run-away reply can cost more, at most 8,192 x 0.50 USD/Mtok =
-- 0.004 USD per call at the catalog price. 16384 was not taken: no answered call needed it, and the one truncation
-- retry (tokens.retry_budget, double, capped at 24000) still covers a reply above 8192.
--
-- Why both rows. gpt-6-luna and gpt-6-luna-openai are the same model on two providers (catalog notes of 170; the S235
-- twin rule). The Bedrock row is refused on acc3 today (access_denied), but once AWS grants access the judges run on
-- it first (route gpt-6-luna > gpt-6-luna-openai > nova-lite), and it would be cut exactly as the API twin was.
--
-- Which other reasoning models were checked and left on the 4096 code floor (no evidence of a cut at 4096):
--   * Claude 5.x (haiku-5-5, sonnet-5, sonnet-5-5, opus-5-5 and their Anthropic API rows): their thinking is bounded
--     by the per stage x model effort (shared.stage_model_params, migration 381) and the writer stages already ask
--     for 8k-12k; no Claude 5.x judge call of the R2 rerun was cut.
--   * gpt-5.6-luna, gpt-6-astra (Bedrock acc3): refused (access_denied) since 29/10/2026, no answered call to size a
--     floor from. Revisit after a grant with a ledger read (tokens_out and reasoning_tokens per stage).
--   * gpt-6-sol, gpt-6.1-sol, gpt-6.1-terra (OpenAI API rows): they served no call of the R2 rerun, so there is no
--     measurement; they keep the code floor until one shows cuts (route_cut alert, S271).
-- A stage that needs more than its model's floor sets shared.stage_model_params.min_output_tokens instead.
--
-- What.
--   1. Guard: the catalog table and its capabilities column exist (320), and both rows exist.
--   2. Merge min_output_tokens = 8192 into each row's capabilities jsonb (the other keys are kept). A row that already
--      states a HIGHER integer floor (an admin choice) is kept and named in a NOTICE: this file never lowers a floor.
--      updated_at / updated_by ('migration-382') move only on a row that changes.
--   3. NOTICE when a row's max_output_tokens is below 8192 (the gateway caps the floor at the model's own output cap).
--   4. Guard: both rows now state an integer min_output_tokens of at least 8192.
--   5. Register 382.
--
-- Behaviour. Within the catalog cache TTL (about 5 minutes) after apply, every gpt-6-luna(-openai) call of a stage
-- that asked for less than 8192 output tokens is sent with 8192 (token_floor.apply_floor). The connection probe
-- (stage adhoc_conn_test, token_floor.NO_RETRY_STAGES) is never floored and keeps its 32 tokens. No route, price,
-- deployment or prompt change.
--
-- Class: contract (root ADR 0017 d3: UPDATE of rows in an existing table), so no migrate directive header and MIG-4
-- order: (1) this migration-only PR merges to AA-CIS-App main; (2) the byte copy in AA-CIS-Infra db/migrations/cis/
-- merges; (3) Infra Migration Apply applies it once every job table is idle (root ADR 0017a). No code PR depends on it
-- (the gateway already reads capabilities.min_output_tokens). DM-7.1: no new table.
--
-- Rollback (a NEW forward migration): UPDATE shared.llm_model_catalog SET capabilities = capabilities -
-- 'min_output_tokens' WHERE model_key IN ('gpt-6-luna', 'gpt-6-luna-openai') AND updated_by = 'migration-382';
-- (the model then falls back to the 4096 code floor).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical.
--
-- X1. One BEGIN ... COMMIT block, no role switch. Runs as cis_owner, the owner of the table. Grants: none (cis_app
-- keeps its table grants).

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. guard ─────────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    missing text[];
BEGIN
    IF to_regclass('shared.llm_model_catalog') IS NULL THEN
        RAISE EXCEPTION 'migration 382: shared.llm_model_catalog is missing (apply 169 first)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'shared' AND table_name = 'llm_model_catalog'
                      AND column_name = 'capabilities') THEN
        RAISE EXCEPTION 'migration 382: shared.llm_model_catalog.capabilities is missing (apply 320 first)';
    END IF;
    SELECT array_agg(k ORDER BY k) INTO missing
      FROM unnest(ARRAY['gpt-6-luna', 'gpt-6-luna-openai']) AS k
     WHERE NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog c WHERE c.model_key = k);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 382: catalog row(s) % missing (apply 170 first)', missing;
    END IF;
END $$;

-- ── 2. merge the floor (never lower an existing higher one) ──────────────────────────────────────────────────────

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT model_key, capabilities -> 'min_output_tokens' AS own
               FROM shared.llm_model_catalog
              WHERE model_key IN ('gpt-6-luna', 'gpt-6-luna-openai')
              ORDER BY model_key LOOP
        IF r.own IS NOT NULL AND jsonb_typeof(r.own) = 'number' THEN
            IF (r.own #>> '{}')::numeric > 8192 THEN
                RAISE NOTICE 'migration 382: % keeps its own min_output_tokens % (higher than 8192)',
                             r.model_key, r.own;
            END IF;
        END IF;
    END LOOP;
END $$;

UPDATE shared.llm_model_catalog
   SET capabilities = coalesce(capabilities, '{}'::jsonb) || jsonb_build_object('min_output_tokens', 8192),
       updated_at = now(),
       updated_by = 'migration-382'
 WHERE model_key IN ('gpt-6-luna', 'gpt-6-luna-openai')
   AND NOT coalesce(CASE WHEN jsonb_typeof(capabilities -> 'min_output_tokens') = 'number'
                         THEN (capabilities ->> 'min_output_tokens')::numeric >= 8192 END, false);

-- ── 3. the model's own output cap ────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT model_key, max_output_tokens FROM shared.llm_model_catalog
              WHERE model_key IN ('gpt-6-luna', 'gpt-6-luna-openai') AND max_output_tokens < 8192
              ORDER BY model_key LOOP
        RAISE NOTICE 'migration 382: % has max_output_tokens % (< 8192): the gateway caps the floor there',
                     r.model_key, r.max_output_tokens;
    END LOOP;
END $$;

-- ── 4. guard ─────────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    bad text[];
BEGIN
    SELECT array_agg(model_key ORDER BY model_key) INTO bad
      FROM shared.llm_model_catalog
     WHERE model_key IN ('gpt-6-luna', 'gpt-6-luna-openai')
       AND NOT coalesce(CASE WHEN jsonb_typeof(capabilities -> 'min_output_tokens') = 'number'
                              AND (capabilities ->> 'min_output_tokens') ~ '^[0-9]{1,9}$'
                             THEN (capabilities ->> 'min_output_tokens')::int >= 8192 END, false);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 382: % do(es) not state an integer min_output_tokens >= 8192 after the update', bad;
    END IF;
END $$;

-- ── 5. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('382', now(), 'AA-900 S271: gpt-6-luna and gpt-6-luna-openai min_output_tokens 8192 (R2 judge cuts at 4096)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
