-- migrate: destructive
-- Migration 296: AA-850 (data standards DM-3.9 step 2) — drop the wave-1 objects quarantined in `retired` by CIS 294.
--
-- What. 294 (applied on Dev 28/10/2026 10:27 UTC) moved 8 dead CIS tables and 2 dead views into schema `retired`
-- with no grant to any app role. This file drops all ten. The schema `retired` stays (empty) for the next waves.
--   retired.atom_decompose_jobs   retired.s1_from_atom_runs   retired.route_pick   retired.marketplace_portfolios
--   retired.tenant_atom_state     retired.acp_runs            retired.tenant_brand_rule_versions
--   retired.tenant_brand_rules_deleted_aa404                  retired.v_batch_stats      retired.v_pipeline_summary
--
-- 14-day wait waived (S255, 28/10/2026). DM-3.9 drops a quarantined object no earlier than 14 days after the
-- quarantine. Nghiệp waived that wait for wave 1 in S255: no service reads or writes these objects (0 code references
-- in CIS, Booking, TripPlanner, Partner and Infra, AA-850 audit), and since 294 no app role can reach them (a forgotten
-- reader would fail with 42501, none has). So this file has no "applied >= 14 days ago" check; it still requires 294
-- to be registered (nothing is dropped from a source schema).
--
-- Rows. Verified after the 294 apply (all ten where = retired): atom_decompose_jobs 0, s1_from_atom_runs 0,
-- route_pick 0, marketplace_portfolios 11 (pre-tenant portfolio drafts, last write 24/08/2026), tenant_atom_state 0,
-- acp_runs 0, tenant_brand_rule_versions 0, tenant_brand_rules_deleted_aa404 6 (AA-404 backup of demo rows of the
-- platform tenant, last write 15/08/2026). The guard refuses a live count that differs from these, except 0: a
-- migration replay into a fresh database (CIS CI, the AA-CIS-Infra nightly drift replay) has empty tables and must
-- apply this file as committed (the same rule as 294). A -1 means "not filled in" and is refused.
--
-- Archive. The header `migrate: destructive` makes DB Migrate take an RDS snapshot before the apply
-- (db-migrate-296-<run>-<attempt>): it holds the 17 rows above and every dropped definition. Record its id and date in
-- AA-Ecosys docs/architecture/dead-table-registry.md and move its `aa:retain-until` tag to apply + 180 days (as for
-- tp-018; the DM-7.3 S3 archive does not exist yet).
--
-- Lock note: dropping retired.route_pick / tenant_atom_state / tenant_brand_rule_versions / s1_from_atom_runs /
-- acp_runs removes their FKs and the RI triggers on the parents (shared.tenants, silver_aa_internal.raw_tours,
-- shared.pipeline_runs), which takes ACCESS EXCLUSIVE on those parents for the length of the DROP. Apply while the
-- job tables are idle (DB Migrate waits for that anyway); lock_timeout 5s, retry on a timeout.
--
-- RESTRICT (the default; nothing cascades): anything that grew a dependency on one of the ten since the quarantine
-- (a view, an inbound FK) stops the drop and rolls the whole file back.
--
-- Rollback: none in SQL. Restore from the pre-apply snapshot (db-migrate-296-<run>-<attempt>).
-- Run by DB Migrate as the owner of the CIS schemas (cis_owner). No REQUIRED_CIS_SCHEMA bump: no code needs it.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    -- rows: exact counts verified after the 294 apply (S255, 28/10/2026). -1 = not filled in (refused).
    w jsonb := '[
      {"name": "atom_decompose_jobs",              "kind": "r", "rows": 0},
      {"name": "s1_from_atom_runs",                "kind": "r", "rows": 0},
      {"name": "route_pick",                       "kind": "r", "rows": 0},
      {"name": "marketplace_portfolios",           "kind": "r", "rows": 11},
      {"name": "tenant_atom_state",                "kind": "r", "rows": 0},
      {"name": "acp_runs",                         "kind": "r", "rows": 0},
      {"name": "tenant_brand_rule_versions",       "kind": "r", "rows": 0},
      {"name": "tenant_brand_rules_deleted_aa404", "kind": "r", "rows": 6},
      {"name": "v_batch_stats",                    "kind": "v", "rows": null},
      {"name": "v_pipeline_summary",               "kind": "v", "rows": null}
    ]';
    e   jsonb;
    o   regclass;
    n   bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '294') THEN
        RAISE EXCEPTION 'migration 296: the quarantine 294 is not registered';
    END IF;
    -- No 14-day check: DM-3.9's wait was waived by Nghiệp for wave 1 (S255, 28/10/2026), see the header.
    FOR e IN SELECT * FROM jsonb_array_elements(w) LOOP
        o := to_regclass(format('retired.%I', e->>'name'));
        CONTINUE WHEN o IS NULL;                                     -- already dropped (re-run)
        IF (SELECT relkind FROM pg_class WHERE oid = o) <> (e->>'kind') THEN
            RAISE EXCEPTION 'migration 296: % is not of kind %', o, e->>'kind';
        END IF;
        IF e->>'kind' = 'r' THEN
            IF (e->>'rows')::bigint < 0 THEN
                RAISE EXCEPTION 'migration 296: % has no verified row count (fill in "rows")', o;
            END IF;
            EXECUTE format('SELECT count(*) FROM %s', o) INTO n;
            -- n = 0 passes too: a fresh database (the CIS CI replay, the AA-CIS-Infra drift replay of DB Schema Dump)
            -- holds none of Dev's rows, and an empty table has nothing to protect. Any other count is refused.
            IF n <> (e->>'rows')::bigint AND n <> 0 THEN
                RAISE EXCEPTION 'migration 296: % has % rows, the verified count is % (someone wrote to it: stop and '
                                're-check)', o, n, e->>'rows';
            END IF;
        END IF;
    END LOOP;
END $$;

DROP VIEW  IF EXISTS retired.v_batch_stats;
DROP VIEW  IF EXISTS retired.v_pipeline_summary;
DROP TABLE IF EXISTS retired.atom_decompose_jobs;
DROP TABLE IF EXISTS retired.s1_from_atom_runs;
DROP TABLE IF EXISTS retired.route_pick;
DROP TABLE IF EXISTS retired.marketplace_portfolios;
DROP TABLE IF EXISTS retired.tenant_atom_state;
DROP TABLE IF EXISTS retired.acp_runs;
DROP TABLE IF EXISTS retired.tenant_brand_rule_versions;
DROP TABLE IF EXISTS retired.tenant_brand_rules_deleted_aa404;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('296', now(),
        'AA-850 wave 1 (DM-3.9 step 2): drop the 8 tables and 2 views quarantined in retired by 294 '
        '(14-day wait waived by Nghiệp, S255)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
