-- Migration 222: AA-772 (S234) — place-card draft moves from Claude Sonnet to GPT-5.6 Luna and the
-- fact check from GPT-5.6 Luna to Claude Haiku. Both become `validate` stages (ADR 0008: reference
-- data the judge never scores, any vendor); draft and check stay on different vendors.
--
-- Evidence: S234 A/B, the same 30 places with an existing card, same draft prompt
-- (.tmp-session/s234/pc_ab*.py, stage adhoc_aa772_ab):
--   Sonnet       identity 28/28, facts kept 152/167 (Luna check), 11 marked wrong, $0.27
--   Haiku        identity 24/28, facts kept 128/154, 23 wrong, $0.07  (fails: Takin Zoo -> National Zoo)
--   GPT-5.6 Luna identity 27/27, facts kept 134/146 by a Haiku check (145/146 by Luna), 2 wrong, $0.023
--   GPT-6 Luna   identity 25/26, fewer facts (104), 3 empty replies, $0.011
-- Luna facts are shorter and carry fewer risky numbers; ~12x cheaper than Sonnet per draft.
-- Rollback: a3_place_card -> role 'writer', provider 'claude', model 'sonnet', fallback '{}';
--           a3_place_card_check -> role 'judge', provider 'openai', model 'gpt-5.6-luna',
--           fallback '{gpt-6-luna,gpt-6-luna-openai}'.

BEGIN;

UPDATE shared.llm_role_config
   SET role = 'validate', provider = 'openai', model_id = 'gpt-5.6-luna', account_route = 'acc3',
       fallback_model_ids = ARRAY['sonnet']::text[], updated_at = now(),
       updated_by = 'migration-222-aa772'
 WHERE stage = 'a3_place_card';

UPDATE shared.llm_role_config
   SET role = 'validate', provider = 'claude', model_id = 'haiku', account_route = 'acc3',
       fallback_model_ids = ARRAY['sonnet']::text[], updated_at = now(),
       updated_by = 'migration-222-aa772'
 WHERE stage = 'a3_place_card_check';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('222', now(), 'AA-772: a3_place_card -> validate on gpt-5.6-luna (sonnet fallback); '
        'a3_place_card_check -> validate on haiku (sonnet fallback)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
