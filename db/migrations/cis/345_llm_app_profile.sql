-- Migration 345: AA-1025 (S263 gateway plan, slice H1a) — the app profile: one row per app with its AI switch,
-- bulk pause, default daily AI budget and degrade mode (root ADR 0009 decision 4).
--
-- Why. ADR 0009 decision 4: "An app profile holds the app-wide switches: AI on/off, bulk paused, default budgets, and
-- the degrade mode the app shows when AI is unavailable." Until now the only switches were per stage
-- (llm_role_config.is_active, 326) and per connection; switching every AI call of one app off took one PATCH per stage,
-- and the degrade mode was a column of each stage row. The tech lead set the degrade mode of each app in S263 (T-21):
-- CIS queue_retry, TripPlanner basic_narration, CRM manual_reply_needed, AA-Booking none (no AI today).
--
-- What.
--   1. shared.llm_app_profile, PK app (cis | tripplanner | crm | booking, CHECKed: an app is added by migration):
--        ai_enabled                false = every AI call of the app is refused before any provider attempt (CIS: the
--                                  gateway, shared/llm_client/app_profile.py; TripPlanner and the CRM read it in their
--                                  own slices H1b / H1c);
--        bulk_paused               the app's bulk work (waves, bulk re-queues) waits; stored and shown here, enforced
--                                  by the capacity slice H2;
--        default_daily_budget_usd  the app's default daily AI budget (NULL = none set). For CIS the central LLM cap
--                                  llm/app:cis (shared.spend_budget, 340) is the enforced one; the apps without the CIS
--                                  gateway take their app-wide daily cap from here (H1b / H1c);
--        degrade_mode              what the app shows when AI is unavailable (the values of llm_role_config's
--                                  degrade_mode_check, 326, plus 'none' for an app with no AI);
--        disabled_reason           why AI was switched off (required by the admin when switching off, <= 500 chars);
--        updated_at, updated_by.
--   2. One row per app (AI on, not paused, no budget, the T-21 degrade mode); ON CONFLICT DO NOTHING.
--   3. Grants: REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner first, then cis_app SELECT and UPDATE
--      on the editable columns only (no INSERT / DELETE, the key app not editable: the four rows are fixed). On Dev
--      DB Migrate creates the table as cis_owner, whose default privileges in shared (CIS 245) give cis_app
--      SELECT, INSERT, UPDATE, DELETE on every new table; without the REVOKE the runtime role could DELETE the 'cis'
--      row, and a missing row means AI on (the gateway fails open). Same pattern as 321.
--   4. Register 345.
--
-- Behaviour. None on apply: every app has AI on, nothing is paused. Before this file is applied the gateway reads no
-- profile (the code catches the missing table: AI on) and the admin routes answer 503.
--
-- Class: contract (root ADR 0017 d3): the content is a new table, its constraints, seed rows, grants and comments, but
-- narrowing the default-privilege grants needs REVOKE, which the expand lint refuses. Applied with 346 (contract) by
-- Infra Migration Apply once every job table is idle (root ADR 0017a). Retention row (DM-7.1): root data standards
-- Part B section 7, in the root PR of this change.
--
-- Number. 344 is the highest on main (02/11). 346 (geo.geocode_call ledger columns, slice D3, contract) follows in the
-- same migration-only PR (batch cis 345-346, MIG-4: no readiness raise).
--
-- Rollback (a new forward migration, after the code is reverted): DROP TABLE shared.llm_app_profile; (a destructive
-- file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.llm_app_profile (
    app                       text          NOT NULL,
    ai_enabled                boolean       NOT NULL DEFAULT true,
    bulk_paused               boolean       NOT NULL DEFAULT false,
    default_daily_budget_usd  numeric(12,4),
    degrade_mode              text          NOT NULL,
    disabled_reason           text,
    updated_at                timestamptz   NOT NULL DEFAULT now(),
    updated_by                text          NOT NULL DEFAULT 'migration:345',
    CONSTRAINT llm_app_profile_pkey PRIMARY KEY (app),
    CONSTRAINT llm_app_profile_app_check CHECK (app IN ('cis', 'tripplanner', 'crm', 'booking')),
    CONSTRAINT llm_app_profile_degrade_mode_check CHECK (degrade_mode IN
        ('queue_retry', 'basic_narration', 'last_saved_text', 'manual_reply_needed', 'none')),
    CONSTRAINT llm_app_profile_budget_check CHECK (
        default_daily_budget_usd IS NULL OR (default_daily_budget_usd >= 0 AND default_daily_budget_usd <= 100000)),
    CONSTRAINT llm_app_profile_reason_check CHECK (disabled_reason IS NULL OR length(disabled_reason) <= 500),
    CONSTRAINT llm_app_profile_updated_by_check CHECK (length(updated_by) <= 128)
);

COMMENT ON TABLE shared.llm_app_profile IS
    'AA-1025 H1a (CIS 345, root ADR 0009 decision 4): the app profile, one row per app: AI on / off, bulk paused, '
    'default daily AI budget, degrade mode. Read by the CIS gateway (shared/llm_client/app_profile.py: AI off = every '
    'CIS AI call refused with a 0 USD ledger row, error_class disabled); edited on AI providers › Providers › App '
    'profiles (PATCH /admin/ai-gateway/app-profiles/{app}, audited).';
COMMENT ON COLUMN shared.llm_app_profile.ai_enabled IS
    'AA-1025 H1a (345): false = every AI call of the app is refused before any provider attempt (CIS gateway; '
    'TripPlanner H1b and the CRM H1c read it too). The degrade_mode says what the app shows meanwhile.';
COMMENT ON COLUMN shared.llm_app_profile.bulk_paused IS
    'AA-1025 H1a (345): the app''s bulk work (waves, bulk re-queues) waits. Stored and shown; enforced by slice H2.';
COMMENT ON COLUMN shared.llm_app_profile.default_daily_budget_usd IS
    'AA-1025 H1a (345): the app''s default daily AI budget in USD (NULL = none). CIS enforces its central cap '
    'llm/app:cis (shared.spend_budget, 340); apps without the CIS gateway take their app-wide daily cap from here.';
COMMENT ON COLUMN shared.llm_app_profile.degrade_mode IS
    'AA-1025 H1a (345): what the app shows when AI is unavailable (tech lead T-21, S263): queue_retry (CIS), '
    'basic_narration (TripPlanner), manual_reply_needed (CRM), none (AA-Booking: no AI).';

INSERT INTO shared.llm_app_profile (app, degrade_mode) VALUES
    ('cis', 'queue_retry'),
    ('tripplanner', 'basic_narration'),
    ('crm', 'manual_reply_needed'),
    ('booking', 'none')
ON CONFLICT (app) DO NOTHING;

REVOKE ALL ON shared.llm_app_profile FROM PUBLIC;
REVOKE ALL ON shared.llm_app_profile FROM cis_app, aa_app_user, catalog_owner;   -- cis_owner's default privileges
GRANT SELECT ON shared.llm_app_profile TO cis_app;
GRANT UPDATE (ai_enabled, bulk_paused, default_daily_budget_usd, degrade_mode, disabled_reason, updated_at, updated_by)
    ON shared.llm_app_profile TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('345', now(), 'AA-1025 H1a: shared.llm_app_profile (AI on/off, bulk paused, default budget, degrade mode '
                      'per app)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
