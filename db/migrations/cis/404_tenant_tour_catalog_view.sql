-- Migration 404: AA-1094 (S278 system audit M20, root ADR 0019 d10) — the contract view catalog.v_tenant_tour_v1:
-- the AA tours an agency tenant has made its own, each with the tenant's own rewritten text, for TripPlanner's
-- /{slug} pages (contract catalog.tenant_tour.v1, root docs/contracts/catalog.tenant_tour.v1.json).
--
-- Why. ADR 0019 d10: "tours from catalog.v_tenant_tour_v1". Until now TripPlanner showed every tenant the whole AA
-- master catalogue with AA's text (the 379 contract: a bound tenant reads AA master rows only, "the tenant's own text
-- comes with catalog.v_tenant_tour_v1"), so the Content base product (the tenant's T2 rewrite) never reached its
-- planner. TripPlanner reads CIS only through catalog contract views (role tripplanner has USAGE on schema catalog,
-- never on gold_aa_internal; CIS 270 revoked the rest).
--
-- What:
--   1. Column-level SELECT for catalog_owner on gold_aa_internal.tenant_tour_versions (id, tenant_id,
--      published_tour_id, version_number, rewritten_content, status, edit_source, created_at): the content of a
--      version and nothing of its gates (no quality_score, qa_*, judge_breakdown, generation_meta, fs_id, job_id,
--      edited_by_user: the tenant projection rule of api/routers/_tenant_projection.py; the policy reads qa_status
--      itself, which needs no grant).
--   2. The policy catalog_owner_tenant_text_read (PERMISSIVE SELECT TO catalog_owner) on that table (RLS is on and
--      catalog_owner is not its owner, so without a policy the view would see no row): a PUBLISHABLE version, one of
--        a. status approved: the tenant approved it (whatever wrote it);
--        b. edit_source tenant_edit with status pending: the agency's own edit (the portal's only write; the edit
--           route inserts it as pending, api/routers/v1_tours.py _VERSION_EDIT_INSERT_SQL);
--        c. status ai_generated AND qa_status passed: a T2 rewrite that met the pass line with no T3 hard code
--           (t2_rewrite_job._t2_status) and whose T3 QA gate really cleared.
--      Never shown: pending AI rewrites (still writing), failed, rejected, needs_review AI text (below the pass line,
--      a T3 hard code that survived, a held fallback writer or an elephant-riding policy hold:
--      t2_orchestrator.linear_status, t2_rewrite_job policy_hold) and ai_generated text whose QA gate did not
--      clear (qa_status pending / failed / escalated). The tenant still receives all of these in its portal; this
--      rule is only what goes PUBLIC under the agency's brand (as AA-side held content needs the owner's audited
--      publish). qa_status is read only inside the policy: catalog_owner gets no grant on it and the view exposes
--      no gate column.
--   3. catalog.v_tenant_tour_v1 (security_barrier, owner catalog_owner): one row per (tenant, AA catalogue key) for a
--      tenant in service (trial, active, past_due; kind internal excluded) that holds a TripPlanner subscription, for
--      every LIVE AA tour (catalog.v_tour) of which the tenant has a publishable version. The served version of a key:
--      a version the tenant owns (a or b) before an AI one (c), so newer unreviewed AI text never replaces what the
--      agency approved or wrote; then the latest (created_at, then version_number). A version written for an older
--      source version of the same key counts, so a re-upload of the AA source keeps the tenant's text. Columns: the
--      tenant id, the AA catalogue key (source_system, source_id) and the live tour id and slug, the tenant's text
--      (title, subtitle, summary, highlights, itinerary_text, seo_title, seo_meta; a blank field is NULL; a blank
--      title falls back to AA's; an itinerary stored as the writer's JSON day list becomes "Day N — Title" blocks as
--      CIS day_parse.written_itinerary_text renders it), the AA facts of the live tour (country, duration_raw,
--      duration_days, best_time_to_go, cover_photo_path, photo_count), the version (version_id, edit_source,
--      text_updated_at = the version's created_at, human_edited) and content_hash (md5 of the served text and
--      facts). No price, no score, no personal data. SELECT to tripplanner only. Contract v1: columns are only
--      appended; a change of meaning is a _v2 view.
--   4. Register 404.
--
-- What a tenant row means (decided here, recorded in the contract and the ADR 0019 d10 amendment): "on the agency's
-- site" = the tenant has a publishable version of the tour (2a-c); a tour still being written, or whose versions are
-- all unpublishable, is not listed (no AA-text fallback under the agency's brand). Liveness is AA's (ADR 0015): a
-- retired or paused AA tour leaves the view at once, whatever the tenant's version says. Whether needs_review / QA-
-- escalated AI text should also go public without an agency step is a tech-lead decision (S278 decision list); this
-- file takes the conservative side, and widening it is a later forward migration.
--
-- Behaviour on apply. Nothing reads the view until the AA-1094 TripPlanner code is deployed; that code detects the
-- view (42P01 / 42501 before this file: a tenant path lists no tour, the demo path keeps the AA catalogue). The new
-- policy only adds rows for catalog_owner; no other role's reads change.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no '-- migrate:' directive): a column GRANT and a new policy on an
-- existing table, a view in the catalog schema under the catalog.* recipe (role switch, GRANT / REVOKE CREATE).
-- MIG-4: migration-only PR; applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a).
-- DM-7.1: a view, no new table. The consumer grant goes into AA-CIS-Infra owners.yaml and the isolation probe
-- (expected from 404).
--
-- Guards (RAISE rolls the whole file back): before — 359 registered (catalog.v_tour with text_updated_at), 379
-- registered (the TripPlanner tenant scope: shared.tenant_subscription column grants to catalog_owner), schema
-- catalog owned by cis_owner, tenant_tour_versions exists. After, as catalog_owner — the view answers. After, as
-- cis_owner — the view's exact columns and types, owner catalog_owner, security_barrier, tripplanner can read it,
-- booking / aa_app_user / cis_app / crm_app cannot, tripplanner has no privilege on tenant_tour_versions,
-- catalog_owner reads exactly the eight granted columns of tenant_tour_versions and writes nothing there, and has no
-- CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 357 / 377 / 379 / 401): the grant and the policy as cis_owner, then GRANT
-- CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner;
-- REVOKE CREATE. DB Migrate runs the file as cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no
-- role DDL, no dynamic SQL. The conftest replay skips this file (catalog recipe, 245's owners);
-- tests/integration/test_aa1094_migration_404.py applies it the DB Migrate way inside a rolled-back transaction.
--
-- Number. 403 (tour_price_reference_view_v2) is the highest on main (12/11, after the S278 review pass renumbered this
-- file from 403). If the owner main max + 1 differs at merge, renumber (git grep '404_' and '404' in this file, the
-- test, conftest, the AA-TripPlanner-Web test stand-in, the AA-CIS-Infra probe and owners.yaml, the root contract).
--
-- Locks. One column GRANT, one CREATE POLICY (a short ACCESS EXCLUSIVE lock on tenant_tour_versions, ~130 rows on
-- Dev) and one CREATE VIEW. lock_timeout 5s, statement_timeout 1min. Idempotent (re-runnable grants, the policy
-- dropped and created again, CREATE OR REPLACE with the same column list), one transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after the TripPlanner code is reverted): DROP VIEW
-- catalog.v_tenant_tour_v1; DROP POLICY catalog_owner_tenant_text_read ON gold_aa_internal.tenant_tour_versions;
-- REVOKE SELECT (the eight columns) ON gold_aa_internal.tenant_tour_versions FROM catalog_owner.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '359') THEN
        RAISE EXCEPTION 'migration 404: apply 359 (catalog.v_tour text_updated_at) first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '379') THEN
        RAISE EXCEPTION 'migration 404: apply 379 (the TripPlanner tenant view and its grants) first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 404: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    IF to_regclass('gold_aa_internal.tenant_tour_versions') IS NULL THEN
        RAISE EXCEPTION 'migration 404: gold_aa_internal.tenant_tour_versions does not exist';
    END IF;
    IF (SELECT count(*) FROM pg_attribute
         WHERE attrelid = 'gold_aa_internal.tenant_tour_versions'::regclass AND NOT attisdropped
           AND attname IN ('status', 'edit_source', 'qa_status')) <> 3 THEN
        RAISE EXCEPTION 'migration 404: tenant_tour_versions lacks status / edit_source / qa_status (107)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read of a tenant version ───────────────────────────────────────────────────────────
