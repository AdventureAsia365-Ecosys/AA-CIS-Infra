-- Migration 474: AA-1160 (S289, the S285 live check of the agency app's Trip planner module) — CIS records when the
-- CRM last proved a tenant's CRM agency (the table shared.tenant_crm_agency and its sighting window setting), and
-- catalog.v_tenant_tripplanner_v1 appends the agency's own fallback route (contract tenant.entitlements.v1 1.11;
-- columns are only appended).
--
-- Why. The lead route of a TripPlanner tenant resolves to crm as soon as the CRM add-on (crm.core) is live (CIS 390).
-- A CRM agency (AA-Partner crm.tenant) is created later, by the CIS CRM onboarding (AA-1116) or the CRM's own console,
-- and may never be; it may also be locked, offboarded or deleted later. S285 found a synthetic tenant with crm.core and
-- no CRM agency whose planner leads went to the CRM, which skipped them (skipped_agency), so they reached neither the
-- CRM nor the agency's e-mail / webhook route. Two consumers need to know whether the CRM can take the leads now:
--   * TripPlanner routes on its own liveness signal, the CRM lead pull beacon (the CRM lists only an agency it can
--     serve: active and routed to it; a locked, offboarding or deleted agency raises before the list call). When the
--     beacon is stale it takes the agency's own route, which this view now carries (fallback_*), and re-routes the
--     tenant's pending CRM leads to it once. It needs no CIS marker.
--   * The CIS agency module (tenant.addons.v1 effective_channel) and Tenant 360 say which route the leads take. CIS may
--     not read CRM tables (root ADR 0008a), so it records what the CRM itself proves: the CRM's entitlement feed reads
--     the tenant.entitlements.v1 snapshot (GET /tenant/v1/tenants/{id}/account) of every agency it holds, on each
--     account event and in an hourly pass over all of them, and the CIS CRM onboarding sees the agency exist or be
--     created. The CIS code PR of AA-1160 refreshes a row here on each of those. A sighting counts only while it is
--     younger than cis.tenant.crm_agency_seen_hours (a deleted or offboarded agency is never read again, so its row
--     ages out); the window is an admin-editable setting (tech lead S279), never a literal of a view.
--
-- What:
--   Part A (cis_owner, the owner of shared since 245; the conftest replay runs this part only, _replay_parts.py):
--   1. shared.tenant_crm_agency — one row per tenant the CRM proved an agency for:
--        tenant_id      PK, FK shared.tenants ON DELETE CASCADE;
--        first_seen_at  when CIS first saw the agency;
--        last_seen_at   the latest sighting (the CIS code refreshes it at most every few minutes: a write throttle,
--                       not a policy value); readers count the row only while it is inside the window of item 2;
--        source         the latest sighting's source: crm_pull (the CRM read the snapshot with its M2M client) or
--                       crm_onboarding (the CIS onboarding found or created the agency).
--      No personal data (ids and times). No RLS, like the other control-plane tables of shared (tenant_tripplanner_site
--      379, tenant_tripplanner_domain 428): read and written only by the CIS API as cis_app, never by TripPlanner or a
--      tenant role (rls catalogue rule a allowlist). Grants: REVOKE ALL first (the Dev default ACL of cis_owner in
--      shared, CIS 245), then cis_app SELECT, INSERT, UPDATE, DELETE (the sightings and the AA-839 tenant erasure).
--      Retention: root DM-7.1 row shared.tenant_crm_agency (kept while the tenant exists; erased with it, FK cascade
--      as the backstop).
--   2. One row in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR), area tenant, scope platform, maker-checker, enforced
--      (services/tenant_account/crm_agency_settings.py names the key in this PR; the code PR reads it):
--        cis.tenant.crm_agency_seen_hours   int hours 2-168, default 3 (the CRM re-reads every held agency hourly)
--      With its plain label and its EN + VI operator guide (CIS 416 rule).
--   Part B (the X1 S22 catalog recipe, as 379 / 390 / 429 / 438):
--   3. catalog.v_tenant_tripplanner_v1 appends (the 438 body unchanged before them, same rows):
--        fallback_channel      text    — the agency's own route, as if it had no CRM add-on: webhook / email when the
--                                         site stores that channel with its target, else none;
--        fallback_webhook_url  text    — the target of a webhook fallback, else NULL;
--        fallback_email        text    — the target of an e-mail fallback, else NULL.
--      lead_channel keeps its 390 meaning (crm while crm.core is live). TripPlanner (AA-1160 code) sends a lead to the
--      CRM only while the CRM pulled the tenant lately (its beacon), else to the fallback, and re-routes the tenant's
--      pending CRM leads once to that fallback. The view does not read shared.tenant_crm_agency.
--   4. Register 474.
--
-- Behaviour on apply. An empty table and a setting at its default: nothing reads either before the CIS code PR. The
-- fallback columns equal 390's lead_webhook_url / lead_email for every tenant whose lead_channel is not crm, and
-- nothing reads them before the TripPlanner code PR of AA-1160.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a new table with a tenant_id and RLS off on
-- purpose (rule a allowlist), REVOKE on it, a config row INSERTed into shared.setting_definition and a replaced view in
-- the hot schema catalog. MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply when every job table is
-- idle (ADR 0017a), then the CIS code PR and the TripPlanner code PR.
--
-- Guards (RAISE rolls the whole file back): before — 438 registered, schema catalog owned by cis_owner. After Part A —
-- RLS off and the grants as designed, the source CHECK refuses an unknown source, the setting row is there. After
-- Part B, as catalog_owner — the view answers. As cis_owner — the view's exact columns and types, owner catalog_owner,
-- security_barrier, tripplanner can read it and booking / aa_app_user / cis_app / crm_app cannot, neither tripplanner
-- nor catalog_owner holds any privilege on the new table, and catalog_owner has no CREATE on schema catalog any more.
--
-- Recipe. Part A as cis_owner. Part B: GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE catalog_owner;
-- the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as cis_owner (login db_migrator).
-- Never RESET ROLE, no SECURITY DEFINER, no role DDL, no dynamic SQL. The conftest replay runs Part A only
-- (tests/integration/_replay_parts.py); tests/integration/test_aa1160_migration_474.py applies 357, 377, 379, 390,
-- 428's grants, 429, 438 and this file the DB Migrate way and undoes them.
--
-- Number. Owner main max (473) + 1 (renumbered from 475 in the S289 review fix pass). If the owner main max + 1 differs
-- at merge, renumber (git grep '474_' and '474' here, in tests/integration/test_aa1160_migration_474.py,
-- tests/integration/_replay_parts.py, shared/settings/compiled_defaults.json, crm_agency_settings.py and
-- docs/implementation-notes/AA-1160.md).
--
-- Locks. One CREATE TABLE (new, empty), one INSERT of one row and one CREATE OR REPLACE VIEW. lock_timeout 5s,
-- statement_timeout 1min. Idempotent (IF NOT EXISTS, ON CONFLICT DO NOTHING, CREATE OR REPLACE with the same column
-- list, re-runnable grants), one transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after the CIS and TripPlanner code is reverted): restate
-- the 438 view (a view loses appended columns only by DROP + CREATE), DELETE the setting's value rows then its
-- definition, DROP the table.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';
SELECT set_config('aa.actor', 'migration:474', true);

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '438') THEN
        RAISE EXCEPTION 'migration 474: apply 438 (the 438 body of catalog.v_tenant_tripplanner_v1) first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 474: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── Part A: the CRM agency marker (cis_owner) ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.tenant_crm_agency (
    tenant_id      uuid        NOT NULL,
    first_seen_at  timestamptz NOT NULL DEFAULT now(),
    last_seen_at   timestamptz NOT NULL DEFAULT now(),
    source         text        NOT NULL,
    CONSTRAINT tenant_crm_agency_pkey PRIMARY KEY (tenant_id),
    CONSTRAINT tenant_crm_agency_tenant_id_fkey FOREIGN KEY (tenant_id)
        REFERENCES shared.tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT tenant_crm_agency_source_chk CHECK (source IN ('crm_pull', 'crm_onboarding')),
    CONSTRAINT tenant_crm_agency_seen_chk CHECK (last_seen_at >= first_seen_at)
);

