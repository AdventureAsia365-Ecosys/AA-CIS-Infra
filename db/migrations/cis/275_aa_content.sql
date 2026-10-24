-- Migration 275: AA-977 (CRM-B5) — AA-authored content: "Before you go" prep packs, starter templates and campaign
-- content blocks, written and published by AA staff in CIS and served to the partner CRM over catalog.http.v1.
--
-- Why. Design v3 §5.9 / §6.3 (root docs/audits/2026-10-21-S246-crm-design-v3) and contract catalog.http.v1 1.2
-- (root docs/contracts/catalog.http.v1.openapi.yaml): AA staff write prep packs (R38), starter templates (R9) and
-- campaign blocks (R14) in EN and VI; agencies use them in the CRM. Two rules:
--   R  draft content is never served;
--   E  when a newer version is published, the CRM can still fetch the version it uses (a published version never
--      changes and is never deleted).
-- Nothing stores this today. The served routes (/catalog/v1/aa-content, M2M scope cis.catalog/read) and the admin
-- editor API (/admin/aa-content) arrive with the AA-977 code PR; this file is storage only.
--
-- What.
--   1. gold_aa_internal.aa_content_item: one piece of content in ONE locale (the contract's version path returns one
--      locale). content_id uuid PK; kind prep_pack | starter_template | campaign_block; locale en | vi; group_key
--      (^[a-z0-9][a-z0-9-]{1,79}$) pairs the EN and VI copies, UNIQUE (group_key, locale); retired_at / retired_by
--      (set together; the list hides a retired item, its published versions stay fetchable); created_at / created_by
--      / updated_at. kind, locale and group_key are fixed once the row exists (trigger): a published version is
--      served with them, so changing them would change a version the CRM pinned (E).
--   2. gold_aa_internal.aa_content_version: (content_id, version) PK, version >= 1; status draft | published; title
--      1–300 characters; body_markdown <= 20000 characters; applies_to jsonb object with at most the keys
--      country_codes and tours (the contract's AaContent.applies_to); content_hash ('sha256:' + 64 hex), published_at
--      and published_by are set exactly when the row is published (CHECK). One draft per item (partial unique index);
--      an index on the published versions (content_id, version DESC) for the served reads.
--   3. A BEFORE INSERT OR UPDATE OR DELETE trigger on the version table (rule E):
--        INSERT   only a draft, numbered max(version) + 1 of its item (so the draft is always the newest version);
--        UPDATE   a published row never changes (restrict_violation); a draft may be edited and turned into a
--                 published row once; content_id and version never change;
--        DELETE   only a draft (discard); a published row is refused (restrict_violation).
--      A BEFORE UPDATE trigger on the item table refuses a change of content_id, kind, locale, group_key or
--      created_at / created_by. Writers are named by a label (an 'admin:<staff uuid>' or 'seed:AA-977'), never a name
--      or an e-mail address.
--   4. gold_aa_internal.v_aa_content_published: the published versions only, with their item's kind, locale,
--      group_key and retired_at. The served reader reads only this view, so rule R sits in SQL.
--   5. Grants. REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner first (it also takes away the DML that
--      the Dev default ACL of cis_owner gives cis_app on every new table, CIS 245), then cis_app: item SELECT, INSERT,
--      UPDATE (no DELETE: an item is retired, never deleted); version SELECT, INSERT, UPDATE, DELETE (the trigger
--      refuses deleting a published row); view SELECT. Nothing for aa_app_user (the AA-859 invariant: no tenant-pool
--      privilege on a relation without RLS) or catalog_owner (the CRM reads over HTTP, root ADR 0008a decision 1).
--      No RLS: no tenant column and no personal data (AA-authored marketing text), like 272's lifecycle record.
--   6. Register 275.
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before: the roles cis_app, aa_app_user, catalog_owner exist; the runner may create in gold_aa_internal; the two
--      tables, if present, have exactly this file's columns (re-run);
--   2. after: every named CHECK / unique constraint is there and validated; the three triggers; the two indexes; the
--      view's columns; privileges exactly as in point 5 (no PUBLIC, aa_app_user or catalog_owner privilege, no
--      column-level grant);
--   3. behaviour (a probe item in a sub-block that is always rolled back): a draft is not in the view, its published
--      row is; updating or deleting the published row raises restrict_violation; a second draft of one item violates
--      the unique index; a published row cannot be inserted directly; the item's locale cannot change.
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: both NULL):
--   SELECT to_regclass('gold_aa_internal.aa_content_item') AS item_table,
--          to_regclass('gold_aa_internal.aa_content_version') AS version_table;
--
-- Locks. New objects only: no lock on an existing table. lock_timeout 5s anyway. Apply through AA-CIS-Infra DB
-- Migrate (byte copy in db/migrations/cis/) with shared.job and booking.job idle (DM-11.4). Re-running is a no-op
-- apart from the guards.
--
-- Order with the code. Nothing reads these objects until the AA-977 code PR (services/aa_content, the /catalog/v1
-- /aa-content routes, /admin/aa-content) deploys, and that code needs them: merge this file's PR, copy to Infra, DB
-- Migrate check → apply, then merge and deploy the code PR. The seed (scripts/aa977_seed_aa_content.py) runs after.
--
-- Undo (a NEW forward migration; only before the code is deployed): DROP VIEW gold_aa_internal.v_aa_content_published;
-- DROP TABLE gold_aa_internal.aa_content_version; DROP TABLE gold_aa_internal.aa_content_item; DROP FUNCTION
-- gold_aa_internal.aa_content_version_guard(); DROP FUNCTION gold_aa_internal.aa_content_item_guard().
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243). DB Migrate runs cis/ files as cis_owner, the owner
-- of gold_aa_internal (245).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── Guard 1: roles, runner rights, re-run shape ────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    owner_ns     name;
    cols         text;
    item_expect  text := 'content_id uuid, kind text, locale text, group_key text, retired_at timestamp with time '
                         'zone, retired_by text, created_at timestamp with time zone, created_by text, updated_at '
                         'timestamp with time zone';
    ver_expect   text := 'content_id uuid, version integer, status text, title text, body_markdown text, applies_to '
                         'jsonb, content_hash text, published_at timestamp with time zone, published_by text, '
                         'created_at timestamp with time zone, created_by text, updated_at timestamp with time zone';