GRANT SELECT (id, tenant_id, published_tour_id, version_number, rewritten_content, status, edit_source, created_at)
    ON gold_aa_internal.tenant_tour_versions TO catalog_owner;
-- 379 granted these on shared.tenants / shared.tenant_subscription; granted again (idempotent) so this file states
-- every column its view reads.
GRANT SELECT (tenant_id, account_status, kind) ON shared.tenants TO catalog_owner;
GRANT SELECT (tenant_id, product) ON shared.tenant_subscription TO catalog_owner;

-- ── 2. Which versions catalog_owner sees: publishable on the agency's site ───────────────────────────────────────
DROP POLICY IF EXISTS catalog_owner_tenant_text_read ON gold_aa_internal.tenant_tour_versions;
CREATE POLICY catalog_owner_tenant_text_read ON gold_aa_internal.tenant_tour_versions
    AS PERMISSIVE FOR SELECT TO catalog_owner
    USING (status = 'approved'
           OR (status = 'pending' AND edit_source = 'tenant_edit')
           OR (status = 'ai_generated' AND qa_status = 'passed'));

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 3. The view: per tenant and live AA tour, the tenant's served text ───────────────────────────────────────────
-- The WHERE repeats the policy's status / edit_source arms (qa_status, read by the policy alone, is not granted).
CREATE OR REPLACE VIEW catalog.v_tenant_tour_v1 WITH (security_barrier = true) AS
WITH tenant_text AS (
    SELECT DISTINCT ON (v.tenant_id, rt.source_key)
           v.tenant_id,
           rt.source_key AS source_id,
           v.id AS version_id,
           v.rewritten_content AS rc,
           v.edit_source,
           v.created_at
      FROM gold_aa_internal.tenant_tour_versions v
      JOIN gold_aa_internal.published_tours pt ON pt.id = v.published_tour_id
      JOIN silver_aa_internal.raw_tours rt ON rt.tour_id = pt.tour_id
      JOIN shared.tenants t ON t.tenant_id = v.tenant_id
     WHERE (v.status IN ('approved', 'ai_generated')
            OR (v.status = 'pending' AND v.edit_source = 'tenant_edit'))
       AND jsonb_typeof(v.rewritten_content) = 'object'
       AND t.kind <> 'internal'
       AND t.account_status IN ('trial', 'active', 'past_due')
       AND EXISTS (SELECT 1 FROM shared.tenant_subscription s
                    WHERE s.tenant_id = v.tenant_id AND s.product = 'tripplanner')
     ORDER BY v.tenant_id, rt.source_key,
              (v.status = 'approved' OR v.edit_source = 'tenant_edit') DESC,   -- the agency's own text first
              v.created_at DESC, v.version_number DESC, v.id
),
served AS (
    SELECT x.tenant_id,
           l.source_system,
           l.source_id,
           l.tour_id,
           l.slug,
           COALESCE(NULLIF(btrim(x.rc ->> 'name'), ''), l.title::text) AS title,
           NULLIF(btrim(x.rc ->> 'subtitle'), '') AS subtitle,
           NULLIF(btrim(x.rc ->> 'summary'), '') AS summary,
           CASE WHEN jsonb_typeof(x.rc -> 'highlights') = 'array' THEN x.rc -> 'highlights'
                ELSE '[]'::jsonb END AS highlights,
           -- a string as stored; the writer's JSON day list as CIS day_parse.written_itinerary_text renders it
           -- ("Day N — Title\nBody" blocks, body falling back to description; a list of strings joined by lines)
           NULLIF(btrim(CASE jsonb_typeof(x.rc -> 'itineraries')
               WHEN 'string' THEN x.rc ->> 'itineraries'
               WHEN 'array' THEN CASE
                   WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(x.rc -> 'itineraries') d(e)
                                 WHERE jsonb_typeof(d.e) = 'object' AND d.e ? 'day')
                   THEN (SELECT string_agg('Day ' || COALESCE(d.e ->> 'day', '') || ' — '
                                           || COALESCE(d.e ->> 'title', '') || E'\n'
                                           || COALESCE(NULLIF(d.e ->> 'body', ''), NULLIF(d.e ->> 'description', ''),
                                                       ''),
                                           E'\n\n' ORDER BY d.ord)
                           FROM jsonb_array_elements(x.rc -> 'itineraries') WITH ORDINALITY d(e, ord)
                          WHERE jsonb_typeof(d.e) = 'object')
                   ELSE (SELECT string_agg(d.e #>> '{}', E'\n' ORDER BY d.ord)
                           FROM jsonb_array_elements(x.rc -> 'itineraries') WITH ORDINALITY d(e, ord)
                          WHERE jsonb_typeof(d.e) = 'string')
               END
           END), '') AS itinerary_text,
           NULLIF(btrim(x.rc ->> 'seo_title'), '') AS seo_title,
           NULLIF(btrim(x.rc ->> 'seo_meta'), '') AS seo_meta,
           l.country::text AS country,
           l.duration_raw::text AS duration_raw,
           l.duration_days,
           l.best_time_to_go::text AS best_time_to_go,
           l.cover_photo_path,
           l.photo_count,
           x.version_id,
           x.edit_source,
           x.created_at AS text_updated_at,
           x.edit_source = 'tenant_edit' AS human_edited
      FROM tenant_text x
      JOIN catalog.v_tour l ON l.source_id = x.source_id
)
SELECT s.tenant_id,
       s.source_system,
       s.source_id,
       s.tour_id,
       s.slug,
       s.title,
       s.subtitle,
       s.summary,
       s.highlights,
       s.itinerary_text,
       s.seo_title,
       s.seo_meta,
       s.country,
       s.duration_raw,
       s.duration_days,
       s.best_time_to_go,
       s.cover_photo_path,
       s.photo_count,
       s.version_id,
       s.edit_source,
       s.text_updated_at,
       s.human_edited,
       md5(jsonb_build_array(
           s.title, s.subtitle, s.summary, s.highlights, s.itinerary_text, s.seo_title, s.seo_meta, s.country,
           s.duration_raw, s.best_time_to_go, s.cover_photo_path, s.version_id
       )::text) AS content_hash
  FROM served s;

