-- Migration 357: AA-1028 R1 slice 2 (root ADR 0019 d1, d2, d9) — Booking's read of the tenant account: the contract
-- view catalog.v_tenant_account_v1 (tenant.entitlements.v1 1.1, the view part for Booking).
--
-- Why. ADR 0019 d1 / d9: booking.b2b_partners becomes a read-only projection of the CIS tenant master, written by
-- Booking's own pull job bk_tenant_pull, with one row for every tenant (Content-only included; m2m_client_id = the
-- AA-Partner client, d9). Booking reads the CIS control plane through catalog contract views only (role booking has
-- USAGE on schema catalog, never on shared; root owners.yaml consumer_grants "catalog.* (schema + views)", CIS 225 /
-- 228), as it reads catalog.v_tour_lifecycle_outbox (274). So the account facts Booking projects are served by a
-- view, not over HTTP: no new Cognito client, scope or secret.
--
-- What:
--   1. Column-level SELECT for catalog_owner on shared.tenants (tenant_id, name, account_status, suspend_reason, kind,
--      is_pilot): never the API key hash, the bill-to fields (DM-6.1 personal data, R4 reads them under its own
--      scope) or the settings; and SELECT on shared.v_tenant_entitlement_resolved (the live resolver, 353 / 356) for
--      the trade.book flag.
--   2. catalog.v_tenant_account_v1 (security_barrier, owner catalog_owner): one row per tenant: tenant_id, name (the
--      agency's trading name, which booking.b2b_partners.agency_name already holds), account_status, suspend_reason,
--      in_service (account_status trial, active or past_due, the contract's rule), kind (agency, demo, internal),
--      is_pilot and trade_book (the trade.book entitlement is live). SELECT to booking only. Contract v1: columns
--      are only appended; a change of meaning is a _v2 view.
--   3. Register 357.
--
-- Behaviour. None on apply: nothing reads the view until the AA-Booking bk_tenant_pull code is deployed, and that
-- code detects the view (42P01 / 42501 before this file: the job answers skipped).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no expand header): column GRANTs on an existing table, a GRANT on an
-- existing view, a DO guard and the catalog.* recipe (role switch, GRANT / REVOKE CREATE). MIG-4: migration-only PR
-- with 356; on Dev a person applies it after 356 with DB Migrate apply (Infra Migration Apply stops at the pending
-- 336, see 356). DM-7.1: a view, no new table.
--
-- Guards (RAISE rolls the whole file back): before — 356 registered, schema catalog owned by cis_owner. After, as
-- catalog_owner — the view answers one row per tenant. After, as cis_owner — the view's exact columns, owner
-- catalog_owner, security_barrier, booking can read it, tripplanner / aa_app_user / cis_app / crm_app cannot, booking
-- has no privilege on shared.tenants, catalog_owner reads exactly the six columns of shared.tenants and has no other
-- privilege on it, catalog_owner has no CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 323 / 329 / 341 / 347): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET
-- LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as
-- cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL, no dynamic SQL. The conftest
-- replay skips this file (catalog recipe, 245's owners); tests/integration/test_aa1028_migration_357.py applies it
-- the DB Migrate way and undoes it.
--
-- Number. 355 is the highest on main (03/11) and 356 comes in the same PR. If another lane lands 356 / 357 first,
-- renumber to the owner main max + 1 (git grep '357_' and '357' in this file, the test and conftest).
--
-- Locks. Column GRANTs and one CREATE VIEW. lock_timeout 5s, statement_timeout 1min. Idempotent (CREATE OR REPLACE
-- with the same column list, re-runnable grants, ON CONFLICT DO NOTHING), one transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after the Booking pull is switched off): DROP VIEW
-- catalog.v_tenant_account_v1; REVOKE SELECT (the columns above) ON shared.tenants FROM catalog_owner; REVOKE SELECT ON
-- shared.v_tenant_entitlement_resolved FROM catalog_owner.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '356') THEN
        RAISE EXCEPTION 'migration 357: apply 356 (the resolver fixes) first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 357: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read ───────────────────────────────────────────────────────────────────────────────
