-- Migration 390: AA-1038 R5 slice 3 (root ADR 0019 d10, d11, b19) — where a TripPlanner tenant's leads go, and the
-- tenant's AI budget for the TripPlanner stages: three lead-route columns on shared.tenant_tripplanner_site, four
-- columns appended to the contract view catalog.v_tenant_tripplanner_v1 and the new contract view
-- catalog.v_tenant_ai_budget_v1 (contract tenant.entitlements.v1 1.5, the TripPlanner view parts).
--
-- Why. ADR 0019 d11: a traveller's "Send to advisor" on a tenant's planner becomes a lead.submitted.v1 for THAT tenant
-- and goes to the tenant's CRM when it holds the CRM add-on (crm.core), else to a signed webhook or an e-mail the
-- tenant set up; TripPlanner keeps the lead only until it is delivered. TripPlanner reads the CIS control plane through
-- catalog contract views only (role tripplanner has USAGE on schema catalog, never on shared), so the route has to be
-- in the view it already reads. ADR 0019 d2 / b19: the tenant's resolved ai.budget_usd_monthly caps the tenant's AI
-- spend on every app, and TripPlanner's model calls now carry the tenant (ledger tenant_id), so TripPlanner needs the
-- budget and the month's spend to stop its own stages for one tenant without stopping every tenant.
--
-- What:
--   1. shared.tenant_tripplanner_site gains lead_channel ('none' | 'webhook' | 'email', default 'none'),
--      lead_webhook_url (https only, at most 500 characters) and lead_email (one address of the agency, at most 254
--      characters). A channel needs its target (CHECK). The agency's business address, never a traveller's; no secret
--      (the webhook signature key is TripPlanner's, per tenant, never stored here). All ADD COLUMN with constant
--      defaults or NULL: metadata-only. cis_app keeps its table grant (the Tenant 360 editor); catalog_owner gets
--      column SELECT on the three new columns.
--   2. catalog.v_tenant_tripplanner_v1 appends (contract v1: columns are only appended, same rows):
--        crm_core         — the crm.core entitlement is live (the CRM add-on);
--        lead_channel     — the resolved route: 'crm' when crm.core is live, else the site's 'webhook' / 'email'
--                           when its target is set, else 'none' (TripPlanner then stores nothing and refuses);
--        lead_webhook_url — the site's URL, only when the resolved channel is 'webhook' (else NULL);
--        lead_email       — the site's address, only when the resolved channel is 'email' (else NULL).
--   3. catalog.v_tenant_ai_budget_v1 (security_barrier, owner catalog_owner, SELECT to tripplanner only): one row per
--      tenant of v_tenant_tripplanner_v1 (a TripPlanner subscription, kind internal excluded): tenant_id,
--      budget_source ('entitlement': the resolved ai.budget_usd_monthly; 'disabled': an active disabled override of
--      the key, served as a 0 USD budget, CIS cost_guard's fail-closed rule; 'none': no key resolves),
--      monthly_usd (NULL with 'entitlement' = unlimited, e.g. AA itself; 0 with 'disabled'; NULL with 'none'),
--      month_spent_usd and month_calls (the tenant's shared.llm_call_log rows of the current UTC calendar month on
--      every app, shadow rows out: the CIS cost_guard / Tenant 360 › Cost rule). TripPlanner stops its AI stages for
--      the tenant at 100 % of monthly_usd and for 'none' / 'disabled' (fail closed); the demo tenant is TripPlanner's
--      own and is not read here. The AA-1016 row of shared.tenant_ai_budget already reaches the resolved key as an
--      override (356), so its amount is served; its alert / approval thresholds stay CIS's (a traveller-facing stage
--      degrades, it never waits for staff approval).
--   4. catalog_owner column SELECT: shared.tenant_tripplanner_site (lead_channel, lead_webhook_url, lead_email),
--      shared.tenant_entitlement_override (tenant_id, feature_key, enabled, expires_at), shared.llm_call_log
--      (tenant_id, is_shadow; app, cost_usd, created_at, quality_signal, stage, status held since 323). Re-runnable.
--   5. Register 390.
--
-- Behaviour on apply. Every existing site row gets lead_channel 'none'; an agency with crm.core resolves to 'crm' at
-- once, every other one to 'none' (TripPlanner refuses a lead it could not deliver: nothing is stored). Nothing reads
-- the new columns or the new view until the AA-1038 slice 3 TripPlanner code is deployed, and that code feature-detects
-- them (42703 / 42P01 before this file: a tenant's send-to-advisor answers 503 lead_route_unavailable, its AI stages
-- stay paused for that tenant; the bare path / demo tenant is unchanged).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no '-- migrate:' directive): ALTER TABLE ADD COLUMN + CHECK on an
-- existing table, a replaced view and a new view in the hot schema catalog (the catalog.* recipe: role switch,
-- GRANT / REVOKE CREATE), column GRANTs on existing tables. MIG-4: migration-only PR; applied on Dev by Infra Migration
-- Apply when the job tables are idle (ADR 0017a). No new table, so no new DM-7.1 retention row (the site row's
-- retention row of 379 covers the new columns: agency settings, deleted with the tenant).
--
-- Guards (RAISE rolls the whole file back): before — 379 registered (the site table and the view), schema catalog
-- owned by cis_owner. After, as catalog_owner — both views answer and the demo tenant resolves to lead_channel 'none'
-- with no target. After, as cis_owner — the exact columns and types of both views, owner catalog_owner,
-- security_barrier, tripplanner can read them and booking / aa_app_user / cis_app / crm_app cannot, tripplanner holds
-- no privilege on the base tables, catalog_owner reads exactly the granted site columns, the channel CHECKs refuse a
-- channel without its target and a non-https URL, and catalog_owner has no CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 323 / 329 / 341 / 347 / 357 / 377 / 379): the ALTER and the grants as
-- cis_owner, then GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE catalog_owner; the view DDL; SET
-- LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as cis_owner (login db_migrator). Never RESET ROLE, no
-- SECURITY DEFINER, no role DDL, no dynamic SQL. The conftest replay skips this file (catalog recipe, 245's owners);
-- tests/integration/test_aa1038_migration_390.py applies 379 then 390 the DB Migrate way and undoes both.
--
-- Number. 388 is the highest on main (07/11) and 389 is held by another lane of the wave. If the owner main max + 1
-- differs at merge, renumber (git grep '390_' and '390' in this file, the test, conftest and the AA-TripPlanner-Web
-- test stubs).
--
-- Locks. ALTER TABLE ADD COLUMN (ACCESS EXCLUSIVE on the small site table, metadata only) + ADD CONSTRAINT (a scan of
-- a few rows), column GRANTs, two CREATE OR REPLACE VIEW. lock_timeout 5s, statement_timeout 1min. Idempotent (IF NOT
-- EXISTS, constraints dropped and re-added, CREATE OR REPLACE with the same column list, re-runnable grants), one
-- transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after the TripPlanner code is reverted): DROP VIEW
-- catalog.v_tenant_ai_budget_v1; recreate catalog.v_tenant_tripplanner_v1 is not possible without its appended
-- columns (a view cannot drop columns: DROP + CREATE with the 379 body); REVOKE the column grants; a destructive file
-- (DRY RUN) for the three site columns.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';
SELECT set_config('aa.actor', 'migration:390', true);

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '379') THEN
        RAISE EXCEPTION 'migration 390: apply 379 (shared.tenant_tripplanner_site, catalog.v_tenant_tripplanner_v1) first';
    END IF;
    IF to_regclass('shared.tenant_tripplanner_site') IS NULL OR to_regclass('catalog.v_tenant_tripplanner_v1') IS NULL THEN
        RAISE EXCEPTION 'migration 390: the 379 objects are missing';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 390: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. The lead route of a site ──────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.tenant_tripplanner_site
    ADD COLUMN IF NOT EXISTS lead_channel     text NOT NULL DEFAULT 'none',
    ADD COLUMN IF NOT EXISTS lead_webhook_url text,
    ADD COLUMN IF NOT EXISTS lead_email       text;

