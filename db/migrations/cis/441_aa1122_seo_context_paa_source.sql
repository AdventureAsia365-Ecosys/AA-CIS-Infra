-- Migration 441: AA-1122 item 5 (S282) — where a tour's People Also Ask questions came from, and when they were filled.
--
-- Why. silver_aa_internal.seo_context.people_also_ask holds the PAA questions S1 and T2 hand the writers, one row per
-- tour. About 258 of 892 published tours have an empty list: their one SERP (bought by the S1 prefetch) had no PAA box.
-- The backfill job (services/seo_intelligence/tour_paa.py, job kind tour_paa_backfill) fills them from the research
-- store first (the PAA segment research already bought for the tour's places, $0) and buys a SERP only for the rest,
-- under a cap. It must never overwrite a bought list, must refresh only what it derived itself, and must not touch
-- fetched_at (fetched_at drives the S1 reuse window S1_SEO_REUSE_DAYS, and an answered-but-empty SERP counts as fresh
-- there: buying it again would answer empty again). Two columns record that provenance.
--
-- What.
--   1. ALTER TABLE silver_aa_internal.seo_context ADD COLUMN paa_source text, ADD COLUMN paa_filled_at timestamptz:
--        paa_source     NULL = written by the S1 prefetch / T2 path as before (a bought SERP or the research store at
--                       S1 time, not tracked); 'store' = filled by the backfill from acp_contract.search_demand; 'serp'
--                       = filled by the backfill from a SERP it bought through the research cache; 'none' = the
--                       backfill looked (store and, when allowed, a SERP) and found no question, so the next backfill
--                       waits for the SERP freshness window before it looks again (no repeat purchase).
--        paa_filled_at  when the backfill last set people_also_ask / paa_source (NULL for rows it never touched).
--      CHECK paa_source IN ('store', 'serp', 'none') or NULL.
--   2. Register 441.
--
-- PII (DM-6.1). None: a provenance code and a time.
--
-- Retention (DM-7.1). The table keeps its rule (grandfathered CIS table, no window change); noted in the root PR.
--
-- Behaviour on apply. None for running code: both columns are NULL on every row and nothing reads them until the code
-- PR. ADD COLUMN with no default is a catalog-only change (no table rewrite). The table is RLS on + FORCE: the existing
-- policies cover the new columns (cis_app ALL, the tenant isolation policy by tenant_id).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): it ALTERs an existing table and adds a CHECK
-- constraint to it. MIG-4: a migration-only PR (with 440 and 442), applied on Dev by Infra Migration Apply when every
-- job table is idle (ADR 0017a), then the code PR.
--
-- Number. Follows 440 (this lane: 440-442). If the owner main max + 1 differs at merge, renumber (git grep '441_' and
-- '441' here, in tests/integration/test_aa1122_migrations_440_442.py and docs/implementation-notes/AA-1122.md).
--
-- Locks. ALTER TABLE takes an ACCESS EXCLUSIVE lock for a catalog-only change (~918 rows); lock_timeout 5s, so a busy
-- table fails the apply instead of queueing readers behind it. Re-runnable (IF NOT EXISTS, the constraint is added only
-- when missing).
--
-- Rollback (a new forward migration, after the code PR is reverted): ALTER TABLE ... DROP COLUMN paa_source, DROP
-- COLUMN paa_filled_at (a destructive file, DRY RUN).

BEGIN;
SET LOCAL lock_timeout = '5s';

ALTER TABLE silver_aa_internal.seo_context
    ADD COLUMN IF NOT EXISTS paa_source text,
    ADD COLUMN IF NOT EXISTS paa_filled_at timestamptz;

DO $add$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'seo_context_paa_source_check'
                      AND conrelid = 'silver_aa_internal.seo_context'::regclass) THEN
        ALTER TABLE silver_aa_internal.seo_context
            ADD CONSTRAINT seo_context_paa_source_check
            CHECK (paa_source IS NULL OR paa_source IN ('store', 'serp', 'none'));
    END IF;
END
$add$;

COMMENT ON COLUMN silver_aa_internal.seo_context.paa_source IS
    'AA-1122 (CIS 441): who filled people_also_ask last: NULL = S1 prefetch / T2 as before; store = the PAA backfill '
    'from acp_contract.search_demand; serp = the backfill from a SERP it bought; none = the backfill found no question '
    '(it looks again after the SERP freshness window).';
COMMENT ON COLUMN silver_aa_internal.seo_context.paa_filled_at IS
    'AA-1122 (CIS 441): when the PAA backfill last set people_also_ask / paa_source. fetched_at is never changed by it.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('441', now(), 'AA-1122: seo_context.paa_source / paa_filled_at (provenance of a tour''s PAA backfill)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
