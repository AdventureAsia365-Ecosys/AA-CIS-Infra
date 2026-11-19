-- migrate: expand
-- Migration tp-035: AA-1139 (the TripPlanner module of the agency app) — the version of each tenant's lead webhook
-- signing key, so an agency owner can rotate the key and see the new one once.
--
-- Why: a webhook lead is signed with a key per tenant derived from the master secret (backend/assembly/leads.py
-- webhook_key: HMAC-SHA256(master, "aa-tripplanner lead webhook v1:" + tenant id)). The key could not be changed: a key
-- that leaked stayed valid until the master secret of the whole environment was replaced. The key of version n >= 1 is
-- HMAC-SHA256(master, "aa-tripplanner lead webhook v1:" + tenant id + ":" + n); a tenant with no row keeps version 0,
-- the key it has today (no tenant's signature changes when this file is applied).
--
-- tripplanner.lead_webhook_key (scope, version, rotated_at, rotated_by), PK scope:
--   scope        'tenant:<tenant uuid>' (the tp-029 / tp-032 spelling: no tenant_id column, so the table is not under
--                the tenant row-level security of tp-028; the code always filters by the bound tenant's scope).
--   version      the key version in force, 1 or more (CHECK); a rotation adds 1.
--   rotated_at   when the version was set.
--   rotated_by   who rotated it: 'crm-member:<uuid>' (the CRM member id the CRM names) or 'studio-member:<uuid>'
--                (the Content studio membership id, for an agency without the CRM add-on: the CRM relays the studio
--                owner's rotation after CIS confirmed the membership); never a name or an e-mail.
-- No secret is stored: the key is derived from the master secret and the version at signing time.
-- No personal data: a version number, a time and a member id. At most one row per tenant.
-- Retention (data standards DM-7.1, root row added before this copy): kept while the tenant's planner exists (the key
-- version must outlive every lead it signs); tenant offboarding leaves the row (no personal data, no secret: the key
-- needs the master secret), and a later erase_tenant contract file deletes it with the tenant's other planner rows
-- (until then it is a reviewed exception of migrations/tests/test_replay_twice_pg.py ERASE_EXCEPTIONS).
--
-- Grants: the runtime role tripplanner gets SELECT, INSERT, UPDATE, the statements the code runs (the tp_owner default
-- privileges of tp-013 grant DML on every new table of the schema anyway, and a REVOKE is not an expand statement).
--
-- Class: expand (root ADR 0017 d3): one new table with its primary key and CHECKs, a comment, a grant to the owner's
-- own runtime role and the registration. Nothing existing changes. Applied before the code PR that reads it (MIG-4);
-- code that runs before it is applied reads version 0 (the table is missing: 42P01), the key every tenant has today.
-- Re-runnable (test_replay_twice_pg.py replays every file twice): IF NOT EXISTS, repeated grant / comment,
-- ON CONFLICT DO NOTHING.
-- Undo: a later tp- file with `-- migrate: destructive` (DROP TABLE tripplanner.lead_webhook_key), after the readers
-- are gone (every tenant then signs with version 0 again).
--
-- Applied through AA-CIS-Infra (byte-identical copy db/migrations/tripplanner/035_lead_webhook_key.sql, Migration
-- Sync) as tp_owner, the live owner of schema tripplanner since tp-013 (XD8). Never run it from a laptop.

BEGIN;

CREATE TABLE IF NOT EXISTS tripplanner.lead_webhook_key (
    scope      TEXT        NOT NULL,
    version    INTEGER     NOT NULL,
    rotated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    rotated_by TEXT        NOT NULL,

    CONSTRAINT lead_webhook_key_pkey PRIMARY KEY (scope),
    CONSTRAINT lead_webhook_key_scope_chk
        CHECK (scope ~ '^tenant:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    CONSTRAINT lead_webhook_key_version_chk CHECK (version >= 1 AND version <= 1000000),
    CONSTRAINT lead_webhook_key_actor_chk
        CHECK (rotated_by ~ '^(crm|studio)-member:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
);

COMMENT ON TABLE tripplanner.lead_webhook_key IS
    'tp-035 (AA-1139): the version of a tenant''s (scope tenant:<uuid>) lead webhook signing key; the key is derived from the master secret and the version at signing time (none stored). No row = version 0. No personal data. Retention: kept while the planner exists; offboarding leaves the row (no personal data, no secret).';

GRANT SELECT, INSERT, UPDATE ON tripplanner.lead_webhook_key TO tripplanner;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-035', now(), 'AA-1139: tripplanner.lead_webhook_key (the rotatable lead webhook signing key version)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
