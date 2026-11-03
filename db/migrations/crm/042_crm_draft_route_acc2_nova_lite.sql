-- Migration crm-042: AA-1027 F4 on the interim path (tech lead re-scope on AA-1027, S265; root ADR 0009 decision 14
-- amendment "CRM draft on acc2, Dev only") — the CRM draft stage routes to Amazon Nova Lite on acc2 while acc3 refuses
-- every model; the two Claude entries stay in the table, switched off, for the day acc3 answers again.
--
-- Owner: AA-Partner (api/migrations/042_crm_draft_route_acc2_nova_lite.sql). AA-CIS-Infra db/migrations/crm/ holds the
-- byte copy DB Migrate applies (Migration Copy Guard). Key crm-042: crm-041 (AA-1025 H1c) is the highest on main.
--
-- Why: crm-037 seeded crm_draft_reply with Claude Haiku 4.5 then Claude Sonnet 4.5 (us. inference profiles), which the
-- CRM can only reach through acc3 (CRM_LLM_ROLE_ARN). acc3 refuses every model since 29/10 (Error 002) and acc2 cannot
-- run Claude ("not available for channel program accounts", S261 access matrix), so with CRM_LLM_PROVIDER=bedrock on
-- the acc2 task role both entries would answer AccessDenied (two refused rows, a "reply by hand" draft, nothing
-- learned). F4 needs one real draft through the gateway, the guardrail and the ledger: the cheapest acc2 chat model
-- the CIS catalogue prices and probed (CIS migration 324; contract-smoked on acc2 in S263 for CIS 331-333) is
-- Amazon Nova Lite, us.amazon.nova-lite-v1:0, family amazon, 0.077 / 0.308 USD per million input / output tokens
-- (AWS Price List API, us-west-1 on-demand, read 31/10/2026; the CIS shared.llm_model_catalog row 'nova-lite').
-- A draft (system text + one client message, at most 800 output tokens) costs about 0.0003 USD on it.
--
-- What:
--   1. crm.llm_stage_route: the crm_draft_reply entries of family anthropic (positions 0 and 1, crm-037) get
--      is_enabled = false. They are kept (model, family, prices unchanged) so that the acc3 return is one forward file
--      that switches them back on (route Haiku, Sonnet, Nova Lite; max_attempts 2 keeps the first two).
--   2. crm.llm_stage_route: position 2 = us.amazon.nova-lite-v1:0, family amazon, prices 0.0770 / 0.3080 (equal to
--      the CIS catalogue row, so the ledger price matches it), enabled. The profile itself (writer, active,
--      max_attempts 2, deadline 30 s) is unchanged: one enabled entry = one attempt per draft.
--   3. Guard: the enabled route of crm_draft_reply is exactly that one entry (a stage nobody can reach on acc2 would
--      otherwise go on refusing every draft silently).
--   4. Register crm-042.
--   Nothing else changes: the kill switch (is_active), the app profile (crm-041), the per-agency monthly budget and
--   ai_enabled (default off), the ai_assist entitlement and the rate cap all stand. The route only matters once the
--   Infra PR sets CRM_LLM_PROVIDER=bedrock on the CRM task (crm_llm.tf); under the stub provider the stub answers as
--   this entry (model and family of the route, cost 0).
--
-- Class: contract (root ADR 0017 d3): an UPDATE and an INSERT of configuration rows in an existing table, so no
-- migrate directive. MIG-4 order: this migration-only PR, the Infra copy (Migration Sync bot), Infra Migration Apply
-- once every job table is idle (root ADR 0017a), the bot/db-schema-reference PR. No code PR depends on it (no
-- readiness raise: the code reads the route as data and works with either route). No new table, so no DM-7.1 row.
--
-- Order: after crm-041. Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL, no grant change
-- (crm_app keeps SELECT on the route, crm-037). Idempotent (the UPDATE touches only enabled anthropic rows, the INSERT
-- is ON CONFLICT DO NOTHING, the guard re-checks the result).
-- Rollback / acc3 back: a forward crm- file (MIG-14): is_enabled = true on positions 0 and 1 (Nova Lite stays as the
-- third entry, beyond max_attempts) or false on position 2.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ── Guard 0: runs as the owner, after crm-041, on the crm-037 draft profile ──────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-042: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-041') THEN
        RAISE EXCEPTION 'crm-042: crm-041 (AA-1025 H1c app profile) lands first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM crm.llm_stage_profile WHERE stage = 'crm_draft_reply' AND role = 'writer') THEN
        RAISE EXCEPTION 'crm-042: the crm_draft_reply writer profile (crm-037) is missing';
    END IF;
END $$;

-- ── 1. the Claude entries off (kept for the acc3 return) ─────────────────────────────────────────
UPDATE crm.llm_stage_route
   SET is_enabled = false, updated_at = now(), updated_by = 'migration-crm-042'
 WHERE stage = 'crm_draft_reply' AND family = 'anthropic' AND is_enabled;

-- ── 2. Amazon Nova Lite on acc2, priced as the CIS catalogue row 'nova-lite' ─────────────────────
INSERT INTO crm.llm_stage_route
    (stage, position, provider, model, family, price_in_per_mtok, price_out_per_mtok, is_enabled, updated_by)
VALUES ('crm_draft_reply', 2, 'bedrock', 'us.amazon.nova-lite-v1:0', 'amazon', 0.0770, 0.3080, true,
        'migration-crm-042')
ON CONFLICT (stage, position) DO NOTHING;

-- ── 3. guard: exactly one enabled entry, the one above ───────────────────────────────────────────
DO $$
DECLARE
    n  int;
    ok int;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE position = 2 AND provider = 'bedrock'
                                        AND model = 'us.amazon.nova-lite-v1:0' AND family = 'amazon'
                                        AND price_in_per_mtok = 0.0770 AND price_out_per_mtok = 0.3080)
      INTO n, ok
      FROM crm.llm_stage_route
     WHERE stage = 'crm_draft_reply' AND is_enabled;
    IF n <> 1 OR ok <> 1 THEN
        RAISE EXCEPTION 'crm-042: expected one enabled crm_draft_reply entry (Nova Lite at position 2), found % '
                        '(% matching): position 2 already held another model?', n, ok;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-042', now(), 'AA-1027 F4 interim path: crm_draft_reply routes to Amazon Nova Lite on acc2 (us.amazon.nova-lite-v1:0, 0.077 / 0.308 USD per MTok, = CIS catalogue nova-lite); the Claude Haiku / Sonnet entries switched off, kept for the acc3 return')
ON CONFLICT (version) DO NOTHING;

COMMIT;
