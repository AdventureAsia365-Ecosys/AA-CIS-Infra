-- Migration 358: AA-1040 (EU AI Act Art. 50(2), root ADR 0019 d19) — the machine-readable AI mark of the supply
-- content Booking shows: catalog.v_supply_content appends ai_generated, ai_generated_at and ai_human_edited.
--
-- Why. CIS drafts the customer text of every Booking hotel and service with the writer stage supply_content_writer
-- (278 / AA-835); staff review and publish it in /admin/supply-content, and Booking shows the published text read-only
-- on its hotel and service pages and in proposals (catalog.v_supply_content, 278). The AI Use Register (root
-- docs/architecture/ai-use-register.md, "Coverage limits") lists it as the one Booking surface without a machine
-- mark. The facts already exist on the CIS side, so no column is added: shared.supply_content_version.origin (llm =
-- the writer's draft, human = a staff edit), based_on_version_id (the version a staff edit started from; NULL when
-- the text was written from scratch) and created_at. Booking reads the view only (role booking has no privilege on
-- shared), so the view carries the mark.
--
-- What:
--   1. catalog.v_supply_content (security_barrier, owner catalog_owner, SELECT to booking only, unchanged) appends,
--      after 278's eleven columns and in this order:
--        ai_generated     boolean      true when the published text is AI-written: the published version is an llm
--                                      draft, or a human edit whose based_on_version_id chain reaches an llm draft
--                                      (a staff edit of AI text stays AI-assisted); false for a text a person wrote
--                                      from scratch (no llm version in its chain);
--        ai_generated_at  timestamptz  created_at of that nearest llm draft (when the AI text was generated), NULL
--                                      when ai_generated is false;
--        ai_human_edited  boolean      true when the published version is a human edit of AI text, false when it is
--                                      the llm draft itself, NULL when ai_generated is false.
--      All three are NULL while the row is not published (the same rule as the text columns: draft, in_review, stale
--      and unpublished rows serve no text, ADR 0004a). The chain is walked by a bounded recursive CTE (32 steps; a
--      version cannot be based on a later one, so a cycle cannot form, the bound is a guard only), per published row
--      inside a LATERAL, so Booking's single-entity read stays an index lookup.
--      The writer model is not exposed: it is on the CIS ledger (llm_job_id -> shared.llm_call_log.job_id), which
--      catalog_owner may not read (column SELECT only, CIS 311 era), and the tour mark leaves model null too.
--      Columns are append-only: Booking's reader (AA-Booking app/supply/content.py) feature-detects 278's nine
--      columns and, separately, these three (its mark turns on by itself once this file is applied).
--   2. Register 358.
--
-- Behaviour. None for the existing reader: CREATE OR REPLACE VIEW with 278's columns first, unchanged; the ACL is
-- kept (re-stated below). Booking's AA-1040 code shows the mark once it detects the columns.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no expand header): a view definition change and the catalog.* recipe
-- (role switch, GRANT / REVOKE CREATE). MIG-4: migration-only PR; on Dev, Infra Migration Apply applies it when every
-- job table is idle (root ADR 0017a). DM-7.1: a view, no new table.
--
-- Guards (RAISE rolls the whole file back): before — 278 registered, schema catalog owned by cis_owner, the view
-- catalog_owner's with 278's eleven columns (or this file's fourteen, a re-run). After, as catalog_owner — the exact
-- column list and types; no mark on a row that is not published; ai_generated_at and ai_human_edited set exactly
-- when ai_generated is true. After, as cis_owner — owner catalog_owner, security_barrier, grants exactly
-- booking:SELECT, no column grant, catalog_owner has no CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 278 / 323 / 341 / 357): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET
-- LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as
-- cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL, no dynamic SQL. The conftest
-- replay skips this file (catalog recipe, 245's owners); tests/integration/test_aa1040_migration_358.py applies 278 +
-- 358 the DB Migrate way and rolls back.
--
-- Number. 357 is the highest on main (03/11), so this file is main max + 1 and 359 (catalog.v_tour text_updated_at)
-- follows it in the same migration-only PR. If another CIS file lands first, renumber both to the owner main max + 1
-- and + 2 (git grep '358_' / '359_' and the bare numbers in each file, its test and conftest).
--
-- Locks. One CREATE OR REPLACE VIEW (AccessExclusiveLock on the view only, catalog-only), lock_timeout 5s,
-- statement_timeout 1min. Idempotent (same column list on a re-run, re-runnable grants, ON CONFLICT DO NOTHING), one
-- transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after the Booking mark code is reverted or left to detect
-- the columns' absence): a view cannot drop columns with CREATE OR REPLACE, so DROP VIEW catalog.v_supply_content and
-- re-create 278's definition with its COMMENT and GRANT SELECT TO booking.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
DECLARE
    cols text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '278') THEN
        RAISE EXCEPTION 'migration 358: apply 278 (supply content) first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') IS DISTINCT FROM 'cis_owner' THEN
        RAISE EXCEPTION 'migration 358: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    IF to_regclass('catalog.v_supply_content') IS NULL
       OR (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = to_regclass('catalog.v_supply_content'))
          <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 358: catalog.v_supply_content is missing or not catalog_owner''s';
    END IF;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_supply_content'::regclass AND a.attnum > 0
       AND NOT a.attisdropped;
    IF cols NOT IN ('source_system,source_id,entity_type,content_status,content_version,description,highlights,'
                    'good_to_know,photo_urls,edit_url,published_at',
                    'source_system,source_id,entity_type,content_status,content_version,description,highlights,'
                    'good_to_know,photo_urls,edit_url,published_at,ai_generated,ai_generated_at,ai_human_edited') THEN
        RAISE EXCEPTION 'migration 358: catalog.v_supply_content has unexpected columns: %', cols;
    END IF;
    IF NOT has_table_privilege('catalog_owner', 'shared.supply_content_version', 'SELECT') THEN
        RAISE EXCEPTION 'migration 358: catalog_owner cannot read shared.supply_content_version (278)';
    END IF;
