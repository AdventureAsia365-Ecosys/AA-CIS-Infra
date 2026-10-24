-- Migration 277: AA-916 (WM-03) — shared.writing_signal, the deletable store of writing-memory signals (the
-- before / after text of an edit, the reason code of an admin action, the fact status) of the A1, T2 and T9 writers.
--
-- Why. App ADR 0010 (governed writing memory, AA-915) decisions 10 and 11: tenant text lives only in deletable,
-- tenant-scoped tables, and acp_shared.audit_log (append-only, hash-chained) keeps only ids, hashes and reason chips.
-- Today the before / after text of an edit is either lost (tenant T9 edits, admin A1 field edits keep no "before") or
-- sits in audit_log details (admin sentence edits), where it can never be deleted. The capture code (AA-916 S2 / S3:
-- record_writer_feedback in services/writing_memory/) writes here; nothing reads it yet apart from the admin
-- drawer history and the AA-839 tenant erasure. This file is storage only.
--
-- What.
--   1. shared.writing_signal: signal_id uuid PK; writer a1 | t2 | t9_blog | t9_social; channel; scope platform |
--      tenant with tenant_id NULL exactly for platform (the acp_shared.facts facts_scope_tenant_ck pattern, ADR 0010
--      decision 10); field; locator jsonb (an object: start / end / index / paragraph); before_text / after_text
--      (pii:free_text, DM-6.1) with their sha256 (lower-case hex; required whenever the text is there); gate; problem
--      (pii:free_text: the gate's diagnostic, which quotes the flagged text, so it lives here and audit_log keeps only
--      its sha256; at most 2000 characters); reason_code (the 8 codes of ADR 0010 / WM-06); action (field_edit,
--      sentence_cut, sentence_rewrite, sentence_manual, tenant_edit, reject, dismiss, regenerate); actor_type admin |
--      tenant | system and actor_id; fact_status pending | grey | pass | fail (default pending); exemplar_pref use |
--      never (WM-07, added now so the toggles need no second migration); audit_log_id (a one-way link; the audit row
--      names the signal in details.signal_id); source_table / source_id (polymorphic, so no FK: the AA-839 erasure
--      order stays free); created_at.
--      Indexes: (tenant_id, created_at DESC) WHERE scope = 'tenant' (erasure, per-tenant reads); (writer, created_at
--      DESC); (source_table, source_id) (the drawer history of one piece / version).
--   2. RLS ENABLE + FORCE (ADR 0010 decision 10; unlike the 229 template, which keeps the owner exempt):
--        writing_signal_cis_app_all   TO cis_app   USING (true) WITH CHECK (true)  X1 parity (CIS 244): the runtime
--                                     sees every row and filters tenant_id explicitly in code (ADR 0010 decision 10);
--        writing_signal_cis_owner_all TO cis_owner USING (true) WITH CHECK (true)  X1 S21 (CIS 245): a FORCE table
--                                     filters its owner too; every later cis/ file runs as cis_owner (standing check
--                                     test_x1_cis_app_privileges::test_standing_a_new_force_table_has_a_cis_owner_policy);
--        tenant_isolation             TO aa_app_user, USING and WITH CHECK scope = 'tenant' AND tenant_id =
--                                     NULLIF(current_setting('app.tenant_id', true), '')::uuid: the tenant pool reads
--                                     and inserts its own tenant rows only, never a platform row.
--      Both parity names are exempt from rls_catalogue_rules rule t (CIS_PARITY_ROLES).
--   3. Grants. REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner first (it also takes away the DML that
--      the Dev default ACL of cis_owner gives cis_app on every new table in shared, CIS 245; SCHEDULE S250 §5 point 3),
--      then explicitly: cis_app SELECT, INSERT, UPDATE (exemplar_pref, fact_status), DELETE (the AA-839 erasure);
--      aa_app_user SELECT, INSERT (the tenant T9 edit path on the tenant pool, AA-859); nothing for catalog_owner.
--      No column-level grant.
--   4. Register 277.
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before: roles cis_app, aa_app_user, cis_owner, catalog_owner exist; aa_app_user is not superuser / BYPASSRLS;
--      the runner may create in shared; the table, if present, has exactly this file's columns (re-run);
--   2. after: every named constraint validated; the three indexes; RLS on AND forced; exactly the three policies with
--      this file's commands, roles and expressions; privileges exactly as in point 3 for PUBLIC, cis_app, aa_app_user
--      and catalog_owner, no column grants; the AA-859 invariant v3 (no aa_app_user privilege on a relation without
--      RLS outside the allowlists, NO_PRIVILEGE_WITHOUT_RLS_SQL_V3);
--   3. behaviour (a sub-block that always rolls back): a tenant row and a platform row insert and read back as the
--      runner; a platform row with a tenant_id, a tenant row without one, an unknown reason code, a text without its
--      hash and a malformed hash are refused (check_violation).
--   aa_app_user's isolation by behaviour cannot run here (the role lint allows no SET ROLE aa_app_user in a cis/ file):
--   tests/integration/test_aa817_rls_tenant_isolation.py (TENANT_TABLES) and test_aa916_migration_277.py prove it in
--   CI, the nightly isolation probe on Dev (cell tenant.aa_app_user_isolation covers every RLS table).
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: NULL):
--   SELECT to_regclass('shared.writing_signal') AS writing_signal;
--
-- Locks. CREATE TABLE / INDEX / POLICY on a new, empty table only. lock_timeout 5s. Apply through AA-CIS-Infra DB
-- Migrate (byte copy in db/migrations/cis/) with shared.job and booking.job idle (DM-11.4). Re-running is a no-op
-- apart from the guards (CREATE … IF NOT EXISTS, DROP POLICY IF EXISTS + CREATE, grants from nothing).
--
-- Order. Independent of 275 / 276 / 278, applied after 276 (keys in order). Nothing reads or writes the table until
-- the AA-916 S2 / S3 code PR deploys, and that code needs it: merge this file's PR, copy to Infra, DB Migrate check ->
-- apply, merge the schema-reference bot PR, then merge and deploy the code PR. The erasure inventory row (AA-839,
-- services/erasure/inventory.py) ships with this file's PR: the erasure planner reports a registered table that is
-- not applied yet as missing and skips it, so the row is safe before the apply.
--
-- Undo (a NEW forward migration, after reverting the code that writes it):
--   REVOKE ALL ON shared.writing_signal FROM aa_app_user;     -- before anything else (241 invariant)
--   DROP TABLE shared.writing_signal;                          -- -- migrate: destructive (MIG-9)
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243). DB Migrate runs cis/ files as cis_owner, the owner
-- of shared (245), which then owns the table.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── Guard 1: roles, runner rights, re-run shape ────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    owner_ns name;
    cols     text;
    expect   text := 'signal_id uuid, writer text, channel text, scope text, tenant_id uuid, field text, locator jsonb, '
                     'before_text text, after_text text, before_sha256 text, after_sha256 text, gate text, '
                     'problem text, reason_code text, action text, actor_type text, actor_id text, fact_status text, '
                     'exemplar_pref text, audit_log_id uuid, source_table text, source_id text, '
                     'created_at timestamp with time zone';
