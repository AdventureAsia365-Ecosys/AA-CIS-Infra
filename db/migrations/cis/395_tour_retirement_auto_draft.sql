-- Migration 395: AA-1039 follow-up (tech lead decision S276, 10/11/2026; root ADR 0019 d20 amendment) — the agency's
-- opt-in to move its WordPress pages about a discontinued tour to draft automatically.
--
-- Why. Since CIS 360 the tour retirement fan-out moved every live WordPress page about a retired tour to draft after
-- the notice period (draft_after_notice, default 7 days): Adventure Asia changed an agency's own website without the
-- agency asking. Tech lead decision S276: by default the agency is only told (bell + e-mail, each page listed, with a
-- one-click "Move to draft" in the Content studio), and the automatic draft becomes a per-agency opt-in in Content
-- studio Settings ("Automatically move posts about a discontinued tour to draft after N days", off by default).
--
-- What.
--   1. acp_shared.tour_retirement_policy.auto_draft boolean NOT NULL DEFAULT false: true = the fan-out writes
--      action draft_after_notice (draft_due_at = event + notice_days) on this agency's WordPress pages; false (every
--      existing row, and no row at all) = notice_only, no draft_due_at.
--   2. CHECK tour_retirement_policy_auto_draft_scope_check (tenant_id IS NOT NULL OR NOT auto_draft): the opt-in is
--      the agency's own; the platform row (tenant_id NULL) keeps only the default notice period and can never turn
--      automatic drafts on for every agency.
--   3. Register 395.
--
-- Behaviour on apply. Every existing policy row gets auto_draft false: an agency with a tenant row keeps its notice
-- period, and its next retirement is notice only until it opts in. Open draft_after_notice flags written before this
-- change are left as they are (tech lead decision S276: report their count, do not convert them); the code PR that
-- follows reads the column, and before this file it treats every agency as not opted in (42703 caught: notice only,
-- and the Settings write answers 503).
--
-- Class: contract (root ADR 0017 decision 3; no '-- migrate:' directive line): ALTER TABLE ADD COLUMN and ADD
-- CONSTRAINT on an existing table. MIG-4: this migration-only PR, applied on Dev by Infra Migration Apply when every
-- job table is idle (ADR 0017a), then the code PR that raises readiness to 395. No new table, so no new DM-7.1
-- retention row (the 360 row of acp_shared.tour_retirement_policy covers the column: agency settings, deleted with the
-- tenant by the AA-839 erasure).
--
-- PII (DM-6.1). None: a boolean setting.
--
-- Guards (RAISE rolls the whole file back): before — 360 registered and the table present. After — the column is
-- boolean NOT NULL DEFAULT false, the CHECK refuses a platform row with auto_draft true, and on the first apply no
-- existing row is opted in.
--
-- Number. 394 is the highest on main (10/11), so 395 = main max + 1 (preflight). If another file takes 395 first,
-- renumber to the new main max + 1: the file name, this header, the registration below,
-- tests/integration/test_aa1039_migration_395.py, the code PR (services/tour_lifecycle/fanout.py POLICY_MIGRATION,
-- api/core/readiness.py, tests/unit/test_aa884_health.py, the implementation notes, CONTEXT.md) and the root ADR
-- amendment (git grep '395_' and git grep '395' in all three).
--
-- Locks. ALTER TABLE ADD COLUMN with a constant default (ACCESS EXCLUSIVE on a table of a few rows, metadata only) and
-- ADD CONSTRAINT (a scan of those rows). lock_timeout 5s, statement_timeout 1min. Idempotent (IF NOT EXISTS, the
-- constraint dropped and re-added), one transaction, self-registering.
--
-- Rollback (a new forward migration, after the code that reads the column is reverted): ALTER TABLE
-- acp_shared.tour_retirement_policy DROP CONSTRAINT tour_retirement_policy_auto_draft_scope_check, DROP COLUMN
-- auto_draft; (a destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of schema
-- acp_shared and of the table (360).

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';
SELECT set_config('aa.actor', 'migration:395', true);

-- ── Preconditions ──────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '360') THEN
        RAISE EXCEPTION 'migration 395: apply 360 (acp_shared.tour_retirement_policy) first';
    END IF;
    IF to_regclass('acp_shared.tour_retirement_policy') IS NULL THEN
        RAISE EXCEPTION 'migration 395: acp_shared.tour_retirement_policy is missing';
    END IF;