BEGIN
    IF to_regrole('cis_app') IS NULL OR to_regrole('aa_app_user') IS NULL OR to_regrole('catalog_owner') IS NULL THEN
        RAISE EXCEPTION 'migration 275: roles cis_app, aa_app_user and catalog_owner must exist';
    END IF;
    SELECT pg_get_userbyid(n.nspowner) INTO owner_ns FROM pg_namespace n WHERE n.nspname = 'gold_aa_internal';
    IF NOT has_schema_privilege(current_user, 'gold_aa_internal', 'CREATE') THEN
        RAISE EXCEPTION 'migration 275: % may not create in gold_aa_internal (owner %); run it through DB Migrate '
                        '(cis_owner)', current_user, owner_ns;
    END IF;

    IF to_regclass('gold_aa_internal.aa_content_item') IS NOT NULL THEN
        SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
          INTO cols
          FROM pg_attribute a
         WHERE a.attrelid = 'gold_aa_internal.aa_content_item'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
        IF cols IS DISTINCT FROM item_expect THEN
            RAISE EXCEPTION 'migration 275: gold_aa_internal.aa_content_item exists with other columns: %', cols;
        END IF;
    END IF;
    IF to_regclass('gold_aa_internal.aa_content_version') IS NOT NULL THEN
        SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
          INTO cols
          FROM pg_attribute a
         WHERE a.attrelid = 'gold_aa_internal.aa_content_version'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
        IF cols IS DISTINCT FROM ver_expect THEN
            RAISE EXCEPTION 'migration 275: gold_aa_internal.aa_content_version exists with other columns: %', cols;
        END IF;
    END IF;
END $$;

