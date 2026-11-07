-- Migration 389: AA-1047 (S272 Quality W1, root ADR 0020 "policy registry") — register the prompt versions the
-- fail-closed revision of the writing policy registry moves, in shared.prompt_version.
--
-- Why. Migration 387 (applied on Dev) registered sixteen versions hashed with the policy as it stood then. The code PR
-- then went back to main's gates until the W2 claim instrument ("fail closed until W2": claim topics
-- `enforcement: block_until_w2_instrument`, the T2 meal-line exemption withdrawn, `meals.source_day_line: a1_only`)
-- and the R2 judge lost its dead cutter (`clip`, `CUT_MARK`). That moved the compiled policy_sha, and every prompt
-- whose source file reads the policy hashes the policy_sha (shared/llm_client/prompt_registry.prompt_hash_of), so the
-- same sixteen stages hash differently from their 387 rows. A version is never edited (387's guard would stop a
-- re-run), so each stage gets the next version:
--   t9_write v5, writing_memory_eval v4 (its judge_version moves too: the source layout no longer names a cut mark),
--   and v3 of a3_place_card, a3_place_card_check, s1_brand_audit, t2_brand_audit, s1_flag_fix, t2_flag_fix,
--   s1_generate, t2_generate, s1_judge, t2_judge, t9_faq_answer_fit, t9_repair, t10_claims, t10_judge.
-- The gateway writes llm_call_log.prompt_version only when the deployed source, the manifest
-- (shared/llm_client/prompt_versions.json) and a row of this table agree (prompt_registry.version_for); without these
-- rows every call of these stages after the code deploy would carry prompt_version NULL. The 387 rows stay (no deployed
-- code ever matched them; harmless history).
--
-- What.
--   1. Sixteen rows (sha256 of the hashed symbols' source text plus the policy_sha, never the text; created_by
--      'migration-389'), the output of
--      `python3 scripts/prompt_registry_check.py --sql --unregistered --created-by migration-389` on the code PR's
--      tree. ON CONFLICT (stage, version) DO NOTHING.
--   2. Guard: each row exists with exactly this hash and path (a version registered earlier with another hash would
--      be kept silently by the ON CONFLICT and every call of it would carry prompt_version NULL).
--   3. Register 389.
--
-- Behaviour. Until the code PR deploys, no deployed prompt matches these versions and nothing changes (calls keep
-- their current version). After it deploys, within the registry cache TTL, rows carry the new versions. No route,
-- model, cost or prompt change by this file. Older versions stay registered.
--
-- Class: contract (root ADR 0017 d3: rows into an existing table), so no migrate directive header and MIG-4 order:
-- (1) this migration-only PR merges to AA-CIS-App main; (2) the byte copy in AA-CIS-Infra db/migrations/cis/ merges;
-- (3) Infra Migration Apply applies it once every job table is idle (root ADR 0017a); (4) then the AA-1047 policy
-- registry code PR merges. No readiness bump. DM-7.1: no new table.
-- Order: 388 (another lane) may not be on Dev when this applies; then the apply needs --allow-out-of-order. The file
-- does not depend on 388.
--
-- Rollback (a NEW forward migration): DELETE FROM shared.prompt_version WHERE created_by = 'migration-389';
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
        RAISE EXCEPTION 'migration 389: shared.prompt_version is missing (apply 321 first)';
    END IF;
END $$;

-- ── 1. the manifest rows ─────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.prompt_version (stage, version, prompt_sha256, source_path, created_by) VALUES
    ('a3_place_card', 'v3', '1fd224bb585f38a290f530892fde49be12b7417addef9d84d78b41110dd0d475', 'services/acp_shared/place_cards.py', 'migration-389'),
    ('a3_place_card_check', 'v3', '6d0fe409c8e691897920664fe4b4dbb2eba3e36f26eb2f0d875cbb300bd8ffcd', 'services/acp_shared/place_cards.py', 'migration-389'),
    ('s1_brand_audit', 'v3', 'a7799f358e4631bbe89eaeb03a9812ce436edda8c993f9629336bdc0400d7263', 'services/content_generation/brand_standards.py', 'migration-389'),
    ('s1_flag_fix', 'v3', '5b757b82efb6b0916861aa3793385d40d2cbfdddaa5313df1498250ef858f488', 'services/content_generation/flag_fix_node.py', 'migration-389'),
    ('s1_generate', 'v3', 'b42594d5827f9d3f60f1dcaf43d8a4e2bb19693df90a0c3a5caa96dfb26a60d3', 'services/content_generation/s1_writer_v2.py', 'migration-389'),
    ('s1_judge', 'v3', 'dbd95e1ffa6ae47051c655a083ef2270b42f3b6201cf46490bac2bc765c0de28', 'services/content_generation/brand_fit_v2.py', 'migration-389'),
    ('t10_claims', 'v3', '9e14d1d7b050378b1e5652ba39c8627c6bab035a48a04fed1d7231de92ee72b8', 'services/acp_content_writing/claim_rules.py', 'migration-389'),
    ('t10_judge', 'v3', '59525f9613545f010408838a516f5c5db9e232939588c5084cbaf12dbe645fb0', 'services/acp_content_writing/quality_gates.py', 'migration-389'),
    ('t2_brand_audit', 'v3', 'a7799f358e4631bbe89eaeb03a9812ce436edda8c993f9629336bdc0400d7263', 'services/content_generation/brand_standards.py', 'migration-389'),
    ('t2_flag_fix', 'v3', '5b757b82efb6b0916861aa3793385d40d2cbfdddaa5313df1498250ef858f488', 'services/content_generation/flag_fix_node.py', 'migration-389'),
    ('t2_generate', 'v3', 'd02d0405b0ceb579516a1440e5c934fe55ff6bc7f6b97c51470cb42fa8d6acba', 'services/content_generation/prompts.py', 'migration-389'),
    ('t2_judge', 'v3', 'dbd95e1ffa6ae47051c655a083ef2270b42f3b6201cf46490bac2bc765c0de28', 'services/content_generation/brand_fit_v2.py', 'migration-389'),
    ('t9_faq_answer_fit', 'v3', '9919c69e5c1f1c28e816287ddeae400188c122c1a7826a0c2c738facd3a7f4e1', 'services/acp_content_writing/faq_answer_fit.py', 'migration-389'),
    ('t9_repair', 'v3', '040e34bd28224c78bf17f80fcfe6abc425580fe76c4770e4ddb828bf42128cf8', 'services/acp_content_writing/generate.py', 'migration-389'),
    ('t9_write', 'v5', '6c967aab65584abe3191a3a6c9422fb91e1faf5be6d4b548a1e8cfa4ca81763f', 'services/acp_content_writing/prompts.py', 'migration-389'),
    ('writing_memory_eval', 'v4', '7f92769d2b7812f7cd737351e70e635e6285abeb7c6a336a856504c9a3d408b1', 'services/writing_memory/eval_judge.py', 'migration-389')
