-- Migration 302: AA-814 — acp_shared.facts gets the fields of the Facts Entry API (kind, valid_until, updated_by)
-- and the tenant pool may delete its own facts.
--
-- Why. acp_shared.facts (CIS 145, AA-529) holds the hand-written, sourced claims the T9 writer cites as [F:<id>]
-- (platform facts for every tenant, tenant facts for their owner only). Rows were only ever written by SQL. AA-814
-- adds the write paths: an admin page for platform facts (/admin/facts, staff pool) and a Content studio page for a
-- tenant's own facts (/v1/facts, the aa_app_user tenant pool under RLS). The writers then pick a tenant fact over a
-- platform fact on the same subject, and drop facts that are out of date. That needs three columns and one grant.
--
-- What.
--   1. kind TEXT NOT NULL DEFAULT 'other', CHECK facts_kind_check: price | season | visa_entry | transfer_time |
--      booking_terms | other. The subject of a fact is (kind, its title, its country): a tenant fact replaces the
--      platform facts with the same subject in the writer seed. Existing rows become 'other' (an admin re-kinds them
--      on the new page; a tenant override copies the kind of the platform fact it replaces, so precedence still
--      works for them).
--   2. valid_until DATE (NULL = no end), CHECK facts_valid_until_ck: not before stated_on when both are set. The
--      writers skip a fact whose valid_until is before today.
--   3. updated_by TEXT: who wrote the row last ('admin:<staff id>' or 'tenant:<tenant id>[:<member>]'); NULL for rows
--      written before this file. Every write also leaves an acp_shared.audit_log row (the API does that).
--   4. GRANT DELETE ON acp_shared.facts TO aa_app_user (it holds SELECT, INSERT, UPDATE since CIS 147). The policies
--      do not change: tenant_isolation (CIS 229, FOR ALL TO aa_app_user, scope = 'tenant' AND own app.tenant_id)
--      is the only aa_app_user policy that admits a DELETE, so a tenant session deletes only its own tenant facts;
--      facts_platform_read is FOR SELECT, so platform facts stay read-only for the tenant pool. Guard 2 checks that
--      before the grant.
--   5. Register 302.
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before: the table exists with RLS on; roles cis_app and aa_app_user exist; aa_app_user is not superuser or
--      BYPASSRLS; a column of this file that exists already has this file's type (re-run).
--   2. before the grant: no policy on the table applies TO PUBLIC; the aa_app_user policies are exactly
--      facts_platform_read (FOR SELECT) and tenant_isolation (FOR ALL) with the CIS 229 expression in USING and
--      WITH CHECK.
--   3. after: the three columns with their types, default and nullability; both CHECKs present and validated; every
--      row has a known kind; aa_app_user holds exactly DELETE, INSERT, SELECT, UPDATE on the table and no column
--      grant; RLS still on.
--   aa_app_user's isolation by behaviour cannot run here (no SET ROLE aa_app_user in a cis/ file): CI proves it in
--   tests/integration/test_aa817_rls_tenant_isolation.py (facts is in DELETE_TABLES from this file) and
--   tests/integration/test_aa814_migration_302.py; on Dev the nightly isolation probe covers every RLS table.
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: kind / valid_until / updated_by
-- absent, aa_app_user_delete false, rows = the current fact count):
--   SELECT (SELECT string_agg(column_name, ',') FROM information_schema.columns
--            WHERE table_schema = 'acp_shared' AND table_name = 'facts'
--              AND column_name IN ('kind', 'valid_until', 'updated_by')) AS present,
--          has_table_privilege('aa_app_user', 'acp_shared.facts', 'DELETE') AS aa_app_user_delete,
--          (SELECT count(*) FROM acp_shared.facts) AS rows;
--
-- Rollback (a NEW forward migration, after the AA-814 code is reverted — the API and the writers read the columns):
--   REVOKE DELETE ON acp_shared.facts FROM aa_app_user;
--   ALTER TABLE acp_shared.facts DROP CONSTRAINT facts_valid_until_ck, DROP CONSTRAINT facts_kind_check,
--     DROP COLUMN updated_by, DROP COLUMN valid_until, DROP COLUMN kind;
--
-- Locks. ALTER TABLE ADD COLUMN with a constant default (no rewrite) and two CHECKs on a table of ~60 rows; one GRANT.
-- lock_timeout 5s. Apply through AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/) with shared.job and
-- booking.job idle (DM-11.4). Re-running is a no-op apart from the guards (IF NOT EXISTS, constraints added only when
-- missing, GRANT is idempotent).
--
-- Order with the code. Additive: today's code (services/acp_content_writing/facts.py) names its columns and keeps
-- working. Apply BEFORE the AA-814 code deploys (the Facts API and the writer read kind / valid_until); that code PR
-- raises readiness.REQUIRED_CIS_SCHEMA to 302.
--
-- Number. 301 is the latest applied CIS migration; 302 is the next free number.
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of the table.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── Guard 1 ──────────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    tbl oid := to_regclass('acp_shared.facts');
    bad text;
