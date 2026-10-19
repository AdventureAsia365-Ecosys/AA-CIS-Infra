-- Migration 248: AA-884 (CIS admin Platform) — acp_shared.audit_log becomes append-only with a hash chain
-- and per-request columns; shared.job_worker records the worker's git SHA; a new table stores the acc2
-- Cost Explorer spend grouped by the App cost-allocation tag.
--
-- Why. The S241 admin-console audit (docs/audits/2026-10-17-S241-admin-console §5.5, GĐ5/7/10) asks for:
--   * a staff action trail nobody can quietly edit: today acp_shared.audit_log (migration 030 + 021) has no
--     trigger, so any role with UPDATE/DELETE rewrites history without a trace. DM-2.4: no new audit table,
--     harden the one we have. Every non-GET staff call (AA-884 PR C, api/middleware/staff_audit.py) logs
--     its method, route template and HTTP status, so the columns live here;
--   * the Platform Apps page shows API vs worker SHA parity: the worker heartbeat (shared.job_worker) has
--     task_revision but no git SHA (the image already carries APP_GIT_SHA, Dockerfile ARG GIT_SHA);
--   * cost per app: Cost Explorer GroupBy TAG App works on acc2 (probe S243: untagged "App$" ~83 % of the
--     month, cis / booking / tripplanner / shared / identity / platform tags present). The existing
--     shared.cost_explorer_snapshot is grouped by SERVICE only and has no tag column; a separate table keeps
--     its readers (GET /admin/cost-explorer, retention_cost_explorer_snapshot) unchanged.
--
-- What.
--   1. acp_shared.audit_actor_type += 'staff', 'machine' (ADD VALUE IF NOT EXISTS is allowed inside a
--      transaction on PG 12+; neither value is USED in this file, which PG forbids before COMMIT). Where
--      021 never applied (a DB replaying files in number order: 021 runs before 030 creates the table), the
--      type (all five values) and the actor_type column are created here; on Dev both exist already.
--   2. acp_shared.audit_log += http_method text (CHECK POST/PUT/PATCH/DELETE or NULL), route text,
--      status smallint, chain_seq bigint, prev_hash text, row_hash text; UNIQUE partial index on chain_seq.
--      The ~1276 existing rows stay pre-chain (all six NULL): nothing is backfilled (MIG-13), and the
--      verifier (GET /admin/platform/audit/verify, PR C) reports them as pre_chain_rows.
--   3. FUNCTION acp_shared.audit_log_chain(), BEFORE INSERT FOR EACH ROW (trigger audit_log_chain):
--        PERFORM pg_advisory_xact_lock(884, 1);    -- one chain writer at a time
--        chain_seq := last chain_seq + 1 (1 at genesis); prev_hash := last row_hash (NULL at genesis);
--        row_hash  := sha256 hex of the canonical text (below).
--      No sequence on purpose: a rolled-back insert leaves no gap, and there is no sequence grant for the
--      X1 runtime role to manage. The order of chain_seq is the order the lock was taken.
--      Canonical text (the verifier recomputes exactly this in Python; change both together or never):
--        concat_ws('|', coalesce(prev_hash,''), id::text, chain_seq::text, coalesce(tenant_id,''),
--                  coalesce(actor,''), coalesce(actor_type::text,''), coalesce(action,''),
--                  coalesce(resource_type,''), coalesce(resource_id,''), coalesce(details::text,''),
--                  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
--                  coalesce(http_method,''), coalesce(route,''), coalesce(status::text,''))
--      encoded UTF8. details::text is jsonb's own normalised text, so the verifier reads it from the DB.
--      created_at is coalesced to now() first (the column is nullable since 030).
--   4. FUNCTION acp_shared.audit_log_append_only(): RAISE 42501 (insufficient_privilege)
--      'acp_shared.audit_log is append-only (AA-884)'. Triggers audit_log_no_update / audit_log_no_delete
--      (BEFORE UPDATE / DELETE FOR EACH ROW) and audit_log_no_truncate (BEFORE TRUNCATE FOR EACH STATEMENT).
--      No production code updates or deletes audit rows and there is no retention kind for the table
--      (inventory S243); the integration tests that cleaned up their own rows now go through
--      tests/integration/_audit_cleanup.py (session_replication_role = replica, superuser test DB only).
--   Both functions: plpgsql, NOT SECURITY DEFINER (MIG-6), search_path pinned to pg_catalog, acp_shared,
--   EXECUTE revoked from PUBLIC (SEC-4; a firing trigger does not check EXECUTE). The chain function runs
--   as the inserting role, so that role needs SELECT on acp_shared.audit_log as well as INSERT (the master
--   today; CIS 244 grants cis_app SELECT, INSERT, UPDATE, DELETE ON ALL TABLES — the triggers refuse the
--   last two; X1 may revoke them from cis_app on this table for defence in depth).
--   5. shared.job_worker += git_sha text (the worker writes APP_GIT_SHA when it registers at start, PR C).
--   6. TABLE shared.cost_explorer_app_snapshot (acc2 GetCostAndUsage DAILY, GroupBy TAG App + SERVICE):
--      account_id, app_tag ('' = untagged, CE key "App$"), service, period_start, period_end, amount_usd
--      numeric(14,4), unit, fetched_at. Readers take the newest fetch per (account_id, app_tag, service,
--      period_start), as cost_explorer.py does for the SERVICE snapshot. Same grants as
--      shared.cost_explorer_snapshot after 241: none to any app role but the CIS runtime; REVOKE ALL FROM
--      aa_app_user here (SEC-3: the 007b default ACL would hand it SELECT). A retention rule for superseded fetches is a
--      code change (services/retention/policy.py), not part of this file.
--   7. Register 248.
--
-- What this does NOT protect against (say it plainly, AA-884 risk 2). The RDS master aa_cis_admin owns
-- the table and is a member of rds_superuser: it can DROP / DISABLE the triggers or run with
-- session_replication_role = replica and then rewrite rows. The hash chain makes such an edit DETECTABLE
-- (the verifier recomputes every row_hash and prev_hash link) but not impossible, and someone who also
-- recomputes every later hash leaves no trace in the table itself. Real tamper resistance comes with the X1
-- runtime role cis_app (no ownership, no superuser) and CIS 245's owner transfer, plus an off-database copy
-- (S3 Object Lock export, a separate follow-up).
--
-- Concurrency. The chain needs READ COMMITTED (asyncpg's and psycopg2's default): after the advisory lock,
-- the SELECT of the last row takes a fresh snapshot and sees the previous holder's committed row. Under
-- REPEATABLE READ / SERIALIZABLE the snapshot predates the lock, the next chain_seq is computed from a stale
-- row and the UNIQUE index on chain_seq rejects the insert (an error, never a silent fork). The lock is
-- transaction-scoped: a writer that inserts its audit row early in a long transaction holds every other
-- audit write until it commits. Inventory S243 (AA-884 notes): every call site writes its row last or
-- next-to-last in a short DB-only transaction (no HTTP / LLM / Cognito call after it inside the
-- transaction); keep it that way (QRY-4). The key (884, 1) is in the two-int4 advisory key space, apart
-- from the single-bigint keys used elsewhere (pg_advisory_xact_lock(hashtext(...)) in v1_tours).
--
-- Locks. ALTER TABLE acp_shared.audit_log (ADD COLUMN without default = metadata only; ADD CONSTRAINT CHECK
-- scans ~1276 rows; the unique index is built on a 1 MB table in the transaction, no CONCURRENTLY) and
-- ALTER TABLE shared.job_worker (ADD COLUMN, metadata only; the heartbeat UPDATEs it every few seconds)
-- take ACCESS EXCLUSIVE for milliseconds. lock_timeout 5s below. Apply with shared.job idle. Not
-- destructive (no `migrate:` directive). Re-running is a no-op (IF NOT EXISTS / OR REPLACE everywhere,
-- constraints added only when missing).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243, AA-CIS-Infra db/owners.yaml): it runs
-- as the DB Migrate login today, as cis_owner after 245, unchanged. No catalog.* view is touched (XD9
-- freeze), no dynamic EXECUTE. 244/245/246 (X1) are reserved; this file may apply before them (the runner
-- keys "applied" on the version only). The X1 245 transfer and the 246 / isolation probes must cover
-- shared.cost_explorer_app_snapshot, the two acp_shared trigger functions and the new columns.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep
-- the two byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump
-- workflow); expect the six audit_log columns, its CHECK, index and three triggers, the two enum values,
-- shared.job_worker.git_sha and the new table.
--
-- Rollback (forward file; the chain columns hold data once a row is chained):
--   DROP TRIGGER IF EXISTS audit_log_chain ON acp_shared.audit_log;
--   DROP TRIGGER IF EXISTS audit_log_no_update ON acp_shared.audit_log;
--   DROP TRIGGER IF EXISTS audit_log_no_delete ON acp_shared.audit_log;
--   DROP TRIGGER IF EXISTS audit_log_no_truncate ON acp_shared.audit_log;
--   DROP FUNCTION IF EXISTS acp_shared.audit_log_chain(), acp_shared.audit_log_append_only();
--   DROP INDEX IF EXISTS acp_shared.audit_log_chain_seq_key;
--   ALTER TABLE acp_shared.audit_log DROP CONSTRAINT IF EXISTS audit_log_http_method_chk,
--       DROP COLUMN IF EXISTS http_method, DROP COLUMN IF EXISTS route, DROP COLUMN IF EXISTS status,
--       DROP COLUMN IF EXISTS chain_seq, DROP COLUMN IF EXISTS prev_hash, DROP COLUMN IF EXISTS row_hash;
--   ALTER TABLE shared.job_worker DROP COLUMN IF EXISTS git_sha;
--   DROP TABLE IF EXISTS shared.cost_explorer_app_snapshot;
--   DELETE FROM shared.schema_versions WHERE version = '248';
--   (Enum values cannot be dropped; rows with actor_type staff/machine must be re-typed first.)

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

