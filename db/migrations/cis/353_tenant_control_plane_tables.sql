-- Migration 353: AA-1028 R1 slice 1 (root ADR 0019 d1, d2) — the tenant control plane in CIS shared: the feature
-- catalogue, plans and their features, tenant subscriptions, per-tenant overrides, the materialised entitlements, the
-- account event feed, and the resolver that turns them into one entitlement per tenant and feature key.
--
-- Why. ADR 0019 d1: the CIS shared schema is the master of the tenant account, lifecycle, plans, subscriptions and
-- entitlements; crm.tenant and booking.b2b_partners become read-only projections (pull jobs, slices 2-3). d2: apps
-- check feature keys, never plan names; entitlements are materialised in shared.tenant_entitlement and published as
-- contract tenant.entitlements.v1 (root docs/contracts/tenant.entitlements.v1.openapi.yaml). Today plan limits live
-- in three places (shared.membership_plans, the PLAN_LIMITS dict in api/routers/admin.py, the CRM's free/core/pro
-- CHECK) and none can be edited as a plan (S263 pricing research §2). This file is storage plus the resolver; the
-- policy rows (products, plans, prices, feature values) and the shared.tenants columns come in 354 / 355 (contract).
--
-- What (new objects only; nothing pre-existing changes):
--   1. shared.entitlement_feature  the feature-key catalogue: feature_key PK (dotted, lower case), product
--      (content | crm | tripplanner | platform), value_kind (flag | limit | seats | policy), unit (NULL for a flag;
--      count_month | usd_month | rpm | seats | days), description, retired_at. A retired key resolves to nothing.
--   2. shared.plan  one row per sellable plan: plan_key PK '<product>.<name>', product (content | crm | tripplanner),
--      name, tier (public.plan_tier_enum, content plans only, one live content plan per tier: the bridge from
--      shared.tenants.plan_tier), price_usd_monthly (NULL = contract / not priced yet), price_unit (tenant | seat |
--      site), seats_included, price_extra_seat_usd, is_public, version, membership_plan_id (a soft link to
--      shared.membership_plans, read while that table is: no FK, because that table was made by hand on Dev and the
--      CI replay of 223 does not build it), notes, retired_at, audit columns.
--   3. shared.plan_feature  (plan_key, feature_key) PK, limit_value numeric(14,2) (NULL = no limit; ignored for a
--      flag). A guard trigger refuses a feature of another product (a platform key fits every plan) and a limit on
--      a flag.
--   4. shared.tenant_subscription  one row per (tenant_id, product) (UNIQUE): plan_key (FK (plan_key, product) to
--      shared.plan, so the plan is of the same product), status in the Stripe vocabulary (trialing | active |
--      past_due | unpaid | canceled | paused; ADR 0019 §3.2), trial_ends_at (required while trialing), paid_through,
--      billing_ref, seats, started_at, canceled_at, audit columns. Guard: a crm / tripplanner row may be live
--      (trialing, active, past_due) only while the tenant's content row is live, and a content row may not leave the
--      live set while an add-on is live; a retired plan is never newly assigned.
--   5. shared.tenant_entitlement_override  one row per (tenant_id, feature_key): limit_value, enabled (false takes a
--      plan feature away), reason (1-500), granted_by, expires_at (an expired row is ignored), audit columns.
--   6. shared.tenant_entitlement  the materialised result, (tenant_id, feature_key) PK: product, value_kind, unit,
--      limit_value, source (plan | trial | override), plan_key, expires_at, resolved_at. Written ONLY by
--      shared.tenant_entitlement_sync() (guard trigger; the erasure may delete the rows of an offboarded tenant).
--   7. shared.tenant_account_event  the append-only feed of the contract: seq identity PK, event_id UNIQUE, txid xid8
--      (the writing transaction, for the feed's snapshot horizon, like CIS 276), type (account.status_changed |
--      subscription.changed | entitlement.changed), tenant_id (no FK: an event outlives a deleted tenant row), change
--      (jsonb object, the contract's change body; ids, codes and limits only, never a name or an e-mail), actor
--      (the writer's label from the transaction setting aa.actor, never served), occurred_at. Written only through
--      shared.tenant_account_emit(); never updated or truncated; deleted only for an offboarded or deleted tenant
--      (the AA-839 erasure). Index (txid, seq) for the feed, (tenant_id, seq) for one tenant's history.
--   8. shared.v_tenant_entitlement_resolved  the resolver (a view, computed live): for each tenant and feature key
--      the first of (a) an unexpired shared.tenant_entitlement_override row, (b) a shared.tenant_ai_budget row, which
--      acts as the override of ai.budget_usd_monthly until slice 3 retires that table (monthly_usd NULL = unlimited,
--      its own meaning), (c) the plan_feature row of a live subscription (source trial while trialing, with the
--      trial end as expires_at); a seats feature takes the subscription's seats when set. An override applies only
--      while the tenant has a live subscription of the feature's product (platform keys always). A disabled
--      override hides the key. A flag never carries a limit.
--   9. shared.tenant_entitlement_sync(tenant uuid): writes the resolver's rows of one tenant into
--      shared.tenant_entitlement (insert / update / delete, per-tenant advisory lock) and emits one
--      entitlement.changed event per changed key; returns the number of changed keys. Nothing for a tenant that has
--      no shared.tenants row. shared.tenant_entitlement_sync_due() re-syncs every tenant with a materialised row past
--      its expires_at (the daily tick of slice 2 calls it).
--  10. Triggers on the new tables: subscription, override, plan_feature and feature changes re-sync the affected
--      tenants; a subscription change also emits subscription.changed. A DELETE for an offboarded or deleted tenant
--      (the erasure, an FK cascade) emits nothing and re-syncs nothing.
--  11. Grants. REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner first (the Dev default ACL of cis_owner
--      in shared gives cis_app DML on every new table, CIS 245), then cis_app: SELECT on all; entitlement_feature
--      SELECT only (rows by migration); plan SELECT, INSERT, UPDATE (the Plans page, slice 3; a plan is retired,
--      never deleted); plan_feature, tenant_subscription, tenant_entitlement_override SELECT, INSERT, UPDATE, DELETE;
--      tenant_entitlement SELECT, INSERT, UPDATE, DELETE (the triggers run as the writer, MIG-6; the guard limits
--      direct writes); tenant_account_event SELECT, INSERT, DELETE (the guard limits both), nothing on its identity
--      sequence; the resolver view SELECT.
--      Nothing for aa_app_user (AA-859: no tenant-pool privilege on a relation without RLS) or catalog_owner. No
--      RLS: cis_app is the only reader (rls_catalogue_rules rule a allowlist, like shared.tenant_members). EXECUTE
--      on the functions revoked from PUBLIC, granted to cis_app for the two sync functions.
--  12. Register 353.
--
-- Behaviour. None on apply: empty tables (the policy rows arrive with 355), nothing reads them until the AA-1028 code
-- PR (GET /tenant/v1/...). shared.tenant_ai_budget is only read by the view: no trigger on it here (355).
--
-- Class: contract (root ADR 0017 d3). The content is additive (new tables, view, functions and the triggers of the new
-- tables; FKs from the new tables to shared.tenants, whose internal RI triggers land on it; no row of a pre-existing
-- table is written, the schema_versions row excepted), but the file needs what the expand lint refuses: REVOKE ALL
-- (the Dev default ACL of cis_owner in shared would otherwise leave cis_app DML on the feed and the catalogue),
-- CREATE OR REPLACE / DROP TRIGGER IF EXISTS (a re-run is a no-op) and the DO guards. It ships with the contract
-- files 354 / 355 in one migration-only PR anyway (MIG-4), so the class costs nothing. On Dev a person applies 353,
-- then 354, then 355 with DB Migrate apply (every job table idle, DM-11.4): Infra Migration Apply cannot, because the
-- cis owner's auto plan stops at the unregistered 336 (below the head, out-of-order) and contract auto-apply is off
-- until 336 is applied (AA-1024 D8, from 10/11).
--
-- Locks. The FKs take SHARE ROW EXCLUSIVE on shared.tenants for the few milliseconds of the file (reads go on). lock_timeout 5s.
--
-- Order. 353 (expand) -> 354 (contract: shared.tenants account columns and their triggers) -> 355 (contract: policy
-- rows, the tenant_ai_budget re-sync trigger, the content subscriptions of the existing tenants, the contract view).
-- One migration-only PR (MIG-4) for the three; the code PR follows once 355 is applied on Dev and the DB Schema Dump
-- bot PR has merged.
--
-- Rollback (a NEW forward migration, after the code is reverted; destructive, DRY RUN): DROP VIEW
-- shared.v_tenant_entitlement_resolved; DROP TABLE shared.tenant_account_event, shared.tenant_entitlement,
-- shared.tenant_entitlement_override, shared.tenant_subscription, shared.plan_feature, shared.plan,
-- shared.entitlement_feature; DROP FUNCTION the nine functions of this file.
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of shared.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical. After
-- apply: the DB Schema Dump bot PR regenerates docs/architecture/db-schema-reference.md.

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── Guard 1: roles, runner rights, the referenced objects ───────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regrole('cis_app') IS NULL OR to_regrole('aa_app_user') IS NULL OR to_regrole('catalog_owner') IS NULL THEN
        RAISE EXCEPTION 'migration 353: roles cis_app, aa_app_user and catalog_owner must exist';
    END IF;
    IF NOT has_schema_privilege(current_user, 'shared', 'CREATE') THEN
        RAISE EXCEPTION 'migration 353: % may not create in shared; run it through DB Migrate (cis_owner)', current_user;
    END IF;
    IF to_regclass('shared.tenants') IS NULL OR to_regclass('shared.tenant_ai_budget') IS NULL
       OR to_regtype('public.plan_tier_enum') IS NULL THEN
        RAISE EXCEPTION 'migration 353: shared.tenants, shared.tenant_ai_budget (321) and public.plan_tier_enum must '
                        'exist';
    END IF;
END $$;

-- ── 1. Feature catalogue ────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.entitlement_feature (
    feature_key text NOT NULL,
    product     text NOT NULL,
    value_kind  text NOT NULL,
    unit        text,
    description text NOT NULL,
    created_at  timestamp with time zone NOT NULL DEFAULT now(),
    retired_at  timestamp with time zone,
    CONSTRAINT entitlement_feature_pkey PRIMARY KEY (feature_key),
    CONSTRAINT entitlement_feature_key_check
        CHECK (feature_key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$' AND char_length(feature_key) <= 64),
    CONSTRAINT entitlement_feature_product_check CHECK (product IN ('content', 'crm', 'tripplanner', 'platform')),
    CONSTRAINT entitlement_feature_kind_check CHECK (value_kind IN ('flag', 'limit', 'seats', 'policy')),
    CONSTRAINT entitlement_feature_unit_check
        CHECK ((value_kind = 'flag') = (unit IS NULL)
               AND (unit IS NULL OR unit IN ('count_month', 'usd_month', 'rpm', 'seats', 'days'))
               AND (value_kind <> 'seats' OR unit = 'seats')),
    CONSTRAINT entitlement_feature_description_check CHECK (char_length(description) BETWEEN 1 AND 500)
);
COMMENT ON TABLE shared.entitlement_feature IS
    'AA-1028 R1 (CIS 353, root ADR 0019 d2): the feature keys apps check (never plan names). value_kind flag = on '
    'when entitled; limit / seats / policy carry a number (NULL = no limit). Rows by migration only.';

-- ── 2. Plans ────────────────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.plan (
    plan_key             text NOT NULL,
    product              text NOT NULL,
    name                 text NOT NULL,
    tier                 public.plan_tier_enum,
    price_usd_monthly    numeric(10,2),
    price_unit           text NOT NULL,
    seats_included       integer,
    price_extra_seat_usd numeric(10,2),
    is_public            boolean NOT NULL DEFAULT false,
    version              integer NOT NULL DEFAULT 1,
    membership_plan_id   uuid,
    notes                text,
    created_at           timestamp with time zone NOT NULL DEFAULT now(),
    updated_at           timestamp with time zone NOT NULL DEFAULT now(),
    updated_by           text NOT NULL,
    retired_at           timestamp with time zone,
    CONSTRAINT plan_pkey PRIMARY KEY (plan_key),
    CONSTRAINT plan_key_product_key UNIQUE (plan_key, product),
    CONSTRAINT plan_product_check CHECK (product IN ('content', 'crm', 'tripplanner')),
    CONSTRAINT plan_key_check
        CHECK (plan_key ~ '^[a-z]+\.[a-z][a-z0-9_]*$' AND split_part(plan_key, '.', 1) = product
               AND char_length(plan_key) <= 64),
    CONSTRAINT plan_tier_check CHECK (tier IS NULL OR product = 'content'),
    CONSTRAINT plan_price_check
        CHECK ((price_usd_monthly IS NULL OR price_usd_monthly >= 0)
               AND (price_extra_seat_usd IS NULL OR price_extra_seat_usd >= 0)
               AND (seats_included IS NULL OR seats_included >= 0)),
    CONSTRAINT plan_price_unit_check CHECK (price_unit IN ('tenant', 'seat', 'site')),
    CONSTRAINT plan_version_check CHECK (version >= 1),
    CONSTRAINT plan_text_check
        CHECK (char_length(name) BETWEEN 1 AND 100 AND (notes IS NULL OR char_length(notes) <= 1000)
               AND char_length(updated_by) BETWEEN 1 AND 64)
);
CREATE UNIQUE INDEX IF NOT EXISTS plan_live_content_tier_key
    ON shared.plan (tier) WHERE product = 'content' AND tier IS NOT NULL AND retired_at IS NULL;
COMMENT ON TABLE shared.plan IS
    'AA-1028 R1 (CIS 353, root ADR 0019 d1/d2, b2-b4): one sellable plan per row (content base product; crm per seat '
    'and tripplanner per site as add-ons). Prices are policy data (NULL = contract / not priced yet). A plan is '
    'retired, never deleted. Generalises shared.membership_plans (membership_plan_id: soft link of the content rows).';
COMMENT ON COLUMN shared.plan.tier IS
    'Content plans only: the shared.tenants.plan_tier value this plan stands for (one live content plan per tier).';

-- ── 3. Plan features ────────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.plan_feature (
    plan_key    text NOT NULL,
    feature_key text NOT NULL,
    limit_value numeric(14,2),
    updated_at  timestamp with time zone NOT NULL DEFAULT now(),
    updated_by  text NOT NULL,
    CONSTRAINT plan_feature_pkey PRIMARY KEY (plan_key, feature_key),
    CONSTRAINT plan_feature_plan_key_fkey FOREIGN KEY (plan_key) REFERENCES shared.plan (plan_key) ON DELETE CASCADE,
    CONSTRAINT plan_feature_feature_key_fkey FOREIGN KEY (feature_key) REFERENCES shared.entitlement_feature (feature_key),
    CONSTRAINT plan_feature_limit_check CHECK (limit_value IS NULL OR limit_value >= 0),
    CONSTRAINT plan_feature_actor_check CHECK (char_length(updated_by) BETWEEN 1 AND 64)
);
CREATE INDEX IF NOT EXISTS plan_feature_feature_key_idx ON shared.plan_feature (feature_key);
COMMENT ON TABLE shared.plan_feature IS
    'AA-1028 R1 (CIS 353): the features a plan gives, with their limit (NULL = no limit; a flag has none).';

-- ── 4. Subscriptions ────────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.tenant_subscription (
    subscription_id uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    product         text NOT NULL,
    plan_key        text NOT NULL,
    status          text NOT NULL,
    trial_ends_at   timestamp with time zone,
    paid_through    date,
    billing_ref     text,
    seats           integer,
    started_at      timestamp with time zone NOT NULL DEFAULT now(),
    canceled_at     timestamp with time zone,
    created_at      timestamp with time zone NOT NULL DEFAULT now(),
    updated_at      timestamp with time zone NOT NULL DEFAULT now(),
    updated_by      text NOT NULL,
    CONSTRAINT tenant_subscription_pkey PRIMARY KEY (subscription_id),
    CONSTRAINT tenant_subscription_tenant_product_key UNIQUE (tenant_id, product),
    CONSTRAINT tenant_subscription_tenant_id_fkey FOREIGN KEY (tenant_id)
        REFERENCES shared.tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT tenant_subscription_plan_fkey FOREIGN KEY (plan_key, product) REFERENCES shared.plan (plan_key, product),
    CONSTRAINT tenant_subscription_product_check CHECK (product IN ('content', 'crm', 'tripplanner')),
    CONSTRAINT tenant_subscription_status_check
        CHECK (status IN ('trialing', 'active', 'past_due', 'unpaid', 'canceled', 'paused')),
    CONSTRAINT tenant_subscription_trial_check CHECK (status <> 'trialing' OR trial_ends_at IS NOT NULL),
    CONSTRAINT tenant_subscription_canceled_check CHECK ((status = 'canceled') = (canceled_at IS NOT NULL)),
    CONSTRAINT tenant_subscription_seats_check CHECK (seats IS NULL OR seats >= 1),
    CONSTRAINT tenant_subscription_text_check
        CHECK ((billing_ref IS NULL OR char_length(billing_ref) <= 200) AND char_length(updated_by) BETWEEN 1 AND 64)
);
CREATE INDEX IF NOT EXISTS tenant_subscription_plan_key_idx ON shared.tenant_subscription (plan_key);
COMMENT ON TABLE shared.tenant_subscription IS
    'AA-1028 R1 (CIS 353, root ADR 0019 d1): one subscription per tenant and product (content is the base; crm and '
    'tripplanner need a live content row). Status vocabulary of Stripe; billing v1 is by hand (paid_through, '
    'billing_ref). Every change re-syncs shared.tenant_entitlement and writes subscription.changed.';
COMMENT ON COLUMN shared.tenant_subscription.billing_ref IS
    'The invoice / contract reference finance types (billing v1 by hand). Never served by tenant.entitlements.v1.';

-- ── 5. Overrides ────────────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.tenant_entitlement_override (
    override_id uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL,
    feature_key text NOT NULL,
    limit_value numeric(14,2),
    enabled     boolean NOT NULL DEFAULT true,
    reason      text NOT NULL,
    granted_by  text NOT NULL,
    expires_at  timestamp with time zone,
    created_at  timestamp with time zone NOT NULL DEFAULT now(),
    updated_at  timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT tenant_entitlement_override_pkey PRIMARY KEY (override_id),
    CONSTRAINT tenant_entitlement_override_tenant_feature_key UNIQUE (tenant_id, feature_key),
    CONSTRAINT tenant_entitlement_override_tenant_id_fkey FOREIGN KEY (tenant_id)
        REFERENCES shared.tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT tenant_entitlement_override_feature_key_fkey FOREIGN KEY (feature_key)
        REFERENCES shared.entitlement_feature (feature_key),
    CONSTRAINT tenant_entitlement_override_limit_check CHECK (limit_value IS NULL OR limit_value >= 0),
    CONSTRAINT tenant_entitlement_override_text_check
        CHECK (char_length(reason) BETWEEN 1 AND 500 AND char_length(granted_by) BETWEEN 1 AND 64)
);
COMMENT ON TABLE shared.tenant_entitlement_override IS
    'AA-1028 R1 (CIS 353): a per-tenant exception to the plan (contract terms, a pilot, a support grant): a limit, or '
    'enabled = false to take a plan feature away. An expired row is ignored. Every change re-syncs the tenant.';
COMMENT ON COLUMN shared.tenant_entitlement_override.reason IS
    'Why staff granted it (contract clause, pilot, support case). Business text, never a person''s data.';

-- ── 6. Materialised entitlements ────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.tenant_entitlement (
    tenant_id   uuid NOT NULL,
    feature_key text NOT NULL,
    product     text NOT NULL,
    value_kind  text NOT NULL,
    unit        text,
    limit_value numeric(14,2),
    source      text NOT NULL,
    plan_key    text,
    expires_at  timestamp with time zone,
    resolved_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT tenant_entitlement_pkey PRIMARY KEY (tenant_id, feature_key),
    CONSTRAINT tenant_entitlement_tenant_id_fkey FOREIGN KEY (tenant_id)
        REFERENCES shared.tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT tenant_entitlement_feature_key_fkey FOREIGN KEY (feature_key)
        REFERENCES shared.entitlement_feature (feature_key),
    CONSTRAINT tenant_entitlement_source_check CHECK (source IN ('plan', 'trial', 'override'))
);
COMMENT ON TABLE shared.tenant_entitlement IS
    'AA-1028 R1 (CIS 353, root ADR 0019 d2): the materialised entitlements, one row per tenant and feature key, '
    'written only by shared.tenant_entitlement_sync() from shared.v_tenant_entitlement_resolved. Each change writes '
    'one entitlement.changed event (contract tenant.entitlements.v1).';

-- ── 7. Account event feed ───────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.tenant_account_event (
    seq         bigint GENERATED ALWAYS AS IDENTITY,
    event_id    uuid NOT NULL DEFAULT gen_random_uuid(),
    txid        xid8 NOT NULL DEFAULT pg_current_xact_id(),
    type        text NOT NULL,
    tenant_id   uuid NOT NULL,
    change      jsonb NOT NULL,
    actor       text,
    occurred_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT tenant_account_event_pkey PRIMARY KEY (seq),
    CONSTRAINT tenant_account_event_event_id_key UNIQUE (event_id),
    CONSTRAINT tenant_account_event_type_check
        CHECK (type IN ('account.status_changed', 'subscription.changed', 'entitlement.changed')),
    CONSTRAINT tenant_account_event_change_check CHECK (jsonb_typeof(change) = 'object'),
    CONSTRAINT tenant_account_event_actor_check CHECK (actor IS NULL OR char_length(actor) BETWEEN 1 AND 64)
);
CREATE INDEX IF NOT EXISTS tenant_account_event_feed_idx ON shared.tenant_account_event (txid, seq);
CREATE INDEX IF NOT EXISTS tenant_account_event_tenant_idx ON shared.tenant_account_event (tenant_id, seq);
COMMENT ON TABLE shared.tenant_account_event IS
    'AA-1028 R1 (CIS 353): append-only feed of contract tenant.entitlements.v1 (account.status_changed, '
    'subscription.changed, entitlement.changed), written only through shared.tenant_account_emit(). Kept while the '
    'tenant exists (account audit); deleted with an offboarded tenant by the AA-839 erasure.';
COMMENT ON COLUMN shared.tenant_account_event.actor IS
    'The writer''s label from the transaction setting aa.actor (admin:<id>, migration:355, job:<kind>); never served.';

-- ── Functions ───────────────────────────────────────────────────────────────────────────────────────────────────────

-- True when the tenant has no shared.tenants row or is offboarded (cancelled_at set): the erasure / cascade case.
CREATE OR REPLACE FUNCTION shared.tenant_account_closed(p_tenant uuid) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path = pg_catalog, shared
AS $$
    SELECT NOT EXISTS (SELECT 1 FROM shared.tenants t WHERE t.tenant_id = p_tenant AND t.cancelled_at IS NULL)
$$;

-- The only writer of shared.tenant_account_event.
CREATE OR REPLACE FUNCTION shared.tenant_account_emit(p_type text, p_tenant uuid, p_change jsonb) RETURNS void
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
BEGIN
    PERFORM set_config('aa.tenant_account_emit', 'on', true);
    INSERT INTO shared.tenant_account_event (type, tenant_id, change, actor)
    VALUES (p_type, p_tenant, p_change, left(NULLIF(current_setting('aa.actor', true), ''), 64));
    PERFORM set_config('aa.tenant_account_emit', '', true);
END
$$;

CREATE OR REPLACE FUNCTION shared.tenant_account_event_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
BEGIN
    IF TG_OP = 'TRUNCATE' THEN
        RAISE EXCEPTION 'shared.tenant_account_event is append-only: TRUNCATE refused' USING ERRCODE = 'restrict_violation';
    ELSIF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'shared.tenant_account_event is append-only: UPDATE refused' USING ERRCODE = 'restrict_violation';
    ELSIF TG_OP = 'INSERT' THEN
        IF current_setting('aa.tenant_account_emit', true) IS DISTINCT FROM 'on' THEN
            RAISE EXCEPTION 'shared.tenant_account_event is written only by shared.tenant_account_emit()'
                USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
    END IF;
    -- DELETE: only the rows of an offboarded or deleted tenant (AA-839 erasure, DM-7.1 row).
    IF NOT shared.tenant_account_closed(OLD.tenant_id) THEN
        RAISE EXCEPTION 'shared.tenant_account_event: an event of a live tenant is never deleted'
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN OLD;
END
$$;

CREATE OR REPLACE FUNCTION shared.tenant_entitlement_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
BEGIN
    IF current_setting('aa.tenant_entitlement_sync', true) = 'on' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'DELETE' AND shared.tenant_account_closed(OLD.tenant_id) THEN
        RETURN OLD;     -- the erasure of an offboarded tenant, or the FK cascade of a deleted one
    END IF;
    RAISE EXCEPTION 'shared.tenant_entitlement is written only by shared.tenant_entitlement_sync()'
        USING ERRCODE = 'restrict_violation';
END
$$;

CREATE OR REPLACE FUNCTION shared.plan_feature_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
DECLARE
    f_product text;
    f_kind    text;
    p_product text;
BEGIN
    SELECT f.product, f.value_kind INTO f_product, f_kind FROM shared.entitlement_feature f
     WHERE f.feature_key = NEW.feature_key;
    SELECT p.product INTO p_product FROM shared.plan p WHERE p.plan_key = NEW.plan_key;
    IF f_product IS NULL OR p_product IS NULL THEN
        RETURN NEW;     -- the FKs report the missing key
    END IF;
    IF f_product <> 'platform' AND f_product <> p_product THEN
        RAISE EXCEPTION 'plan_feature: % is a % feature, plan % is %', NEW.feature_key, f_product, NEW.plan_key,
                        p_product USING ERRCODE = 'check_violation';
    END IF;
    IF f_kind = 'flag' AND NEW.limit_value IS NOT NULL THEN
        RAISE EXCEPTION 'plan_feature: % is a flag and takes no limit', NEW.feature_key USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION shared.tenant_subscription_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
DECLARE
    live constant text[] := ARRAY['trialing', 'active', 'past_due'];
BEGIN
    IF TG_OP = 'UPDATE' AND (NEW.tenant_id IS DISTINCT FROM OLD.tenant_id OR NEW.product IS DISTINCT FROM OLD.product) THEN
        RAISE EXCEPTION 'tenant_subscription: tenant_id and product never change' USING ERRCODE = 'restrict_violation';
    END IF;
    IF (TG_OP = 'INSERT' OR NEW.plan_key IS DISTINCT FROM OLD.plan_key)
       AND EXISTS (SELECT 1 FROM shared.plan p WHERE p.plan_key = NEW.plan_key AND p.retired_at IS NOT NULL) THEN
        RAISE EXCEPTION 'tenant_subscription: plan % is retired', NEW.plan_key USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.product <> 'content' AND NEW.status = ANY (live)
       AND NOT EXISTS (SELECT 1 FROM shared.tenant_subscription c
                        WHERE c.tenant_id = NEW.tenant_id AND c.product = 'content' AND c.status = ANY (live)) THEN
        RAISE EXCEPTION 'tenant_subscription: the % add-on needs a live content subscription', NEW.product
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.product = 'content' AND NOT (NEW.status = ANY (live))
       AND EXISTS (SELECT 1 FROM shared.tenant_subscription a
                    WHERE a.tenant_id = NEW.tenant_id AND a.product <> 'content' AND a.status = ANY (live)) THEN
        RAISE EXCEPTION 'tenant_subscription: end the live add-ons before the content subscription leaves %',
                        array_to_string(live, ', ') USING ERRCODE = 'check_violation';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        NEW.updated_at := now();
    END IF;
    RETURN NEW;
END
$$;

-- ── 8. The resolver ─────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW shared.v_tenant_entitlement_resolved AS
WITH live_sub AS (
    SELECT s.tenant_id, s.product, s.plan_key, s.status, s.trial_ends_at, s.seats
      FROM shared.tenant_subscription s
     WHERE s.status IN ('trialing', 'active', 'past_due')
),
candidate AS (
    SELECT o.tenant_id, o.feature_key, o.limit_value, o.enabled, 'override'::text AS source, NULL::text AS plan_key,
           o.expires_at, 1 AS rank
      FROM shared.tenant_entitlement_override o
     WHERE o.expires_at IS NULL OR o.expires_at > now()
    UNION ALL
    -- AA-1016's per-tenant AI budget acts as the override of ai.budget_usd_monthly until slice 3 retires the table.
    SELECT b.tenant_id, 'ai.budget_usd_monthly'::text, b.monthly_usd::numeric(14,2), true, 'override'::text,
           NULL::text, NULL::timestamp with time zone, 2
      FROM shared.tenant_ai_budget b
    UNION ALL
    SELECT ls.tenant_id, pf.feature_key,
           CASE WHEN f.value_kind = 'seats' THEN coalesce(ls.seats::numeric(14,2), pf.limit_value)
                ELSE pf.limit_value END,
           true,
           CASE WHEN ls.status = 'trialing' THEN 'trial' ELSE 'plan' END,
           ls.plan_key,
           CASE WHEN ls.status = 'trialing' THEN ls.trial_ends_at END,
           3
      FROM live_sub ls
      JOIN shared.plan_feature pf ON pf.plan_key = ls.plan_key
      JOIN shared.entitlement_feature f ON f.feature_key = pf.feature_key
),
ranked AS (
    SELECT c.tenant_id, c.feature_key, c.limit_value, c.enabled, c.source, c.plan_key, c.expires_at,
           f.product, f.value_kind, f.unit,
           row_number() OVER (PARTITION BY c.tenant_id, c.feature_key ORDER BY c.rank) AS rn
      FROM candidate c
      JOIN shared.entitlement_feature f ON f.feature_key = c.feature_key
     WHERE f.retired_at IS NULL
       AND (c.rank = 3 OR f.product = 'platform'
            OR EXISTS (SELECT 1 FROM live_sub ls WHERE ls.tenant_id = c.tenant_id AND ls.product = f.product))
)
SELECT r.tenant_id, r.feature_key, r.product, r.value_kind, r.unit,
       CASE WHEN r.value_kind = 'flag' THEN NULL ELSE r.limit_value END AS limit_value,
       r.source, r.plan_key, r.expires_at
  FROM ranked r
 WHERE r.rn = 1 AND r.enabled;
COMMENT ON VIEW shared.v_tenant_entitlement_resolved IS
    'AA-1028 R1 (CIS 353): the resolver, computed live: override (unexpired) > shared.tenant_ai_budget (as the '
    'ai.budget_usd_monthly override) > the plan of a live subscription (trial while trialing). Internal: the contract '
    'view is shared.v_tenant_entitlement_v1 (355).';

-- ── 9. Materialisation ──────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION shared.tenant_entitlement_sync(p_tenant uuid) RETURNS integer
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
DECLARE
    r record;
    n integer := 0;
BEGIN
    IF p_tenant IS NULL OR NOT EXISTS (SELECT 1 FROM shared.tenants t WHERE t.tenant_id = p_tenant) THEN
        RETURN 0;
    END IF;
    PERFORM pg_advisory_xact_lock(1028, hashtext(p_tenant::text));
    PERFORM set_config('aa.tenant_entitlement_sync', 'on', true);
    FOR r IN
        SELECT coalesce(w.feature_key, h.feature_key) AS feature_key,
               w.feature_key IS NULL AS removed, h.feature_key IS NULL AS added,
               coalesce(w.product, h.product) AS product, w.value_kind, w.unit, w.limit_value, w.source, w.plan_key,
               w.expires_at
          FROM (SELECT * FROM shared.v_tenant_entitlement_resolved v WHERE v.tenant_id = p_tenant) w
          FULL JOIN (SELECT * FROM shared.tenant_entitlement e WHERE e.tenant_id = p_tenant) h
            ON h.feature_key = w.feature_key
         WHERE w.feature_key IS NULL OR h.feature_key IS NULL
            OR w.limit_value IS DISTINCT FROM h.limit_value OR w.source IS DISTINCT FROM h.source
            OR w.plan_key IS DISTINCT FROM h.plan_key OR w.expires_at IS DISTINCT FROM h.expires_at
            OR w.value_kind IS DISTINCT FROM h.value_kind OR w.unit IS DISTINCT FROM h.unit
         ORDER BY 1
    LOOP
        IF r.removed THEN
            DELETE FROM shared.tenant_entitlement e WHERE e.tenant_id = p_tenant AND e.feature_key = r.feature_key;
        ELSE
            INSERT INTO shared.tenant_entitlement AS e
                   (tenant_id, feature_key, product, value_kind, unit, limit_value, source, plan_key, expires_at,
                    resolved_at)
            VALUES (p_tenant, r.feature_key, r.product, r.value_kind, r.unit, r.limit_value, r.source, r.plan_key,
                    r.expires_at, now())
            ON CONFLICT (tenant_id, feature_key) DO UPDATE
               SET product = EXCLUDED.product, value_kind = EXCLUDED.value_kind, unit = EXCLUDED.unit,
                   limit_value = EXCLUDED.limit_value, source = EXCLUDED.source, plan_key = EXCLUDED.plan_key,
                   expires_at = EXCLUDED.expires_at, resolved_at = EXCLUDED.resolved_at;
        END IF;
        PERFORM shared.tenant_account_emit('entitlement.changed', p_tenant, jsonb_build_object(
            'op', CASE WHEN r.removed THEN 'removed' WHEN r.added THEN 'added' ELSE 'updated' END,
            'feature_key', r.feature_key,
            'product', r.product,
            'limit', CASE WHEN r.removed THEN NULL ELSE r.limit_value::text END,
            'source', CASE WHEN r.removed THEN NULL ELSE r.source END,
            'expires_at', CASE WHEN r.removed OR r.expires_at IS NULL THEN NULL
                               ELSE to_char(r.expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END));
        n := n + 1;
    END LOOP;
    PERFORM set_config('aa.tenant_entitlement_sync', '', true);
    RETURN n;
END
$$;

CREATE OR REPLACE FUNCTION shared.tenant_entitlement_sync_due() RETURNS integer
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
DECLARE
    t uuid;
    n integer := 0;
BEGIN
    FOR t IN SELECT DISTINCT e.tenant_id FROM shared.tenant_entitlement e
              WHERE e.expires_at IS NOT NULL AND e.expires_at <= now() ORDER BY 1
    LOOP
        n := n + shared.tenant_entitlement_sync(t);
    END LOOP;
    RETURN n;
END
$$;

-- ── 10. Triggers of the new tables ──────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION shared.tenant_subscription_changed() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
DECLARE
    rec shared.tenant_subscription;
BEGIN
    IF TG_OP = 'DELETE' THEN
        rec := OLD;
        IF shared.tenant_account_closed(OLD.tenant_id) THEN
            RETURN NULL;    -- erasure or FK cascade: nothing to tell, nothing to resolve
        END IF;
    ELSE
        rec := NEW;
    END IF;
    PERFORM shared.tenant_account_emit('subscription.changed', rec.tenant_id, jsonb_build_object(
        'op', CASE TG_OP WHEN 'INSERT' THEN 'created' WHEN 'UPDATE' THEN 'updated' ELSE 'deleted' END,
        'product', rec.product,
        'plan_key', rec.plan_key,
        'status', rec.status,
        'previous_status', CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END,
        'previous_plan_key', CASE WHEN TG_OP = 'UPDATE' AND OLD.plan_key IS DISTINCT FROM NEW.plan_key
                                  THEN OLD.plan_key END,
        'seats', rec.seats,
        'trial_ends_at', CASE WHEN rec.trial_ends_at IS NULL THEN NULL
                              ELSE to_char(rec.trial_ends_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END));
    PERFORM shared.tenant_entitlement_sync(rec.tenant_id);
    RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION shared.tenant_entitlement_resync_row() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF NOT shared.tenant_account_closed(OLD.tenant_id) THEN
            PERFORM shared.tenant_entitlement_sync(OLD.tenant_id);
        END IF;
    ELSE
        PERFORM shared.tenant_entitlement_sync(NEW.tenant_id);
    END IF;
    RETURN NULL;
END
$$;

-- Shared by the plan_feature and entitlement_feature triggers. Each branch names only the fields of its own table:
-- PL/pgSQL resolves OLD.x / NEW.x against the firing table's row type at run time, so a query that names
-- OLD.plan_key raises "record old has no field plan_key" when entitlement_feature fires it, even behind a
-- TG_TABLE_NAME test in the same WHERE clause.
CREATE OR REPLACE FUNCTION shared.tenant_entitlement_resync_plan() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
DECLARE
    t      uuid;
    p_old  text;
    p_new  text;
    f_key  text;
BEGIN
    IF TG_TABLE_NAME = 'plan_feature' THEN
        IF TG_OP <> 'INSERT' THEN p_old := OLD.plan_key; END IF;
        IF TG_OP <> 'DELETE' THEN p_new := NEW.plan_key; END IF;
        FOR t IN SELECT DISTINCT s.tenant_id FROM shared.tenant_subscription s
                  WHERE s.plan_key IN (p_old, p_new) ORDER BY 1
        LOOP
            PERFORM shared.tenant_entitlement_sync(t);
        END LOOP;
    ELSE
        -- entitlement_feature: AFTER UPDATE only (retired_at, value_kind, unit, product)
        f_key := NEW.feature_key;
        FOR t IN SELECT DISTINCT s.tenant_id FROM shared.tenant_subscription s
                  WHERE EXISTS (SELECT 1 FROM shared.plan_feature pf
                                 WHERE pf.plan_key = s.plan_key AND pf.feature_key = f_key)
                 UNION
                 SELECT o.tenant_id FROM shared.tenant_entitlement_override o WHERE o.feature_key = f_key
                 UNION
                 SELECT e.tenant_id FROM shared.tenant_entitlement e WHERE e.feature_key = f_key
                 ORDER BY 1
        LOOP
            PERFORM shared.tenant_entitlement_sync(t);
        END LOOP;
    END IF;
    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS tenant_account_event_guard ON shared.tenant_account_event;
CREATE TRIGGER tenant_account_event_guard
    BEFORE INSERT OR UPDATE OR DELETE ON shared.tenant_account_event
    FOR EACH ROW EXECUTE FUNCTION shared.tenant_account_event_guard();
DROP TRIGGER IF EXISTS tenant_account_event_no_truncate ON shared.tenant_account_event;
CREATE TRIGGER tenant_account_event_no_truncate
    BEFORE TRUNCATE ON shared.tenant_account_event
    FOR EACH STATEMENT EXECUTE FUNCTION shared.tenant_account_event_guard();

DROP TRIGGER IF EXISTS tenant_entitlement_guard ON shared.tenant_entitlement;
CREATE TRIGGER tenant_entitlement_guard
    BEFORE INSERT OR UPDATE OR DELETE ON shared.tenant_entitlement
    FOR EACH ROW EXECUTE FUNCTION shared.tenant_entitlement_guard();

DROP TRIGGER IF EXISTS plan_feature_guard ON shared.plan_feature;
CREATE TRIGGER plan_feature_guard
    BEFORE INSERT OR UPDATE ON shared.plan_feature
    FOR EACH ROW EXECUTE FUNCTION shared.plan_feature_guard();
DROP TRIGGER IF EXISTS plan_feature_resync ON shared.plan_feature;
CREATE TRIGGER plan_feature_resync
    AFTER INSERT OR UPDATE OR DELETE ON shared.plan_feature
    FOR EACH ROW EXECUTE FUNCTION shared.tenant_entitlement_resync_plan();

DROP TRIGGER IF EXISTS entitlement_feature_resync ON shared.entitlement_feature;
CREATE TRIGGER entitlement_feature_resync
    AFTER UPDATE OF retired_at, value_kind, unit, product ON shared.entitlement_feature
    FOR EACH ROW EXECUTE FUNCTION shared.tenant_entitlement_resync_plan();

DROP TRIGGER IF EXISTS tenant_subscription_guard ON shared.tenant_subscription;
CREATE TRIGGER tenant_subscription_guard
    BEFORE INSERT OR UPDATE ON shared.tenant_subscription
    FOR EACH ROW EXECUTE FUNCTION shared.tenant_subscription_guard();
DROP TRIGGER IF EXISTS tenant_subscription_changed_ins_del ON shared.tenant_subscription;
CREATE TRIGGER tenant_subscription_changed_ins_del
    AFTER INSERT OR DELETE ON shared.tenant_subscription
    FOR EACH ROW EXECUTE FUNCTION shared.tenant_subscription_changed();
DROP TRIGGER IF EXISTS tenant_subscription_changed_upd ON shared.tenant_subscription;
CREATE TRIGGER tenant_subscription_changed_upd
    AFTER UPDATE ON shared.tenant_subscription
    FOR EACH ROW
    WHEN (OLD.plan_key IS DISTINCT FROM NEW.plan_key OR OLD.status IS DISTINCT FROM NEW.status
          OR OLD.seats IS DISTINCT FROM NEW.seats OR OLD.trial_ends_at IS DISTINCT FROM NEW.trial_ends_at)
    EXECUTE FUNCTION shared.tenant_subscription_changed();

DROP TRIGGER IF EXISTS tenant_entitlement_override_resync ON shared.tenant_entitlement_override;
CREATE TRIGGER tenant_entitlement_override_resync
    AFTER INSERT OR UPDATE OR DELETE ON shared.tenant_entitlement_override
    FOR EACH ROW EXECUTE FUNCTION shared.tenant_entitlement_resync_row();

-- ── 11. Grants ──────────────────────────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON shared.entitlement_feature, shared.plan, shared.plan_feature, shared.tenant_subscription,
              shared.tenant_entitlement_override, shared.tenant_entitlement, shared.tenant_account_event,
              shared.v_tenant_entitlement_resolved
    FROM PUBLIC, cis_app, aa_app_user, catalog_owner;
-- An identity column's nextval does not check sequence privileges: nobody needs a right on the sequence.
REVOKE ALL ON SEQUENCE shared.tenant_account_event_seq_seq FROM PUBLIC, cis_app, aa_app_user, catalog_owner;
GRANT SELECT ON shared.entitlement_feature, shared.v_tenant_entitlement_resolved TO cis_app;
GRANT SELECT, INSERT, UPDATE ON shared.plan TO cis_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.plan_feature, shared.tenant_subscription,
                                        shared.tenant_entitlement_override, shared.tenant_entitlement TO cis_app;
GRANT SELECT, INSERT, DELETE ON shared.tenant_account_event TO cis_app;

REVOKE ALL ON FUNCTION shared.tenant_account_closed(uuid), shared.tenant_account_emit(text, uuid, jsonb),
                       shared.tenant_account_event_guard(), shared.tenant_entitlement_guard(),
                       shared.plan_feature_guard(), shared.tenant_subscription_guard(),
                       shared.tenant_entitlement_sync(uuid), shared.tenant_entitlement_sync_due(),
                       shared.tenant_subscription_changed(), shared.tenant_entitlement_resync_row(),
                       shared.tenant_entitlement_resync_plan()
    FROM PUBLIC;
-- The functions the triggers call run as the writer (cis_app); the two sync entry points are also called by code.
GRANT EXECUTE ON FUNCTION shared.tenant_account_closed(uuid), shared.tenant_account_emit(text, uuid, jsonb),
                          shared.tenant_entitlement_sync(uuid), shared.tenant_entitlement_sync_due() TO cis_app;

-- ── Guard 2: the objects as this file leaves them ───────────────────────────────────────────────────────────────────
DO $$
DECLARE
    bad text;
BEGIN
    SELECT string_agg(p.proname, ', ') INTO bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'shared'
       AND p.proname IN ('tenant_account_closed', 'tenant_account_emit', 'tenant_account_event_guard',
                         'tenant_entitlement_guard', 'plan_feature_guard', 'tenant_subscription_guard',
                         'tenant_entitlement_sync', 'tenant_entitlement_sync_due', 'tenant_subscription_changed',
                         'tenant_entitlement_resync_row', 'tenant_entitlement_resync_plan')
       AND (p.prosecdef OR p.proconfig IS NULL OR NOT EXISTS (
                SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%')
            OR has_function_privilege('public', p.oid, 'EXECUTE'));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 353: functions must be SECURITY INVOKER, pin search_path and give PUBLIC no '
                        'EXECUTE: %', bad;
    END IF;
    SELECT string_agg(c, ', ') INTO bad
      FROM unnest(ARRAY['shared.entitlement_feature', 'shared.plan', 'shared.plan_feature',
                        'shared.tenant_subscription', 'shared.tenant_entitlement_override',
                        'shared.tenant_entitlement', 'shared.tenant_account_event',
                        'shared.v_tenant_entitlement_resolved']) AS c
     WHERE has_table_privilege('aa_app_user', c, 'SELECT') OR has_table_privilege('catalog_owner', c, 'SELECT')
        OR NOT has_table_privilege('cis_app', c, 'SELECT');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 353: grants not as designed on %', bad;
    END IF;
    IF has_table_privilege('cis_app', 'shared.tenant_account_event', 'UPDATE')
       OR has_table_privilege('cis_app', 'shared.entitlement_feature', 'INSERT')
       OR has_table_privilege('cis_app', 'shared.plan', 'DELETE') THEN
        RAISE EXCEPTION 'migration 353: cis_app holds a write this file does not grant';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('353', now(), 'AA-1028 R1: tenant control plane tables (plans, subscriptions, entitlements, account events)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
