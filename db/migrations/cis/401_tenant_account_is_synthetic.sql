-- Migration 401: AA-1087 (S278, root ADR 0006a A10e) — catalog.v_tenant_account_v1 appends is_synthetic, so
-- AA-Booking can hold its Dev-only E2E write identities to synthetic agencies (contract tenant.entitlements.v1 1.6).
--
-- Why. The tech lead chose (S278, audit gap B2) to build Dev-only write-capable E2E staff identities before the
-- synthetic pilot rehearsal. CIS already marks a synthetic tenant (shared.tenants.is_canary, CIS 058: "TRUE for
-- synthetic canary tenant"; the pilot, is_pilot CIS 354, is never synthetic) and holds its own A10b writes to it
-- (api/core/e2e_staff.SYNTHETIC_TENANT_SQL). Booking reads the CIS tenant account through this contract view only
-- (role booking has no privilege on shared.tenants), so the same rule reaches Booking as a view column.
--
-- What:
--   1. Column-level SELECT for catalog_owner on shared.tenants.is_canary (357 / 377 / 379 hold the other columns; no
--      table-level SELECT, no write).
--   2. catalog.v_tenant_account_v1 replaced with the same eight columns in the same order and one appended column,
--      is_synthetic = (is_canary IS TRUE AND NOT is_pilot): exactly CIS's own synthetic rule (NULL / FALSE canary and
--      the pilot are real). Contract v1: columns are only appended. SELECT stays booking only.
--   3. Register 401.
--
-- Behaviour on apply. None for the existing reader: bk_tenant_pull selects named columns (never *). The AA-Booking
-- E2E write identities (app/auth/e2e_staff.py) detect the column; before this file every one of their writes is
-- refused (fail closed, 403 e2e_synthetic_only), reads are unchanged.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no '-- migrate:' directive): a column GRANT on an existing table and the
-- replacement of an existing catalog view under the catalog.* recipe. MIG-4: migration-only PR; applied on Dev by
-- Infra Migration Apply when the job tables are idle (ADR 0017a). DM-7.1: a view column, no new table.
--
-- Guards (RAISE rolls the whole file back): before — 357 registered, schema catalog owned by cis_owner, the view has
-- exactly 357's eight columns or already this file's nine (re-run). After, as catalog_owner — the view answers. After,
-- as cis_owner — the view's exact columns, owner catalog_owner, security_barrier, booking can read it, tripplanner /
-- aa_app_user / cis_app / crm_app cannot, booking still has no privilege on shared.tenants, catalog_owner reads
-- is_canary and still has no table-level SELECT and no write on shared.tenants, and no CREATE on schema catalog.
--
-- Recipe. The X1 S22 catalog recipe (as 357 / 377 / 379): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL
-- ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as cis_owner
-- (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL, no dynamic SQL. The conftest replay skips
-- this file (catalog recipe, 245's owners); tests/integration/test_aa1087_migration_401.py applies 357 + 401 the DB
-- Migrate way and undoes both.
--
-- Number. 400 is the highest on main (12/11). If the owner main max + 1 differs at
-- merge, renumber (git grep '401_' and '401' in this file, the test and conftest).
--
-- Locks. One column GRANT and one CREATE OR REPLACE VIEW. lock_timeout 5s, statement_timeout 1min. Idempotent,
-- one transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after the Booking E2E write identities are removed, root
-- ADR 0006a A10e removal): a view cannot drop a column in place, so the rollback is a _v2 view or a DROP + CREATE of
-- 357's definition, then REVOKE SELECT (is_canary) ON shared.tenants FROM catalog_owner.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
DECLARE
    cols text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '357') THEN
        RAISE EXCEPTION 'migration 401: apply 357 (catalog.v_tenant_account_v1) first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 401: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a
     WHERE a.attrelid = 'catalog.v_tenant_account_v1'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols NOT IN ('tenant_id,name,account_status,suspend_reason,in_service,kind,is_pilot,trade_book',
                    'tenant_id,name,account_status,suspend_reason,in_service,kind,is_pilot,trade_book,is_synthetic')
    THEN
        RAISE EXCEPTION 'migration 401: catalog.v_tenant_account_v1 has columns % (expected 357''s)', cols;
    END IF;