-- ── Guard 0: the objects exist and the runner may alter them ─────────────────────────────────────
DO $$
DECLARE
    obj        text;
    owner_name text;
BEGIN
    FOREACH obj IN ARRAY ARRAY['acp_shared.audit_log', 'shared.job_worker', 'shared.schema_versions'] LOOP
        IF pg_catalog.to_regclass(obj) IS NULL THEN
            RAISE EXCEPTION 'migration 248: % does not exist', obj;
        END IF;
        SELECT pg_catalog.pg_get_userbyid(relowner) INTO owner_name
          FROM pg_catalog.pg_class WHERE oid = pg_catalog.to_regclass(obj);
        IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
            RAISE EXCEPTION 'migration 248: % is owned by %, not by the runner % (ALTER TABLE / CREATE TRIGGER need the owner)',
                obj, owner_name, current_user;
        END IF;
    END LOOP;
    SELECT pg_catalog.pg_get_userbyid(t.typowner) INTO owner_name
      FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'acp_shared' AND t.typname = 'audit_actor_type';
    -- A missing type is created below (see step 1); an existing one must be the runner's to alter.
    IF owner_name IS NOT NULL AND NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
        RAISE EXCEPTION 'migration 248: acp_shared.audit_actor_type is owned by %, not by the runner %',
            owner_name, current_user;
    END IF;
