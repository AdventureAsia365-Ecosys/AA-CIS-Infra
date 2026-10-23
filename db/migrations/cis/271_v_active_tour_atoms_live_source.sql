-- Migration 271: AA-986 L1 — acp_contract.v_active_tour_atoms also requires a live source version.
--
-- Why. Audit S248 (root docs/audits/2026-10-23-S248-tour-deletion-propagation/memo.md section 2.2): two rules of
-- "this tour is live" existed side by side. catalog._live_tour (CIS 258) keeps a tour only when its Master Content row
-- is active and not deleted AND its source version (raw_tours) is active and not deleted. The atom view
-- (CIS 203 / 208) checked only the Master half, so the atoms of a tour trashed or superseded at S0/A0 stayed live
-- for A3 ranking / routes / Segment matching, the Slate and the tenant routes whenever the Master was left active
-- (a supersede by Excel re-upload, DELETE /admin/raw-tours, a Master re-activated by hand, an approve after the
-- trash). This file gives the view the source half too: one rule, the catalog's.
--
-- What.
--   1. CREATE OR REPLACE VIEW acp_contract.v_active_tour_atoms: the same 24 columns in the same order (named
--      explicitly: 208 created it with `ta.*`, which Postgres froze to these columns), plus an inner join on
--      silver_aa_internal.raw_tours with `rt.source_status = 'active' AND rt.deleted_at IS NULL`. The Master half is
--      unchanged. The predicates are the ones of services' shared/tour_liveness.py (live_master_sql /
--      live_source_sql); tests/unit/test_aa986_tour_liveness.py checks the two stay identical.
--      CREATE OR REPLACE keeps the view's owner (cis_owner), its table grants and its column grants;
--      no other object depends on the view (no catalog view reads it), so nothing else is rebuilt.
--   2. Register 271.
--
-- Read path and RLS. The view keeps its owner's rights (CIS 241 / 266: not security_invoker). raw_tours has RLS
-- with FORCE; its policy raw_tours_cis_owner_all (USING true) lets the owner read every row, exactly as
-- published_tours_cis_owner_all already does for the Master join. The readers of the view (cis_app: api main pool,
-- worker; no tenant-pool grant since 241) are unchanged.
--
-- Rows. A row leaves the view only when its tour's source version is not live (trashed / superseded / deleted).
-- Live tours are unaffected. An atom always has a raw_tours row (FK tour_atoms.tour_id -> raw_tours, CIS 079), so the
-- inner join drops nothing else; the "missing source" count below is a defensive check that stays 0.
-- Probe S248 (CIS half, 23/10/2026, Dev): the trashed / superseded buckets have 0 live atoms today, so the expected
-- row change on Dev is 0 (orphan Masters, if any, are counted in the NOTICE).
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before: the view exists and its columns are exactly the 24 (name, type, position) of db-schema-reference.md;
--      the runner may replace it (owns it or is a member of its owner);
--   2. after: same columns, same owner, same relation ACL and column ACLs as before;
--   3. after: rows = rows before - rows of a dead source - rows of a missing source (the rule changed nothing else).
--   A NOTICE reports the three counts.
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: 24 columns, owner cis_owner,
-- dead_source_rows 0, missing_source_rows 0):
--   SELECT count(*) FILTER (WHERE rt.tour_id IS NOT NULL AND (rt.source_status <> 'active' OR rt.deleted_at IS NOT NULL))
--            AS dead_source_rows,
--          count(*) FILTER (WHERE rt.tour_id IS NULL) AS missing_source_rows, count(*) AS rows_now
--     FROM acp_contract.v_active_tour_atoms v LEFT JOIN silver_aa_internal.raw_tours rt ON rt.tour_id = v.tour_id;
--
-- Locks. CREATE OR REPLACE VIEW takes ACCESS EXCLUSIVE on the view only (not on tour_atoms), held for the
-- milliseconds of the swap; lock_timeout 5s (DB Migrate default). Re-running is a no-op apart from the guards.
-- Undo: a NEW forward migration recreating the 208 body (the Master join only), same column list.
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243). DB Migrate runs cis/ files as cis_owner, the
-- owner of the view (245).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── Guard 1 + the before state ─────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_oid     oid := to_regclass('acp_contract.v_active_tour_atoms');
    cols      text;
    expected  text := 'atom_id text, tour_id uuid, owner_scope text, text text, activity_type text, '
                      'emotional_hook text, visual_potential smallint, persona_fit jsonb, season_note text, '
                      'media jsonb, starred boolean, deleted boolean, usage_log jsonb, cooldown_until jsonb, '
                      'human_seam_notes jsonb, weight numeric, created_at timestamp with time zone, '
                      'updated_at timestamp with time zone, source_hash text, is_empty_marker boolean, '
                      'itinerary_day smallint, place text, action text, evidence text';
    owner     name;
    dead      bigint;
    missing   bigint;
    total     bigint;
