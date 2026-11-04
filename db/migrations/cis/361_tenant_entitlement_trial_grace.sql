-- Migration 361: AA-1028 R1 slice 3 (root ADR 0019 d1, d2) — resolver fixes from the S266 review of slice 3: an ended
-- trial stays live until the tenant_account_tick moves it (no gap in which the AI budget fails open), and a platform
-- key is taken only from the content plan (a deterministic winner).
--
-- Why.
--   * 356 made a trialing subscription live only while trial_ends_at > now(), because nothing ended a trial then.
--     Slice 3 adds the hourly tenant_account_tick (services/tenant_account/lifecycle.py), which moves an ended trial
--     to active (paid) or past_due (the grace state, still live). Between trial_ends_at and that tick (up to an hour
--     plus the queue) the tenant had no live subscription at all: the resolver served it no key, so the gateway read
--     no ai.budget_usd_monthly and a saga-made trial tenant (no AA-1016 shared.tenant_ai_budget row) ran its T-stage
--     and adhoc AI calls with no budget (fail open), and the tenant.entitlements.v1 snapshot showed every add-on gone
--     for that hour. The tick's next state is always live (active or past_due), so the resolver now treats an ended
--     trialing row as live until the tick moves it: nothing changes at trial_ends_at, everything follows the tick.
--     The rows keep source trial and expires_at = trial_ends_at (now in the past) until then, so a consumer that
--     honours expires_at stops at the trial end while CIS keeps the plan's limits; the tick's subscription update
--     re-syncs them (source plan, expires_at cleared) through the 353 trigger.
--   * The 356 resolver ranked every live subscription's plan_feature rows at rank 3 and picked with row_number()
--     ORDER BY rank only. A platform key (ai.budget_usd_monthly, policy.notice_days) on an add-on plan (crm,
--     tripplanner) as well as on the content plan gave an arbitrary winner. Platform keys now come from the content
--     plan only (the Plans API refuses them on add-on plans, services/tenant_account/plans.py), and the order ends
--     with the plan key so a tie is always broken the same way.
--
-- What.
--   1. CREATE OR REPLACE VIEW shared.v_tenant_entitlement_resolved, same columns as 356: (a) live_sub takes every
--      trialing row (the 353 rule; 356's trial_ends_at cut removed); (b) a plan candidate (rank 3) of a platform key
--      needs the plan to be the tenant's content subscription; (c) ORDER BY rank, plan_key.
--   2. Re-sync every tenant (shared.tenant_entitlement_sync): a trialing tenant past its trial_ends_at gets its keys
--      back (entitlement.changed, actor migration:361). Dev today: no saga trial has been made (the saga refused
--      trial_days until slice 3), so the expected count is 0.
--   3. Guards: the materialisation equals the resolver; no tenant without a live content subscription (361's rule)
--      keeps a platform key; no platform key is served from a non-content plan.
--   4. Register 361.
--
-- Behaviour. The resolver changes only for a trialing subscription past its end (live until the tick) and a platform
-- key on an add-on plan (none on Dev: the 355 seed puts ai.budget_usd_monthly and policy.notice_days on content plans
-- only). Code: shared/cost_guard.py also falls back to the content subscription plan's ai.budget_usd_monthly when no
-- key resolves, so the AI budget never reads as unlimited whether this file is applied or not (MIG-4: no code waits
-- for it). services/tenant_account/subscription.py LIVE_PRODUCT_SQL (the informational "applies" of an override)
-- still uses 356's rule; for an ended trial waiting for the tick it says false for at most that hour.
--
-- Class: contract (CREATE OR REPLACE of an existing view, writes rows through the sync). It ships in its own
-- migration-only PR ahead of the slice 3 code PR (MIG-4 order, root ADR 0017) with no readiness raise
-- (REQUIRED_CIS_SCHEMA stays): no code waits for it and Deploy Dev's schema gate does not either. On Dev a person
-- applies it with DB Migrate apply (every job table idle, DM-11.4), as 353-357. The code that reads the trial
-- grace (the hourly tick, the cost_guard plan fallback) is correct before and after it.
--
-- Number. 361 = main's max (360, AA-1039 content compliance, merged) + 1 when renumbered (S266); first written as
-- 360 before AA-1039 merged.
--
-- Rollback (a NEW forward migration): restate 356's view; SELECT shared.tenant_entitlement_sync(tenant_id) FROM
-- shared.tenants.
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of shared.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical. After
-- apply: the DB Schema Dump bot PR regenerates docs/architecture/db-schema-reference.md.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('aa.actor', 'migration:361', true);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '356') THEN
        RAISE EXCEPTION 'migration 361: apply 356 first';
    END IF;
END $$;

-- ── 1. The resolver ─────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW shared.v_tenant_entitlement_resolved AS
WITH live_sub AS (
    -- 361: a trialing row stays live past trial_ends_at until the tenant_account_tick moves it (to active or
    -- past_due, both live): no gap between the trial end and the tick
    SELECT s.tenant_id, s.product, s.plan_key, s.status, s.trial_ends_at, s.seats
      FROM shared.tenant_subscription s
     WHERE s.status IN ('trialing', 'active', 'past_due')
),
candidate AS (
    -- 356: the limiter's per-tenant RPM (shared.tenants.rate_limit_rpm) when it differs from the live content plan.
    SELECT t.tenant_id, 'content.rate_limit_rpm'::text AS feature_key, t.rate_limit_rpm::numeric(14,2) AS limit_value,
           true AS enabled, 'override'::text AS source, NULL::text AS plan_key,
           NULL::timestamp with time zone AS expires_at, 0 AS rank, NULL::text AS sub_product
      FROM shared.tenants t
      JOIN live_sub ls ON ls.tenant_id = t.tenant_id AND ls.product = 'content'
      LEFT JOIN shared.plan_feature pf ON pf.plan_key = ls.plan_key AND pf.feature_key = 'content.rate_limit_rpm'
     WHERE pf.limit_value IS DISTINCT FROM t.rate_limit_rpm::numeric(14,2)
    UNION ALL
    SELECT o.tenant_id, o.feature_key, o.limit_value, o.enabled, 'override'::text, NULL::text, o.expires_at, 1,
           NULL::text
      FROM shared.tenant_entitlement_override o
     WHERE o.expires_at IS NULL OR o.expires_at > now()
    UNION ALL
    -- AA-1016's per-tenant AI budget acts as the override of ai.budget_usd_monthly until it is retired.
    SELECT b.tenant_id, 'ai.budget_usd_monthly'::text, b.monthly_usd::numeric(14,2), true, 'override'::text,
           NULL::text, NULL::timestamp with time zone, 2, NULL::text
      FROM shared.tenant_ai_budget b
    UNION ALL
    SELECT ls.tenant_id, pf.feature_key,
           CASE WHEN f.value_kind = 'seats' THEN coalesce(ls.seats::numeric(14,2), pf.limit_value)
                ELSE pf.limit_value END,
           true,
           CASE WHEN ls.status = 'trialing' THEN 'trial' ELSE 'plan' END,
           ls.plan_key,
           CASE WHEN ls.status = 'trialing' THEN ls.trial_ends_at END,
           3,
           ls.product
      FROM live_sub ls
      JOIN shared.plan_feature pf ON pf.plan_key = ls.plan_key
      JOIN shared.entitlement_feature f ON f.feature_key = pf.feature_key
),
ranked AS (
    SELECT c.tenant_id, c.feature_key, c.limit_value, c.enabled, c.source, c.plan_key, c.expires_at,
           f.product, f.value_kind, f.unit,
           row_number() OVER (PARTITION BY c.tenant_id, c.feature_key ORDER BY c.rank, c.plan_key) AS rn
      FROM candidate c
      JOIN shared.entitlement_feature f ON f.feature_key = c.feature_key
     WHERE f.retired_at IS NULL
       -- a candidate that is not the plan's own needs a live subscription of the key's product; a platform key's
       -- product is content (356)
       AND (c.rank = 3
            OR EXISTS (SELECT 1 FROM live_sub ls
                        WHERE ls.tenant_id = c.tenant_id
                          AND ls.product = CASE WHEN f.product = 'platform' THEN 'content' ELSE f.product END))
       -- 361: a plan's platform key counts only from the content plan
       AND (c.rank <> 3 OR f.product <> 'platform' OR c.sub_product = 'content')
)
SELECT r.tenant_id, r.feature_key, r.product, r.value_kind, r.unit,
       CASE WHEN r.value_kind = 'flag' THEN NULL ELSE r.limit_value END AS limit_value,
       r.source, r.plan_key, r.expires_at
  FROM ranked r
 WHERE r.rn = 1 AND r.enabled;
COMMENT ON VIEW shared.v_tenant_entitlement_resolved IS
    'AA-1028 R1 (CIS 353, 356, 361): the resolver, computed live: shared.tenants.rate_limit_rpm when it differs from '
    'the content plan (the limiter''s value, 356) > override (unexpired) > shared.tenant_ai_budget (as the '
    'ai.budget_usd_monthly override) > the plan of a live subscription (trialing, active, past_due; a trial past '
    'trial_ends_at stays live until the tenant_account_tick moves it, 361; a platform key only from the content plan, '
    '361). A non-plan candidate needs a live subscription of its product (content for platform keys, 356). Internal: '
    'the contract view is shared.v_tenant_entitlement_v1 (355).';

-- ── 2. Re-sync every tenant ─────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    before_n bigint;
    changed  bigint := 0;
    t        record;
BEGIN
    SELECT count(*) INTO before_n FROM shared.tenant_account_event WHERE type = 'entitlement.changed';
    FOR t IN SELECT tenant_id FROM shared.tenants ORDER BY created_at, tenant_id LOOP
        changed := changed + shared.tenant_entitlement_sync(t.tenant_id);
    END LOOP;
    RAISE NOTICE 'migration 361: re-sync changed % entitlement row(s) (% entitlement.changed event(s))', changed,
        (SELECT count(*) FROM shared.tenant_account_event WHERE type = 'entitlement.changed') - before_n;
END $$;

-- ── 3. Guards ───────────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    n bigint;
BEGIN
    -- The materialisation equals the resolver after the re-sync.
    SELECT count(*) INTO n
      FROM shared.v_tenant_entitlement_resolved r
      FULL JOIN shared.tenant_entitlement e ON e.tenant_id = r.tenant_id AND e.feature_key = r.feature_key
     WHERE r.feature_key IS NULL OR e.feature_key IS NULL OR r.limit_value IS DISTINCT FROM e.limit_value
        OR r.source IS DISTINCT FROM e.source;
    IF n > 0 THEN
        RAISE EXCEPTION 'migration 361: % materialised row(s) differ from the resolver', n;
    END IF;
    -- No tenant without a live content subscription keeps a platform key (live: trialing, active, past_due).
    SELECT count(*) INTO n
      FROM shared.tenant_entitlement e
      JOIN shared.entitlement_feature f ON f.feature_key = e.feature_key AND f.product = 'platform'
     WHERE NOT EXISTS (SELECT 1 FROM shared.tenant_subscription s
                        WHERE s.tenant_id = e.tenant_id AND s.product = 'content'
                          AND s.status IN ('trialing', 'active', 'past_due'));
    IF n > 0 THEN
        RAISE EXCEPTION 'migration 361: % platform entitlement(s) without a live content subscription', n;
    END IF;
    -- A platform key served from a plan is the content plan's.
    SELECT count(*) INTO n
      FROM shared.v_tenant_entitlement_resolved r
      JOIN shared.plan p ON p.plan_key = r.plan_key
     WHERE r.product = 'platform' AND r.source IN ('plan', 'trial') AND p.product <> 'content';
    IF n > 0 THEN
        RAISE EXCEPTION 'migration 361: % platform entitlement(s) served from an add-on plan', n;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('361', now(), 'AA-1028 R1 slice 3: resolver keeps an ended trial live until the tenant_account_tick, '
                      'platform keys from the content plan only, deterministic tie-break')
ON CONFLICT (version) DO NOTHING;

COMMIT;
