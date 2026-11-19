-- Migration crm-078: AA-1138 (tech lead decision of 19/11/2026 after a blind A/B of ten client replies: Claude Haiku
-- 5.5 won 7 of 10 over Amazon Nova Lite) — the CRM draft stage routes to Claude Haiku 5.5 on the acc1 Bedrock
-- connection first, with Amazon Nova Lite on the CRM's own acc2 connection kept as the last fallback.
--
-- Owner: AA-Partner (api/migrations/078_crm_draft_route_haiku_acc1.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy Migration Apply runs (Migration Copy Guard). Key crm-078, right after crm-077; if the numbers move, renumber:
-- file name, this header, Guard 0 and the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS (code PR) and the
-- tests that name it (git grep '078_' and 'crm-078').
--
-- Why. crm-042 moved crm_draft_reply to Nova Lite on acc2 because the CRM could reach Claude nowhere (acc2 refuses
-- Claude, acc3 refuses every model). Since S278 acc1 serves the Bedrock chat models through its invoker role (root ADR
-- 0001a, Note S278), and the platform route order for Claude is the Anthropic API, then acc1, then acc3 (route-control
-- v11). The CRM is Bedrock only (root ADR 0008a §5: no vendor API client, no vendor key) and has no Anthropic API
-- connection, so its Claude hop is acc1 (docs/implementation-notes/AA-1138.md: why not the Anthropic API). The model
-- is Claude Haiku 5.5 (CIS catalogue row 'haiku-5-5', CIS migration 259) through its US inference profile
-- us.anthropic.claude-haiku-5-5, NOT the catalogue's global. profile (review S285): the agency terms say CRM text is
-- processed in US regions only (root DPA Annexes 1-3) and root ADR 0009 decision 10 keeps tenant stages off global.
-- profiles until the terms cover it; the S247 CRM readiness check (root docs/audits/2026-10-22-S247-crm-readiness)
-- found the us. profile ACTIVE, routing to us-east-1, us-east-2, us-west-1 and us-west-2 only. The acc1 invoker role
-- grants that profile (AA-CIS-Infra accounts/acc1-bedrock, AA-1138). Price 0.11 / 0.55 USD per million input / output
-- tokens: the AWS Price List regional (us.) price of "Claude Haiku 5.5 (Amazon Bedrock Edition)" read on 22/10/2026
-- (global is 0.10 / 0.50). It rejects a temperature (CIS 259 supports_temperature = false).
--
-- What:
--   1. crm.llm_stage_route gets two columns, so a route entry says where it runs and what it accepts:
--        connection_key     text, NULL = the CRM process's own Bedrock connection (the ECS task role, acc2, or
--                           CRM_LLM_ROLE_ARN when set: unchanged for every existing row); otherwise the key of a
--                           named Bedrock connection the CRM provider knows (app/llm/providers/bedrock.py), today
--                           'bedrock_acc1' = acc1's invoker role. A key the running code does not know is never
--                           called: that attempt is logged as an error at 0 USD and the route moves on.
--        sends_temperature  boolean NOT NULL DEFAULT true: false for a model that rejects a temperature (the provider
--                           then leaves it out of the request).
--      CHECK llm_stage_route_connection_chk: NULL or a lower-case key of at most 31 characters.
--   2. crm_draft_reply position 0 (the crm-037 Claude Haiku 4.5 entry, switched off by crm-042) becomes Claude Haiku
--      5.5 on 'bedrock_acc1', us. profile at the regional price, sends_temperature false, enabled. Position 1 (Claude
--      Sonnet 4.5, off) and position 2 (Nova Lite on acc2, on) are unchanged. The profile is unchanged: max_attempts
--      2 = Haiku, then Nova Lite; route_deadline_s 30.
--      crm_notes_options and crm_supplier_confirm (crm-069 copies) are closed-list picks checked in code: they keep
--      Nova Lite only (the issue's scope).
--   3. Guard: the enabled route of crm_draft_reply is exactly Haiku 5.5 on bedrock_acc1, then Nova Lite on the
--      process's own connection, and the profile lets both run.
--   4. Register crm-078.
--
-- Behaviour on apply (before the AA-Partner code PR deploys): the running code does not read the two columns, so it
-- plays Haiku 5.5 on its own acc2 connection, where AWS refuses Claude (one refused 0 USD row, then Nova Lite answers
-- as today) and sends a temperature Haiku would reject anyway. The code PR (readiness crm-078) adds the acc1
-- connection, the per-connection CRM cap and the temperature rule.
--
-- Spend. The CRM's own cap on acc1 is the setting crm.ai.connection_monthly_cap_usd (crm-077) entry "acc1" (5 USD a
-- month, tech lead 19/11, taken from the CIS share of acc1): not a seed here (maker-checker setting), and it is the
-- FIRST live step, written and approved before the Infra apply, this file and the code deploy (the running code maps
-- only acc2, so the extra key is inert until then). The code PR also fails closed: under the dev spend rules a route
-- entry on a named connection without its own CRM cap is never called (connection_cap_missing, the draft goes to
-- Nova Lite), so no order of the live steps calls acc1 uncapped.
--
-- Class: contract (root ADR 0017 d3: ALTER of an existing table, a new CHECK on it and an UPDATE of a configuration
-- row), so no migrate directive. MIG-4: this migration-only PR, applied on Dev by Infra Migration Apply once every job
-- table is idle (root ADR 0017a), then the code PR. No new table (no DM-7.1 row), no personal data (route
-- configuration), no crm.erase_subject change, no grant change (crm_app keeps SELECT on the route, crm-037).
--
-- Rollback (a NEW forward migration, MIG-14): UPDATE crm.llm_stage_route SET is_enabled = false WHERE stage =
-- 'crm_draft_reply' AND position = 0 (Nova Lite answers alone again). The two columns stay (NULL / true = today).
--
-- Runs as crm_owner (Migration Apply live-owner switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (ADD
-- COLUMN IF NOT EXISTS, the constraint added only when missing, the UPDATE touches the row only when it differs, the
-- guard re-checks the result).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ── Guard 0: runs as the owner, after crm-077, on the crm-037 draft profile ──────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-078: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-077') THEN
        RAISE EXCEPTION 'crm-078: crm-077 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-078' AND description NOT LIKE 'AA-1138 draft route:%') THEN
        RAISE EXCEPTION 'crm-078: the key crm-078 is already held by another migration (not AA-1138): renumber one';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM crm.llm_stage_profile WHERE stage = 'crm_draft_reply' AND role = 'writer') THEN
        RAISE EXCEPTION 'crm-078: the crm_draft_reply writer profile (crm-037) is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM crm.llm_stage_route WHERE stage = 'crm_draft_reply' AND position = 0) THEN
        RAISE EXCEPTION 'crm-078: the crm_draft_reply route has no position 0 (crm-037 seeds it)';
    END IF;
