-- migrate: destructive
-- Migration 282: AA-853 (S251 decision D2) — codify in git the CIS schema state Dev has but no migration makes. Dev is
-- the truth: on Dev every statement below is a no-op (each one checks the catalog first and does nothing when Dev's
-- shape is already there: no ALTER, no rewrite, no lock beyond catalog reads); on a database built from the migration
-- files alone (a fresh install, the CI DB, the nightly schema drift replay of AA-CIS-Infra) it converges to Dev.
--
-- Why. The nightly DB Schema Dump replays every applied migration into a scratch PostgreSQL and diffs it against the
-- live catalog (AA-CIS-Infra db/replay_migrations.py, db/schema_drift.py). With the lost AA-ACP-App lineage restored
-- by the replay's baseline, what is left are hand changes on Dev that no file holds (data standards MIG-5):
--   a. columns added by hand: shared.pipeline_runs.llm_model / llm_provider / step_name (text), shared.
--      tenant_brand_rules.created_at (timestamptz; also in the 104 backup copy tenant_brand_rules_deleted_aa404, which
--      took the table's shape on 2026-08-15, so the column predates 104) and silver_aa_internal.raw_sources.file_hash
--      (varchar(64); 123 registered only its unique index, "already live via manual DDL", and fails without it);
--   b. nullability changed by hand: shared.tenant_brand_rules.brand_name NOT NULL (043 adds it nullable; the 104 copy
--      has NOT NULL too), shared.tenants.is_canary / skip_hitl nullable (058 adds them NOT NULL);
--   c. indexes as Dev has them: 044 ran in an earlier form (143's header lists the live constraint as
--      uq_tenant_brand_name_version; the file names it uq_brand_rules_tenant_brand_version), and 048's GIN index on
--      generated_content.metadata is idx_generated_content_metadata_gin with jsonb_path_ops on Dev (the file:
--      idx_generated_content_metadata_brand_rule, default opclass);
--   d. tables dropped by hand: acp_shared.unknown_ledger (AA-598 G3, 16/09/2026) and acp_shared.content_metric_snapshot,
--      acp_deliver.pieces / packets, acp_shared.acp_v2_slots / acp_v2_runs (AA-603, 21/09/2026); the scripts are in
--      the AA-Ecosys root repo docs/archive/2026/. Schemas bronze, gold, ops, silver (001's v1 layer) are gone on Dev
--      too (dropped by hand before the registry existed);
--   e. column types changed by hand: silver_aa_internal.raw_tours.country / duration / group_size (varchar(100)),
--      period / price_raw / sku / tour_id_external (varchar(200)) are text on Dev, so every view over them is text
--      too (acp_contract.v_trip_registry, catalog._live_tour and the catalog views on it, shared.v_country_unmapped,
--      shared.v_pipeline_summary); chk_raw_tours_country has the form it gets when created on a text column (197 ran
--      after the change) and raw_tours_review_status_check the form a type rewrite of review_status leaves.
--      shared.membership_plans.overage_rate_usd_per_tour / _per_1k_calls are numeric(8,4) on Dev: the table predates
--      223, whose "baseline capture" CREATE TABLE IF NOT EXISTS wrote numeric(10,4) (a no-op on Dev); its view
--      shared.v_tenant_monthly_usage follows.
-- public.checkpoint_migrations (LangGraph's own bookkeeping, kept on purpose by 122) is not a CIS object: AA-CIS-Infra
-- db/schema_drift_decisions.json records it as an exemption instead.
--
-- What, in order (one transaction; each step reads the catalog and acts only where the shape differs from Dev):
--   1. Add the hand-made columns (a): no default, nullable, as the dump shows them (the dump has no defaults; none of
--      them is read by code). The 104 copy only when it exists.
--   2. Nullability (b): DROP NOT NULL on is_canary / skip_hitl; SET NOT NULL on brand_name, refused with a clear
--      message when a NULL row exists (fix the data first).
--   3. Indexes (c): rename 044's constraint (its index follows) to uq_tenant_brand_name_version; replace 048's index by
--      idx_generated_content_metadata_gin (jsonb_path_ops); 123's partial unique index on raw_sources.file_hash.
--   4. Hand drops (d): each table only when it exists and is EMPTY (refused otherwise: the drop on Dev removed 0-row
--      tables, a database with rows there needs a decision, not a migration); the four v1 schemas with CASCADE only
--      when every table in them is empty AND the running role may drop them (on a database migrated by DB Migrate
--      they are the RDS master's, from 001, and 245 did not move them: left with a NOTICE, recorded as an owner
--      decision in AA-CIS-Infra db/schema_drift_decisions.json).
--   5. Types (e): only when a column differs. Every view that depends on a changed column, and every view on those
--      (transitively), is saved (definition, reloptions, owner, privileges, comments), dropped as its owner (catalog
--      views as catalog_owner, the X1 S22 catalog recipe), the columns are altered (varchar -> text is binary
--      coercible: no rewrite; numeric(10,4) -> numeric(8,4) rewrites the small plans table), triggers on the changed
--      columns are recreated from pg_get_triggerdef, and the views are recreated in dependency order with the same
--      options, owner, privileges and comments. The two CHECKs are then put in Dev's form when their values match.
--      Refused (RAISE) on anything it cannot recreate faithfully: a materialized view, a view owned by a role other
--      than cis_owner / catalog_owner, a cis_owner view on a catalog view, a policy or rule other than a view's own
--      _RETURN on a changed column, a column grant or default on a view.
--   6. Post-check: every column, index, nullability and CHECK is Dev's; every dropped table is gone; every recreated
--      view exists with its owner, columns, options and privileges. Then register 282.
--
-- On Dev (expected; the preflight below shows it): steps 1-5 find nothing to do and say so in NOTICEs; step 5's GRANT
-- CREATE on schema catalog is not even issued. The two `SET LOCAL ROLE` switches of the catalog recipe still run (they
-- change nothing). A re-run anywhere is a no-op.
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: 0 rows):
--   SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull
--     FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
--    WHERE (n.nspname, c.relname, a.attname) IN (('silver_aa_internal', 'raw_tours', 'country'),
--          ('shared', 'membership_plans', 'overage_rate_usd_per_tour'), ('shared', 'tenants', 'is_canary'))
--      AND (format_type(a.atttypid, a.atttypmod) NOT IN ('text', 'numeric(8,4)', 'boolean') OR
--           (c.relname = 'tenants' AND a.attnotnull));
--
-- Locks. On Dev: catalog reads only, lock_timeout 5s. On a database in the old shape: ACCESS EXCLUSIVE on the tables
-- and views it changes, for the length of the file (small tables; plans: a rewrite of 4 rows). Apply through
-- AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/) with shared.job and booking.job idle (DM-11.4). The
-- `destructive` header is for the drops of step 4, which only run on a database that still has those objects; DB
-- Migrate takes its RDS snapshot first as for any destructive file.
--
-- Readiness: no REQUIRED_CIS_SCHEMA bump (api/core/readiness.py): no code needs 282. NUMBER: 282 was assigned by the
-- S251 plan (281 is held for another lane). The readiness check compares max(version) of shared.schema_versions, so
-- if 281 is applied after 282, code that needs 281 must not be deployed on 282's evidence alone.
--
-- X1. One BEGIN … COMMIT block. DB Migrate runs cis/ files as cis_owner (245), the owner of every table and of the
-- cis_owner views it touches; catalog views are dropped and recreated as catalog_owner after GRANT CREATE ON SCHEMA
-- catalog TO catalog_owner, then SET LOCAL ROLE cis_owner and REVOKE (the recipe of 253 / 258 / 273 / 279). Never
-- RESET ROLE. The state between the blocks travels in the transaction-local setting aa282.state (set_config).
--
-- Undo: none needed on Dev (nothing changes). On a converged copy the old shape is the files before 282; a forward
-- migration would have to re-add what Dev dropped, which nobody wants.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── 0. Preconditions ───────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    -- shared.membership_plans is not required: a database where 223 never ran has no plans table to narrow.
    FOREACH t IN ARRAY ARRAY['shared.pipeline_runs', 'shared.tenant_brand_rules', 'shared.tenants',
                             'silver_aa_internal.raw_sources', 'silver_aa_internal.raw_tours',
                             'silver_aa_internal.generated_content'] LOOP
        IF to_regclass(t) IS NULL THEN
            RAISE EXCEPTION 'migration 282: % does not exist', t;
        END IF;
    END LOOP;
    IF to_regrole('catalog_owner') IS NULL OR to_regrole('cis_owner') IS NULL THEN
        RAISE EXCEPTION 'migration 282: roles cis_owner and catalog_owner must exist (Infra roles/, CIS 225)';
    END IF;
END $$;

-- ── 1. Columns added by hand on Dev ────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    r   record;
    cur text;
BEGIN
    FOR r IN SELECT * FROM (VALUES
            ('shared', 'pipeline_runs', 'llm_model', 'text'),
            ('shared', 'pipeline_runs', 'llm_provider', 'text'),
            ('shared', 'pipeline_runs', 'step_name', 'text'),
            ('shared', 'tenant_brand_rules', 'created_at', 'timestamp with time zone'),
            ('shared', 'tenant_brand_rules_deleted_aa404', 'created_at', 'timestamp with time zone'),
            ('silver_aa_internal', 'raw_sources', 'file_hash', 'character varying(64)')) v(s, t, c, typ) LOOP
        IF to_regclass(format('%I.%I', r.s, r.t)) IS NULL THEN
            CONTINUE;                       -- the 104 copy exists only where 104 ran
        END IF;
        SELECT format_type(a.atttypid, a.atttypmod) INTO cur
          FROM pg_attribute a
         WHERE a.attrelid = format('%I.%I', r.s, r.t)::regclass AND a.attname = r.c AND a.attnum > 0
           AND NOT a.attisdropped;
        IF cur IS NULL THEN
            EXECUTE format('ALTER TABLE %I.%I ADD COLUMN %I %s', r.s, r.t, r.c, r.typ);
            RAISE NOTICE 'migration 282: added %.%.% %', r.s, r.t, r.c, r.typ;
        ELSIF cur <> r.typ THEN
            RAISE EXCEPTION 'migration 282: %.%.% is %, Dev has %', r.s, r.t, r.c, cur, r.typ;
        END IF;
    END LOOP;
END $$;

-- ── 2. Nullability ─────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    r       record;
    has_nn  boolean;
    n       bigint;
BEGIN
    FOR r IN SELECT * FROM (VALUES
            ('shared', 'tenants', 'is_canary', false),
            ('shared', 'tenants', 'skip_hitl', false),
            ('shared', 'tenant_brand_rules', 'brand_name', true),
            ('shared', 'tenant_brand_rules_deleted_aa404', 'brand_name', true)) v(s, t, c, want) LOOP
        IF to_regclass(format('%I.%I', r.s, r.t)) IS NULL THEN
            CONTINUE;
        END IF;
        SELECT a.attnotnull INTO has_nn
          FROM pg_attribute a
         WHERE a.attrelid = format('%I.%I', r.s, r.t)::regclass AND a.attname = r.c AND a.attnum > 0
           AND NOT a.attisdropped;
        IF has_nn IS NULL THEN
            RAISE EXCEPTION 'migration 282: %.%.% does not exist', r.s, r.t, r.c;
        ELSIF has_nn = r.want THEN
            CONTINUE;
        ELSIF r.want THEN
            EXECUTE format('SELECT count(*) FROM %I.%I WHERE %I IS NULL', r.s, r.t, r.c) INTO n;
            IF n > 0 THEN
                RAISE EXCEPTION 'migration 282: %.%.% has % NULL row(s); Dev has it NOT NULL: fix the data first',
                                r.s, r.t, r.c, n;
            END IF;
            EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I SET NOT NULL', r.s, r.t, r.c);
            RAISE NOTICE 'migration 282: %.%.% SET NOT NULL', r.s, r.t, r.c;
        ELSE
            EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I DROP NOT NULL', r.s, r.t, r.c);
            RAISE NOTICE 'migration 282: %.%.% DROP NOT NULL', r.s, r.t, r.c;
        END IF;
    END LOOP;
END $$;

-- ── 3. Indexes as Dev has them ─────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    -- 044: Dev's name for the (tenant_id, brand_name, version) unique constraint
    IF to_regclass('shared.uq_tenant_brand_name_version') IS NULL THEN
        IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'shared.tenant_brand_rules'::regclass
                                                   AND conname = 'uq_brand_rules_tenant_brand_version') THEN
            ALTER TABLE shared.tenant_brand_rules
                RENAME CONSTRAINT uq_brand_rules_tenant_brand_version TO uq_tenant_brand_name_version;
            RAISE NOTICE 'migration 282: renamed uq_brand_rules_tenant_brand_version to uq_tenant_brand_name_version';
        ELSIF to_regclass('shared.uq_brand_rules_tenant_brand_version') IS NOT NULL THEN
            ALTER INDEX shared.uq_brand_rules_tenant_brand_version RENAME TO uq_tenant_brand_name_version;
            RAISE NOTICE 'migration 282: renamed index uq_brand_rules_tenant_brand_version';
        ELSE
            ALTER TABLE shared.tenant_brand_rules
                ADD CONSTRAINT uq_tenant_brand_name_version UNIQUE (tenant_id, brand_name, version);
            RAISE NOTICE 'migration 282: added uq_tenant_brand_name_version';
        END IF;
    END IF;
    -- 048: Dev's GIN index on generated_content.metadata (jsonb_path_ops)
    IF to_regclass('silver_aa_internal.idx_generated_content_metadata_gin') IS NULL THEN
        CREATE INDEX idx_generated_content_metadata_gin
            ON silver_aa_internal.generated_content USING gin (metadata jsonb_path_ops);
        RAISE NOTICE 'migration 282: created idx_generated_content_metadata_gin';
    END IF;
    IF to_regclass('silver_aa_internal.idx_generated_content_metadata_brand_rule') IS NOT NULL THEN
        DROP INDEX silver_aa_internal.idx_generated_content_metadata_brand_rule;
        RAISE NOTICE 'migration 282: dropped idx_generated_content_metadata_brand_rule (048 as written; not on Dev)';
    END IF;
    -- 123: the partial unique index on the hand-made file_hash column (step 1)
    IF to_regclass('silver_aa_internal.idx_raw_sources_file_hash') IS NULL THEN
        CREATE UNIQUE INDEX idx_raw_sources_file_hash
            ON silver_aa_internal.raw_sources USING btree (file_hash) WHERE (file_hash IS NOT NULL);
        RAISE NOTICE 'migration 282: created idx_raw_sources_file_hash';
    END IF;