BEGIN
    IF to_regrole('cis_app') IS NULL OR to_regrole('aa_app_user') IS NULL OR to_regrole('cis_owner') IS NULL
       OR to_regrole('catalog_owner') IS NULL THEN
        RAISE EXCEPTION 'migration 277: roles cis_app, aa_app_user, cis_owner and catalog_owner must exist';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aa_app_user' AND (rolsuper OR rolbypassrls)) THEN
        RAISE EXCEPTION 'migration 277: aa_app_user is superuser or BYPASSRLS: RLS would not apply to it';
    END IF;
    SELECT pg_get_userbyid(n.nspowner) INTO owner_ns FROM pg_namespace n WHERE n.nspname = 'shared';
    IF NOT has_schema_privilege(current_user, 'shared', 'CREATE') THEN
        RAISE EXCEPTION 'migration 277: % may not create in shared (owner %); run it through DB Migrate (cis_owner)',
                        current_user, owner_ns;
    END IF;
    IF to_regclass('shared.writing_signal') IS NOT NULL THEN
        SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
          INTO cols
          FROM pg_attribute a
         WHERE a.attrelid = 'shared.writing_signal'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
        IF cols IS DISTINCT FROM expect THEN
            RAISE EXCEPTION 'migration 277: shared.writing_signal exists with other columns: %', cols;
        END IF;
    END IF;
END $$;