COMMENT ON TABLE shared.tenant_crm_agency IS
    'AA-1160 (CIS 474): when the CRM (AA-Partner) last proved it holds an agency for the tenant: the CRM read the '
    'tenant.entitlements.v1 snapshot with its M2M client (it reads it only for an agency it holds, hourly for each), '
    'or the CIS CRM onboarding found or created the agency. A row counts only while last_seen_at is inside the setting '
    'cis.tenant.crm_agency_seen_hours (services/tenant_account/crm_agency.py): the agency module''s effective_channel '
    'and Tenant 360. TripPlanner routes on its own CRM pull beacon. No personal data.';
COMMENT ON COLUMN shared.tenant_crm_agency.source IS
    'AA-1160 (474): the latest sighting: crm_pull (CRM snapshot read) or crm_onboarding (CIS onboarding).';

REVOKE ALL ON shared.tenant_crm_agency FROM PUBLIC, cis_app, aa_app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.tenant_crm_agency TO cis_app;

DO $$
DECLARE
    t constant text := 'shared.tenant_crm_agency';
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class WHERE oid = t::regclass AND relrowsecurity) THEN
        RAISE EXCEPTION 'migration 474: % has row-level security on (the 244 guard keeps the shared RLS set fixed)', t;
    END IF;
    IF NOT pg_catalog.has_table_privilege('cis_app', t, 'SELECT, INSERT, UPDATE, DELETE')
       OR pg_catalog.has_table_privilege('aa_app_user', t, 'SELECT')
       OR pg_catalog.has_table_privilege('public', t, 'SELECT') THEN
        RAISE EXCEPTION 'migration 474: grants on % are not as designed', t;
    END IF;
    BEGIN
        INSERT INTO shared.tenant_crm_agency (tenant_id, source)
        VALUES ('00000000-0000-0000-0000-000000000000'::uuid, 'crm_guess');
        RAISE EXCEPTION 'migration 474: the source CHECK let an unknown source through';
    EXCEPTION
        WHEN check_violation THEN NULL;
    END;