END $$;

-- ── 1. Actor types for staff and machine calls ──────────────────────────────────────────────────
-- Dev has the type and the column since 021. A DB that replays the files in number order (CI, the local
-- integration DB) never got them: 021 alters acp_shared.audit_log, which only 030 creates, so the whole
-- 021 file fails there. Create both when missing (a no-op on Dev), so 248 behaves the same everywhere.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
                    WHERE n.nspname = 'acp_shared' AND t.typname = 'audit_actor_type') THEN
        CREATE TYPE acp_shared.audit_actor_type AS ENUM
            ('hitl_reviewer', 'tenant_admin', 'tenant_reviewer', 'staff', 'machine');
    END IF;
END $$;
ALTER TYPE acp_shared.audit_actor_type ADD VALUE IF NOT EXISTS 'staff';
ALTER TYPE acp_shared.audit_actor_type ADD VALUE IF NOT EXISTS 'machine';
ALTER TABLE acp_shared.audit_log ADD COLUMN IF NOT EXISTS actor_type acp_shared.audit_actor_type;

-- ── 2. Per-request and chain columns ────────────────────────────────────────────────────────────
ALTER TABLE acp_shared.audit_log
    ADD COLUMN IF NOT EXISTS http_method text,
    ADD COLUMN IF NOT EXISTS route       text,
    ADD COLUMN IF NOT EXISTS status      smallint,
    ADD COLUMN IF NOT EXISTS chain_seq   bigint,
    ADD COLUMN IF NOT EXISTS prev_hash   text,
    ADD COLUMN IF NOT EXISTS row_hash    text;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'acp_shared.audit_log'::regclass AND conname = 'audit_log_http_method_chk') THEN
        ALTER TABLE acp_shared.audit_log ADD CONSTRAINT audit_log_http_method_chk CHECK (
            http_method IS NULL OR http_method IN ('POST', 'PUT', 'PATCH', 'DELETE'));
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS audit_log_chain_seq_key
    ON acp_shared.audit_log (chain_seq) WHERE chain_seq IS NOT NULL;