-- ── 1. The signal store ────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.writing_signal (
    signal_id     uuid NOT NULL DEFAULT gen_random_uuid(),
    writer        text NOT NULL,
    channel       text,
    scope         text NOT NULL,
    tenant_id     uuid,
    field         text,
    locator       jsonb,
    before_text   text,
    after_text    text,
    before_sha256 text,
    after_sha256  text,
    gate          text,
    problem       text,
    reason_code   text,
    action        text NOT NULL,
    actor_type    text NOT NULL,
    actor_id      text,
    fact_status   text NOT NULL DEFAULT 'pending',
    exemplar_pref text,
    audit_log_id  uuid,
    source_table  text NOT NULL,
    source_id     text NOT NULL,
    created_at    timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT writing_signal_pkey PRIMARY KEY (signal_id),
    CONSTRAINT writing_signal_writer_check CHECK (writer IN ('a1', 't2', 't9_blog', 't9_social')),
    CONSTRAINT writing_signal_scope_check CHECK (scope IN ('platform', 'tenant')),
    CONSTRAINT writing_signal_scope_tenant_ck
        CHECK ((scope = 'platform' AND tenant_id IS NULL) OR (scope = 'tenant' AND tenant_id IS NOT NULL)),
    CONSTRAINT writing_signal_reason_code_check
        CHECK (reason_code IS NULL
               OR reason_code IN ('fact_not_in_source', 'optional_as_included', 'wrong_place_or_time',
                                  'voice_off_brand', 'ai_phrasing', 'format_channel', 'repair_residue', 'style_only')),
    CONSTRAINT writing_signal_action_check
        CHECK (action IN ('field_edit', 'sentence_cut', 'sentence_rewrite', 'sentence_manual', 'tenant_edit',
                          'reject', 'dismiss', 'regenerate')),
    CONSTRAINT writing_signal_actor_type_check CHECK (actor_type IN ('admin', 'tenant', 'system')),
    CONSTRAINT writing_signal_fact_status_check CHECK (fact_status IN ('pending', 'grey', 'pass', 'fail')),
    CONSTRAINT writing_signal_exemplar_pref_check CHECK (exemplar_pref IS NULL OR exemplar_pref IN ('use', 'never')),
    CONSTRAINT writing_signal_locator_check CHECK (locator IS NULL OR jsonb_typeof(locator) = 'object'),
    CONSTRAINT writing_signal_sha256_check
        CHECK ((before_text IS NULL OR before_sha256 IS NOT NULL) AND (after_text IS NULL OR after_sha256 IS NOT NULL)
               AND (before_sha256 IS NULL OR before_sha256 ~ '^[0-9a-f]{64}$')
               AND (after_sha256 IS NULL OR after_sha256 ~ '^[0-9a-f]{64}$')),
    CONSTRAINT writing_signal_size_check
        CHECK (coalesce(char_length(before_text), 0) <= 200000 AND coalesce(char_length(after_text), 0) <= 200000
               AND coalesce(char_length(field), 0) <= 200 AND coalesce(char_length(channel), 0) <= 64
               AND coalesce(char_length(gate), 0) <= 128 AND coalesce(char_length(actor_id), 0) <= 128
               AND coalesce(char_length(problem), 0) <= 2000),
    CONSTRAINT writing_signal_source_check
        CHECK (char_length(source_table) BETWEEN 1 AND 128 AND char_length(source_id) BETWEEN 1 AND 128)
);

CREATE INDEX IF NOT EXISTS writing_signal_tenant_created_idx
    ON shared.writing_signal (tenant_id, created_at DESC) WHERE scope = 'tenant';
CREATE INDEX IF NOT EXISTS writing_signal_writer_created_idx ON shared.writing_signal (writer, created_at DESC);
CREATE INDEX IF NOT EXISTS writing_signal_source_idx ON shared.writing_signal (source_table, source_id);

COMMENT ON TABLE shared.writing_signal IS
    'AA-916 WM-03 (CIS 277, app ADR 0010): writing-memory signals of the A1 / T2 / T9 writers: the before / after text '
    'of an admin or tenant edit, the reason code of an admin action, the fact status. Deletable: tenant rows go with '
    'the tenant (AA-839 erasure inventory); acp_shared.audit_log keeps only the signal_id and the hashes. Written by '
    'services/writing_memory/signals.py record_writer_feedback only. RLS ENABLE + FORCE: aa_app_user reads and inserts '
    'its own tenant rows only; cis_app sees every row and filters tenant_id in code.';
COMMENT ON COLUMN shared.writing_signal.scope IS
    'AA-916 (277): platform (A1 / Master text, tenant_id NULL; never tenant text, ADR 0010 decision 10) | tenant '
    '(T2 / T9 text of one tenant, tenant_id set).';