GRANT SELECT (tenant_id, name, account_status, suspend_reason, kind, is_pilot) ON shared.tenants TO catalog_owner;
GRANT SELECT ON shared.v_tenant_entitlement_resolved TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 2. The view: one row per tenant ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tenant_account_v1 WITH (security_barrier = true) AS
SELECT t.tenant_id,
       t.name::text AS name,
       t.account_status,
       t.suspend_reason,
       t.account_status IN ('trial', 'active', 'past_due') AS in_service,
       t.kind,
       t.is_pilot,
       EXISTS (SELECT 1 FROM shared.v_tenant_entitlement_resolved r
                WHERE r.tenant_id = t.tenant_id AND r.feature_key = 'trade.book') AS trade_book
  FROM shared.tenants t;

COMMENT ON VIEW catalog.v_tenant_account_v1 IS
    'AA-1028 R1 slice 2 (357, contract tenant.entitlements.v1 1.1, root ADR 0019 d1 / d9): one row per CIS tenant for '
    'the Booking projection booking.b2b_partners (bk_tenant_pull): the trading name, the lifecycle status, in_service '
    '(trial, active, past_due: serve the tenant only then), kind (agency, demo, internal), the pilot marker and '
    'trade_book (the trade.book entitlement is live). Booking only. Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_tenant_account_v1 TO booking;

-- ── Closing check as catalog_owner: the view answers ─────────────────────────────────────────────────────────────
DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM catalog.v_tenant_account_v1;
    RAISE NOTICE 'migration 357: as catalog_owner, % tenant row(s), % in service, % with trade.book', n,
        (SELECT count(*) FROM catalog.v_tenant_account_v1 WHERE in_service),
        (SELECT count(*) FROM catalog.v_tenant_account_v1 WHERE trade_book);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner: columns, owner, barrier, exact consumer grant, column grants ─────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_tenant_account_v1';
    r text;
    cols text;
    granted text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 357: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 357: % is not security_barrier', v;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'booking')
       AND NOT pg_catalog.has_table_privilege('booking', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 357: booking cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 357: % can read % (booking only)', r, v;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'tenant_id,name,account_status,suspend_reason,in_service,kind,is_pilot,trade_book' THEN
        RAISE EXCEPTION 'migration 357: % columns are %', v, cols;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'booking')
       AND (pg_catalog.has_any_column_privilege('booking', 'shared.tenants', 'SELECT')
            OR pg_catalog.has_any_column_privilege('booking', 'shared.tenants', 'UPDATE')) THEN
        RAISE EXCEPTION 'migration 357: booking can read or change shared.tenants directly';
    END IF;
    SELECT string_agg(a.attname, ',' ORDER BY a.attname) INTO granted
      FROM pg_attribute a
     WHERE a.attrelid = 'shared.tenants'::regclass AND a.attnum > 0 AND NOT a.attisdropped
       AND pg_catalog.has_column_privilege('catalog_owner', a.attrelid, a.attnum, 'SELECT');
    IF granted IS DISTINCT FROM 'account_status,is_pilot,kind,name,suspend_reason,tenant_id' THEN
        RAISE EXCEPTION 'migration 357: catalog_owner reads shared.tenants columns %', granted;
    END IF;
    IF pg_catalog.has_table_privilege('catalog_owner', 'shared.tenants', 'SELECT')
       OR pg_catalog.has_any_column_privilege('catalog_owner', 'shared.tenants', 'INSERT')
       OR pg_catalog.has_any_column_privilege('catalog_owner', 'shared.tenants', 'UPDATE')
       OR pg_catalog.has_table_privilege('catalog_owner', 'shared.tenants', 'DELETE') THEN
        RAISE EXCEPTION 'migration 357: catalog_owner has more than column SELECT on shared.tenants';
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 357: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('357', now(), 'AA-1028 R1 slice 2: catalog.v_tenant_account_v1 (tenant account facts) for the Booking '
                      'projection; column SELECT for catalog_owner on shared.tenants')
ON CONFLICT (version) DO NOTHING;

COMMIT;
