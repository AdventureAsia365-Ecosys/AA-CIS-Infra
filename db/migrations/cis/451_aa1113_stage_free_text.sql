-- Migration 451: AA-1113 (root ADR 0009 decision 10, accepted S283) — shared.llm_role_config.free_text: the registry
-- of the stages whose prompts carry tenant or traveller free text, scrubbed by the gateway before any model call.
-- break-glass: decided policy change (ADR 0009 d10, accepted by the tech lead in S283): marks the free-text stages for the PII scrub; no model, route, order or parameter of any stage changes
--
-- Why. The gateway's free-text PII scrub (shared/llm_client/free_text_scrub.py, CIS #1559) chose its stages by a
-- name rule in code (every tenant stage "t<n>_...") plus an empty code deny-list. Decision 10 says the data class of a
-- stage is data ("a scope change happens only by migration"), and a stage that carries free text but is not named
-- "t<n>_" (a CRM or Booking stage routed through the shared gateway) could not be marked at all. This column is that
-- registry: the gateway scrubs a stage whose row says free_text (and every "t<n>_" stage, as a fail-safe floor that a
-- row cannot lower), and refuses the call when the scrub cannot run. catalog.v_llm_gateway_config_v1 publishes the
-- mark (CIS 452, same PR).
-- Not covered by this file (review S284): TripPlanner's planning chat (tp_plan_chat) carries traveller free text but
-- has no row (it borrows tp_compose, left false here) and runs in TripPlanner's own gateway, which does not read the
-- mark yet. A follow-up seeds its row with free_text = true together with the TripPlanner change that refuses an
-- unscrubbed call on a marked stage; until then its call-site scrub is TripPlanner's own.
--
-- What.
--   1. ADD COLUMN free_text boolean NOT NULL DEFAULT false (PostgreSQL 11+: a constant default, no table rewrite).
--   2. CHECK llm_role_config_free_text_pii_check: NOT (free_text AND pii_class = 'pii'). A pii stage needs the personal
--      data it is sent (CIS 373: US AWS deployments only, unscrubbed); free_text means the opposite rule.
--   3. UPDATE: every existing tenant stage (stage ~ '^t[0-9]+_', not pii) gets free_text = true, so the registry and the
--      code floor agree on Dev from the first read (S283 measure: tenant rows on the writers and on every repair, FAQ
--      and judge stage that re-reads their seed, facts and brand rules; root
--      docs/audits/2026-11-17-S283-session/aa1113-provider-stage-30d.psv). Catalogue stages (s1_*, a3_*, tp_compose)
--      stay false (tenants = 0 in the measure).
--   4. Migration-only, like pii_class: cis_app gets no INSERT / UPDATE grant on the column (the admin GET
--      /admin/llm-config shows it read-only; cis_app already has table-wide SELECT).
--   5. Register 451.
--
-- Guards (RAISE rolls the whole file back): before, shared.llm_role_config has pii_class (373). After, no tenant stage
-- that is not pii is left with free_text = false, and the CHECK holds (added VALID).
--
-- Behaviour on apply. None for running code: the gateway on main scrubs every "t<n>_" stage by name and does not read
-- the column; after the code PR it reads it with a fallback when the column is missing (role_config: no column =
-- false, the name floor still applies), so code and file may ship in either order.
--
-- Class: contract (root ADR 0017 decision 3): ALTER TABLE ADD COLUMN, ADD CONSTRAINT and UPDATE on an existing table.
-- No migrate directive line: Infra Migration Apply applies it once every job table is idle (root ADR 0017a). MIG-4:
-- this migration-only PR (with 452), the byte copy in AA-CIS-Infra db/migrations/cis/, the apply, then the code PR.
-- DM-7.1: no new table.
--
-- Number. 447 is the highest on main (18/11, AA-1126); 448-450 are held by other S284 lanes' open migration PRs.
-- Renumber to main max + 1 if needed (git grep '451_' and 'CIS 451' / 'migration 451'; 452 and 453 move with it).
--
-- Rollback (a NEW forward migration, after the code is reverted; the code treats a missing column as false):
--   ALTER TABLE shared.llm_role_config DROP CONSTRAINT llm_role_config_free_text_pii_check;
--   ALTER TABLE shared.llm_role_config DROP COLUMN free_text;          (a destructive file, DRY RUN)
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.
-- Locks: ADD COLUMN / ADD CONSTRAINT take an AccessExclusiveLock on a ~40-row table for milliseconds; lock_timeout 5s.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

DO $$
BEGIN
    IF to_regclass('shared.llm_role_config') IS NULL THEN
        RAISE EXCEPTION 'migration 451: shared.llm_role_config (137) is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'shared' AND table_name = 'llm_role_config'
                      AND column_name = 'pii_class') THEN
        RAISE EXCEPTION 'migration 451: shared.llm_role_config.pii_class (373) is missing';
    END IF;
END $$;

ALTER TABLE shared.llm_role_config ADD COLUMN IF NOT EXISTS free_text boolean NOT NULL DEFAULT false;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'llm_role_config_free_text_pii_check'
                      AND conrelid = 'shared.llm_role_config'::regclass) THEN
        ALTER TABLE shared.llm_role_config ADD CONSTRAINT llm_role_config_free_text_pii_check
            CHECK (NOT (free_text AND pii_class = 'pii'));
    END IF;
END $$;

UPDATE shared.llm_role_config
   SET free_text = true
 WHERE stage ~ '^t[0-9]+_'
   AND pii_class <> 'pii'
   AND NOT free_text;

COMMENT ON COLUMN shared.llm_role_config.free_text IS
    'AA-1113 (CIS 451, root ADR 0009 d10): the stage''s prompts carry tenant or traveller free text. The gateway '
    'scrubs them (e-mails, phones, cards, ids, links, credentials) before any model call and refuses the call when '
    'the scrub cannot run; every t<n>_ stage is scrubbed whatever this says (fail-safe floor). Never true on a pii '
    'stage (CHECK llm_role_config_free_text_pii_check). Migration-only.';
COMMENT ON CONSTRAINT llm_role_config_free_text_pii_check ON shared.llm_role_config IS
    'AA-1113 (CIS 451): a pii stage needs its data unscrubbed (CIS 373), so it is never a free_text stage.';

DO $$
DECLARE
    n_free integer;
    n_missed integer;
BEGIN
    SELECT count(*) FILTER (WHERE free_text),
           count(*) FILTER (WHERE stage ~ '^t[0-9]+_' AND pii_class <> 'pii' AND NOT free_text)
      INTO n_free, n_missed
      FROM shared.llm_role_config;
    IF n_missed > 0 THEN
        RAISE EXCEPTION 'migration 451: % tenant stage(s) left without free_text', n_missed;
    END IF;
    RAISE NOTICE 'migration 451: stages marked free_text: %', n_free;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('451', now(), 'AA-1113: shared.llm_role_config.free_text (the gateway scrubs these stages before any model '
                      'call, fail closed; every tenant stage marked; never on a pii stage)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
