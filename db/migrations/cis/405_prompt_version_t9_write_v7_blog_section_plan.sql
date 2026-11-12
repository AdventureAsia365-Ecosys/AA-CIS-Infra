-- Migration 405: AA-1077 round 2 (S278, blog length repair) — register prompt version t9_write v7 in
-- shared.prompt_version, so the ledger can tell the blog prompt with the section plan from v6.
--
-- Why. The S278 paid trial (3 blog pieces on an audit tenant, t9_write v6) approved 1 of 3: the first drafts landed at
-- 690-840 words although the prompt asked for at least 950 (a word band alone is not obeyed), and a lengthen line that
-- named its sources ("the CONTENT SEED, its Place background and the FACTS lines") was copied into a post as "The
-- source notes name ..." (held F13_leak). The code PR adds to the blog's LENGTH AND EFFORT block a section plan whose
-- word budgets add up to the floor (prompts._blog_length_plan, from the hashed symbols _BLOG_WORDS,
-- _BLOG_SECTIONS_MAX and two restatements of the format bullets' own numbers, _BLOG_FAQ_PLAN and
-- _BLOG_RICHEST_SHARE) and a "never mention where a fact comes from" rule to the block and to every rewrite's
-- feedback footer (build_user_prompt). That is t9_write v7. The gateway writes llm_call_log.prompt_version only when
-- the deployed source, the manifest (shared/llm_client/prompt_versions.json) and a row of this table agree
-- (shared/llm_client/prompt_registry.version_for); without this row every t9_write call after the code deploy would
-- carry prompt_version NULL and the before / after read of the trial (length, cost per version) would be lost.
--
-- What.
--   1. One row (sha256 of the hashed symbols' source text in the source file, never the text; created_by
--      'migration-405'), the output of
--      `python3 scripts/prompt_registry_check.py --sql --unregistered --created-by migration-405` on the code PR's tree:
--        t9_write  v7  SYSTEM_PROMPT, build_user_prompt, _BLOG_WORDS, _BLOG_WORDS_MAX, _BLOG_SECTIONS_MAX,
--                      _BLOG_FAQ_PLAN, _BLOG_RICHEST_SHARE, _blog_length_plan, _PLAN, _BLOG_LENGTH_INSTRUCTIONS,
--                      _WALK_FOCUS_MARK, _WALK_FOCUS_RULE (services/acp_content_writing/prompts.py)
--      ON CONFLICT (stage, version) DO NOTHING.
--   2. Guard: the row exists with exactly this hash and path (a version registered earlier with another hash would be
--      kept silently by the ON CONFLICT and every call of it would carry prompt_version NULL).
--   3. Register 405.
--
-- Behaviour. Until the code PR deploys, no deployed prompt matches v7 and nothing changes (calls keep 'v6'). After it
-- deploys, within the registry cache TTL, t9_write rows carry 'v7'. No route, model, cost or prompt change by this
-- file. Older versions stay registered.
--
-- Class: contract (root ADR 0017 d3: rows into an existing table), so no migrate directive header and MIG-4 order:
-- (1) this migration-only PR merges to AA-CIS-App main; (2) the byte copy in AA-CIS-Infra db/migrations/cis/ merges;
-- (3) Infra Migration Apply applies it once every job table is idle (root ADR 0017a); (4) then the AA-1077 round 2
-- code PR merges. No readiness bump. DM-7.1: no new table.
--
-- Rollback (a NEW forward migration): DELETE FROM shared.prompt_version WHERE created_by = 'migration-405';
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
        RAISE EXCEPTION 'migration 405: shared.prompt_version is missing (apply 321 first)';
    END IF;
END $$;

-- ── 1. the manifest row ──────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.prompt_version (stage, version, prompt_sha256, source_path, created_by) VALUES
    ('t9_write', 'v7', '6b6705fced2e2ad57ba6f01f9101295db72518aae093bbab0df864e8923a2c88', 'services/acp_content_writing/prompts.py', 'migration-405')
ON CONFLICT (stage, version) DO NOTHING;

-- ── 2. guard ─────────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM shared.prompt_version
         WHERE stage = 't9_write' AND version = 'v7'
           AND prompt_sha256 = '6b6705fced2e2ad57ba6f01f9101295db72518aae093bbab0df864e8923a2c88'
           AND source_path = 'services/acp_content_writing/prompts.py'
    ) THEN
        RAISE EXCEPTION 'migration 405: t9_write v7 is registered with another hash or path, or missing (a version '
                        'is never edited: bump the manifest instead)';
    END IF;
END $$;

-- ── 3. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('405', now(), 'AA-1077 S278 round 2: register prompt version t9_write v7 (blog section plan, never-mention rule; no prompt text)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
