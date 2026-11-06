-- Migration 384: AA-900 (S271 W0, Writing Lab eval interim) — register prompt version writing_memory_eval v2 in
-- shared.prompt_version, so the ledger can tell the new R2 judge prompt from the old one.
--
-- Why. The S271 judge root cause (root audit docs/audits/2026-11-06-S271-writing-quality-audit, RC2) found the R2
-- judge reading a cut input without knowing it: the SEED cap (16000) was below the longest golden seed, the OUTPUT was
-- sliced at 9000 chars with no cut mark (complete texts looked truncated, the SEO title, meta and slug went unseen) and
-- the OUTPUT fields had no names. The W0 code PR raises the caps (SEED 24000, SOURCE 32000, OUTPUT 16000), ends a cut
-- text with the cut mark, tells the judge an OUTPUT ending in it was shortened by the grader (never struct.truncated
-- there) and sends the OUTPUT as labelled fields (services/writing_memory/eval_judge.py: system_prompt,
-- build_user_prompt). The rubric text (LABEL_RUBRIC) is unchanged. The gateway writes llm_call_log.prompt_version only
-- when the deployed source, the manifest (shared/llm_client/prompt_versions.json) and a row of this table agree
-- (shared/llm_client/prompt_registry.version_for); without this row every writing_memory_eval / adhoc_aa900 judge call
-- after the code deploy would carry prompt_version NULL.
--
-- What.
--   1. One row (sha256 of the hashed symbols' source text in the source file, never the text; created_by
--      'migration-384'), the output of
--      `python3 scripts/prompt_registry_check.py --sql --unregistered --created-by migration-384` on the code PR's tree:
--        writing_memory_eval  v2  system_prompt, build_user_prompt, judge_version (services/writing_memory/eval_judge.py)
--      ON CONFLICT (stage, version) DO NOTHING.
--   2. Guard: the row exists with exactly this hash and path (a version registered earlier with another hash would be
--      kept silently by the ON CONFLICT and every call of it would carry prompt_version NULL).
--   3. Register 384.
--
-- Behaviour. Until the code PR deploys, no deployed prompt matches v2 and nothing changes (calls keep 'v1'). After it
-- deploys, within the registry cache TTL, judge rows carry 'v2'. No route, model, cost or prompt change by this file.
-- v1 stays registered.
--
-- Class: contract (root ADR 0017 d3: rows into an existing table), so no migrate directive header and MIG-4 order:
-- (1) this migration-only PR merges to AA-CIS-App main; (2) the byte copy in AA-CIS-Infra db/migrations/cis/ merges;
-- (3) Infra Migration Apply applies it once every job table is idle (root ADR 0017a); (4) then the W0 eval code PR
-- merges. No readiness bump. DM-7.1: no new table.
--
-- Rollback (a NEW forward migration): DELETE FROM shared.prompt_version WHERE created_by = 'migration-384';
-- (calls of this version then carry prompt_version NULL; rows already written keep their version).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical.
--
-- X1. One BEGIN … COMMIT block, no role switch. Runs as cis_owner, the owner of the table. Grants: none (cis_app keeps
-- SELECT from 321).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.prompt_version') IS NULL THEN
        RAISE EXCEPTION 'migration 384: shared.prompt_version is missing (apply 321 first)';
    END IF;
END $$;

-- ── 1. the manifest row ──────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.prompt_version (stage, version, prompt_sha256, source_path, created_by) VALUES
    ('writing_memory_eval', 'v2', '1bb1732339d7785be23edb2f1024e2900860a15b289ead0eacb7205ac502eb99', 'services/writing_memory/eval_judge.py', 'migration-384')
ON CONFLICT (stage, version) DO NOTHING;

-- ── 2. guard ─────────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM shared.prompt_version
         WHERE stage = 'writing_memory_eval' AND version = 'v2'
           AND prompt_sha256 = '1bb1732339d7785be23edb2f1024e2900860a15b289ead0eacb7205ac502eb99'
           AND source_path = 'services/writing_memory/eval_judge.py'
    ) THEN
        RAISE EXCEPTION 'migration 384: writing_memory_eval v2 is registered with another hash or path, or missing (a '
                        'version is never edited: bump the manifest instead)';
    END IF;
END $$;

-- ── 3. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('384', now(), 'AA-900 S271 W0: register prompt version writing_memory_eval v2 (no prompt text)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
