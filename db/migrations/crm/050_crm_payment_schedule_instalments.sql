-- Migration crm-050: AA-1067 (S275 study of a tour and travel app, root docs/research/2026-11-10-odoo-tour-travel-
-- plugin-comparison.md, items crm-08 / crm-11 / crm-12) — a payment schedule with several instalments and a live
-- status, the agency's schedule template, the cancellation policy frozen on a proposal, and the cancellation fee
-- invoice.
--
-- Owner: AA-Partner (api/migrations/050_crm_payment_schedule_instalments.sql). AA-CIS-Infra db/migrations/crm/ holds
-- the byte copy DB Migrate applies (Migration Copy Guard). Key crm-050, after crm-049 (the expand file of the same
-- issue); if main moves, renumber both: file names, headers, the guards and registrations, app/db.py
-- REQUIRED_SCHEMA_VERSIONS.
--
-- What:
--   1. crm.payment_schedule: kind deposit | instalment | balance (was deposit | balance); seq (SMALLINT, default 1:
--      the instalment number, 1 for the deposit and the balance, 1..10 for instalments); percent (NUMERIC(5,2), NULL:
--      the share of the total the line was planned with; NULL for the balance (the rest) and for rows written before
--      this key). One live row per proposal, kind and seq (payment_schedule_live_uq rebuilt on (tenant_id,
--      proposal_id, kind, seq)). The seal (CRM31) covers seq and percent too. The stored status stays due | paid |
--      void and paid_at stays per row (history kept); partial and overdue are derived in the view of step 4.
--   2. crm.proposal: schedule_plan (JSONB, NULL = the two-row schedule of crm-016 / crm-019: deposit_pct and
--      balance_due_on): the lines the agent set in the builder ([{kind, seq, percent, due_on, days_before}], at most
--      12, 4 KB); cancellation_policy_id (UUID, NULL; no key, the crm-049 policy rows stay while the agency lives):
--      the policy version the client accepts with the proposal (pinned when the version goes out). Both are sealed
--      after draft with the other content columns (crm.proposal_sealed recreated with the crm-048 list plus these
--      two, CRM31), so the price hash and the accepted text never move.
--   3. crm.tenant_settings.schedule_template (JSONB, NULL = the AA default 30 % now, 40 % at T-60, the rest at T-30):
--      the agency's default schedule for a new builder version (an array of 1..12 lines, 4 KB; the API checks the
--      lines).
--   4. crm.v_schedule_status (security_invoker): each live schedule row with the money paid on it (payments minus
--      refund entries, every payment carries its schedule row), the open amount and a live status: paid | void |
--      overdue (due before today in the agency's timezone, not paid in full) | partial | due, and the days overdue.
--      crm_app SELECT; no reader grant.
--   5. crm.invoice: kind adds instalment (bills an instalment row, like deposit / balance: schedule_id set, tax
--      inclusive) and cancellation_fee (the cancel run's charge to the client, crm-12: no schedule row).
--   6. Index crm.payment (tenant_id, schedule_id) for the view's per-row sums.
--
-- Behaviour on apply: none. Every existing schedule row keeps kind deposit / balance with seq 1 and no percent; every
-- proposal has no plan and no policy; no agency has a template (the AA default applies once the code deploys).
--
-- Class: contract (ALTER of crm.payment_schedule, crm.proposal, crm.tenant_settings, crm.invoice; the seal triggers
-- recreated; an index replaced). MIG-4: this migration-only PR (batch crm 049-050), then the code PR once both are
-- applied on Dev. DM-7.1: no new table here (crm-049's tables have their rows).
--
-- Rollback (a NEW forward migration, after the code is reverted): DROP VIEW crm.v_schedule_status; DROP INDEX
-- crm.payment_schedule_idx; restore the crm-016 kind / unique index and seal (needs no instalment row left), the
-- crm-024 invoice kind checks (needs no instalment / cancellation_fee invoice left) and the crm-048 proposal seal;
-- DROP COLUMN proposal.schedule_plan, proposal.cancellation_policy_id, tenant_settings.schedule_template,
-- payment_schedule.seq, payment_schedule.percent.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (IF NOT EXISTS, DROP …
-- IF EXISTS before each ADD, CREATE OR REPLACE).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

-- ── Guard 0: runs as the owner, after crm-049 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-050: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-049') THEN
        RAISE EXCEPTION 'crm-050: crm-049 (AA-1067, the cancellation policy tables) lands first';
    END IF;
    IF to_regclass('crm.payment_schedule') IS NULL OR to_regclass('crm.invoice') IS NULL
       OR to_regclass('crm.cancellation_policy') IS NULL
       OR to_regprocedure('crm.guard_sealed_row()') IS NULL THEN
        RAISE EXCEPTION 'crm-050: crm.payment_schedule (crm-016), crm.invoice (crm-024), crm.cancellation_policy (crm-049) or crm.guard_sealed_row missing';
    END IF;
END $$;

-- ── 1. crm.payment_schedule: instalments ─────────────────────────────────────────────────────────
ALTER TABLE crm.payment_schedule ADD COLUMN IF NOT EXISTS seq SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE crm.payment_schedule ADD COLUMN IF NOT EXISTS percent NUMERIC(5,2);
ALTER TABLE crm.payment_schedule DROP CONSTRAINT IF EXISTS payment_schedule_kind_chk;
ALTER TABLE crm.payment_schedule ADD CONSTRAINT payment_schedule_kind_chk
    CHECK (kind IN ('deposit', 'instalment', 'balance'));
ALTER TABLE crm.payment_schedule DROP CONSTRAINT IF EXISTS payment_schedule_seq_chk;
ALTER TABLE crm.payment_schedule ADD CONSTRAINT payment_schedule_seq_chk CHECK (
    (kind = 'instalment' AND seq BETWEEN 1 AND 10) OR (kind <> 'instalment' AND seq = 1)
);
ALTER TABLE crm.payment_schedule DROP CONSTRAINT IF EXISTS payment_schedule_percent_chk;
ALTER TABLE crm.payment_schedule ADD CONSTRAINT payment_schedule_percent_chk CHECK (
    percent IS NULL OR (percent > 0 AND percent <= 100)
);
DROP INDEX IF EXISTS crm.payment_schedule_live_uq;
CREATE UNIQUE INDEX payment_schedule_live_uq ON crm.payment_schedule (tenant_id, proposal_id, kind, seq)
    WHERE status <> 'void' AND deleted_at IS NULL;
-- The crm-016 seal plus the two new columns: a paid or void row never changes.
CREATE OR REPLACE TRIGGER payment_schedule_sealed BEFORE UPDATE ON crm.payment_schedule FOR EACH ROW
    EXECUTE FUNCTION crm.guard_sealed_row('due', 'trip_id', 'proposal_id', 'kind', 'amount', 'currency', 'due_on',
        'paid_at', 'tenant_id', 'seq', 'percent');
COMMENT ON COLUMN crm.payment_schedule.kind IS 'AA-946 (crm-016), widened by AA-1067 (crm-050): deposit (the first line, due at accept; its payment opens Proposal -> Booked) | instalment (seq 1..10) | balance (the rest, the last line)';
COMMENT ON COLUMN crm.payment_schedule.seq IS 'AA-1067 (crm-050): the instalment number (1..10); 1 for the deposit and the balance. One live row per proposal, kind and seq';
COMMENT ON COLUMN crm.payment_schedule.percent IS 'AA-1067 (crm-050): the share of the accepted total the line was planned with (deposit, instalments); NULL for the balance (the rest) and for rows written before crm-050';

-- ── 2. crm.proposal: the schedule plan and the frozen cancellation policy ────────────────────────
ALTER TABLE crm.proposal ADD COLUMN IF NOT EXISTS schedule_plan JSONB;
ALTER TABLE crm.proposal ADD COLUMN IF NOT EXISTS cancellation_policy_id UUID;
ALTER TABLE crm.proposal DROP CONSTRAINT IF EXISTS proposal_schedule_plan_chk;
ALTER TABLE crm.proposal ADD CONSTRAINT proposal_schedule_plan_chk CHECK (
    schedule_plan IS NULL
    OR (kind = 'builder' AND jsonb_typeof(schedule_plan) = 'array'
        AND jsonb_array_length(schedule_plan) BETWEEN 1 AND 12 AND octet_length(schedule_plan::text) <= 4096)
);
COMMENT ON COLUMN crm.proposal.schedule_plan IS 'AA-1067 (crm-050): builder versions: the payment lines the agent set ([{kind deposit|instalment|balance, seq, percent, due_on, days_before}]); NULL = the crm-019 deposit_pct / balance_due_on pair. deposit_pct and balance_due_on mirror its deposit and balance lines. Covered by the price hash; the accept writes one crm.payment_schedule row per line from the accepted total (the balance takes the rounding rest)';
COMMENT ON COLUMN crm.proposal.cancellation_policy_id IS 'AA-1067 (crm-050): the crm.cancellation_policy version (crm-049) the client accepts with this version, pinned when it goes out (the agency default when the agent chose none); no key (a policy version stays while the agency lives). Covered by the price hash; merged into the booking terms text (cancellation.policy)';
-- The crm-048 seal plus the plan and the policy.
CREATE OR REPLACE TRIGGER proposal_sealed BEFORE UPDATE ON crm.proposal FOR EACH ROW
    EXECUTE FUNCTION crm.guard_sealed_row('draft', 'trip_id', 'version', 'body_enc', 'currency', 'total_amount',
        'deposit_amount', 'balance_due_on', 'terms_doc_id', 'price_hash', 'tenant_id', 'kind', 'price_visibility',
        'room_config', 'deposit_pct', 'starts_on', 'published_at', 'discount_pct', 'schedule_plan',
        'cancellation_policy_id');

-- ── 3. crm.tenant_settings.schedule_template ─────────────────────────────────────────────────────
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS schedule_template JSONB;
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_schedule_template_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_schedule_template_chk CHECK (
    schedule_template IS NULL
    OR (jsonb_typeof(schedule_template) = 'array' AND jsonb_array_length(schedule_template) BETWEEN 1 AND 12
        AND octet_length(schedule_template::text) <= 4096)
);
COMMENT ON COLUMN crm.tenant_settings.schedule_template IS 'AA-1067 (crm-050): the owner''s default payment schedule for a new builder version ([{kind, percent, due: {anchor accept | before_start, days}}]); NULL = the AA default (30 % at accept, 40 % 60 days before departure, the rest 30 days before)';

-- ── 5. crm.invoice: instalment and cancellation_fee ──────────────────────────────────────────────
ALTER TABLE crm.invoice DROP CONSTRAINT IF EXISTS invoice_kind_chk;
ALTER TABLE crm.invoice ADD CONSTRAINT invoice_kind_chk CHECK (
    kind IN ('deposit', 'instalment', 'balance', 'service_fee', 'adjustment', 'cancellation_fee')
);
ALTER TABLE crm.invoice DROP CONSTRAINT IF EXISTS invoice_schedule_chk;
ALTER TABLE crm.invoice ADD CONSTRAINT invoice_schedule_chk CHECK (
    (kind IN ('deposit', 'instalment', 'balance')) = (schedule_id IS NOT NULL)
    AND (schedule_id IS NULL OR (proposal_id IS NOT NULL AND tax_inclusive))
);
COMMENT ON COLUMN crm.invoice.kind IS 'AA-952 (crm-024), widened by AA-1067 (crm-050): deposit | instalment | balance (bills its schedule row) | service_fee | adjustment (typed lines) | cancellation_fee (issued by the trip cancel run for the policy charge not covered by money already paid)';

-- ── 6. Index for the per-row payment sums ────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS payment_schedule_idx ON crm.payment (tenant_id, schedule_id) WHERE schedule_id IS NOT NULL;

-- ── 4. crm.v_schedule_status ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW crm.v_schedule_status WITH (security_invoker = true) AS
SELECT s.schedule_id, s.tenant_id, s.trip_id, s.proposal_id, s.kind, s.seq, s.percent, s.amount, s.currency,
       s.due_on, s.status, s.paid_at, x.paid_amount,
       CASE WHEN s.status = 'due' THEN greatest(s.amount - x.paid_amount, 0)::numeric(14,2)
            ELSE 0::numeric(14,2) END AS open_amount,
       CASE WHEN s.status IN ('paid', 'void') THEN s.status
            WHEN x.paid_amount >= s.amount THEN 'paid'
            WHEN s.due_on < d.today THEN 'overdue'
            WHEN x.paid_amount > 0 THEN 'partial'
            ELSE 'due' END AS live_status,
       CASE WHEN s.status = 'due' AND x.paid_amount < s.amount AND s.due_on < d.today THEN d.today - s.due_on
            ELSE 0 END AS days_overdue
  FROM crm.payment_schedule s
 CROSS JOIN LATERAL (
       SELECT coalesce(sum(CASE WHEN p.entry_kind = 'payment' THEN p.amount ELSE -p.amount END), 0)::numeric(14,2)
              AS paid_amount
         FROM crm.payment p WHERE p.tenant_id = s.tenant_id AND p.schedule_id = s.schedule_id) x
 CROSS JOIN LATERAL (
       SELECT (now() AT TIME ZONE coalesce(
                  (SELECT ts.timezone FROM crm.tenant_settings ts WHERE ts.tenant_id = s.tenant_id),
                  'Asia/Ho_Chi_Minh'))::date AS today) d
 WHERE s.deleted_at IS NULL;
COMMENT ON VIEW crm.v_schedule_status IS 'AA-1067 (crm-050): each live payment schedule row with paid_amount (its payments minus refund entries), open_amount, live_status (paid | void | overdue: due before today in the agency timezone and not paid in full | partial | due) and days_overdue. security_invoker: reads through the caller''s policies.';
GRANT SELECT ON crm.v_schedule_status TO crm_app;

-- ── Post-checks ──────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT has_column_privilege('crm_app', 'crm.proposal', 'schedule_plan', 'UPDATE')
       OR NOT has_column_privilege('crm_app', 'crm.proposal', 'cancellation_policy_id', 'UPDATE')
       OR NOT has_column_privilege('crm_app', 'crm.tenant_settings', 'schedule_template', 'UPDATE')
       OR NOT has_column_privilege('crm_app', 'crm.payment_schedule', 'seq', 'INSERT') THEN
        RAISE EXCEPTION 'crm-050: crm_app cannot write the new columns';
    END IF;
    IF NOT has_table_privilege('crm_app', 'crm.v_schedule_status', 'SELECT') THEN
        RAISE EXCEPTION 'crm-050: crm_app cannot read crm.v_schedule_status';
    END IF;
    IF has_table_privilege('crm_support_reader', 'crm.v_schedule_status', 'SELECT') THEN
        RAISE EXCEPTION 'crm-050: crm_support_reader must not read crm.v_schedule_status';
    END IF;
    IF NOT COALESCE((SELECT 'security_invoker=true' = ANY (reloptions) FROM pg_catalog.pg_class
                     WHERE oid = 'crm.v_schedule_status'::regclass), false) THEN
        RAISE EXCEPTION 'crm-050: crm.v_schedule_status must be security_invoker';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'proposal_sealed'
                   AND tgrelid = 'crm.proposal'::regclass
                   AND position('schedule_plan' IN pg_catalog.encode(tgargs, 'escape')) > 0
                   AND position('cancellation_policy_id' IN pg_catalog.encode(tgargs, 'escape')) > 0
                   AND position('discount_pct' IN pg_catalog.encode(tgargs, 'escape')) > 0) THEN
        RAISE EXCEPTION 'crm-050: the proposal seal must cover schedule_plan and cancellation_policy_id and keep crm-048''s';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'payment_schedule_sealed'
                   AND tgrelid = 'crm.payment_schedule'::regclass
                   AND position('percent' IN pg_catalog.encode(tgargs, 'escape')) > 0) THEN
        RAISE EXCEPTION 'crm-050: the schedule seal must cover seq and percent';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-050', now(), 'AA-1067: payment schedule instalments (kind instalment, seq, percent, live index per kind+seq, crm.v_schedule_status partial / overdue), proposal.schedule_plan + cancellation_policy_id (sealed), tenant_settings.schedule_template, invoice kinds instalment + cancellation_fee')
ON CONFLICT (version) DO NOTHING;

COMMIT;
