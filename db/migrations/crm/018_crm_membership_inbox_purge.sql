-- Migration crm-018: AA-978 follow-up (partner CRM, CRM-P1) — the 90-day window of crm.membership_inbox, enforced by
-- the daily data lifecycle run.
--
-- Owner: AA-Partner (api/migrations/018_crm_membership_inbox_purge.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy DB Migrate applies (Migration Copy Guard). Key crm-018 (S251 schedule: crm-016 = AA-946, crm-017 = AA-947).
-- crm.lifecycle_purge_expired below is the crm-010 text plus one step; a later key that replaces it starts from THIS
-- text.
--
-- Why. Root data standards Part B §7 (DM-7, row crm.membership_inbox, S250 R2): an inbox row is deleted 90 days after
-- it was received (created_at) and with its agency at offboarding. crm-013 shipped the offboarding half (the agency
-- scope of crm.erase_subject) and named the window "proposed, not enforced yet" (AA-Partner
-- docs/implementation-notes/AA-978.md, Follow-ups). The inbox only exists to make a replayed CIS page a no-op; CIS keeps
-- its own events 90 days (CIS 276 DM-7 row), so a cursor older than that cannot be replayed and an older inbox row
-- protects nothing.
--
-- What:
--   1. crm.lifecycle_purge_expired(dry_run) (crm-010 item 11) + one step: the agency's crm.membership_inbox rows whose
--      created_at is more than 90 days ago (crm.erase_rows, so a dry run counts only), returned as the new key
--      `membership_inbox` next to `llm_call` and `placeholder_map`. Same rules as the other steps: runs as crm_owner
--      (SECURITY DEFINER) for app.tenant_id only (FORCE RLS: crm_owner sees that agency's rows only), under
--      app.erasing (crm.membership_inbox_append_only lets crm_owner delete only then), EXECUTE for crm_eraser only.
--      An agency legal hold still skips the whole purge (hold rule 4c / 4f of crm-010: the inbox names no trip or
--      traveller, so only the agency hold reaches it), and the result then carries `membership_inbox: 0`.
--      The app's crm_lifecycle job (app/lifecycle/job.py) records the count as `membership_inbox_purged`; before this
--      file is applied the key is absent and the job records 0.
--   2. Comments: crm.membership_inbox (the window is enforced now) and crm.membership_inbox_append_only() (it also
--      lets crm.lifecycle_purge_expired delete, which its body always allowed: crm_owner + app.erasing).
--   No table, column, grant or policy changes; no DM-7 row is added (the inbox row exists since S250; the root
--   register only drops "proposed, not enforced yet").
--
-- Order: needs crm-013 (the inbox and its trigger function) and crm-010 (the function replaced here); Guard 0 checks
-- those objects, not crm-016 / crm-017, which touch neither. DB Migrate applies keys in order, so on Dev this file runs
-- after crm-016 and crm-017 (other S251 lanes); applied alone it works the same. Guard 0 also refuses to run when the
-- live crm.lifecycle_purge_expired already deletes from a table this text does not know (a key between crm-010 and
-- this one replaced it): replacing it would silently drop that step.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (CREATE OR REPLACE,
-- COMMENT, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14) with the crm-010 text. Until the app
-- deploys the new count the daily run deletes the rows all the same (the function does it); only the count is missing
-- from crm.lifecycle_run.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, on the objects it needs ──────────────────────────────────────────
DO $$
DECLARE
    v_src text;
    v_unknown text[];
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-018: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-013') THEN
        RAISE EXCEPTION 'crm-018: crm-013 is not registered (AA-978 membership feed, lands first)';
    END IF;
    IF to_regclass('crm.membership_inbox') IS NULL
       OR to_regprocedure('crm.membership_inbox_append_only()') IS NULL
       OR to_regprocedure('crm.lifecycle_purge_expired(boolean)') IS NULL
       OR to_regprocedure('crm.erase_rows(text,text,uuid,uuid,boolean,text)') IS NULL
       OR to_regprocedure('crm.hold_row(uuid,uuid)') IS NULL THEN
        RAISE EXCEPTION 'crm-018: crm.membership_inbox (crm-013) or the crm-010 lifecycle functions missing';
    END IF;
    -- The live function may only purge what this text purges (crm-010's two steps, or this file's three on a re-run).
    SELECT prosrc INTO v_src FROM pg_catalog.pg_proc WHERE oid = 'crm.lifecycle_purge_expired(boolean)'::regprocedure;
    SELECT array_agg(DISTINCT m[1]) INTO v_unknown
      FROM regexp_matches(v_src, 'erase_rows\(''([a-z_]+)''', 'g') AS m
     WHERE m[1] NOT IN ('placeholder_map', 'llm_call', 'membership_inbox');
    IF v_unknown IS NOT NULL THEN
        RAISE EXCEPTION 'crm-018: crm.lifecycle_purge_expired also purges % (a later key replaced it); start from that text',
            array_to_string(v_unknown, ', ');
    END IF;
END $$;

-- ── 1. crm.lifecycle_purge_expired with the inbox ────────────────────────────────────────────────
-- The crm-010 text with one step added (file header item 1). Later keys start from THIS text.
CREATE OR REPLACE FUNCTION crm.lifecycle_purge_expired(p_dry_run boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    n bigint;
    m bigint := 0;
    i bigint;
BEGIN
    IF v_tenant IS NULL OR p_dry_run IS NULL THEN
        RAISE EXCEPTION 'crm: lifecycle_purge_expired needs app.tenant_id and dry_run'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    LOCK TABLE crm.legal_hold IN SHARE MODE;  -- hold rule 4g
    -- llm_call and membership_inbox name no trip or traveller: the agency hold only (4c, 4f).
    IF crm.hold_row(NULL, NULL) THEN
        RETURN jsonb_build_object('llm_call', 0, 'placeholder_map', 0, 'membership_inbox', 0, 'held', 1);
    END IF;
    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', 'on', true);
    END IF;
    -- crm-009 placeholder_map_call_fk: a map of a call this purge deletes goes first (a 24 h map the hourly
    -- crm_placeholder_purge has not removed yet). Skipped while crm-009 is not applied (crm-010 may land first).
    IF to_regclass('crm.placeholder_map') IS NOT NULL THEN
        m := crm.erase_rows('placeholder_map',
                            'llm_call_id IN (SELECT l.llm_call_id FROM crm.llm_call l '
                            'WHERE l.at < now() - interval ''180 days'')',
                            NULL, NULL, p_dry_run);
    END IF;
    n := crm.erase_rows('llm_call', 'at < now() - interval ''180 days''', NULL, NULL, p_dry_run);
    -- crm-018: the CIS membership events this agency received more than 90 days ago (DM-7; created_at = received).
    i := crm.erase_rows('membership_inbox', 'created_at < now() - interval ''90 days''', NULL, NULL, p_dry_run);
    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', '', true);
    END IF;
    RETURN jsonb_build_object('llm_call', n, 'placeholder_map', m, 'membership_inbox', i, 'held', 0);
END;
$$;
REVOKE ALL ON FUNCTION crm.lifecycle_purge_expired(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.lifecycle_purge_expired(boolean) TO crm_eraser;
COMMENT ON FUNCTION crm.lifecycle_purge_expired(boolean) IS 'AA-942 (crm-010, design §3.6) + AA-978 (crm-018, DM-7): deletes the agency''s crm.llm_call rows older than 180 days (crm.llm_usage_daily keeps the rollup), first the crm-009 placeholder maps of those calls, and its crm.membership_inbox rows received more than 90 days ago; nothing under an agency legal hold. Dry run counts only. Returns {llm_call, placeholder_map, membership_inbox, held}. EXECUTE: crm_eraser only.';

-- ── 2. Comments ──────────────────────────────────────────────────────────────────────────────────
COMMENT ON TABLE crm.membership_inbox IS 'AA-978 (crm-013): one row per tenant.membership.v1 event the CRM received for an agency it holds, active or locked (event_id = the CIS event id: applied at most once, a replayed page is a no-op), with the agency (= the CIS tenant id; no foreign key; events of CIS tenants without a CRM agency and of offboarding agencies get no row), the type (NULL only when a rejected event names none of the eight), the outcome applied | ignored | rejected and a reason code. Ids and codes only. created_at = received. Append-only; deleted 90 days after created_at by crm.lifecycle_purge_expired (crm-018, DM-7) and with the agency (crm.erase_subject tenant scope).';
COMMENT ON FUNCTION crm.membership_inbox_append_only() IS 'AA-978 (crm-013, crm-018): crm.membership_inbox is append-only; DELETE only as crm_owner with app.erasing on, which only crm.erase_subject (agency erase) and crm.lifecycle_purge_expired (90-day window) set: the crm.erasable_append_only() rule (crm-010) for this table.';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    IF position('''membership_inbox''' IN (SELECT prosrc FROM pg_catalog.pg_proc
                 WHERE oid = 'crm.lifecycle_purge_expired(boolean)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-018: crm.lifecycle_purge_expired does not purge crm.membership_inbox';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_catalog.pg_proc WHERE oid = 'crm.lifecycle_purge_expired(boolean)'::regprocedure)
    THEN
        RAISE EXCEPTION 'crm-018: crm.lifecycle_purge_expired must stay SECURITY DEFINER';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.lifecycle_purge_expired(boolean)', 'EXECUTE')
       OR pg_catalog.has_function_privilege('public', 'crm.lifecycle_purge_expired(boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.lifecycle_purge_expired(boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-018: crm.lifecycle_purge_expired must be executable by crm_eraser only';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm_app', 'crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
        IF pg_catalog.has_table_privilege(t, 'crm.membership_inbox', 'DELETE')
           OR pg_catalog.has_table_privilege(t, 'crm.membership_inbox', 'UPDATE') THEN
            RAISE EXCEPTION 'crm-018: % may change crm.membership_inbox (append-only)', t;
        END IF;
    END LOOP;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-018', now(), 'AA-978 follow-up: crm.lifecycle_purge_expired also deletes crm.membership_inbox rows received more than 90 days ago (DM-7 window enforced)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