-- ── 1. The item (one locale of one piece of content) ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS gold_aa_internal.aa_content_item (
    content_id  uuid NOT NULL DEFAULT gen_random_uuid(),
    kind        text NOT NULL,
    locale      text NOT NULL,
    group_key   text NOT NULL,
    retired_at  timestamp with time zone,
    retired_by  text,
    created_at  timestamp with time zone NOT NULL DEFAULT now(),
    created_by  text NOT NULL,
    updated_at  timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT aa_content_item_pkey PRIMARY KEY (content_id),
    CONSTRAINT aa_content_item_kind_check CHECK (kind IN ('prep_pack', 'starter_template', 'campaign_block')),
    CONSTRAINT aa_content_item_locale_check CHECK (locale IN ('en', 'vi')),
    CONSTRAINT aa_content_item_group_key_check CHECK (group_key ~ '^[a-z0-9][a-z0-9-]{1,79}$'),
    CONSTRAINT aa_content_item_retired_check CHECK ((retired_at IS NULL) = (retired_by IS NULL)),
    CONSTRAINT aa_content_item_actor_check
        CHECK (char_length(created_by) BETWEEN 1 AND 64
               AND (retired_by IS NULL OR char_length(retired_by) BETWEEN 1 AND 64)),
    CONSTRAINT aa_content_item_group_locale_key UNIQUE (group_key, locale)
);

COMMENT ON TABLE gold_aa_internal.aa_content_item IS
    'AA-977 (CRM-B5): one AA-authored piece of content in one locale (prep_pack R38, starter_template R9, '
    'campaign_block R14). The EN and VI copies share group_key. Versions in aa_content_version; served to the partner '
    'CRM over catalog.http.v1 (/catalog/v1/aa-content) from v_aa_content_published only. No tenant column, no '
    'personal data.';
COMMENT ON COLUMN gold_aa_internal.aa_content_item.retired_at IS
    'Set with retired_by when staff retire the item: the served list hides it, its published versions stay '
    'fetchable by version (the CRM keeps the version it uses). NULL = live.';
COMMENT ON COLUMN gold_aa_internal.aa_content_item.created_by IS
    'Who created the row: admin:<shared.admin_users id> or seed:AA-977. A label, not a person''s name or e-mail.';

CREATE OR REPLACE FUNCTION gold_aa_internal.aa_content_item_guard() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.content_id IS DISTINCT FROM OLD.content_id OR NEW.kind IS DISTINCT FROM OLD.kind
       OR NEW.locale IS DISTINCT FROM OLD.locale OR NEW.group_key IS DISTINCT FROM OLD.group_key
       OR NEW.created_at IS DISTINCT FROM OLD.created_at OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION 'gold_aa_internal.aa_content_item: content_id, kind, locale, group_key and created_* never '
                        'change (AA-977: published versions are served with them)'
              USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS aa_content_item_guard ON gold_aa_internal.aa_content_item;
CREATE TRIGGER aa_content_item_guard
    BEFORE UPDATE ON gold_aa_internal.aa_content_item
    FOR EACH ROW EXECUTE FUNCTION gold_aa_internal.aa_content_item_guard();

-- ── 2. The versions (draft or published) ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS gold_aa_internal.aa_content_version (
    content_id    uuid NOT NULL,
    version       integer NOT NULL,
    status        text NOT NULL DEFAULT 'draft',
    title         text NOT NULL,
    body_markdown text NOT NULL DEFAULT '',
    applies_to    jsonb NOT NULL DEFAULT '{}'::jsonb,
    content_hash  text,
    published_at  timestamp with time zone,
    published_by  text,
    created_at    timestamp with time zone NOT NULL DEFAULT now(),
    created_by    text NOT NULL,
    updated_at    timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT aa_content_version_pkey PRIMARY KEY (content_id, version),
    CONSTRAINT aa_content_version_content_id_fkey FOREIGN KEY (content_id)
        REFERENCES gold_aa_internal.aa_content_item (content_id) ON DELETE RESTRICT,
    CONSTRAINT aa_content_version_version_check CHECK (version >= 1),
    CONSTRAINT aa_content_version_status_check CHECK (status IN ('draft', 'published')),
    CONSTRAINT aa_content_version_title_check CHECK (char_length(title) BETWEEN 1 AND 300),
    CONSTRAINT aa_content_version_body_check CHECK (char_length(body_markdown) <= 20000),
    CONSTRAINT aa_content_version_applies_to_check
        CHECK (jsonb_typeof(applies_to) = 'object' AND (applies_to - 'country_codes' - 'tours') = '{}'::jsonb),
    CONSTRAINT aa_content_version_published_check
        CHECK (CASE status
                 WHEN 'draft' THEN content_hash IS NULL AND published_at IS NULL AND published_by IS NULL
                 ELSE content_hash IS NOT NULL AND published_at IS NOT NULL AND published_by IS NOT NULL
               END),
    CONSTRAINT aa_content_version_hash_check CHECK (content_hash IS NULL OR content_hash ~ '^sha256:[0-9a-f]{64}$'),
    CONSTRAINT aa_content_version_actor_check
        CHECK (char_length(created_by) BETWEEN 1 AND 64
               AND (published_by IS NULL OR char_length(published_by) BETWEEN 1 AND 64))
);

