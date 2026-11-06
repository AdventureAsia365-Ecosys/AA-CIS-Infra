-- Migration 379: AA-1038 R5 slice 2 (root ADR 0019 d10, b4, BO-8) — TripPlanner's read of its tenants: the per-tenant
-- site settings table shared.tenant_tripplanner_site, the contract view catalog.v_tenant_tripplanner_v1
-- (tenant.entitlements.v1 1.4, the view part for TripPlanner) and the CIS row of the demo tenant aa-tripplanner.
--
-- Why. ADR 0019 d10: TripPlanner serves each agency tenant on the path /{slug} of its existing host, and "tenant
-- configuration comes from catalog.v_tenant_tripplanner_v1". TripPlanner reads the CIS control plane through catalog
-- contract views only (role tripplanner has USAGE on schema catalog, never on shared; root owners.yaml consumer_grants
-- "catalog.* (schema + views)", CIS 225 / 228), as Booking reads catalog.v_tenant_account_v1 (357). TripPlanner tp-025
-- (applied on Dev 05/11) already stamps every trip row with the demo tenant 00000000-0000-0000-0000-000000000002 as a
-- soft key to shared.tenants; that row is seeded here.
--
-- What:
--   1. shared.tenant_tripplanner_site: one row per tenant with the TripPlanner site settings that are not plan data:
--      theme (an object of kit token name -> '#rrggbb' colour, at most 4 kB; empty = the kit defaults), locale (en | vi,
--      the kit's languages), updated_at, updated_by (the actor, never an e-mail). No personal data, no secret. No RLS,
--      like the R1 control plane tables (read only by the CIS API and the catalog view, never by a tenant role; rls
--      catalogue rule a allowlist). Grants: REVOKE ALL first (the Dev default ACL of cis_owner in shared, CIS 245), then
--      cis_app SELECT, INSERT, UPDATE, DELETE (the Tenant 360 editor of the kit brand token slice, and the AA-839
--      tenant erasure), catalog_owner column SELECT (tenant_id, theme, locale).
--   2. Column-level SELECT for catalog_owner on shared.tenants.slug (357 / 377 hold tenant_id, name, account_status,
--      kind; granted again, idempotent) and on shared.tenant_subscription (tenant_id, product; held since 377), and
--      SELECT on shared.v_tenant_entitlement_resolved (held since 357; granted again).
--   3. catalog.v_tenant_tripplanner_v1 (security_barrier, owner catalog_owner): one row per tenant that holds a
--      TripPlanner subscription (any status) and is not kind internal: tenant_id, slug, name (the trading name, the
--      brand label of the site), kind, account_status, in_service (trial, active, past_due: the contract's rule),
--      served (in_service AND the tp.hosted entitlement is live: TripPlanner answers /{slug} only then, 404 otherwise),
--      tp_launcher, tp_branding (the BO-8 "Powered by AA" badge flag; no plan gives it, an override turns it on),
--      theme (jsonb, '{}' without a site row) and locale ('en' without a site row). SELECT to tripplanner only.
--      Contract v1: columns are only appended; a change of meaning is a _v2 view.
--   4. The demo tenant, only when it is absent: shared.tenants (tenant_id 00000000-0000-0000-0000-000000000002, slug
--      aa-tripplanner, kind demo, plan_tier internal: the content.internal plan, which has no price, so no software fee
--      is drafted for it), its TripPlanner subscription (tripplanner.hosted, active) and an empty site row. The CIS
--      triggers write the content subscription (355 bridge), the entitlements and the account / membership events as
--      for any new tenant. actor 'migration:379'.
--   5. Register 379.
--
-- What a bound tenant sees of the catalogue (decided here, recorded in the contract): AA master rows only. The tour
-- views read catalog._live_tour, which keeps published_tours.tenant_id = the AA master tenant in its WHERE (225 / 273),
-- so binding a tenant (TripPlanner sets app.tenant_id per request since AA-1038 slice 1) never adds the tenant's own
-- CIS rows to v_tour / v_tour_* (the GUC policies only ever add rows, the view's WHERE removes them again). A tenant's
-- own rewritten text in TripPlanner is a later slice (catalog.v_tenant_tour_v1), a separate view with its own rule.
--
-- Behaviour on apply. The demo tenant appears in the CIS admin tenant directory (kind demo) and, through the account
-- feed, in AA-Booking's projection (bk_tenant_pull projects every tenant except kind internal) like the other demo
-- tenants. Nothing reads the view until the AA-1038 slice 2 TripPlanner code is deployed, and that code detects the
-- view (42P01 / 42501 before this file: every /{slug} answers 404 and the bare path keeps the demo tenant).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no '-- migrate:' directive): a new table with a tenant_id column and RLS
-- off on purpose (rule a allowlist) and REVOKE ALL, column GRANTs on existing tables, a view in the hot schema catalog,
-- the catalog.* recipe (role switch, GRANT / REVOKE CREATE) and seed rows in existing tables. MIG-4: migration-only
-- PR; applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a). DM-7.1: the retention row of
-- shared.tenant_tripplanner_site comes in a root PR that is on root master before the Infra bot copy PR of 379.
--
-- Guards (RAISE rolls the whole file back): before — 356 registered (the resolver), the plans tripplanner.hosted and
-- content.internal live, schema catalog owned by cis_owner, and no other tenant holds the demo id or the slug
-- aa-tripplanner. After, as catalog_owner — the view answers and the demo tenant is served. After, as cis_owner — the
-- view's exact columns and types, owner catalog_owner, security_barrier, tripplanner can read it, booking / aa_app_user
-- / cis_app / crm_app cannot, tripplanner has no privilege on the base tables, catalog_owner has no table-level SELECT
-- and no write on them and reads exactly tenant_id, theme, locale of the site table, the theme CHECK refuses a value
-- that is not a colour, and catalog_owner has no CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 323 / 329 / 341 / 347 / 357 / 377): the table and the seed as cis_owner, then
-- GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE
-- cis_owner; REVOKE CREATE. DB Migrate runs the file as cis_owner (login db_migrator). Never RESET ROLE, no SECURITY
-- DEFINER, no role DDL, no dynamic SQL. The conftest replay skips this file (catalog recipe, 245's owners);
-- tests/integration/test_aa1038_migration_379.py applies it the DB Migrate way and undoes it.
--
-- Number. 378 is the highest on main (06/11). If the owner main max + 1 differs at merge, renumber (git grep '379_'
-- and '379' in this file, the test, conftest and the AA-TripPlanner-Web test stub).
--
-- Locks. One CREATE TABLE, column GRANTs, three seed INSERTs (row locks on shared.tenants / tenant_subscription and the
-- trigger writes) and one CREATE VIEW. lock_timeout 5s, statement_timeout 1min. Idempotent (IF NOT EXISTS, CREATE OR
-- REPLACE with the same column list, re-runnable grants, seed only when absent, ON CONFLICT DO NOTHING), one
-- transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after the TripPlanner code is reverted): DROP VIEW
-- catalog.v_tenant_tripplanner_v1; REVOKE SELECT (slug) ON shared.tenants FROM catalog_owner; a destructive file (DRY
-- RUN) for DROP TABLE shared.tenant_tripplanner_site and the demo tenant's rows.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';
SELECT set_config('aa.actor', 'migration:379', true);

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
DECLARE
    demo constant uuid := '00000000-0000-0000-0000-000000000002';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '356') THEN
        RAISE EXCEPTION 'migration 379: apply 356 (the entitlement resolver) first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.plan WHERE plan_key = 'tripplanner.hosted' AND retired_at IS NULL)
       OR NOT EXISTS (SELECT 1 FROM shared.plan WHERE plan_key = 'content.internal' AND retired_at IS NULL) THEN
        RAISE EXCEPTION 'migration 379: the plans tripplanner.hosted and content.internal must be live (355)';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 379: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.tenants WHERE tenant_id = demo AND slug::text <> 'aa-tripplanner')
       OR EXISTS (SELECT 1 FROM shared.tenants WHERE slug::text = 'aa-tripplanner' AND tenant_id <> demo) THEN
        RAISE EXCEPTION 'migration 379: another tenant holds the demo id or the slug aa-tripplanner';
    END IF;
