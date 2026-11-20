-- Migration bk-062: AA-1155 (S286, custom staff roles, foundation) — Booking custom roles as data, their
-- capabilities, the key-only role -> capability view for the CIS matrix page, and custom codes on staff_users.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/062_custom_staff_roles.sql and Migration Apply applies it on Dev as bk_owner once every job
-- table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Why: Booking resolves one built-in role per person from the first booking-* group, with a hard-coded capability
-- dict (backend/app/auth/staff.py PERMISSIONS). The content + operations staff member needs "Product, ops &
-- accounting": make and read rights across supply, pricing, operations, supplier bills and agency billing, the agency
-- quote and booking rights (tech lead S285 Q3), and no approve right. Built-in roles STAY in code; these tables hold
-- custom roles only. A holder has WORKFORCE group booking-custom; WHICH role is the CIS Staff page grant
-- (shared.staff_app_grant.role = a code below), read through the CIS contract view shared.v_staff_booking_grant (CIS
-- 462, root ADR 0006a A14, Q2 option A). Spec: root .kiro/specs/AA-1155-custom-staff-roles/ (task T4).
--
-- What:
--   1. booking.staff_role: code ^custom_[a-z][a-z0-9_]{1,46}$ (the CIS 462 pattern: never a built-in role name),
--      label, based_on (the built-in role the editor cloned it from: admin, sales, contracting, content_creator,
--      finance), archived, created / updated stamps and actors (staff keys).
--   2. booking.staff_role_capability: (role_code, capability). A CHECK refuses the approve class reserved for
--      built-in roles: any *.approve or *.approve_<x>, supplier.activate, contract.publish, stop_sale.approve,
--      payout.write, payment.verify, billing_config.write, staff.admin. The code also refuses a capability its
--      PERMISSIONS set does not know (400 on the role editor).
--      Reserved ahead of use: pricing.approve, supplier.activate, contract.publish and stop_sale.approve are not in
--      PERMISSIONS yet. Until the Booking approve split (root spec task T4.1 and the lean-roles step-1 split) re-gates
--      the routes, supply.write still carries supplier / hotel / service activate and contract publish,
--      stop_sale.write the stop-sale review and end, pricing.write the approve of pricing rules, FX rates,
--      cancellation policies, agency pricing and price adjustments, and b2b_desk.write the allotment approve. The
--      resolver of booking-custom (task T5) ships only after that split; until then the group resolves to no role.
--   3. booking.v_staff_role_capability (security_barrier): (role_code, label, based_on, archived, capability), one row
--      per capability (a role without one: one row, capability NULL). Key-only: no person. SELECT to cis_app (the CIS
--      "Roles & permissions" page and the Staff page pickers) and booking.
--   4. staff_users_role_chk widened: a built-in role OR a custom code (the resolved role of a booking-custom holder;
--      Booking writes it only after reading the code from the CIS view and this table).
--   5. Seed (exact allow-list, unit-tested in the code PR): custom_product_ops_accounting "Product, ops &
--      accounting", based_on contracting, 24 capabilities: supply.read/write, pricing.read/write, trip_plan.write,
--      stop_sale.write, catalog.read, ops.read/write, b2b_desk.read/write, staff.directory, bill.read/write,
--      billing.read/write, agency_billing.read/write, profit.read (S285 audit section 3.3) and, Q3, b2b_desk.book,
--      trip_case.read/write, customer.read/write. Never customer.admin, trip_case.assign, version.write, supplier_bank.*.
--
-- Class: contract (root ADR 0017 d3: a replaced CHECK on an existing table, a seed, a cross-app grant). No migrate
-- directive. Migration-only PR first (MIG-4); the code PR raises readiness to bk-062. The running code never reads
-- the new objects and writes only built-in roles to staff_users, so nothing it does changes here.
-- DM-6.1: no personal data (codes, labels, capability names; created_by / updated_by are staff keys, never e-mails).
-- DM-7.1: both new tables have their row in the root data standards (root PR merged before the Infra copy).
-- Locks: staff_users takes a short ACCESS EXCLUSIVE for the CHECK (about 13 rows); lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS, DROP CONSTRAINT IF EXISTS, CREATE OR REPLACE,
-- ON CONFLICT DO NOTHING.
-- Undo (a later bk- file, after the code is reverted and no staff_users row holds a custom code): DROP the view and
-- the two tables, put back the bk-038 staff_users_role_chk.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. Booking custom roles ──────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.staff_role (
    code        text         NOT NULL,
    label       text         NOT NULL,
    based_on    text         NOT NULL,
    archived    boolean      NOT NULL DEFAULT false,
    created_at  timestamptz  NOT NULL DEFAULT now(),
    created_by  text         NOT NULL,
    updated_at  timestamptz  NOT NULL DEFAULT now(),
    updated_by  text         NOT NULL,
    CONSTRAINT staff_role_pkey PRIMARY KEY (code),
    CONSTRAINT staff_role_code_chk CHECK (code ~ '^custom_[a-z][a-z0-9_]{1,46}$'),
    CONSTRAINT staff_role_label_chk CHECK (char_length(btrim(label)) BETWEEN 1 AND 80 AND label !~ '[[:cntrl:]]'),
    CONSTRAINT staff_role_based_on_chk CHECK (
        based_on IN ('admin', 'sales', 'contracting', 'content_creator', 'finance')),
    CONSTRAINT staff_role_actor_chk CHECK (char_length(created_by) BETWEEN 1 AND 128
                                           AND char_length(updated_by) BETWEEN 1 AND 128),
    CONSTRAINT staff_role_time_chk CHECK (updated_at >= created_at)
);