CREATE UNIQUE INDEX IF NOT EXISTS aa_content_version_one_draft_idx
    ON gold_aa_internal.aa_content_version (content_id) WHERE status = 'draft';
CREATE INDEX IF NOT EXISTS aa_content_version_published_idx
    ON gold_aa_internal.aa_content_version (content_id, version DESC) WHERE status = 'published';

COMMENT ON TABLE gold_aa_internal.aa_content_version IS
    'AA-977 (CRM-B5): the versions of one aa_content_item. At most one draft (always the newest version); a published '
    'version never changes and is never deleted (trigger aa_content_version_guard), so the CRM can keep fetching the '
    'version it uses. Served only through v_aa_content_published.';
COMMENT ON COLUMN gold_aa_internal.aa_content_version.content_hash IS
    'sha256:<hex> over the canonical JSON of the served AaContent body (catalog.http.v1), set at publish; the ETag.';

CREATE OR REPLACE FUNCTION gold_aa_internal.aa_content_version_guard() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE
    newest integer;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'draft' THEN
            RAISE EXCEPTION 'gold_aa_internal.aa_content_version: a version is inserted as a draft and then published '
                            '(AA-977)' USING ERRCODE = 'restrict_violation';
        END IF;
        SELECT max(v.version) INTO newest FROM gold_aa_internal.aa_content_version v
         WHERE v.content_id = NEW.content_id;
        IF NEW.version <> COALESCE(newest, 0) + 1 THEN
            RAISE EXCEPTION 'gold_aa_internal.aa_content_version: a new draft of % must be version % (got %)',
                NEW.content_id, COALESCE(newest, 0) + 1, NEW.version USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.status = 'published' THEN
        RAISE EXCEPTION 'gold_aa_internal.aa_content_version: published version % of % never changes and is never '
                        'deleted (AA-977 rule E)', OLD.version, OLD.content_id USING ERRCODE = 'restrict_violation';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    IF NEW.content_id IS DISTINCT FROM OLD.content_id OR NEW.version IS DISTINCT FROM OLD.version
       OR NEW.created_at IS DISTINCT FROM OLD.created_at OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION 'gold_aa_internal.aa_content_version: content_id, version and created_* never change (AA-977)'
              USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS aa_content_version_guard ON gold_aa_internal.aa_content_version;
CREATE TRIGGER aa_content_version_guard
    BEFORE INSERT OR UPDATE OR DELETE ON gold_aa_internal.aa_content_version
    FOR EACH ROW EXECUTE FUNCTION gold_aa_internal.aa_content_version_guard();

-- ── 3. The served view (published versions only: rule R) ───────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW gold_aa_internal.v_aa_content_published AS
SELECT v.content_id,
       i.kind,
       i.locale,
       i.group_key,
       v.version,
       v.title,
       v.body_markdown,
       v.applies_to,
       v.published_at,
       v.content_hash,
       i.retired_at
  FROM gold_aa_internal.aa_content_version v
  JOIN gold_aa_internal.aa_content_item i ON i.content_id = v.content_id
 WHERE v.status = 'published';