END $$;

-- ── 1. The site settings table ───────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.tenant_tripplanner_site (
    tenant_id   uuid        NOT NULL,
    theme       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    locale      text        NOT NULL DEFAULT 'en',
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  text        NOT NULL,
    CONSTRAINT tenant_tripplanner_site_pkey PRIMARY KEY (tenant_id),
    CONSTRAINT tenant_tripplanner_site_tenant_id_fkey FOREIGN KEY (tenant_id)
        REFERENCES shared.tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT tenant_tripplanner_site_theme_chk CHECK (
        jsonb_typeof(theme) = 'object'
        AND octet_length(theme::text) <= 4096
        AND NOT jsonb_path_exists(theme, '$.keyvalue() ? (!(@.key like_regex "^[a-z][a-z0-9-]{0,39}$"))')
        AND NOT jsonb_path_exists(theme, '$.* ? (@.type() != "string" || !(@ like_regex "^#[0-9a-f]{6}$"))')),
    CONSTRAINT tenant_tripplanner_site_locale_chk CHECK (locale IN ('en', 'vi')),
    CONSTRAINT tenant_tripplanner_site_actor_chk CHECK (char_length(updated_by) BETWEEN 1 AND 64)
);

COMMENT ON TABLE shared.tenant_tripplanner_site IS
    'AA-1038 R5 slice 2 (CIS 379, root ADR 0019 d10): the TripPlanner site settings of a tenant that are not plan '
    'data: theme (kit token name -> #rrggbb colour; empty = the kit defaults) and locale (en | vi). Whether the site is '
    'served comes from the entitlements (tp.hosted), never from this row. Read by TripPlanner through '
    'catalog.v_tenant_tripplanner_v1. No personal data.';