END $$;

-- ── 1. What catalog_owner may read ───────────────────────────────────────────────────────────────────────────────
GRANT SELECT (is_canary) ON shared.tenants TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 2. The view: 357's columns, is_synthetic appended ────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tenant_account_v1 WITH (security_barrier = true) AS
SELECT t.tenant_id,
       t.name::text AS name,
       t.account_status,
       t.suspend_reason,
       t.account_status IN ('trial', 'active', 'past_due') AS in_service,
       t.kind,
       t.is_pilot,
       EXISTS (SELECT 1 FROM shared.v_tenant_entitlement_resolved r
                WHERE r.tenant_id = t.tenant_id AND r.feature_key = 'trade.book') AS trade_book,
       (t.is_canary IS TRUE AND NOT t.is_pilot) AS is_synthetic
  FROM shared.tenants t;

COMMENT ON VIEW catalog.v_tenant_account_v1 IS
    'AA-1028 R1 slice 2 (357, contract tenant.entitlements.v1 1.1, root ADR 0019 d1 / d9): one row per CIS tenant for '
    'the Booking projection booking.b2b_partners (bk_tenant_pull): the trading name, the lifecycle status, in_service '
    '(trial, active, past_due: serve the tenant only then), kind (agency, demo, internal), the pilot marker and '
    'trade_book (the trade.book entitlement is live). AA-1087 (401, 1.6): is_synthetic = is_canary IS TRUE and not the '
    'pilot (the Booking E2E write identities touch synthetic agencies only). Booking only. Contract v1: columns are '
    'only appended.';

GRANT SELECT ON catalog.v_tenant_account_v1 TO booking;

-- ── Closing check as catalog_owner: the view answers ─────────────────────────────────────────────────────────────
DO $$
BEGIN
    RAISE NOTICE 'migration 401: as catalog_owner, % tenant row(s), % synthetic',
        (SELECT count(*) FROM catalog.v_tenant_account_v1),
        (SELECT count(*) FROM catalog.v_tenant_account_v1 WHERE is_synthetic);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner ───────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_tenant_account_v1';
    r text;
    cols text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 401: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 401: % is not security_barrier', v;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'booking')
       AND NOT pg_catalog.has_table_privilege('booking', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 401: booking cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 401: % can read % (booking only)', r, v;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM
       'tenant_id,name,account_status,suspend_reason,in_service,kind,is_pilot,trade_book,is_synthetic' THEN
        RAISE EXCEPTION 'migration 401: % columns are %', v, cols;
    END IF;
    IF (SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
         WHERE a.attrelid = v::regclass AND a.attname = 'is_synthetic') <> 'boolean' THEN
        RAISE EXCEPTION 'migration 401: %.is_synthetic is not boolean', v;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'booking')
       AND (pg_catalog.has_any_column_privilege('booking', 'shared.tenants', 'SELECT')
            OR pg_catalog.has_any_column_privilege('booking', 'shared.tenants', 'UPDATE')) THEN
        RAISE EXCEPTION 'migration 401: booking can read or change shared.tenants directly';
    END IF;
    IF NOT pg_catalog.has_column_privilege('catalog_owner', 'shared.tenants', 'is_canary', 'SELECT') THEN
        RAISE EXCEPTION 'migration 401: catalog_owner cannot read shared.tenants.is_canary';
    END IF;
    IF pg_catalog.has_table_privilege('catalog_owner', 'shared.tenants', 'SELECT')
       OR pg_catalog.has_any_column_privilege('catalog_owner', 'shared.tenants', 'INSERT')
       OR pg_catalog.has_any_column_privilege('catalog_owner', 'shared.tenants', 'UPDATE')
       OR pg_catalog.has_table_privilege('catalog_owner', 'shared.tenants', 'DELETE') THEN
        RAISE EXCEPTION 'migration 401: catalog_owner has more than column SELECT on shared.tenants';
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 401: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('401', now(), 'AA-1087: catalog.v_tenant_account_v1 appends is_synthetic (is_canary and not the pilot) for '
                      'the Booking E2E write identities; column SELECT for catalog_owner on shared.tenants.is_canary')
ON CONFLICT (version) DO NOTHING;

COMMIT;
