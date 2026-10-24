-- Migration crm-007: AA-940 (partner CRM, design v3 card CRM-12) — F5 audit complete: monthly partitions of the agency
-- audit with a 12-month retention that drops whole partitions, the hourly export chain (manifest table and export
-- registry), and the offboarding path that works with the append-only trigger and the tenant foreign key.
--
-- Owner: AA-Partner (api/migrations/007_crm_audit_partitions_export.sql). AA-CIS-Infra db/migrations/crm/ holds the
-- byte copy DB Migrate applies (Migration Copy Guard). Key crm-007.
--
-- Why. Design v3 §3.3 group J ("audit_event (monthly partitions, INSERT/SELECT only, no PII), audit_export_manifest
-- (hash chain)"), §3.6 ("audit_event in the DB: 12 months viewable"), §4.9 ("hourly to both Object Lock buckets,
-- with a chained SHA-256 manifest"; "agency page: 12 months in the app, plus download"); data standards DM-7 row
-- crm.audit_event ("a partition is dropped only after its export is verified"; the manifest "follows the archive").
-- The AA-934 comment on AA-940: crm.audit_event is append-only (a trigger refuses UPDATE / DELETE / TRUNCATE) and
-- references crm.tenant with no ON DELETE action, so retention and offboarding cannot use DELETE.
-- Card R test: UPDATE as crm_app -> error. E tests: an export retry keeps the chain; the verify script detects a
-- deleted row.
--
-- What:
--   1. crm.audit_event becomes PARTITION BY RANGE (at), one partition per UTC month. The crm-003 table is renamed
--      crm.audit_event_legacy and ATTACHED as the first partition (MINVALUE up to the start of next month), so its
--      rows are never rewritten or copied. The new parent keeps every column, CHECK, index name and the tenant
--      foreign key; the primary key becomes (event_id, at) (a partitioned key must hold the partition column).
--      `at` now defaults to clock_timestamp() (insert time, not transaction start: the hourly export needs the time
--      a row became visible), and a trigger refuses an explicit `at` more than a minute away from the insert time
--      unless the writer is crm_owner, so crm_app cannot backdate an event into an hour that is already exported.
--      Append-only as before: crm_app INSERT + SELECT on the parent only and nothing on any partition (a query
--      through the parent checks the parent's privileges and policy only); the row trigger refusing UPDATE / DELETE
--      is cloned to every partition, and each partition gets the TRUNCATE trigger, ENABLE + FORCE RLS and its own
--      tenant_isolation policy (defence in depth if a partition is ever named directly).
--   2. crm.audit_partition_bounds(): the partitions with their [lower, upper) range (lower NULL = MINVALUE).
--      crm.audit_ensure_partitions(): SECURITY DEFINER, creates the missing monthly partitions from the current
--      month to three months ahead (no argument, so the caller cannot make more). crm_app runs it from the hourly
--      export job; the migration runs it once.
--   3. crm.audit_drop_expired_partitions(dry_run): SECURITY DEFINER, the only retention path. A partition goes only
--      when its range ends at or before the start of the UTC month twelve months ago (so the agency always sees at
--      least 12 months) AND every agency in the export registry is verified up to that end (DM-7: "dropped only
--      after its export is verified"). DROP TABLE does not fire the row trigger, so append-only holds for every row
--      the database keeps. Dry run (the default of the retention job, DM-7.2) only reports.
--   4. crm.audit_export_tenant: platform registry, ids and times only: one row per agency,
--      written by an AFTER INSERT trigger on crm.tenant and backfilled here; `exported_until` (the end of the last
--      exported hour), `verified_until` (the end of the last hour the daily verification confirmed), `last_seq`.
--      RLS enabled but not forced: crm_app sees the row of app.tenant_id only; the owner's SECURITY DEFINER
--      functions read every row (crm.audit_export_agencies() lists the agencies for the export job, since crm_app
--      cannot list crm.tenant; the drop function checks every agency is verified). ON DELETE CASCADE: it never
--      blocks the offboarding delete of a tenant row. crm_app may UPDATE only (exported_until, last_seq) and INSERT
--      only (tenant_id, exported_until); `verified_until` moves only through crm.audit_mark_verified() (SECURITY
--      DEFINER: the agency of app.tenant_id, forward only, never past exported_until).
--   5. crm.audit_export_manifest: the hash chain, one row per agency per exported hour (append-only template
--      variant): seq, [period_start, period_end), event_count, content_sha256 (the events of the object),
--      prev_manifest_sha256 (64 zeros for seq 1), manifest_sha256, object_key, object_sha256. A trigger refuses a
--      row that does not continue the agency's chain (seq + 1, previous hash, contiguous period). No foreign key to
--      crm.tenant: the manifest follows the archive (seven years, DM-7) and outlives an offboarded agency's row.
--   Offboarding path (CRM-35 uses it; nothing here deletes an agency): the agency is locked and trashed (its row
--   stays, the foreign key holds); the export keeps running for it (the export context accepts a locked or trashed
--   agency) until its last hour is exported and verified; its audit rows leave the database only with the monthly
--   partition drops (at most 13 months after its last event); then no row references crm.tenant and the tenant row
--   can be deleted (the registry row cascades, the manifests stay with the archive). Erasure keeps the audit by
--   design (§4.10: "audit_event has no PII and is kept").
--
-- Order: after crm-006 (AA-937); Guard 0 refuses to run before it is registered.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. The backfill of the registry reads
-- every agency once: FORCE RLS binds the owner too, so the file turns FORCE off on crm.tenant and the audit parent
-- for that one statement and on again in the same transaction (ACCESS EXCLUSIVE until COMMIT; Guard 1 checks both
-- are forced again). Idempotent: section 1 runs only while crm.audit_event is a plain table; everything else uses
-- IF NOT EXISTS, CREATE OR REPLACE, DROP … IF EXISTS and ON CONFLICT DO NOTHING. Rollback: a forward crm- file
-- (MIG-14); no data is removed (the crm-003 table becomes a partition).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-006 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-007: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-006') THEN
        RAISE EXCEPTION 'crm-007: crm-006 is not registered (F1 / F2 complete, AA-937, lands first)';
    END IF;
END $$;

-- ── 1. crm.audit_event: monthly partitions (the crm-003 table becomes the first partition) ──────
DO $$
DECLARE
    v_upper timestamptz := (date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month') AT TIME ZONE 'UTC';
BEGIN
    IF (SELECT relkind FROM pg_catalog.pg_class WHERE oid = 'crm.audit_event'::regclass) <> 'r' THEN
        RETURN;  -- already partitioned (re-run)
    END IF;
    ALTER TABLE crm.audit_event RENAME TO audit_event_legacy;
    -- A partition's primary key must be the parent's (event_id, at); event_id stays a random UUID.
    ALTER TABLE crm.audit_event_legacy DROP CONSTRAINT audit_event_pkey;
    ALTER TABLE crm.audit_event_legacy ADD CONSTRAINT audit_event_legacy_pkey PRIMARY KEY (event_id, at);
    ALTER INDEX crm.audit_event_tenant_at_idx RENAME TO audit_event_legacy_tenant_at_idx;
    ALTER INDEX crm.audit_event_object_idx RENAME TO audit_event_legacy_object_idx;
    -- The parent's row trigger is cloned onto the partition when it is attached (same name).
    DROP TRIGGER IF EXISTS audit_event_append_only ON crm.audit_event_legacy;

    CREATE TABLE crm.audit_event (
        event_id     UUID NOT NULL DEFAULT gen_random_uuid(),
        tenant_id    UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid,
        at           TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
        actor_kind   TEXT NOT NULL,
        actor_ref    TEXT NOT NULL,
        action       TEXT NOT NULL,
        outcome      TEXT NOT NULL,
        object_kind  TEXT NOT NULL,
        object_id    TEXT,
        fields       TEXT[] NOT NULL DEFAULT '{}',
        reason       TEXT,
        request_id   TEXT,
        created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
        created_by   TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
        object_ids   TEXT[] NOT NULL DEFAULT '{}',
        CONSTRAINT audit_event_pkey PRIMARY KEY (event_id, at),
        CONSTRAINT audit_event_tenant_fk FOREIGN KEY (tenant_id) REFERENCES crm.tenant (tenant_id),
        CONSTRAINT audit_event_actor_kind_chk CHECK (
            actor_kind IN ('user', 'traveler', 'ai_agent', 'aa_ops', 'aa_staff', 'support', 'breakglass', 'system')
        ),
        CONSTRAINT audit_event_actor_ref_chk CHECK (actor_ref ~ '^[A-Za-z0-9:_-]{1,80}$'),
        CONSTRAINT audit_event_action_chk CHECK (action ~ '^[a-z][a-z0-9_]{0,39}$'),
        CONSTRAINT audit_event_outcome_chk CHECK (outcome IN ('allowed', 'denied')),
        CONSTRAINT audit_event_object_kind_chk CHECK (object_kind ~ '^[a-z][a-z0-9_]{0,39}$'),
        CONSTRAINT audit_event_object_id_chk CHECK (object_id IS NULL OR object_id ~ '^[A-Za-z0-9:_-]{1,80}$'),
        CONSTRAINT audit_event_fields_chk CHECK (
            cardinality(fields) <= 32 AND array_to_string(fields, ',', '!') ~ '^([a-z][a-z0-9_]{0,62}(,|$))*$'
        ),
        CONSTRAINT audit_event_reason_chk CHECK (reason IS NULL OR reason ~ '^[a-z][a-z0-9_]{0,63}$'),
        CONSTRAINT audit_event_request_id_chk CHECK (request_id IS NULL OR request_id ~ '^[A-Za-z0-9._:-]{1,128}$'),
        CONSTRAINT audit_event_object_ids_chk CHECK (
            cardinality(object_ids) <= 200
            AND array_to_string(object_ids, ',', '!') ~ '^([A-Za-z0-9:_-]{1,80}(,|$))*$'
        )
    ) PARTITION BY RANGE (at);
    -- Same names and definitions as crm-003, so ATTACH reuses the legacy indexes instead of building new ones.
    CREATE INDEX audit_event_tenant_at_idx ON crm.audit_event (tenant_id, at DESC);
    CREATE INDEX audit_event_object_idx ON crm.audit_event (tenant_id, object_kind, object_id);
    EXECUTE format(
        'ALTER TABLE crm.audit_event ATTACH PARTITION crm.audit_event_legacy FOR VALUES FROM (MINVALUE) TO (%L)',
        v_upper
    );
    -- (ATTACH merged the legacy tenant foreign key into the parent's: it is now the inherited one.)
    REVOKE ALL ON crm.audit_event_legacy FROM crm_app;
END $$;

ALTER TABLE crm.audit_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.audit_event FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.audit_event;
CREATE POLICY tenant_isolation ON crm.audit_event
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

-- Explicit `at` only from the owner (tests, a future restore); the app never sends one.
CREATE OR REPLACE FUNCTION crm.audit_event_check_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF current_user <> 'crm_owner'
       AND (NEW.at < clock_timestamp() - interval '1 minute' OR NEW.at > clock_timestamp() + interval '1 minute') THEN
        RAISE EXCEPTION 'crm: audit_event.at is the insert time; an explicit value is refused'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.audit_event_check_at() FROM PUBLIC;

CREATE OR REPLACE TRIGGER audit_event_append_only
    BEFORE UPDATE OR DELETE ON crm.audit_event
    FOR EACH ROW EXECUTE FUNCTION crm.reject_append_only_change();
CREATE OR REPLACE TRIGGER audit_event_no_truncate
    BEFORE TRUNCATE ON crm.audit_event
    FOR EACH STATEMENT EXECUTE FUNCTION crm.reject_append_only_change();
CREATE OR REPLACE TRIGGER audit_event_check_at
    BEFORE INSERT ON crm.audit_event
    FOR EACH ROW EXECUTE FUNCTION crm.audit_event_check_at();
REVOKE UPDATE, DELETE, TRUNCATE ON crm.audit_event FROM crm_app;

COMMENT ON TABLE crm.audit_event IS 'AA-934 (crm-003) / AA-940 (crm-007): the agency audit (F5), append-only, PARTITION BY RANGE (at), one partition per UTC month (crm.audit_ensure_partitions). crm_app INSERT + SELECT on this parent only; a trigger refuses UPDATE, DELETE and TRUNCATE. Codes and random ids only, never personal data. Retention: 12 months, whole partitions dropped by crm.audit_drop_expired_partitions only after the hourly export (crm.audit_export_manifest, two Object Lock buckets) is verified (data standards §7 row crm.audit_event).';
COMMENT ON COLUMN crm.audit_event.at IS 'insert time (clock_timestamp()); an explicit value is refused unless the writer is crm_owner (crm.audit_event_check_at), so no event lands in an hour that is already exported';
COMMENT ON COLUMN crm.audit_event.actor_ref IS 'a random id only (member:<uuid>, job:<kind>, ai:<stage>), never a name or an e-mail';
COMMENT ON COLUMN crm.audit_event.fields IS 'column names touched (for example display_name_enc), never values';
COMMENT ON COLUMN crm.audit_event.reason IS 'a reason code (integrity_check_failed, tenant_mismatch, ...), never free text';
COMMENT ON COLUMN crm.audit_event.object_ids IS 'AA-937 (crm-006): the ids a list view showed (action list_view, design §4.4), at most 200; ids only, never values';

-- ── 2. Partition bounds and the monthly partition maker ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.audit_partition_bounds()
    RETURNS TABLE (partition_name text, range_start timestamptz, range_end timestamptz)
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog
    SET "TimeZone" = 'UTC'
AS $$
    SELECT c.relname::text,
           CASE WHEN b.m[1] = 'MINVALUE' THEN NULL ELSE trim(both '''' FROM b.m[1])::timestamptz END,
           trim(both '''' FROM b.m[2])::timestamptz
      FROM pg_catalog.pg_inherits i
      JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid
     CROSS JOIN LATERAL (
           SELECT regexp_match(pg_catalog.pg_get_expr(c.relpartbound, c.oid),
                               'FROM \((MINVALUE|''[^'']*'')\) TO \((''[^'']*'')\)') AS m
     ) b
     WHERE i.inhparent = 'crm.audit_event'::regclass
     ORDER BY 3;
$$;
REVOKE ALL ON FUNCTION crm.audit_partition_bounds() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.audit_partition_bounds() TO crm_app;
COMMENT ON FUNCTION crm.audit_partition_bounds() IS 'AA-940 (crm-007): the partitions of crm.audit_event and their [range_start, range_end) (range_start NULL = MINVALUE). Catalog data only; the job metrics sampler reads it (months ahead).';

CREATE OR REPLACE FUNCTION crm.audit_ensure_partitions() RETURNS integer
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog
    SET "TimeZone" = 'UTC'
    -- CREATE TABLE ... PARTITION OF locks the parent: wait at most 2 s behind a long reader instead of queueing every
    -- audit insert (bound by the app pool's 5 s command timeout) behind this statement. The hourly job retries.
    SET lock_timeout = '2s'
AS $$
DECLARE
    v_base timestamp := date_trunc('month', now() AT TIME ZONE 'UTC');
    v_start timestamptz;
    v_end timestamptz;
    v_name text;
    v_created integer := 0;
BEGIN
    FOR i IN 0..3 LOOP
        v_start := (v_base + make_interval(months => i)) AT TIME ZONE 'UTC';
        v_end := (v_base + make_interval(months => i + 1)) AT TIME ZONE 'UTC';
        CONTINUE WHEN EXISTS (
            SELECT 1 FROM crm.audit_partition_bounds() b
             WHERE (b.range_start IS NULL OR b.range_start < v_end) AND b.range_end > v_start
        );
        v_name := 'audit_event_p' || to_char(v_start, 'YYYYMM');
        EXECUTE format('CREATE TABLE crm.%I PARTITION OF crm.audit_event FOR VALUES FROM (%L) TO (%L)',
                       v_name, v_start, v_end);
        EXECUTE format('ALTER TABLE crm.%I ENABLE ROW LEVEL SECURITY', v_name);
        EXECUTE format('ALTER TABLE crm.%I FORCE ROW LEVEL SECURITY', v_name);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON crm.%I '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)', v_name);
        EXECUTE format('CREATE TRIGGER audit_event_no_truncate BEFORE TRUNCATE ON crm.%I '
                       'FOR EACH STATEMENT EXECUTE FUNCTION crm.reject_append_only_change()', v_name);
        -- The schema's default privileges give crm_app DML on every new table: a partition is reached through the
        -- parent only.
        EXECUTE format('REVOKE ALL ON crm.%I FROM crm_app', v_name);
        EXECUTE format('COMMENT ON TABLE crm.%I IS %L', v_name,
                       'AA-940 (crm-007): one UTC month of crm.audit_event (append-only); reached through the parent only; dropped as a whole by crm.audit_drop_expired_partitions');
        v_created := v_created + 1;
    END LOOP;
    RETURN v_created;
END;
$$;
REVOKE ALL ON FUNCTION crm.audit_ensure_partitions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.audit_ensure_partitions() TO crm_app;
COMMENT ON FUNCTION crm.audit_ensure_partitions() IS 'AA-940 (crm-007): creates the missing monthly partitions of crm.audit_event from the current UTC month to three months ahead (FORCE RLS, tenant policy, TRUNCATE trigger, no crm_app privilege). Returns how many it created. lock_timeout 2 s (the parent lock); run by the hourly crm_audit_export job, which retries.';

SELECT crm.audit_ensure_partitions();

-- ── 4. crm.audit_export_tenant (platform registry, ids and times only) ───────────────────────────
-- Created before the drop function, which reads it.
CREATE TABLE IF NOT EXISTS crm.audit_export_tenant (
    tenant_id       UUID PRIMARY KEY REFERENCES crm.tenant (tenant_id) ON DELETE CASCADE,
    exported_until  TIMESTAMPTZ NOT NULL,
    verified_until  TIMESTAMPTZ,
    last_seq        BIGINT NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT audit_export_tenant_hour_chk CHECK (
        exported_until = date_trunc('hour', exported_until AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
        AND (verified_until IS NULL
             OR verified_until = date_trunc('hour', verified_until AT TIME ZONE 'UTC') AT TIME ZONE 'UTC')
    ),
    CONSTRAINT audit_export_tenant_verified_chk CHECK (verified_until IS NULL OR verified_until <= exported_until),
    CONSTRAINT audit_export_tenant_seq_chk CHECK (last_seq >= 0)
);
-- crm_app: SELECT its row, INSERT a new agency's row (the tenant trigger runs as the inserter) and move the export
-- marks only. `verified_until` moves through crm.audit_mark_verified() (below), which keeps it monotonic and never past
-- `exported_until`; there is no table-level UPDATE and no DELETE / TRUNCATE.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON crm.audit_export_tenant FROM crm_app;
GRANT INSERT (tenant_id, exported_until) ON crm.audit_export_tenant TO crm_app;
GRANT UPDATE (exported_until, last_seq) ON crm.audit_export_tenant TO crm_app;
-- ENABLE without FORCE, on purpose: crm_app sees and updates only the row of app.tenant_id (the export works inside
-- one agency's context), while the owner's SECURITY DEFINER functions below (the agency list for the export job, the
-- retention check) read every row. The tenant policy keeps the catalogue rule a ("tenant_id table without RLS").
ALTER TABLE crm.audit_export_tenant ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.audit_export_tenant NO FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.audit_export_tenant;
CREATE POLICY tenant_isolation ON crm.audit_export_tenant
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE OR REPLACE TRIGGER audit_export_tenant_set_updated_at
    BEFORE UPDATE ON crm.audit_export_tenant
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
COMMENT ON TABLE crm.audit_export_tenant IS 'AA-940 (crm-007): platform registry of the hourly audit export, one row per agency (ids and times only). RLS enabled, not forced: crm_app sees the row of app.tenant_id; the owner functions crm.audit_export_agencies / crm.audit_drop_expired_partitions read all rows. exported_until = end of the last exported hour, verified_until = end of the last hour the daily verification confirmed (crm.audit_drop_expired_partitions needs every agency verified past a partition). Written by the tenant insert trigger and the crm_audit_export / crm_audit_retention jobs; ON DELETE CASCADE with the tenant row.';

CREATE OR REPLACE FUNCTION crm.audit_register_tenant() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    INSERT INTO crm.audit_export_tenant (tenant_id, exported_until)
    VALUES (NEW.tenant_id, date_trunc('hour', clock_timestamp() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC')
    ON CONFLICT (tenant_id) DO NOTHING;
    RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION crm.audit_register_tenant() FROM PUBLIC;
CREATE OR REPLACE TRIGGER tenant_audit_register
    AFTER INSERT ON crm.tenant
    FOR EACH ROW EXECUTE FUNCTION crm.audit_register_tenant();

-- The agency list for the export job and the metrics sampler (crm_app cannot list crm.tenant or the registry: RLS).
CREATE OR REPLACE FUNCTION crm.audit_export_agencies()
    RETURNS TABLE (tenant_id uuid, exported_until timestamptz, verified_until timestamptz, last_seq bigint,
                   registered_at timestamptz)
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog
AS $$
    SELECT x.tenant_id, x.exported_until, x.verified_until, x.last_seq, x.created_at
      FROM crm.audit_export_tenant x
     ORDER BY x.tenant_id;
$$;
REVOKE ALL ON FUNCTION crm.audit_export_agencies() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.audit_export_agencies() TO crm_app;
COMMENT ON FUNCTION crm.audit_export_agencies() IS 'AA-940 (crm-007): every agency of the audit export registry with its export / verification marks and registration time (ids and times only). Used by the crm_audit_export / crm_audit_retention jobs and the metrics sampler.';

-- The only way `verified_until` moves (crm_app has no UPDATE on it): in the agency of app.tenant_id, forward only, never
-- past `exported_until`. Returns true when the mark moved. The caller (crm_audit_retention) calls it only after the
-- verification of both archived copies passed; the database cannot re-check the buckets (accepted risk, AA-940 notes).
CREATE OR REPLACE FUNCTION crm.audit_mark_verified(p_until timestamptz) RETURNS boolean
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
BEGIN
    IF v_tenant IS NULL OR p_until IS NULL THEN
        RAISE EXCEPTION 'crm: audit_mark_verified needs app.tenant_id and a time' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    UPDATE crm.audit_export_tenant x SET verified_until = p_until
     WHERE x.tenant_id = v_tenant
       AND (x.verified_until IS NULL OR x.verified_until < p_until)
       AND p_until <= x.exported_until;
    RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION crm.audit_mark_verified(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.audit_mark_verified(timestamptz) TO crm_app;
COMMENT ON FUNCTION crm.audit_mark_verified(timestamptz) IS 'AA-940 (crm-007): moves verified_until of the agency of app.tenant_id forward, never past exported_until (crm_app has no UPDATE on that column). Called by crm_audit_retention after the database rows, the chain and both archived copies verified.';

-- Backfill: every existing agency, exported from the hour of its first event (or this hour when it has none).
-- FORCE RLS binds the owner, so it is lifted for this one statement and restored at once (same transaction).
ALTER TABLE crm.tenant NO FORCE ROW LEVEL SECURITY;
ALTER TABLE crm.audit_event NO FORCE ROW LEVEL SECURITY;
INSERT INTO crm.audit_export_tenant (tenant_id, exported_until)
SELECT t.tenant_id,
       date_trunc('hour', COALESCE((SELECT min(e.at) FROM crm.audit_event e WHERE e.tenant_id = t.tenant_id),
                                   clock_timestamp()) AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
  FROM crm.tenant t
ON CONFLICT (tenant_id) DO NOTHING;
ALTER TABLE crm.tenant FORCE ROW LEVEL SECURITY;
ALTER TABLE crm.audit_event FORCE ROW LEVEL SECURITY;

-- ── 3. Retention: whole partitions, only after verification ──────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.audit_drop_expired_partitions(p_dry_run boolean DEFAULT true)
    RETURNS TABLE (partition_name text, range_end timestamptz, action text)
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog
    SET "TimeZone" = 'UTC'
AS $$
DECLARE
    -- The agency sees at least 12 months: a partition goes when it ends at or before the start of the UTC month
    -- twelve months ago.
    v_cutoff timestamptz := (date_trunc('month', now() AT TIME ZONE 'UTC') - interval '12 months') AT TIME ZONE 'UTC';
    r record;
BEGIN
    IF p_dry_run IS NULL THEN
        RAISE EXCEPTION 'crm: dry_run must be true or false';
    END IF;
    FOR r IN SELECT b.partition_name, b.range_end FROM crm.audit_partition_bounds() b
              WHERE b.range_end <= v_cutoff ORDER BY b.range_end LOOP
        partition_name := r.partition_name;
        range_end := r.range_end;
        IF EXISTS (SELECT 1 FROM crm.audit_export_tenant x
                    WHERE x.verified_until IS NULL OR x.verified_until < r.range_end) THEN
            action := 'kept_unverified';
        ELSIF p_dry_run THEN
            action := 'would_drop';
        ELSE
            -- DROP fires no row trigger: every row the database keeps stays append-only.
            EXECUTE format('DROP TABLE crm.%I', r.partition_name);
            action := 'dropped';
        END IF;
        RETURN NEXT;
    END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION crm.audit_drop_expired_partitions(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.audit_drop_expired_partitions(boolean) TO crm_app;
COMMENT ON FUNCTION crm.audit_drop_expired_partitions(boolean) IS 'AA-940 (crm-007): the only retention path of crm.audit_event. Drops a whole partition when it ends at or before the start of the UTC month twelve months ago AND every agency in crm.audit_export_tenant is verified up to its end (DM-7). Dry run reports only (would_drop / kept_unverified). Run by the daily crm_audit_retention job.';

-- ── 5. crm.audit_export_manifest (the hash chain) ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.audit_export_manifest (
    manifest_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- No foreign key to crm.tenant: the manifest follows the archive (seven years) and outlives an offboarded agency.
    tenant_id             UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid,
    seq                   BIGINT NOT NULL,
    period_start          TIMESTAMPTZ NOT NULL,
    period_end            TIMESTAMPTZ NOT NULL,
    event_count           INTEGER NOT NULL,
    content_sha256        TEXT NOT NULL,
    prev_manifest_sha256  TEXT NOT NULL,
    manifest_sha256       TEXT NOT NULL,
    object_key            TEXT NOT NULL,
    object_sha256         TEXT NOT NULL,
    format_version        SMALLINT NOT NULL DEFAULT 1,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    CONSTRAINT audit_export_manifest_seq_uq UNIQUE (tenant_id, seq),
    CONSTRAINT audit_export_manifest_period_uq UNIQUE (tenant_id, period_start),
    CONSTRAINT audit_export_manifest_seq_chk CHECK (seq >= 1),
    CONSTRAINT audit_export_manifest_period_chk CHECK (
        period_end > period_start
        AND period_start = date_trunc('hour', period_start AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
        AND period_end = date_trunc('hour', period_end AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
    ),
    CONSTRAINT audit_export_manifest_count_chk CHECK (event_count >= 0),
    CONSTRAINT audit_export_manifest_hashes_chk CHECK (
        content_sha256 ~ '^[0-9a-f]{64}$' AND prev_manifest_sha256 ~ '^[0-9a-f]{64}$'
        AND manifest_sha256 ~ '^[0-9a-f]{64}$' AND object_sha256 ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT audit_export_manifest_key_chk CHECK (
        object_key LIKE 'audit/v1/tenants/' || tenant_id::text || '/%'
        AND object_key ~ '^audit/v1/tenants/[0-9a-f-]{36}/[0-9]{4}/[0-9]{2}/[0-9]{2}/[0-9]{4}Z-[0-9]{10}\.jsonl$'
    ),
    CONSTRAINT audit_export_manifest_format_chk CHECK (format_version = 1)
);

ALTER TABLE crm.audit_export_manifest ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.audit_export_manifest FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.audit_export_manifest;
CREATE POLICY tenant_isolation ON crm.audit_export_manifest
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

-- The chain in the database: a row must continue the agency's last one (the export locks the registry row first).
CREATE OR REPLACE FUNCTION crm.audit_manifest_chain() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_prev record;
BEGIN
    SELECT m.seq, m.manifest_sha256, m.period_end INTO v_prev
      FROM crm.audit_export_manifest m
     WHERE m.tenant_id = NEW.tenant_id
     ORDER BY m.seq DESC
     LIMIT 1;
    IF NOT FOUND THEN
        IF NEW.seq <> 1 OR NEW.prev_manifest_sha256 <> repeat('0', 64) THEN
            RAISE EXCEPTION 'crm: the first manifest of an agency is seq 1 with a zero previous hash'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF NEW.seq <> v_prev.seq + 1 OR NEW.prev_manifest_sha256 <> v_prev.manifest_sha256
          OR NEW.period_start <> v_prev.period_end THEN
        RAISE EXCEPTION 'crm: a manifest must continue the chain (seq %, previous hash, period from %)',
            v_prev.seq + 1, v_prev.period_end
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.audit_manifest_chain() FROM PUBLIC;

CREATE OR REPLACE TRIGGER audit_export_manifest_chain
    BEFORE INSERT ON crm.audit_export_manifest
    FOR EACH ROW EXECUTE FUNCTION crm.audit_manifest_chain();
CREATE OR REPLACE TRIGGER audit_export_manifest_append_only
    BEFORE UPDATE OR DELETE ON crm.audit_export_manifest
    FOR EACH ROW EXECUTE FUNCTION crm.reject_append_only_change();
CREATE OR REPLACE TRIGGER audit_export_manifest_no_truncate
    BEFORE TRUNCATE ON crm.audit_export_manifest
    FOR EACH STATEMENT EXECUTE FUNCTION crm.reject_append_only_change();
REVOKE UPDATE, DELETE, TRUNCATE ON crm.audit_export_manifest FROM crm_app;

COMMENT ON TABLE crm.audit_export_manifest IS 'AA-940 (crm-007): the hourly audit export chain, one row per agency per hour (design §4.9). manifest_sha256 = SHA-256 of the canonical manifest (format 1: tenant, seq, period, count, content hash, previous hash); content_sha256 = SHA-256 of the event lines of the object; object_sha256 = SHA-256 of the object written to both Object Lock buckets under object_key. Append-only; a trigger refuses a row that does not continue the chain. No foreign key to crm.tenant: kept with the archive (DM-7).';
COMMENT ON COLUMN crm.audit_export_manifest.prev_manifest_sha256 IS '64 zeros for seq 1, else the manifest_sha256 of seq - 1 (crm.audit_manifest_chain)';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    p text;
    r text;
    part record;
BEGIN
    IF (SELECT relkind FROM pg_catalog.pg_class WHERE oid = 'crm.audit_event'::regclass) <> 'p' THEN
        RAISE EXCEPTION 'crm-007: crm.audit_event must be partitioned';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.tenant', 'crm.audit_event', 'crm.audit_export_manifest'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = t::regclass) THEN
            RAISE EXCEPTION 'crm-007: % must have ENABLE + FORCE row level security', t;
        END IF;
    END LOOP;
    -- Append-only for the runtime role (card R test: UPDATE as crm_app -> error).
    FOREACH t IN ARRAY ARRAY['crm.audit_event', 'crm.audit_export_manifest'] LOOP
        IF NOT (pg_catalog.has_table_privilege('crm_app', t, 'INSERT')
                AND pg_catalog.has_table_privilege('crm_app', t, 'SELECT')) THEN
            RAISE EXCEPTION 'crm-007: crm_app must INSERT and SELECT %', t;
        END IF;
        FOREACH p IN ARRAY ARRAY['UPDATE', 'DELETE', 'TRUNCATE'] LOOP
            IF pg_catalog.has_table_privilege('crm_app', t, p) THEN
                RAISE EXCEPTION 'crm-007: crm_app may % % (append-only)', p, t;
            END IF;
        END LOOP;
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, t, p) THEN
                    RAISE EXCEPTION 'crm-007: % may % on %', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
    -- Every partition: forced RLS with the tenant policy, no crm_app privilege, both append-only triggers.
    FOR part IN SELECT c.oid, c.relname, c.relrowsecurity, c.relforcerowsecurity
                  FROM pg_catalog.pg_inherits i JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid
                 WHERE i.inhparent = 'crm.audit_event'::regclass LOOP
        IF NOT (part.relrowsecurity AND part.relforcerowsecurity) THEN
            RAISE EXCEPTION 'crm-007: partition % must have ENABLE + FORCE row level security', part.relname;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy WHERE polrelid = part.oid AND polname = 'tenant_isolation') THEN
            RAISE EXCEPTION 'crm-007: partition % lacks the tenant_isolation policy', part.relname;
        END IF;
        FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
            IF pg_catalog.has_table_privilege('crm_app', part.oid, p) THEN
                RAISE EXCEPTION 'crm-007: crm_app may % partition % (reach it through the parent)', p, part.relname;
            END IF;
        END LOOP;
        IF (SELECT count(*) FROM pg_catalog.pg_trigger g
             WHERE g.tgrelid = part.oid AND NOT g.tgisinternal
               AND g.tgfoid = 'crm.reject_append_only_change()'::regprocedure) <> 2 THEN
            RAISE EXCEPTION 'crm-007: partition % lacks the append-only triggers', part.relname;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM crm.audit_partition_bounds() b WHERE b.range_end > now() + interval '2 months') = 0 THEN
        RAISE EXCEPTION 'crm-007: crm.audit_event has no partition two months ahead';
    END IF;
    IF NOT (SELECT relrowsecurity AND NOT relforcerowsecurity FROM pg_catalog.pg_class
             WHERE oid = 'crm.audit_export_tenant'::regclass) THEN
        RAISE EXCEPTION 'crm-007: crm.audit_export_tenant must have RLS enabled and not forced';
    END IF;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.audit_export_tenant', 'DELETE')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.audit_export_tenant', 'UPDATE')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.audit_export_tenant', 'TRUNCATE')
       OR pg_catalog.has_column_privilege('crm_app', 'crm.audit_export_tenant', 'verified_until', 'UPDATE')
       OR pg_catalog.has_column_privilege('crm_app', 'crm.audit_export_tenant', 'verified_until', 'INSERT')
       OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.audit_export_tenant', 'SELECT')
       OR NOT pg_catalog.has_column_privilege('crm_app', 'crm.audit_export_tenant', 'exported_until', 'UPDATE')
       OR NOT pg_catalog.has_column_privilege('crm_app', 'crm.audit_export_tenant', 'last_seq', 'UPDATE')
       OR NOT pg_catalog.has_column_privilege('crm_app', 'crm.audit_export_tenant', 'tenant_id', 'INSERT') THEN
        RAISE EXCEPTION 'crm-007: crm_app must SELECT, INSERT (tenant_id, exported_until) and UPDATE (exported_until, last_seq) only on crm.audit_export_tenant (verified_until through crm.audit_mark_verified)';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-007: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.audit_event_check_at()', 'crm.audit_partition_bounds()',
                             'crm.audit_ensure_partitions()', 'crm.audit_drop_expired_partitions(boolean)',
                             'crm.audit_register_tenant()', 'crm.audit_manifest_chain()',
                             'crm.audit_export_agencies()', 'crm.audit_mark_verified(timestamptz)'] LOOP
        IF pg_catalog.has_function_privilege('public', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-007: % is executable by PUBLIC (SEC-4)', t;
        END IF;
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            IF pg_catalog.has_function_privilege(r, t, 'EXECUTE') THEN
                RAISE EXCEPTION 'crm-007: % may execute %', r, t;
            END IF;
        END LOOP;
    END LOOP;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-007', now(), 'AA-940: audit_event monthly partitions (crm-003 table attached as the first), partition maker + verified drop, audit_export_tenant registry, audit_export_manifest hash chain')
ON CONFLICT (version) DO NOTHING;

COMMIT;
