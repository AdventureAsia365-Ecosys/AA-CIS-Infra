-- Migration 326: AA-642 (AI gateway v2, plan S263 slice A1, gaps CIS-2 / CIS-4 / OPS-11 stage part) — the stage kill
-- switch and the declared degrade mode of a stage (root ADR 0009 decisions 4 and 5).
--
-- Why. ADR 0009 decision 4: a stage profile = route + parameters + data scopes + budget + kill switch. CIS had no
-- switch: shared.llm_role_config.is_active = false made the CIS gateway ignore the row and run the stage on its
-- hard-coded SAFE_DEFAULTS route (shared/llm_client/role_config.py), while TripPlanner already treated an inactive row
-- as "AI paused" (its fail-closed route read). Decision 5: every production stage class needs a deployment in
-- another failure domain, or a declared degrade mode. The tenant (T-series) and TripPlanner writer stages are aws_only
-- until AA-820, stay on Anthropic models, and acc2 cannot run Claude, so their only way to meet the rule is a declared
-- degrade mode; without a column for it /admin/llm-availability reports t2_generate, t9_write and tp_compose as
-- breaches (root plan docs/audits/2026-11-01-S263-gateway-gap-audit/plan.md, slice A1).
--
-- What.
--   1. Guard: no llm_role_config row is inactive today. From the code PR that reads this file on, is_active = false
--      means "switched off": the gateway refuses every call of the stage before any provider attempt (a 0 USD ledger
--      row, status refused, error_class disabled). A row that is inactive under the old meaning (= run on the
--      built-in route) would silently stop its stage, so the file stops instead and names it.
--   2. shared.llm_role_config.degrade_mode text NULL, CHECK in ('queue_retry', 'basic_narration', 'last_saved_text',
--      'manual_reply_needed') — what the product does when the stage cannot run (tech lead T-21: CIS jobs queue and
--      retry later; TripPlanner shows its basic narration; CRM asks for a manual reply). NULL = none declared.
--      Changed by migration only (a product decision; no cis_app grant).
--   3. shared.llm_role_config.disabled_reason text NULL (<= 500 characters): why an admin switched the stage off,
--      shown in the admin and in the refused ledger row. cis_app gets column UPDATE on it (the admin switch, audited);
--      it already has UPDATE on is_active / updated_at / updated_by.
--   4. Declared degrade modes: t2_generate and t9_write 'queue_retry' (the T2 / T9 job stops and is re-queued once
--      the stage runs again), tp_compose 'basic_narration' (TripPlanner's degrade, TP #198). Guard: exactly these
--      three rows exist and are updated.
--   5. shared.llm_call_log error_class CHECK gains 'disabled' (the class of a call refused by the stage switch).
--      Dropped and re-added NOT VALID, then VALIDATE (SHARE UPDATE EXCLUSIVE: writers keep writing while it scans).
--   6. Comments on is_active and the two new columns. Register 326.
--
-- Behaviour on apply: none for calls (every row stays active; only the admin switch turns a stage off). The availability
-- report starts reading degrade_mode after the code PR: the three stages show "declared degrade", not a breach.
--
-- Class: contract (root ADR 0017 d3: a new constraint, a changed constraint, column ACL and an UPDATE on existing
-- tables; llm_call_log is a hot table), so no "-- migrate: expand" header and MIG-4: (1) this migration-only PR merges
-- to AA-CIS-App main after 325; (2) the byte copy in AA-CIS-Infra db/migrations/cis/ merges (contract copy: merged by
-- hand after its checks); (3) a manual DB Migrate apply (check, then apply) once every job table is idle; (4) the
-- bot/db-schema-reference PR merges; (5) only then the A1 code PR (it writes error_class 'disabled', which the CHECK
-- must allow first). No readiness bump: the code reads degrade_mode / disabled_reason with a fallback for a missing
-- column. DM-7.1: no new table.
--
-- Locks. llm_role_config (~36 rows): ADD COLUMN without default, ADD CONSTRAINT (instant). llm_call_log: DROP / ADD
-- CONSTRAINT NOT VALID take ACCESS EXCLUSIVE for an instant (lock_timeout 5s: the file stops rather than queue behind
-- a long writer); VALIDATE scans the table under SHARE UPDATE EXCLUSIVE (reads and writes go on).
--
-- Rollback (a NEW forward migration, after the code PR is reverted): re-add the error_class CHECK without 'disabled'
-- (after UPDATE ... SET error_class = 'other' WHERE error_class = 'disabled'), REVOKE UPDATE (disabled_reason) FROM
-- cis_app, DROP COLUMN disabled_reason, degrade_mode (a destructive file).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of both tables.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '10min';

-- ── 1. guard ─────────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    inactive text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'shared'
                      AND table_name = 'llm_role_config' AND column_name = 'route_deadline_s') THEN
        RAISE EXCEPTION 'migration 326: shared.llm_role_config.route_deadline_s is missing (apply 320 first)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'shared'
                      AND table_name = 'llm_call_log' AND column_name = 'error_class') THEN
        RAISE EXCEPTION 'migration 326: shared.llm_call_log.error_class is missing (apply 319 first)';
    END IF;
    SELECT string_agg(stage, ', ' ORDER BY stage) INTO inactive
      FROM shared.llm_role_config WHERE NOT is_active;
    IF inactive IS NOT NULL AND NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '326') THEN
        RAISE EXCEPTION 'migration 326: inactive llm_role_config rows: % (is_active = false will mean "switched off": '
                        'set them active or delete them first)', inactive;
    END IF;
