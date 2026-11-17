-- Migration 443: AA-1116 (S283) — storage for the quote discount of each subscription line (contract
-- tenant.entitlements.v1 1.10, appended to catalog.v_tenant_billing_v1 by 444).
--
-- Why. Booking drafts the monthly software invoice from catalog.v_tenant_billing_v1 (377, 438) but cannot see the
-- discount the CIS quote gives (founding offer or combo, never both: the larger wins, S282 decision 6), so its draft
-- carries a zero "check the Tenant 360 quote for a discount" line. The rule lives in one pure function
-- (services/tenant_account/quote.py) that Tenant 360 and /v1/billing already use; re-writing it in SQL would make two
-- rules that drift. So CIS code computes the quote and stores the share of each line here (the AA-1116 code PR: on a
-- Tenant 360 billing write and every hour in the tenant_billing_tick), and 444 serves it to Booking.
--
-- What:
--   1. shared.tenant_subscription: + quote_discount_pct numeric(5,2) NOT NULL DEFAULT 0 (the percentage of THIS
--      line's amount the quote takes off: the founding share on an eligible line when the founding offer wins, the
--      combo share on every line when the combo wins, else 0) and quote_discount_kind text (founding | combo; NULL
--      exactly when the share is 0). CHECK tenant_subscription_quote_discount_check.
--   2. Register 443.
--
-- Behaviour on apply. None for running code: every row gets 0 / NULL (what Booking assumes today); the code PR fills
-- the rows at its first tick. The update trigger tenant_subscription_changed_upd fires only on plan_key / status / seats
-- / trial_ends_at, so writing the share never adds an account event; the guard trigger only bumps updated_at.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): ALTERs an existing table and adds a CHECK.
-- MIG-4: the AA-1116 contract 1.10 migration-only PR (443-444, one batch), applied on Dev by Infra Migration Apply when
-- every job table is idle (ADR 0017a), then the code PR (readiness 443). DM-6.1: a commercial term, not personal data;
-- DM-7.1: no new table.
--
-- Number. 442 is the newest CIS migration on main (17/11/2026). If the owner main max + 1 differs at merge, renumber
-- 443-444 (git grep '443_' and '443' in api/migrations, tests and docs/implementation-notes/AA-1116-l1-discount.md;
-- likewise 444).
--
-- Locks. ALTER TABLE ADD COLUMN with constant defaults (no rewrite on PG 15) and a CHECK swap on a small table
-- (tenant_subscription ~31 rows). lock_timeout 5s, statement_timeout 1min. Idempotent (IF NOT EXISTS, DROP CONSTRAINT IF
-- EXISTS + ADD), one transaction, self-registering.
--
-- Rollback (a NEW forward migration, after the code PR and 444's readers are reverted and 444's view restated without
-- the columns): DROP the CHECK and the two columns.
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of the table.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '435') THEN
        RAISE EXCEPTION 'migration 443: apply 435 first';
    END IF;
END $$;

ALTER TABLE shared.tenant_subscription
    ADD COLUMN IF NOT EXISTS quote_discount_pct  numeric(5,2) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS quote_discount_kind text;
ALTER TABLE shared.tenant_subscription DROP CONSTRAINT IF EXISTS tenant_subscription_quote_discount_check;
ALTER TABLE shared.tenant_subscription ADD CONSTRAINT tenant_subscription_quote_discount_check
    CHECK (quote_discount_pct >= 0 AND quote_discount_pct <= 100
           AND (quote_discount_kind IS NULL OR quote_discount_kind IN ('founding', 'combo'))
           AND ((quote_discount_kind IS NULL) = (quote_discount_pct = 0)));
COMMENT ON COLUMN shared.tenant_subscription.quote_discount_pct IS
    'AA-1116 (443): the percentage of this line''s amount the CIS quote takes off (services/tenant_account/quote.py: '
    'founding offer on an eligible line or combo on every line, the larger wins). Written by CIS code (Tenant 360 '
    'billing writes, the hourly tenant_billing_tick); 0 = no discount. Served to Booking by '
    'catalog.v_tenant_billing_v1 (444, contract tenant.entitlements.v1 1.10).';
COMMENT ON COLUMN shared.tenant_subscription.quote_discount_kind IS
    'AA-1116 (443): founding | combo, the discount quote_discount_pct comes from; NULL when it is 0.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('443', now(), 'AA-1116: tenant_subscription quote_discount_pct / quote_discount_kind (contract 1.10 storage)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
