-- Migration 219: AA-763 (G4) — T-series stage keys for the shared S1 graph and T7 Debate.
--
-- T2 (tenant tour rewrite) runs the S1 content graph, and T7 Debate reuses the S1 brand-fit
-- judge, so their model calls routed and logged under A1 keys (s1_judge, s1_brand_audit,
-- s1_flag_fix, s1_itinerary_nudge). T cost, routing and shadow config could not be read or set
-- apart from A1 (S229 T-series audit, §7 G4). The code now asks for a T key
-- (services/content_generation/stages.py); this seeds those keys.
--
-- Each new row is a COPY of its A1 twin's current row — model, role, provider, account route,
-- fallback chain and shadow settings — so no model choice changes (out of scope for AA-763).
-- Admin can retune a T stage on its own afterwards (Settings > LLM Models). SAFE_DEFAULTS in
-- shared/llm_client/role_config.py mirrors the seeded twins for when the DB is unreachable.
--
--   t2_judge           <- s1_judge
--   t2_brand_audit     <- s1_brand_audit
--   t2_flag_fix        <- s1_flag_fix
--   t2_itinerary_nudge <- s1_itinerary_nudge
--   t7_debate_judge    <- s1_judge
--
-- Applied on Dev via the AA-CIS-Infra "DB Migrate" workflow (identical copy in
-- db/migrations/cis/), BEFORE the app change that asks for these keys is deployed.

BEGIN;

INSERT INTO shared.llm_role_config
    (stage, role, provider, model_id, account_route, is_active, fallback_model_ids,
     shadow_model_id, shadow_sample_pct, updated_by)
SELECT t.new_stage, c.role, c.provider, c.model_id, c.account_route, c.is_active,
       c.fallback_model_ids, c.shadow_model_id, c.shadow_sample_pct, 'system-migration-aa763'
FROM (VALUES ('t2_judge', 's1_judge'),
             ('t2_brand_audit', 's1_brand_audit'),
             ('t2_flag_fix', 's1_flag_fix'),
             ('t2_itinerary_nudge', 's1_itinerary_nudge'),
             ('t7_debate_judge', 's1_judge')) AS t(new_stage, twin)
JOIN shared.llm_role_config c ON c.stage = t.twin
ON CONFLICT (stage) DO NOTHING;

DO $$
BEGIN
    IF (SELECT count(*) FROM shared.llm_role_config
        WHERE stage IN ('t2_judge', 't2_brand_audit', 't2_flag_fix', 't2_itinerary_nudge',
                        't7_debate_judge')) <> 5 THEN
        RAISE EXCEPTION 'AA-763: expected 5 T-series stage rows — an A1 twin row is missing';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('219', now(), 'AA-763: T-series stage keys (t2_judge, t2_brand_audit, t2_flag_fix, t2_itinerary_nudge, t7_debate_judge) copied from their A1 twins')
ON CONFLICT (version) DO NOTHING;

COMMIT;
