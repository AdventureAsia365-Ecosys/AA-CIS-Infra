-- Migration 260: AA-847 (S246) — the place pipeline's two model stages move from Claude Sonnet 4.6 to
-- Claude Haiku 4.5 (owner's choice, S246: "Haiku or Luna only"; Haiku 5.5 is not callable on acc3 yet —
-- its Marketplace subscription is refused). Sonnet stays as the outage fallback.
--
-- Evidence: S246 place_model_trial (stage adhoc_aa847, 3 Laos tours, Sonnet 4.6 as the reference):
--                    decided overnight  decided anchor  locate within radius (confirmed)  $/tour
--   Haiku 4.5              0.95             0.89                  0.53                     0.011
--   GPT-6 Luna             0.74             0.79                  0.76                     0.001
--   GPT-5.6 Luna           0.74             0.84                  0.76                     0.003
--   (Sonnet 4.6 today: ~$0.016/tour on days alone.)
-- No model passed the runner's 0.95 bar. Haiku is closest on the day skeleton (what the trip map draws);
-- its locate points are coarser (median 21 km off a confirmed point vs Sonnet 5 km), so fewer names will
-- pass the geocoder acceptance window (services/places/geomatch.py) and more stay 'llm' / precision
-- 'area' on the /admin/places review list. The first S247 build measures that rate before the rest.
--
-- Rows (226 seeded them with ON CONFLICT DO NOTHING; the admin PATCH could do this but needs a staff
-- ai.admin session, and a migration is the reproducible record — same as 213 / 222):
--   a3_place_days    sonnet -> haiku, fallback {sonnet}, shadow gpt-5.6-luna @20% cleared
--   a3_place_locate  sonnet -> haiku, fallback {sonnet}
-- The model is not part of days_hash, so tours already built are not redone.
-- No deploy needed: the gateway reads the row per call (20 s cache). SAFE_DEFAULTS mirrors it.
-- Rollback: both rows -> model_id 'sonnet', fallback '{}'; a3_place_days shadow 'gpt-5.6-luna' @ 20.

BEGIN;

UPDATE shared.llm_role_config
   SET model_id = 'haiku', provider = 'claude', account_route = 'acc3',
       fallback_model_ids = ARRAY['sonnet']::text[], shadow_model_id = NULL, shadow_sample_pct = 0,
       updated_at = now(), updated_by = 'migration-260-aa847'
 WHERE stage IN ('a3_place_days', 'a3_place_locate');

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('260', now(), 'AA-847: a3_place_days / a3_place_locate -> haiku (sonnet fallback, no shadow)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