COMMENT ON COLUMN shared.writing_signal.locator IS
    'AA-916 (277): where in the field the edit sits, an object: start / end (character offsets), index (sentence), '
    'paragraph. NULL for a whole-field edit or a reason-only signal.';
COMMENT ON COLUMN shared.writing_signal.before_text IS
    'pii:free_text; AA-916 (277): the text before the edit (a sentence, a field or a whole piece). Tenant text for '
    'scope tenant; deleted with the tenant.';
COMMENT ON COLUMN shared.writing_signal.after_text IS
    'pii:free_text; AA-916 (277): the text after the edit (empty string for a cut). Tenant text for scope tenant; '
    'deleted with the tenant.';
COMMENT ON COLUMN shared.writing_signal.before_sha256 IS
    'AA-916 (277): sha256 (lower-case hex) of before_text as UTF-8; the audit_log row carries the same value.';
COMMENT ON COLUMN shared.writing_signal.after_sha256 IS
    'AA-916 (277): sha256 (lower-case hex) of after_text as UTF-8; the audit_log row carries the same value.';
COMMENT ON COLUMN shared.writing_signal.problem IS
    'pii:free_text; AA-916 (277): the gate''s diagnostic for the edited sentence (it quotes the flagged text: a '
    'fact, a number, a claim) or the admin''s own note. Kept here, deletable with the tenant; the audit_log row '
    'carries only its sha256 (ADR 0010 decision 11).';
COMMENT ON COLUMN shared.writing_signal.reason_code IS
    'AA-916 WM-06 (277): why the admin acted (one-click reason chip). fact_not_in_source also sets fact_status fail '
    'and, for A1 / T2 sentences, a Jev truth=false outcome on question a1_claim_supported.';
COMMENT ON COLUMN shared.writing_signal.actor_id IS
    'AA-916 (277): who acted: the shared.admin_users id (x-admin-user-id) for admin, the tenant id or the portal '
    'actor label for tenant, a job label for system. An id or a label, never a name or an e-mail address.';
COMMENT ON COLUMN shared.writing_signal.exemplar_pref IS
    'AA-916 WM-07 (277): the admin''s "use as example" (use) / "never use as example" (never) toggle; NULL = not set.';
COMMENT ON COLUMN shared.writing_signal.audit_log_id IS
    'AA-916 (277): acp_shared.audit_log row of the same action when known (write_audit_log returns no id today, so the '
    'link is usually the other way: the audit row''s details.signal_id).';
COMMENT ON COLUMN shared.writing_signal.source_table IS
    'AA-916 (277): the edited object''s table (content_piece, generated_content, tenant_tour_versions, review_queue, '
    '…); with source_id it names the row. No FK (polymorphic).';