END $$;

-- ── 4. Objects Dev dropped by hand ─────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    t      text;
    s      text;
    n      bigint;
    tables text[];
BEGIN
    -- children first (AA-603's order: content_metric_snapshot -> pieces -> packets -> acp_v2_slots -> acp_v2_runs)
    FOREACH t IN ARRAY ARRAY['acp_shared.unknown_ledger', 'acp_shared.content_metric_snapshot', 'acp_deliver.pieces',
                             'acp_deliver.packets', 'acp_shared.acp_v2_slots', 'acp_shared.acp_v2_runs'] LOOP
        IF to_regclass(t) IS NULL THEN
            CONTINUE;
        END IF;
        EXECUTE format('SELECT count(*) FROM %s', t) INTO n;
        IF n > 0 THEN
            RAISE EXCEPTION 'migration 282: % has % row(s); Dev dropped it empty (AA-598 / AA-603): decide first', t, n;
        END IF;
        EXECUTE format('DROP TABLE %s', t);
        RAISE NOTICE 'migration 282: dropped % (empty; dropped by hand on Dev)', t;
    END LOOP;
    FOREACH s IN ARRAY ARRAY['bronze', 'gold', 'ops', 'silver'] LOOP
        IF to_regnamespace(s) IS NULL THEN
            CONTINUE;
        END IF;
        IF NOT pg_has_role(current_user, (SELECT nspowner FROM pg_namespace WHERE nspname = s), 'USAGE') THEN
            RAISE NOTICE 'migration 282: schema % (001''s v1 layer, gone on Dev) belongs to %, not to %: left as is '
                         '(owner decision in AA-CIS-Infra db/schema_drift_decisions.json)',
                         s, (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = s), current_user;
            CONTINUE;
        END IF;
        SELECT array_agg(format('%I.%I', s, c.relname)) INTO tables
          FROM pg_class c WHERE c.relnamespace = to_regnamespace(s)::oid AND c.relkind IN ('r', 'p');
        FOREACH t IN ARRAY coalesce(tables, ARRAY[]::text[]) LOOP
            EXECUTE format('SELECT count(*) FROM %s', t) INTO n;
            IF n > 0 THEN
                RAISE EXCEPTION 'migration 282: % has % row(s); Dev has no schema %: decide first', t, n, s;
            END IF;
        END LOOP;
        EXECUTE format('DROP SCHEMA %I CASCADE', s);
        RAISE NOTICE 'migration 282: dropped schema % (001''s v1 layer, empty; gone on Dev)', s;
    END LOOP;
END $$;

-- ── 5. Column types: save the dependent views, drop, alter, recreate ───────────────────────────────────────────────
-- 5a. What differs, and the views (transitively) that depend on it. Writes aa282.state; issues the catalog GRANT only
--     when there is something to do.
DO $$
DECLARE
    pending jsonb;
    views   jsonb;
    trigs   jsonb;
    bad     text;
BEGIN
    WITH want(s, t, c, typ) AS (VALUES
            ('silver_aa_internal', 'raw_tours', 'country', 'text'),
            ('silver_aa_internal', 'raw_tours', 'duration', 'text'),
            ('silver_aa_internal', 'raw_tours', 'group_size', 'text'),
            ('silver_aa_internal', 'raw_tours', 'period', 'text'),
            ('silver_aa_internal', 'raw_tours', 'price_raw', 'text'),
            ('silver_aa_internal', 'raw_tours', 'sku', 'text'),
            ('silver_aa_internal', 'raw_tours', 'tour_id_external', 'text'),
            ('shared', 'membership_plans', 'overage_rate_usd_per_tour', 'numeric(8,4)'),
            ('shared', 'membership_plans', 'overage_rate_usd_per_1k_calls', 'numeric(8,4)'))
    SELECT jsonb_agg(jsonb_build_object('rel', a.attrelid::regclass::text, 'relid', a.attrelid, 'attnum', a.attnum,
                                        'col', a.attname, 'from', format_type(a.atttypid, a.atttypmod), 'to', w.typ)
                     ORDER BY a.attrelid, a.attnum)
      INTO pending
      FROM want w
      JOIN pg_attribute a ON a.attrelid = to_regclass(format('%I.%I', w.s, w.t)) AND a.attname = w.c
                         AND a.attnum > 0 AND NOT a.attisdropped
     WHERE format_type(a.atttypid, a.atttypmod) <> w.typ;

    IF pending IS NULL THEN
        PERFORM set_config('aa282.state', '{"pending": false}', true);
        RAISE NOTICE 'migration 282: column types already as on Dev, step 5 is a no-op';
        RETURN;
    END IF;

    -- What on a changed column the file cannot recreate faithfully.
    SELECT string_agg(DISTINCT pg_describe_object(d.classid, d.objid, d.objsubid), ', ') INTO bad
      FROM pg_depend d
      JOIN jsonb_to_recordset(pending) p(relid oid, attnum int) ON d.refobjid = p.relid AND d.refobjsubid = p.attnum
     WHERE d.classid NOT IN ('pg_class'::regclass, 'pg_constraint'::regclass, 'pg_attrdef'::regclass,
                             'pg_trigger'::regclass, 'pg_rewrite'::regclass, 'pg_type'::regclass)
        OR (d.classid = 'pg_class'::regclass
            AND (SELECT relkind FROM pg_class WHERE oid = d.objid) NOT IN ('i', 'I'))
        OR (d.classid = 'pg_rewrite'::regclass
            AND (SELECT rulename FROM pg_rewrite WHERE oid = d.objid) <> '_RETURN');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 282: cannot change the column types under %', bad;
    END IF;

    -- Views on the changed columns, then views on those views; depth = longest path, so a view comes after every
    -- view it reads.
    WITH RECURSIVE v(oid, depth) AS (
        SELECT DISTINCT r.ev_class, 1
          FROM pg_depend d
          JOIN pg_rewrite r ON r.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
          JOIN jsonb_to_recordset(pending) p(relid oid, attnum int)
            ON d.refobjid = p.relid AND d.refobjsubid = p.attnum
        UNION
        SELECT r.ev_class, v.depth + 1
          FROM v
          JOIN pg_depend d ON d.refobjid = v.oid AND d.classid = 'pg_rewrite'::regclass
          JOIN pg_rewrite r ON r.oid = d.objid AND r.ev_class <> v.oid
         WHERE v.depth < 50
    ), deepest AS (
        SELECT oid, max(depth) AS depth FROM v GROUP BY oid
    )
    SELECT jsonb_agg(jsonb_build_object(
               'oid', c.oid, 'name', format('%I.%I', n.nspname, c.relname), 'schema', n.nspname,
               'kind', c.relkind, 'owner', pg_get_userbyid(c.relowner), 'depth', x.depth,
               'options', coalesce(array_to_string(c.reloptions, ', '), ''),
               'def', pg_get_viewdef(c.oid),
               'cols', (SELECT jsonb_agg(a.attname ORDER BY a.attnum) FROM pg_attribute a
                         WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped),
               'acl', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                 'grantee', CASE WHEN e.grantee = 0 THEN 'PUBLIC'
                                                 ELSE quote_ident(pg_get_userbyid(e.grantee)) END,
                                 'priv', e.privilege_type, 'grantable', e.is_grantable)
                                 ORDER BY e.grantee, e.privilege_type), '[]'::jsonb)
                         FROM aclexplode(c.relacl) e WHERE e.grantee <> c.relowner),
               'has_acl', c.relacl IS NOT NULL,
               'comment', obj_description(c.oid, 'pg_class'),
               'colcomments', (SELECT coalesce(jsonb_agg(jsonb_build_object('col', a.attname,
                                                                           'comment', col_description(c.oid, a.attnum))),
                                               '[]'::jsonb)
                                 FROM pg_attribute a
                                WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                                  AND col_description(c.oid, a.attnum) IS NOT NULL),
               'colacl', EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attacl IS NOT NULL),
               'coldefault', EXISTS (SELECT 1 FROM pg_attrdef ad WHERE ad.adrelid = c.oid),
               'extra', EXISTS (SELECT 1 FROM pg_rewrite r WHERE r.ev_class = c.oid AND r.rulename <> '_RETURN')
                        OR EXISTS (SELECT 1 FROM pg_trigger tg WHERE tg.tgrelid = c.oid))
           ORDER BY x.depth, n.nspname, c.relname)
      INTO views
      FROM deepest x JOIN pg_class c ON c.oid = x.oid JOIN pg_namespace n ON n.oid = c.relnamespace;
    views := coalesce(views, '[]'::jsonb);

    SELECT string_agg(e->>'name', ', ') INTO bad FROM jsonb_array_elements(views) e
     WHERE e->>'kind' <> 'v' OR e->>'owner' NOT IN ('cis_owner', 'catalog_owner')
        OR (e->>'schema' = 'catalog') <> (e->>'owner' = 'catalog_owner')
        OR (e->>'colacl')::boolean OR (e->>'coldefault')::boolean OR (e->>'extra')::boolean;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 282: cannot recreate these dependent views faithfully (materialized, owned by '
                        'another role, catalog / owner mismatch, column grants or defaults, rules or triggers): %', bad;
    END IF;
    -- A cis_owner view must not read a catalog view of the set: cis_owner views are recreated first.
    SELECT string_agg(DISTINCT a->>'name', ', ') INTO bad
      FROM jsonb_array_elements(views) a
      JOIN pg_rewrite r ON r.ev_class = (a->>'oid')::oid
      JOIN pg_depend d ON d.objid = r.oid AND d.classid = 'pg_rewrite'::regclass
      JOIN jsonb_array_elements(views) b ON (b->>'oid')::oid = d.refobjid AND b->>'oid' <> a->>'oid'
     WHERE a->>'owner' = 'cis_owner' AND b->>'owner' = 'catalog_owner';
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 282: cis_owner view(s) % read a catalog view of the set', bad;
    END IF;

    SELECT coalesce(jsonb_agg(DISTINCT jsonb_build_object(
               'rel', tg.tgrelid::regclass::text, 'name', tg.tgname, 'def', pg_get_triggerdef(tg.oid),
               'enabled', tg.tgenabled, 'comment', obj_description(tg.oid, 'pg_trigger'))), '[]'::jsonb)
      INTO trigs
      FROM pg_depend d
      JOIN pg_trigger tg ON tg.oid = d.objid AND d.classid = 'pg_trigger'::regclass
      JOIN jsonb_to_recordset(pending) p(relid oid, attnum int) ON d.refobjid = p.relid AND d.refobjsubid = p.attnum;

    IF EXISTS (SELECT 1 FROM jsonb_array_elements(views) e WHERE e->>'owner' = 'catalog_owner') THEN
        GRANT CREATE ON SCHEMA catalog TO catalog_owner;
    END IF;
    PERFORM set_config('aa282.state', jsonb_build_object('pending', true, 'columns', pending, 'views', views,
                                                         'triggers', trigs)::text, true);
    RAISE NOTICE 'migration 282: % column(s) to change, % dependent view(s), % trigger(s)',
                 jsonb_array_length(pending), jsonb_array_length(views), jsonb_array_length(trigs);
END $$;

-- 5b. As catalog_owner: drop its views of the set, deepest first.
SET LOCAL ROLE catalog_owner;
DO $$
DECLARE
    st jsonb := current_setting('aa282.state')::jsonb;
    e  jsonb;
BEGIN
    IF NOT (st->>'pending')::boolean THEN
        RETURN;
    END IF;
    FOR e IN SELECT x FROM jsonb_array_elements(st->'views') x
              WHERE x->>'owner' = current_user ORDER BY (x->>'depth')::int DESC, x->>'name' LOOP
        EXECUTE format('DROP VIEW %s', e->>'name');
    END LOOP;
END $$;

-- 5c. As cis_owner: drop its views, drop the triggers on the changed columns, alter the columns, recreate the
--     triggers, put the two CHECKs in Dev's form.
SET LOCAL ROLE cis_owner;
DO $$
DECLARE
    st   jsonb := current_setting('aa282.state')::jsonb;
    e    jsonb;
    rel  text;
    alt  text;
    con  record;
    norm text;
    cmt  text;
BEGIN
    IF NOT (st->>'pending')::boolean THEN
        RETURN;
    END IF;
    FOR e IN SELECT x FROM jsonb_array_elements(st->'views') x
              WHERE x->>'owner' = current_user ORDER BY (x->>'depth')::int DESC, x->>'name' LOOP
        EXECUTE format('DROP VIEW %s', e->>'name');
    END LOOP;
    FOR e IN SELECT x FROM jsonb_array_elements(st->'triggers') x LOOP
        EXECUTE format('DROP TRIGGER %I ON %s', e->>'name', e->>'rel');
    END LOOP;
    FOR rel IN SELECT DISTINCT x->>'rel' FROM jsonb_array_elements(st->'columns') x LOOP
        SELECT string_agg(format('ALTER COLUMN %I TYPE %s', x->>'col', x->>'to'), ', ') INTO alt
          FROM jsonb_array_elements(st->'columns') x WHERE x->>'rel' = rel;
        EXECUTE format('ALTER TABLE %s %s', rel, alt);
        RAISE NOTICE 'migration 282: ALTER TABLE % %', rel, alt;
    END LOOP;
    FOR e IN SELECT x FROM jsonb_array_elements(st->'triggers') x LOOP
        EXECUTE e->>'def';
        IF e->>'enabled' <> 'O' THEN
            EXECUTE format('ALTER TABLE %s %s TRIGGER %I', e->>'rel',
                           CASE e->>'enabled' WHEN 'D' THEN 'DISABLE' WHEN 'A' THEN 'ENABLE ALWAYS'
                                              ELSE 'ENABLE REPLICA' END, e->>'name');
        END IF;
        IF e->>'comment' IS NOT NULL THEN
            EXECUTE format('COMMENT ON TRIGGER %I ON %s IS %L', e->>'name', e->>'rel', e->>'comment');
        END IF;
    END LOOP;
    -- The CHECKs in Dev's form (same values; the form follows from when they were created, see the header).
    FOR con IN SELECT * FROM (VALUES
            ('chk_raw_tours_country',
             'CHECK (((country IS NULL) OR (country = ANY (ARRAY[''Bhutan''::text, ''Cambodia''::text, '
             '''China''::text, ''India''::text, ''Indonesia''::text, ''Japan''::text, ''Kyrgyzstan''::text, '
             '''Laos''::text, ''Malaysia''::text, ''Mongolia''::text, ''Myanmar''::text, ''Nepal''::text, '
             '''Pakistan''::text, ''Philippines''::text, ''South Korea''::text, ''Sri Lanka''::text, '
             '''Taiwan''::text, ''Thailand''::text, ''Uzbekistan''::text, ''Vietnam''::text]))))'),
            ('raw_tours_review_status_check',
             'CHECK (((review_status)::text = ANY (ARRAY[(''pending_review''::character varying)::text, '
             '(''reviewed''::character varying)::text, (''approved''::character varying)::text, '
             '(''rejected''::character varying)::text])))')) v(name, dev) LOOP
        SELECT pg_get_constraintdef(c.oid) INTO norm FROM pg_constraint c
         WHERE c.conrelid = 'silver_aa_internal.raw_tours'::regclass AND c.conname = con.name;
        IF norm IS NULL OR norm = con.dev THEN
            CONTINUE;
        END IF;
        -- same values in another form: compare without casts, parentheses and blanks
        IF regexp_replace(norm, '::(character varying|text)(\[\])?|[() ]', '', 'g')
           <> regexp_replace(con.dev, '::(character varying|text)(\[\])?|[() ]', '', 'g') THEN
            RAISE EXCEPTION 'migration 282: % is %, not the values Dev has (%): decide first', con.name, norm, con.dev;
        END IF;
        SELECT obj_description(c.oid, 'pg_constraint') INTO cmt FROM pg_constraint c
         WHERE c.conrelid = 'silver_aa_internal.raw_tours'::regclass AND c.conname = con.name;
        EXECUTE format('ALTER TABLE silver_aa_internal.raw_tours DROP CONSTRAINT %I, ADD CONSTRAINT %I %s',
                       con.name, con.name, con.dev);
        IF cmt IS NOT NULL THEN
            EXECUTE format('COMMENT ON CONSTRAINT %I ON silver_aa_internal.raw_tours IS %L', con.name, cmt);
        END IF;
        RAISE NOTICE 'migration 282: % in Dev''s form', con.name;
    END LOOP;
