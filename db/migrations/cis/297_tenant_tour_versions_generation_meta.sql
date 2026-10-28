-- Migration 297: AA-920 (WM-25) — gold_aa_internal.tenant_tour_versions.generation_meta: how a T2 version was written.
--
-- Why. A T2 tenant rewrite records the writing-memory release it was written with only in shared.job.result
-- (`writing_release`, AA-919). The job row is runner state (retention may delete it, a re-run overwrites it), so the
-- version row itself cannot say which release and which rules wrote it, and the post-activation check (AA-920 WM-26)
-- reads the stamp through a join on the job. WM-25 puts the stamp on the version: `generation_meta` = {"writing_release":
-- {writer, platform: {release_id, release_no, items_sha256}, tenant: {...}, ignored}, "rule_ids": [...],
-- "writer_prompt_version": sha256[:8] of the kept draft's system prompt}. Ids, numbers and hashes only, never rule text
-- (app ADR 0010 decision 12). With memory off only the prompt version; NULL for tenant edits and on every row written
-- before this file.
--
-- Tenant exposure (hard stop 3 of the writing-memory design). The tenant reads use `SELECT ttv.*`; the AA-920 code PR
-- (merged after this file is applied, migration flow D8) adds `generation_meta` to
-- api/routers/_tenant_projection.TENANT_HIDDEN_VERSION_FIELDS and extends the key regex with
-- `generation_meta|rule_ids|release|memory`, with a key-walk test over every tenant tour-version read. The column is
-- admin-only data; the tenant never sees it. Between this apply and that deploy a tenant read may carry the key with a
-- NULL value only (no deployed code writes it yet), so ship the code PR right after the apply.
--
-- What. One nullable jsonb column, no default, no index (read by version id or by the check's time-window scan, which
-- uses idx_ttv_created), no CHECK (the shape is the app's stamp; insertion.stamp). Additive: no data change, no grant
-- change (cis_app and aa_app_user hold table-level grants, which cover a new column; RLS policies are row filters and
-- are unchanged).
--
-- Order with the code. Apply BEFORE the code deploys: the T2 job's save UPDATE names this column, and without it every
-- T2 save fails (the job retries, then the version is marked failed). Apply through AA-CIS-Infra DB Migrate (byte copy
-- in db/migrations/cis/). It only needs the table (CIS 001 on Dev).
--
-- Number. 297 was reserved for this file in S255 and is applied after 299 (AA-850). DB Migrate applies any version
-- that is not registered (no version-order rule; the role lint covers every cis/ file from 243 on). The readiness check
-- reads max(version), already 299, so the code PR lists 297 in api/core/readiness.OUT_OF_ORDER_CIS (with
-- REQUIRED_CIS_SCHEMA 297): while 297 is not registered /health/ready reports 296 ("schema_behind") and the deploy
-- verify fails.
--
-- Preflight (read-only; expected: table present = 1, column present = 0):
--   SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--            WHERE n.nspname = 'gold_aa_internal' AND c.relname = 'tenant_tour_versions') AS table_present,
--          (SELECT count(*) FROM information_schema.columns
--            WHERE table_schema = 'gold_aa_internal' AND table_name = 'tenant_tour_versions'
--              AND column_name = 'generation_meta') AS present;
--
-- Rollback (a NEW forward migration, after the code that writes the column is reverted):
--   ALTER TABLE gold_aa_internal.tenant_tour_versions DROP COLUMN generation_meta;
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of the table.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('gold_aa_internal.tenant_tour_versions') IS NULL THEN
        RAISE EXCEPTION 'migration 297: gold_aa_internal.tenant_tour_versions is missing (CIS 001)';
    END IF;
END $$;

ALTER TABLE gold_aa_internal.tenant_tour_versions
    ADD COLUMN IF NOT EXISTS generation_meta jsonb;

COMMENT ON COLUMN gold_aa_internal.tenant_tour_versions.generation_meta IS
    'AA-920 WM-25 (CIS 297): how this T2 version was written: {"writing_release": the writing-memory stamp '
    '(release ids, numbers, items_sha256), "rule_ids": [...], "writer_prompt_version"}. Ids and hashes only, never '
    'rule text. NULL for tenant edits and before 297. Admin-only: hidden from every tenant read (_tenant_projection).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('297', now(), 'AA-920 WM-25: tenant_tour_versions.generation_meta (T2 writing-memory stamp, admin-only)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