ALTER TABLE shared.tenant_tripplanner_site DROP CONSTRAINT IF EXISTS tenant_tripplanner_site_lead_channel_chk;
ALTER TABLE shared.tenant_tripplanner_site ADD CONSTRAINT tenant_tripplanner_site_lead_channel_chk CHECK (
    lead_channel IN ('none', 'webhook', 'email')
    AND (lead_channel <> 'webhook' OR lead_webhook_url IS NOT NULL)
    AND (lead_channel <> 'email' OR lead_email IS NOT NULL));
ALTER TABLE shared.tenant_tripplanner_site DROP CONSTRAINT IF EXISTS tenant_tripplanner_site_lead_webhook_chk;
ALTER TABLE shared.tenant_tripplanner_site ADD CONSTRAINT tenant_tripplanner_site_lead_webhook_chk CHECK (
    lead_webhook_url IS NULL
    OR (lead_webhook_url ~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^\s]*)?$' AND char_length(lead_webhook_url) <= 500));
ALTER TABLE shared.tenant_tripplanner_site DROP CONSTRAINT IF EXISTS tenant_tripplanner_site_lead_email_chk;
ALTER TABLE shared.tenant_tripplanner_site ADD CONSTRAINT tenant_tripplanner_site_lead_email_chk CHECK (
    lead_email IS NULL
    OR (lead_email ~ '^[^@\s]{1,64}@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,63}$' AND char_length(lead_email) <= 254));

