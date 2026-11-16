-- Migration 438: AA-1116 (S282) — the option B billing terms reach Booking and TripPlanner through their catalog
-- contract views (contract tenant.entitlements.v1 1.9; columns are only appended).
--
-- Why. Booking drafts the monthly software invoice from catalog.v_tenant_billing_v1 (377) and TripPlanner enforces its
-- AI budget from catalog.v_tenant_ai_budget_v1 (390) and serves the site from catalog.v_tenant_tripplanner_v1 (429).
-- Option B needs Booking to see the agency's currency, the VND list, the seat minimum, an agreed / locked price, the
-- billing interval, the trial end and the free pilot; and TripPlanner
-- to see its AI sessions a month (tp.ai_sessions) and the alert / stop shares (80 / 100 % from the settings registry,
-- not a literal 100).
--
-- What:
--   1. catalog_owner column SELECTs: shared.tenants (billing_currency, is_pilot), shared.tenant_subscription
--      (billing_interval, agreed_price_monthly, agreed_currency, agreed_until, trial_ends_at), shared.plan
--      (price_vnd_monthly, price_extra_seat_vnd, seats_min), shared.tenant_ai_budget (tenant_id, alert_pct,
--      approval_pct, hard_stop).
--   2. catalog.v_tenant_billing_v1 (Booking only) appends: billing_currency, price_vnd_monthly, price_extra_seat_vnd,
--      seats_min, agreed_price_monthly, agreed_currency, agreed_until, billing_interval, trial_ends_at, is_pilot,
--      bill_free (is_pilot AND cis.billing.pilot_free). Same rows as 377 (one per tenant and subscription; no retail
--      add-on rows: S282 decision 14), so a reader that knows only the 377 columns keeps its rows unchanged.
--      agreed_price_monthly is the agreed price per billed unit (per seat on a per-seat plan, as price_usd_monthly):
--      the line amount is agreed_price_monthly x max(seats, seats_min) for a seat plan (435 column comment).
--   3. catalog.v_tenant_ai_budget_v1 (TripPlanner only) appends alert_pct, approval_pct, hard_stop (the tenant's
--      AA-1016 row, else cis.billing.ai_alert_pct_default / ai_approval_pct_default / ai_hard_stop_default).
--   4. catalog.v_tenant_tripplanner_v1 (TripPlanner only) appends ai_sessions_monthly (resolved tp.ai_sessions,
--      NULL = no limit).
--   5. Register 438.
--
-- Behaviour on apply. Same rows in every view; the new columns are NULL / defaulted until staff enter values.
-- Booking's draft code reads columns by name (the AA-1116 Booking lane adds the new columns); TripPlanner reads the new
-- columns only after its AA-1116 lane.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): column GRANTs on existing tables, replaced
-- views in the hot schema catalog (the catalog.* recipe). MIG-4: AA-1116 migration-only PR (435-439, one batch),
-- applied on Dev by Infra Migration Apply when every job table is idle (ADR 0017a).
--
-- Recipe. The X1 S22 catalog recipe (as 377 / 390 / 429): the grants as cis_owner, then GRANT CREATE ON SCHEMA catalog
-- TO catalog_owner; SET LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate
-- runs the file as cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER here (the views read 435's
-- shared.v_setting_billing_effective, SELECT to catalog_owner), no role DDL, no dynamic SQL. The conftest replay skips this file
-- (needs 377 / 379 / 390 / 429, skipped too); tests/integration/test_aa1116_migration_438.py applies them the DB
-- Migrate way and undoes them.
--
-- Number. 435 + 3 (see 435 for the renumber rule).
--
-- Locks. Column GRANTs and three CREATE OR REPLACE VIEW. lock_timeout 5s, statement_timeout 1min. Idempotent, one
-- transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after the Booking / TripPlanner readers are reverted):
-- restate the 377 / 390 / 429 views (a view loses appended columns only by DROP + CREATE), REVOKE the column grants.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '437')
       OR NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '429')
       OR NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '377') THEN
        RAISE EXCEPTION 'migration 438: apply 377, 429 and 437 first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 438: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read ───────────────────────────────────────────────────────────────────────────────
GRANT SELECT (billing_currency, is_pilot) ON shared.tenants TO catalog_owner;
GRANT SELECT (billing_interval, agreed_price_monthly, agreed_currency, agreed_until, trial_ends_at)
    ON shared.tenant_subscription TO catalog_owner;
