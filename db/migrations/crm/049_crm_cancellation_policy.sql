-- migrate: expand
-- Migration crm-049: AA-1067 (S275 study of a tour and travel app, root docs/research/2026-11-10-odoo-tour-travel-
-- plugin-comparison.md, items crm-11 / crm-12) — the agency's cancellation policy for its travellers (a days-before
-- charge table, versioned) and the record of what a trip cancellation charged the client.
--
-- Owner: AA-Partner (api/migrations/049_crm_cancellation_policy.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy DB Migrate applies (Migration Copy Guard). Key crm-049: crm-048 is the highest on main; if main moves, renumber:
-- file name, this header, the registration below, crm-050's guard, app/db.py REQUIRED_SCHEMA_VERSIONS.
--
-- What (DM-7.1: root data standards Part B §7 rows added with this key; no personal data in any of the three tables):
--   1. crm.cancellation_policy (base template): one version of an agency's cancellation policy for its travellers:
--      name, version (1, 2, ...), the version it replaces, the currency of its minimum charges (NULL = none),
--      is_default (the agency's default for new proposals; at most one live default), published_at (NULL = a draft
--      the owner still edits; set once), retired_at (a newer version replaced it, or the owner retired it). A published
--      version never changes its tiers: a change is a new version (so a proposal that froze a version keeps the text
--      the client accepted). Cascades from the agency's crm.tenant_settings row (the agency erase deletes it).
--   2. crm.cancellation_policy_tier (base template): "cancelled N days or more before departure -> X % of the trip
--      total, at least M": days_before_min (0..730), charge_pct (0..100), min_charge_amount (NULL, else in the policy
--      currency). One tier per days_before_min. Changes only while its policy is a draft (crm.guard_cancellation_policy,
--      CRM49). Cascades from its policy.
--   3. crm.cancellation_charge (base template): what one trip cancellation charged the client (crm-12): the policy
--      version and tier percent applied, the days before departure, the policy charge, the final charge (the policy's,
--      an override with a reason, or waived with a reason), the money paid, the part kept towards the charge, the
--      refund due, the cancellation fee invoice raised for the rest (no key: an invoice is never deleted while its
--      trip lives, and both leave with the trip). One row per trip. Written once by the cancel run (a member), never
--      updated or deleted by crm_app (the guard, CRM49); cascades from its trip. The seam of the trip P&L (crm-30):
--      fee = charge_amount; AA's cost stays the booking line money kind cancellation_cost.
--   4. Keys: the policy row is referenced by proposals (crm-050, plain uuid, no key: a policy is never deleted while
--      the agency lives) and by a charge row (plain uuid too).
--   5. Write guard crm.guard_cancellation_policy (SQLSTATE CRM49; crm-048 used CRM48) on the three tables:
--      a published policy changes only is_default, retired_at (set once) and updated_at; published_at is set once;
--      a tier of a published policy never changes; a charge row is inserted by a member and never changes. A cascade
--      (trigger depth > 1) and crm_owner pass. No crm_app DELETE of a published policy (the guard).
--   6. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles); crm_app keeps the default DML of crm-001 (the guard
--      decides); no reader grant: AI context, insights and support never read them.
--
-- Class: expand (root ADR 0017 d3): three new tables and one new trigger function with their constraints, indexes,
-- triggers, policies and comments; foreign keys from the new tables (to crm.tenant, crm.tenant_settings, crm.trip and
-- each other); no change to an existing object, no DO block, no CREATE OR REPLACE. Not re-runnable by itself (plain
-- CREATE POLICY / TRIGGER / FUNCTION); DB Migrate never applies a registered key again and the test conftest skips
-- it. Ships in the migration-only PR with crm-050 (batch crm 049-050), applied before the code PR.
--
-- Rollback (a forward crm- file, after the code that reads them is reverted): DROP TABLE crm.cancellation_charge,
-- crm.cancellation_policy_tier, crm.cancellation_policy; DROP FUNCTION crm.guard_cancellation_policy().
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- ── 1. crm.cancellation_policy ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.cancellation_policy (
    policy_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    name               TEXT NOT NULL,
    version            SMALLINT NOT NULL DEFAULT 1,
    replaces_policy_id UUID,
    currency           CHARACTER(3),
    is_default         BOOLEAN NOT NULL DEFAULT false,
    published_at       TIMESTAMPTZ,
    retired_at         TIMESTAMPTZ,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,
    deleted_by         TEXT,
    purge_after        TIMESTAMPTZ,
    CONSTRAINT cancellation_policy_tenant_id_uq UNIQUE (tenant_id, policy_id),
    CONSTRAINT cancellation_policy_settings_fk FOREIGN KEY (tenant_id)
        REFERENCES crm.tenant_settings (tenant_id) ON DELETE CASCADE,
    CONSTRAINT cancellation_policy_values_chk CHECK (
        char_length(btrim(name)) BETWEEN 1 AND 80 AND name !~ '[[:cntrl:]]'
        AND version BETWEEN 1 AND 999
        AND (currency IS NULL OR currency ~ '^[A-Z]{3}$')
    ),
    -- A draft is never the default nor retired; retired only after published.
    CONSTRAINT cancellation_policy_state_chk CHECK (
        (published_at IS NOT NULL OR (NOT is_default AND retired_at IS NULL))
        AND (retired_at IS NULL OR NOT is_default)
    ),
    CONSTRAINT cancellation_policy_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS cancellation_policy_one_default_uq ON crm.cancellation_policy (tenant_id)
    WHERE is_default AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS cancellation_policy_tenant_idx ON crm.cancellation_policy (tenant_id, name, version)
    WHERE deleted_at IS NULL;
COMMENT ON TABLE crm.cancellation_policy IS 'AA-1067 (crm-049, item crm-11): one version of the agency''s cancellation policy for its travellers (a days-before charge table in crm.cancellation_policy_tier). A draft (published_at NULL) is edited by the owner; a published version never changes its tiers (a change is a new version, replaces_policy_id) and is frozen on the proposals that went out with it (crm.proposal.cancellation_policy_id, crm-050). is_default: the agency''s policy for new proposals (one live default). Commercial, no personal data. Cascades from the agency''s tenant_settings row. Guard crm.guard_cancellation_policy (CRM49).';
COMMENT ON COLUMN crm.cancellation_policy.currency IS 'the currency of the tiers'' min_charge_amount (NULL = no minimum charges); a minimum applies only to a trip in that currency';
COMMENT ON COLUMN crm.cancellation_policy.replaces_policy_id IS 'the published version this one replaces (no key: versions of one policy stay together while the agency lives); publishing this one retires that one';

-- ── 2. crm.cancellation_policy_tier ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.cancellation_policy_tier (
    tier_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                      REFERENCES crm.tenant (tenant_id),
    policy_id         UUID NOT NULL,
    days_before_min   SMALLINT NOT NULL,
    charge_pct        NUMERIC(5,2) NOT NULL,
    min_charge_amount NUMERIC(14,2),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,
    deleted_by        TEXT,
    purge_after       TIMESTAMPTZ,
    CONSTRAINT cancellation_policy_tier_tenant_id_uq UNIQUE (tenant_id, tier_id),
    CONSTRAINT cancellation_policy_tier_days_uq UNIQUE (tenant_id, policy_id, days_before_min),
    CONSTRAINT cancellation_policy_tier_policy_fk FOREIGN KEY (tenant_id, policy_id)
        REFERENCES crm.cancellation_policy (tenant_id, policy_id) ON DELETE CASCADE,
    CONSTRAINT cancellation_policy_tier_values_chk CHECK (
        days_before_min BETWEEN 0 AND 730
        AND charge_pct BETWEEN 0 AND 100
        AND (min_charge_amount IS NULL OR (min_charge_amount > 0 AND min_charge_amount <= 99999999.99))
    ),
    CONSTRAINT cancellation_policy_tier_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
COMMENT ON TABLE crm.cancellation_policy_tier IS 'AA-1067 (crm-049, item crm-11): one line of a cancellation policy: a trip cancelled days_before_min days or more before departure (and fewer than the next line''s) is charged charge_pct % of the trip total, at least min_charge_amount (policy currency) and never more than the total. Changes only while the policy is a draft (CRM49). Cascades from its policy. Commercial, no personal data.';

-- ── 3. crm.cancellation_charge ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.cancellation_charge (
    charge_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    trip_id          UUID NOT NULL,
    proposal_id      UUID,
    policy_id        UUID,
    currency         CHARACTER(3) NOT NULL,
    trip_total       NUMERIC(14,2) NOT NULL,
    days_before      SMALLINT,
    charge_pct       NUMERIC(5,2),
    policy_charge    NUMERIC(14,2) NOT NULL,
    charge_amount    NUMERIC(14,2) NOT NULL,
    decision         TEXT NOT NULL,
    reason           TEXT,
    paid_amount      NUMERIC(14,2) NOT NULL,
    kept_amount      NUMERIC(14,2) NOT NULL,
    refund_due       NUMERIC(14,2) NOT NULL,
    invoiced_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,
    invoice_id       UUID,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT cancellation_charge_tenant_id_uq UNIQUE (tenant_id, charge_id),
    CONSTRAINT cancellation_charge_trip_uq UNIQUE (tenant_id, trip_id),
    CONSTRAINT cancellation_charge_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT cancellation_charge_money_chk CHECK (
        currency ~ '^[A-Z]{3}$'
        AND trip_total >= 0 AND policy_charge >= 0 AND charge_amount >= 0 AND paid_amount >= 0
        AND kept_amount >= 0 AND refund_due >= 0 AND invoiced_amount >= 0
        AND charge_amount <= trip_total AND policy_charge <= trip_total
        AND kept_amount <= paid_amount
        AND (charge_pct IS NULL OR charge_pct BETWEEN 0 AND 100)
        AND (days_before IS NULL OR days_before BETWEEN -3650 AND 3650)
        AND (invoice_id IS NULL) = (invoiced_amount = 0)
    ),
    -- The policy's charge as is, or the member's override / waiver with a reason; no policy = no_policy.
    CONSTRAINT cancellation_charge_decision_chk CHECK (
        decision IN ('policy', 'override', 'waived', 'no_policy')
        AND (decision IN ('override', 'waived')) = (reason IS NOT NULL)
        AND (decision <> 'waived' OR charge_amount = 0)
        AND (decision <> 'policy' OR (policy_id IS NOT NULL AND charge_amount = policy_charge))
        AND (decision <> 'no_policy' OR (policy_id IS NULL AND charge_amount = 0))
        AND (reason IS NULL OR (char_length(btrim(reason)) BETWEEN 1 AND 500 AND reason !~ '[[:cntrl:]]'))
    ),
    CONSTRAINT cancellation_charge_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
COMMENT ON TABLE crm.cancellation_charge IS 'AA-1067 (crm-049, items crm-11 / crm-12): what one trip cancellation charged the client: the frozen policy version and tier percent, days before departure (agency date), the policy charge, the final charge_amount (decision policy | override (reason) | waived (reason) | no_policy), the money paid, the part kept towards the charge, the refund due (paid - charge, never below 0) and the cancellation fee invoice raised for the rest. One row per trip, written once by the cancel run (a member), never changed (CRM49). The trip P&L seam (crm-30): fee = charge_amount. Cascades from its trip. Amounts only, no personal data.';
COMMENT ON COLUMN crm.cancellation_charge.reason IS 'the member''s reason for an override or a waiver (agency text, 1..500, one line); NULL for the policy charge';
COMMENT ON COLUMN crm.cancellation_charge.invoice_id IS 'the crm.invoice (kind cancellation_fee) the run issued for charge_amount - kept_amount (no key: both leave with the trip)';

-- ── RLS, policies and triggers of the three tables (no DO block: an expand file) ─────────────────
ALTER TABLE crm.cancellation_policy ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.cancellation_policy FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.cancellation_policy
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE crm.cancellation_policy_tier ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.cancellation_policy_tier FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.cancellation_policy_tier
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE crm.cancellation_charge ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.cancellation_charge FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.cancellation_charge
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE TRIGGER cancellation_policy_set_updated_at
    BEFORE UPDATE ON crm.cancellation_policy
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE TRIGGER cancellation_policy_tier_set_updated_at
    BEFORE UPDATE ON crm.cancellation_policy_tier
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE TRIGGER cancellation_charge_set_updated_at
    BEFORE UPDATE ON crm.cancellation_charge
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();

CREATE FUNCTION crm.guard_cancellation_policy() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    -- The columns a published policy may still change.
    v_live_cols text[] := ARRAY['is_default', 'retired_at', 'updated_at'];
    v_published timestamptz;
BEGIN
    -- A cascade (the agency erase, a trip erase: trigger depth > 1) and the owner role (migrations, tests) pass.
    IF pg_catalog.pg_trigger_depth() > 1 OR current_user = 'crm_owner' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_TABLE_NAME = 'cancellation_charge' THEN
        IF TG_OP = 'INSERT' AND v_actor LIKE 'member:%' THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'crm: cancellation_policy_guard (a cancellation charge is written once by a member''s cancel, actor %)',
            v_actor USING ERRCODE = 'CRM49';
    END IF;
    IF TG_TABLE_NAME = 'cancellation_policy' THEN
        IF TG_OP = 'INSERT' THEN
            IF NEW.published_at IS NOT NULL THEN
                RAISE EXCEPTION 'crm: cancellation_policy_guard (a new policy is a draft)' USING ERRCODE = 'CRM49';
            END IF;
            RETURN NEW;
        END IF;
        IF OLD.published_at IS NULL THEN
            RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;  -- a draft: edited or deleted freely
        END IF;
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'crm: cancellation_policy_guard (a published policy is retired, never deleted)'
                USING ERRCODE = 'CRM49';
        END IF;
        IF (pg_catalog.to_jsonb(NEW) - v_live_cols) IS DISTINCT FROM (pg_catalog.to_jsonb(OLD) - v_live_cols)
           OR (OLD.retired_at IS NOT NULL AND NEW.retired_at IS DISTINCT FROM OLD.retired_at) THEN
            RAISE EXCEPTION 'crm: cancellation_policy_guard (a published policy changes only its default flag, or is retired once)'
                USING ERRCODE = 'CRM49';
        END IF;
        RETURN NEW;
    END IF;
    -- crm.cancellation_policy_tier: only the tiers of a draft change.
    SELECT p.published_at INTO v_published FROM crm.cancellation_policy p
     WHERE p.tenant_id = (CASE WHEN TG_OP = 'DELETE' THEN OLD.tenant_id ELSE NEW.tenant_id END)
       AND p.policy_id = (CASE WHEN TG_OP = 'DELETE' THEN OLD.policy_id ELSE NEW.policy_id END);
    IF v_published IS NOT NULL OR (TG_OP = 'UPDATE' AND NEW.policy_id IS DISTINCT FROM OLD.policy_id) THEN
        RAISE EXCEPTION 'crm: cancellation_policy_guard (the tiers of a published policy never change; make a new version)'
            USING ERRCODE = 'CRM49';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
COMMENT ON FUNCTION crm.guard_cancellation_policy() IS 'AA-1067 (crm-049, SQLSTATE CRM49): who may write the cancellation policy tables. crm.cancellation_policy: inserted as a draft; a draft changes and is deleted freely; a published one changes only is_default and retired_at (set once), never deleted. crm.cancellation_policy_tier: only while its policy is a draft. crm.cancellation_charge: inserted by a member (member:<id>, the cancel run), never updated or deleted. A cascade (depth > 1) and crm_owner pass. Invoker rights.';
CREATE TRIGGER cancellation_policy_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.cancellation_policy
    FOR EACH ROW EXECUTE FUNCTION crm.guard_cancellation_policy();
CREATE TRIGGER cancellation_policy_tier_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.cancellation_policy_tier
    FOR EACH ROW EXECUTE FUNCTION crm.guard_cancellation_policy();
CREATE TRIGGER cancellation_charge_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.cancellation_charge
    FOR EACH ROW EXECUTE FUNCTION crm.guard_cancellation_policy();

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-049', now(), 'AA-1067: traveller cancellation policy (crm.cancellation_policy versions + crm.cancellation_policy_tier days-before charge table) and crm.cancellation_charge (what a trip cancellation charged); guard CRM49; cascades from tenant_settings / trip, no erase_subject change')
ON CONFLICT (version) DO NOTHING;

COMMIT;
