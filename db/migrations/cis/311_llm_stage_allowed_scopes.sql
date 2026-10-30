-- Migration 311: AA-1002 (LLM gateway slice S5) — shared.llm_role_config.allowed_scopes: the data policy per stage.
--
-- Why. Which stage may send its content outside AWS was code: the S235 constant in the admin (an OpenAI platform API
-- model only as the last fallback) and the S3 rule in vendor_route.deployment_plan (a vendor_direct connection only as
-- a model's first enabled deployment, "until S5"). Every connection already carries a data_scope (304: aws_only for a
-- Bedrock account, vendor_direct for a vendor API). This file gives every stage the scopes its content may use, so
-- the gateway (shared/llm_client/data_scope.py) and the admin decide from data, and opening a stage to a vendor API is
-- a reviewed migration, not a code constant or an admin click.
--
-- What.
--   1. ADD COLUMN allowed_scopes text[] (NULL = no stage policy: the code keeps its pre-S5 rules).
--   2. Backfill, from the routes as they are (no call changes): a stage whose route (model_id, fallback_model_ids,
--      shadow_model_id) names a catalog model whose EVERY deployment is on a connection outside AWS (data_scope <>
--      'aws_only': today gpt-6-luna-openai, the S235 last resort on openai-direct) gets {aws_only, vendor_direct};
--      every other stage {aws_only}. Dev on 30/10: the seven judge / validate stages with gpt-6-luna-openai last
--      (s1_judge, t2_judge, t7_debate_judge, t10_judge, writing_memory_mine, writing_memory_eval, a3_place_dedupe) and
--      t10_adjudicate (308). Only NULL rows are written (a re-run keeps a later decision).
--   3. DEFAULT ARRAY['aws_only'], NOT NULL is NOT set (a NULL row stays "no policy", the code's safe reading), and
--      CHECK: NULL, or a non-empty subset of {aws_only, vendor_direct} (connections.DATA_SCOPES).
--   4. Grants: cis_app keeps INSERT / UPDATE on every column EXCEPT allowed_scopes (column grants; a new stage row
--      takes the default aws_only). The scope is migration-only, like llm_provider_connection.data_scope (310). The
--      admin PATCH endpoints never write it (they return it read-only). SELECT / DELETE unchanged; tripplanner keeps
--      its SELECT (its gateway lists its columns: no SELECT *).
--   5. Register 311.
--
-- Guards (RAISE rolls the whole file back): the 304 registry tables exist; after the backfill no stage that names a
-- provider='openai' catalog row (the OpenAI platform API) is left without vendor_direct (the two definitions agree).
--
-- Behaviour. None on apply: with the backfilled scopes every Dev stage makes exactly the calls it made before
-- (tests/unit/test_aa1002_s3_routes_snapshot.py, *_scoped cases; the code reads the column with a fallback when it is
-- missing, so code and file may ship in either order). Effect of the data from now on: an aws_only stage never calls
-- a vendor_direct deployment, even one an admin puts first; a stage with vendor_direct may fall back to a vendor API
-- behind acc3 (with anthropic-direct still switched off, nothing changes today).
--
-- Contract file (no expand header: ADD CONSTRAINT, UPDATE of existing rows, grant changes on an existing table): DB
-- Migrate apply by hand with the job tables idle, then the S5 code PR (MIG-4). Number: 310 is the highest on main.
--
-- Rollback (a NEW forward migration, after the code is reverted; the code also treats NULL as "no policy"):
--   GRANT INSERT, UPDATE ON shared.llm_role_config TO cis_app;
--   ALTER TABLE shared.llm_role_config DROP CONSTRAINT llm_role_config_allowed_scopes_check;
--   ALTER TABLE shared.llm_role_config DROP COLUMN allowed_scopes;        (a destructive file)
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.llm_role_config') IS NULL OR to_regclass('shared.llm_provider_connection') IS NULL
       OR to_regclass('shared.llm_model_deployment') IS NULL OR to_regclass('shared.llm_model_catalog') IS NULL THEN
        RAISE EXCEPTION 'migration 311: shared.llm_role_config (137) or the 304 registry tables are missing';
    END IF;
END $$;

ALTER TABLE shared.llm_role_config ADD COLUMN IF NOT EXISTS allowed_scopes text[];

COMMENT ON COLUMN shared.llm_role_config.allowed_scopes IS
    'AA-1002 S5: the data scopes (shared.llm_provider_connection.data_scope) this stage''s content may be sent '
    'through: {aws_only} or {aws_only,vendor_direct}. NULL = no stage policy (pre-S5 rules). Migration-only.';

-- 2. Backfill from the routes as they are.
WITH reach AS (
    SELECT d.model_key, bool_and(c.data_scope <> 'aws_only') AS outside_only
      FROM shared.llm_model_deployment d
      JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key
     GROUP BY d.model_key
), outside AS (
    SELECT model_key FROM reach WHERE outside_only
)
UPDATE shared.llm_role_config r
   SET allowed_scopes = CASE
           WHEN EXISTS (SELECT 1 FROM outside o
                         WHERE o.model_key = r.model_id
                            OR o.model_key = ANY (r.fallback_model_ids)
                            OR o.model_key = r.shadow_model_id)
           THEN ARRAY['aws_only', 'vendor_direct']::text[]
           ELSE ARRAY['aws_only']::text[]
       END
 WHERE r.allowed_scopes IS NULL;

-- 3. Default and CHECK.
ALTER TABLE shared.llm_role_config ALTER COLUMN allowed_scopes SET DEFAULT ARRAY['aws_only']::text[];

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'llm_role_config_allowed_scopes_check'
                      AND conrelid = 'shared.llm_role_config'::regclass) THEN
        ALTER TABLE shared.llm_role_config ADD CONSTRAINT llm_role_config_allowed_scopes_check CHECK (
            allowed_scopes IS NULL
            OR (cardinality(allowed_scopes) >= 1
                AND allowed_scopes <@ ARRAY['aws_only', 'vendor_direct']::text[]));
    END IF;
