-- Migration 224: S235 — Bedrock first; the OpenAI platform API only as the LAST-RESORT fallback for a
-- Bedrock outage, never a primary or a shadow; GPT-4.1 retired (Nghiệp, 14/10/2026).
--
-- Live state before (S235 read-only audit, docs/audits/2026-10-14-S235-ecosystem-team-pilot/
-- ai-governance-audit/ai_audit.json): no primary or shadow uses the OpenAI platform API;
-- gpt-6-luna-openai is the LAST fallback of s1_judge, t10_judge, t2_judge, t7_debate_judge; gpt-4.1 is
-- in no route but still enabled in the catalog (last real OpenAI platform call 01/10/2026). A fresh DB
-- (137 -> 171 -> 219) also has gpt-4.1 as the judges' shadow.
--
-- 1. gpt-4.1 is removed from every fallback_model_ids array (order of the rest kept).
-- 2. Any other OpenAI-platform key (catalog provider = 'openai', i.e. gpt-6-luna-openai) is kept only
--    where it is the LAST element of fallback_model_ids; an occurrence anywhere else is removed.
-- 3. A gpt-4.1 shadow is cleared (shadow_model_id NULL, shadow_sample_pct 0).
-- 4. The gpt-4.1 catalog row is disabled with a blocked_reason. gpt-6-luna-openai stays enabled.
--    LLMClient._call_openai refuses a model whose catalog row is not enabled, and the admin catalog
--    PATCH refuses to re-enable a retired key (S235 code change in the same PR).
-- 5. Guard: if any active stage still has an OpenAI-platform primary or shadow, the migration raises
--    (none expected). That needs a human decision, not a data patch.
--
-- Judge route after: gpt-5.6-luna (Bedrock acc3) -> gpt-6-luna (Bedrock acc3) -> gpt-6-luna-openai
-- (OpenAI API, last resort). All non-Anthropic: the writer/judge vendor separation (ADR 0006 §5,
-- ADR 0008) is unchanged.
--
-- Rollback (re-enables GPT-4.1 — needs a new decision from Nghiệp first):
--   UPDATE shared.llm_model_catalog SET enabled = true, blocked_reason = NULL,
--          updated_at = now(), updated_by = 'rollback-224'
--    WHERE model_key = 'gpt-4.1';
--   (the removed fallback/shadow entries are not restored: none existed on Dev.)

BEGIN;

UPDATE shared.llm_role_config r
   SET fallback_model_ids = ARRAY(
           SELECT f.key
             FROM unnest(r.fallback_model_ids) WITH ORDINALITY AS f(key, ord)
            WHERE f.key <> 'gpt-4.1'
              AND (f.key NOT IN (SELECT model_key FROM shared.llm_model_catalog WHERE provider = 'openai')
                   OR f.ord = cardinality(r.fallback_model_ids))
            ORDER BY f.ord),
       updated_at = now(),
       updated_by = 'migration-224-s235'
 WHERE EXISTS (
           SELECT 1
             FROM unnest(r.fallback_model_ids) WITH ORDINALITY AS f(key, ord)
            WHERE f.key = 'gpt-4.1'
               OR (f.key IN (SELECT model_key FROM shared.llm_model_catalog WHERE provider = 'openai')
                   AND f.ord < cardinality(r.fallback_model_ids)));

UPDATE shared.llm_role_config
   SET shadow_model_id = NULL,
       shadow_sample_pct = 0,
       updated_at = now(),
       updated_by = 'migration-224-s235'
 WHERE shadow_model_id = 'gpt-4.1';

UPDATE shared.llm_model_catalog
   SET enabled = false,
       blocked_reason = 'S235: retired; OpenAI API kept only as last-resort fallback via gpt-6-luna-openai',
       updated_at = now(),
       updated_by = 'migration-224-s235'
 WHERE model_key = 'gpt-4.1';

DO $$
DECLARE
    bad TEXT;
BEGIN
    SELECT string_agg(stage || ' (' || what || '=' || key || ')', ', ' ORDER BY stage) INTO bad
      FROM (SELECT stage, 'model_id' AS what, model_id AS key FROM shared.llm_role_config WHERE is_active
            UNION ALL
            SELECT stage, 'shadow_model_id', shadow_model_id FROM shared.llm_role_config
             WHERE is_active AND shadow_model_id IS NOT NULL) x
     WHERE key = 'gpt-4.1'
        OR key IN (SELECT model_key FROM shared.llm_model_catalog WHERE provider = 'openai');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 224: OpenAI platform API model as primary/shadow: %', bad;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('224', now(), 'S235: OpenAI API only as last-resort fallback (never primary/shadow); '
        'gpt-4.1 removed from routes and disabled in llm_model_catalog')
ON CONFLICT (version) DO NOTHING;

COMMIT;
