-- Migration crm-086: AA-1152 (S289 lane g-1152; S285 decision B2 option C, root
-- docs/audits/2026-11-19-S285-session/advisory-r2-b2b-crm.md) — the agency's own rounded prices: the rounding step per
-- currency the agency chooses, its "Show prices on my planner" switch (the platform settings behind them: crm-087).
--
-- Owner: AA-Partner (api/migrations/086_crm_planner_prices.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- Migration Apply runs. Key crm-086, owner main max + 1; if the number moves, renumber: file name, this header, Guard 0,
-- the post-check and the registration, and the tests that name it (git grep '086_' and 'crm-086').
--
-- What:
--   1. crm.tenant_settings.price_round_step (JSONB NOT NULL DEFAULT '{}'): the agency's rounding step per currency
--      ({"USD": "5", "VND": "50000"}); a currency it did not choose takes the platform default (setting
--      crm.agency_defaults.price_round_step). The API accepts only a step of the platform list
--      (crm.agency_defaults.price_round_steps); the CHECK keeps the shape (an object, at most 512 bytes).
--      Every price the CRM suggests (the AA option of a proposal, the agency's planner "from" prices) is rounded UP
--      per traveller to this step, then times the party (app/proposals/rounding.py).
--   2. crm.tenant_settings.show_planner_prices (boolean NOT NULL DEFAULT true): the owner's switch; off = the agency's
--      TripPlanner pages show no price (contract tripplanner.agency_prices.v1 show_prices false).
--   3. Register crm-086. The two platform settings behind the columns (the default step per currency and the steps an
--      owner may choose) are crm-087, shipped with their readers in the code PR like crm-084 (settings rows need their
--      reader and guide in the same PR; the readers serve the compiled defaults until it is applied).
--
-- Behaviour on apply: none for running code (the code PR reads the columns with a fallback to the defaults while they
-- are missing).
--
-- Class: contract (ALTER of an existing table; no '-- migrate:' directive). Migration-only PR
-- first (MIG-4); the code PR raises readiness to crm-086. No new table (no DM-7.1 row), no personal data (commercial
-- settings), no crm.erase_subject change (the tenant's settings row goes with the tenant).
--
-- Rollback (a new forward migration, after the code is reverted): ALTER TABLE crm.tenant_settings DROP CONSTRAINT
-- tenant_settings_price_round_step_chk, DROP COLUMN price_round_step, DROP COLUMN show_planner_prices, as crm_owner.
--
-- Runs as crm_owner (the crm-064 definition guard allows only the owner), one BEGIN … COMMIT block, no role DDL.
-- Re-runnable (ADD COLUMN IF NOT EXISTS, DROP CONSTRAINT IF EXISTS + ADD, ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-085 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-086: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-085') THEN
        RAISE EXCEPTION 'crm-086: crm-085 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-086' AND description NOT LIKE 'AA-1152 planner prices:%') THEN
        RAISE EXCEPTION 'crm-086: the key crm-086 is already held by another migration (not AA-1152): renumber one';
    END IF;
END $$;

-- ── 1–2. The agency's rounding steps and its show-prices switch ──────────────────────────────────
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS price_round_step JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS show_planner_prices BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_price_round_step_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_price_round_step_chk
    CHECK (jsonb_typeof(price_round_step) = 'object' AND octet_length(price_round_step::text) <= 512);
COMMENT ON COLUMN crm.tenant_settings.price_round_step IS 'AA-1152 (crm-086, S285 B2 option C): the agency''s rounding step per currency ({"USD": "5"}); every price the CRM suggests is rounded up per traveller to it. ''{}'' = the platform default (crm.agency_defaults.price_round_step). Commercial, no personal data.';
COMMENT ON COLUMN crm.tenant_settings.show_planner_prices IS 'AA-1152 (crm-086): the owner''s "Show prices on my planner" switch; false = the agency''s TripPlanner pages show no price (tripplanner.agency_prices.v1 show_prices). No personal data.';

-- ── Post-check ────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT has_column_privilege('crm_app', 'crm.tenant_settings', 'price_round_step', 'UPDATE')
       OR NOT has_column_privilege('crm_app', 'crm.tenant_settings', 'show_planner_prices', 'UPDATE') THEN
        RAISE EXCEPTION 'crm-086: crm_app cannot write the new crm.tenant_settings columns';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-086', now(), 'AA-1152 planner prices: crm.tenant_settings.price_round_step (the agency''s rounding step per currency) and show_planner_prices (its "Show prices on my planner" switch)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
