-- Migration 334: AA-1024 (AI gateway v2, root plan S263 slice A3, gap RW-11 part 1) — one route deadline per stage.
--
-- Why. Root ADR 0009 decision 5: "One deadline per route; the gateway owns retries (SDK retries off, at most six
-- attempts per chain)". Migration 320 added shared.llm_role_config.route_deadline_s and the gateway reads it
-- (AA-1018 part 2: checked before every attempt after the first, RouteDeadlineExceeded, ledger 'deadline' at 0 USD),
-- but every row is NULL, so no route has a deadline: a chain of fallbacks can hold a job for 6 x 300 s. The code PR of
-- the same lane makes the SDKs and botocore retry nothing (the gateway's next deployment / model is the retry) and caps
-- a request at six attempts; this file gives every stage its deadline.
--
-- What. route_deadline_s by role on every row that has none (an admin's or a later migration's value is kept):
--
--   role       seconds   reason
--   writer     1200      longest attempts (long outputs); a timed-out first attempt (300 s read timeout) still
--                        leaves room for the route's fallbacks
--   judge       900      reasoning judges (GPT Luna), up to four hops
--   validate    600      short structured extractions
--   embed       120      an acc2 embedding attempt times out at 30 s, the satellite one at 60 s
--
-- The same values are the code's SAFE_DEFAULTS (shared/llm_client/role_config.py ROUTE_DEADLINE_S), used when the
-- table cannot be read. The first attempt always runs (the deadline only stops a later one), and the OpenAI / Anthropic
-- API adapters take the remaining time as their per-request timeout, never more than the connection's own timeout.
-- No column default: a stage row inserted by a later migration states its deadline itself (335 does).
--
-- Not changed: updated_at / updated_by (the provenance of the route itself, which 331 / 332 / 333 and their rollbacks
-- read, stays), every other column. TripPlanner does not read the column (catalog.v_llm_gateway_config_v1 does not
-- expose it).
--
-- Guards (RAISE rolls the whole file back): before — the column exists (320); after — no row is NULL, and every row
-- this file filled has the value of its role.
--
-- Class: contract (root ADR 0017 d3: an UPDATE of existing routing rows), no expand header. MIG-4: this migration-only
-- PR merges to AA-CIS-App main, the byte copy in AA-CIS-Infra db/migrations/cis/ merges, then DB Migrate check /
-- apply with every job table idle (DM-11.4). No code needs it (the code reads the column with NULL = no deadline).
-- DM-7.1: no new table.
--
-- Rollback (a NEW forward migration): UPDATE shared.llm_role_config SET route_deadline_s = NULL (no deadline again,
-- byte-identical requests), or per stage.
--
-- X1. One BEGIN … COMMIT block, no role switch (DB Migrate runs cis/ files as cis_owner, the owner of the table).
-- Locks: one UPDATE on ~40 rows.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    filled text[];
    bad    text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'shared'
                      AND table_name = 'llm_role_config' AND column_name = 'route_deadline_s') THEN
        RAISE EXCEPTION 'migration 334: shared.llm_role_config.route_deadline_s is missing (apply 320 first)';
    END IF;

    WITH upd AS (
        UPDATE shared.llm_role_config
           SET route_deadline_s = CASE role WHEN 'writer' THEN 1200 WHEN 'judge' THEN 900
                                            WHEN 'validate' THEN 600 WHEN 'embed' THEN 120 END
         WHERE route_deadline_s IS NULL
        RETURNING stage
    )
    SELECT coalesce(array_agg(stage ORDER BY stage), ARRAY[]::text[]) INTO filled FROM upd;

    SELECT string_agg(stage || ' (' || role || ')', ', ' ORDER BY stage) INTO bad
      FROM shared.llm_role_config WHERE route_deadline_s IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 334: stages left without a route deadline: %', bad;
    END IF;
    SELECT string_agg(stage, ', ' ORDER BY stage) INTO bad
      FROM shared.llm_role_config
     WHERE stage = ANY (filled)
       AND route_deadline_s <> CASE role WHEN 'writer' THEN 1200 WHEN 'judge' THEN 900
                                         WHEN 'validate' THEN 600 WHEN 'embed' THEN 120 END;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 334: route deadline not the value of its role: %', bad;
    END IF;
    RAISE NOTICE 'migration 334: route deadline set on % stage(s): %', cardinality(filled), filled;
END $$;

COMMENT ON COLUMN shared.llm_role_config.route_deadline_s IS
    'AA-1018 part 2 / AA-1024 A3 (migration 334): the wall-time budget of the whole route in seconds. The first '
    'attempt always runs; no later attempt (fallback model, deployment, legacy tier) starts once it has passed '
    '(ledger error_class deadline, 0 USD). By role: writer 1200, judge 900, validate 600, embed 120. NULL = none.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('334', now(), 'AA-1024 A3: route_deadline_s on every llm_role_config row (writer 1200, judge 900, '
                      'validate 600, embed 120 s)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