BEGIN
    IF v_oid IS NULL THEN
        RAISE EXCEPTION 'migration 271: acp_contract.v_active_tour_atoms does not exist';
    END IF;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
      INTO cols
      FROM pg_attribute a WHERE a.attrelid = v_oid AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'migration 271: the view''s columns are not the 24 expected ones: %', cols;
    END IF;
    SELECT pg_get_userbyid(c.relowner) INTO owner FROM pg_class c WHERE c.oid = v_oid;
    IF NOT pg_has_role(current_user, owner, 'USAGE') THEN
        RAISE EXCEPTION 'migration 271: % may not replace the view (owner %); run it through DB Migrate (cis_owner)',
            current_user, owner;
    END IF;

    SELECT count(*) FILTER (WHERE rt.tour_id IS NOT NULL
                              AND (rt.source_status <> 'active' OR rt.deleted_at IS NOT NULL)),
           count(*) FILTER (WHERE rt.tour_id IS NULL),
           count(*)
      INTO dead, missing, total
      FROM acp_contract.v_active_tour_atoms v
      LEFT JOIN silver_aa_internal.raw_tours rt ON rt.tour_id = v.tour_id;

    PERFORM set_config('aa986.cols', cols, true);
    PERFORM set_config('aa986.owner', owner::text, true);
    PERFORM set_config('aa986.relacl', COALESCE((SELECT c.relacl::text FROM pg_class c WHERE c.oid = v_oid), ''),
                       true);
    PERFORM set_config('aa986.attacl',
                       COALESCE((SELECT string_agg(a.attname || '=' || a.attacl::text, ';' ORDER BY a.attnum)
                                   FROM pg_attribute a
                                  WHERE a.attrelid = v_oid AND a.attnum > 0 AND a.attacl IS NOT NULL), ''), true);
    PERFORM set_config('aa986.expected_rows', (total - dead - missing)::text, true);
    RAISE NOTICE 'migration 271: view rows before %, dead source % (leave), missing source % (leave)',
        total, dead, missing;
END $$;

-- ── 1. The view: Master half (203 / 208) + the source half of catalog._live_tour (258) ─────────────────────────────
CREATE OR REPLACE VIEW acp_contract.v_active_tour_atoms AS
SELECT ta.atom_id, ta.tour_id, ta.owner_scope, ta.text, ta.activity_type, ta.emotional_hook, ta.visual_potential,
       ta.persona_fit, ta.season_note, ta.media, ta.starred, ta.deleted, ta.usage_log, ta.cooldown_until,
       ta.human_seam_notes, ta.weight, ta.created_at, ta.updated_at, ta.source_hash, ta.is_empty_marker,
       ta.itinerary_day, ta.place, ta.action, ta.evidence
FROM acp_contract.tour_atoms ta
JOIN gold_aa_internal.published_tours pt
  ON pt.tour_id = ta.tour_id
 AND pt.master_status = 'active' AND pt.deleted_at IS NULL
JOIN silver_aa_internal.raw_tours rt
  ON rt.tour_id = pt.tour_id
 AND rt.source_status = 'active' AND rt.deleted_at IS NULL
WHERE NOT ta.deleted
  AND NOT ta.is_empty_marker;

-- ── Guards 2 + 3 ───────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_oid  oid := 'acp_contract.v_active_tour_atoms'::regclass;
    cols   text;
    n      bigint;
BEGIN
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
      INTO cols
      FROM pg_attribute a WHERE a.attrelid = v_oid AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM current_setting('aa986.cols') THEN
        RAISE EXCEPTION 'migration 271: the view''s columns changed: %', cols;
    END IF;
    IF (SELECT pg_get_userbyid(c.relowner)::text FROM pg_class c WHERE c.oid = v_oid)
       IS DISTINCT FROM current_setting('aa986.owner') THEN
        RAISE EXCEPTION 'migration 271: the view''s owner changed';
    END IF;
    IF COALESCE((SELECT c.relacl::text FROM pg_class c WHERE c.oid = v_oid), '')
       IS DISTINCT FROM current_setting('aa986.relacl') THEN
        RAISE EXCEPTION 'migration 271: the view''s grants changed';
    END IF;
    IF COALESCE((SELECT string_agg(a.attname || '=' || a.attacl::text, ';' ORDER BY a.attnum)
                   FROM pg_attribute a
                  WHERE a.attrelid = v_oid AND a.attnum > 0 AND a.attacl IS NOT NULL), '')
       IS DISTINCT FROM current_setting('aa986.attacl') THEN
        RAISE EXCEPTION 'migration 271: the view''s column grants changed';
    END IF;
    SELECT count(*) INTO n FROM acp_contract.v_active_tour_atoms;
    IF n <> current_setting('aa986.expected_rows')::bigint THEN
        RAISE EXCEPTION 'migration 271: view rows after % <> expected % (rows before minus dead / missing source)',
            n, current_setting('aa986.expected_rows');
    END IF;
    RAISE NOTICE 'migration 271: view rows after %', n;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('271', now(), 'AA-986 L1: v_active_tour_atoms requires a live source version (the catalog._live_tour rule)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
