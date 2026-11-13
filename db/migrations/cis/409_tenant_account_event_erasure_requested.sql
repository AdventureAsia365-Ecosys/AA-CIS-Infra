-- Migration 409: AA-1093 lane L2 — the tenant.entitlements.v1 feed (1.7) carries account.erasure_requested.
--
-- Why. The partner CRM and AA-Booking learn of a tenant's lifecycle from the tenant.entitlements.v1 feed
-- (GET /tenant/v1/account-events, shared.tenant_account_event, CIS 353). The offboarding erasure saga (CIS 408) adds one
-- event type: account.erasure_requested, written when CIS records an erasure request at the offboard (change: the
-- request id, its status scheduled, the per-app not_before) and when a restore cancels it (status cancelled). Ids and
-- timestamps only, no reason, no actor (the feed's rule). The CHECK of 353 lists the three 1.0 types; the saga's emit
-- would fail without this file.
--
-- What:
--   1. shared.tenant_account_event_type_check re-created with account.erasure_requested added (NOT VALID first, then
--      VALIDATE: the existing rows are re-checked under a SHARE UPDATE EXCLUSIVE lock, a few hundred rows on Dev).
--   2. The exact grants on 408's tables, which an expand file cannot set: REVOKE ALL from PUBLIC, aa_app_user and
--      cis_app, then cis_app SELECT, INSERT, UPDATE again (the Dev default ACL of cis_owner in shared adds DELETE and
--      more on every new table, CIS 245; the saga never deletes its record). EXECUTE on 408's trigger function revoked
--      from PUBLIC (a trigger needs none).
--   3. Register 409.
--
-- Behaviour on apply. None: the tables of 408 are empty and nothing writes the new type until the AA-1093 saga code is
-- deployed. Consumers that do not know the type skip it (contract rule: unknown event types are ignored).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no '-- migrate:' directive): a CHECK of an existing table changes. MIG-4:
-- migration-only PR (with 408 and 410); applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a).
-- DM-7.1: no new table.
--
-- Number. 408 is this wave's first file; if the owner main max + 1 differs at merge, renumber (git grep '409_' and
-- '409' here, in the test and in the code that names the file).
--
-- Locks. One ALTER TABLE ... DROP / ADD CONSTRAINT NOT VALID (ACCESS EXCLUSIVE, catalog only) and one VALIDATE.
-- lock_timeout 5s, statement_timeout 1min. Idempotent (DROP IF EXISTS + ADD), one transaction, self-registering.
--
-- Rollback (a new forward migration, after the saga code is reverted and no account.erasure_requested row is left: the
-- feed is append-only, so the old CHECK cannot come back while such rows exist).

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

ALTER TABLE shared.tenant_account_event DROP CONSTRAINT IF EXISTS tenant_account_event_type_check;
ALTER TABLE shared.tenant_account_event ADD CONSTRAINT tenant_account_event_type_check
    CHECK (type IN ('account.status_changed', 'subscription.changed', 'entitlement.changed',
                    'account.erasure_requested')) NOT VALID;
ALTER TABLE shared.tenant_account_event VALIDATE CONSTRAINT tenant_account_event_type_check;

COMMENT ON TABLE shared.tenant_account_event IS
    'AA-1028 R1 (CIS 353): append-only feed of contract tenant.entitlements.v1 (account.status_changed, '
    'subscription.changed, entitlement.changed; AA-1093 CIS 409, 1.7: account.erasure_requested), written only through '
    'shared.tenant_account_emit(). Kept while the tenant exists (account audit); deleted with an offboarded tenant by '
    'the AA-839 erasure.';

REVOKE ALL ON shared.tenant_erasure_request, shared.tenant_erasure_step FROM PUBLIC, cis_app, aa_app_user;
GRANT SELECT, INSERT, UPDATE ON shared.tenant_erasure_request, shared.tenant_erasure_step TO cis_app;
REVOKE ALL ON FUNCTION shared.tenant_erasure_touch() FROM PUBLIC;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('409', now(), 'AA-1093: tenant.entitlements.v1 1.7 feed event type account.erasure_requested')
ON CONFLICT (version) DO NOTHING;

COMMIT;
