-- Migration 492: AA-1142 follow-up (S293) — the external check results say where they were measured from: the CIS
-- worker (new, every cis.ops.external_check_interval_min minutes) or the root repo workflow External checks on GitHub
-- Actions (the S292 producer, kept as a second vantage point).
--
-- Why. The root workflow (cron every 15 minutes, merged 25/11 04:10Z) had 0 scheduled runs by S293, and the other
-- root crons start up to 10 hours late: a GitHub schedule cannot feed a 15-minute check. The code PR adds a monitoring
-- lane job on the CIS worker (job kind ops_external_check, AA-1178 lane, $0, no new AWS service) that runs the same
-- checks from the worker's egress through the public internet and writes them here. Both producers write the same
-- table, so each row needs its source, and the uniqueness key must include it (a worker run and a GitHub run of the
-- same target may share a second).
--
-- What:
--   1. acp_shared.ops_external_check.source text NOT NULL DEFAULT 'github', CHECK in ('github', 'worker'). Every
--      existing row came from the GitHub workflow, so the default labels them right; the S292 code on main inserts
--      without the column and keeps writing 'github'.
--   2. A unique index on (source, target, checked_at). The S292 index (target, checked_at) stays for now: the code on
--      main names it in ON CONFLICT (target, checked_at), so dropping it before the code PR ships would break the
--      sampler's copy. The code PR inserts with a bare ON CONFLICT DO NOTHING (any unique index); a later contract
--      file drops the old index once the code PR is live (follow-up in docs/implementation-notes/AA-1142.md).
--   3. An index on (source, checked_at) for the newest run per source (the page's staleness rule).
--   4. Register 492.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): it ALTERs an existing table and adds a
-- constraint to it. MIG-4: a migration-only PR (with CIS 493), applied on Dev by Infra Migration Apply when the job
-- tables are idle (ADR 0017a), then the code PR, which requires 492 in api/core/readiness.py.
--
-- Behaviour on apply. None for running code: the column has a default and the old unique index stays.
--
-- DM-6.1: no personal data (a source label). DM-7.1: no new table; the table's proposed retention is unchanged.
--
-- Number. CIS 490-491 are taken by the ops assistant lane of the same wave; 492-493 follow in the one CIS batch. If the
-- owner main max + 1 differs at merge, renumber: git grep '492_' and "'492'" (this file,
-- tests/integration/test_aa1142_migration_492_493.py, api/core/readiness.py of the code PR,
-- docs/implementation-notes/AA-1142.md).
--
-- Locks. ADD COLUMN with a constant default is a catalog change; its CHECK scans the table once (about 2,000 rows on
-- Dev) under ACCESS EXCLUSIVE; the two CREATE INDEX are plain (small table; a CONCURRENTLY build cannot run in the
-- file's transaction). lock_timeout 5s. Re-runnable: IF NOT EXISTS everywhere (lesson S281: a contract file runs
-- again on a replay).
--
-- Rollback (a new forward migration, after the code PR is reverted): DROP INDEX the two new indexes, ALTER TABLE ...
-- DROP COLUMN source (destructive: the worker rows lose their label; DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of the table.

BEGIN;

SET LOCAL lock_timeout = '5s';

ALTER TABLE acp_shared.ops_external_check
    ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'github'
        CONSTRAINT ops_external_check_source_chk CHECK (source IN ('github', 'worker'));

CREATE UNIQUE INDEX IF NOT EXISTS ops_external_check_source_target_at_key
    ON acp_shared.ops_external_check (source, target, checked_at);
CREATE INDEX IF NOT EXISTS ops_external_check_source_at_idx
    ON acp_shared.ops_external_check (source, checked_at DESC);

COMMENT ON COLUMN acp_shared.ops_external_check.source IS
    'AA-1142 (CIS 492): where the check ran: worker (the CIS worker''s job ops_external_check, every '
    'cis.ops.external_check_interval_min minutes) or github (the root repo workflow External checks, copied by the '
    'status sampler). The status page draws one strip per target and source.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('492', now(), 'AA-1142: acp_shared.ops_external_check.source (worker or github) in the uniqueness key')
ON CONFLICT (version) DO NOTHING;

COMMIT;
