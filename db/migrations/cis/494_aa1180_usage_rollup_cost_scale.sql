-- Migration 494: AA-1180 (S293) — the hourly usage rollup keeps the ledgers' cost precision.
--
-- Why. GET /admin/usage-explorer/rollup/check compares the rollup's totals with the ledgers' own totals exactly, and
-- answers ok:false on Dev for every window that holds Jev calls: shared.decision_log.cost_usd is numeric(12,8) (the
-- 7-day Jev total was 0.06664078 USD), but shared.ai_usage_hourly.cost_usd (CIS 372) is numeric(18,6), so each hourly
-- row is rounded to 6 decimals and the rolled sum (0.066641) is not the ledger's sum. The rollup is right otherwise;
-- the check stays exact (no tolerance).
--
-- What.
--   1. shared.ai_usage_hourly.cost_usd: numeric(18,6) -> numeric(20,8). Scale 8 is the widest of the source ledgers
--      (shared.llm_call_log numeric(10,6), shared.decision_log numeric(12,8), shared.dfs_call_log numeric(12,6),
--      geo.geocode_call numeric(10,6)); precision 20 keeps the 12 integer digits of numeric(18,6), so no stored value
--      can overflow. cost_usd is the rollup's only cost or amount column (the others are bigint counts). No view,
--      rule or function depends on the column (catalog dump of 25/11), so nothing is dropped or recreated. The
--      NOT NULL and DEFAULT 0 stay. Existing rows keep their 6-decimal values until the re-roll (below).
--   2. The column comment says so.
--   3. Register 494.
--
-- Behaviour. The ALTER rewrites the table (~4.6k rows, 2.4 MB on Dev, well under a second) under an ACCESS EXCLUSIVE
-- lock: the explorer's reads and the ai_usage_rollup job wait for it. No code change is needed for it to apply: the
-- rollup SQL already sums the ledgers' costs as unbounded numeric. After apply, the orchestrator re-rolls the last
-- 8 days with the audited POST /admin/usage-explorer/rollup/run ($0), so the hours already stored at 6 decimals get
-- 8; the 15-minute schedule re-rolls only the last 6 hours. Hours older than that keep 6 decimals until re-rolled
-- (the check's windows that matter are the last 7 days).
--
-- Class: contract (no '-- migrate:' directive): it ALTERs an existing table (root ADR 0017 d3). MIG-4: this
-- migration-only PR ships first (Infra copy, then Infra Migration Apply once every job table is idle, root ADR
-- 0017a); the AA-1180 code PR (8-decimal explorer figures, tests) follows. No readiness raise: the code works on
-- either column type.
--
-- Number. The S293 wave's CIS batch after 492 and 493; owner main max + 1 at merge. If it differs, renumber:
-- git grep '494_' and "'494'" (this file, tests/integration/test_aa1180_migration_494.py,
-- tests/unit/test_aa1180_migration_494_static.py, docs/implementation-notes/AA-1180.md).
--
-- Idempotent: re-running it on a numeric(20,8) column changes nothing (ALTER ... TYPE to the same type is a no-op
-- rewrite-free statement; the comment and the registration are re-set / ON CONFLICT DO NOTHING).
--
-- Rollback (a new forward migration, after the code PR is reverted): ALTER COLUMN cost_usd TYPE numeric(18,6)
-- (rounds every stored cost to 6 decimals; the rollup check is red again on Jev windows).
--
-- DM-6.1: no personal data. DM-7.1: no new table.
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the table's owner.

BEGIN;

SET LOCAL lock_timeout = '5s';

ALTER TABLE shared.ai_usage_hourly ALTER COLUMN cost_usd TYPE numeric(20,8);

COMMENT ON COLUMN shared.ai_usage_hourly.cost_usd IS
    'AA-1180 (494): the summed cost in USD of the hour''s ledger rows, numeric(20,8): scale 8 is the widest of the '
    'source ledgers (shared.decision_log), so the rollup equals the ledgers exactly (GET /admin/usage-explorer/'
    'rollup/check).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('494', now(), 'AA-1180: shared.ai_usage_hourly.cost_usd numeric(18,6) -> numeric(20,8) (the ledgers'' '
                      'widest cost scale, so the rollup check is exact)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