-- ── 2. RLS ─────────────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.writing_signal ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.writing_signal FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS writing_signal_cis_app_all ON shared.writing_signal;
CREATE POLICY writing_signal_cis_app_all ON shared.writing_signal AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS writing_signal_cis_owner_all ON shared.writing_signal;
CREATE POLICY writing_signal_cis_owner_all ON shared.writing_signal AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON shared.writing_signal;
CREATE POLICY tenant_isolation ON shared.writing_signal AS PERMISSIVE FOR ALL TO aa_app_user
    USING (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.writing_signal IS
    'AA-916 (CIS 277): the tenant pool reads and inserts its own tenant rows only; never a platform row, never under '
    'an empty app.tenant_id.';

-- ── 3. Grants ──────────────────────────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON shared.writing_signal FROM PUBLIC;
REVOKE ALL ON shared.writing_signal FROM cis_app, aa_app_user, catalog_owner;   -- also column grants: from nothing
GRANT USAGE ON SCHEMA shared TO aa_app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.writing_signal TO cis_app;
GRANT SELECT, INSERT ON shared.writing_signal TO aa_app_user;

-- ── Guard 2: constraints, indexes, RLS, policies, privileges, AA-859 invariant ──────────────────────────────────────
DO $$
DECLARE
    tbl     oid := 'shared.writing_signal'::regclass;
    missing text;
    pols    text;
    privs   text;
    bad     text;
BEGIN
    SELECT string_agg(want, ', ' ORDER BY want) INTO missing
      FROM unnest(ARRAY['writing_signal_pkey', 'writing_signal_writer_check', 'writing_signal_scope_check',
                        'writing_signal_scope_tenant_ck', 'writing_signal_reason_code_check',
                        'writing_signal_action_check', 'writing_signal_actor_type_check',
                        'writing_signal_fact_status_check', 'writing_signal_exemplar_pref_check',
                        'writing_signal_locator_check', 'writing_signal_sha256_check', 'writing_signal_size_check',
                        'writing_signal_source_check']) AS want
     WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = tbl AND c.conname = want AND c.convalidated);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 277: constraints missing or not validated: %', missing;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                    WHERE x.indrelid = tbl AND c.relname = 'writing_signal_tenant_created_idx'
                      AND pg_get_expr(x.indpred, x.indrelid) = '(scope = ''tenant''::text)')
       OR NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                       WHERE x.indrelid = tbl AND c.relname = 'writing_signal_writer_created_idx')
       OR NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                       WHERE x.indrelid = tbl AND c.relname = 'writing_signal_source_idx') THEN
        RAISE EXCEPTION 'migration 277: the indexes are missing or not as this file defines them';
    END IF;

    IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = tbl) THEN
        RAISE EXCEPTION 'migration 277: shared.writing_signal RLS is not on and forced (ADR 0010 decision 10)';
    END IF;
    SELECT string_agg(p.polname || ':' || CASE WHEN p.polpermissive THEN 'permissive' ELSE 'restrictive' END || ':'
                      || p.polcmd::text || ':'
                      || array_to_string(ARRAY(SELECT pg_get_userbyid(r) FROM unnest(p.polroles) r ORDER BY 1), ',')
                      || ':' || pg_get_expr(p.polqual, p.polrelid) || ':' || pg_get_expr(p.polwithcheck, p.polrelid),
                      ' | ' ORDER BY p.polname)
      INTO pols FROM pg_policy p WHERE p.polrelid = tbl;
    IF pols IS DISTINCT FROM
         'tenant_isolation:permissive:*:aa_app_user:'
         || '((scope = ''tenant''::text) AND (tenant_id = (NULLIF(current_setting(''app.tenant_id''::text, true), '
         || '''''::text))::uuid)):'
         || '((scope = ''tenant''::text) AND (tenant_id = (NULLIF(current_setting(''app.tenant_id''::text, true), '
         || '''''::text))::uuid))'
         || ' | writing_signal_cis_app_all:permissive:*:cis_app:true:true'
         || ' | writing_signal_cis_owner_all:permissive:*:cis_owner:true:true' THEN
        RAISE EXCEPTION 'migration 277: unexpected policies on shared.writing_signal: %', pols;
    END IF;

    SELECT string_agg(r || ':' || p, ', ' ORDER BY r COLLATE "C", p COLLATE "C") INTO privs FROM (
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r, a.privilege_type AS p
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid = tbl
           AND (a.grantee = 0 OR a.grantee IN ('cis_app'::regrole, 'aa_app_user'::regrole,
                                               'catalog_owner'::regrole))) x;
    IF privs IS DISTINCT FROM 'aa_app_user:INSERT, aa_app_user:SELECT, cis_app:DELETE, cis_app:INSERT, '
                              'cis_app:SELECT, cis_app:UPDATE' THEN
        RAISE EXCEPTION 'migration 277: unexpected privileges on shared.writing_signal: %', privs;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = tbl AND a.attacl IS NOT NULL) THEN
        RAISE EXCEPTION 'migration 277: column-level grants on shared.writing_signal';
    END IF;

    -- the AA-859 invariant, version 3 (same text as 272 guard 4 / NO_PRIVILEGE_WITHOUT_RLS_SQL_V3)
    SELECT string_agg(rel || ' ' || privilege_type || COALESCE('(' || column_name || ')', ''), ', ') INTO bad FROM (
SELECT c.oid::regclass::text AS rel, a.privilege_type, NULL::text AS column_name
  FROM pg_class c
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
 CROSS JOIN LATERAL aclexplode(c.relacl) a
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND NOT c.relrowsecurity
   AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
   AND ns.nspname NOT LIKE 'pg_toast%'
   AND a.grantee = 'aa_app_user'::regrole
   AND NOT (ns.nspname = 'catalog'
            AND c.relowner IS NOT DISTINCT FROM to_regrole('catalog_owner')
            AND a.privilege_type = 'SELECT')
   AND NOT (ns.nspname || '.' || c.relname = ANY (ARRAY['acp_contract.route', 'acp_contract.atom_segment',
                                                        'acp_contract.atom_segment_member',
                                                        'acp_contract.atom_segment_alias',
                                                        'acp_shared.place_card_alias', 'acp_shared.atom_place_card',
                                                        'gold_aa_internal.v_tour_liveness'])
            AND a.privilege_type = 'SELECT')
UNION ALL
SELECT c.oid::regclass::text, a.privilege_type, att.attname::text
  FROM pg_class c
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
  JOIN pg_attribute att ON att.attrelid = c.oid AND att.attacl IS NOT NULL AND NOT att.attisdropped
 CROSS JOIN LATERAL aclexplode(att.attacl) a
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND NOT c.relrowsecurity
   AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
   AND ns.nspname NOT LIKE 'pg_toast%'
   AND a.grantee = 'aa_app_user'::regrole
   AND NOT (ns.nspname || '.' || c.relname = 'acp_shared.place_card'
            AND att.attname IN ('card_id', 'status')
            AND a.privilege_type = 'SELECT')
ORDER BY 1, 3, 2
    ) v;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 277: aa_app_user holds privileges on relations without RLS: % (AA-859 invariant v3)',
            bad;
    END IF;