END $$;

-- 5d. Recreate the views of the running role (cis_owner here, catalog_owner below) in dependency order, with their
--     options, privileges and comments. The same block runs twice.
DO $$
DECLARE
    st jsonb := current_setting('aa282.state')::jsonb;
    e  jsonb;
    g  jsonb;
    c  jsonb;
    r  record;
BEGIN
    IF NOT (st->>'pending')::boolean THEN
        RETURN;
    END IF;
    FOR e IN SELECT x FROM jsonb_array_elements(st->'views') x
              WHERE x->>'owner' = current_user ORDER BY (x->>'depth')::int, x->>'name' LOOP
        EXECUTE format('CREATE VIEW %s%s AS %s', e->>'name',
                       CASE WHEN e->>'options' <> '' THEN format(' WITH (%s)', e->>'options') ELSE '' END,
                       rtrim(e->>'def', '; '));
        -- privileges exactly as saved: take away what default privileges gave, then the saved grants
        FOR r IN SELECT DISTINCT CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(x.grantee)) END
                                 AS grantee
                   FROM pg_class k, aclexplode(k.relacl) x
                  WHERE k.oid = (e->>'name')::regclass AND x.grantee <> k.relowner LOOP
            EXECUTE format('REVOKE ALL ON %s FROM %s', e->>'name', r.grantee);
        END LOOP;
        FOR g IN SELECT x FROM jsonb_array_elements(e->'acl') x LOOP
            EXECUTE format('GRANT %s ON %s TO %s%s', g->>'priv', e->>'name', g->>'grantee',
                           CASE WHEN (g->>'grantable')::boolean THEN ' WITH GRANT OPTION' ELSE '' END);
        END LOOP;
        IF e->>'comment' IS NOT NULL THEN
            EXECUTE format('COMMENT ON VIEW %s IS %L', e->>'name', e->>'comment');
        END IF;
        FOR c IN SELECT x FROM jsonb_array_elements(e->'colcomments') x LOOP
            EXECUTE format('COMMENT ON COLUMN %s.%I IS %L', e->>'name', c->>'col', c->>'comment');
        END LOOP;
    END LOOP;
