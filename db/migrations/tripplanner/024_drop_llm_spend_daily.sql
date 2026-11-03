-- Migration tp-024: AA-1027 E5 (AI gateway v2, gap TP-1) — drop tripplanner.llm_spend_daily, the tp-010 counter.
-- migrate: destructive
--
-- NEEDS APPROVAL AFTER THE DRY RUN (skill aa-cis-schema references/destructive-ops.md): apply only after the tech lead
-- has seen the DRY RUN (AA-CIS-Infra db/scripts/aa1027_tp_spend_daily_dry_run.py: rows, last write, counters,
-- dependents, the ledger totals of the same days) and said go.
--
-- Owner: AA-TripPlanner-Web (key tp-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/tripplanner/024_drop_llm_spend_daily.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as tp_owner (the live owner of schema tripplanner since tp-013, XD8). The `destructive` header makes DB
-- Migrate take a manual RDS snapshot first and refuse to apply without it (MIG-12).
--
-- Why. tp-010 (AA-805) created the counter for the TP_DAILY_SPEND_CAP_USD hard stop: the gateway added each priced
-- customer-facing call to it and read today's sum. Since CIS 323 (AA-642 S8, root ADR 0009 decision 13) the spend is
-- read from the ledger through catalog.v_llm_app_spend_today_v1 and the counter was only the fallback while that view
-- was missing, plus a second write. AA-1027 E5 removed both from the gateway (AA-TripPlanner-Web "gateway reads the CIS
-- views only (fail closed)"): nothing reads or writes the table any more (guard backend/tests/test_extraction_ops.py
-- fails on any SQL string naming it), and no other app reads it (CIS cannot: no grant; the AA-CIS-Infra evidence
-- script aa805_ai_guards_read.py of the closed AA-805 already reads tables tp-018 dropped and is not run any more).
-- Billing truth is shared.llm_call_log, so the rows are derived data.
--
-- What.
--   1. Guards (RAISE, nothing changes):
--      * running as tp_owner;
--      * no object depends on the table (a view, a rule, a foreign key from another table): listed;
--      * no row was written in the last hour (updated_at): a recent write means a TripPlanner build that still writes
--        the counter is live on a Lambda; deploy the E5 build first.
--   2. DROP TABLE IF EXISTS tripplanner.llm_spend_daily (RESTRICT, the default: its primary key index goes with it;
--      it has no foreign key).
--   3. Register tp-024.
--
-- Undo: none in SQL (the rows are gone). Restore from the RDS snapshot DB Migrate takes before the apply (restore to a
-- new instance, then pg_dump/pg_restore the table as tp_owner); the same sums can be recomputed from shared.llm_call_log
-- (app = 'tripplanner', the online stages, by UTC day). Only needed if a build that reads the counter is redeployed.
--
-- Exception to the written retirement rules (needs the tech lead's written approval in the PR and the session log, as
-- tp-018 did): data standards DM-3.8 / DM-3.9 ask for 14 days of pg_stat_user_tables, a quarantine step (ALTER ... SET
-- SCHEMA retired) and an S3 archive of rows with real data. This drop skips them on Dev because the rows are derived
-- from the ledger (recomputable), the writer and reader are gone (the DRY RUN shows the last write and the counters),
-- and the archive is the DB Migrate pre-apply RDS snapshot (DM-7.3 S3 archive not built yet).
--
-- Locks: ACCESS EXCLUSIVE on tripplanner.llm_spend_daily only (no foreign key, so no other table is locked). A pre-E5
-- build that still writes the counter would wait behind it up to lock_timeout (5s by DB Migrate default); the hour
-- guard keeps the apply away from such a build.
-- Re-runnable (test_replay_twice_pg.py): the guards read the table only when it exists, DROP ... IF EXISTS,
-- ON CONFLICT DO NOTHING. tp-010 recreates the table if re-run after this file (SUPERSEDED_BY_DROP in that test).

BEGIN;

DO $$
DECLARE
    rel      constant text := 'tripplanner.llm_spend_daily';
    deps     text;
    last_at  timestamptz;
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-024: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
    IF to_regclass(rel) IS NULL THEN
        RETURN;                                                     -- already dropped
    END IF;

    -- objects that depend on the table (views, rules, foreign keys from other tables)
    SELECT string_agg(DISTINCT dep, ', ' ORDER BY dep) INTO deps
      FROM (
        SELECT v.oid::regclass::text AS dep
          FROM pg_depend d
          JOIN pg_rewrite r ON r.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
          JOIN pg_class v ON v.oid = r.ev_class
         WHERE d.refobjid = to_regclass(rel) AND v.oid <> to_regclass(rel)
        UNION
        SELECT c.conrelid::regclass::text || ' (FK ' || c.conname || ')'
          FROM pg_constraint c
         WHERE c.contype = 'f' AND c.confrelid = to_regclass(rel) AND c.conrelid <> to_regclass(rel)
      ) x;
    IF deps IS NOT NULL THEN
        RAISE EXCEPTION 'tp-024: objects depend on %: %', rel, deps;
    END IF;

    -- no write in the last hour (the counter's writer is gone since AA-1027 E5)
    EXECUTE 'SELECT max(updated_at) FROM tripplanner.llm_spend_daily' INTO last_at;
    IF last_at > now() - interval '1 hour' THEN
        RAISE EXCEPTION 'tp-024: % has a row written at % (less than an hour ago): a build that writes it is still live',
            rel, last_at;
    END IF;
END $$;

DROP TABLE IF EXISTS tripplanner.llm_spend_daily;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-024', now(), 'AA-1027 E5: drop tripplanner.llm_spend_daily (the tp-010 spend counter; the ledger view is the only spend source)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
