-- Migration 338: AA-1024 (AI gateway v2, root plan S263 slice A5, gap RW-09) — the ledger class of a model the gateway
-- did not call because no connection may serve the stage's role.
--
-- Why. Slice A5 (the code PR of this lane) makes the route planner leave out a deployment whose connection's
-- served_roles (migration 322) do not include the stage's role (acc2 serves embed / judge / validate, never a writer:
-- root ADR 0009 decision 14). Review S263: when that filter empties a model's plan, the gateway must refuse the model
-- with that reason, not fail with a generic "no usable deployment" (error_class other) or, on the legacy alias path,
-- "Bedrock tiers down". The code raises a typed refusal (errors.RouteRoleNotServed) and writes its 0 USD ledger row as
-- status 'refused', error_class 'role_not_served'; a route whose every model ended that way fails the job at once
-- (LLMAccessDenied with that class: a retry cannot help until an admin changes the route or the connection).
--
-- What. shared.llm_call_log error_class CHECK gains 'role_not_served' (the list of migration 326 plus that value).
-- Nothing else changes; no row is written or updated.
--
-- Class: contract (root ADR 0017 d3: a constraint change on an existing table is not in the expand list), no expand
-- header. MIG-4: this migration-only PR (334-338) merges first, the byte copy in AA-CIS-Infra db/migrations/cis/ merges,
-- then DB Migrate check / apply with the job tables idle (DM-11.4), then the bot/db-schema-reference PR, then the code
-- PR. Without this file the code still works: a v2 ledger row the CHECK refuses falls back to the plain statement
-- (shared/llm_client/call_log.py), so the row is kept without its v2 columns. DM-7.1: no new table.
--
-- Locks. DROP / ADD CONSTRAINT ... NOT VALID take a short ACCESS EXCLUSIVE lock on shared.llm_call_log (lock_timeout
-- 5 s, so a busy table fails the file instead of queueing writers); VALIDATE CONSTRAINT then scans under SHARE UPDATE
-- EXCLUSIVE, which does not block inserts (the pattern of 319 / 326).
--
-- Rollback (a NEW forward migration, after the code PR is reverted):
--   UPDATE shared.llm_call_log SET error_class = 'other' WHERE error_class = 'role_not_served';
--   then re-add the CHECK with the list of migration 326.
--
-- X1. One BEGIN … COMMIT block, no role switch (DB Migrate runs cis/ files as cis_owner, the table's owner).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'shared'
                      AND table_name = 'llm_call_log' AND column_name = 'error_class') THEN
        RAISE EXCEPTION 'migration 338: shared.llm_call_log.error_class is missing (apply 319 first)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_call_log_error_class_check'
                      AND conrelid = 'shared.llm_call_log'::regclass
                      AND pg_get_constraintdef(oid) LIKE '%''disabled''%') THEN
        RAISE EXCEPTION 'migration 338: the error_class CHECK has no ''disabled'' (apply 326 first)';
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_call_log_error_class_check'
                      AND conrelid = 'shared.llm_call_log'::regclass
                      AND pg_get_constraintdef(oid) LIKE '%''role_not_served''%') THEN
        ALTER TABLE shared.llm_call_log DROP CONSTRAINT IF EXISTS llm_call_log_error_class_check;
        ALTER TABLE shared.llm_call_log ADD CONSTRAINT llm_call_log_error_class_check CHECK (
            error_class IS NULL OR error_class IN ('access_denied', 'quota_exhausted', 'throttled', 'credential',
                                                   'other', 'deadline', 'budget', 'truncated', 'disabled',
                                                   'role_not_served')) NOT VALID;
        ALTER TABLE shared.llm_call_log VALIDATE CONSTRAINT llm_call_log_error_class_check;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_call_log_error_class_check'
                      AND conrelid = 'shared.llm_call_log'::regclass AND convalidated
                      AND pg_get_constraintdef(oid) LIKE '%''role_not_served''%'
                      AND pg_get_constraintdef(oid) LIKE '%''disabled''%') THEN
        RAISE EXCEPTION 'migration 338: the error_class CHECK does not allow role_not_served';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('338', now(), 'AA-1024 A5: llm_call_log error_class role_not_served (a model refused because no connection '
                      'serves the stage role)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