COMMENT ON COLUMN acp_shared.audit_log.http_method IS
    'AA-884 (248): HTTP method of the staff/machine request this row records (POST/PUT/PATCH/DELETE); NULL for domain events.';
COMMENT ON COLUMN acp_shared.audit_log.route IS
    'AA-884 (248): FastAPI route template of the request (e.g. /admin/tenants/{tenant_id}); NULL for domain events or an unmatched path.';
COMMENT ON COLUMN acp_shared.audit_log.status IS
    'AA-884 (248): HTTP status the request returned (denied calls are logged too).';
COMMENT ON COLUMN acp_shared.audit_log.chain_seq IS
    'AA-884 (248): position in the hash chain, set by trigger audit_log_chain; NULL for rows written before 248.';
COMMENT ON COLUMN acp_shared.audit_log.prev_hash IS
    'AA-884 (248): row_hash of the previous chained row (NULL at genesis and on pre-248 rows).';
COMMENT ON COLUMN acp_shared.audit_log.row_hash IS
    'AA-884 (248): sha256 hex of this row''s canonical text (see acp_shared.audit_log_chain); recomputed by GET /admin/platform/audit/verify.';

-- ── 3. Hash chain (BEFORE INSERT) ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION acp_shared.audit_log_chain() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, acp_shared
AS $$
DECLARE
    last_seq  bigint;
    last_hash text;
BEGIN
    -- One chain writer at a time, until the inserting transaction ends (see the migration header).
    PERFORM pg_catalog.pg_advisory_xact_lock(884, 1);
    NEW.created_at := COALESCE(NEW.created_at, pg_catalog.now());
    SELECT a.chain_seq, a.row_hash INTO last_seq, last_hash
      FROM acp_shared.audit_log a
     WHERE a.chain_seq IS NOT NULL
     ORDER BY a.chain_seq DESC
     LIMIT 1;
    NEW.chain_seq := COALESCE(last_seq, 0) + 1;
    NEW.prev_hash := last_hash;
    NEW.row_hash := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(pg_catalog.concat_ws('|',
        COALESCE(NEW.prev_hash, ''),
        NEW.id::text,
        NEW.chain_seq::text,
        COALESCE(NEW.tenant_id::text, ''),
        COALESCE(NEW.actor::text, ''),
        COALESCE(NEW.actor_type::text, ''),
        COALESCE(NEW.action::text, ''),
        COALESCE(NEW.resource_type::text, ''),
        COALESCE(NEW.resource_id, ''),
        COALESCE(NEW.details::text, ''),
        pg_catalog.to_char(NEW.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        COALESCE(NEW.http_method, ''),
        COALESCE(NEW.route, ''),
        COALESCE(NEW.status::text, '')), 'UTF8')), 'hex');
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION acp_shared.audit_log_chain() FROM PUBLIC;
COMMENT ON FUNCTION acp_shared.audit_log_chain() IS
    'AA-884 (248): BEFORE INSERT trigger on acp_shared.audit_log; sets chain_seq / prev_hash / row_hash under pg_advisory_xact_lock(884, 1). Needs READ COMMITTED. The canonical text is mirrored by api/services/platform_audit.py (verifier).';

CREATE OR REPLACE TRIGGER audit_log_chain
    BEFORE INSERT ON acp_shared.audit_log
    FOR EACH ROW EXECUTE FUNCTION acp_shared.audit_log_chain();

-- ── 4. Append-only (BEFORE UPDATE / DELETE / TRUNCATE) ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION acp_shared.audit_log_append_only() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, acp_shared
AS $$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = 'insufficient_privilege',
        MESSAGE = format('acp_shared.audit_log is append-only (AA-884): %s refused', TG_OP),
        HINT    = 'Audit rows are never updated or deleted; write a new row that records the correction.';
