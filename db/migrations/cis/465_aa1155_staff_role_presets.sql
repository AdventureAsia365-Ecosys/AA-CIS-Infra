-- Migration 465: AA-1155 (S287, custom staff roles, spec tasks T13 / T14) — the Staff page's people-role presets as
-- data, and the runtime grants of the CIS custom role editor.
--
-- Why. The Staff page offers four presets (Administrator, Business owner, Content + Product & operations, Pricing
-- team: AA-1031, AA-1091, AA-1150). What each one grants was a code literal in two places (api/services/
-- staff_presets.py and frontend/lib/staffPresets.ts + StaffManage.tsx), so a new combined role for a person needed a
-- code change. Root spec R5.7: the presets are data an is_owner user edits on the Staff page, audited; the code keeps
-- only the guards (a preset never sets is_owner, the self-demote and last-owner checks, an additive-only preset never
-- replaces a held role). R5.6: the CIS role editor writes shared.staff_role / staff_role_capability (CIS 462 granted
-- cis_app SELECT only).
--
-- What.
--   1. shared.staff_role_preset: one row per preset.
--        code ^[a-z][a-z0-9_]{1,47}$ (what PATCH …/staff/{id}/roles {"preset": code} names, kept in the audit row);
--        label (1-80, no control characters) and description (0-300) as the Staff page shows them;
--        cis_role: the CIS role it grants (a built-in assignable role or a CIS custom role code), NULL = kept;
--        booking_mode keep / set / clear + booking_role (set: a built-in Booking role or a Booking custom role code);
--        crm_mode keep / replace / add + crm_roles (the CRM staff roles of shared.staff_crm_grant);
--        additive_only: the preset only fills an empty slot (CIS viewer; no Booking grant or a retired one) and keeps a
--          role listed in cis_keep_roles / booking_keep_roles (a role that already gives what the preset gives); any
--          other held role is never replaced (the code answers 409 preset_would_replace). An additive preset never
--          clears the Booking grant and never replaces the CRM roles (CHECK);
--        sort_order, archived (an archived preset is not offered and not applied; rows are never deleted), created /
--        updated stamps and actors.
--      There is no owner column: a preset never sets is_owner (the code guard, and nothing here could hold it).
--      The code also checks every role code on save (an active custom role, an assignable built-in one) and again on
--      apply (the directory's own checks).
--   2. Seed: today's four presets, exactly what api/services/staff_presets.py applied on main (20/11/2026):
--        platform_owner "Administrator": CIS admin, Booking admin, CRM platform_admin added;
--        business_owner "Business owner": CIS admin, Booking admin, CRM kept;
--        content_ops "Content + Product & operations": CIS content_lead, Booking grant cleared, CRM roles cleared;
--        pricing_team "Pricing team": CIS customer_success, Booking contracting, CRM kept, additive only, keeping
--          CIS admin / content_lead / customer_success and Booking admin / contracting.
--   3. Grants to cis_app: SELECT, INSERT, UPDATE on the preset table (the Staff page editor; no DELETE: archive only);
--      INSERT, UPDATE on shared.staff_role and INSERT, DELETE on shared.staff_role_capability (the CIS role editor,
--      task T13; roles are archived, never deleted).
--   4. Register 465.
--
-- Guards (RAISE, nothing changes): 0. before: CIS 462 is applied (shared.staff_role exists), role cis_app exists.
-- 1. after: the four seeded presets hold exactly their rules; no column of the table names an owner flag; cis_app
-- may write the editor tables.
--
-- Class: CONTRACT (root ADR 0017 d3: a new table with a seed and grants on existing tables). No migrate directive
-- line. MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply once every job table is idle (ADR 0017a),
-- then the code PR (readiness raises to 465; the Staff page reads presets from the table). DM-6.1: no personal column
-- (created_by / updated_by hold an actor tag "admin:<uuid>", as shared.staff_role does). DM-7.1: one new table, its
-- row in root data standards Part B section 7 (root PR of this change, merged before the Infra copy).
--
-- Number. 464 is the newest CIS migration on main (21/11/2026); 466 is reserved for another lane of S287. If the
-- owner main max + 1 differs at merge, renumber (git grep '465_' and "'465'": this file,
-- tests/integration/test_aa1155_migration_465.py, api/core/readiness.py, the code PR's tests and notes).
--
-- Behaviour on apply: none for running code. Code on main applies the presets from its own constants and never
-- reads this table; the new grants only widen what cis_app may write on two tables no running code writes.
--
-- Locks. A new table; GRANT takes a brief lock on shared.staff_role / staff_role_capability (a handful of rows,
-- read on a custom holder's sign-in with a 60 s cache). lock_timeout 5s. Re-runnable (IF NOT EXISTS, ON CONFLICT DO
-- NOTHING, GRANT is idempotent).
--
-- X1. One BEGIN … COMMIT block, no role switch (the runner is cis_owner, the owner of schema shared).
--
-- Rollback (a new forward migration, after the code PR is reverted): REVOKE the editor grants and DROP TABLE
-- shared.staff_role_preset (a destructive file, DRY RUN: the presets edited on the Staff page are lost).
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: CIS 462 applied, the runtime role exists ────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('shared.staff_role') IS NULL OR to_regclass('shared.staff_role_capability') IS NULL THEN
        RAISE EXCEPTION 'migration 465: shared.staff_role / staff_role_capability do not exist (migration 462)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'cis_app') THEN
        RAISE EXCEPTION 'migration 465: role cis_app does not exist';
    END IF;
END $$;

-- ── 1. The people-role presets ───────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.staff_role_preset (
    code                text         NOT NULL,
    label               text         NOT NULL,
    description         text         NOT NULL DEFAULT '',
    cis_role            text,
    booking_mode        text         NOT NULL DEFAULT 'keep',
    booking_role        text,
    crm_mode            text         NOT NULL DEFAULT 'keep',
    crm_roles           text[]       NOT NULL DEFAULT '{}',
    additive_only       boolean      NOT NULL DEFAULT false,
    cis_keep_roles      text[]       NOT NULL DEFAULT '{}',
    booking_keep_roles  text[]       NOT NULL DEFAULT '{}',
    sort_order          smallint     NOT NULL DEFAULT 100,
    archived            boolean      NOT NULL DEFAULT false,
    created_at          timestamptz  NOT NULL DEFAULT now(),
    created_by          text         NOT NULL,
    updated_at          timestamptz  NOT NULL DEFAULT now(),
    updated_by          text         NOT NULL,
    CONSTRAINT staff_role_preset_pkey PRIMARY KEY (code),
    CONSTRAINT staff_role_preset_code_chk CHECK (code ~ '^[a-z][a-z0-9_]{1,47}$'),
    CONSTRAINT staff_role_preset_label_chk CHECK (char_length(btrim(label)) BETWEEN 1 AND 80
                                                  AND label !~ '[[:cntrl:]]'),
    CONSTRAINT staff_role_preset_description_chk CHECK (char_length(description) <= 300
                                                        AND description !~ '[[:cntrl:]]'),
    CONSTRAINT staff_role_preset_cis_role_chk CHECK (
        cis_role IS NULL
        OR cis_role IN ('admin', 'content_lead', 'content', 'tenant_qa', 'customer_success', 'support', 'finance',
                        'ai_ops')
        OR cis_role ~ '^custom_[a-z][a-z0-9_]{1,46}$'),
    CONSTRAINT staff_role_preset_booking_chk CHECK (
        booking_mode IN ('keep', 'set', 'clear')
        AND (booking_mode = 'set') = (booking_role IS NOT NULL)
        AND (booking_role IS NULL
             OR booking_role IN ('admin', 'sales', 'contracting', 'finance')
             OR booking_role ~ '^custom_[a-z][a-z0-9_]{1,46}$')),
    CONSTRAINT staff_role_preset_crm_chk CHECK (
        crm_mode IN ('keep', 'replace', 'add')
        AND crm_roles <@ ARRAY['platform_admin', 'ops', 'support']::text[]
        AND (crm_mode <> 'keep' OR cardinality(crm_roles) = 0)
        AND (crm_mode <> 'add' OR cardinality(crm_roles) > 0)),
    CONSTRAINT staff_role_preset_additive_chk CHECK (
        (additive_only AND booking_mode <> 'clear' AND crm_mode <> 'replace')
        OR (NOT additive_only AND cardinality(cis_keep_roles) = 0 AND cardinality(booking_keep_roles) = 0)),
    CONSTRAINT staff_role_preset_keep_chk CHECK (cardinality(cis_keep_roles) <= 16
                                                 AND cardinality(booking_keep_roles) <= 16),
    CONSTRAINT staff_role_preset_sets_something_chk CHECK (
        cis_role IS NOT NULL OR booking_mode <> 'keep' OR crm_mode <> 'keep'),
    CONSTRAINT staff_role_preset_sort_chk CHECK (sort_order BETWEEN 0 AND 999),
    CONSTRAINT staff_role_preset_actor_chk CHECK (char_length(created_by) BETWEEN 1 AND 128
                                                  AND char_length(updated_by) BETWEEN 1 AND 128),
    CONSTRAINT staff_role_preset_time_chk CHECK (updated_at >= created_at)
);

COMMENT ON TABLE shared.staff_role_preset IS
    'AA-1155 (CIS 465, root spec R5.7): the Staff page''s people-role presets as data, edited by an is_owner user and '
    'audited (acp_shared.audit_log staff.preset_created / staff.preset_updated). Applied by PATCH '
    '/admin/platform/staff/{id}/roles {"preset": code}; the code keeps the guards (never is_owner, self-demote, last '
    'owner, an additive preset never replaces a held role). Archived rows are kept for history.';
COMMENT ON COLUMN shared.staff_role_preset.cis_role IS
    'AA-1155 (465): the CIS role the preset grants (built-in assignable role or a CIS custom role code); NULL = kept.';
COMMENT ON COLUMN shared.staff_role_preset.booking_mode IS
    'AA-1155 (465): keep = the Booking grant is not changed; set = booking_role is granted; clear = the grant is removed.';
COMMENT ON COLUMN shared.staff_role_preset.crm_mode IS
    'AA-1155 (465): keep = the CRM roles are not changed; replace = the CRM roles become crm_roles; add = crm_roles are '
    'added to those held.';
COMMENT ON COLUMN shared.staff_role_preset.additive_only IS
    'AA-1155 (465, was the AA-1091 Pricing team rule): fill an empty slot (CIS viewer; no or a retired Booking grant), '
    'keep a role in cis_keep_roles / booking_keep_roles, refuse (409 preset_would_replace) any other held role.';

-- ── 2. Seed: today's four presets ────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.staff_role_preset (code, label, description, cis_role, booking_mode, booking_role, crm_mode,
                                      crm_roles, additive_only, cis_keep_roles, booking_keep_roles, sort_order,
                                      created_by, updated_by)
VALUES
    ('platform_owner', 'Administrator',
     'CIS Administrator, Booking admin and CRM Agency admin. Other CRM roles are kept.',
     'admin', 'set', 'admin', 'add', ARRAY['platform_admin'], false, '{}', '{}', 10, 'migration:465', 'migration:465'),
    ('business_owner', 'Business owner',
     'CIS Administrator and Booking admin. CRM roles are not changed.',
     'admin', 'set', 'admin', 'keep', '{}', false, '{}', '{}', 20, 'migration:465', 'migration:465'),
    ('content_ops', 'Content + Product & operations',
     'CIS Content Lead. No Booking role and no CRM role.',
     'content_lead', 'clear', NULL, 'replace', '{}', false, '{}', '{}', 30, 'migration:465', 'migration:465'),
    ('pricing_team', 'Pricing team',
     'What the customer-service team needs to enter prices: CIS Customer Success and Booking Product & operations. '
     'It only adds: a role that already has these rights is kept, another role is never replaced. CRM roles are not '
     'changed.',
     'customer_success', 'set', 'contracting', 'keep', '{}', true,
     ARRAY['admin', 'content_lead', 'customer_success'], ARRAY['admin', 'contracting'], 40,
     'migration:465', 'migration:465')
ON CONFLICT (code) DO NOTHING;

-- ── 3. Runtime grants: the preset editor and the CIS role editor ─────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE ON shared.staff_role_preset TO cis_app;
GRANT SELECT, INSERT, UPDATE ON shared.staff_role TO cis_app;
GRANT SELECT, INSERT, DELETE ON shared.staff_role_capability TO cis_app;

-- ── Guard 1: what this file promises ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    got text;
BEGIN
    SELECT string_agg(concat_ws('|', code, coalesce(cis_role, '-'), booking_mode, coalesce(booking_role, '-'),
                                crm_mode, array_to_string(crm_roles, ','), additive_only::text,
                                array_to_string(cis_keep_roles, ','), array_to_string(booking_keep_roles, ',')),
                      ';' ORDER BY code)
      INTO got
      FROM shared.staff_role_preset
     WHERE code IN ('platform_owner', 'business_owner', 'content_ops', 'pricing_team')
       AND updated_by = 'migration:465';
    -- Checked while the four seeded rows are unedited (on a re-run an owner may have edited one since; ON CONFLICT
    -- kept the edit, and an edited row no longer carries updated_by migration:465).
    IF (SELECT count(*) FROM shared.staff_role_preset WHERE updated_by = 'migration:465') = 4
       AND got IS DISTINCT FROM
        'business_owner|admin|set|admin|keep||false||;content_ops|content_lead|clear|-|replace||false||;'
        || 'platform_owner|admin|set|admin|add|platform_admin|false||;'
        || 'pricing_team|customer_success|set|contracting|keep||true|admin,content_lead,customer_success|admin,contracting'
    THEN
        RAISE EXCEPTION 'migration 465: the seeded presets are not the expected rules: %', got;
    END IF;
    IF (SELECT count(*) FROM shared.staff_role_preset
         WHERE code IN ('platform_owner', 'business_owner', 'content_ops', 'pricing_team')) <> 4 THEN
        RAISE EXCEPTION 'migration 465: the four seeded presets are missing';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
                WHERE attrelid = 'shared.staff_role_preset'::regclass AND attnum > 0 AND NOT attisdropped
                  AND attname LIKE '%owner%') THEN
        RAISE EXCEPTION 'migration 465: shared.staff_role_preset has an owner column (a preset never sets is_owner)';
    END IF;

    IF NOT has_table_privilege('cis_app', 'shared.staff_role_preset', 'INSERT')
       OR NOT has_table_privilege('cis_app', 'shared.staff_role_preset', 'UPDATE')
       OR NOT has_table_privilege('cis_app', 'shared.staff_role', 'INSERT')
       OR NOT has_table_privilege('cis_app', 'shared.staff_role', 'UPDATE')
       OR NOT has_table_privilege('cis_app', 'shared.staff_role_capability', 'INSERT')
       OR NOT has_table_privilege('cis_app', 'shared.staff_role_capability', 'DELETE') THEN
        RAISE EXCEPTION 'migration 465: cis_app cannot write the preset or role editor tables';
    END IF;
END $$;

-- ── 4. Register ──────────────────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('465', now(), 'AA-1155: Staff page people-role presets as data (shared.staff_role_preset, four seeded presets) and the CIS role editor grants to cis_app')
ON CONFLICT (version) DO NOTHING;

COMMIT;