ON CONFLICT (stage, version) DO NOTHING;

-- ── 2. guard ─────────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    expected CONSTANT text[][] := ARRAY[
        ['a3_place_card', 'v3', '1fd224bb585f38a290f530892fde49be12b7417addef9d84d78b41110dd0d475', 'services/acp_shared/place_cards.py'],
        ['a3_place_card_check', 'v3', '6d0fe409c8e691897920664fe4b4dbb2eba3e36f26eb2f0d875cbb300bd8ffcd', 'services/acp_shared/place_cards.py'],
        ['s1_brand_audit', 'v3', 'a7799f358e4631bbe89eaeb03a9812ce436edda8c993f9629336bdc0400d7263', 'services/content_generation/brand_standards.py'],
        ['s1_flag_fix', 'v3', '5b757b82efb6b0916861aa3793385d40d2cbfdddaa5313df1498250ef858f488', 'services/content_generation/flag_fix_node.py'],
        ['s1_generate', 'v3', 'b42594d5827f9d3f60f1dcaf43d8a4e2bb19693df90a0c3a5caa96dfb26a60d3', 'services/content_generation/s1_writer_v2.py'],
        ['s1_judge', 'v3', 'dbd95e1ffa6ae47051c655a083ef2270b42f3b6201cf46490bac2bc765c0de28', 'services/content_generation/brand_fit_v2.py'],
        ['t10_claims', 'v3', '9e14d1d7b050378b1e5652ba39c8627c6bab035a48a04fed1d7231de92ee72b8', 'services/acp_content_writing/claim_rules.py'],
        ['t10_judge', 'v3', '59525f9613545f010408838a516f5c5db9e232939588c5084cbaf12dbe645fb0', 'services/acp_content_writing/quality_gates.py'],
        ['t2_brand_audit', 'v3', 'a7799f358e4631bbe89eaeb03a9812ce436edda8c993f9629336bdc0400d7263', 'services/content_generation/brand_standards.py'],
        ['t2_flag_fix', 'v3', '5b757b82efb6b0916861aa3793385d40d2cbfdddaa5313df1498250ef858f488', 'services/content_generation/flag_fix_node.py'],
        ['t2_generate', 'v3', 'd02d0405b0ceb579516a1440e5c934fe55ff6bc7f6b97c51470cb42fa8d6acba', 'services/content_generation/prompts.py'],
        ['t2_judge', 'v3', 'dbd95e1ffa6ae47051c655a083ef2270b42f3b6201cf46490bac2bc765c0de28', 'services/content_generation/brand_fit_v2.py'],
        ['t9_faq_answer_fit', 'v3', '9919c69e5c1f1c28e816287ddeae400188c122c1a7826a0c2c738facd3a7f4e1', 'services/acp_content_writing/faq_answer_fit.py'],
        ['t9_repair', 'v3', '040e34bd28224c78bf17f80fcfe6abc425580fe76c4770e4ddb828bf42128cf8', 'services/acp_content_writing/generate.py'],
        ['t9_write', 'v5', '6c967aab65584abe3191a3a6c9422fb91e1faf5be6d4b548a1e8cfa4ca81763f', 'services/acp_content_writing/prompts.py'],
        ['writing_memory_eval', 'v4', '7f92769d2b7812f7cd737351e70e635e6285abeb7c6a336a856504c9a3d408b1', 'services/writing_memory/eval_judge.py']
    ];
    i int;
BEGIN
    FOR i IN 1 .. array_length(expected, 1) LOOP
        IF NOT EXISTS (
            SELECT 1 FROM shared.prompt_version
             WHERE stage = expected[i][1] AND version = expected[i][2]
               AND prompt_sha256 = expected[i][3] AND source_path = expected[i][4]
        ) THEN
            RAISE EXCEPTION 'migration 389: % % is registered with another hash or path, or missing (a version is '
                            'never edited: bump the manifest instead)', expected[i][1], expected[i][2];
        END IF;
    END LOOP;
END $$;

-- ── 3. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('389', now(), 'AA-1047 S272 W1: register prompt versions moved by the fail-closed writing policy (no prompt text)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
