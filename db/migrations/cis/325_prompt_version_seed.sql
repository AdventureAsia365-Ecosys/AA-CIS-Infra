-- Migration 325: AA-642 (AI gateway v2, plan S263 slice D1, gap OPS-03) — register the 32 prompt versions of the
-- prompt manifest in shared.prompt_version, so the ledger can say which prompt a call ran.
--
-- Why. Migration 321 (AA-900) created shared.prompt_version empty, and the gateway writes llm_call_log.prompt_version
-- only when the deployed prompt source, the manifest (shared/llm_client/prompt_versions.json) and a row of this table
-- agree (shared/llm_client/prompt_registry.version_for). With no rows every ledger row has prompt_version NULL: a
-- prompt change could not be told apart in cost, quality or eval reads (root plan
-- docs/audits/2026-11-01-S263-gateway-gap-audit/plan.md, gap OPS-03).
--
-- What.
--   1. 32 rows, one per manifest entry today (32 stages, version v1 each): stage, version, prompt_sha256 (sha256 of
--      the source text of the prompt symbols, never the text), source_path, created_by 'migration-325'. The rows are
--      the output of `python3 scripts/prompt_registry_check.py --sql --created-by migration-325`. ON CONFLICT
--      (stage, version) DO NOTHING.
--   2. Guard: every one of the 32 (stage, version) rows exists with exactly this prompt_sha256 and source_path (a row
--      registered earlier with another hash would otherwise be kept silently by the ON CONFLICT and every call of that
--      stage would keep prompt_version NULL).
--   3. Register 325.
--
-- The CI gate that keeps this true from now on (same PR): tests/unit/test_aa900_prompt_registry_gate.py
-- (scripts/prompt_registry_check.py) also fails when a manifest entry is not inserted by any file in api/migrations/:
-- a prompt change = `--bump` + a new migration with the `--sql --unregistered` rows.
--
-- Behaviour. Within CACHE_TTL_SECONDS (10 min) of the apply, every new llm_call_log row of a manifest stage whose
-- deployed prompt still matches its v1 hash carries prompt_version 'v1' (refused / error attempt rows included). No
-- route, model, cost or prompt changes. Nothing else reads the table.
--
-- Class: contract (root ADR 0017 d3: rows into an existing table), so no "-- migrate: expand" header and MIG-4 order:
-- (1) this PR merges to AA-CIS-App main (the file and its CI gate; no code that depends on it); (2) the byte copy in
-- AA-CIS-Infra db/migrations/cis/ merges (bot/migration-copy/cis-325, contract: merged by hand after its checks);
-- (3) a manual DB Migrate apply (check, then apply) once every job table is idle; (4) the bot/db-schema-reference PR
-- (if any: rows only, the structure does not change). No readiness bump. DM-7.1: no new table.
--
-- Rollback (a NEW forward migration): DELETE FROM shared.prompt_version WHERE created_by = 'migration-325';
-- (the ledger then writes prompt_version NULL again; rows already written keep 'v1').
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of the table.
-- Grants: none (cis_app keeps SELECT from 321).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.prompt_version') IS NULL THEN
        RAISE EXCEPTION 'migration 325: shared.prompt_version is missing (apply 321 first)';
    END IF;
END $$;