END $$;

SET LOCAL ROLE catalog_owner;
DO $$
DECLARE
    st jsonb := current_setting('aa282.state')::jsonb;
    e  jsonb;
    g  jsonb;
    c  jsonb;
    r  record;
BEGIN
    IF NOT (st->>'pending')::boolean THEN
        RETURN;
    END IF;
    FOR e IN SELECT x FROM jsonb_array_elements(st->'views') x
              WHERE x->>'owner' = current_user ORDER BY (x->>'depth')::int, x->>'name' LOOP
        EXECUTE format('CREATE VIEW %s%s AS %s', e->>'name',
                       CASE WHEN e->>'options' <> '' THEN format(' WITH (%s)', e->>'options') ELSE '' END,
                       rtrim(e->>'def', '; '));
        FOR r IN SELECT DISTINCT CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(x.grantee)) END
                                 AS grantee
                   FROM pg_class k, aclexplode(k.relacl) x
                  WHERE k.oid = (e->>'name')::regclass AND x.grantee <> k.relowner LOOP
            EXECUTE format('REVOKE ALL ON %s FROM %s', e->>'name', r.grantee);
        END LOOP;
        FOR g IN SELECT x FROM jsonb_array_elements(e->'acl') x LOOP
            EXECUTE format('GRANT %s ON %s TO %s%s', g->>'priv', e->>'name', g->>'grantee',
                           CASE WHEN (g->>'grantable')::boolean THEN ' WITH GRANT OPTION' ELSE '' END);
        END LOOP;
        IF e->>'comment' IS NOT NULL THEN
            EXECUTE format('COMMENT ON VIEW %s IS %L', e->>'name', e->>'comment');
        END IF;
        FOR c IN SELECT x FROM jsonb_array_elements(e->'colcomments') x LOOP
            EXECUTE format('COMMENT ON COLUMN %s.%I IS %L', e->>'name', c->>'col', c->>'comment');
        END LOOP;
    END LOOP;
