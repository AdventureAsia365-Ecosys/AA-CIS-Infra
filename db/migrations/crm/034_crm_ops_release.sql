-- migrate: expand
-- Migration crm-034: AA-956 CRM-26 Module 8 AA ops release (design v3 M8, Fix B2, Fix B3, R33, R44 data, C12;
-- data-privacy-integrations §2.10 group I `ops_release` / `supplier_manifest_export`, §4 retention "trip end + 90 days,
-- then purge + deletion receipt") — the traveller details AA ground operations need to run a confirmed AA departure,
-- kept in the CRM under the agency's `ops_release` key, read by AA ops (WORKFORCE group crm-ops) inside AA-Partner with
-- one agency audit line per view, a minimal supplier manifest, and a purge at return + 90 days with a receipt.
--
-- Owner: AA-Partner (api/migrations/034_crm_ops_release.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-034, after crm-033 (AA-971 support access, a contract file); if
-- main moves, renumber: file name, this header, the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS.
--
-- What (DM-7: both tables already have their row in root data standards Part B §7: "trip end + 90 days, then purge with
-- a deletion receipt; revoked at once when the trip is cancelled before it starts"):
--   1. crm.ops_release (base template): at most one live release per trip (partial unique on purged_at IS NULL; a
--      purged row stays as its receipt). created_on = 'aa_line_confirmed' (Fix B2: a release exists only once an AA
--      line of the trip is confirmed; the crm_ops_release_sync job is the only writer of a new row). payload_enc: the
--      release document (names, age band, dietary / mobility codes, flights, insurance choice, the AA lines) under the
--      agency's ops_release DEK (AAD = tenant, ops_release, payload_enc, row id); payload_version moves up on every
--      change (payload refresh as Stage 3 fills in); fields_released (codes), completeness (counts per missing item)
--      and complete (the S-02 indicator); departure_ids / bk_booking_ids (Booking's ids, for the link to the Booking
--      incident admin, Fix B3), start_date / end_date (copied from the trip), purge_at = end_date + 90 days
--      (recomputed when the dates move), t21_alerted_at (the T-21 alert, once), withdrawn_at + withdraw_reason (C12
--      cancel, or no confirmed AA line left), purged_at + purge_reason + deletion_receipt (counts only), view_count /
--      last_viewed_at (AA ops views; the agency audit holds each view).
--   2. crm.supplier_manifest_export (base template): one minimal manifest AA ops exported (A:3.10): which payload
--      version, the field codes, the format (csv), row count and the watermark printed on it. No personal data: the
--      file itself is never stored. Deleted with the release's purge (counted on the receipt).
--   3. Erasure without a replaced crm.erase_subject (the crm-029 pattern): crm.ops_release cascades from its trip,
--      crm.supplier_manifest_export from its release, so a trip or agency erase removes both and the agency erase's
--      "nothing left" check finds none. tests/integration/test_crm010_schema.py lists both as cascade-erased.
--   4. Write guards (SQLSTATE CRM45 ops_release_guard; crm-033 used CRM43 / CRM44): crm.guard_ops_release —
--      a release is created by a job actor only (job:); its trip, creation reason and release time never change; a
--      purged row is sealed; payload_version only moves up; AA ops (actor ops:) change only view_count (by one) and
--      last_viewed_at; a member (C12 withdraw) only withdraws (the job purges right after); a withdrawal is
--      lifted only by a job and only when its reason was aa_lines_cancelled (a new AA line confirmed); no crm_app
--      DELETE (a row leaves with its trip); the hold rule: a purge of a held trip's release is refused (CRM10).
--      crm.guard_supplier_manifest_export — inserted by AA ops (ops:) only, never updated, deleted by a job (the
--      purge) unless its trip is held; a cascade (trigger depth > 1) passes both guards: the parent row's guard and
--      crm.erase_held ruled (crm.guard_held_flight comment, crm-029).
--   5. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles); crm_app keeps the default DML of crm-001 (the guards
--      decide); no reader grant: AI, insights and support never see a release (design §4.3, the isolation probe).
--
-- Class: expand (root ADR 0017 d3): two new tables and two new trigger functions with their constraints, indexes,
-- triggers, policies and comments; foreign keys from the new tables (the RI triggers they add on crm.trip and
-- crm.tenant are allowed); no change to an existing object, no DO block, no CREATE OR REPLACE. DB Migrate never
-- applies a registered file twice and the test conftest skips it. The code PR carries this file and raises
-- REQUIRED_SCHEMA_VERSIONS to crm-034 (expand: one PR). The auto-apply stops at an unapplied contract file, so crm-033
-- is applied by hand first.
--
-- Rollback (a forward crm- file, after the code that reads it is reverted): DROP TABLE crm.supplier_manifest_export;
-- DROP TABLE crm.ops_release; DROP FUNCTION crm.guard_supplier_manifest_export(); DROP FUNCTION crm.guard_ops_release().
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- ── 1. crm.ops_release ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.ops_release (
    ops_release_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                      REFERENCES crm.tenant (tenant_id),
    trip_id           UUID NOT NULL,
    created_on        TEXT NOT NULL DEFAULT 'aa_line_confirmed',
    payload_enc       BYTEA,
    payload_version   INTEGER NOT NULL DEFAULT 1,
    fields_released   TEXT[] NOT NULL DEFAULT '{}',
    completeness      JSONB NOT NULL DEFAULT '{}'::jsonb,
    complete          BOOLEAN NOT NULL DEFAULT false,
    traveller_count   SMALLINT NOT NULL DEFAULT 0,
    departure_ids     TEXT[] NOT NULL DEFAULT '{}',
    bk_booking_ids    TEXT[] NOT NULL DEFAULT '{}',
    start_date        DATE,
    end_date          DATE,
    released_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    refreshed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    purge_at          DATE,
    t21_alerted_at    TIMESTAMPTZ,
    withdrawn_at      TIMESTAMPTZ,
    withdraw_reason   TEXT,
    purged_at         TIMESTAMPTZ,
    purge_reason      TEXT,
    deletion_receipt  JSONB,
    view_count        INTEGER NOT NULL DEFAULT 0,
    last_viewed_at    TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,
    deleted_by        TEXT,
    purge_after       TIMESTAMPTZ,
    CONSTRAINT ops_release_tenant_id_uq UNIQUE (tenant_id, ops_release_id),
    CONSTRAINT ops_release_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT ops_release_created_on_chk CHECK (created_on = 'aa_line_confirmed'),
    CONSTRAINT ops_release_version_chk CHECK (payload_version >= 1),
    -- A live release holds its document; a purged one holds its receipt instead (both or neither).
    CONSTRAINT ops_release_purge_chk CHECK (
        (purged_at IS NULL) = (payload_enc IS NOT NULL)
        AND (purged_at IS NULL) = (purge_reason IS NULL)
        AND (purged_at IS NULL) = (deletion_receipt IS NULL)
        AND (purge_reason IS NULL OR purge_reason IN ('retention', 'withdrawn'))
        AND (deletion_receipt IS NULL OR jsonb_typeof(deletion_receipt) = 'object')
    ),
    CONSTRAINT ops_release_enc_chk CHECK (payload_enc IS NULL OR octet_length(payload_enc) >= 30),
    CONSTRAINT ops_release_withdraw_chk CHECK (
        (withdrawn_at IS NULL) = (withdraw_reason IS NULL)
        AND (withdraw_reason IS NULL OR withdraw_reason IN ('trip_cancelled', 'aa_lines_cancelled', 'agency_withdrawn'))
    ),
    CONSTRAINT ops_release_fields_chk CHECK (
        cardinality(fields_released) <= 32
        AND array_to_string(fields_released, ',', '!') ~ '^([a-z][a-z0-9_]{0,39}(,|$))*$'
    ),
    CONSTRAINT ops_release_completeness_chk CHECK (jsonb_typeof(completeness) = 'object'),
    CONSTRAINT ops_release_counts_chk CHECK (traveller_count BETWEEN 0 AND 200 AND view_count >= 0),
    -- Booking's ids, the crm.booking_line_refs_chk shape.
    CONSTRAINT ops_release_refs_chk CHECK (
        cardinality(departure_ids) <= 50 AND cardinality(bk_booking_ids) <= 50
        AND array_to_string(departure_ids, ',', '!') ~ '^([A-Za-z0-9:_.-]{1,80}(,|$))*$'
        AND array_to_string(bk_booking_ids, ',', '!') ~ '^([A-Za-z0-9:_.-]{1,80}(,|$))*$'
    ),
    CONSTRAINT ops_release_dates_chk CHECK (start_date IS NULL OR end_date IS NULL OR end_date >= start_date),
    CONSTRAINT ops_release_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS ops_release_live_uq ON crm.ops_release (tenant_id, trip_id) WHERE purged_at IS NULL;
CREATE INDEX IF NOT EXISTS ops_release_trip_idx ON crm.ops_release (trip_id);
-- The S-02 board (live releases by departure date) and the purge (due dates).
CREATE INDEX IF NOT EXISTS ops_release_start_idx ON crm.ops_release (tenant_id, start_date) WHERE purged_at IS NULL;
CREATE INDEX IF NOT EXISTS ops_release_purge_idx ON crm.ops_release (tenant_id, purge_at) WHERE purged_at IS NULL;

ALTER TABLE crm.ops_release ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.ops_release FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.ops_release
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE TRIGGER ops_release_set_updated_at
    BEFORE UPDATE ON crm.ops_release
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();

CREATE FUNCTION crm.guard_ops_release() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    -- The columns a view or a withdrawal may change; everything else must stay as it was.
    v_view_cols text[] := ARRAY['view_count', 'last_viewed_at', 'updated_at'];
    v_withdraw_cols text[] := ARRAY['withdrawn_at', 'withdraw_reason', 'updated_at'];
BEGIN
    -- A cascade from the trip (an erase, trigger depth > 1) passes: the trip's own guard and crm.erase_held ruled.
    IF pg_catalog.pg_trigger_depth() > 1 OR current_user = 'crm_owner' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF v_actor NOT LIKE 'job:%' THEN
            RAISE EXCEPTION 'crm: ops_release_guard (a release is created by the release job only, actor %)', v_actor
                USING ERRCODE = 'CRM45';
        END IF;
        IF NEW.purged_at IS NOT NULL OR NEW.withdrawn_at IS NOT NULL OR NEW.view_count <> 0 THEN
            RAISE EXCEPTION 'crm: ops_release_guard (a new release is live, unviewed and not withdrawn)'
                USING ERRCODE = 'CRM45';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'crm: ops_release_guard (a release leaves only with its trip; a purge keeps the receipt row)'
            USING ERRCODE = 'CRM45';
    END IF;
    -- UPDATE
    IF (NEW.ops_release_id, NEW.tenant_id, NEW.trip_id, NEW.created_on, NEW.released_at, NEW.created_at, NEW.created_by)
       IS DISTINCT FROM
       (OLD.ops_release_id, OLD.tenant_id, OLD.trip_id, OLD.created_on, OLD.released_at, OLD.created_at, OLD.created_by)
    THEN
        RAISE EXCEPTION 'crm: ops_release_guard (a release''s trip, reason and release time never change)'
            USING ERRCODE = 'CRM45';
    END IF;
    IF OLD.purged_at IS NOT NULL THEN
        RAISE EXCEPTION 'crm: ops_release_guard (a purged release is a sealed receipt)' USING ERRCODE = 'CRM45';
    END IF;
    IF NEW.payload_version < OLD.payload_version THEN
        RAISE EXCEPTION 'crm: ops_release_guard (payload_version only moves up)' USING ERRCODE = 'CRM45';
    END IF;
    IF NEW.purged_at IS NOT NULL AND crm.hold_row(OLD.trip_id, NULL) THEN
        RAISE EXCEPTION 'crm: legal_hold (purge of a held ops_release refused)' USING ERRCODE = 'CRM10';
    END IF;
    IF v_actor LIKE 'ops:%' THEN
        IF (pg_catalog.to_jsonb(NEW) - v_view_cols) IS DISTINCT FROM (pg_catalog.to_jsonb(OLD) - v_view_cols)
           OR NEW.view_count <> OLD.view_count + 1 THEN
            RAISE EXCEPTION 'crm: ops_release_guard (AA ops only record a view)' USING ERRCODE = 'CRM45';
        END IF;
        RETURN NEW;
    END IF;
    IF v_actor LIKE 'member:%' THEN
        IF OLD.withdrawn_at IS NOT NULL OR NEW.withdrawn_at IS NULL
           OR NEW.withdraw_reason NOT IN ('trip_cancelled', 'agency_withdrawn')
           OR (pg_catalog.to_jsonb(NEW) - v_withdraw_cols) IS DISTINCT FROM (pg_catalog.to_jsonb(OLD) - v_withdraw_cols)
        THEN
            RAISE EXCEPTION 'crm: ops_release_guard (a member only withdraws a live release)' USING ERRCODE = 'CRM45';
        END IF;
        RETURN NEW;
    END IF;
    IF v_actor LIKE 'job:%' THEN
        IF OLD.withdrawn_at IS NOT NULL AND NEW.withdrawn_at IS NULL AND OLD.withdraw_reason <> 'aa_lines_cancelled' THEN
            RAISE EXCEPTION 'crm: ops_release_guard (a cancelled trip or an agency withdrawal is not lifted by a job)'
                USING ERRCODE = 'CRM45';
        END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'crm: ops_release_guard (actor % may not change a release)', v_actor USING ERRCODE = 'CRM45';
END;
$$;
COMMENT ON FUNCTION crm.guard_ops_release() IS 'AA-956 (crm-034, SQLSTATE CRM45): who may write crm.ops_release. INSERT: a job actor only (Fix B2: created when an AA line is confirmed, by crm_ops_release_sync). UPDATE: trip, reason and release time fixed; a purged row sealed; payload_version up only; ops:<sub> only records a view (view_count + 1, last_viewed_at); member:<id> only withdraws (C12; the job then purges); job:<kind> refreshes, alerts, withdraws and purges, and lifts only an aa_lines_cancelled withdrawal; a purge of a held trip CRM10. DELETE: refused (the row leaves with its trip by cascade, depth > 1). crm_owner unguarded (migrations, tests). Invoker rights.';
CREATE TRIGGER ops_release_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.ops_release
    FOR EACH ROW EXECUTE FUNCTION crm.guard_ops_release();

COMMENT ON TABLE crm.ops_release IS 'AA-956 (crm-034; design v3 M8, Fix B2, data-privacy-integrations §2.10 group I): the traveller details AA ground operations need for a trip with a confirmed AA line, under the agency''s ops_release DEK, read by AA ops (WORKFORCE crm-ops) in AA-Partner with one agency audit line per view. Created by crm_ops_release_sync when an AA line is confirmed, refreshed as Stage 3 fills in (payload_version), alerted once at T-21 when incomplete, withdrawn on a cancel (C12) or when no confirmed AA line is left, purged at end_date + 90 days (or at once when withdrawn before departure) with a receipt. At most one live (unpurged) release per trip. Cascades from its trip. No reader role is granted it.';
COMMENT ON COLUMN crm.ops_release.payload_enc IS 'pii:health; the release document (traveller names, age band at departure, dietary / mobility codes, arrival and departure flights, insurance choice, the AA lines), JSON under the tenant ops_release DEK, AAD = tenant, ops_release, payload_enc, row id; NULL once purged';
COMMENT ON COLUMN crm.ops_release.fields_released IS 'the field codes the document carries (name, age_band, dietary, mobility, arrival_flight, departure_flight, insurance)';
COMMENT ON COLUMN crm.ops_release.completeness IS 'counts only: travellers, complete, and per missing item (stage3, waiver, arrival_flight, departure_flight) how many travellers lack it';
COMMENT ON COLUMN crm.ops_release.departure_ids IS 'Booking''s departure ids of the confirmed AA lines (the S-02 link to the Booking incident admin, Fix B3)';
COMMENT ON COLUMN crm.ops_release.bk_booking_ids IS 'Booking''s booking ids of the confirmed AA lines';
COMMENT ON COLUMN crm.ops_release.start_date IS 'pii:travel; the trip''s start date when last refreshed';
COMMENT ON COLUMN crm.ops_release.end_date IS 'pii:travel; the trip''s return date when last refreshed (purge_at = end_date + 90 days)';
COMMENT ON COLUMN crm.ops_release.purge_at IS 'end_date + 90 days, recomputed when the trip''s dates move; NULL while the return date is unknown';
COMMENT ON COLUMN crm.ops_release.deletion_receipt IS 'counts and codes only: what the purge removed (payload version, travellers, manifest exports, views)';

-- ── 2. crm.supplier_manifest_export ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.supplier_manifest_export (
    supplier_manifest_export_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                    UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                                 REFERENCES crm.tenant (tenant_id),
    ops_release_id               UUID NOT NULL,
    payload_version              INTEGER NOT NULL,
    fields                       TEXT[] NOT NULL,
    format                       TEXT NOT NULL DEFAULT 'csv',
    row_count                    SMALLINT NOT NULL,
    watermark                    TEXT NOT NULL,
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                   TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at                   TIMESTAMPTZ,
    deleted_by                   TEXT,
    purge_after                  TIMESTAMPTZ,
    CONSTRAINT supplier_manifest_export_release_fk FOREIGN KEY (tenant_id, ops_release_id)
        REFERENCES crm.ops_release (tenant_id, ops_release_id) ON DELETE CASCADE,
    CONSTRAINT supplier_manifest_export_version_chk CHECK (payload_version >= 1),
    CONSTRAINT supplier_manifest_export_fields_chk CHECK (
        cardinality(fields) BETWEEN 1 AND 16
        AND array_to_string(fields, ',', '!') ~ '^([a-z][a-z0-9_]{0,39}(,|$))*$'
    ),
    CONSTRAINT supplier_manifest_export_format_chk CHECK (format = 'csv'),
    CONSTRAINT supplier_manifest_export_rows_chk CHECK (row_count BETWEEN 0 AND 200),
    CONSTRAINT supplier_manifest_export_watermark_chk CHECK (watermark ~ '^[A-Z0-9-]{8,40}$'),
    CONSTRAINT supplier_manifest_export_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS supplier_manifest_export_release_idx
    ON crm.supplier_manifest_export (tenant_id, ops_release_id);

ALTER TABLE crm.supplier_manifest_export ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.supplier_manifest_export FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.supplier_manifest_export
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE TRIGGER supplier_manifest_export_set_updated_at
    BEFORE UPDATE ON crm.supplier_manifest_export
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();

CREATE FUNCTION crm.guard_supplier_manifest_export() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    v_trip uuid;
BEGIN
    IF pg_catalog.pg_trigger_depth() > 1 OR current_user = 'crm_owner' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF v_actor NOT LIKE 'ops:%' THEN
            RAISE EXCEPTION 'crm: ops_release_guard (a supplier manifest is exported by AA ops only, actor %)', v_actor
                USING ERRCODE = 'CRM45';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'crm: ops_release_guard (a manifest export record never changes)' USING ERRCODE = 'CRM45';
    END IF;
    IF v_actor NOT LIKE 'job:%' THEN
        RAISE EXCEPTION 'crm: ops_release_guard (manifest records leave with the release purge only)'
            USING ERRCODE = 'CRM45';
    END IF;
    SELECT r.trip_id INTO v_trip FROM crm.ops_release r WHERE r.ops_release_id = OLD.ops_release_id;
    IF crm.hold_row(v_trip, NULL) THEN
        RAISE EXCEPTION 'crm: legal_hold (delete of a held supplier_manifest_export row refused)' USING ERRCODE = 'CRM10';
    END IF;
    RETURN OLD;
END;
$$;
COMMENT ON FUNCTION crm.guard_supplier_manifest_export() IS 'AA-956 (crm-034, SQLSTATE CRM45): a supplier manifest export record is inserted by AA ops (ops:<sub>) only, never updated, and deleted only by a job (the release purge) unless its trip is held (CRM10). A cascade from its release (depth > 1) and crm_owner pass. Invoker rights.';
CREATE TRIGGER supplier_manifest_export_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.supplier_manifest_export
    FOR EACH ROW EXECUTE FUNCTION crm.guard_supplier_manifest_export();

COMMENT ON TABLE crm.supplier_manifest_export IS 'AA-956 (crm-034; design v3 S-02, A:3.10): one minimal supplier manifest AA ops exported from a release (payload version, field codes, csv, row count, the watermark printed on it). The file is never stored; no personal data here. Deleted by the release purge (counted on its receipt); cascades from its release.';
COMMENT ON COLUMN crm.supplier_manifest_export.watermark IS 'the export''s code printed on every page / row of the file (traces a leaked copy back to this export)';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-034', now(), 'AA-956 CRM-26 Module 8 ops release: crm.ops_release (one live release per trip once an AA line is confirmed, payload under the ops_release DEK, completeness, T-21 alert, withdraw, purge at return + 90 days with a receipt) and crm.supplier_manifest_export (minimal manifest log); guards CRM45; cascading keys, no erase_subject change')
ON CONFLICT (version) DO NOTHING;

COMMIT;