END $$;

-- ── 1. a route entry names its connection and whether it takes a temperature ─────────────────────
ALTER TABLE crm.llm_stage_route
    ADD COLUMN IF NOT EXISTS connection_key text,
    ADD COLUMN IF NOT EXISTS sends_temperature boolean NOT NULL DEFAULT true;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'crm.llm_stage_route'::regclass AND conname = 'llm_stage_route_connection_chk') THEN
        ALTER TABLE crm.llm_stage_route ADD CONSTRAINT llm_stage_route_connection_chk
            CHECK (connection_key IS NULL OR connection_key ~ '^[a-z][a-z0-9_]{0,30}$');
    END IF;
END $$;

COMMENT ON COLUMN crm.llm_stage_route.connection_key IS 'AA-1138 (crm-078): the Bedrock connection of this entry. NULL = the CRM process''s own (ECS task role, acc2); else a named connection of the CRM provider (bedrock_acc1 = the acc1 invoker role). An unknown key is never called (0 USD error row, next entry).';
COMMENT ON COLUMN crm.llm_stage_route.sends_temperature IS 'AA-1138 (crm-078): false for a model that rejects a temperature (Claude Haiku 5.5); the provider then leaves it out.';

-- ── 2. crm_draft_reply position 0 = Claude Haiku 5.5 on acc1 ──────────────────────────────────────
UPDATE crm.llm_stage_route
   SET provider = 'bedrock',
       model = 'us.anthropic.claude-haiku-5-5',
       family = 'anthropic',
       price_in_per_mtok = 0.1100,
       price_out_per_mtok = 0.5500,
       connection_key = 'bedrock_acc1',
       sends_temperature = false,
       is_enabled = true,
       updated_at = now(),
       updated_by = 'migration-crm-078'
 WHERE stage = 'crm_draft_reply'
   AND position = 0
   AND (model <> 'us.anthropic.claude-haiku-5-5'
        OR family IS DISTINCT FROM 'anthropic'
        OR price_in_per_mtok IS DISTINCT FROM 0.1100
        OR price_out_per_mtok IS DISTINCT FROM 0.5500
        OR connection_key IS DISTINCT FROM 'bedrock_acc1'
        OR sends_temperature
        OR NOT is_enabled);

-- ── 3. guard: Haiku 5.5 on acc1, then Nova Lite on the process's own connection ───────────────────
DO $$
DECLARE
    v_route    text;
    v_attempts int;
BEGIN
    SELECT string_agg(format('%s|%s|%s|%s|%s|%s|%s', position, provider, model, family,
                             coalesce(connection_key, '-'), sends_temperature, price_in_per_mtok),
                      ';' ORDER BY position)
      INTO v_route
      FROM crm.llm_stage_route
     WHERE stage = 'crm_draft_reply' AND is_enabled;
    IF v_route IS DISTINCT FROM
       '0|bedrock|us.anthropic.claude-haiku-5-5|anthropic|bedrock_acc1|f|0.1100;'
       '2|bedrock|us.amazon.nova-lite-v1:0|amazon|-|t|0.0770' THEN
        RAISE EXCEPTION 'crm-078: unexpected enabled crm_draft_reply route: %', v_route;
    END IF;
    SELECT max_attempts INTO v_attempts FROM crm.llm_stage_profile WHERE stage = 'crm_draft_reply';
    IF v_attempts < 2 THEN
        RAISE EXCEPTION 'crm-078: crm_draft_reply max_attempts is %, the Nova Lite fallback would never run', v_attempts;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-078', now(), 'AA-1138 draft route: crm.llm_stage_route.connection_key + sends_temperature; crm_draft_reply = Claude Haiku 5.5 on acc1 (us.anthropic.claude-haiku-5-5, 0.11 / 0.55 USD per MTok, US regions only, no temperature), then Nova Lite on acc2')
ON CONFLICT (version) DO NOTHING;

COMMIT;
