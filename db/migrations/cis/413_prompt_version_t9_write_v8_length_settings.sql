-- Migration 413: S279 thresholds lane L2 (AA-1096) — register prompt version t9_write v8 in shared.prompt_version, so
-- the ledger can tell the blog prompt that renders its length values at call time from v7.
--
-- Why. Lane L2 moves the T9 blog length band (4,700-13,000 characters) and the length target margin (0.17) onto the
-- platform settings registry (CIS 412: cis.t9.blog_chars_min / _max, cis.quality.t9_blog_length_target_margin,
-- evidence-gated, maker-checker). The blog's LENGTH AND EFFORT block named the word floor through the module literal
-- prompts._BLOG_WORDS = (950, 1300); the code PR renders it at call time from length_contract.target_words() (the F4
-- floor plus the margin in force): _BLOG_WORDS becomes _BLOG_WORDS_TOP + _blog_words(), the block constant
-- _BLOG_LENGTH_INSTRUCTIONS becomes the function _blog_length_instructions() and the plan constant _PLAN goes. At the
-- seeded values the rendered block is byte for byte v7's (tests/unit/test_s279_quality_settings_parity.py); only the
-- hashed source changed, which is t9_write v8. Without this row every t9_write call after the code deploy would carry
-- prompt_version NULL (shared/llm_client/prompt_registry.version_for).
--
-- What.
--   1. One row (sha256 of the hashed symbols' source text, never the text; created_by 'migration-413'), the output of
--      `python3 scripts/prompt_registry_check.py --sql --unregistered --created-by migration-413` on the code PR's tree:
--        t9_write  v8  SYSTEM_PROMPT, build_user_prompt, _BLOG_WORDS_TOP, _blog_words, _BLOG_WORDS_MAX,
--                      _BLOG_SECTIONS_MAX, _BLOG_FAQ_PLAN, _BLOG_RICHEST_SHARE, _blog_length_plan,
--                      _blog_length_instructions, _WALK_FOCUS_MARK, _WALK_FOCUS_RULE
--                      (services/acp_content_writing/prompts.py)
--      ON CONFLICT (stage, version) DO NOTHING.
--   2. Guard: the row exists with exactly this hash and path.
--   3. Register 413.
--
-- Behaviour. Until the code PR deploys, no deployed prompt matches v8 and nothing changes (calls keep 'v7'). After it
-- deploys, t9_write rows carry 'v8' (or 'v8.s<8 hex>' once an approved length setting differs from its seed). No
-- route, model, cost or prompt text change by this file. Older versions stay registered.
--
-- Class: contract (root ADR 0017 d3: rows into an existing table), so no migrate directive header and MIG-4 order with
-- 412 in one migration-only PR (batch cis 412-413): Infra Migration Apply once every job table is idle (root ADR
-- 0017a), then the L2 code PR. No readiness bump. DM-7.1: no new table.
--
-- Rollback (a NEW forward migration): DELETE FROM shared.prompt_version WHERE created_by = 'migration-413';
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
        RAISE EXCEPTION 'migration 413: shared.prompt_version is missing (apply 321 first)';
    END IF;
END $$;

-- ── 1. the manifest row ──────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.prompt_version (stage, version, prompt_sha256, source_path, created_by) VALUES
    ('t9_write', 'v8', 'e16183822e12d7ea7c232167da6c3520c5fd16b15eba4c0f8087af527a8966e7', 'services/acp_content_writing/prompts.py', 'migration-413')
ON CONFLICT (stage, version) DO NOTHING;

-- ── 2. guard ─────────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM shared.prompt_version
         WHERE stage = 't9_write' AND version = 'v8'
           AND prompt_sha256 = 'e16183822e12d7ea7c232167da6c3520c5fd16b15eba4c0f8087af527a8966e7'
           AND source_path = 'services/acp_content_writing/prompts.py'
    ) THEN
        RAISE EXCEPTION 'migration 413: t9_write v8 is registered with another hash or path, or missing (a version '
                        'is never edited: bump the manifest instead)';
    END IF;
END $$;

-- ── 3. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('413', now(), 'S279 thresholds L2: register prompt version t9_write v8 (blog length values rendered at call time; no prompt text)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