-- ── 2. Their capabilities (never the approve class) ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.staff_role_capability (
    role_code   text         NOT NULL,
    capability  text         NOT NULL,
    created_at  timestamptz  NOT NULL DEFAULT now(),
    created_by  text         NOT NULL,
    CONSTRAINT staff_role_capability_pkey PRIMARY KEY (role_code, capability),
    CONSTRAINT staff_role_capability_role_fkey FOREIGN KEY (role_code)
        REFERENCES booking.staff_role (code) ON DELETE CASCADE,
    CONSTRAINT staff_role_capability_name_chk CHECK (capability ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,3}$'),
    CONSTRAINT staff_role_capability_not_approve_chk CHECK (
        capability !~ '\.approve(_[a-z0-9_]+)?$'
        AND capability NOT IN ('supplier.activate', 'contract.publish', 'stop_sale.approve', 'payout.write',
                               'payment.verify', 'billing_config.write', 'staff.admin')),
    CONSTRAINT staff_role_capability_actor_chk CHECK (char_length(created_by) BETWEEN 1 AND 128)
);

COMMENT ON TABLE booking.staff_role IS
    'AA-1155 (bk-062): Booking custom staff roles only (built-in roles stay in backend/app/auth/staff.py PERMISSIONS). '
    'A holder has WORKFORCE group booking-custom; the CIS Staff page grant (shared.staff_app_grant.role) names the '
    'code, read through shared.v_staff_booking_grant. Archived roles stay for history.';
COMMENT ON TABLE booking.staff_role_capability IS
    'AA-1155 (bk-062): the capabilities of a Booking custom role. Never an approve-class capability (CHECK); the code '
    'also refuses a capability PERMISSIONS does not know. Changed only on the role editor by is_owner staff, audited.';

GRANT SELECT, INSERT, UPDATE, DELETE ON booking.staff_role, booking.staff_role_capability TO booking;

-- ── 3. The key-only view for CIS (matrix page, Staff pickers) ────────────────────────────────────────────────────

CREATE OR REPLACE VIEW booking.v_staff_role_capability WITH (security_barrier = true) AS
SELECT r.code AS role_code,
       r.label,
       r.based_on,
       r.archived,
       c.capability
  FROM booking.staff_role r
  LEFT JOIN booking.staff_role_capability c ON c.role_code = r.code;

