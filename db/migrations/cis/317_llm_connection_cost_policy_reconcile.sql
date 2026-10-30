-- migrate: expand
-- Migration 317: AA-1002 (LLM gateway slice S10) — the budget policy of each LLM connection and the nightly cost
-- reconciliation against the provider's own usage.
--
-- Why. shared.llm_provider_connection.monthly_budget_usd (304) was stored but never enforced, and nothing compared the
-- gateway's own ledger (shared.llm_call_log) with what a provider says it billed. S10 makes the budget a soft warning
-- and an optional hard stop per connection (shared/cost_guard.py, read on the call path by
-- shared/llm_client/connection_budget.py), and adds job kind llm_cost_reconcile (nightly, $0) that writes one row per
-- connection and UTC day: our logged cost next to the provider's figure (Anthropic Usage & Cost API, OpenAI costs
-- API, the stored AWS Cost Explorer snapshot for Bedrock), or why there is none.
--
-- What. Two new platform tables in shared (no tenant column, no personal data, no secret value):
--   1. shared.llm_connection_cost_policy: one optional row per connection (FK, ON DELETE CASCADE). No row = the
--      defaults the code applies (alert at 80 %, hard stop at 100 % of monthly_budget_usd, no reconcile source).
--      alert_pct 1..100; hard_stop (false = alert only, the call goes on); usage_secret_name = the NAME of a
--      read-only usage / admin key secret (same aa-llm/<env>/<name> CHECK as llm_provider_connection.secret_name,
--      checked again in code before anything is read; NULL = the provider source is "not configured");
--      usage_scope_id = the provider's workspace / project id the connection's key lives in (Anthropic wrkspc_...,
--      OpenAI proj_...; NULL = the whole organisation). The usage endpoint host is a code constant per kind, never
--      a column, so an edited row cannot send the usage key elsewhere.
--   2. shared.llm_cost_reconcile: one row per (connection, UTC day), upserted by the job (a later run of the same day
--      replaces it: Cost Explorer revises the last 24-48 h). source / status are closed lists; logged_usd and
--      logged_calls come from shared.llm_call_log (account = connection_key); provider_usd, diff_usd (logged minus
--      provider) and diff_pct are NULL when the source gave no figure. details holds the source's notes (no secret).
--      Retention: 400 days, pruned by the job itself (root data standards Part B §7 row, same PR series).
--   Grants: cis_app SELECT, INSERT, UPDATE, DELETE on both (the admin PATCH writes the policy; the worker writes and
--   prunes the reconcile rows). cis_owner's default privileges in shared give the same.
--
-- Class: expand (root ADR 0017 d3): only new tables, their indexes, FKs to existing tables (the RI triggers that adds
-- on the referenced table are allowed), grants and comments; no change to any existing object, no DO block. The code
-- reads both tables with a fallback when they are missing (defaults, "schema not ready"), so the readiness
-- requirement is not raised here.
--
-- Number. 312 is the highest on main; 313-315 are claimed by another S260 lane. Renumber at merge if needed (file
-- name, this header, the registration below).
--
-- Rollback (a new forward migration, after the code that reads them is reverted):
--   DROP TABLE shared.llm_cost_reconcile; DROP TABLE shared.llm_connection_cost_policy;
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.llm_connection_cost_policy (
    connection_key     text NOT NULL,
    alert_pct          smallint NOT NULL DEFAULT 80,
    hard_stop          boolean NOT NULL DEFAULT true,
    usage_secret_name  text,
    usage_scope_id     text,
    notes              text,
    created_at         timestamp with time zone NOT NULL DEFAULT now(),
    updated_at         timestamp with time zone NOT NULL DEFAULT now(),
    updated_by         text NOT NULL,
    CONSTRAINT llm_connection_cost_policy_pkey PRIMARY KEY (connection_key),
    CONSTRAINT llm_connection_cost_policy_connection_fkey FOREIGN KEY (connection_key)
        REFERENCES shared.llm_provider_connection (connection_key) ON DELETE CASCADE,
    CONSTRAINT llm_connection_cost_policy_alert_pct_check CHECK (alert_pct BETWEEN 1 AND 100),
    CONSTRAINT llm_connection_cost_policy_usage_secret_check
        CHECK (usage_secret_name IS NULL OR usage_secret_name ~ '^aa-llm/[a-z0-9-]+/[a-z0-9][a-z0-9-]*$'),
    CONSTRAINT llm_connection_cost_policy_scope_check
        CHECK (usage_scope_id IS NULL OR usage_scope_id ~ '^[A-Za-z0-9_-]{1,128}$'),
    CONSTRAINT llm_connection_cost_policy_text_check
        CHECK (coalesce(char_length(notes), 0) <= 2000 AND char_length(updated_by) <= 128)
);