END;
$$;
REVOKE ALL ON FUNCTION acp_shared.audit_log_append_only() FROM PUBLIC;
COMMENT ON FUNCTION acp_shared.audit_log_append_only() IS
    'AA-884 (248): refuses UPDATE / DELETE / TRUNCATE on acp_shared.audit_log with SQLSTATE 42501. The table owner (rds_superuser member) can still bypass it until X1 cis_app + 245.';

CREATE OR REPLACE TRIGGER audit_log_no_update
    BEFORE UPDATE ON acp_shared.audit_log
    FOR EACH ROW EXECUTE FUNCTION acp_shared.audit_log_append_only();
CREATE OR REPLACE TRIGGER audit_log_no_delete
    BEFORE DELETE ON acp_shared.audit_log
    FOR EACH ROW EXECUTE FUNCTION acp_shared.audit_log_append_only();
CREATE OR REPLACE TRIGGER audit_log_no_truncate
    BEFORE TRUNCATE ON acp_shared.audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION acp_shared.audit_log_append_only();

COMMENT ON TABLE acp_shared.audit_log IS
    'Audit trail (030; actor_type 021). Append-only with a sha256 hash chain since AA-884 (248): UPDATE / DELETE / TRUNCATE raise 42501, rows from 248 on carry chain_seq / prev_hash / row_hash.';

-- ── 5. Worker git SHA ───────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.job_worker ADD COLUMN IF NOT EXISTS git_sha text;
COMMENT ON COLUMN shared.job_worker.git_sha IS
    'AA-884 (248): APP_GIT_SHA of the worker image (written when the worker registers at start); compared with the API''s on /admin/platform/apps.';

