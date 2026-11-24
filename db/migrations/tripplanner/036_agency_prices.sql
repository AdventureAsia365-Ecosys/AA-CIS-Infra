-- migrate: expand
-- Migration tp-036: AA-1152 (S285 decision B2 option C, Jira PR-29) — an agency's own "from" prices on its planner
-- pages, as its CRM computed them (contract tripplanner.agency_prices.v1, root docs/contracts).
--
-- Why: an agency's TripPlanner pages showed no price at all (root ADR 0019 b5 "no AA price"), so a traveller could not
-- choose. B2 option C: they show "from X per person" in the agency's OWN price (AA's B2B price x the agency's markup,
-- else AA's RRP, rounded up to the agency's step). The CRM owns the agency's pricing and computes every number; no AA
-- app reads crm (root ADR 0008a), so the CRM PUTs the list (PUT /trip/m2m/v1/tenants/{id}/planner/prices) and
-- TripPlanner keeps it here and shows it as given. TripPlanner never sees AA's B2B price, the markup or a supplier.
--
-- tripplanner.agency_prices (scope, show_prices, currency, tours, addons, computed_at, received_at), PK scope:
--   scope        'tenant:<tenant uuid>' (the tp-029 / tp-035 spelling: no tenant_id column, so the table is not under
--                the tenant row-level security of tp-028; the code always filters by the bound tenant's scope).
--   show_prices  the agency's "Show prices on my planner" switch; false = no price on its pages.
--   currency     the agency's currency (ISO 4217).
--   tours        JSON object {tour source_id: "amount"}: the agency's price per traveller of each AA tour it sells.
--   addons       JSON object {"sv:<uuid>": "amount"}: the same for each AA add-on (supply.place_addons.v1).
--   computed_at  when the CRM computed the list (a PUT with an older computed_at changes nothing: 409 stale).
--   received_at  when TripPlanner stored it: a list older than the setting tripplanner.prices.agency_stale_hours
--                (CIS 476) shows no price (the CRM stopped refreshing it).
-- One row per tenant, replaced by each PUT (no history). No personal data, no AA B2B price, no markup.
-- Retention (data standards DM-7.1, root row added before this copy): kept while the tenant's planner exists;
-- offboarding leaves the row (no personal data) until a later erase_tenant contract file deletes it with the tenant's
-- other planner rows (until then a reviewed exception of migrations/tests/test_replay_twice_pg.py ERASE_EXCEPTIONS).
--
-- Grants: the runtime role tripplanner gets SELECT, INSERT, UPDATE, the statements the code runs (the tp_owner default
-- privileges of tp-013 grant DML on every new table of the schema anyway).
--
-- Class: expand (root ADR 0017 d3): one new table with its primary key and CHECKs, a comment, a grant to the owner's
-- own runtime role and the registration. Nothing existing changes. Applied before the code PR that reads it (MIG-4);
-- code that runs before it is applied shows no price (42P01 = no list).
-- Re-runnable (test_replay_twice_pg.py replays every file twice): IF NOT EXISTS, repeated grant / comment,
-- ON CONFLICT DO NOTHING.
-- Undo: a later tp- file with `-- migrate: destructive` (DROP TABLE tripplanner.agency_prices), after the readers are
-- gone (every agency page then shows no price again).
--
-- Applied through AA-CIS-Infra (byte-identical copy db/migrations/tripplanner/036_agency_prices.sql, Migration Sync)
-- as tp_owner, the live owner of schema tripplanner since tp-013 (XD8). Never run it from a laptop.

BEGIN;

CREATE TABLE IF NOT EXISTS tripplanner.agency_prices (
    scope       TEXT        NOT NULL,
    show_prices BOOLEAN     NOT NULL,
    currency    TEXT        NOT NULL,
    tours       JSONB       NOT NULL DEFAULT '{}'::jsonb,
    addons      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    computed_at TIMESTAMPTZ NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT agency_prices_pkey PRIMARY KEY (scope),
    CONSTRAINT agency_prices_scope_chk
        CHECK (scope ~ '^tenant:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    CONSTRAINT agency_prices_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT agency_prices_lists_chk
        CHECK (jsonb_typeof(tours) = 'object' AND jsonb_typeof(addons) = 'object'
               AND octet_length(tours::text) <= 262144 AND octet_length(addons::text) <= 131072)
);

COMMENT ON TABLE tripplanner.agency_prices IS
    'tp-036 (AA-1152, contract tripplanner.agency_prices.v1): an agency''s (scope tenant:<uuid>) own "from" price per traveller of each AA tour and add-on it sells, as its CRM computed them, and its show-prices switch; one row per tenant, replaced on each publish. No personal data, no AA B2B price, no markup. Retention: kept while the planner exists.';

GRANT SELECT, INSERT, UPDATE ON tripplanner.agency_prices TO tripplanner;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-036', now(), 'AA-1152: tripplanner.agency_prices (an agency''s own from prices on its planner, from its CRM)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