END $$;

-- ── Guard 3: behaviour (a sub-block that always rolls back) ────────────────────────────────────────────────────────
DO $$
DECLARE
    probe   uuid := gen_random_uuid();
    h       text := repeat('a', 64);
    n       bigint;
    refused boolean;
    bad     text;
BEGIN
    BEGIN
        INSERT INTO shared.writing_signal (writer, channel, scope, tenant_id, field, before_text, after_text,
                                           before_sha256, after_sha256, action, actor_type, source_table, source_id)
        VALUES ('t9_blog', 'blog', 'tenant', probe, 'content_text', 'before', 'after', h, h, 'tenant_edit', 'tenant',
                'content_piece', 'migration-277-probe'),
               ('a1', 'master', 'platform', NULL, 'overview', 'before', 'after', h, h, 'field_edit', 'admin',
                'generated_content', 'migration-277-probe');
        SELECT count(*) INTO n FROM shared.writing_signal WHERE source_id = 'migration-277-probe';
        IF n <> 2 THEN
            RAISE EXCEPTION 'migration 277: the runner reads % of its 2 probe rows (FORCE RLS without its policy?)', n;
        END IF;

        FOREACH bad IN ARRAY ARRAY[
            $q$('a1', 'platform', gen_random_uuid(), NULL, NULL, NULL, 'field_edit')$q$,     -- platform with a tenant
            $q$('t9_blog', 'tenant', NULL, NULL, NULL, NULL, 'tenant_edit')$q$,              -- tenant without one
            $q$('a1', 'platform', NULL, 'bogus', NULL, NULL, 'reject')$q$,                   -- unknown reason code
            $q$('a1', 'platform', NULL, NULL, 'text', NULL, 'field_edit')$q$,                -- text without its hash
            $q$('a1', 'platform', NULL, NULL, 'text', 'ABC', 'field_edit')$q$]               -- malformed hash
        LOOP
            refused := false;
            BEGIN
                EXECUTE 'INSERT INTO shared.writing_signal (writer, scope, tenant_id, reason_code, before_text, '
                        'before_sha256, action, actor_type, source_table, source_id) '
                        'SELECT w, s, t::uuid, r, b, bh, a, ''admin'', ''probe'', ''migration-277-probe'' FROM (VALUES '
                        || bad || ') v(w, s, t, r, b, bh, a)';
            EXCEPTION WHEN check_violation THEN refused := true;
            END;
            IF NOT refused THEN
                RAISE EXCEPTION 'migration 277: the CHECKs accepted %', bad;
            END IF;
        END LOOP;

        RAISE EXCEPTION 'probe done' USING ERRCODE = 'ZZ277';
    EXCEPTION WHEN SQLSTATE 'ZZ277' THEN
        NULL;
    END;
    IF EXISTS (SELECT 1 FROM shared.writing_signal WHERE source_id = 'migration-277-probe') THEN
        RAISE EXCEPTION 'migration 277: the behaviour probe was not rolled back';
    END IF;
    SELECT count(*) INTO n FROM shared.writing_signal;
    RAISE NOTICE 'migration 277: shared.writing_signal under RLS (forced), % rows', n;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('277', now(), 'AA-916 WM-03: shared.writing_signal, deletable writing-memory signals (before/after text, '
                      'reason codes), RLS forced, tenant pool own tenant rows only')
ON CONFLICT (version) DO NOTHING;

COMMIT;
