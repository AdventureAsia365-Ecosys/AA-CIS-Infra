-- Migration 282: AA-835 (S251 live run) — supply_content_writer moves from the legacy key 'sonnet' to the catalog key
-- 'sonnet-5-5' (Claude Sonnet 5.5, Bedrock Converse on acc3), with the legacy 'sonnet' kept as its last fallback.
--
-- Why. The first Dev runs of the supply_content_draft job failed twice with "draft unusable: reply is not JSON"
-- (llm_call_log: satellite sonnet-4-6, acc3, ~150 output tokens). 278 seeded the stage with 'sonnet', a LEGACY key
-- (shared/llm_client/catalog.py LEGACY_KEYS): the gateway sends it through the legacy chain to the Anthropic Messages
-- API (invoke_claude), which never received the request's json_schema, so the model answered in free text and the
-- writer's strict json.loads refused it. A catalog key goes through Converse, where the schema is the input of the
-- one tool the model is asked to call and the reply is conformed (_checked_json) before any caller sees it.
-- The same PR also makes the legacy path ask for the schema in the system prompt and check the reply (so the
-- fallback below and any other legacy route keep their schema), and lets the writer accept a ``` fenced reply.
--
-- Model. sonnet-5-5 (catalog row from 259: converse, acc3 + acc1 global profiles, enabled) is the key the A1 writer
-- route s1_generate runs on since S250 (writer v2 decision), so this is the same model the catalogue is written with.
-- It rejects a forced tool choice; the gateway asks it with tool choice `auto` + an instruction and still conforms
-- the result (AA-803). It takes no temperature (supports_temperature = false: the writer's 0.4 is left out).
-- Price: $2 / $10 per MTok against $3 / $15 for the legacy Sonnet 4.6, so the job's budget (bedrock /
-- job:supply_content_draft, $0.10 a run, $1.00 a day, 278) is unchanged; the app raises the call's max_tokens to
-- 2048 for its adaptive thinking (≈ $0.026 a request; worst case per job attempt ≈ $0.09: two Converse requests after
-- a schema retry, then the legacy fallback; the job's pre-call estimate is $0.10, and an unusable reply is not
-- retried).
-- Fallback {sonnet}: the legacy Sonnet 4.6 on the satellites (may degrade to Haiku 4.5 inside the legacy chain when
-- both Sonnet satellites fail; the row then has fallback_used), schema-checked by the gateway from the new app
-- image on; same vendor (writers are Anthropic), and it keeps the stage drafting when the catalog is unreadable
-- (SAFE_DEFAULTS mirrors this row). No shadow.
--
-- Idempotent and respectful of an admin choice: the UPDATE matches only while the row is still 278's seed (model_id
-- 'sonnet', no fallback). A row an admin already changed in Settings is left alone (NOTICE). A re-run is a no-op.
-- Guard: sonnet-5-5 must be in shared.llm_model_catalog, enabled, Converse, with an acc3 profile — otherwise the
-- route would fail every call, so the file refuses (a human decision, not a data patch).
-- Deploy order: the gateway reads the row per call (20 s cache), so 282 alone fixes the live failure (the Sonnet 5.5
-- primary enforces the schema on any image). Deploy the app soon after: the old image still sends max_tokens 1200
-- (a long think can end before the tool call) and its legacy fallback drops the schema. Apply in version order
-- (281 before 282). Apply through AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/).
--
-- Rollback (the 278 row):
--   UPDATE shared.llm_role_config
--      SET model_id = 'sonnet', fallback_model_ids = ARRAY[]::text[], updated_at = now(), updated_by = 'rollback-282'
--    WHERE stage = 'supply_content_writer' AND model_id = 'sonnet-5-5';
--   DELETE FROM shared.schema_versions WHERE version = '282';

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    m record;
BEGIN
    SELECT enabled, api_style, bedrock_profile_ids INTO m FROM shared.llm_model_catalog WHERE model_key = 'sonnet-5-5';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'migration 282: shared.llm_model_catalog has no sonnet-5-5 row (migration 259)';
    END IF;
    IF NOT m.enabled OR m.api_style <> 'converse' OR NOT (m.bedrock_profile_ids ? 'acc3') THEN
        RAISE EXCEPTION 'migration 282: sonnet-5-5 is not routable (enabled %, api_style %, profiles %)',
            m.enabled, m.api_style, m.bedrock_profile_ids;
    END IF;
END $$;

UPDATE shared.llm_role_config
   SET model_id = 'sonnet-5-5', provider = 'claude', fallback_model_ids = ARRAY['sonnet']::text[],
       updated_at = now(), updated_by = 'migration-282-aa835'
 WHERE stage = 'supply_content_writer'
   AND model_id = 'sonnet'
   AND cardinality(fallback_model_ids) = 0;

DO $$
DECLARE
    r record;
BEGIN
    SELECT model_id, fallback_model_ids INTO r FROM shared.llm_role_config WHERE stage = 'supply_content_writer';
    IF NOT FOUND THEN
        RAISE NOTICE 'migration 282: no supply_content_writer row (278 not applied?): SAFE_DEFAULTS serve the stage';
    ELSIF r.model_id <> 'sonnet-5-5' THEN
        RAISE NOTICE 'migration 282: supply_content_writer left as set in admin Settings: model %, fallbacks %',
            r.model_id, r.fallback_model_ids;
    ELSE
        RAISE NOTICE 'migration 282: supply_content_writer -> sonnet-5-5, fallbacks %', r.fallback_model_ids;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('282', now(), 'AA-835 (S251): supply_content_writer -> sonnet-5-5 (Converse, schema enforced), '
                      'legacy sonnet as last fallback')
ON CONFLICT (version) DO NOTHING;

COMMIT;