COMMENT ON COLUMN shared.tenant_tripplanner_site.theme IS
    'AA-1038 (379): kit brand tokens as {"<token-name>": "#rrggbb"} (lower-case hex, at most 4 kB). TripPlanner maps '
    'only the token names it knows onto its --aa-* variables and ignores the rest.';
COMMENT ON COLUMN shared.tenant_tripplanner_site.updated_by IS
    'AA-1038 (379): the actor of the last change, admin:<admin_users.id> or migration:<n>. Never an e-mail.';

-- ── Grants (REVOKE first: the Dev default ACL of cis_owner in shared, CIS 245) ─────────────────────────────────────
REVOKE ALL ON shared.tenant_tripplanner_site FROM PUBLIC, cis_app, aa_app_user, catalog_owner;
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.tenant_tripplanner_site TO cis_app;

-- ── 2. What catalog_owner may read ───────────────────────────────────────────────────────────────────────────────
GRANT SELECT (tenant_id, slug, name, account_status, kind) ON shared.tenants TO catalog_owner;
GRANT SELECT (tenant_id, product) ON shared.tenant_subscription TO catalog_owner;
GRANT SELECT (tenant_id, theme, locale) ON shared.tenant_tripplanner_site TO catalog_owner;
GRANT SELECT ON shared.v_tenant_entitlement_resolved TO catalog_owner;

-- ── 4. The demo tenant (only when absent; the triggers add its content subscription, entitlements and events) ────
INSERT INTO shared.tenants (tenant_id, name, slug, plan_tier, rate_limit_rpm, is_active, posts_per_week, kind)
SELECT '00000000-0000-0000-0000-000000000002'::uuid, 'Adventure Asia TripPlanner demo', 'aa-tripplanner',
       'internal'::public.plan_tier_enum, 60, true, 1, 'demo'
 WHERE NOT EXISTS (SELECT 1 FROM shared.tenants WHERE tenant_id = '00000000-0000-0000-0000-000000000002'::uuid);

INSERT INTO shared.tenant_subscription (tenant_id, product, plan_key, status, updated_by)
SELECT '00000000-0000-0000-0000-000000000002'::uuid, 'tripplanner', 'tripplanner.hosted', 'active', 'migration:379'
 WHERE NOT EXISTS (SELECT 1 FROM shared.tenant_subscription
                    WHERE tenant_id = '00000000-0000-0000-0000-000000000002'::uuid AND product = 'tripplanner');

INSERT INTO shared.tenant_tripplanner_site (tenant_id, updated_by)
VALUES ('00000000-0000-0000-0000-000000000002'::uuid, 'migration:379')
ON CONFLICT (tenant_id) DO NOTHING;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 3. The view: one row per tenant with a TripPlanner subscription ──────────────────────────────────────────────
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
       COALESCE(site.locale, 'en') AS locale
  FROM shared.tenants t
  LEFT JOIN shared.tenant_tripplanner_site site ON site.tenant_id = t.tenant_id
 WHERE t.kind <> 'internal'
   AND EXISTS (SELECT 1 FROM shared.tenant_subscription s
                WHERE s.tenant_id = t.tenant_id AND s.product = 'tripplanner');

COMMENT ON VIEW catalog.v_tenant_tripplanner_v1 IS
    'AA-1038 R5 slice 2 (379, contract tenant.entitlements.v1 1.4, root ADR 0019 d10): one row per tenant with a '
    'TripPlanner subscription (kind internal excluded) for the /{slug} site: the slug, the trading name (brand label), '
    'kind, the lifecycle status, in_service (trial, active, past_due), served (in service and tp.hosted live: answer '
    '/{slug} only then), tp_launcher, tp_branding (BO-8 badge), theme (kit token name -> #rrggbb) and locale. A bound '
    'tenant reads AA master catalogue rows only (catalog._live_tour keeps the master tenant). TripPlanner only. '
    'Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_tenant_tripplanner_v1 TO tripplanner;

