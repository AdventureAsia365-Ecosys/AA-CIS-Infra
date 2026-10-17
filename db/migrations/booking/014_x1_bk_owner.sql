-- Migration bk-014: AA-852 (X1 plan S6) — every booking.* object moves from the RDS master aa_cis_admin to the
-- NOLOGIN owner role bk_owner, and the default privileges of role booking are restated FOR ROLE bk_owner.
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra db/migrations/booking/014_x1_bk_owner.sql
-- and is applied to Dev by the DB Migrate workflow (check, then apply), as aa_cis_admin (the live owner of schema
-- booking when the file starts, X1 XD8). Never run it from a laptop.
--
-- Why (ADR 0008 decision 6, data standards SEC-1, DM-1.3; AA-Ecosys docs/audits/2026-10-17-S241-x1/x1-plan.md):
-- Booking's objects (customer PII, pricing, supplier rates) must not be owned by the role the CIS runtime logs in as.
-- After this file DB Migrate runs every later booking/ file as bk_owner (it reads the live owner of schema booking
-- before each file and SET ROLEs to it), so bk-015+ create objects owned by bk_owner and covered by its default
-- privileges, with no gap and no runner change. The runtime role booking keeps exactly the privileges it has.
--
-- Depends on: Infra roles/001_x1_owner_roles.sql (rl-001: bk_owner NOLOGIN, GRANT bk_owner TO aa_cis_admin) and
-- CIS 243 (USAGE on shared + SELECT, INSERT on shared.schema_versions to bk_owner: the registration below runs as
-- aa_cis_admin, but from bk-015 on it runs as bk_owner, and booking.v_schema_versions — owned by bk_owner from here —
-- reads shared.schema_versions with its owner's rights for GET /booking/health/ready). Applied in the X1 S8 train:
-- rl-001 -> 243 -> bk-014 -> tp-013. The first guard refuses the file when either is missing.
--
-- Objects (34 relations + 12 functions; list from bk-001..bk-013 replayed on PostgreSQL 15/16 and the schema
-- reference dump of 2026-10-16, Booking bk-013; no static introspection of Dev was possible for this PR — the last
-- guard raises if Dev has any object this list misses, then regenerate the list):
--   * 32 tables + 2 views (ALTER TABLE carries their indexes, row types and owned/identity sequences:
--     trip_case_status_history.seq);
--   * 5 standalone sequences (no pg_depend 'a'/'i' row, so a table owner change does not carry them);
--   * 12 trigger functions (none SECURITY DEFINER; Booking has no types of its own).
-- Grants: ALTER ... OWNER rewrites every ACL to the new owner (grantor aa_cis_admin -> bk_owner), so the privileges
-- of role booking (and of anyone else) are unchanged; the last guard compares them with a snapshot taken first.
-- Default privileges: bk-001's three rows FOR ROLE aa_cis_admin IN SCHEMA booking are restated FOR ROLE bk_owner and
-- the old rows revoked (the master creates nothing in booking any more).
-- Undo (not a booking/ file: once bk_owner owns the schema the runner runs booking/ files as bk_owner, which cannot
-- give objects to aa_cis_admin): a prepared Infra-native roles/ file (rl-0xx), kept unmerged. Never key bk-015.
--
-- Locks: ALTER ... OWNER takes ACCESS EXCLUSIVE on each object for milliseconds; lock_timeout 5s; DB Migrate refuses
-- apply while booking.job (or any job table) is busy. booking.job, inbox_events, customers are the hot tables.
-- Re-running the whole file is a no-op (owner already bk_owner, idempotent default privileges, ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── 1. Guard + snapshot ──────────────────────────────────────────────────────

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bk_owner' AND NOT rolcanlogin) THEN
        RAISE EXCEPTION 'bk-014: role bk_owner (NOLOGIN) is missing: apply Infra roles/001_x1_owner_roles.sql (rl-001) first';
    END IF;
    IF NOT pg_has_role(current_user, 'bk_owner', 'MEMBER') THEN
        RAISE EXCEPTION 'bk-014: % is not a member of bk_owner (rl-001 grants it to aa_cis_admin)', current_user;
    END IF;
    IF NOT has_database_privilege(current_database(), 'CREATE') THEN
        RAISE EXCEPTION 'bk-014: % lacks CREATE on the database (needed for ALTER SCHEMA ... OWNER)', current_user;
    END IF;
    IF NOT (has_schema_privilege('bk_owner', 'shared', 'USAGE')
            AND has_table_privilege('bk_owner', 'shared.schema_versions', 'SELECT')
            AND has_table_privilege('bk_owner', 'shared.schema_versions', 'INSERT')) THEN
        RAISE EXCEPTION 'bk-014: bk_owner needs USAGE on schema shared and SELECT, INSERT on shared.schema_versions: apply CIS 243 first';
    END IF;
END $$;

-- Privileges of every role other than the owner on schema booking and everything in it (relations, columns,
-- functions), owner-independent: grantor and the owner's own entries left out. Compared in step 5.
SELECT set_config('bk014.privileges_before', coalesce(string_agg(p, ',' ORDER BY p), ''), true)
FROM (
    SELECT format('schema:%s:%s:%s', a.grantee::regrole, a.privilege_type, a.is_grantable) AS p
    FROM pg_namespace n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
    WHERE n.nspname = 'booking' AND a.grantee <> n.nspowner
    UNION ALL
    SELECT format('rel:%s:%s:%s:%s', c.relname, a.grantee::regrole, a.privilege_type, a.is_grantable)
    FROM pg_class c,
         aclexplode(coalesce(c.relacl, acldefault(CASE WHEN c.relkind = 'S' THEN 's'::"char" ELSE 'r'::"char" END, c.relowner))) a
    WHERE c.relnamespace = 'booking'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
      AND a.grantee <> c.relowner
    UNION ALL
    SELECT format('col:%s.%s:%s:%s:%s', c.relname, t.attname, a.grantee::regrole, a.privilege_type, a.is_grantable)
    FROM pg_class c JOIN pg_attribute t ON t.attrelid = c.oid, aclexplode(t.attacl) a
    WHERE c.relnamespace = 'booking'::regnamespace AND t.attacl IS NOT NULL AND a.grantee <> c.relowner
    UNION ALL
    SELECT format('fn:%s:%s:%s:%s', f.oid::regprocedure, a.grantee::regrole, a.privilege_type, a.is_grantable)
    FROM pg_proc f, aclexplode(coalesce(f.proacl, acldefault('f', f.proowner))) a
    WHERE f.pronamespace = 'booking'::regnamespace AND a.grantee <> f.proowner
) s;

-- ── 2. Schema first (the new owner needs CREATE on it for the objects below) ──

ALTER SCHEMA booking OWNER TO bk_owner;

-- ── 3. Objects ───────────────────────────────────────────────────────────────

ALTER TABLE booking.audit_logs OWNER TO bk_owner;
ALTER TABLE booking.countries OWNER TO bk_owner;
ALTER TABLE booking.customer_otps OWNER TO bk_owner;
ALTER TABLE booking.customer_sessions OWNER TO bk_owner;
ALTER TABLE booking.customers OWNER TO bk_owner;
ALTER TABLE booking.fx_rates OWNER TO bk_owner;
ALTER TABLE booking.hotel_room_types OWNER TO bk_owner;
ALTER TABLE booking.hotels OWNER TO bk_owner;
ALTER TABLE booking.inbox_cursor OWNER TO bk_owner;
ALTER TABLE booking.inbox_events OWNER TO bk_owner;
ALTER TABLE booking.job OWNER TO bk_owner;
ALTER TABLE booking.media_files OWNER TO bk_owner;
ALTER TABLE booking.notification_reads OWNER TO bk_owner;
ALTER TABLE booking.notifications OWNER TO bk_owner;
ALTER TABLE booking.policy_approvals OWNER TO bk_owner;
ALTER TABLE booking.pricing_rules OWNER TO bk_owner;
ALTER TABLE booking.services OWNER TO bk_owner;
ALTER TABLE booking.settings OWNER TO bk_owner;
ALTER TABLE booking.staff_assignments OWNER TO bk_owner;
ALTER TABLE booking.staff_users OWNER TO bk_owner;
ALTER TABLE booking.supplier_contracts OWNER TO bk_owner;
ALTER TABLE booking.supplier_rates OWNER TO bk_owner;
ALTER TABLE booking.suppliers OWNER TO bk_owner;
ALTER TABLE booking.trip_case_countries OWNER TO bk_owner;
ALTER TABLE booking.trip_case_legs OWNER TO bk_owner;
ALTER TABLE booking.trip_case_status_history OWNER TO bk_owner;
ALTER TABLE booking.trip_case_status_transitions OWNER TO bk_owner;
ALTER TABLE booking.trip_case_version_itinerary OWNER TO bk_owner;
ALTER TABLE booking.trip_case_versions OWNER TO bk_owner;
ALTER TABLE booking.trip_cases OWNER TO bk_owner;
ALTER TABLE booking.trip_plans OWNER TO bk_owner;
ALTER TABLE booking.version_item_costs OWNER TO bk_owner;

ALTER VIEW booking.v_customer_summary OWNER TO bk_owner;
ALTER VIEW booking.v_schema_versions OWNER TO bk_owner;

ALTER SEQUENCE booking.customer_code_seq OWNER TO bk_owner;
ALTER SEQUENCE booking.hotel_code_seq OWNER TO bk_owner;
ALTER SEQUENCE booking.service_code_seq OWNER TO bk_owner;
ALTER SEQUENCE booking.supplier_code_seq OWNER TO bk_owner;
ALTER SEQUENCE booking.trip_case_code_seq OWNER TO bk_owner;

ALTER FUNCTION booking.policy_approval_maker_checker() OWNER TO bk_owner;
ALTER FUNCTION booking.set_updated_at() OWNER TO bk_owner;
ALTER FUNCTION booking.supplier_contract_lock() OWNER TO bk_owner;
ALTER FUNCTION booking.supplier_contract_rates_fit() OWNER TO bk_owner;
ALTER FUNCTION booking.supplier_rate_guard() OWNER TO bk_owner;
ALTER FUNCTION booking.trip_case_check_transition() OWNER TO bk_owner;
ALTER FUNCTION booking.trip_case_record_status() OWNER TO bk_owner;
ALTER FUNCTION booking.trip_case_version_item_lock() OWNER TO bk_owner;
ALTER FUNCTION booking.trip_case_version_item_sent_lock() OWNER TO bk_owner;
ALTER FUNCTION booking.trip_case_version_lock() OWNER TO bk_owner;
ALTER FUNCTION booking.trip_case_version_sent_lock() OWNER TO bk_owner;
ALTER FUNCTION booking.version_item_cost_lock() OWNER TO bk_owner;

-- ── 4. Default privileges: bk-001's rows, restated for the new creator ───────

ALTER DEFAULT PRIVILEGES FOR ROLE bk_owner IN SCHEMA booking
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO booking;
ALTER DEFAULT PRIVILEGES FOR ROLE bk_owner IN SCHEMA booking
    GRANT USAGE, SELECT ON SEQUENCES TO booking;
ALTER DEFAULT PRIVILEGES FOR ROLE bk_owner IN SCHEMA booking
    GRANT EXECUTE ON FUNCTIONS TO booking;

ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA booking
    REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM booking;
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA booking
    REVOKE USAGE, SELECT ON SEQUENCES FROM booking;
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA booking
    REVOKE EXECUTE ON FUNCTIONS FROM booking;

-- ── 5. Guard: everything moved, nothing else changed ─────────────────────────

DO $$
DECLARE
    stray TEXT;
    privileges_after TEXT;
BEGIN
    -- Every object with an owner in schema booking (and the schema itself) belongs to bk_owner.
    SELECT string_agg(o, ', ' ORDER BY o) INTO stray FROM (
        SELECT format('schema booking (%s)', nspowner::regrole) AS o FROM pg_namespace
         WHERE nspname = 'booking' AND nspowner <> 'bk_owner'::regrole
        UNION ALL
        SELECT format('%s %s (%s)', relkind, relname, relowner::regrole) FROM pg_class
         WHERE relnamespace = 'booking'::regnamespace AND relowner <> 'bk_owner'::regrole
        UNION ALL
        SELECT format('function %s (%s)', oid::regprocedure, proowner::regrole) FROM pg_proc
         WHERE pronamespace = 'booking'::regnamespace AND proowner <> 'bk_owner'::regrole
        UNION ALL
        SELECT format('type %s (%s)', typname, typowner::regrole) FROM pg_type
         WHERE typnamespace = 'booking'::regnamespace AND typowner <> 'bk_owner'::regrole
        UNION ALL
        SELECT format('operator %s (%s)', oprname, oprowner::regrole) FROM pg_operator
         WHERE oprnamespace = 'booking'::regnamespace AND oprowner <> 'bk_owner'::regrole
        UNION ALL
        SELECT format('collation %s (%s)', collname, collowner::regrole) FROM pg_collation
         WHERE collnamespace = 'booking'::regnamespace AND collowner <> 'bk_owner'::regrole
        UNION ALL
        SELECT format('statistics %s (%s)', stxname, stxowner::regrole) FROM pg_statistic_ext
         WHERE stxnamespace = 'booking'::regnamespace AND stxowner <> 'bk_owner'::regrole
    ) s;
    IF stray IS NOT NULL THEN
        RAISE EXCEPTION 'bk-014: objects in schema booking not owned by bk_owner (a new object? regenerate the list): %', stray;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'booking'::regnamespace AND prosecdef) THEN
        RAISE EXCEPTION 'bk-014: a SECURITY DEFINER function in schema booking would now run as bk_owner';
    END IF;

    -- Default privileges in schema booking: exactly bk-001's three rows, now FOR ROLE bk_owner.
    IF EXISTS (SELECT 1 FROM pg_default_acl
                WHERE defaclnamespace = 'booking'::regnamespace AND defaclrole <> 'bk_owner'::regrole) THEN
        RAISE EXCEPTION 'bk-014: default privileges FOR ROLE other than bk_owner remain in schema booking';
    END IF;
    IF (SELECT count(*) FROM pg_default_acl d, aclexplode(d.defaclacl) a
         WHERE d.defaclnamespace = 'booking'::regnamespace AND d.defaclrole = 'bk_owner'::regrole
           AND a.grantee = 'booking'::regrole
           AND (d.defaclobjtype, a.privilege_type) IN (
               ('r', 'SELECT'), ('r', 'INSERT'), ('r', 'UPDATE'), ('r', 'DELETE'),
               ('S', 'USAGE'), ('S', 'SELECT'), ('f', 'EXECUTE'))) <> 7 THEN
        RAISE EXCEPTION 'bk-014: default privileges FOR ROLE bk_owner IN SCHEMA booking are not bk-001''s rows';
    END IF;

    -- The privileges of role booking (and of any other non-owner) are exactly what they were in step 1.
    SELECT coalesce(string_agg(p, ',' ORDER BY p), '') INTO privileges_after
    FROM (
        SELECT format('schema:%s:%s:%s', a.grantee::regrole, a.privilege_type, a.is_grantable) AS p
        FROM pg_namespace n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
        WHERE n.nspname = 'booking' AND a.grantee <> n.nspowner
        UNION ALL
        SELECT format('rel:%s:%s:%s:%s', c.relname, a.grantee::regrole, a.privilege_type, a.is_grantable)
        FROM pg_class c,
             aclexplode(coalesce(c.relacl, acldefault(CASE WHEN c.relkind = 'S' THEN 's'::"char" ELSE 'r'::"char" END, c.relowner))) a
        WHERE c.relnamespace = 'booking'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
          AND a.grantee <> c.relowner
        UNION ALL
        SELECT format('col:%s.%s:%s:%s:%s', c.relname, t.attname, a.grantee::regrole, a.privilege_type, a.is_grantable)
        FROM pg_class c JOIN pg_attribute t ON t.attrelid = c.oid, aclexplode(t.attacl) a
        WHERE c.relnamespace = 'booking'::regnamespace AND t.attacl IS NOT NULL AND a.grantee <> c.relowner
        UNION ALL
        SELECT format('fn:%s:%s:%s:%s', f.oid::regprocedure, a.grantee::regrole, a.privilege_type, a.is_grantable)
        FROM pg_proc f, aclexplode(coalesce(f.proacl, acldefault('f', f.proowner))) a
        WHERE f.pronamespace = 'booking'::regnamespace AND a.grantee <> f.proowner
    ) s;
    IF privileges_after IS DISTINCT FROM current_setting('bk014.privileges_before') THEN
        RAISE EXCEPTION 'bk-014: privileges changed by the owner transfer. before: % / after: %',
            current_setting('bk014.privileges_before'), privileges_after;
    END IF;

    -- What bk_owner needs from CIS from bk-015 on and for booking.v_schema_versions (CIS 243). has_table_privilege
    -- alone ignores schema USAGE, hence both. The view read as role booking is checked live (readiness).
    IF NOT (has_schema_privilege('bk_owner', 'shared', 'USAGE')
            AND has_table_privilege('bk_owner', 'shared.schema_versions', 'SELECT')
            AND has_table_privilege('bk_owner', 'shared.schema_versions', 'INSERT')) THEN
        RAISE EXCEPTION 'bk-014: bk_owner lost USAGE on shared or SELECT, INSERT on shared.schema_versions';
    END IF;
END $$;

-- ── 6. Register ──────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-014', now(), 'AA-852 (X1 S6): booking schema, 32 tables, 2 views, 5 sequences, 12 functions owned by bk_owner, default privileges of role booking restated FOR ROLE bk_owner, FOR ROLE aa_cis_admin rows revoked')
ON CONFLICT (version) DO NOTHING;

COMMIT;
