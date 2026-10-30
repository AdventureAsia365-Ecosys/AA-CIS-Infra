-- Migration 310: AA-1002 (LLM gateway slice S4) — let the admin edit a connection's credential name, endpoint and limits.
--
-- Why. Slice S4 widens PATCH /admin/llm-connections/{connection_key} (admin only, POLICY ai.admin, one
-- acp_shared.audit_log row per change) from the S2 on/off switch to the fields an operator needs when a provider
-- changes: the secret NAME (CHECKed to aa-llm/<env>/<name>, never a value), the base URL (code allowlist per kind),
-- the per-connection timeout / retries, the limiter (max_concurrency, rpm_limit), the monthly budget and notes. The
-- api runs as cis_app, which migration 306 allowed to UPDATE only (enabled, updated_at, updated_by).
--
-- What.
--   1. GRANT UPDATE (secret_name, base_url, timeout_s, max_retries, max_concurrency, rpm_limit, monthly_budget_usd,
--      notes) ON shared.llm_provider_connection TO cis_app. Not kind, auth_mode, account, role, ExternalId, region,
--      credential_env or data_scope: those change who is called with which identity or which data may leave AWS
--      (data scopes are slice S5) and stay migration-only.
--   2. Register 310.
--
-- Behaviour. None on apply. Until it is applied the PATCH answers 503 "needs migration 310" for these fields; the
-- on/off switch keeps working (306).
--
-- Contract file (no expand header: a GRANT on an existing table): DB Migrate apply by hand, after 309 or before it
-- (independent). Number: 309 is this slice's expand file; 308 is AA-1000's contract file.
--
-- Rollback (a NEW forward migration):
--   REVOKE UPDATE (secret_name, base_url, timeout_s, max_retries, max_concurrency, rpm_limit, monthly_budget_usd,
--                  notes) ON shared.llm_provider_connection FROM cis_app;
--
-- X1. One BEGIN … COMMIT block, no role switch; DB Migrate runs cis/ files as cis_owner, the table's owner.

BEGIN;

SET LOCAL lock_timeout = '5s';

GRANT UPDATE (secret_name, base_url, timeout_s, max_retries, max_concurrency, rpm_limit, monthly_budget_usd, notes)
    ON shared.llm_provider_connection TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('310', now(), 'AA-1002 S4: cis_app may UPDATE the admin-editable columns of shared.llm_provider_connection')
ON CONFLICT (version) DO NOTHING;

COMMIT;
