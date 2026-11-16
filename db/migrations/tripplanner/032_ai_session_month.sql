-- migrate: expand
-- Migration tp-032: AA-1116 (option B pricing, S282 decision 10) — the TripPlanner AI sessions of each tenant per UTC
-- month, for the plan quota tp.ai_sessions (CIS 438: catalog.v_tenant_tripplanner_v1.ai_sessions_monthly, NULL = no
-- limit; Hosted 300, Pro 1,500 a month in option B).
--
-- Why: an AI session is a planner session (tripplanner.sessions) that makes at least one AI call in a UTC month,
-- counted once per month. Before a session's first AI call of the month the assembly Lambda
-- (backend/shared/tenant_sessions.py) admits it: a session already counted this month continues; a new one is counted
-- here while the tenant's count is under its quota, else its AI is stopped (narration and the planning chat degrade).
--
-- tripplanner.ai_session_month (scope, month, session_id, first_ai_at), PK (scope, month, session_id):
--   scope        'tenant:<tenant uuid>' (the tp-029 spelling: no tenant_id column, so the table is not under the
--                tenant row-level security of tp-028; the code always filters by the bound tenant's scope).
--   month        first day of the UTC month (CHECK).
--   session_id   the planner session (a random v4 uuid, an identifier, never a credential; no FK, the rows are
--                usage counts, not session children).
--   first_ai_at  when the session was admitted (its first AI call of the month).
-- No personal data: no traveller, IP, account or text. At most a quota's worth of rows per tenant and month.
-- Retention (data standards DM-7.1, root row added before this copy): kept as the usage history behind the quota; a
-- window is set before prod with the other usage records. Tenant offboarding deletes a tenant's rows: tp-033 adds the
-- table to tripplanner.erase_tenant (tenant.erasure.v1, action delete).
--
-- Grants: the runtime role tripplanner gets SELECT, INSERT, the statements the code runs (stated here; the tp_owner
-- default privileges of tp-013 grant DML on every new table of the schema anyway, and a REVOKE is not an expand
-- statement, so they stay as the schema's rule).
--
-- Class: expand (root ADR 0017 d3): one new table with its primary key and CHECKs, a comment, a grant to the owner's
-- own runtime role and the registration. Nothing existing changes. It ships in the AA-1116 migration-only PR with
-- tp-033 (contract, the erase function), applied before the code PR that reads it (MIG-4); code that would run before
-- it is applied fails closed for NEW AI sessions of a tenant with a quota (no AI narration / chat for them; the rest of
-- the planner is untouched; the bare path and the demo tenant are exempt).
-- Re-runnable (test_replay_twice_pg.py replays every file twice): IF NOT EXISTS, repeated grant / comment,
-- ON CONFLICT DO NOTHING.
-- Undo: a later tp- file with `-- migrate: destructive` (DROP TABLE tripplanner.ai_session_month), after the readers
-- are gone.
--
-- Applied through AA-CIS-Infra (byte-identical copy db/migrations/tripplanner/032_ai_session_month.sql, Migration
-- Sync) as tp_owner, the live owner of schema tripplanner since tp-013 (XD8). Never run it from a laptop.

BEGIN;

CREATE TABLE IF NOT EXISTS tripplanner.ai_session_month (
    scope       TEXT        NOT NULL,
    month       DATE        NOT NULL,
    session_id  UUID        NOT NULL,
    first_ai_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ai_session_month_pkey PRIMARY KEY (scope, month, session_id),
    CONSTRAINT ai_session_month_scope_chk
        CHECK (scope ~ '^tenant:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    CONSTRAINT ai_session_month_month_chk CHECK (month = date_trunc('month', month)::date)
);

COMMENT ON TABLE tripplanner.ai_session_month IS
    'tp-032 (AA-1116): the planner sessions of a tenant (scope tenant:<uuid>) that made an AI call in a UTC month, one row per session and month, for the plan quota tp.ai_sessions (CIS 438 ai_sessions_monthly). No personal data. Retention: kept as usage history (a window is set before prod); a tenant''s rows are deleted at offboarding (tp-033, erase_tenant).';

GRANT SELECT, INSERT ON tripplanner.ai_session_month TO tripplanner;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-032', now(), 'AA-1116: tripplanner.ai_session_month (the monthly AI sessions quota)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
