-- Migration 429: AA-1090 (TripPlanner R8, root ADR 0019 b4, tech lead S278 D10 / D13 NEW-D) — TripPlanner's read of
-- a tenant's custom hosts: the column custom_domains appended to the contract view catalog.v_tenant_tripplanner_v1
-- (contract tenant.entitlements.v1 1.8) and catalog_owner's read of shared.tenant_tripplanner_domain (CIS 428).
--
-- Why. TripPlanner reads the CIS control plane through catalog contract views only (role tripplanner has USAGE on
-- schema catalog, never on shared). A request to trip.<agency domain> reaches the TripPlanner web through the
-- distribution alias the CIS job tripplanner_custom_domain attached; TripPlanner resolves its Host to the tenant with
-- the view
-- it already reads for /{slug} (browse GET /browse/tenant-host/{host}), so the tenant's branding, tours and lead route
-- carry over unchanged and the path /{slug} keeps working.
--
-- What:
--   1. catalog_owner: column SELECT (tenant_id, domain, status) on shared.tenant_tripplanner_domain (no RLS, 428);
--      the view keeps status = 'active' in its WHERE, so a pending, validating, attaching, removing or failed host
--      never reaches TripPlanner.
--   2. catalog.v_tenant_tripplanner_v1 appends (contract v1: columns are only appended, same rows):
--        custom_domains text[] — the tenant's active custom hosts, sorted; an empty array when it has none.
--      TripPlanner serves a host only for a row that is also served (in service, tp.hosted live), as for /{slug}.
--   3. Register 429.
--
-- Behaviour on apply. Every row gets custom_domains = '{}' (no host is active before the AA-1090 CIS code runs the
-- job). Nothing reads the column until the AA-1090 TripPlanner code is deployed, and that code feature-detects it
-- (42703 before this file: every custom host is unknown, a 404; /{slug} and the bare path are unchanged).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): column GRANTs on an existing table, a replaced
-- view in the hot schema catalog (the catalog.* recipe: role switch, GRANT / REVOKE CREATE). MIG-4:
-- migration-only PR in the wave's CIS batch with 428; applied on Dev by Infra Migration Apply when the job tables are
-- idle (ADR 0017a). No new table (428's retention row covers the hosts).
--
-- Guards (RAISE rolls the whole file back): before — 390 and 428 registered, schema catalog owned by cis_owner. After,
-- as catalog_owner — the view answers and the demo tenant has no custom host. After, as cis_owner — the view's exact
-- columns and types, owner catalog_owner, security_barrier, tripplanner can read it and booking / aa_app_user /
-- cis_app / crm_app cannot, tripplanner holds no privilege on shared.tenant_tripplanner_domain, catalog_owner reads
-- exactly its three granted columns and writes nothing, and catalog_owner has no CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 379 / 390 / 404): the grants as cis_owner, then GRANT CREATE ON
-- SCHEMA catalog TO catalog_owner; SET LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE.
-- DB Migrate runs the file as cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL, no
-- dynamic SQL. The conftest replay skips this file (catalog recipe, needs 379 / 390, which it skips too);
-- tests/integration/test_aa1090_migrations_428_429.py applies 379 + 390 + 429 the DB Migrate way and undoes them.
--
-- Number. 428 (this lane) is the table; renumber both together (see 428).
--
-- Locks. Column GRANTs and one CREATE OR REPLACE VIEW.
-- lock_timeout 5s, statement_timeout 1min. Idempotent (CREATE OR REPLACE with the same column list, re-runnable
-- grants), one transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after the TripPlanner code is reverted): the column cannot
-- be dropped from the view (DROP + CREATE with the 390 body), then REVOKE the column grants.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';
SELECT set_config('aa.actor', 'migration:429', true);

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '390') THEN
        RAISE EXCEPTION 'migration 429: apply 390 (the lead-route columns of catalog.v_tenant_tripplanner_v1) first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '428')
       OR to_regclass('shared.tenant_tripplanner_domain') IS NULL THEN
        RAISE EXCEPTION 'migration 429: apply 428 (shared.tenant_tripplanner_domain) first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 429: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read of the custom hosts (the view keeps active ones only) ─────────────────────────