GRANT SELECT (price_vnd_monthly, price_extra_seat_vnd, seats_min) ON shared.plan TO catalog_owner;
GRANT SELECT (tenant_id, alert_pct, approval_pct, hard_stop) ON shared.tenant_ai_budget TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 2. The Booking billing view: 377's columns, then the option B terms ─────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tenant_billing_v1 WITH (security_barrier = true) AS
SELECT t.tenant_id,
       t.name::text AS name,
       t.kind,
       t.legal_entity_name,
       t.tax_id,
       t.billing_email,
       t.billing_address,
       t.billing_country,
       s.product,
       s.plan_key,
       p.name AS plan_name,
       p.price_usd_monthly,
       p.price_unit,
       p.seats_included,
       p.price_extra_seat_usd,
       s.seats,
       s.status AS subscription_status,
       t.billing_currency::text AS billing_currency,
       p.price_vnd_monthly,
       p.price_extra_seat_vnd,
       p.seats_min,
       s.agreed_price_monthly,
       s.agreed_currency::text AS agreed_currency,
       s.agreed_until,
       s.billing_interval,
       s.trial_ends_at,
       t.is_pilot,
       t.is_pilot AND coalesce(((SELECT v.value FROM shared.v_setting_billing_effective v
                  WHERE v.key = 'cis.billing.pilot_free') #>> '{}')::boolean, true)
           AS bill_free
  FROM shared.tenants t
  LEFT JOIN shared.tenant_subscription s ON s.tenant_id = t.tenant_id
  LEFT JOIN shared.plan p ON p.plan_key = s.plan_key;

COMMENT ON VIEW catalog.v_tenant_billing_v1 IS
    'AA-1037 R4, AA-1116 (377, 438; contract tenant.entitlements.v1 1.9, root ADR 0019 d1 / d9): what AA-Booking '
    'invoices an agency for: one row per tenant and subscription (NULL subscription columns for a tenant without one) '
    'with the plan''s USD and VND list prices, unit, included seats, seat minimum and extra-seat prices, the agreed '
    'price per billed unit / currency / end (438), the billing interval, '
    'the trial end, the agency''s billing currency, the pilot flag and bill_free (pilot while cis.billing.pilot_free '
    'is on), and the bill-to fields CIS holds. Booking only. Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_tenant_billing_v1 TO booking;

-- ── 3. The TripPlanner AI budget view: 390's columns, then the alert / stop shares ──────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tenant_ai_budget_v1 WITH (security_barrier = true) AS
SELECT t.tenant_id,
       b.source AS budget_source,
       b.monthly_usd,
       spend.spent AS month_spent_usd,
       spend.calls AS month_calls,
       -- 438: the alert / stop shares and the hard stop (the tenant's AI budget row, else the registry defaults)
       coalesce(ab.alert_pct::integer,
                ((SELECT v.value FROM shared.v_setting_billing_effective v
                  WHERE v.key = 'cis.billing.ai_alert_pct_default') #>> '{}')::numeric::integer)
           AS alert_pct,
       coalesce(ab.approval_pct::integer,
                ((SELECT v.value FROM shared.v_setting_billing_effective v
                  WHERE v.key = 'cis.billing.ai_approval_pct_default') #>> '{}')::numeric::integer)
           AS approval_pct,
       coalesce(ab.hard_stop, ((SELECT v.value FROM shared.v_setting_billing_effective v
                  WHERE v.key = 'cis.billing.ai_hard_stop_default') #>> '{}')::boolean)
           AS hard_stop
  FROM shared.tenants t
  LEFT JOIN shared.tenant_ai_budget ab ON ab.tenant_id = t.tenant_id
 CROSS JOIN LATERAL (
        SELECT CASE WHEN d.disabled THEN 'disabled'
                    WHEN e.feature_key IS NOT NULL THEN 'entitlement'
                    ELSE 'none' END AS source,
               CASE WHEN d.disabled THEN 0::numeric
                    WHEN e.feature_key IS NOT NULL THEN e.limit_value END AS monthly_usd
          FROM (SELECT EXISTS (SELECT 1 FROM shared.tenant_entitlement_override o
                                WHERE o.tenant_id = t.tenant_id AND o.feature_key = 'ai.budget_usd_monthly'
                                  AND NOT o.enabled AND (o.expires_at IS NULL OR o.expires_at > now())) AS disabled) d
          LEFT JOIN shared.v_tenant_entitlement_resolved e
                 ON e.tenant_id = t.tenant_id AND e.feature_key = 'ai.budget_usd_monthly'
       ) b
 CROSS JOIN LATERAL (
        SELECT coalesce(sum(l.cost_usd), 0)::numeric(14,6) AS spent, count(*)::integer AS calls
          FROM shared.llm_call_log l
         WHERE l.tenant_id = t.tenant_id
           AND l.created_at >= date_trunc('month', now() AT TIME ZONE 'utc') AT TIME ZONE 'utc'
           AND NOT coalesce(l.is_shadow, l.quality_signal @> '{"shadow": true}'::jsonb, false)
       ) spend
 WHERE t.kind <> 'internal'
   AND EXISTS (SELECT 1 FROM shared.tenant_subscription s
                WHERE s.tenant_id = t.tenant_id AND s.product = 'tripplanner');

COMMENT ON VIEW catalog.v_tenant_ai_budget_v1 IS
    'AA-1038 R5 slice 3, AA-1116 (390, 438; contract tenant.entitlements.v1 1.9, root ADR 0019 d2 / b19): the AI '
    'budget of a TripPlanner tenant and its AI spend this UTC month on every app (shared.llm_call_log, shadow rows '
    'out). budget_source entitlement (monthly_usd NULL = unlimited) | disabled (0 USD) | none (no key: fail closed). '
    '438: alert_pct / approval_pct / hard_stop (the tenant''s AI budget row, else the cis.billing.* registry '
    'defaults). Read with WHERE tenant_id = $1. TripPlanner only. Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_tenant_ai_budget_v1 TO tripplanner;

-- ── 4. The TripPlanner tenant view: 429's columns, then the AI sessions a month ─────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tenant_tripplanner_v1 WITH (security_barrier = true) AS
SELECT t.tenant_id,
       t.slug::text AS slug,
       t.name::text AS name,
       t.kind,
       t.account_status,
       t.account_status IN ('trial', 'active', 'past_due') AS in_service,
       t.account_status IN ('trial', 'active', 'past_due')
           AND EXISTS (SELECT 1 FROM shared.v_tenant_entitlement_resolved r
                        WHERE r.tenant_id = t.tenant_id AND r.feature_key = 'tp.hosted') AS served,
       EXISTS (SELECT 1 FROM shared.v_tenant_entitlement_resolved r
                WHERE r.tenant_id = t.tenant_id AND r.feature_key = 'tp.launcher') AS tp_launcher,
       EXISTS (SELECT 1 FROM shared.v_tenant_entitlement_resolved r
                WHERE r.tenant_id = t.tenant_id AND r.feature_key = 'tp.branding') AS tp_branding,
       COALESCE(site.theme, '{}'::jsonb) AS theme,
       COALESCE(site.locale, 'en') AS locale,
       crm.live AS crm_core,
       route.channel AS lead_channel,
       CASE WHEN route.channel = 'webhook' THEN site.lead_webhook_url END AS lead_webhook_url,
       CASE WHEN route.channel = 'email' THEN site.lead_email END AS lead_email,
       ARRAY(SELECT d.domain FROM shared.tenant_tripplanner_domain d
              WHERE d.tenant_id = t.tenant_id AND d.status = 'active'
              ORDER BY d.domain) AS custom_domains,
       -- 438: the resolved TripPlanner AI sessions a month (tp.ai_sessions; NULL = no limit)
       (SELECT r.limit_value FROM shared.v_tenant_entitlement_resolved r
         WHERE r.tenant_id = t.tenant_id AND r.feature_key = 'tp.ai_sessions')::integer AS ai_sessions_monthly
  FROM shared.tenants t
  LEFT JOIN shared.tenant_tripplanner_site site ON site.tenant_id = t.tenant_id
 CROSS JOIN LATERAL (
        SELECT EXISTS (SELECT 1 FROM shared.v_tenant_entitlement_resolved r
                        WHERE r.tenant_id = t.tenant_id AND r.feature_key = 'crm.core') AS live
       ) crm
 CROSS JOIN LATERAL (
        SELECT CASE WHEN crm.live THEN 'crm'
                    WHEN site.lead_channel = 'webhook' AND site.lead_webhook_url IS NOT NULL THEN 'webhook'
                    WHEN site.lead_channel = 'email' AND site.lead_email IS NOT NULL THEN 'email'
                    ELSE 'none' END AS channel
       ) route
 WHERE t.kind <> 'internal'
   AND EXISTS (SELECT 1 FROM shared.tenant_subscription s
                WHERE s.tenant_id = t.tenant_id AND s.product = 'tripplanner');

COMMENT ON VIEW catalog.v_tenant_tripplanner_v1 IS
    'AA-1038 R5 slices 2-3, AA-1090 R8, AA-1116 (379, 390, 429, 438; contract tenant.entitlements.v1 1.9, root ADR '
    '0019 d10, d11, b4): one row per tenant with a TripPlanner subscription (kind internal excluded) for the /{slug} '
    'site: the slug, the trading name (brand label), kind, the lifecycle status, in_service (trial, active, past_due), '
    'served (in service and tp.hosted live: answer /{slug} only then), tp_launcher, tp_branding (BO-8 badge), theme '
    '(kit token name -> #rrggbb) and locale; 390: crm_core and the resolved lead route with its target; 429: '
    'custom_domains, the active custom hosts of the site (served only when served is true); 438: ai_sessions_monthly '
    '(resolved tp.ai_sessions, NULL = no limit). A bound tenant reads AA master catalogue rows only. TripPlanner only. '
    'Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_tenant_tripplanner_v1 TO tripplanner;

-- ── Closing check as catalog_owner: the views answer ─────────────────────────────────────────────────────────────
DO $$
BEGIN
    RAISE NOTICE 'migration 438: as catalog_owner, billing % row(s), ai budget % row(s), tripplanner % row(s)',
        (SELECT count(*) FROM catalog.v_tenant_billing_v1),
        (SELECT count(*) FROM catalog.v_tenant_ai_budget_v1),
        (SELECT count(*) FROM catalog.v_tenant_tripplanner_v1);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner ───────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    r text;
    v text;
    cols text;
BEGIN
    FOREACH v IN ARRAY ARRAY['catalog.v_tenant_billing_v1', 'catalog.v_tenant_ai_budget_v1',
                             'catalog.v_tenant_tripplanner_v1'] LOOP
        IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
            RAISE EXCEPTION 'migration 438: % is not catalog_owner''s', v;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
            RAISE EXCEPTION 'migration 438: % is not security_barrier', v;
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'booking')
       AND NOT pg_catalog.has_table_privilege('booking', 'catalog.v_tenant_billing_v1', 'SELECT') THEN
        RAISE EXCEPTION 'migration 438: booking cannot read catalog.v_tenant_billing_v1';
    END IF;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, 'catalog.v_tenant_billing_v1', 'SELECT') THEN
            RAISE EXCEPTION 'migration 438: % can read catalog.v_tenant_billing_v1 (booking only)', r;
        END IF;
    END LOOP;
    FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND (pg_catalog.has_table_privilege(r, 'catalog.v_tenant_ai_budget_v1', 'SELECT')
                OR pg_catalog.has_table_privilege(r, 'catalog.v_tenant_tripplanner_v1', 'SELECT')) THEN
            RAISE EXCEPTION 'migration 438: % can read a TripPlanner view (tripplanner only)', r;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_tenant_billing_v1'::regclass AND a.attnum > 0
       AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'tenant_id uuid, name text, kind text, legal_entity_name text, tax_id text, '
                             'billing_email text, billing_address text, billing_country text, product text, '
                             'plan_key text, plan_name text, price_usd_monthly numeric(10,2), price_unit text, '
                             'seats_included integer, price_extra_seat_usd numeric(10,2), seats integer, '
                             'subscription_status text, billing_currency text, price_vnd_monthly numeric(14,0), '
                             'price_extra_seat_vnd numeric(14,0), seats_min integer, '
                             'agreed_price_monthly numeric(14,2), agreed_currency text, agreed_until date, '
                             'billing_interval text, trial_ends_at timestamp with time zone, is_pilot boolean, '
                             'bill_free boolean' THEN
        RAISE EXCEPTION 'migration 438: catalog.v_tenant_billing_v1 columns are %', cols;
    END IF;
    IF pg_catalog.has_column_privilege('catalog_owner', 'shared.tenant_subscription', 'billing_ref', 'SELECT') THEN
        RAISE EXCEPTION 'migration 438: catalog_owner reads tenant_subscription.billing_ref';
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 438: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('438', now(), 'AA-1116: option B terms appended to catalog.v_tenant_billing_v1, '
                      'v_tenant_ai_budget_v1 (alert / stop shares) and v_tenant_tripplanner_v1 (ai_sessions_monthly)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