END $$;

-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$
[
{"key": "cis.tenant.crm_agency_seen_hours", "app": "cis", "area": "tenant", "label": "CRM agency counts as live for (hours after the CRM last proved it)", "description": "The agency module (tenant.addons.v1 effective_channel) and the Tenant 360 lead route say the Trip planner's leads go to the CRM only while the CRM add-on is live AND the CRM proved the tenant's CRM agency within this many hours (shared.tenant_crm_agency.last_seen_at, CIS 474: the CRM read the account snapshot of an agency it holds, which its entitlement feed does on each account event and hourly for every agency, or the CIS CRM onboarding found or created the agency). Past it, CIS shows the agency's own route (webhook, e-mail or none). TripPlanner routes each lead on its own CRM pull beacon, not on this value. Read by services/tenant_account/crm_agency.py.", "value_type": "int", "unit": "hours", "min_value": 2, "max_value": 168, "allowed_values": null, "default_value": 3, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How long after the CRM last showed that it holds a tenant's agency the agency app and Tenant 360 still say that the planner's leads go to the CRM. The CRM re-reads every agency it holds at least once an hour, so a live agency stays inside the window; a deleted or offboarded agency drops out of it.", "raise": "A short CRM outage never makes the agency app say the leads take the agency's own route, but a deleted CRM agency keeps showing the CRM route longer.", "lower": "A CRM agency that was deleted or offboarded stops showing the CRM route sooner; below two hourly CRM passes a slow CRM pass can make the label flicker.", "when": "Raise it when the CRM's hourly pass is slowed down for a long time; lower it only if staff need the label to follow a deleted CRM agency faster.", "example": "With the default of 3 hours, an agency deleted in the CRM at 09:00 (last seen 08:40) shows its own route from 11:40."}, "vi": {"what": "Bao lâu sau lần cuối CRM chứng minh nó giữ đại lý của một tenant thì app đại lý và Tenant 360 vẫn ghi lead của planner đi vào CRM. CRM đọc lại mọi đại lý nó giữ ít nhất mỗi giờ một lần, nên đại lý còn hoạt động luôn nằm trong khung; đại lý đã xoá hoặc offboard sẽ rơi ra ngoài.", "raise": "CRM gián đoạn ngắn không làm app đại lý ghi lead đi đường riêng của đại lý, nhưng đại lý CRM đã xoá vẫn hiện đường CRM lâu hơn.", "lower": "Đại lý CRM đã xoá hoặc offboard thôi hiện đường CRM sớm hơn; dưới hai lượt đọc hằng giờ của CRM thì một lượt chậm có thể làm nhãn nhấp nháy.", "when": "Tăng khi lượt đọc hằng giờ của CRM bị chậm lâu; chỉ giảm khi nhân viên cần nhãn theo kịp đại lý CRM đã xoá.", "example": "Với mặc định 3 giờ, đại lý bị xoá trong CRM lúc 09:00 (thấy lần cuối 08:40) hiện đường riêng từ 11:40."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.setting_definition WHERE key IN ('cis.tenant.crm_agency_seen_hours')) THEN
        RAISE EXCEPTION 'migration 474: the setting cis.tenant.crm_agency_seen_hours is not seeded';
    END IF;
END $$;

-- ── Part B: catalog.v_tenant_tripplanner_v1 (X1 S22 catalog recipe) ──────────────────────────────────────────────
GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

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
       (SELECT r.limit_value FROM shared.v_tenant_entitlement_resolved r
         WHERE r.tenant_id = t.tenant_id AND r.feature_key = 'tp.ai_sessions')::integer AS ai_sessions_monthly,
       -- 474: the agency's own route as if it had no CRM add-on
       fallback.channel AS fallback_channel,
       CASE WHEN fallback.channel = 'webhook' THEN site.lead_webhook_url END AS fallback_webhook_url,
       CASE WHEN fallback.channel = 'email' THEN site.lead_email END AS fallback_email
  FROM shared.tenants t
  LEFT JOIN shared.tenant_tripplanner_site site ON site.tenant_id = t.tenant_id
 CROSS JOIN LATERAL (
        SELECT EXISTS (SELECT 1 FROM shared.v_tenant_entitlement_resolved r
                        WHERE r.tenant_id = t.tenant_id AND r.feature_key = 'crm.core') AS live
       ) crm
 CROSS JOIN LATERAL (
        SELECT CASE WHEN site.lead_channel = 'webhook' AND site.lead_webhook_url IS NOT NULL THEN 'webhook'
                    WHEN site.lead_channel = 'email' AND site.lead_email IS NOT NULL THEN 'email'
                    ELSE 'none' END AS channel
       ) fallback
 CROSS JOIN LATERAL (
        SELECT CASE WHEN crm.live THEN 'crm' ELSE fallback.channel END AS channel
       ) route
 WHERE t.kind <> 'internal'
   AND EXISTS (SELECT 1 FROM shared.tenant_subscription s
                WHERE s.tenant_id = t.tenant_id AND s.product = 'tripplanner');

COMMENT ON VIEW catalog.v_tenant_tripplanner_v1 IS
    'AA-1038 R5 slices 2-3, AA-1090 R8, AA-1116, AA-1160 (379, 390, 429, 438, 474; contract tenant.entitlements.v1 '
    '1.11, root ADR 0019 d10, d11, b4): one row per tenant with a TripPlanner subscription (kind internal excluded) for '
    'the /{slug} site: the slug, the trading name (brand label), kind, the lifecycle status, in_service (trial, active, '
    'past_due), served (in service and tp.hosted live: answer /{slug} only then), tp_launcher, tp_branding (BO-8 badge), '
    'theme (kit token name -> #rrggbb) and locale; 390: crm_core and the resolved lead route with its target (crm while '
    'crm.core is live); 429: custom_domains, the active custom hosts of the site (served only when served is true); '
    '438: ai_sessions_monthly (resolved tp.ai_sessions, NULL = no limit); 474: the fallback route (fallback_channel '
    'webhook / email / none with its target: the route without the CRM add-on). TripPlanner sends a lead to the CRM '
    'only while the CRM pulled the tenant lately (its beacon), else to the fallback. A bound tenant reads AA master '
    'catalogue rows only. TripPlanner only. Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_tenant_tripplanner_v1 TO tripplanner;

-- ── Closing check as catalog_owner: the view answers ─────────────────────────────────────────────────────────────
DO $$
BEGIN
    RAISE NOTICE 'migration 474: as catalog_owner, % TripPlanner tenant(s), % with a stored fallback route',
        (SELECT count(*) FROM catalog.v_tenant_tripplanner_v1),
        (SELECT count(*) FROM catalog.v_tenant_tripplanner_v1 WHERE fallback_channel <> 'none');
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner ───────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_tenant_tripplanner_v1';
    t constant text := 'shared.tenant_crm_agency';
    r text;
    cols text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 474: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 474: % is not security_barrier', v;
    END IF;
    IF NOT pg_catalog.has_table_privilege('tripplanner', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 474: tripplanner cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 474: % can read % (tripplanner only)', r, v;
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'tripplanner')
       AND pg_catalog.has_table_privilege('tripplanner', t, 'SELECT') THEN
        RAISE EXCEPTION 'migration 474: tripplanner can read % (only through the view)', t;
    END IF;
    IF pg_catalog.has_column_privilege('catalog_owner', t, 'tenant_id', 'SELECT')
       OR pg_catalog.has_table_privilege('catalog_owner', t, 'SELECT, INSERT, UPDATE, DELETE') THEN
        RAISE EXCEPTION 'migration 474: catalog_owner holds a privilege on % (the view does not read it)', t;
    END IF;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'tenant_id uuid, slug text, name text, kind text, account_status text, '
                             'in_service boolean, served boolean, tp_launcher boolean, tp_branding boolean, '
                             'theme jsonb, locale text, crm_core boolean, lead_channel text, lead_webhook_url text, '
                             'lead_email text, custom_domains text[], ai_sessions_monthly integer, '
                             'fallback_channel text, fallback_webhook_url text, fallback_email text' THEN
        RAISE EXCEPTION 'migration 474: % columns are %', v, cols;
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 474: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('474', now(), 'AA-1160: shared.tenant_crm_agency (CRM agency marker), cis.tenant.crm_agency_seen_hours and '
                      'catalog.v_tenant_tripplanner_v1 fallback route columns')
ON CONFLICT (version) DO NOTHING;

COMMIT;
