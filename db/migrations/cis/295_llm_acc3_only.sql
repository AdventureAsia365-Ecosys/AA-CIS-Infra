-- Migration 295: AA-998 — LLM runs on acc3 only; remove the retired fallback account (acc1) from the gateway data.
--
-- Why. acc1 (the personal AWS account that was the cross-account LLM fallback since AA-397) leaves the ecosystem.
-- The CIS code no longer knows acc1 (bedrock_satellite has acc3 only, CatalogModel.account_for never picks a key
-- outside acc3 / acc2), but the data still names it in two places:
--   * shared.llm_model_catalog.bedrock_profile_ids — rows seeded by 169 (haiku, sonnet) and 259 (haiku-5-5,
--     sonnet-5-5) carry an "acc1" profile next to "acc3". TripPlanner's gateway reads this catalog and tries every
--     account a row has a profile for, so the key must go for TripPlanner to stop reaching acc1 too.
--   * shared.llm_role_config_account_route_check (137) still allows account_route = 'acc1'.
--
-- What.
--   1. Every catalog row: bedrock_profile_ids - 'acc1' (only rows that have the key are touched; updated_by and a
--      note record it). Guard: refuse if a row's ONLY profile is acc1 — removing it would leave a model with no
--      account, a decision for a human (live Dev 28/10/2026: none; the 4 rows above also carry acc3).
--   1b. The seeded catalog text the Settings pages render without a key or an issue ID: the cohere-embed-v4-acc3
--      label (240), gpt-6-luna's old blocked_reason (170), the haiku (169) and jev-latest (181) price_source.
--      Exact seeded value only.
--   2. account_route CHECK -> acc3 or NULL. Guard: refuse if any stage still routes to acc1 (live Dev: 0); move such
--      a stage to acc3 first (Settings > Models or a DB Migrate run-script), then apply.
--   Kept on purpose: silver_aa_internal.generated_content.satellite_account CHECK (100) still allows 'acc1', because
--   historical rows hold it; shared.llm_call_log.account has no CHECK and keeps its historical 'acc1' rows.
--
-- Order with the code. Independent: the code PR (AA-998) ignores an acc1 catalog key and refuses account_route
-- 'acc1' at the API, so this file can apply before or after it. REQUIRED_CIS_SCHEMA is not raised. Apply through
-- AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/), after 294.
--
-- Preflight (read-only; expected: acc1_rows = 4 on Dev, acc1_only = 0, acc1_routes = 0):
--   SELECT (SELECT count(*) FROM shared.llm_model_catalog WHERE bedrock_profile_ids ? 'acc1') AS acc1_rows,
--          (SELECT count(*) FROM shared.llm_model_catalog
--            WHERE bedrock_profile_ids ? 'acc1' AND (bedrock_profile_ids - 'acc1') = '{}'::jsonb) AS acc1_only,
--          (SELECT count(*) FROM shared.llm_role_config WHERE account_route = 'acc1') AS acc1_routes;
--
-- Rollback (a NEW forward migration; only if acc1 came back into the ecosystem, which AA-998 rules out):
--   restore the CHECK IN ('acc1', 'acc3') and the acc1 profiles of 169 / 259.
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of both tables.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    only_acc1 text;
    routed    text;
BEGIN
    IF to_regclass('shared.llm_model_catalog') IS NULL OR to_regclass('shared.llm_role_config') IS NULL THEN
        RAISE EXCEPTION 'migration 295: shared.llm_model_catalog (169) or shared.llm_role_config (137) is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '294') THEN
        RAISE NOTICE 'migration 295: 294 is not registered (Dev applies in version order)';
    END IF;

    SELECT string_agg(model_key, ', ' ORDER BY model_key) INTO only_acc1
      FROM shared.llm_model_catalog
     WHERE bedrock_profile_ids ? 'acc1'
       AND (bedrock_profile_ids - 'acc1') = '{}'::jsonb;
    IF only_acc1 IS NOT NULL THEN
        RAISE EXCEPTION 'migration 295: catalog rows whose only profile is acc1: % — give them an acc3 profile or '
                        'disable/delete them first (AA-998)', only_acc1;
    END IF;

    SELECT string_agg(stage, ', ' ORDER BY stage) INTO routed
      FROM shared.llm_role_config
     WHERE account_route = 'acc1';
    IF routed IS NOT NULL THEN
        RAISE EXCEPTION 'migration 295: stages still routed to acc1: % — set account_route to acc3 first (AA-998)',
            routed;
    END IF;
END $$;

UPDATE shared.llm_model_catalog
   SET bedrock_profile_ids = bedrock_profile_ids - 'acc1',
       notes = COALESCE(notes || ' ', '') || 'AA-998 (S255): acc1 profile removed (acc1 left the ecosystem; acc3 only).',
       updated_at = now(),
       updated_by = 'migration-295-aa998'
 WHERE bedrock_profile_ids ? 'acc1';

-- 1b. Seeded catalog text the Settings pages render (label, blocked_reason) named an account key: the admin shows
--     account IDs, never the keys. Only the exact seeded value is replaced, so an admin's own edit is kept.
UPDATE shared.llm_model_catalog
   SET label = 'Cohere Embed v4 (LLM account)', updated_at = now(), updated_by = 'migration-295-aa998'
 WHERE model_key = 'cohere-embed-v4-acc3' AND label = 'Cohere Embed v4 (acc3 satellite)';   -- seeded by 240
UPDATE shared.llm_model_catalog
   SET blocked_reason = 'Bedrock agreement not accepted on the LLM account yet (28/09/2026)',
       updated_at = now(), updated_by = 'migration-295-aa998'
 WHERE blocked_reason = 'Bedrock agreement not accepted on acc3 yet (28/09/2026)';           -- seeded by 170
-- Rendered text never carries an internal issue ID either (the price source column of Settings > Catalog).
UPDATE shared.llm_model_catalog
   SET price_source = 'pricing.py', updated_at = now(), updated_by = 'migration-295-aa998'
 WHERE price_source = 'pricing.py (AA-635)';                                                  -- seeded by 169
UPDATE shared.llm_model_catalog
   SET price_source = 'typesafe.ai pricing (24/09/2026): input only, output free',
       updated_at = now(), updated_by = 'migration-295-aa998'
 WHERE price_source = 'typesafe.ai pricing (AA-634, 24/09/2026): input only, output free';   -- seeded by 181

ALTER TABLE shared.llm_role_config
    DROP CONSTRAINT IF EXISTS llm_role_config_account_route_check;
ALTER TABLE shared.llm_role_config
    ADD CONSTRAINT llm_role_config_account_route_check
    CHECK (account_route IS NULL OR account_route = 'acc3');

COMMENT ON CONSTRAINT llm_role_config_account_route_check ON shared.llm_role_config IS
    'AA-998 (CIS 295): acc3 is the only satellite account (was acc1 | acc3 since 137).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('295', now(), 'AA-998: llm_model_catalog drops the acc1 profiles; llm_role_config.account_route acc3 only')
ON CONFLICT (version) DO NOTHING;

COMMIT;
