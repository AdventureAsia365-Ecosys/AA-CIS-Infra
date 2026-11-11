-- Migration 396: AA-1078 (S277) — an output ceiling sized to the field, and effort low, for the flag_fix stages on
-- Claude Haiku 5.5: rows of shared.stage_model_params for t2_flag_fix and s1_flag_fix (max_tokens 16000, effort low).
-- break-glass: S276 audit, 4 of 6 t2_flag_fix calls cut at the 4096 default, one fix lost under a passed job
--
-- Why. AA-741 phase 3 (root docs/audits/2026-11-10-S276-aa741-phase3/ §4.7): t2_flag_fix on Haiku 5.5
-- (anthropic-direct) cut 4 of 6 calls. flag_fix_node sends no max_tokens, so the request gets the LLMRequest default of
-- 4096, the same as the gateway's reasoning floor; Haiku 5.5 bills its adaptive thinking as output inside that ceiling
-- and the first call carried no effort (the model default). The gateway's one truncation retry (8192, effort medium)
-- answered 2 of 3 and cut the third at 8192; that job still reported QA passed with its brand fix lost. Output per call
-- grew about 21x from Haiku 4.5 (average 104 tokens out) to Haiku 5.5 (average 2,165, max 6,717). s1_flag_fix runs the
-- same node and the same prompt shape on the same model, so the same cut can hit A1.
--
-- Why 16000. "Sized to the field": flag_fix rewrites whole page fields, the largest being the itinerary of a long tour,
-- and a field is never longer than the page the S1 writer v2 writes inside its own ceiling of 16000
-- (services/content_generation/s1_writer_v2.py WRITER_MAX_TOKENS; the T2 page is the same shape). A ceiling is head-room,
-- not the expected size: a complete reply costs the same under 16000 as under 4096; only a run-away reply can cost
-- more, at most 16000 output tokens at the Haiku 5.5 catalog price per call. The gateway's truncation retry still
-- doubles it once (tokens.retry_budget, capped at the model's output cap).
-- Why effort low. The task is a constrained edit of given text (rewrite the flagged fields, keep the rest), not open
-- writing; low bounds the thinking that filled the 4096 ceiling (the same lever migration 381 used for the Claude 5.5
-- validate stages). The code fix of this issue records a cut reply as a lost fix ("fix_not_applied") instead of a pass,
-- so a quality cost of low effort shows as fixes not applied in the 24 h stop_reason read, never as a silent pass.
--
-- Which calls it reaches. The field rewrite (flag_fix_node: no explicit max_tokens, so the row's 16000 applies) and the
-- meta re-repair loop (_rerepair_meta: no explicit max_tokens either). The grounding sentence repair (grounding.repair,
-- also on these stages) sets max_tokens 4096 itself: the call site wins over a row for max_tokens (stage_params
-- precedence), so only effort low reaches it (its reply is a few sentences of JSON). The gpt-6-luna-openai fallback of
-- t2_flag_fix keeps its catalog floor of 8192 (migration 382); a row is per model, so no fallback inherits these.
--
-- What.
--   1. Guards (RAISE rolls the whole file back): 320 registered (the table and its CHECKs), haiku-5-5 is an Anthropic
--      catalog row, both stages have a shared.llm_role_config row.
--   2. Two rows, ON CONFLICT DO NOTHING (a row that exists is kept and named in a NOTICE when it differs);
--      updated_by 'migration-396-aa1078'.
--   3. Guard after: both rows exist.
--   4. Register 396.
--
-- Behaviour on Dev. Within the stage_params cache TTL (300 s) after the apply, a t2_flag_fix / s1_flag_fix call answered
-- by Haiku 5.5 on the Anthropic Messages API is sent max_tokens 16000 (where the call site sets none) and
-- output_config.effort "low" (on Converse, acc3, effort is not sent: logged once as stage_params_not_applied, and the
-- max_tokens still applies). No route, model, price, prompt or schema change. Kill switch: LLM_STAGE_PARAMS=off (ECS
-- env) ignores every row. With S1_CONTROL=contract the A1 v2 path makes no s1_flag_fix call at all (CIS AA-1049 S277),
-- so the s1_flag_fix row reaches the main A1 path (switch off) and a v1 / seed draft only.
--
-- Class: contract (root ADR 0017 d3: INSERT of config rows into an existing table), no migrate directive line.
-- Migration-only PR (MIG-4). The code PR of AA-1078 does not need it (the gateway reads every column since 320); either
-- order is safe. On Dev, Infra Migration Apply applies it once every job table is idle (root ADR 0017a). DM-7.1: no new
-- table. Change control (ADR 0020 d12): a gated stage's route config, so the break-glass line above.
--
-- Number. CIS main max is 395 (CIS #1425), so 396. Renumber to main max + 1 if needed: git grep '396_' and
-- 'migration 396' / 'migration-396' / "'396'" (file, updated_by, version, and the CIS implementation notes
-- docs/implementation-notes/AA-1078.md of the code PR).
--
-- Rollback (a NEW forward migration): DELETE FROM shared.stage_model_params WHERE updated_by = 'migration-396-aa1078';
-- (both stages then run the 4096 default and the model's default effort again).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical.
--
-- X1. One BEGIN … COMMIT block, no role switch. Runs as cis_owner, the owner of the table. Grants: none (cis_app keeps
-- SELECT from 320; catalog_owner keeps its column grant from 350).

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TEMP TABLE m396_rows (stage text, model_key text, max_tokens int, effort text, notes text) ON COMMIT DROP;

INSERT INTO m396_rows (stage, model_key, max_tokens, effort, notes) VALUES
    ('t2_flag_fix', 'haiku-5-5', 16000, 'low',
     'AA-1078 S277: field rewrite cut 4 of 6 calls at the 4096 default (S276 audit 4.7); ceiling = the page writer''s'),
    ('s1_flag_fix', 'haiku-5-5', 16000, 'low',
     'AA-1078 S277: same node and model as t2_flag_fix; ceiling = the S1 writer v2 page ceiling');

-- ── 1. guards before ─────────────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    r record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '320') OR
       to_regclass('shared.stage_model_params') IS NULL THEN
        RAISE EXCEPTION 'migration 396: shared.stage_model_params is missing (apply 320 first)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog WHERE model_key = 'haiku-5-5' AND vendor = 'anthropic') THEN
        RAISE EXCEPTION 'migration 396: catalog row haiku-5-5 is missing or not an Anthropic model';
    END IF;
    FOR r IN SELECT stage FROM m396_rows m
              WHERE NOT EXISTS (SELECT 1 FROM shared.llm_role_config c WHERE c.stage = m.stage) LOOP
        RAISE EXCEPTION 'migration 396: stage % has no shared.llm_role_config row', r.stage;
    END LOOP;
END $$;

-- ── 2. the rows ──────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT m.stage, m.model_key, p.max_tokens, p.effort
               FROM m396_rows m
               JOIN shared.stage_model_params p ON p.stage = m.stage AND p.model_key = m.model_key
              WHERE p.max_tokens IS DISTINCT FROM m.max_tokens OR p.effort IS DISTINCT FROM m.effort LOOP
        RAISE NOTICE 'migration 396: % x % already has a row (max_tokens %, effort %), kept as it is', r.stage,
                     r.model_key, coalesce(r.max_tokens::text, 'NULL'), coalesce(r.effort, 'NULL');
    END LOOP;
END $$;

INSERT INTO shared.stage_model_params (stage, model_key, max_tokens, effort, notes, updated_by)
SELECT stage, model_key, max_tokens, effort, notes, 'migration-396-aa1078' FROM m396_rows
ON CONFLICT (stage, model_key) DO NOTHING;

-- ── 3. guard after ───────────────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    missing int;
BEGIN
    SELECT count(*) INTO missing
      FROM m396_rows m
     WHERE NOT EXISTS (SELECT 1 FROM shared.stage_model_params p
                        WHERE p.stage = m.stage AND p.model_key = m.model_key);
    IF missing > 0 THEN
        RAISE EXCEPTION 'migration 396: % stage x model row(s) missing after the insert', missing;
    END IF;
END $$;

-- ── 4. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('396', now(), 'AA-1078 S277: max_tokens 16000 and effort low for t2_flag_fix / s1_flag_fix on Haiku 5.5')
ON CONFLICT (version) DO NOTHING;

COMMIT;