BEGIN
    IF tbl IS NULL THEN
        RAISE EXCEPTION 'migration 302: acp_shared.facts is missing (CIS 145)';
    END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = tbl) THEN
        RAISE EXCEPTION 'migration 302: RLS is off on acp_shared.facts (CIS 229)';
    END IF;
    IF to_regrole('cis_app') IS NULL OR to_regrole('aa_app_user') IS NULL THEN
        RAISE EXCEPTION 'migration 302: roles cis_app and aa_app_user must exist';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aa_app_user' AND (rolsuper OR rolbypassrls)) THEN
        RAISE EXCEPTION 'migration 302: aa_app_user is superuser or BYPASSRLS: RLS would not apply to it';
    END IF;
    SELECT string_agg(column_name || ':' || data_type, ',' ORDER BY column_name) INTO bad
      FROM information_schema.columns
     WHERE table_schema = 'acp_shared' AND table_name = 'facts'
       AND ((column_name = 'kind' AND data_type <> 'text')
         OR (column_name = 'valid_until' AND data_type <> 'date')
         OR (column_name = 'updated_by' AND data_type <> 'text'));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 302: acp_shared.facts already has % with another type', bad;
    END IF;
END $$;

-- ── Guard 2: the policies make a DELETE grant safe ───────────────────────────────────────────────────────────────
DO $$
DECLARE
    tbl  oid := 'acp_shared.facts'::regclass;
    expr text := '((scope = ''tenant''::text) AND (tenant_id = (NULLIF(current_setting(''app.tenant_id''::text, '
                 || 'true), ''''::text))::uuid))';
    pols text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = tbl AND 0 = ANY (p.polroles)) THEN
        RAISE EXCEPTION 'migration 302: a policy on acp_shared.facts applies TO PUBLIC';
    END IF;
    SELECT string_agg(p.polname || ':' || CASE WHEN p.polpermissive THEN 'permissive' ELSE 'restrictive' END
                      || ':' || p.polcmd::text, ' | ' ORDER BY p.polname)
      INTO pols
      FROM pg_policy p
     WHERE p.polrelid = tbl AND 'aa_app_user'::regrole = ANY (p.polroles);
    IF pols IS DISTINCT FROM 'facts_platform_read:permissive:r | tenant_isolation:permissive:*' THEN
        RAISE EXCEPTION 'migration 302: unexpected aa_app_user policies on acp_shared.facts: %', pols;
    END IF;
    IF (SELECT pg_get_expr(p.polqual, p.polrelid) IS DISTINCT FROM expr
               OR pg_get_expr(p.polwithcheck, p.polrelid) IS DISTINCT FROM expr
          FROM pg_policy p WHERE p.polrelid = tbl AND p.polname = 'tenant_isolation') THEN
        RAISE EXCEPTION 'migration 302: tenant_isolation on acp_shared.facts is not the CIS 229 expression';
    END IF;
END $$;

-- ── Columns ──────────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE acp_shared.facts
    ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'other',
    ADD COLUMN IF NOT EXISTS valid_until DATE,
    ADD COLUMN IF NOT EXISTS updated_by TEXT;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'acp_shared.facts'::regclass AND conname = 'facts_kind_check') THEN
        ALTER TABLE acp_shared.facts ADD CONSTRAINT facts_kind_check
            CHECK (kind IN ('price', 'season', 'visa_entry', 'transfer_time', 'booking_terms', 'other'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'acp_shared.facts'::regclass AND conname = 'facts_valid_until_ck') THEN
        ALTER TABLE acp_shared.facts ADD CONSTRAINT facts_valid_until_ck
            CHECK (valid_until IS NULL OR stated_on IS NULL OR valid_until >= stated_on);
    END IF;
END $$;

COMMENT ON COLUMN acp_shared.facts.kind IS
    'AA-814 (CIS 302): price | season | visa_entry | transfer_time | booking_terms | other. With the title and the '
    'country it is the subject of the fact: a tenant fact replaces the platform facts on the same subject in the '
    'writer seed.';
COMMENT ON COLUMN acp_shared.facts.valid_until IS
    'AA-814 (CIS 302): last day the fact holds (NULL = no end). The writers skip a fact after this day.';
COMMENT ON COLUMN acp_shared.facts.updated_by IS
    'AA-814 (CIS 302): who wrote the row last (admin:<staff id> or tenant:<tenant id>[:<member>]); NULL before 302. '
    'The full history is in acp_shared.audit_log (fact.*).';

-- ── Grant ────────────────────────────────────────────────────────────────────────────────────────────────────────
GRANT DELETE ON acp_shared.facts TO aa_app_user;

-- ── Guard 3 ──────────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    tbl   oid := 'acp_shared.facts'::regclass;
    cols  text;
    privs text;
BEGIN
    SELECT string_agg(column_name || ':' || data_type || ':' || is_nullable || ':' || COALESCE(column_default, '-'),
                      ',' ORDER BY column_name)
      INTO cols
      FROM information_schema.columns
     WHERE table_schema = 'acp_shared' AND table_name = 'facts'
       AND column_name IN ('kind', 'valid_until', 'updated_by');
    IF cols IS DISTINCT FROM 'kind:text:NO:''other''::text,updated_by:text:YES:-,valid_until:date:YES:-' THEN
        RAISE EXCEPTION 'migration 302: unexpected new columns on acp_shared.facts: %', cols;
    END IF;
    IF (SELECT count(*) FROM pg_constraint
         WHERE conrelid = tbl AND conname IN ('facts_kind_check', 'facts_valid_until_ck') AND contype = 'c'
           AND convalidated) <> 2 THEN
        RAISE EXCEPTION 'migration 302: facts_kind_check / facts_valid_until_ck missing or not validated';
    END IF;
    IF EXISTS (SELECT 1 FROM acp_shared.facts
                WHERE kind NOT IN ('price', 'season', 'visa_entry', 'transfer_time', 'booking_terms', 'other')) THEN
        RAISE EXCEPTION 'migration 302: a fact has an unknown kind';
    END IF;
    SELECT string_agg(a.privilege_type, ',' ORDER BY a.privilege_type) INTO privs
      FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
     WHERE c.oid = tbl AND a.grantee = 'aa_app_user'::regrole;
    IF privs IS DISTINCT FROM 'DELETE,INSERT,SELECT,UPDATE' THEN
        RAISE EXCEPTION 'migration 302: aa_app_user holds % on acp_shared.facts (expected DELETE,INSERT,SELECT,UPDATE)',
            privs;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute att CROSS JOIN LATERAL aclexplode(att.attacl) a
                WHERE att.attrelid = tbl AND att.attacl IS NOT NULL AND a.grantee = 'aa_app_user'::regrole) THEN
        RAISE EXCEPTION 'migration 302: aa_app_user has a column grant on acp_shared.facts';
    END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = tbl) THEN
        RAISE EXCEPTION 'migration 302: RLS is off on acp_shared.facts';
    END IF;
    RAISE NOTICE 'migration 302: acp_shared.facts has kind / valid_until / updated_by, % rows; aa_app_user may delete '
                 'its own tenant facts', (SELECT count(*) FROM acp_shared.facts);
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('302', now(), 'AA-814: acp_shared.facts kind / valid_until / updated_by (Facts Entry API); DELETE to aa_app_user '
                      '(own tenant facts under tenant_isolation)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
