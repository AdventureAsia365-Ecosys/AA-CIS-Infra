-- Migration 337: AA-1024 (AI gateway v2, root plan S263 open item I6, gap RW-06) — Llama 4 Maverick and Scout are
-- asked for a structured object in the prompt, not with a forced tool choice.
--
-- Why. The S263 live contract smoke got "ValidationException ... This model doesn't support the
-- toolConfig.toolChoice.tool field" from Bedrock for Llama 4 Scout AND Llama 4 Maverick. Migration 333 recorded the
-- fact for Scout only (capabilities.forced_tool_choice = false), so the contract smoke's plan refuses both for a stage
-- that sends a JSON schema (a3_place_dedupe: services/places/dedupe.py VERDICT_SCHEMA), and a3_place_dedupe has no acc2
-- pick of another maker than its check stage's Nova Lite. The code PR of the same lane (client.structured_mode) reads a
-- new catalog capability, structured_output, that says how the gateway asks a model for a structured object on
-- Converse: tool (forced by name, the default), any, auto (AA-803: tool choice auto + an instruction), prompt (no
-- toolConfig: the schema is asked for in the system prompt and the first JSON object of the reply is taken). Whatever
-- the mode, the reply is checked against the schema (one schema retry, then a billed unusable reply that moves the
-- route on). The contract smoke runs a model that refuses a forced tool choice when its row states a non-forced mode.
--
-- What. shared.llm_model_catalog.capabilities of two rows, each key only when the row does not state it already (an
-- admin's or a later migration's value wins):
--
--   model_key        forced_tool_choice   structured_output
--   llama4-maverick  false (new)          prompt
--   llama4-scout     false (333, kept)    prompt
--
-- Why prompt, not any / auto: Bedrock documents the any and tool choices only for some makers (not Meta), so any is
-- likely refused the same way; under auto a Llama model may answer a tool call as plain text in its own syntax, which
-- no parser takes. prompt sends no toolConfig field at all and reads the JSON object, prose around it ignored.
-- Effect on live routes: only the structured (json_schema) requests of the two models change. Maverick is on no route.
-- Scout is on judge / validate routes (331 / 333) whose requests carry no json_schema (text JSON verdicts parsed by
-- their callers), so their requests stay byte-identical. No route changes here: a3_place_dedupe gets its Maverick rung
-- in a later migration, after the contract smoke passes with the model override (the PR's live steps).
--
-- Guards (RAISE rolls the whole file back): before — the capabilities column (320) and both catalog rows exist;
-- after — both rows state forced_tool_choice false and a structured_output mode the code knows (tool / any / auto /
-- prompt), and no other catalog row changed.
--
-- Class: contract (root ADR 0017 d3: an UPDATE of existing catalog rows), no expand header. MIG-4: this migration-only
-- PR merges after 336 (number order), the byte copy in AA-CIS-Infra db/migrations/cis/ merges, then DB Migrate check /
-- apply with every job table idle (DM-11.4). The code PR reads the key with "unstated = today's rule", so the order of
-- code and migration does not matter for behaviour; the smoke passes on Maverick only once both are live.
-- DM-7.1: no new table.
--
-- Rollback (a NEW forward migration):
--   UPDATE shared.llm_model_catalog SET capabilities = capabilities - 'structured_output'
--    WHERE model_key IN ('llama4-maverick', 'llama4-scout');
--   (and capabilities - 'forced_tool_choice' on llama4-maverick)
--
-- X1. One BEGIN … COMMIT block, no role switch (DB Migrate runs cis/ files as cis_owner). Locks: one UPDATE, 2 rows.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    keys    constant text[] := ARRAY['llama4-maverick', 'llama4-scout'];
    actor   constant text   := 'migration-337-aa1024';
    missing text[];
    others_before text;
    others_after  text;
    bad     text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'shared'
                      AND table_name = 'llm_model_catalog' AND column_name = 'capabilities') THEN
        RAISE EXCEPTION 'migration 337: shared.llm_model_catalog.capabilities is missing (apply 320 first)';
    END IF;
    SELECT array_agg(k ORDER BY k) INTO missing
      FROM unnest(keys) AS k WHERE NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog m WHERE m.model_key = k);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 337: catalog rows missing (migration 324): %', missing;
    END IF;

    SELECT md5(coalesce(string_agg(model_key || '=' || capabilities::text, '|' ORDER BY model_key), '')) INTO others_before
      FROM shared.llm_model_catalog WHERE NOT (model_key = ANY (keys));

    UPDATE shared.llm_model_catalog
       SET capabilities = coalesce(capabilities, '{}'::jsonb) || '{"forced_tool_choice": false}'::jsonb,
           updated_at   = now(),
           updated_by   = actor
     WHERE model_key = ANY (keys) AND NOT (coalesce(capabilities, '{}'::jsonb) ? 'forced_tool_choice');

    UPDATE shared.llm_model_catalog
       SET capabilities = coalesce(capabilities, '{}'::jsonb) || '{"structured_output": "prompt"}'::jsonb,
           updated_at   = now(),
           updated_by   = actor
     WHERE model_key = ANY (keys) AND NOT (coalesce(capabilities, '{}'::jsonb) ? 'structured_output');

    SELECT string_agg(model_key || ' ' || capabilities::text, '; ' ORDER BY model_key) INTO bad
      FROM shared.llm_model_catalog
     WHERE model_key = ANY (keys)
       AND (capabilities ->> 'forced_tool_choice' IS DISTINCT FROM 'false'
            OR NOT (capabilities ->> 'structured_output' = ANY (ARRAY['tool', 'any', 'auto', 'prompt'])));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 337: rows without forced_tool_choice false and a known structured_output: %', bad;
    END IF;

    SELECT md5(coalesce(string_agg(model_key || '=' || capabilities::text, '|' ORDER BY model_key), '')) INTO others_after
      FROM shared.llm_model_catalog WHERE NOT (model_key = ANY (keys));
    IF others_after IS DISTINCT FROM others_before THEN
        RAISE EXCEPTION 'migration 337: another catalog row changed its capabilities';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('337', now(), 'AA-1024 I6: llama4-maverick / llama4-scout capabilities forced_tool_choice false, '
                      'structured_output prompt (schema asked in the prompt, no toolConfig)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