COMMENT ON TABLE shared.llm_connection_cost_policy IS
    'AA-1002 (CIS 317, gateway slice S10): budget policy and reconcile source of one LLM connection. No row = '
    'defaults (alert 80 %, hard stop at monthly_budget_usd, no provider source). Edited by PATCH '
    '/admin/llm-connections/{key} (admin only, audited). Never a secret value: usage_secret_name is a NAME.';
COMMENT ON COLUMN shared.llm_connection_cost_policy.alert_pct IS
    'AA-1002 (317): month-to-date spend at or above this percent of llm_provider_connection.monthly_budget_usd raises '
    'one admin bell (and the ops e-mail) per 24 h.';
COMMENT ON COLUMN shared.llm_connection_cost_policy.hard_stop IS
    'AA-1002 (317): true = at 100 % of the monthly budget the gateway leaves the connection out of every route (the '
    'route''s next deployment / model answers; a request with no other way in stops as a budget stop). false = alert only.';
COMMENT ON COLUMN shared.llm_connection_cost_policy.usage_secret_name IS
    'AA-1002 (317): Secrets Manager NAME (aa-llm/<env>/<name>) of a read-only usage key (Anthropic Admin API key, '
    'OpenAI admin key) for llm_cost_reconcile. NULL = the provider source is not configured.';
COMMENT ON COLUMN shared.llm_connection_cost_policy.usage_scope_id IS
    'AA-1002 (317): the provider workspace / project id to reconcile (Anthropic workspace, OpenAI project); NULL = '
    'the whole organisation.';

GRANT SELECT, INSERT, UPDATE, DELETE ON shared.llm_connection_cost_policy TO cis_app;

CREATE TABLE IF NOT EXISTS shared.llm_cost_reconcile (
    connection_key  text NOT NULL,
    day             date NOT NULL,
    source          text NOT NULL,
    status          text NOT NULL,
    logged_usd      numeric(12,6) NOT NULL DEFAULT 0,
    logged_calls    integer NOT NULL DEFAULT 0,
    provider_usd    numeric(12,6),
    diff_usd        numeric(12,6),
    diff_pct        numeric(9,2),
    details         jsonb NOT NULL DEFAULT '{}'::jsonb,
    job_id          uuid,
    checked_at      timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT llm_cost_reconcile_pkey PRIMARY KEY (connection_key, day),
    CONSTRAINT llm_cost_reconcile_connection_fkey FOREIGN KEY (connection_key)
        REFERENCES shared.llm_provider_connection (connection_key) ON DELETE CASCADE,
    CONSTRAINT llm_cost_reconcile_source_check
        CHECK (source IN ('anthropic_cost_report', 'openai_costs', 'aws_cost_explorer', 'none')),
    CONSTRAINT llm_cost_reconcile_status_check
        CHECK (status IN ('ok', 'mismatch', 'not_configured', 'unsupported', 'no_data', 'error')),
    CONSTRAINT llm_cost_reconcile_figures_check
        CHECK (logged_usd >= 0 AND logged_calls >= 0 AND (provider_usd IS NULL OR provider_usd >= 0)),
    CONSTRAINT llm_cost_reconcile_details_check CHECK (jsonb_typeof(details) = 'object')
);
CREATE INDEX IF NOT EXISTS llm_cost_reconcile_day_idx ON shared.llm_cost_reconcile (day DESC);

COMMENT ON TABLE shared.llm_cost_reconcile IS
    'AA-1002 (CIS 317, gateway slice S10): nightly reconciliation of one LLM connection and UTC day: the cost '
    'shared.llm_call_log logged (account = connection_key) next to the provider''s own figure. Upserted by job kind '
    'llm_cost_reconcile (a later run of the same day replaces the row). Retention: 400 days, pruned by that job.';
COMMENT ON COLUMN shared.llm_cost_reconcile.source IS
    'AA-1002 (317): anthropic_cost_report (Admin API cost report), openai_costs (OpenAI organization costs), '
    'aws_cost_explorer (the stored shared.cost_explorer_snapshot, Bedrock services of the connection''s account), none.';
COMMENT ON COLUMN shared.llm_cost_reconcile.status IS
    'AA-1002 (317): ok / mismatch (|diff| above the tolerance) / not_configured (no usage key) / unsupported (no '
    'source for this kind) / no_data (the source has no figure for the day yet) / error (the source failed).';
COMMENT ON COLUMN shared.llm_cost_reconcile.diff_usd IS
    'AA-1002 (317): logged_usd - provider_usd (positive = our ledger says more than the provider billed).';
COMMENT ON COLUMN shared.llm_cost_reconcile.job_id IS
    'AA-1002 (317): the llm_cost_reconcile job that wrote the row (no FK: job rows expire under their own retention).';

GRANT SELECT, INSERT, UPDATE, DELETE ON shared.llm_cost_reconcile TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('317', now(), 'AA-1002 S10: shared.llm_connection_cost_policy + shared.llm_cost_reconcile (budget per connection, nightly reconcile)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