-- ── 1. the 32 manifest rows ──────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.prompt_version (stage, version, prompt_sha256, source_path, created_by) VALUES
    ('a0_column_map', 'v1', '611ad8b6916a6f7d1a51f7dd08b237920d448ef6c807b04fdbc78c15bcd45fd6', 'shared/llm_client/column_mapper.py', 'migration-325'),
    ('a3_atomize', 'v1', '788aa1e89a28e265c1bbc1a3a1ff4950219b050d1ecbff84a14773b7301faa37', 'services/acp_shared/atom_extraction.py', 'migration-325'),
    ('a3_place_card', 'v1', '91c5a7a019faea04edb0b7ecbb0bde636286554215d66c640cb3fc981c3bcdbc', 'services/acp_shared/place_cards.py', 'migration-325'),
    ('a3_place_card_check', 'v1', '476e183a4002c0706a789b563638fcc2d789eecadcfa98b91194aef72f048eff', 'services/acp_shared/place_cards.py', 'migration-325'),
    ('a3_place_days', 'v1', '7ef8f7d14cd331ef8f7c9b82bd7470cbecfb82b1dd4986ff44fbd177a38eb696', 'services/places/days.py', 'migration-325'),
    ('a3_place_dedupe', 'v1', 'cca9491aaf31da0057fd3cd13232352efc7a7ce456130ed71f0b6114d94d25b1', 'services/places/dedupe.py', 'migration-325'),
    ('a3_place_dedupe_check', 'v1', 'cca9491aaf31da0057fd3cd13232352efc7a7ce456130ed71f0b6114d94d25b1', 'services/places/dedupe.py', 'migration-325'),
    ('a3_place_locate', 'v1', 'c9fd0152c321c1ef1d16f8a1e306bd08780aa364af13a81e4ec42aee1b4f2d41', 'services/places/locate.py', 'migration-325'),
    ('a3_search_demand', 'v1', 'c417a3b548f924154abd4824e9421125b561a8f32a1a6a61b353a2e1a78405bc', 'services/acp_contract/segment_research.py', 'migration-325'),
    ('s1_brand_audit', 'v1', 'f9cbafc5d5e29d23d20a0cfe54a9d0842047d8b4ac7a37e43b6fc06b2cc7360f', 'services/content_generation/brand_standards.py', 'migration-325'),
    ('s1_flag_fix', 'v1', '1bf4af05aaadbeb6dae4b9f7597073d60c40b4439e1376e486aca3b173923e42', 'services/content_generation/flag_fix_node.py', 'migration-325'),
    ('s1_generate', 'v1', 'f3ab407a9f5d124859fd77b3cc7c4131c5c3f1ea4d48afe25fad2b2351fc006d', 'services/content_generation/s1_writer_v2.py', 'migration-325'),
    ('s1_itinerary_nudge', 'v1', 'a9e4c0126545921b2547de6c865f2f2e6732f98bea34af99fe1bce5086d9121d', 'services/content_generation/itinerary_utils.py', 'migration-325'),
    ('s1_judge', 'v1', '390f7fc2eebc93897c2da5c0fc56b3f517be9be05438dfc068f915bfd76b351c', 'services/content_generation/brand_fit_v2.py', 'migration-325'),
    ('s1_source_facts', 'v1', 'f1607ebad95744e225cfcbda9fe61704aec51b9784815635f62c829224070436', 'services/content_generation/source_facts.py', 'migration-325'),
    ('supply_content_writer', 'v1', '51ae46761bb836f998c0e28c5cfcd79481628b52e6f1c2d75d13e143772e1a47', 'services/supply_content/writer.py', 'migration-325'),
    ('t10_adjudicate', 'v1', '46ccd5b7b70380e2b5508559d931a6f527aafc42b864fd4464fa77f0ccd360fd', 'services/acp_content_writing/seed_align/adjudicate.py', 'migration-325'),
    ('t10_claims', 'v1', '7e99cefd208b339085e00e2c35c9eb058cb6b58f2a298a437c03e7ca363f4e4c', 'services/acp_content_writing/claim_rules.py', 'migration-325'),
    ('t10_judge', 'v1', '7351485bea5a7b869c999d77ff0ca3357e9c6740049ed4ffe9531f8727b5aa6f', 'services/acp_content_writing/quality_gates.py', 'migration-325'),
    ('t2_brand_audit', 'v1', 'f9cbafc5d5e29d23d20a0cfe54a9d0842047d8b4ac7a37e43b6fc06b2cc7360f', 'services/content_generation/brand_standards.py', 'migration-325'),
    ('t2_flag_fix', 'v1', '1bf4af05aaadbeb6dae4b9f7597073d60c40b4439e1376e486aca3b173923e42', 'services/content_generation/flag_fix_node.py', 'migration-325'),
    ('t2_generate', 'v1', '324a9e3818d2085063ae52726f526f823116265fcdfa902b45a0a07a6f739d4f', 'services/content_generation/prompts.py', 'migration-325'),
    ('t2_itinerary_nudge', 'v1', '7d1658b33072f0dc7b714ebd96157cb9e89a65b2cfe830cd44fc0fea192ef82f', 'services/content_generation/itinerary_utils.py', 'migration-325'),
    ('t2_judge', 'v1', '390f7fc2eebc93897c2da5c0fc56b3f517be9be05438dfc068f915bfd76b351c', 'services/content_generation/brand_fit_v2.py', 'migration-325'),
    ('t7_debate_judge', 'v1', '7fd11eb74b684358ac24a7adc6cddb9a2dbc4f01b183b0bb0e958242789a67a8', 'services/content_generation/brand_fit.py', 'migration-325'),
    ('t8_angle_gen', 'v1', 'ac67e8d2e32fae9f16f090efd605a23d2bcf79fc2879c38d369a3f55f4f4fb72', 'services/acp_angle_gate/prompts.py', 'migration-325'),
    ('t9_faq_answer_fit', 'v1', '0bb91f4cf4e8630e222ac1e95f2454c5f9fa674575e162cf34e9cdcdb87636a0', 'services/acp_content_writing/faq_answer_fit.py', 'migration-325'),
    ('t9_faq_filter', 'v1', 'eae27d526be68f04f32ebd1acc11c0ba689c9c054d2de11d6a16dc795180f6eb', 'services/acp_content_writing/faq_filter.py', 'migration-325'),
    ('t9_repair', 'v1', '2131e13b610294d088c1f1da91273f073805e4661a7d98d841f1f20a331afb59', 'services/acp_content_writing/generate.py', 'migration-325'),
    ('t9_write', 'v1', '166d555c256cf6ea83edc6a60d61a5a8400c9c85b6f824de643fa755ad873bb5', 'services/acp_content_writing/prompts.py', 'migration-325'),
    ('writing_memory_eval', 'v1', 'c8ddffc252af1784b0ced1bdddc470f1254635fde62ea34e4ce7952aec93ce9f', 'services/writing_memory/eval_judge.py', 'migration-325'),
    ('writing_memory_mine', 'v1', '2c57d971d6c37305c06f1ef0dc8bb3e238bcb5a4dbc0f590d1950cb46d3c4e1b', 'services/writing_memory/drafter.py', 'migration-325')