COMMENT ON COLUMN shared.tenant_tripplanner_site.lead_channel IS
    'AA-1038 (390): where a tenant WITHOUT the CRM add-on gets its TripPlanner leads (lead.submitted.v1): none | '
    'webhook | email. A tenant with crm.core live always gets them in its CRM (catalog.v_tenant_tripplanner_v1 '
    'lead_channel = crm). none = TripPlanner refuses the request and stores nothing.';
COMMENT ON COLUMN shared.tenant_tripplanner_site.lead_webhook_url IS
    'AA-1038 (390): the agency''s https endpoint for lead.submitted.v1 (signed by TripPlanner, X-AA-Signature). No '
    'secret here; the key is TripPlanner''s, per tenant.';
COMMENT ON COLUMN shared.tenant_tripplanner_site.lead_email IS
    'AA-1038 (390): the agency''s own inbox for lead.submitted.v1 e-mails (a business address, never a traveller''s).';

-- ── 4. What catalog_owner may read (column grants, re-runnable) ──────────────────────────────────────────────────
GRANT SELECT (lead_channel, lead_webhook_url, lead_email) ON shared.tenant_tripplanner_site TO catalog_owner;
GRANT SELECT (tenant_id, feature_key, enabled, expires_at) ON shared.tenant_entitlement_override TO catalog_owner;
GRANT SELECT (tenant_id, is_shadow, app, cost_usd, created_at, quality_signal, stage, status)
    ON shared.llm_call_log TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 2. The TripPlanner tenant view, four columns appended ────────────────────────────────────────────────────────
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
       CASE WHEN route.channel = 'email' THEN site.lead_email END AS lead_email
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
    'AA-1038 R5 slices 2-3 (379, 390; contract tenant.entitlements.v1 1.5, root ADR 0019 d10, d11): one row per tenant '
    'with a TripPlanner subscription (kind internal excluded) for the /{slug} site: the slug, the trading name (brand '
    'label), kind, the lifecycle status, in_service (trial, active, past_due), served (in service and tp.hosted live: '
    'answer /{slug} only then), tp_launcher, tp_branding (BO-8 badge), theme (kit token name -> #rrggbb) and locale; '
    '390: crm_core and the resolved lead route (crm when crm.core is live, else the site''s webhook / email when set, '
    'else none) with its target. A bound tenant reads AA master catalogue rows only. TripPlanner only. Contract v1: '
    'columns are only appended.';