COMMENT ON VIEW gold_aa_internal.v_aa_content_published IS
    'AA-977 (CRM-B5): every published version of AA-authored content with its item''s kind, locale, group_key and '
    'retired_at. The only read of catalog.http.v1 /aa-content: a draft is never in it (rule R).';

-- ── 4. Grants ──────────────────────────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON gold_aa_internal.aa_content_item, gold_aa_internal.aa_content_version,
              gold_aa_internal.v_aa_content_published FROM PUBLIC;
REVOKE ALL ON gold_aa_internal.aa_content_item, gold_aa_internal.aa_content_version,
              gold_aa_internal.v_aa_content_published FROM cis_app, aa_app_user, catalog_owner;
GRANT SELECT, INSERT, UPDATE ON gold_aa_internal.aa_content_item TO cis_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON gold_aa_internal.aa_content_version TO cis_app;
GRANT SELECT ON gold_aa_internal.v_aa_content_published TO cis_app;

-- ── Guards 2 + 3 ───────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    i_oid   oid := 'gold_aa_internal.aa_content_item'::regclass;
    v_oid   oid := 'gold_aa_internal.aa_content_version'::regclass;
    w_oid   oid := 'gold_aa_internal.v_aa_content_published'::regclass;
    cols    text;
    privs   text;
    missing text;
BEGIN
    -- 2. constraints, triggers, indexes, view columns
    SELECT string_agg(want, ', ' ORDER BY want) INTO missing
      FROM unnest(ARRAY['aa_content_item_pkey', 'aa_content_item_kind_check', 'aa_content_item_locale_check',
                        'aa_content_item_group_key_check', 'aa_content_item_retired_check',
                        'aa_content_item_actor_check', 'aa_content_item_group_locale_key',
                        'aa_content_version_pkey', 'aa_content_version_content_id_fkey',
                        'aa_content_version_version_check', 'aa_content_version_status_check',
                        'aa_content_version_title_check', 'aa_content_version_body_check',
                        'aa_content_version_applies_to_check', 'aa_content_version_published_check',
                        'aa_content_version_hash_check', 'aa_content_version_actor_check']) AS want
     WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                        WHERE c.conrelid IN (i_oid, v_oid) AND c.conname = want AND c.convalidated);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 275: constraints missing or not validated: %', missing;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = i_oid AND tgname = 'aa_content_item_guard'
                      AND NOT tgisinternal)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = v_oid AND tgname = 'aa_content_version_guard'
                         AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'migration 275: a guard trigger is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                    WHERE x.indrelid = v_oid AND c.relname = 'aa_content_version_one_draft_idx' AND x.indisunique
                      AND pg_get_expr(x.indpred, x.indrelid) = '(status = ''draft''::text)')
       OR NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                       WHERE x.indrelid = v_oid AND c.relname = 'aa_content_version_published_idx') THEN
        RAISE EXCEPTION 'migration 275: the version indexes are missing or not as this file defines them';
    END IF;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
      INTO cols
      FROM pg_attribute a WHERE a.attrelid = w_oid AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'content_id uuid, kind text, locale text, group_key text, version integer, title text, '
                             'body_markdown text, applies_to jsonb, published_at timestamp with time zone, '
                             'content_hash text, retired_at timestamp with time zone' THEN
        RAISE EXCEPTION 'migration 275: v_aa_content_published has unexpected columns: %', cols;
    END IF;

    -- 2. privileges of the four roles that matter, table level, and no column grants
    SELECT string_agg(r || ':' || o || ':' || p, ', ' ORDER BY r COLLATE "C", o COLLATE "C", p COLLATE "C")
      INTO privs FROM (
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r,
               CASE c.oid WHEN i_oid THEN 'item' WHEN v_oid THEN 'version' ELSE 'view' END AS o,
               a.privilege_type AS p
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid IN (i_oid, v_oid, w_oid)
           AND (a.grantee = 0 OR a.grantee IN ('cis_app'::regrole, 'aa_app_user'::regrole,
                                               'catalog_owner'::regrole))) x;
    IF privs IS DISTINCT FROM 'cis_app:item:INSERT, cis_app:item:SELECT, cis_app:item:UPDATE, '
                              'cis_app:version:DELETE, cis_app:version:INSERT, cis_app:version:SELECT, '
                              'cis_app:version:UPDATE, cis_app:view:SELECT' THEN
        RAISE EXCEPTION 'migration 275: unexpected privileges on the AA content objects: %', privs;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid IN (i_oid, v_oid, w_oid) AND a.attacl IS NOT NULL) THEN
        RAISE EXCEPTION 'migration 275: column-level grants on the AA content objects';
    END IF;