END $$;

-- 5e. Back to cis_owner; catalog_owner loses CREATE again (only granted in 5a when there were catalog views to move).
SET LOCAL ROLE cis_owner;
DO $$
BEGIN
    IF has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;
    END IF;
END $$;

-- ── 6. Post-check ──────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    st  jsonb := current_setting('aa282.state')::jsonb;
    bad text;
    e   jsonb;
BEGIN
    WITH want(rel, c, typ, nn) AS (VALUES
            ('shared.pipeline_runs', 'llm_model', 'text', NULL::boolean),
            ('shared.pipeline_runs', 'llm_provider', 'text', NULL),
            ('shared.pipeline_runs', 'step_name', 'text', NULL),
            ('shared.tenant_brand_rules', 'created_at', 'timestamp with time zone', NULL),
            ('shared.tenant_brand_rules', 'brand_name', NULL, true),
            ('shared.tenants', 'is_canary', NULL, false),
            ('shared.tenants', 'skip_hitl', NULL, false),
            ('silver_aa_internal.raw_sources', 'file_hash', 'character varying(64)', NULL),
            ('silver_aa_internal.raw_tours', 'country', 'text', NULL),
            ('silver_aa_internal.raw_tours', 'duration', 'text', NULL),
            ('silver_aa_internal.raw_tours', 'group_size', 'text', NULL),
            ('silver_aa_internal.raw_tours', 'period', 'text', NULL),
            ('silver_aa_internal.raw_tours', 'price_raw', 'text', NULL),
            ('silver_aa_internal.raw_tours', 'sku', 'text', NULL),
            ('silver_aa_internal.raw_tours', 'tour_id_external', 'text', NULL),
            ('shared.membership_plans', 'overage_rate_usd_per_tour', 'numeric(8,4)', NULL),
            ('shared.membership_plans', 'overage_rate_usd_per_1k_calls', 'numeric(8,4)', NULL))
    SELECT string_agg(format('%s.%s', w.rel, w.c), ', ') INTO bad
      FROM want w
      LEFT JOIN pg_attribute a ON a.attrelid = to_regclass(w.rel) AND a.attname = w.c AND a.attnum > 0
                              AND NOT a.attisdropped
     WHERE (a.attname IS NULL AND (to_regclass(w.rel) IS NOT NULL OR w.rel <> 'shared.membership_plans'))
        OR (w.typ IS NOT NULL AND format_type(a.atttypid, a.atttypmod) <> w.typ)
        OR (w.nn IS NOT NULL AND a.attnotnull <> w.nn);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 282: post-check: not as on Dev: %', bad;
    END IF;
    IF to_regclass('shared.uq_tenant_brand_name_version') IS NULL
       OR to_regclass('silver_aa_internal.idx_generated_content_metadata_gin') IS NULL
       OR to_regclass('silver_aa_internal.idx_generated_content_metadata_brand_rule') IS NOT NULL
       OR to_regclass('silver_aa_internal.idx_raw_sources_file_hash') IS NULL THEN
        RAISE EXCEPTION 'migration 282: post-check: the indexes are not as on Dev';
    END IF;
    IF to_regclass('acp_shared.unknown_ledger') IS NOT NULL OR to_regclass('acp_deliver.pieces') IS NOT NULL
       OR to_regclass('acp_deliver.packets') IS NOT NULL OR to_regclass('acp_shared.acp_v2_slots') IS NOT NULL
       OR to_regclass('acp_shared.acp_v2_runs') IS NOT NULL
       OR to_regclass('acp_shared.content_metric_snapshot') IS NOT NULL THEN
        RAISE EXCEPTION 'migration 282: post-check: a table Dev dropped still exists';
    END IF;
    IF (st->>'pending')::boolean THEN
        FOR e IN SELECT x FROM jsonb_array_elements(st->'views') x LOOP
            IF to_regclass(e->>'name') IS NULL THEN
                RAISE EXCEPTION 'migration 282: post-check: view % was not recreated', e->>'name';
            END IF;
            IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = (e->>'name')::regclass) <> e->>'owner'
               OR (SELECT coalesce(array_to_string(reloptions, ', '), '') FROM pg_class
                    WHERE oid = (e->>'name')::regclass) <> e->>'options'
               OR (SELECT jsonb_agg(a.attname ORDER BY a.attnum) FROM pg_attribute a
                    WHERE a.attrelid = (e->>'name')::regclass AND a.attnum > 0 AND NOT a.attisdropped) <> e->'cols'
               OR (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                 'grantee', CASE WHEN x.grantee = 0 THEN 'PUBLIC'
                                                 ELSE quote_ident(pg_get_userbyid(x.grantee)) END,
                                 'priv', x.privilege_type, 'grantable', x.is_grantable)
                                 ORDER BY x.grantee, x.privilege_type), '[]'::jsonb)
                     FROM pg_class k, aclexplode(k.relacl) x
                    WHERE k.oid = (e->>'name')::regclass AND x.grantee <> k.relowner) <> e->'acl' THEN
                RAISE EXCEPTION 'migration 282: post-check: view % differs from before (owner, options, columns or '
                                'privileges)', e->>'name';
            END IF;
        END LOOP;
    END IF;
    IF has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 282: post-check: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('282', now(),
        'AA-853 D2: codify the Dev-only schema state (hand columns, nullability, index names, hand drops, raw_tours '
        'text and plans numeric(8,4) with their views); a no-op on Dev')
ON CONFLICT (version) DO NOTHING;

COMMIT;
