-- Migration 261: AA-847 (S247) — a3_place_locate goes back to Claude Sonnet (model key 'sonnet', the row it had
-- before migration 260). a3_place_days stays on Claude Haiku 4.5 (260).
--
-- Evidence: the S247 one-country build (Mongolia, both stages on Haiku 4.5) left 84% of the names it placed as
-- located_by 'llm' (the geocoder did not confirm the model's point), against 49% on Laos when locate ran on
-- Sonnet. 260's notes named this as the expected cost of Haiku's coarser points (median 21 km from a confirmed point
-- against Sonnet's 5 km; services/places/geomatch.py accepts a candidate only inside its window) and gave the
-- remedy: move locate alone back to Sonnet. The S246 plan keeps a3_place_days on Haiku: the day skeleton is what
-- the trip map draws, and Haiku matched Sonnet there (decided overnight 0.95).
-- Cost: one locate call per 40 new names; design §8 envelope ≈ 1k tokens in, ≤ 0.8k out ≈ $0.015 per call on
-- Sonnet (about $0.005 per tour), against ≈ $0.005 per call on Haiku.
--
-- Row: a3_place_locate  haiku -> sonnet, fallback {haiku} (an outage still places names, coarser), no shadow.
-- (Before 260 the fallback list was empty; Haiku as fallback is the same outage pattern as 222 / 260.)
-- Only new names are located: a key with a resolved geo.place_name or a located shared.destinations row is reused
-- (store.resolved_names / known_destinations), even after a forced rebuild. So the names the Mongolia build placed
-- as 'llm' stay as they are; this row changes the names of the tours still to build (the coverage gate's list).
-- No deploy needed: the gateway reads the row per call (20 s cache). SAFE_DEFAULTS mirrors it.
-- Rollback: a3_place_locate -> model_id 'haiku', fallback '{sonnet}' (the 260 row); no shadow either way.

BEGIN;

UPDATE shared.llm_role_config
   SET model_id = 'sonnet', provider = 'claude', account_route = 'acc3',
       fallback_model_ids = ARRAY['haiku']::text[], shadow_model_id = NULL, shadow_sample_pct = 0,
       updated_at = now(), updated_by = 'migration-261-aa847'
 WHERE stage = 'a3_place_locate';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('261', now(), 'AA-847: a3_place_locate -> sonnet (haiku fallback, no shadow); a3_place_days stays haiku')
ON CONFLICT (version) DO NOTHING;

COMMIT;