-- ── 6. Cost Explorer by App tag (acc2) ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.cost_explorer_app_snapshot (
    id           uuid          NOT NULL DEFAULT gen_random_uuid(),
    account_id   text          NOT NULL,
    app_tag      text          NOT NULL,
    service      text          NOT NULL,
    period_start date          NOT NULL,
    period_end   date          NOT NULL,
    amount_usd   numeric(14,4) NOT NULL,
    unit         text          NOT NULL,
    fetched_at   timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT cost_explorer_app_snapshot_pkey PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS cost_explorer_app_snapshot_period_idx
    ON shared.cost_explorer_app_snapshot (period_start, app_tag, service, fetched_at DESC);
CREATE INDEX IF NOT EXISTS cost_explorer_app_snapshot_fetched_idx
    ON shared.cost_explorer_app_snapshot (fetched_at DESC);
REVOKE ALL ON shared.cost_explorer_app_snapshot FROM aa_app_user;

COMMENT ON TABLE shared.cost_explorer_app_snapshot IS
    'AA-884 (248): acc2 Cost Explorer UnblendedCost, DAILY, grouped by TAG App + SERVICE. Every refresh inserts a batch; readers take the newest fetch per (account_id, app_tag, service, period_start). No app-role grants.';
COMMENT ON COLUMN shared.cost_explorer_app_snapshot.app_tag IS
    'AA-884 (248): value of the App cost-allocation tag with CE''s "App$" prefix stripped; '''' = untagged.';

-- ── Guard 1: the shape is what this file promises ────────────────────────────────────────────────
DO $$
DECLARE
    missing text;
    labels  text[];
    fn      text;
    acl     text;
BEGIN
    SELECT string_agg(want.col || ' ' || want.typ, ', ') INTO missing
      FROM (VALUES ('acp_shared.audit_log', 'http_method', 'text'), ('acp_shared.audit_log', 'route', 'text'),
                   ('acp_shared.audit_log', 'status', 'smallint'), ('acp_shared.audit_log', 'chain_seq', 'bigint'),
                   ('acp_shared.audit_log', 'prev_hash', 'text'), ('acp_shared.audit_log', 'row_hash', 'text'),
                   ('acp_shared.audit_log', 'actor_type', 'acp_shared.audit_actor_type'),
                   ('shared.job_worker', 'git_sha', 'text'),
                   ('shared.cost_explorer_app_snapshot', 'app_tag', 'text'),
                   ('shared.cost_explorer_app_snapshot', 'amount_usd', 'numeric(14,4)'),
                   ('shared.cost_explorer_app_snapshot', 'fetched_at', 'timestamp with time zone'))
           AS want(rel, col, typ)
     WHERE NOT EXISTS (
         SELECT 1 FROM pg_catalog.pg_attribute a
          WHERE a.attrelid = want.rel::regclass AND a.attname = want.col
            AND NOT a.attisdropped AND pg_catalog.format_type(a.atttypid, a.atttypmod) = want.typ);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 248: missing column(s) %', missing;
    END IF;

    SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) INTO labels
      FROM pg_catalog.pg_enum e
      JOIN pg_catalog.pg_type t ON t.oid = e.enumtypid
      JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'acp_shared' AND t.typname = 'audit_actor_type';
    IF NOT (labels @> ARRAY['staff', 'machine']) THEN
        RAISE EXCEPTION 'migration 248: acp_shared.audit_actor_type lacks staff/machine (has %)', labels;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid = i.indexrelid
                    WHERE i.indrelid = 'acp_shared.audit_log'::regclass AND i.indisunique AND i.indisvalid
                      AND c.relname = 'audit_log_chain_seq_key') THEN
        RAISE EXCEPTION 'migration 248: unique index audit_log_chain_seq_key is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'acp_shared.audit_log'::regclass AND conname = 'audit_log_http_method_chk'
                      AND contype = 'c') THEN
        RAISE EXCEPTION 'migration 248: CHECK audit_log_http_method_chk is missing';
    END IF;

    -- Exactly the four triggers, enabled (tgenabled 'O'), each calling the right function:
    -- tgtype bits: 1 ROW, 2 BEFORE, 4 INSERT, 8 DELETE, 16 UPDATE, 32 TRUNCATE.
    IF (SELECT count(*) FROM pg_catalog.pg_trigger tg
         WHERE tg.tgrelid = 'acp_shared.audit_log'::regclass AND NOT tg.tgisinternal AND tg.tgenabled = 'O'
           AND ((tg.tgname = 'audit_log_chain' AND tg.tgtype = 7
                 AND tg.tgfoid = 'acp_shared.audit_log_chain()'::regprocedure)
             OR (tg.tgname = 'audit_log_no_update' AND tg.tgtype = 19
                 AND tg.tgfoid = 'acp_shared.audit_log_append_only()'::regprocedure)
             OR (tg.tgname = 'audit_log_no_delete' AND tg.tgtype = 11
                 AND tg.tgfoid = 'acp_shared.audit_log_append_only()'::regprocedure)
             OR (tg.tgname = 'audit_log_no_truncate' AND tg.tgtype = 34
                 AND tg.tgfoid = 'acp_shared.audit_log_append_only()'::regprocedure))) <> 4 THEN
        RAISE EXCEPTION 'migration 248: acp_shared.audit_log does not have its four enabled triggers';
    END IF;

    FOREACH fn IN ARRAY ARRAY['acp_shared.audit_log_chain()', 'acp_shared.audit_log_append_only()'] LOOP
        IF (SELECT p.prosecdef FROM pg_catalog.pg_proc p WHERE p.oid = fn::regprocedure) THEN
            RAISE EXCEPTION 'migration 248: % must not be SECURITY DEFINER (MIG-6)', fn;
        END IF;
        IF pg_catalog.has_function_privilege('public', fn, 'EXECUTE') THEN
            RAISE EXCEPTION 'migration 248: % is executable by PUBLIC (SEC-4)', fn;
        END IF;
    END LOOP;

    -- The new table is reachable by no other app role: no grant to anyone but its owner and the CIS runtime
    -- cis_app (CIS 244's default privileges may hand it the CIS table set when 244 lands first).
    SELECT string_agg(format('%s:%s', CASE WHEN x.grantee = 0 THEN 'PUBLIC'
                                           ELSE pg_catalog.pg_get_userbyid(x.grantee) END, x.privilege_type), ',')
      INTO acl
      FROM pg_catalog.pg_class c, LATERAL aclexplode(c.relacl) x
     WHERE c.oid = 'shared.cost_explorer_app_snapshot'::regclass AND x.grantee <> c.relowner
       AND (x.grantee = 0 OR pg_catalog.pg_get_userbyid(x.grantee) <> 'cis_app');
    IF acl IS NOT NULL THEN
        RAISE EXCEPTION 'migration 248: shared.cost_explorer_app_snapshot has grants beyond its owner and cis_app: %', acl;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('248', now(), 'AA-884: acp_shared.audit_log append-only + sha256 hash chain + http_method/route/status, audit_actor_type staff/machine, shared.job_worker.git_sha, shared.cost_explorer_app_snapshot (App tag)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