-- ── 3. The tenant AI budget view ─────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tenant_ai_budget_v1 WITH (security_barrier = true) AS
SELECT t.tenant_id,
       b.source AS budget_source,
       b.monthly_usd,
       spend.spent AS month_spent_usd,
       spend.calls AS month_calls
  FROM shared.tenants t
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
    'AA-1038 R5 slice 3 (390, contract tenant.entitlements.v1 1.5, root ADR 0019 d2 / b19): the AI budget of a '
    'TripPlanner tenant and its AI spend this UTC month on every app (shared.llm_call_log, shadow rows out). '
    'budget_source entitlement (monthly_usd NULL = unlimited) | disabled (0 USD) | none (no key: fail closed). '
    'Read with WHERE tenant_id = $1. TripPlanner only. Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_tenant_tripplanner_v1 TO tripplanner;
GRANT SELECT ON catalog.v_tenant_ai_budget_v1 TO tripplanner;

-- ── Closing check as catalog_owner: both views answer; the demo tenant has no lead route ─────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM catalog.v_tenant_tripplanner_v1
                    WHERE tenant_id = '00000000-0000-0000-0000-000000000002'::uuid AND lead_channel = 'none'
                      AND lead_webhook_url IS NULL AND lead_email IS NULL AND NOT crm_core) THEN
        RAISE EXCEPTION 'migration 390: the demo tenant aa-tripplanner does not resolve to lead_channel none';
    END IF;
    PERFORM 1 FROM catalog.v_tenant_ai_budget_v1
     WHERE tenant_id = '00000000-0000-0000-0000-000000000002'::uuid;
    RAISE NOTICE 'migration 390: as catalog_owner, % TripPlanner tenant(s): % crm, % webhook, % email, % none',
        (SELECT count(*) FROM catalog.v_tenant_tripplanner_v1),
        (SELECT count(*) FROM catalog.v_tenant_tripplanner_v1 WHERE lead_channel = 'crm'),
        (SELECT count(*) FROM catalog.v_tenant_tripplanner_v1 WHERE lead_channel = 'webhook'),
        (SELECT count(*) FROM catalog.v_tenant_tripplanner_v1 WHERE lead_channel = 'email'),
        (SELECT count(*) FROM catalog.v_tenant_tripplanner_v1 WHERE lead_channel = 'none');
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner ───────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v text;
    r text;
    t text;
    cols text;
    granted text;
