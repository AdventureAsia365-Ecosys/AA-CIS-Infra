-- Migration 362: AA-1035 (R2 slice 1, S267) — shared.admin_role gains the six staff roles of root ADR 0019 d3.
--
-- Why. ADR 0019 (B2B-only model, S265) gives AA staff one CIS role each: admin, content_lead, content, tenant_qa,
-- customer_success, support, finance, ai_ops (and the read-only viewer). Until now shared.admin_role is admin /
-- reviewer / content / viewer, so every tenant, money and AI task needs admin and nothing scopes an account manager to
-- their own tenants. The role table and the permission matrix are root
-- docs/audits/2026-11-03-S265-ecosystem-restructure/clarifications.md section 3; the code half is
-- api/core/staff_authz.py ROLE_PERMS and api/core/tenant_scope.py.
--
-- What.
--   1. ALTER TYPE shared.admin_role ADD VALUE IF NOT EXISTS for content_lead, tenant_qa, customer_success, support,
--      finance and ai_ops. ADD VALUE inside a transaction block is allowed on Postgres 12+ (Dev runs 15), but a new
--      value can not be USED before this transaction commits (55P04 "unsafe use of new value"), so this file only adds
--      them: no cast, no default, no row, no CHECK that names them (ADR 0019 d3: "ALTER TYPE runs in its own
--      migration"). CIS 363 (reviewer merge, CHECK fixes) and 364 (the tenant assignment tables) follow.
--   2. Register 362.
--
-- Guard 0 (RAISE, nothing changes): shared.admin_role exists (migration 074) and the runner owns it or is a member of
-- its owner (ALTER TYPE needs the type owner; DB Migrate runs cis/ files as cis_owner since X1 245).
-- Guard 1 (RAISE): after the ADD VALUEs every expected label is in pg_enum (a typo can not pass silently).
--
-- Class: contract (root ADR 0017 d3: a change to an existing type). No `migrate:` directive: not expand, not
-- destructive. On Dev it is applied by Infra Migration Apply when every job table is idle (root ADR 0017a).
--
-- Behaviour on apply: none. No row uses a new value until the staff directory assigns one, which the code PR
-- (readiness raised to 364) allows only after this batch is applied; the code before it does not know these roles
-- (a cis-* group it does not map gives no role, so the token is refused as before).
--
-- Locks. ALTER TYPE … ADD VALUE takes a lock on the type only; readers of shared.admin_users are not blocked.
-- lock_timeout 5s. Re-running is a no-op (IF NOT EXISTS, ON CONFLICT DO NOTHING).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243, AA-CIS-Infra db/owners.yaml). No catalog.* view
-- is touched.
--
-- The SQL applied to Dev is the byte copy in AA-CIS-Infra db/migrations/cis/ (migration sync); keep the two identical.
-- After apply the schema reference lists `shared.admin_role`: 'admin', 'reviewer', 'content', 'viewer',
-- 'content_lead', 'tenant_qa', 'customer_success', 'support', 'finance', 'ai_ops'.
--
-- Rollback. Postgres can not drop an enum value. While no row uses them the values are harmless (the code before the
-- R2 code PR maps none of them). To remove them for real: move every row off them, then recreate the type in a new,
-- reviewed migration (the recipe is in 249's header).
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: the type exists and the runner may alter it ─────────────────────────────────────────
DO $$
DECLARE
    owner_name text;
BEGIN
    IF to_regtype('shared.admin_role') IS NULL THEN
        RAISE EXCEPTION 'migration 362: type shared.admin_role does not exist (migration 074)';
    END IF;
    SELECT pg_catalog.pg_get_userbyid(t.typowner) INTO owner_name
      FROM pg_catalog.pg_type t WHERE t.oid = 'shared.admin_role'::regtype;
    IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
        RAISE EXCEPTION 'migration 362: shared.admin_role is owned by %, not by the runner % (ALTER TYPE needs the owner)',
            owner_name, current_user;
    END IF;
END $$;

-- ── 1. The six roles of root ADR 0019 d3 ─────────────────────────────────────────────────────────
ALTER TYPE shared.admin_role ADD VALUE IF NOT EXISTS 'content_lead';
ALTER TYPE shared.admin_role ADD VALUE IF NOT EXISTS 'tenant_qa';
ALTER TYPE shared.admin_role ADD VALUE IF NOT EXISTS 'customer_success';
ALTER TYPE shared.admin_role ADD VALUE IF NOT EXISTS 'support';
ALTER TYPE shared.admin_role ADD VALUE IF NOT EXISTS 'finance';
ALTER TYPE shared.admin_role ADD VALUE IF NOT EXISTS 'ai_ops';

-- ── Guard 1: every label is there (reads pg_enum as text, never casts a new value) ────────────────
DO $$
DECLARE
    missing text;
BEGIN
    SELECT string_agg(want, ', ') INTO missing
      FROM unnest(ARRAY['admin', 'reviewer', 'content', 'viewer', 'content_lead', 'tenant_qa', 'customer_success',
                        'support', 'finance', 'ai_ops']) AS want
     WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_enum e
                        WHERE e.enumtypid = 'shared.admin_role'::regtype AND e.enumlabel = want);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 362: shared.admin_role lacks %', missing;
    END IF;
END $$;

-- ── 2. Register ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('362', now(), 'AA-1035: shared.admin_role gains content_lead, tenant_qa, customer_success, support, finance, ai_ops (root ADR 0019 d3)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