END $$;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 1. The view: 278's columns unchanged, then the mark ──────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_supply_content WITH (security_barrier = true) AS
SELECT e.source_system,
       e.source_id,
       e.entity_type,
       e.content_status,
       COALESCE(p.content_version, n.content_version) AS content_version,
       p.description,
       p.highlights,
       p.good_to_know,
       CASE WHEN p.id IS NOT NULL THEN COALESCE(ph.urls, ARRAY[]::text[]) END AS photo_urls,
       '/admin/supply-content/' || e.id::text AS edit_url,
       p.reviewed_at AS published_at,
       CASE WHEN p.id IS NOT NULL THEN ai.llm_created_at IS NOT NULL END AS ai_generated,
       ai.llm_created_at AS ai_generated_at,
       CASE WHEN ai.llm_created_at IS NOT NULL THEN p.origin = 'human' END AS ai_human_edited
  FROM shared.supply_entity e
  LEFT JOIN shared.supply_content_version p
         ON e.content_status = 'published'
        AND e.active
        AND p.entity_id = e.id
        AND p.id = e.published_version_id
        AND p.status = 'approved'
  LEFT JOIN LATERAL (
        SELECT max(v.content_version) AS content_version
          FROM shared.supply_content_version v
         WHERE v.entity_id = e.id
       ) n ON true
  LEFT JOIN LATERAL (
        SELECT array_agg(m.url_1600 ORDER BY x.ord) AS urls
          FROM jsonb_array_elements(p.photos) WITH ORDINALITY AS x(photo, ord)
          JOIN shared.supply_media m ON m.booking_media_id::text = x.photo ->> 'media_id'
         WHERE m.entity_id = e.id
           AND m.usage_rights
           AND m.active
           AND m.url_1600 IS NOT NULL
       ) ph ON true
  LEFT JOIN LATERAL (
        -- the nearest llm draft in the published version's based_on chain (itself included)
        WITH RECURSIVE chain (id, origin, based_on_version_id, created_at, depth) AS (
            SELECT p.id, p.origin, p.based_on_version_id, p.created_at, 0
             WHERE p.id IS NOT NULL
            UNION ALL
            SELECT b.id, b.origin, b.based_on_version_id, b.created_at, c.depth + 1
              FROM chain c
              JOIN shared.supply_content_version b ON b.id = c.based_on_version_id AND b.entity_id = e.id
             WHERE c.origin <> 'llm' AND c.depth < 32
        )
        SELECT c.created_at AS llm_created_at
          FROM chain c
         WHERE c.origin = 'llm'
         ORDER BY c.depth
         LIMIT 1
       ) ai ON true;