END $$;

DO $$
DECLARE
    probe   uuid := gen_random_uuid();
    refused boolean;
    n       bigint;
BEGIN
    -- 3. behaviour, on a probe item; the block always ends in SQLSTATE ZZ275, which rolls the probe back
    BEGIN
        INSERT INTO gold_aa_internal.aa_content_item (content_id, kind, locale, group_key, created_by)
        VALUES (probe, 'prep_pack', 'en', 'zz-migration-275-probe', 'migration:275');
        INSERT INTO gold_aa_internal.aa_content_version (content_id, version, title, created_by)
        VALUES (probe, 1, 'probe', 'migration:275');
        SELECT count(*) INTO n FROM gold_aa_internal.v_aa_content_published WHERE content_id = probe;
        IF n <> 0 THEN
            RAISE EXCEPTION 'migration 275: v_aa_content_published serves a draft';
        END IF;
        UPDATE gold_aa_internal.aa_content_version
           SET status = 'published', content_hash = 'sha256:' || repeat('0', 64), published_at = now(),
               published_by = 'migration:275'
         WHERE content_id = probe AND version = 1;
        SELECT count(*) INTO n FROM gold_aa_internal.v_aa_content_published WHERE content_id = probe;
        IF n <> 1 THEN
            RAISE EXCEPTION 'migration 275: v_aa_content_published misses a published version';
        END IF;

        refused := false;
        BEGIN
            UPDATE gold_aa_internal.aa_content_version SET title = 'changed' WHERE content_id = probe AND version = 1;
        EXCEPTION WHEN restrict_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 275: a published version could be updated';
        END IF;
        refused := false;
        BEGIN
            DELETE FROM gold_aa_internal.aa_content_version WHERE content_id = probe AND version = 1;
        EXCEPTION WHEN restrict_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 275: a published version could be deleted';
        END IF;
        refused := false;
        BEGIN
            INSERT INTO gold_aa_internal.aa_content_version (content_id, version, status, title, content_hash,
                                                             published_at, published_by, created_by)
            VALUES (probe, 2, 'published', 'probe', 'sha256:' || repeat('1', 64), now(), 'migration:275',
                    'migration:275');
        EXCEPTION WHEN restrict_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 275: a published version could be inserted directly';
        END IF;

        INSERT INTO gold_aa_internal.aa_content_version (content_id, version, title, created_by)
        VALUES (probe, 2, 'probe v2', 'migration:275');
        refused := false;
        BEGIN
            INSERT INTO gold_aa_internal.aa_content_version (content_id, version, title, created_by)
            VALUES (probe, 3, 'probe v3', 'migration:275');
        EXCEPTION WHEN unique_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 275: a second draft of one item was accepted';
        END IF;
        refused := false;
        BEGIN
            UPDATE gold_aa_internal.aa_content_item SET locale = 'vi' WHERE content_id = probe;
        EXCEPTION WHEN restrict_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 275: an item''s locale could change';
        END IF;

        RAISE EXCEPTION 'probe done' USING ERRCODE = 'ZZ275';
    EXCEPTION WHEN SQLSTATE 'ZZ275' THEN
        NULL;
    END;
    IF EXISTS (SELECT 1 FROM gold_aa_internal.aa_content_item WHERE content_id = probe) THEN
        RAISE EXCEPTION 'migration 275: the behaviour probe was not rolled back';
    END IF;
    SELECT count(*) INTO n FROM gold_aa_internal.aa_content_item;
    RAISE NOTICE 'migration 275: AA content items present: %', n;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('275', now(), 'AA-977 CRM-B5: AA-authored content (items, versions, published view)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
