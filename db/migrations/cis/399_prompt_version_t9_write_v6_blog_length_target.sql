-- Migration 399: AA-1077 (S278, blog length target) — register prompt version t9_write v6 in shared.prompt_version, so
-- the ledger can tell the blog prompt with the new word floor from the old one.
--
-- Why. S278 (12/11/2026) wrote 9 blog pieces on 3 audit tenants after the T7 600-word seed floor: 5 of 9 were held
-- length_short, 3 of them at the floor's edge (4,699 / 4,696 / 4,696 tag-stripped chars, 799-809 words) while the
-- writer prompt's word floor was 900 words, only ~11 % above the F4 floor of 4,700 chars; the post-loop normalizer then
-- cut up to 241 chars more. The code PR makes the length target ONE number above the floor: the registry threshold
-- t9.blog_length_target_margin (0.17) gives 5,499 chars / 950 words (services/acp_content_writing/length_contract.py),
-- and the hashed prompt literal prompts._BLOG_WORDS moves from (900, 1300) to (950, 1300), pinned to the target by a
-- test. That is t9_write v6. The gateway writes llm_call_log.prompt_version only when the deployed source, the
-- manifest (shared/llm_client/prompt_versions.json) and a row of this table agree
-- (shared/llm_client/prompt_registry.version_for); without this row every t9_write call after the code deploy would
-- carry prompt_version NULL and the before / after read of the new floor (length, cost per version) would be lost.
--
-- What.
--   1. One row (sha256 of the hashed symbols' source text in the source file, never the text; created_by
--      'migration-399'), the output of
--      `python3 scripts/prompt_registry_check.py --sql --unregistered --created-by migration-399` on the code PR's tree:
--        t9_write  v6  SYSTEM_PROMPT, build_user_prompt, _BLOG_WORDS, _BLOG_WORDS_MAX, _BLOG_SECTIONS_MAX,
--                      _BLOG_LENGTH_INSTRUCTIONS, _WALK_FOCUS_MARK, _WALK_FOCUS_RULE
--                      (services/acp_content_writing/prompts.py)
--      ON CONFLICT (stage, version) DO NOTHING.
--   2. Guard: the row exists with exactly this hash and path (a version registered earlier with another hash would be
--      kept silently by the ON CONFLICT and every call of it would carry prompt_version NULL).
--   3. Register 399.
--
-- Behaviour. Until the code PR deploys, no deployed prompt matches v6 and nothing changes (calls keep 'v5'). After it
-- deploys, within the registry cache TTL, t9_write rows carry 'v6'. No route, model, cost or prompt change by this
-- file. Older versions stay registered.
--
-- Class: contract (root ADR 0017 d3: rows into an existing table), so no migrate directive header and MIG-4 order:
-- (1) this migration-only PR merges to AA-CIS-App main; (2) the byte copy in AA-CIS-Infra db/migrations/cis/ merges;
-- (3) Infra Migration Apply applies it once every job table is idle (root ADR 0017a); (4) then the AA-1077 S278 code PR
-- merges. No readiness bump. DM-7.1: no new table.
--
-- Rollback (a NEW forward migration): DELETE FROM shared.prompt_version WHERE created_by = 'migration-399';
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
        RAISE EXCEPTION 'migration 399: shared.prompt_version is missing (apply 321 first)';
    END IF;
END $$;

-- ── 1. the manifest row ──────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.prompt_version (stage, version, prompt_sha256, source_path, created_by) VALUES
    ('t9_write', 'v6', '91e34c9f5ce06002eb7565d1af7db9779dbb27bf77c0e0806e1725cc3d299cf3', 'services/acp_content_writing/prompts.py', 'migration-399')
ON CONFLICT (stage, version) DO NOTHING;

-- ── 2. guard ─────────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM shared.prompt_version
         WHERE stage = 't9_write' AND version = 'v6'
           AND prompt_sha256 = '91e34c9f5ce06002eb7565d1af7db9779dbb27bf77c0e0806e1725cc3d299cf3'
           AND source_path = 'services/acp_content_writing/prompts.py'
    ) THEN
        RAISE EXCEPTION 'migration 399: t9_write v6 is registered with another hash or path, or missing (a version '
                        'is never edited: bump the manifest instead)';
    END IF;
END $$;

-- ── 3. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('399', now(), 'AA-1077 S278: register prompt version t9_write v6 (blog word floor = length target, no prompt text)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