END $$;

-- ── 2./3. the two columns ────────────────────────────────────────────────────────────────────────────────────────

ALTER TABLE shared.llm_role_config ADD COLUMN IF NOT EXISTS degrade_mode text;
ALTER TABLE shared.llm_role_config ADD COLUMN IF NOT EXISTS disabled_reason text;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_role_config_degrade_mode_check'
                      AND conrelid = 'shared.llm_role_config'::regclass) THEN
        ALTER TABLE shared.llm_role_config ADD CONSTRAINT llm_role_config_degrade_mode_check CHECK (
            degrade_mode IS NULL
            OR degrade_mode IN ('queue_retry', 'basic_narration', 'last_saved_text', 'manual_reply_needed'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_role_config_disabled_reason_check'
                      AND conrelid = 'shared.llm_role_config'::regclass) THEN
        ALTER TABLE shared.llm_role_config ADD CONSTRAINT llm_role_config_disabled_reason_check CHECK (
            disabled_reason IS NULL OR length(disabled_reason) <= 500);
    END IF;
END $$;

GRANT UPDATE (disabled_reason) ON shared.llm_role_config TO cis_app;

COMMENT ON COLUMN shared.llm_role_config.is_active IS
    'AA-642 A1 (migration 326): the stage kill switch. false = switched off: the CIS gateway refuses every call of the '
    'stage before any provider attempt (0 USD ledger row, status refused, error_class disabled) and TripPlanner '
    'pauses AI for it. Set by the admin (PATCH /admin/llm-config/{stage}/switch, audited).';
COMMENT ON COLUMN shared.llm_role_config.degrade_mode IS
    'AA-642 A1 (migration 326): what the product does when the stage cannot run (ADR 0009 decision 5): queue_retry, '
    'basic_narration, last_saved_text or manual_reply_needed. NULL = none declared. A stage with one meets the '
    'failure-domain rule without a second domain. Changed by migration only.';
COMMENT ON COLUMN shared.llm_role_config.disabled_reason IS
    'AA-642 A1 (migration 326): why an admin switched the stage off (NULL while it is on).';

-- ── 4. declared degrade modes ────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    n int;
BEGIN
    UPDATE shared.llm_role_config SET degrade_mode = 'queue_retry'
     WHERE stage IN ('t2_generate', 't9_write') AND degrade_mode IS DISTINCT FROM 'queue_retry';
    UPDATE shared.llm_role_config SET degrade_mode = 'basic_narration'
     WHERE stage = 'tp_compose' AND degrade_mode IS DISTINCT FROM 'basic_narration';
    SELECT count(*) INTO n FROM shared.llm_role_config
     WHERE (stage IN ('t2_generate', 't9_write') AND degrade_mode = 'queue_retry')
        OR (stage = 'tp_compose' AND degrade_mode = 'basic_narration');
    IF n <> 3 THEN
        RAISE EXCEPTION 'migration 326: expected the t2_generate, t9_write and tp_compose rows, found %', n;
    END IF;
END $$;

-- ── 5. ledger: error_class 'disabled' ────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_call_log_error_class_check'
                      AND conrelid = 'shared.llm_call_log'::regclass
                      AND pg_get_constraintdef(oid) LIKE '%''disabled''%') THEN
        ALTER TABLE shared.llm_call_log DROP CONSTRAINT IF EXISTS llm_call_log_error_class_check;
        ALTER TABLE shared.llm_call_log ADD CONSTRAINT llm_call_log_error_class_check CHECK (
            error_class IS NULL OR error_class IN ('access_denied', 'quota_exhausted', 'throttled', 'credential',
                                                   'other', 'deadline', 'budget', 'truncated', 'disabled')) NOT VALID;
        ALTER TABLE shared.llm_call_log VALIDATE CONSTRAINT llm_call_log_error_class_check;
    END IF;
END $$;

-- ── 6. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('326', now(), 'AA-642 A1: stage kill switch (is_active = switched off) + llm_role_config.degrade_mode / '
                      'disabled_reason; t2_generate, t9_write queue_retry, tp_compose basic_narration; error_class '
                      'disabled')
ON CONFLICT (version) DO NOTHING;

COMMIT;
