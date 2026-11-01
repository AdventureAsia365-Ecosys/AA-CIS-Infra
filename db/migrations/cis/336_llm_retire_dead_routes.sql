-- Migration 336: AA-1024 (AI gateway v2, root plan S263 slice D8, gap CIS-10) — retire three stage routes nothing
-- calls any more: s1_atom_writer, tp_extract, tp_component_embed.
--
-- Why. A route nobody calls still counts in the failure-domain report, the route page and the AI Use Register, and
-- would answer again the day a stray caller came back. The three are dead:
--   s1_atom_writer      the atom-based S1 writer; no call site in CIS (only its SAFE_DEFAULTS entry and admin label);
--   tp_extract          TripPlanner's offline component extraction; the place pipeline moved into CIS jobs (AA-712,
--                       migration 226: a3_place_days took over), no caller in TripPlanner since (its CONTEXT.md);
--   tp_component_embed  the same pipeline's component embeddings (a3_place_embed took over).
-- t10_claims is NOT touched (live validate stage; migration 332 gave it its acc2 fallback).
--
-- What. Each of the three rows is switched off with the stage kill switch of migration 326 (is_active = false: the
-- CIS gateway refuses any call before a provider attempt, 0 USD ledger row 'disabled'; TripPlanner treats an inactive
-- row as "AI paused") and disabled_reason says why. Nothing is deleted: the rows, their routes and every ledger row
-- stay (history), and the admin switch (PATCH /admin/llm-config/{stage}/switch, audited) turns one back on.
--
-- Guards (RAISE rolls the whole file back):
--   before: 326 registered (is_active = false means "switched off" only since then).
--   traffic: no shared.llm_call_log row of the three stages in the last 30 days (any status: a refused attempt is a
--           caller too). Uses idx_llm_call_log_stage_created. A database with no row at all (CI, a local replay)
--           passes.
--   after: the three rows that exist are inactive with a reason; every other row keeps its is_active.
-- A missing row is reported with a NOTICE (nothing to retire), never an error.
--
-- Class: contract (root ADR 0017 d3: an UPDATE of existing routing rows), no expand header. MIG-4: this migration-only
-- PR merges after 335, the byte copy in AA-CIS-Infra db/migrations/cis/ merges, then DB Migrate check / apply with the
-- job tables idle. Before the apply, the live check (read only) in the PR's live steps confirms 0 rows in 30 days.
-- No code needs it. DM-7.1: no new table. Follow-ups outside this file: the root route page / AI Use Register drop
-- the three (they read the live rows), and TripPlanner's Route table (backend/shared/llm_gateway.py) drops its two.
--
-- Rollback (a NEW forward migration, or the admin switch per stage):
--   UPDATE shared.llm_role_config SET is_active = true, disabled_reason = NULL
--    WHERE stage IN ('s1_atom_writer', 'tp_extract', 'tp_component_embed');
--
-- X1. One BEGIN … COMMIT block, no role switch (DB Migrate runs cis/ files as cis_owner). Locks: one UPDATE.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';

DO $$
DECLARE
    dead    constant text[] := ARRAY['s1_atom_writer', 'tp_extract', 'tp_component_embed'];
    reason  constant text   := 'Retired (D8, AI gateway plan S263): no caller and no ledger traffic in 30 days. '
                               'Kept for history; switch it on again only for a new caller.';
    others_before jsonb;
    others_after  jsonb;
    traffic text;
    missing text[];
    bad     text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '326') THEN
        RAISE EXCEPTION 'migration 336: apply 326 first (is_active = false must mean "switched off")';
    END IF;

    SELECT string_agg(stage || ': ' || n || ' row(s), last ' || last_at, '; ' ORDER BY stage) INTO traffic
      FROM (SELECT stage, count(*) AS n, max(created_at) AS last_at
              FROM shared.llm_call_log
             WHERE stage = ANY (dead) AND created_at > now() - interval '30 days'
             GROUP BY stage) t;
    IF traffic IS NOT NULL THEN
        RAISE EXCEPTION 'migration 336: a stage to retire still has ledger traffic in the last 30 days (%): find '
                        'the caller first', traffic;
    END IF;

    SELECT array_agg(s ORDER BY s) INTO missing
      FROM unnest(dead) AS s WHERE NOT EXISTS (SELECT 1 FROM shared.llm_role_config r WHERE r.stage = s);
    IF missing IS NOT NULL THEN
        RAISE NOTICE 'migration 336: no row to retire for %', missing;
    END IF;

    SELECT coalesce(jsonb_object_agg(stage, is_active), '{}'::jsonb) INTO others_before
      FROM shared.llm_role_config WHERE NOT (stage = ANY (dead));

    UPDATE shared.llm_role_config
       SET is_active = false, disabled_reason = reason, updated_at = now(), updated_by = 'migration-336-aa1024'
     WHERE stage = ANY (dead) AND is_active;

    SELECT string_agg(stage, ', ' ORDER BY stage) INTO bad
      FROM shared.llm_role_config WHERE stage = ANY (dead) AND (is_active OR disabled_reason IS NULL);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 336: still active or without a reason: %', bad;
    END IF;
    SELECT coalesce(jsonb_object_agg(stage, is_active), '{}'::jsonb) INTO others_after
      FROM shared.llm_role_config WHERE NOT (stage = ANY (dead));
    IF others_after IS DISTINCT FROM others_before THEN
        RAISE EXCEPTION 'migration 336: another stage changed its switch';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('336', now(), 'AA-1024 D8: retire s1_atom_writer, tp_extract, tp_component_embed (switched off with a reason, '
                      'history kept)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
