-- Migration 380: AA-741 (S271 phase-1 findings, Blog) — register three prompt versions in shared.prompt_version, so the
-- ledger can tell the new blog prompts from the old ones: t9_write v2 (blog length and one-pass budget), t9_write v3
-- (v2 + the walk focus) and t8_angle_gen v2 (the FOCUS sentence).
--
-- Why. (1) The S271 audit (4 audit tenants, 06/11/2026) saw t9_write for a blog average 1,846 output tokens but reach
-- 11,465, and 4 calls hit the 12,000 ceiling (3 cut, 1 billed but unusable). The T9 budget PR gives every blog prompt
-- a word band with a hard floor (F4's floor in words), a section cap and a one-pass rule
-- (services/acp_content_writing/prompts.py, _BLOG_LENGTH_INSTRUCTIONS): t9_write v2. (2) The Blog Segment Slate PR
-- (Blog proposes Segments that carry their Route walk) writes a Segment-grain Blog walk about its Subject's own moment
-- (services/acp_shared/walk_focus.py): T9 marks that moment FOCUS and appends the WALK FOCUS rule (_WALK_FOCUS_MARK,
-- _WALK_FOCUS_RULE): t9_write v3; T8's SYSTEM_PROMPT gains one sentence on a ROUTE that names a FOCUS: t8_angle_gen
-- v2. The gateway writes llm_call_log.prompt_version only when the deployed source, the manifest
-- (shared/llm_client/prompt_versions.json) and a row of this table agree (shared/llm_client/prompt_registry.
-- version_for); without these rows every t9_write / t8_angle_gen call after each code deploy would carry
-- prompt_version NULL and the before / after read (cost, tokens, quality per version) would be lost.
--
-- What.
--   1. Three rows (sha256 of each version's hashed symbols' source text in its source file, never the text; created_by
--      'migration-380'), the output of
--      `python3 scripts/prompt_registry_check.py --sql --unregistered --created-by migration-380` on the Slate PR's tree:
--        t9_write     v2  SYSTEM_PROMPT, build_user_prompt, _BLOG_WORDS, _BLOG_WORDS_MAX, _BLOG_SECTIONS_MAX,
--                         _BLOG_LENGTH_INSTRUCTIONS (the T9 budget PR's source)
--        t9_write     v3  the same + _WALK_FOCUS_MARK, _WALK_FOCUS_RULE (the Slate PR's source)
--        t8_angle_gen v2  SYSTEM_PROMPT, SYSTEM_PROMPT_R8, system_prompt, build_user_prompt (the Slate PR's source)
--      ON CONFLICT (stage, version) DO NOTHING.
--   2. Guard: each row exists with exactly this hash and path (a version registered earlier with another hash would be
--      kept silently by the ON CONFLICT and every call of it would carry prompt_version NULL).
--   3. Register 380.
--
-- Behaviour. Until a code PR deploys, no deployed prompt matches its new version and nothing changes (calls keep 'v1').
-- After the T9 budget PR deploys, within the registry cache TTL, t9_write rows carry 'v2'; after the Slate PR, 'v3'
-- and t8_angle_gen 'v2'. No route, model, cost or prompt change by this file. Older versions stay registered.
--
-- Class: contract (root ADR 0017 d3: rows into an existing table), so no migrate directive header and MIG-4 order:
-- (1) this migration-only PR merges to AA-CIS-App main; (2) the byte copy in AA-CIS-Infra db/migrations/cis/ merges;
-- (3) Infra Migration Apply applies it once every job table is idle (root ADR 0017a); (4) then the T9 budget PR, then
-- the Slate PR (stacked on it) merge. No readiness bump. DM-7.1: no new table.
--
-- Rollback (a NEW forward migration): DELETE FROM shared.prompt_version WHERE created_by = 'migration-380';
-- (calls of these versions then carry prompt_version NULL; rows already written keep their version).
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
        RAISE EXCEPTION 'migration 380: shared.prompt_version is missing (apply 321 first)';
    END IF;
END $$;

-- ── 1. the manifest rows ─────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.prompt_version (stage, version, prompt_sha256, source_path, created_by) VALUES
    ('t9_write', 'v2', '0a1d1f804988534d78bc9e15513251a8e98a5c6a4442ffdf467c9d94f861c277', 'services/acp_content_writing/prompts.py', 'migration-380'),
    ('t9_write', 'v3', '2fc26ac2cf17abd0bee803f330c9bab7b8500fcbc1c8d8fb156450891d067d0b', 'services/acp_content_writing/prompts.py', 'migration-380'),
    ('t8_angle_gen', 'v2', '4972f4467440c80fb06efefa7982f2ce4bc6493e9634b20f78effa5dea3c1240', 'services/acp_angle_gate/prompts.py', 'migration-380')
ON CONFLICT (stage, version) DO NOTHING;

-- ── 2. guard ─────────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    expected CONSTANT text[][] := ARRAY[
        ['t9_write', 'v2', '0a1d1f804988534d78bc9e15513251a8e98a5c6a4442ffdf467c9d94f861c277', 'services/acp_content_writing/prompts.py'],
        ['t9_write', 'v3', '2fc26ac2cf17abd0bee803f330c9bab7b8500fcbc1c8d8fb156450891d067d0b', 'services/acp_content_writing/prompts.py'],
        ['t8_angle_gen', 'v2', '4972f4467440c80fb06efefa7982f2ce4bc6493e9634b20f78effa5dea3c1240', 'services/acp_angle_gate/prompts.py']
    ];
    i int;
BEGIN
    FOR i IN 1 .. array_length(expected, 1) LOOP
        IF NOT EXISTS (
            SELECT 1 FROM shared.prompt_version
             WHERE stage = expected[i][1] AND version = expected[i][2]
               AND prompt_sha256 = expected[i][3] AND source_path = expected[i][4]
        ) THEN
            RAISE EXCEPTION 'migration 380: % % is registered with another hash or path, or missing (a version is '
                            'never edited: bump the manifest instead)', expected[i][1], expected[i][2];
        END IF;
    END LOOP;
END $$;

-- ── 3. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('380', now(), 'AA-741 S271: register prompt versions t9_write v2 / v3 and t8_angle_gen v2 (no prompt text)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
