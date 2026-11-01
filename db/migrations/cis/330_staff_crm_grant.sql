-- migrate: expand
-- Migration 330: AA-1031 (S263) — shared.staff_crm_grant: the AA-Partner (CRM) staff roles of a staff account, so the
-- CIS Staff page grants them like the Booking role.
--
-- Why. Root ADR 0006 §3: the staff directory (shared.admin_users + its grant tables) is the source of truth for who is
-- staff and the CIS admin UI is the only writer of WORKFORCE group memberships. Root ADR 0006b decision 6 added three
-- WORKFORCE groups for AA-Partner staff (crm-platform-admin, crm-ops, crm-support), but the directory had no place for
-- them, so they could only be set by hand in the pool (S263: the tech lead could not create an agency until
-- crm-platform-admin was added by command). A person may hold several of them (Operations AND Support), so they do not
-- fit shared.staff_app_grant, which is one role per (person, app).
--
-- What.
--   1. shared.staff_crm_grant (admin_user_id -> shared.admin_users(id) ON DELETE CASCADE, role, created_at;
--      PK (admin_user_id, role)). role in {platform_admin, ops, support} = WORKFORCE groups crm-platform-admin,
--      crm-ops, crm-support (api/services/staff_directory.py CRM_ROLE_GROUPS). One row per granted role; no rows here.
--      No personal data beyond the FK; changes are audited in acp_shared.audit_log (staff.created /
--      staff.roles_changed, details.crm_roles).
--   2. GRANT SELECT, INSERT, DELETE to cis_app (the staff directory writer and the Staff page read; a role change is a
--      delete + insert, never an update).
--   3. Register 330.
--
-- Behaviour. None on apply: no row means no CRM role, and the code reads the table only when to_regclass finds it,
-- so the code PR may deploy before or after this file is applied (lists show no CRM role; a CRM write answers 503
-- until then).
--
-- Class: expand (root ADR 0017 d3): one new table, its constraints, a grant on it and comments; nothing else changes
-- (the FK only adds the internal RI triggers on shared.admin_users), no DO block, no row in an existing table except
-- the schema_versions registration.
--
-- Number. 327 is the highest on main (01/11); 328 / 329 are AA-1026's (embedding registry, S263).
--
-- Rollback (a new forward migration, after the code is reverted): DROP TABLE shared.staff_crm_grant; (destructive file)
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.staff_crm_grant (
    admin_user_id  uuid        NOT NULL,
    role           text        NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT staff_crm_grant_pkey PRIMARY KEY (admin_user_id, role),
    CONSTRAINT staff_crm_grant_admin_user_id_fkey FOREIGN KEY (admin_user_id)
        REFERENCES shared.admin_users (id) ON DELETE CASCADE,
    CONSTRAINT staff_crm_grant_role_chk CHECK (role IN ('platform_admin', 'ops', 'support'))
);

COMMENT ON TABLE shared.staff_crm_grant IS
    'AA-1031 (CIS 330): AA-Partner (CRM) staff roles of a staff directory account, one row per role. Written only by '
    'the CIS staff directory (api/services/staff_directory.py) together with the WORKFORCE groups crm-platform-admin / '
    'crm-ops / crm-support; read by the Staff page and the staff directory reconcile. Audited in acp_shared.audit_log.';
COMMENT ON COLUMN shared.staff_crm_grant.role IS
    'AA-1031 (330): platform_admin = group crm-platform-admin (Agency admin: L1 console writes), ops = crm-ops '
    '(Operations), support = crm-support (Support; also needs an owner grant in the CRM).';

GRANT SELECT, INSERT, DELETE ON shared.staff_crm_grant TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('330', now(), 'AA-1031: shared.staff_crm_grant (CRM staff roles in the staff directory)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
