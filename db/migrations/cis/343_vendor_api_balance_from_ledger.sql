-- Migration 343: AA-1025 (S263 gateway plan, slice B5) — the direct vendor API connections (kinds anthropic, openai)
-- take their balance from the shared credit ledger (342).
--
-- Why. Migration 322 set balance_source 'none' on every non-Bedrock LLM connection: neither the Anthropic nor the
-- OpenAI API offers a balance read the gateway may call with its key, so the Providers page showed no balance and no
-- alert fired before the credit ran out. With the ledger of 342 (top-ups and balance checks recorded by an admin) the
-- balance is estimated the same way as Jev's: recorded money minus the spend logged in shared.llm_call_log. The
-- registry says where a balance comes from (balance_source is migration-only, D9), so this file is the switch.
--
-- What.
--   1. UPDATE shared.llm_provider_connection SET balance_source = 'topups_minus_spend' for the rows of kind anthropic
--      or openai whose balance_source is NULL or 'none' (today anthropic-direct and openai-direct; a row already set
--      to something else is left alone). updated_by / updated_at say who changed it.
--   2. Register 343.
--
-- Behaviour. The code of AA-1025 B5 (shared/provider_credit.py) estimates the balance of a topups_minus_spend
-- connection from shared.provider_credit_topup and raises the low-credit bell + e-mail below the row's
-- low_balance_usd (admin-editable, NULL = no alert). With no ledger entry the estimate is empty and nothing alerts,
-- so applying this file changes nothing until an admin records a balance. Routing, budgets and the circuit do not
-- read balance_source (the route snapshot of the S262 plan Q0 has no balance_source line).
--
-- Class: contract (root ADR 0017 d3): an UPDATE of configuration rows of an existing table. No readiness raise in this
-- migration-only PR (MIG-4); on Dev, Infra Migration Apply applies it once every job table is idle (ADR 0017a).
-- Order: after 342 (same PR), after 339 to 341 of the parallel lanes (merge order = number order).
--
-- Rollback (a new forward migration): UPDATE ... SET balance_source = 'none' WHERE kind IN ('anthropic', 'openai').
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

UPDATE shared.llm_provider_connection
   SET balance_source = 'topups_minus_spend',
       updated_by = 'migration-343-aa1025',
       updated_at = now()
 WHERE kind IN ('anthropic', 'openai')
   AND (balance_source IS NULL OR balance_source = 'none');

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('343', now(), 'AA-1025 B5: anthropic / openai connections take balance_source topups_minus_spend '
                      '(the credit ledger of 342)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