COMMENT ON VIEW catalog.v_tenant_tour_v1 IS
    'AA-1094 (404, contract catalog.tenant_tour.v1, root ADR 0019 d10): per agency tenant in service with a '
    'TripPlanner subscription, the live AA tours with a version publishable on its site (approved by the tenant, the '
    'tenant''s own edit, or ai_generated text whose T3 QA passed; never needs_review, QA-escalated, pending AI, failed '
    'or rejected text) with the served text (the tenant''s own version before AI text, then the latest; title falls '
    'back to AA''s), the AA facts of the live tour and the version id. AA liveness wins (catalog.v_tour). No price, no '
    'score, no personal data. TripPlanner only. Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_tenant_tour_v1 TO tripplanner;

-- ── Closing check as catalog_owner: the view answers ─────────────────────────────────────────────────────────────
DO $$
BEGIN
    RAISE NOTICE 'migration 404: as catalog_owner, % tenant tour row(s) for % tenant(s)',
        (SELECT count(*) FROM catalog.v_tenant_tour_v1),
        (SELECT count(DISTINCT tenant_id) FROM catalog.v_tenant_tour_v1);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner ───────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_tenant_tour_v1';
    ttv constant text := 'gold_aa_internal.tenant_tour_versions';
    r text;
    cols text;
    granted text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 404: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 404: % is not security_barrier', v;
    END IF;
    IF NOT pg_catalog.has_table_privilege('tripplanner', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 404: tripplanner cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 404: % can read % (tripplanner only)', r, v;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'tenant_id uuid, source_system text, source_id text, tour_id uuid, slug text, '
                             'title text, subtitle text, summary text, highlights jsonb, itinerary_text text, '
                             'seo_title text, seo_meta text, country text, duration_raw text, duration_days integer, '
                             'best_time_to_go text, cover_photo_path text, photo_count bigint, version_id uuid, '
                             'edit_source text, text_updated_at timestamp with time zone, human_edited boolean, '
                             'content_hash text' THEN
        RAISE EXCEPTION 'migration 404: % columns are %', v, cols;
    END IF;
    IF pg_catalog.has_any_column_privilege('tripplanner', ttv, 'SELECT')
       OR pg_catalog.has_any_column_privilege('tripplanner', ttv, 'INSERT')
       OR pg_catalog.has_any_column_privilege('tripplanner', ttv, 'UPDATE') THEN
        RAISE EXCEPTION 'migration 404: tripplanner can read or change % directly', ttv;
    END IF;
    IF pg_catalog.has_table_privilege('catalog_owner', ttv, 'SELECT')
       OR pg_catalog.has_any_column_privilege('catalog_owner', ttv, 'INSERT')
       OR pg_catalog.has_any_column_privilege('catalog_owner', ttv, 'UPDATE')
       OR pg_catalog.has_table_privilege('catalog_owner', ttv, 'DELETE') THEN
        RAISE EXCEPTION 'migration 404: catalog_owner has more than column SELECT on %', ttv;
    END IF;
    SELECT string_agg(a.attname, ',' ORDER BY a.attname) INTO granted
      FROM pg_attribute a
     WHERE a.attrelid = ttv::regclass AND a.attnum > 0 AND NOT a.attisdropped
       AND pg_catalog.has_column_privilege('catalog_owner', a.attrelid, a.attnum, 'SELECT');
    IF granted IS DISTINCT FROM
       'created_at,edit_source,id,published_tour_id,rewritten_content,status,tenant_id,version_number' THEN
        RAISE EXCEPTION 'migration 404: catalog_owner reads % columns %', ttv, granted;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies
                    WHERE schemaname = 'gold_aa_internal' AND tablename = 'tenant_tour_versions'
                      AND policyname = 'catalog_owner_tenant_text_read' AND cmd = 'SELECT'
                      AND roles = ARRAY['catalog_owner']::name[]) THEN
        RAISE EXCEPTION 'migration 404: the policy catalog_owner_tenant_text_read is not SELECT TO catalog_owner';
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 404: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('404', now(), 'AA-1094: catalog.v_tenant_tour_v1 (a TripPlanner tenant''s live AA tours with its own '
                      'publishable text; catalog.tenant_tour.v1), catalog_owner reads publishable tenant versions')
ON CONFLICT (version) DO NOTHING;

COMMIT;