BEGIN
    FOREACH v IN ARRAY ARRAY['catalog.v_tenant_tripplanner_v1', 'catalog.v_tenant_ai_budget_v1'] LOOP
        IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
            RAISE EXCEPTION 'migration 390: % is not catalog_owner''s', v;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
            RAISE EXCEPTION 'migration 390: % is not security_barrier', v;
        END IF;
        IF NOT pg_catalog.has_table_privilege('tripplanner', v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 390: tripplanner cannot read %', v;
        END IF;
        FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
            IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
               AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
                RAISE EXCEPTION 'migration 390: % can read % (tripplanner only)', r, v;
            END IF;
        END LOOP;
    END LOOP;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a
     WHERE a.attrelid = 'catalog.v_tenant_tripplanner_v1'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'tenant_id uuid, slug text, name text, kind text, account_status text, '
                             'in_service boolean, served boolean, tp_launcher boolean, tp_branding boolean, '
                             'theme jsonb, locale text, crm_core boolean, lead_channel text, lead_webhook_url text, '
                             'lead_email text' THEN
        RAISE EXCEPTION 'migration 390: catalog.v_tenant_tripplanner_v1 columns are %', cols;
    END IF;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a
     WHERE a.attrelid = 'catalog.v_tenant_ai_budget_v1'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'tenant_id uuid, budget_source text, monthly_usd numeric, '
                             'month_spent_usd numeric(14,6), month_calls integer' THEN
        RAISE EXCEPTION 'migration 390: catalog.v_tenant_ai_budget_v1 columns are %', cols;
    END IF;
    FOREACH t IN ARRAY ARRAY['shared.tenants', 'shared.tenant_subscription', 'shared.tenant_tripplanner_site',
                             'shared.tenant_entitlement_override', 'shared.v_tenant_entitlement_resolved'] LOOP
        IF pg_catalog.has_any_column_privilege('tripplanner', t, 'SELECT')
           OR pg_catalog.has_any_column_privilege('tripplanner', t, 'INSERT')
           OR pg_catalog.has_any_column_privilege('tripplanner', t, 'UPDATE') THEN
            RAISE EXCEPTION 'migration 390: tripplanner can read or change % directly', t;
        END IF;
    END LOOP;
    IF pg_catalog.has_any_column_privilege('tripplanner', 'shared.llm_call_log', 'SELECT') THEN
        RAISE EXCEPTION 'migration 390: tripplanner can read shared.llm_call_log';
    END IF;
    FOREACH t IN ARRAY ARRAY['shared.tenant_tripplanner_site', 'shared.tenant_entitlement_override',
                             'shared.llm_call_log'] LOOP
        IF pg_catalog.has_table_privilege('catalog_owner', t, 'SELECT')
           OR pg_catalog.has_any_column_privilege('catalog_owner', t, 'INSERT')
           OR pg_catalog.has_any_column_privilege('catalog_owner', t, 'UPDATE')
           OR pg_catalog.has_table_privilege('catalog_owner', t, 'DELETE') THEN
            RAISE EXCEPTION 'migration 390: catalog_owner has more than column SELECT on %', t;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname, ',' ORDER BY a.attname) INTO granted
      FROM pg_attribute a
     WHERE a.attrelid = 'shared.tenant_tripplanner_site'::regclass AND a.attnum > 0 AND NOT a.attisdropped
       AND pg_catalog.has_column_privilege('catalog_owner', a.attrelid, a.attnum, 'SELECT');
    IF granted IS DISTINCT FROM 'lead_channel,lead_email,lead_webhook_url,locale,tenant_id,theme' THEN
        RAISE EXCEPTION 'migration 390: catalog_owner reads shared.tenant_tripplanner_site columns %', granted;
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 390: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

-- ── Closing check: the route CHECKs refuse a channel without its target and a bad target (always rolled back) ────
DO $$
DECLARE
    probe text[];
    refused integer := 0;
BEGIN
    FOREACH probe SLICE 1 IN ARRAY ARRAY[
        ARRAY['webhook', NULL, NULL], ARRAY['email', NULL, NULL], ARRAY['sms', NULL, NULL],
        ARRAY['webhook', 'http://agency.example.invalid/leads', NULL],
        ARRAY['webhook', 'https://agency.example.invalid/a b', NULL],
        ARRAY['email', NULL, 'not-an-address']] LOOP
        BEGIN
            UPDATE shared.tenant_tripplanner_site
               SET lead_channel = probe[1], lead_webhook_url = probe[2], lead_email = probe[3]
             WHERE tenant_id = '00000000-0000-0000-0000-000000000002'::uuid;
        EXCEPTION WHEN check_violation THEN
            refused := refused + 1;
        END;
    END LOOP;
    IF refused <> 6 THEN
        RAISE EXCEPTION 'migration 390: the lead route CHECKs let % of 6 bad values through', 6 - refused;
    END IF;
    IF (SELECT lead_channel FROM shared.tenant_tripplanner_site
         WHERE tenant_id = '00000000-0000-0000-0000-000000000002'::uuid) IS DISTINCT FROM 'none' THEN
        RAISE EXCEPTION 'migration 390: the demo site row changed during the CHECK probe';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('390', now(), 'AA-1038 R5 slice 3: tenant_tripplanner_site lead route, catalog.v_tenant_tripplanner_v1 '
                      '(crm_core, lead_channel, lead target) and catalog.v_tenant_ai_budget_v1')
ON CONFLICT (version) DO NOTHING;

COMMIT;
