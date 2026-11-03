-- migrate: expand
-- Migration 352: AA-1024 D2 (S263 gateway plan, OPS-04) — model lifecycle as data: the lifecycle status and the
-- end-of-life date of every catalog model, filled by a nightly job.
--
-- Why. A Bedrock model that AWS moves to LEGACY and then to end of life stops answering on its EOL date; nothing in
-- the registry knew the date, so the first sign would have been failed jobs on the routed stage. The plan's slice D2:
-- a nightly sync fills lifecycle_status and eol_date, and the OPS-12 digest (plus an admin bell) warns 90 days before
-- a routed model's EOL. Done-when: every routed model has a non-NULL lifecycle status after one run.
--
-- What. ALTER TABLE shared.llm_model_catalog ADD COLUMN (all nullable, no default, no constraint):
--   lifecycle_status      active | legacy | unlisted | unknown | untracked (code vocabulary, services/jobs/
--                         llm_model_lifecycle_job.py; no CHECK, so this file stays expand):
--                           active / legacy  Bedrock ListFoundationModels modelLifecycle.status, the worst over the
--                                            model's Bedrock deployments whose account answered;
--                           unlisted         an account answered but does not list the model id (past its end of
--                                            life, or a wrong wire id);
--                           unknown          a Bedrock model none of whose accounts answered and that had no status
--                                            before (an answered status is kept when the account later refuses);
--                           untracked        a provider without a lifecycle source (OpenAI, Anthropic API, Jev, mock).
--   eol_date              modelLifecycle.endOfLifeTime (UTC date), the earliest over the answering accounts;
--   legacy_date           modelLifecycle.legacyTime (UTC date), same rule;
--   lifecycle_checked_at  when the sync last wrote the row;
--   lifecycle_detail      jsonb, per Bedrock connection: access (ok | refused | error | disabled | unconfigured),
--                         error_class, wire_id, the matched model id and its status / dates.
--   Comments on the five columns. Register 352.
--
-- Behaviour. None on apply: every row keeps NULL until the job llm_model_lifecycle_sync runs (nightly from 04:00
-- UTC, switch LLM_MODEL_LIFECYCLE_SYNC, default on; or POST /admin/job-runner/llm-model-lifecycle/run). The code
-- reads the columns with a fallback for a missing column (no readiness raise). cis_app has table-level UPDATE on
-- shared.llm_model_catalog (the job writes only these five columns). The column grant of catalog_owner and the
-- contract views (323, 341) name their columns: unchanged.
--
-- Class: expand (root ADR 0017 d3): new nullable columns without a default on a pre-existing table that is not hot
-- (Infra db/owners.yaml expand_hot_tables), comments on them, the registry row. No constraint, no DO block, no grant.
-- Locks: ADD COLUMN without a default is a catalog-only change under a short ACCESS EXCLUSIVE lock (~60 rows).
--
-- Number. 346 is the highest on main (03/11); 347 (lane l1), 348 / 349 (lane l2) and 350 / 351 (lane l3) are held by
-- parallel lanes of S265.
--
-- Rollback (a new forward migration, after the code is reverted): ALTER TABLE shared.llm_model_catalog DROP COLUMN
-- lifecycle_detail, DROP COLUMN lifecycle_checked_at, DROP COLUMN legacy_date, DROP COLUMN eol_date, DROP COLUMN
-- lifecycle_status; (a destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of the table.

BEGIN;

SET LOCAL lock_timeout = '5s';

ALTER TABLE shared.llm_model_catalog
    ADD COLUMN IF NOT EXISTS lifecycle_status     text,
    ADD COLUMN IF NOT EXISTS eol_date             date,
    ADD COLUMN IF NOT EXISTS legacy_date          date,
    ADD COLUMN IF NOT EXISTS lifecycle_checked_at timestamptz,
    ADD COLUMN IF NOT EXISTS lifecycle_detail     jsonb;

COMMENT ON COLUMN shared.llm_model_catalog.lifecycle_status IS
    'AA-1024 D2 (CIS 352): active | legacy | unlisted | unknown | untracked, written by the nightly job '
    'llm_model_lifecycle_sync (Bedrock ListFoundationModels per Bedrock connection). NULL = never synced.';
COMMENT ON COLUMN shared.llm_model_catalog.eol_date IS
    'AA-1024 D2 (352): Bedrock modelLifecycle.endOfLifeTime (UTC date), the earliest over the answering accounts.';
COMMENT ON COLUMN shared.llm_model_catalog.legacy_date IS
    'AA-1024 D2 (352): Bedrock modelLifecycle.legacyTime (UTC date), the earliest over the answering accounts.';
COMMENT ON COLUMN shared.llm_model_catalog.lifecycle_checked_at IS
    'AA-1024 D2 (352): when llm_model_lifecycle_sync last wrote the lifecycle columns of the row.';
COMMENT ON COLUMN shared.llm_model_catalog.lifecycle_detail IS
    'AA-1024 D2 (352): per Bedrock connection: access, error_class, wire_id, matched model id, status and dates.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('352', now(), 'AA-1024 D2: llm_model_catalog lifecycle_status / eol_date / legacy_date / '
                      'lifecycle_checked_at / lifecycle_detail (model lifecycle as data)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