END $$;

-- 4. The scope is migration-only: column grants for everything else.
REVOKE INSERT, UPDATE ON shared.llm_role_config FROM cis_app;
GRANT INSERT (stage, role, provider, model_id, account_route, is_active, updated_at, updated_by, fallback_model_ids,
              shadow_model_id, shadow_sample_pct)
    ON shared.llm_role_config TO cis_app;
GRANT UPDATE (stage, role, provider, model_id, account_route, is_active, updated_at, updated_by, fallback_model_ids,
              shadow_model_id, shadow_sample_pct)
    ON shared.llm_role_config TO cis_app;

-- Guard: the OpenAI platform API rows (catalog provider 'openai') are all reached outside AWS; a stage naming one
-- must have been given vendor_direct.
DO $$
DECLARE
    missed text;
    opened text;
BEGIN
    SELECT string_agg(r.stage, ', ' ORDER BY r.stage) INTO missed
      FROM shared.llm_role_config r
     WHERE NOT ('vendor_direct' = ANY (coalesce(r.allowed_scopes, ARRAY[]::text[])))
       AND EXISTS (SELECT 1 FROM shared.llm_model_catalog m
                    WHERE m.provider = 'openai'
                      AND (m.model_key = r.model_id OR m.model_key = ANY (r.fallback_model_ids)
                           OR m.model_key = r.shadow_model_id));
    IF missed IS NOT NULL THEN
        RAISE EXCEPTION 'migration 311: stages naming an OpenAI platform API model left without vendor_direct: %', missed;
    END IF;
    SELECT string_agg(stage, ', ' ORDER BY stage) INTO opened
      FROM shared.llm_role_config WHERE 'vendor_direct' = ANY (allowed_scopes);
    RAISE NOTICE 'migration 311: stages allowed vendor_direct: %', coalesce(opened, '(none)');
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('311', now(), 'AA-1002 S5: shared.llm_role_config.allowed_scopes (data policy per stage, backfilled from the routes)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