END $$;

-- ── 1. the opt-in column ───────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE acp_shared.tour_retirement_policy
    ADD COLUMN IF NOT EXISTS auto_draft boolean NOT NULL DEFAULT false;

-- ── 2. only an agency row can opt in ───────────────────────────────────────────────────────────────────────────────
ALTER TABLE acp_shared.tour_retirement_policy DROP CONSTRAINT IF EXISTS tour_retirement_policy_auto_draft_scope_check;
ALTER TABLE acp_shared.tour_retirement_policy ADD CONSTRAINT tour_retirement_policy_auto_draft_scope_check
    CHECK (tenant_id IS NOT NULL OR NOT auto_draft);

COMMENT ON COLUMN acp_shared.tour_retirement_policy.auto_draft IS
    'AA-1039 (CIS 395, tech lead decision S276): the agency opted in to automatic drafts. true = the tour retirement '
    'fan-out writes draft_after_notice on its live WordPress pages (draft at event + notice_days); false (default) = '
    'notice_only: bell + e-mail and a one-click "Move to draft" in the Content studio, the site is never changed. '
    'Agency rows only (tour_retirement_policy_auto_draft_scope_check).';
COMMENT ON TABLE acp_shared.tour_retirement_policy IS
    'AA-1039 R6 (CIS 360, 395; root ADR 0019 d20 b7, amended S276): per agency, the opt-in to move WordPress pages '
    'about a retired tour to draft automatically (auto_draft, off by default) and the days of notice before that '
    'draft. tenant_id NULL = the platform row (default notice period only, never auto_draft); a tenant row overrides '
    'it. No row = notice only, 7 days (code default).';

-- ── Guards ─────────────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    col record;
    refused boolean := false;
BEGIN
    SELECT data_type, is_nullable, column_default INTO col
      FROM information_schema.columns
     WHERE table_schema = 'acp_shared' AND table_name = 'tour_retirement_policy' AND column_name = 'auto_draft';
    IF col IS NULL OR col.data_type <> 'boolean' OR col.is_nullable <> 'NO' OR col.column_default <> 'false' THEN
        RAISE EXCEPTION 'migration 395: auto_draft is not boolean NOT NULL DEFAULT false (%)', col;
    END IF;
    -- first apply only: once 395 is registered, agencies opt in through the Content studio and a re-run keeps them
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '395')
       AND EXISTS (SELECT 1 FROM acp_shared.tour_retirement_policy WHERE auto_draft) THEN
        RAISE EXCEPTION 'migration 395: an existing policy row is opted in to automatic drafts';
    END IF;
    BEGIN
        INSERT INTO acp_shared.tour_retirement_policy (tenant_id, notice_days, updated_by, auto_draft)
        VALUES (NULL, 7, 'migration:395-probe', true);
    EXCEPTION WHEN check_violation THEN
        refused := true;
    WHEN unique_violation THEN
        -- a platform row already exists: probe the CHECK on an UPDATE of it instead (rolled back by the block)
        BEGIN
            UPDATE acp_shared.tour_retirement_policy SET auto_draft = true WHERE tenant_id IS NULL;
        EXCEPTION WHEN check_violation THEN
            refused := true;
        END;
    END;
    IF NOT refused THEN
        RAISE EXCEPTION 'migration 395: the platform row can be opted in to automatic drafts';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('395', now(), 'AA-1039 follow-up (S276): tour_retirement_policy.auto_draft, the agency opt-in to automatic '
                      'drafts of WordPress pages about a retired tour (default off: notice only)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
