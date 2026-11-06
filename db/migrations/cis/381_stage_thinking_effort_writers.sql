-- Migration 381: AA-741 (S271, after t9_write v2 went live) — a thinking level per stage x model for the blog writer
-- t9_write and five Claude 5.5 validate stages, as rows of shared.stage_model_params (AA-1017, migration 320; empty
-- until now).
--
-- Why. A real blog write on 06/11/2026 (~07:26Z, an audit tenant) after CIS #1341 (t9_write v2, word band 900-1,300)
-- still had t9_write on Claude Sonnet 5.5 (anthropic-direct) cut 2 of 3 calls at max_tokens 12000 (one billed
-- unusable, one truncated, ~0.29 USD lost); the call that answered produced 5,800-9,500 output tokens for an article
-- of ~985 words (~1,300 tokens), and the route fell back to Sonnet 4.6 to finish. Cause: Sonnet 5.5's adaptive
-- thinking is billed as output inside max_tokens, and the gateway sends Sonnet 5.5 at its default effort, high (the
-- Anthropic adapter's family table). A word band in the prompt cannot bound the thinking.
--
-- The lever. On the Claude 5.x models a numeric thinking budget does not exist any more: `thinking: {type: "enabled",
-- budget_tokens: N}` is a 400 on Sonnet 5.5, Haiku 5.5 and Opus 5.5, and `{type: "disabled"}` is a 400 on Sonnet 5.5
-- and Opus 5.5 (Anthropic API docs, claude-api reference cached 2026-10-06). Adaptive thinking is bounded by
-- `output_config.effort` (low / medium / high / xhigh / max), which the gateway already sends on the Anthropic
-- Messages API from a stage x model row (client._call_anthropic_messages, stage_params.effort_for). So this file sets
-- effort only; the thinking type stays the model's default (reasoning_mode NULL = adaptive on every 5.x model).
--
-- What.
--   1. Six rows (ON CONFLICT DO NOTHING: a row that exists is kept, NOTICE when it differs):
--        stage                  model       effort   (default today)  why
--        t9_write               sonnet-5-5  medium   (high)           the 06/11 cuts: a one-pass blog of ~1,300 tokens
--        t9_faq_filter          haiku-5-5   low      (medium)         validate, JSON verdict; 1 cut in 30 days
--        t9_faq_answer_fit      sonnet-5-5  low      (high)           validate, JSON fit check
--        a3_place_card_check    haiku-5-5   low      (medium)         validate, JSON check of a place card
--        a3_place_days          haiku-5-5   low      (medium)         validate, JSON day check
--        a3_place_dedupe_check  haiku-5-5   low      (medium)         validate, JSON dedupe check
--      max_tokens, min_output_tokens, temperature and reasoning_mode stay NULL: the call sites keep their ceilings
--      (t9_write 12000 explicit, the S270 budget retry at 24000 and the gateway floor of CIS #1344 unchanged), the
--      ceiling is head-room, not the expected size. notes says why; updated_by 'migration-381-aa741'.
--      Not set: t2_generate and t8_angle_gen (sonnet-5-5, the tour and angle writers) stay at their default, high.
--      The S271 cuts were t9_write only, and the writer eval gate does not cover stage_model_params yet (a writer
--      effort change does not flag a release for reverify): their effort moves in a later forward migration, after a
--      paid quality read (t2_judge score and tokens_out next to the high-effort baseline) on an audit tenant.
--      The judges (s1_judge, t2_judge, t7_debate_judge, t10_judge, writing_memory_*) run GPT on Converse,
--      where the gateway sends no reasoning field until a probe shows the provider's field (AA-803), and a judge's
--      effort is an eval-gated choice (Writing Lab kappa), not this file's; a3_place_locate (geo accuracy) and the
--      Haiku 5.5 fix / nudge / repair writers keep their default; the Sonnet 4.6 / Haiku 4.5 / GPT rungs of each
--      route keep theirs (a row is per model, so a fallback never inherits the primary's effort).
--   2. Guards (RAISE rolls the whole file back): before: 320 registered (the table and its effort CHECK exist), both
--      model keys are Anthropic catalog rows (vendor anthropic; enabled or not: a row of a switched-off model is
--      harmless), t9_write has a shared.llm_role_config row; a
--      listed stage without one gets no row (NOTICE: the gateway would never read it). After: each row exists; a
--      pre-existing row that differs from this file is kept and named in a NOTICE.
--   3. Register 381.
--
-- Behaviour on Dev. Within the stage_params cache TTL (300 s) after the apply, t9_write on Sonnet 5.5 (anthropic-direct,
-- and acc3 when it answers: on Converse the effort is not sent, logged once as stage_params_not_applied) is sent
-- output_config.effort "medium" instead of "high", and the five validate stages "low". Fewer thinking tokens per call: less output billed, fewer cuts, fewer budget retries at 24000. Ledger: the
-- effort column of llm_call_log shows the value sent (as today). No route, model, price, prompt or schema change.
-- Kill switch: LLM_STAGE_PARAMS=off (ECS env) ignores every row.
-- Quality. Effort is a quality lever for a writer: the first paid blog write after the apply is read for quality, not
-- only size (t9_write tokens_out and status, the piece's status / attempt_number / gate_ledger, its t10_judge rows and
-- any subject_gate flag in acp_shared.content_compliance_flag), next to the last blog writes at effort high on the
-- audit tenants. A piece held where the baseline passed, more attempts, or a subject_gate flag = roll back (below).
--
-- Class: contract (root ADR 0017 d3: INSERT of config rows into an existing table), no migrate directive line.
-- Migration-only PR (MIG-4): no code needs this file (the gateway reads every column it writes since 320 / AA-1017).
-- The companion code PR (gateway thinking control: the Anthropic `thinking` type per model, OpenAI reasoning_effort)
-- does not need it either; either order is safe. On Dev, Infra Migration Apply applies it once every job table is
-- idle (root ADR 0017a). DM-7.1: no new table.
--
-- Number. Main max is 380 (06/11: CIS #1340), so 381 (the migration preflight refuses any other). Renumber to main
-- max + 1 if needed: git grep '381_' and 'migration 381' / 'migration-381' / "'381'" (file, updated_by, version).
--
-- Rollback (a NEW forward migration): DELETE FROM shared.stage_model_params WHERE updated_by = 'migration-381-aa741';
-- (every stage then runs its model's default effort again, as before this file).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical.
--
-- X1. One BEGIN … COMMIT block, no role switch. Runs as cis_owner, the owner of the table. Grants: none (cis_app keeps
-- SELECT from 320; catalog_owner keeps its column grant from 350).

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TEMP TABLE m381_rows (stage text, model_key text, effort text, notes text) ON COMMIT DROP;

INSERT INTO m381_rows (stage, model_key, effort, notes) VALUES
    ('t9_write', 'sonnet-5-5', 'medium',
     'AA-741 S271: blog write; adaptive thinking billed inside max_tokens cut 2 of 3 calls at 12000 at effort high'),
    ('t9_faq_filter', 'haiku-5-5', 'low', 'AA-741 S271: validate stage, JSON verdict; 1 reply cut in 30 days'),
    ('t9_faq_answer_fit', 'sonnet-5-5', 'low', 'AA-741 S271: validate stage, JSON fit check'),
    ('a3_place_card_check', 'haiku-5-5', 'low', 'AA-741 S271: validate stage, JSON place card check'),
    ('a3_place_days', 'haiku-5-5', 'low', 'AA-741 S271: validate stage, JSON day check'),
    ('a3_place_dedupe_check', 'haiku-5-5', 'low', 'AA-741 S271: validate stage, JSON dedupe check');

-- ── guards before ────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    r record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '320') OR
       to_regclass('shared.stage_model_params') IS NULL THEN
        RAISE EXCEPTION 'migration 381: shared.stage_model_params is missing (apply 320 first)';
    END IF;
    FOR r IN SELECT DISTINCT model_key FROM m381_rows LOOP
        IF NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog
                        WHERE model_key = r.model_key AND vendor = 'anthropic') THEN
            RAISE EXCEPTION 'migration 381: catalog row % is missing or not an Anthropic model', r.model_key;
        END IF;
    END LOOP;
    -- A stage with no route row gets no parameter row (the gateway would never read it): skipped and named.
    FOR r IN SELECT stage FROM m381_rows m
              WHERE NOT EXISTS (SELECT 1 FROM shared.llm_role_config c WHERE c.stage = m.stage) LOOP
        RAISE NOTICE 'migration 381: stage % has no shared.llm_role_config row, skipped', r.stage;
    END LOOP;
    DELETE FROM m381_rows m WHERE NOT EXISTS (SELECT 1 FROM shared.llm_role_config c WHERE c.stage = m.stage);
    IF NOT EXISTS (SELECT 1 FROM m381_rows WHERE stage = 't9_write') THEN
        RAISE EXCEPTION 'migration 381: stage t9_write has no shared.llm_role_config row';
    END IF;
END $$;

-- ── 1. the rows ──────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT m.stage, m.model_key, m.effort, p.effort AS live_effort, p.max_tokens, p.min_output_tokens,
                    p.temperature, p.reasoning_mode
               FROM m381_rows m
               JOIN shared.stage_model_params p ON p.stage = m.stage AND p.model_key = m.model_key LOOP
        IF r.live_effort IS DISTINCT FROM r.effort OR r.max_tokens IS NOT NULL OR r.min_output_tokens IS NOT NULL
           OR r.temperature IS NOT NULL OR r.reasoning_mode IS NOT NULL THEN
            RAISE NOTICE 'migration 381: % x % already has a row (effort %), kept as it is', r.stage, r.model_key,
                         coalesce(r.live_effort, 'NULL');
        END IF;
    END LOOP;
END $$;

INSERT INTO shared.stage_model_params (stage, model_key, effort, notes, updated_by)
SELECT stage, model_key, effort, notes, 'migration-381-aa741' FROM m381_rows
ON CONFLICT (stage, model_key) DO NOTHING;

-- ── 2. guard after ───────────────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    missing int;
BEGIN
    SELECT count(*) INTO missing
      FROM m381_rows m
     WHERE NOT EXISTS (SELECT 1 FROM shared.stage_model_params p
                        WHERE p.stage = m.stage AND p.model_key = m.model_key);
    IF missing > 0 THEN
        RAISE EXCEPTION 'migration 381: % stage x model row(s) missing after the insert', missing;
    END IF;
END $$;

-- ── 3. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('381', now(), 'AA-741 S271: effort per stage x model for the t9_write blog writer on Sonnet 5.5 (medium) '
                      'and Claude 5.5 validate stages (low)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