-- ── Closing check as catalog_owner: the view answers and the demo tenant is served ───────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM catalog.v_tenant_tripplanner_v1
                    WHERE tenant_id = '00000000-0000-0000-0000-000000000002'::uuid AND slug = 'aa-tripplanner'
                      AND served) THEN
        RAISE EXCEPTION 'migration 379: the demo tenant aa-tripplanner is not served by the view';
    END IF;
    RAISE NOTICE 'migration 379: as catalog_owner, % TripPlanner tenant(s), % served',
        (SELECT count(*) FROM catalog.v_tenant_tripplanner_v1),
        (SELECT count(*) FROM catalog.v_tenant_tripplanner_v1 WHERE served);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner ───────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_tenant_tripplanner_v1';
    r text;
    t text;
    cols text;
    granted text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 379: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 379: % is not security_barrier', v;
    END IF;
    IF NOT pg_catalog.has_table_privilege('tripplanner', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 379: tripplanner cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 379: % can read % (tripplanner only)', r, v;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'tenant_id uuid, slug text, name text, kind text, account_status text, '
                             'in_service boolean, served boolean, tp_launcher boolean, tp_branding boolean, '
                             'theme jsonb, locale text' THEN
        RAISE EXCEPTION 'migration 379: % columns are %', v, cols;
    END IF;
    FOREACH t IN ARRAY ARRAY['shared.tenants', 'shared.tenant_subscription', 'shared.tenant_tripplanner_site',
                             'shared.v_tenant_entitlement_resolved'] LOOP
        IF pg_catalog.has_any_column_privilege('tripplanner', t, 'SELECT')
           OR pg_catalog.has_any_column_privilege('tripplanner', t, 'INSERT')
           OR pg_catalog.has_any_column_privilege('tripplanner', t, 'UPDATE') THEN
            RAISE EXCEPTION 'migration 379: tripplanner can read or change % directly', t;
        END IF;
        IF t <> 'shared.v_tenant_entitlement_resolved'
           AND (pg_catalog.has_table_privilege('catalog_owner', t, 'SELECT')
                OR pg_catalog.has_any_column_privilege('catalog_owner', t, 'INSERT')
                OR pg_catalog.has_any_column_privilege('catalog_owner', t, 'UPDATE')
                OR pg_catalog.has_table_privilege('catalog_owner', t, 'DELETE')) THEN
            RAISE EXCEPTION 'migration 379: catalog_owner has more than column SELECT on %', t;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname, ',' ORDER BY a.attname) INTO granted
      FROM pg_attribute a
     WHERE a.attrelid = 'shared.tenant_tripplanner_site'::regclass AND a.attnum > 0 AND NOT a.attisdropped
       AND pg_catalog.has_column_privilege('catalog_owner', a.attrelid, a.attnum, 'SELECT');
    IF granted IS DISTINCT FROM 'locale,tenant_id,theme' THEN
        RAISE EXCEPTION 'migration 379: catalog_owner reads shared.tenant_tripplanner_site columns %', granted;
    END IF;
    IF pg_catalog.has_table_privilege('aa_app_user', 'shared.tenant_tripplanner_site', 'SELECT')
       OR NOT pg_catalog.has_table_privilege('cis_app', 'shared.tenant_tripplanner_site', 'SELECT, INSERT, UPDATE, DELETE')
       OR pg_catalog.has_table_privilege('public', 'shared.tenant_tripplanner_site', 'SELECT') THEN
        RAISE EXCEPTION 'migration 379: grants on shared.tenant_tripplanner_site are not as designed';
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 379: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

-- ── Closing check: the theme CHECK refuses what is not a colour (savepoint, always rolled back) ──────────────────
DO $$
DECLARE
    bad jsonb;
    refused integer := 0;
BEGIN
    FOREACH bad IN ARRAY ARRAY['[]'::jsonb, '{"accent": "red"}', '{"accent": "#ABCDEF"}', '{"accent": 1}',
                               '{"Accent": "#abcdef"}', '{"accent": "#abcdef; x: y"}'] LOOP
        BEGIN
            UPDATE shared.tenant_tripplanner_site SET theme = bad
             WHERE tenant_id = '00000000-0000-0000-0000-000000000002'::uuid;
        EXCEPTION WHEN check_violation THEN
            refused := refused + 1;
        END;
    END LOOP;
    IF refused <> 6 THEN
        RAISE EXCEPTION 'migration 379: the theme CHECK let % of 6 bad values through', 6 - refused;
    END IF;
    IF (SELECT theme FROM shared.tenant_tripplanner_site
         WHERE tenant_id = '00000000-0000-0000-0000-000000000002'::uuid) IS DISTINCT FROM '{}'::jsonb THEN
        RAISE EXCEPTION 'migration 379: the demo site row changed during the CHECK probe';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('379', now(), 'AA-1038 R5 slice 2: shared.tenant_tripplanner_site, catalog.v_tenant_tripplanner_v1 '
                      '(TripPlanner tenants, served flag, theme, locale) and the demo tenant aa-tripplanner')
ON CONFLICT (version) DO NOTHING;

COMMIT;
