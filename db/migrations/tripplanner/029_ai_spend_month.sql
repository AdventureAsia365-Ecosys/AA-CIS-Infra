-- migrate: expand
-- Migration tp-029: AA-1041 slice 2 — the monthly spend sums of the planning chat (stage tp_plan_chat), for its money
-- caps per UTC month: the whole app and each tenant (tech lead, S277: 2 USD a month on Dev).
--
-- Why: the CIS contract views give TripPlanner today's spend per stage (catalog.v_llm_app_spend_today_v1) and a tenant's
-- whole month across apps (catalog.v_tenant_ai_budget_v1), not a month per stage, and the tripplanner role may only
-- INSERT into shared.llm_call_log. The assembly Lambda (backend/shared/monthly_spend.py) adds each chat turn's billed
-- cost here and refuses a turn once a month's sum reaches its cap. The ledger stays the record of every call.
--
-- tripplanner.ai_spend_month (stage, scope, month, cost_usd, calls, updated_at), PK (stage, scope, month):
--   stage     the gateway stage (tp_plan_chat today).
--   scope     'app' (every tenant) or 'tenant:<tenant uuid>' (a tenant id is not personal data; the app sum is read
--             across tenants on purpose, so the table is not under the tenant row-level security of tp-028).
--   month     first day of the UTC month (CHECK).
--   cost_usd  billed USD of the month (numeric(14,6), the ledger's precision), calls = billed attempts.
-- No personal data: no traveller, session, IP or text. At most a few rows per tenant and month.
-- Retention (data standards DM-7.1, root row added before this copy): kept as the chat's cost history; a window is set
-- before prod with the other spend records.
--
-- Grants: the runtime role tripplanner gets SELECT, INSERT, UPDATE, the statements the code runs (stated here; the
-- tp_owner default privileges of tp-013 grant DML on every new table of the schema anyway, and a REVOKE is not an
-- expand statement, so they stay as the schema's rule).
--
-- Class: expand (root ADR 0017 d3): one new table with its primary key and CHECKs, a comment, a grant to the owner's
-- own runtime role and the registration. Nothing existing changes. The code PR that reads it carries this file
-- (expand: one PR); code that runs before it is applied fails closed (the chat answers "paused", the rest of the
-- planner is untouched).
-- Re-runnable (test_replay_twice_pg.py replays every file twice): IF NOT EXISTS, repeated grant / comment,
-- ON CONFLICT DO NOTHING.
-- Undo: a later tp- file with `-- migrate: destructive` (DROP TABLE tripplanner.ai_spend_month), after the readers
-- are gone.
--
-- Applied through AA-CIS-Infra (byte-identical copy db/migrations/tripplanner/029_ai_spend_month.sql, Migration Sync)
-- as tp_owner, the live owner of schema tripplanner since tp-013 (XD8). Never run it from a laptop.

BEGIN;

CREATE TABLE IF NOT EXISTS tripplanner.ai_spend_month (
    stage      TEXT          NOT NULL,
    scope      TEXT          NOT NULL,
    month      DATE          NOT NULL,
    cost_usd   NUMERIC(14,6) NOT NULL DEFAULT 0,
    calls      INT           NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT ai_spend_month_pkey PRIMARY KEY (stage, scope, month),
    CONSTRAINT ai_spend_month_stage_chk CHECK (stage ~ '^[a-z0-9][a-z0-9_]{0,62}$'),
    CONSTRAINT ai_spend_month_scope_chk
        CHECK (scope = 'app' OR scope ~ '^tenant:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    CONSTRAINT ai_spend_month_month_chk CHECK (month = date_trunc('month', month)::date),
    CONSTRAINT ai_spend_month_amounts_chk CHECK (cost_usd >= 0 AND calls >= 0)
);

COMMENT ON TABLE tripplanner.ai_spend_month IS
    'tp-029 (AA-1041): billed USD and calls per AI stage, scope (app or tenant:<uuid>) and UTC month, for the monthly caps of the planning chat (tp_plan_chat). No personal data. Retention: kept as cost history; a window is set before prod.';

GRANT SELECT, INSERT, UPDATE ON tripplanner.ai_spend_month TO tripplanner;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-029', now(), 'AA-1041: tripplanner.ai_spend_month (monthly caps of the planning chat)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