ON CONFLICT (stage, version) DO NOTHING;

-- ── 2. guard: each row is registered with this exact hash and path ───────────────────────────────────────────────

DO $$
DECLARE
    n     int;
    wrong text;
BEGIN
    WITH expected (stage, version, prompt_sha256, source_path) AS (VALUES
        ('a0_column_map', 'v1', '611ad8b6916a6f7d1a51f7dd08b237920d448ef6c807b04fdbc78c15bcd45fd6', 'shared/llm_client/column_mapper.py'),
        ('a3_atomize', 'v1', '788aa1e89a28e265c1bbc1a3a1ff4950219b050d1ecbff84a14773b7301faa37', 'services/acp_shared/atom_extraction.py'),
        ('a3_place_card', 'v1', '91c5a7a019faea04edb0b7ecbb0bde636286554215d66c640cb3fc981c3bcdbc', 'services/acp_shared/place_cards.py'),
        ('a3_place_card_check', 'v1', '476e183a4002c0706a789b563638fcc2d789eecadcfa98b91194aef72f048eff', 'services/acp_shared/place_cards.py'),
        ('a3_place_days', 'v1', '7ef8f7d14cd331ef8f7c9b82bd7470cbecfb82b1dd4986ff44fbd177a38eb696', 'services/places/days.py'),
        ('a3_place_dedupe', 'v1', 'cca9491aaf31da0057fd3cd13232352efc7a7ce456130ed71f0b6114d94d25b1', 'services/places/dedupe.py'),
        ('a3_place_dedupe_check', 'v1', 'cca9491aaf31da0057fd3cd13232352efc7a7ce456130ed71f0b6114d94d25b1', 'services/places/dedupe.py'),
        ('a3_place_locate', 'v1', 'c9fd0152c321c1ef1d16f8a1e306bd08780aa364af13a81e4ec42aee1b4f2d41', 'services/places/locate.py'),
        ('a3_search_demand', 'v1', 'c417a3b548f924154abd4824e9421125b561a8f32a1a6a61b353a2e1a78405bc', 'services/acp_contract/segment_research.py'),
        ('s1_brand_audit', 'v1', 'f9cbafc5d5e29d23d20a0cfe54a9d0842047d8b4ac7a37e43b6fc06b2cc7360f', 'services/content_generation/brand_standards.py'),
        ('s1_flag_fix', 'v1', '1bf4af05aaadbeb6dae4b9f7597073d60c40b4439e1376e486aca3b173923e42', 'services/content_generation/flag_fix_node.py'),
        ('s1_generate', 'v1', 'f3ab407a9f5d124859fd77b3cc7c4131c5c3f1ea4d48afe25fad2b2351fc006d', 'services/content_generation/s1_writer_v2.py'),
        ('s1_itinerary_nudge', 'v1', 'a9e4c0126545921b2547de6c865f2f2e6732f98bea34af99fe1bce5086d9121d', 'services/content_generation/itinerary_utils.py'),
        ('s1_judge', 'v1', '390f7fc2eebc93897c2da5c0fc56b3f517be9be05438dfc068f915bfd76b351c', 'services/content_generation/brand_fit_v2.py'),
        ('s1_source_facts', 'v1', 'f1607ebad95744e225cfcbda9fe61704aec51b9784815635f62c829224070436', 'services/content_generation/source_facts.py'),
        ('supply_content_writer', 'v1', '51ae46761bb836f998c0e28c5cfcd79481628b52e6f1c2d75d13e143772e1a47', 'services/supply_content/writer.py'),
        ('t10_adjudicate', 'v1', '46ccd5b7b70380e2b5508559d931a6f527aafc42b864fd4464fa77f0ccd360fd', 'services/acp_content_writing/seed_align/adjudicate.py'),
        ('t10_claims', 'v1', '7e99cefd208b339085e00e2c35c9eb058cb6b58f2a298a437c03e7ca363f4e4c', 'services/acp_content_writing/claim_rules.py'),
        ('t10_judge', 'v1', '7351485bea5a7b869c999d77ff0ca3357e9c6740049ed4ffe9531f8727b5aa6f', 'services/acp_content_writing/quality_gates.py'),
        ('t2_brand_audit', 'v1', 'f9cbafc5d5e29d23d20a0cfe54a9d0842047d8b4ac7a37e43b6fc06b2cc7360f', 'services/content_generation/brand_standards.py'),
        ('t2_flag_fix', 'v1', '1bf4af05aaadbeb6dae4b9f7597073d60c40b4439e1376e486aca3b173923e42', 'services/content_generation/flag_fix_node.py'),
        ('t2_generate', 'v1', '324a9e3818d2085063ae52726f526f823116265fcdfa902b45a0a07a6f739d4f', 'services/content_generation/prompts.py'),
        ('t2_itinerary_nudge', 'v1', '7d1658b33072f0dc7b714ebd96157cb9e89a65b2cfe830cd44fc0fea192ef82f', 'services/content_generation/itinerary_utils.py'),
        ('t2_judge', 'v1', '390f7fc2eebc93897c2da5c0fc56b3f517be9be05438dfc068f915bfd76b351c', 'services/content_generation/brand_fit_v2.py'),
        ('t7_debate_judge', 'v1', '7fd11eb74b684358ac24a7adc6cddb9a2dbc4f01b183b0bb0e958242789a67a8', 'services/content_generation/brand_fit.py'),
        ('t8_angle_gen', 'v1', 'ac67e8d2e32fae9f16f090efd605a23d2bcf79fc2879c38d369a3f55f4f4fb72', 'services/acp_angle_gate/prompts.py'),
        ('t9_faq_answer_fit', 'v1', '0bb91f4cf4e8630e222ac1e95f2454c5f9fa674575e162cf34e9cdcdb87636a0', 'services/acp_content_writing/faq_answer_fit.py'),
        ('t9_faq_filter', 'v1', 'eae27d526be68f04f32ebd1acc11c0ba689c9c054d2de11d6a16dc795180f6eb', 'services/acp_content_writing/faq_filter.py'),
        ('t9_repair', 'v1', '2131e13b610294d088c1f1da91273f073805e4661a7d98d841f1f20a331afb59', 'services/acp_content_writing/generate.py'),
        ('t9_write', 'v1', '166d555c256cf6ea83edc6a60d61a5a8400c9c85b6f824de643fa755ad873bb5', 'services/acp_content_writing/prompts.py'),
        ('writing_memory_eval', 'v1', 'c8ddffc252af1784b0ced1bdddc470f1254635fde62ea34e4ce7952aec93ce9f', 'services/writing_memory/eval_judge.py'),
        ('writing_memory_mine', 'v1', '2c57d971d6c37305c06f1ef0dc8bb3e238bcb5a4dbc0f590d1950cb46d3c4e1b', 'services/writing_memory/drafter.py')
    )
    SELECT count(p.stage),
           string_agg(e.stage || ' ' || e.version, ', ' ORDER BY e.stage)
             FILTER (WHERE p.stage IS NULL OR p.prompt_sha256 <> e.prompt_sha256 OR p.source_path <> e.source_path)
      INTO n, wrong
      FROM expected e
      LEFT JOIN shared.prompt_version p ON p.stage = e.stage AND p.version = e.version;
    IF wrong IS NOT NULL THEN
        RAISE EXCEPTION 'migration 325: registered with another hash or path, or missing: % (a version is never '
                        'edited: bump the manifest instead)', wrong;
    END IF;
    IF n <> 32 THEN
        RAISE EXCEPTION 'migration 325: expected 32 registered prompt versions, found %', n;
    END IF;
END $$;

-- ── 3. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('325', now(), 'AA-642 D1: register the 32 manifest prompt versions in shared.prompt_version (no prompt text)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