COMMENT ON VIEW catalog.v_supply_content IS
    'AA-835 (CIS 278, root ADR 0004a decision 5): the AA-written customer content of each Booking hotel / service CIS '
    'knows, for Booking (role booking only). Key (source_system, source_id = the Booking id). description, '
    'highlights, good_to_know and photo_urls are non-NULL only while content_status = published (approved version, '
    'active entity); draft, in_review, stale and unpublished rows carry NULL text. photo_urls = CDN URLs of the '
    'published photos whose Booking media has usage_rights. edit_url = the CIS admin path of the entity (prefix the '
    'CIS admin origin). AA-1040 (CIS 358, EU AI Act Art. 50(2)): ai_generated = the published text is AI-written '
    '(the supply_content_writer draft, or a staff edit of it), ai_generated_at = when that draft was written, '
    'ai_human_edited = a person edited it before publishing; all three NULL while not published. Columns are '
    'append-only (Booking feature-detects them).';

REVOKE ALL ON catalog.v_supply_content FROM PUBLIC;
GRANT SELECT ON catalog.v_supply_content TO booking;

-- ── Closing checks as catalog_owner ──────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    cols text;
BEGIN
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_supply_content'::regclass AND a.attnum > 0
       AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'source_system text, source_id text, entity_type text, content_status text, '
                             'content_version integer, description text, highlights text[], good_to_know text[], '
                             'photo_urls text[], edit_url text, published_at timestamp with time zone, '
                             'ai_generated boolean, ai_generated_at timestamp with time zone, '
                             'ai_human_edited boolean' THEN
        RAISE EXCEPTION 'migration 358: catalog.v_supply_content has unexpected columns: %', cols;
    END IF;
    IF EXISTS (SELECT 1 FROM catalog.v_supply_content
                WHERE description IS NULL
                  AND (ai_generated IS NOT NULL OR ai_generated_at IS NOT NULL OR ai_human_edited IS NOT NULL)) THEN
        RAISE EXCEPTION 'migration 358: catalog.v_supply_content marks a row that serves no text';
    END IF;
    IF EXISTS (SELECT 1 FROM catalog.v_supply_content
                WHERE (ai_generated IS TRUE) <> (ai_generated_at IS NOT NULL)
                   OR (ai_generated IS TRUE) <> (ai_human_edited IS NOT NULL)) THEN
        RAISE EXCEPTION 'migration 358: ai_generated_at / ai_human_edited must be set exactly when ai_generated';
    END IF;
    RAISE NOTICE 'migration 358: catalog.v_supply_content published rows %, AI-written %, of which edited by staff %',
        (SELECT count(*) FROM catalog.v_supply_content WHERE description IS NOT NULL),
        (SELECT count(*) FROM catalog.v_supply_content WHERE ai_generated),
        (SELECT count(*) FROM catalog.v_supply_content WHERE ai_human_edited);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing checks as cis_owner: owner, barrier, exact consumer grant ────────────────────────────────────────────
DO $$
DECLARE
    privs text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class WHERE oid = 'catalog.v_supply_content'::regclass
                                        AND (pg_get_userbyid(relowner) <> 'catalog_owner'
                                             OR NOT COALESCE(reloptions, '{}') @> ARRAY['security_barrier=true'])) THEN
        RAISE EXCEPTION 'migration 358: catalog.v_supply_content must be catalog_owner''s and security_barrier';
    END IF;
    SELECT string_agg(r || ':' || p, ', ' ORDER BY r, p) INTO privs FROM (
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r, a.privilege_type AS p
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid = 'catalog.v_supply_content'::regclass AND a.grantee <> c.relowner) x;
    IF privs IS DISTINCT FROM 'booking:SELECT' THEN
        RAISE EXCEPTION 'migration 358: unexpected grants on catalog.v_supply_content: %', privs;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attacl IS NOT NULL
                                            AND attrelid = 'catalog.v_supply_content'::regclass) THEN
        RAISE EXCEPTION 'migration 358: column grants on catalog.v_supply_content';
    END IF;
    IF has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 358: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('358', now(), 'AA-1040: catalog.v_supply_content appends ai_generated, ai_generated_at, ai_human_edited '
                      '(the machine-readable AI mark of the published supply text, for Booking)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