GRANT SELECT (tenant_id, domain, status) ON shared.tenant_tripplanner_domain TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 2. The TripPlanner tenant view, custom_domains appended (the 390 body unchanged before it) ───────────────────
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
              ORDER BY d.domain) AS custom_domains
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
    'AA-1038 R5 slices 2-3, AA-1090 R8 (379, 390, 429; contract tenant.entitlements.v1 1.8, root ADR 0019 d10, d11, '
    'b4): one row per tenant with a TripPlanner subscription (kind internal excluded) for the /{slug} site: the slug, '
    'the trading name (brand label), kind, the lifecycle status, in_service (trial, active, past_due), served (in '
    'service and tp.hosted live: answer /{slug} only then), tp_launcher, tp_branding (BO-8 badge), theme (kit token '
    'name -> #rrggbb) and locale; 390: crm_core and the resolved lead route with its target; 429: custom_domains, the '
    'active custom hosts of the site (served only when served is true). A bound tenant reads AA master catalogue rows '
    'only. TripPlanner only. Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_tenant_tripplanner_v1 TO tripplanner;

-- ── Closing check as catalog_owner: the view answers; the demo tenant has no custom host ─────────────────────────
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM catalog.v_tenant_tripplanner_v1
                WHERE tenant_id = '00000000-0000-0000-0000-000000000002'::uuid
                  AND cardinality(custom_domains) <> 0) THEN
        RAISE EXCEPTION 'migration 429: the demo tenant aa-tripplanner has a custom host';
    END IF;
    RAISE NOTICE 'migration 429: as catalog_owner, % TripPlanner tenant(s), % with a custom host',
        (SELECT count(*) FROM catalog.v_tenant_tripplanner_v1),
        (SELECT count(*) FROM catalog.v_tenant_tripplanner_v1 WHERE cardinality(custom_domains) > 0);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner ───────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_tenant_tripplanner_v1';
    d constant text := 'shared.tenant_tripplanner_domain';
    r text;
    cols text;
    granted text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 429: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 429: % is not security_barrier', v;
    END IF;
    IF NOT pg_catalog.has_table_privilege('tripplanner', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 429: tripplanner cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 429: % can read % (tripplanner only)', r, v;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'tenant_id uuid, slug text, name text, kind text, account_status text, '
                             'in_service boolean, served boolean, tp_launcher boolean, tp_branding boolean, '
                             'theme jsonb, locale text, crm_core boolean, lead_channel text, lead_webhook_url text, '
                             'lead_email text, custom_domains text[]' THEN
        RAISE EXCEPTION 'migration 429: % columns are %', v, cols;
    END IF;
    IF pg_catalog.has_any_column_privilege('tripplanner', d, 'SELECT')
       OR pg_catalog.has_any_column_privilege('tripplanner', d, 'INSERT')
       OR pg_catalog.has_any_column_privilege('tripplanner', d, 'UPDATE') THEN
        RAISE EXCEPTION 'migration 429: tripplanner can read or change % directly', d;
    END IF;
    IF pg_catalog.has_table_privilege('catalog_owner', d, 'SELECT')
       OR pg_catalog.has_any_column_privilege('catalog_owner', d, 'INSERT')
       OR pg_catalog.has_any_column_privilege('catalog_owner', d, 'UPDATE')
       OR pg_catalog.has_table_privilege('catalog_owner', d, 'DELETE') THEN
        RAISE EXCEPTION 'migration 429: catalog_owner has more than column SELECT on %', d;
    END IF;
    SELECT string_agg(a.attname, ',' ORDER BY a.attname) INTO granted
      FROM pg_attribute a
     WHERE a.attrelid = d::regclass AND a.attnum > 0 AND NOT a.attisdropped
       AND pg_catalog.has_column_privilege('catalog_owner', a.attrelid, a.attnum, 'SELECT');
    IF granted IS DISTINCT FROM 'domain,status,tenant_id' THEN
        RAISE EXCEPTION 'migration 429: catalog_owner reads % columns %', d, granted;
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 429: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('429', now(), 'AA-1090 TripPlanner R8: catalog.v_tenant_tripplanner_v1.custom_domains (active custom hosts) '
                      'and catalog_owner''s read of shared.tenant_tripplanner_domain')
ON CONFLICT (version) DO NOTHING;

COMMIT;