COMMENT ON VIEW booking.v_staff_role_capability IS
    'AA-1155 (bk-062): the Booking custom roles and their capabilities, one row per capability (NULL for a role with '
    'none). Key-only: codes, labels and capability names, no person. Readers: cis_app (CIS "Roles & permissions" page '
    'and Staff page pickers), booking.';

GRANT SELECT ON booking.v_staff_role_capability TO booking;
REVOKE INSERT, UPDATE, DELETE ON booking.v_staff_role_capability FROM booking;
GRANT USAGE ON SCHEMA booking TO cis_app;
GRANT SELECT ON booking.v_staff_role_capability TO cis_app;

-- ── 4. staff_users may hold a resolved custom code ───────────────────────────────────────────────────────────────

ALTER TABLE booking.staff_users DROP CONSTRAINT IF EXISTS staff_users_role_chk;
ALTER TABLE booking.staff_users ADD CONSTRAINT staff_users_role_chk CHECK (
    role IN ('admin', 'sales', 'contracting', 'content_creator', 'finance')
    OR role ~ '^custom_[a-z][a-z0-9_]{1,46}$');

-- ── 5. Seed: "Product, ops & accounting" ─────────────────────────────────────────────────────────────────────────

INSERT INTO booking.staff_role (code, label, based_on, created_by, updated_by)
VALUES ('custom_product_ops_accounting', 'Product, ops & accounting', 'contracting', 'migration:bk-062',
        'migration:bk-062')
ON CONFLICT (code) DO NOTHING;

INSERT INTO booking.staff_role_capability (role_code, capability, created_by)
SELECT 'custom_product_ops_accounting', c, 'migration:bk-062'
  FROM unnest(ARRAY[
      'supply.read', 'supply.write', 'pricing.read', 'pricing.write', 'trip_plan.write', 'stop_sale.write',
      'catalog.read', 'ops.read', 'ops.write', 'b2b_desk.read', 'b2b_desk.write', 'staff.directory',
      'bill.read', 'bill.write', 'billing.read', 'billing.write', 'agency_billing.read', 'agency_billing.write',
      'profit.read', 'b2b_desk.book', 'trip_case.read', 'trip_case.write', 'customer.read', 'customer.write'
  ]) AS c
ON CONFLICT (role_code, capability) DO NOTHING;

-- ── Guards: what this file promises ──────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    cols text;
    n integer;
BEGIN
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a
     WHERE a.attrelid = 'booking.v_staff_role_capability'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'role_code,label,based_on,archived,capability' THEN
        RAISE EXCEPTION 'bk-062: booking.v_staff_role_capability columns are %', cols;
    END IF;
    IF NOT has_table_privilege('cis_app', 'booking.v_staff_role_capability', 'SELECT') THEN
        RAISE EXCEPTION 'bk-062: cis_app cannot read booking.v_staff_role_capability';
    END IF;
    IF has_table_privilege('cis_app', 'booking.staff_role', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.staff_role_capability', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.v_staff_role_capability', 'INSERT') THEN
        RAISE EXCEPTION 'bk-062: cis_app reaches more than the read of booking.v_staff_role_capability';
    END IF;
    SELECT count(*) INTO n FROM booking.staff_role_capability WHERE role_code = 'custom_product_ops_accounting';
    IF n <> 24 THEN
        RAISE EXCEPTION 'bk-062: the Product, ops & accounting role holds % capabilities, expected 24', n;
    END IF;
    SELECT count(*) INTO n FROM booking.staff_role_capability
     WHERE role_code = 'custom_product_ops_accounting'
       AND (capability IN ('customer.admin', 'trip_case.assign', 'version.write') OR capability LIKE 'supplier_bank.%');
    IF n > 0 THEN
        RAISE EXCEPTION 'bk-062: the Product, ops & accounting role holds % capability(ies) outside its allow-list', n;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-062', now(), 'AA-1155 custom staff roles: booking.staff_role, booking.staff_role_capability (no approve class), booking.v_staff_role_capability (reader cis_app), staff_users_role_chk accepts custom codes, seed Product, ops & accounting')
ON CONFLICT (version) DO NOTHING;

COMMIT;
