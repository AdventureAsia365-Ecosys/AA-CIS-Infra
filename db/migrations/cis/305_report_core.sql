-- migrate: expand
-- Migration 305: AA-1003 R1 (report core) — shared.kpi_daily (daily KPI snapshots) and shared.report_run (the register
-- of generated reports).
--
-- Why. The AA-1001 report catalog (root docs/audits/2026-10-29-S258-report-catalog/, registry root
-- docs/reports/catalog.yaml + kpis.yaml) needs history: /admin/overview shows only "now", so no report can say whether a
-- number moved, and nothing records which report ran for which period. Reports read stored snapshots and never
-- recompute history (automation-plan.md §1).
--
-- What. Two new platform tables in shared (no tenant column, no personal data; numbers, IDs, rendered text):
--   1. shared.kpi_daily: one value per (kpi_id, day, scope). kpi_id is a kpis.yaml ID; day is the ICT calendar day the
--      value describes; scope is the one dimension key: 'all', 'app:<app>' or 'provider:<provider>' (NOT NULL, so the
--      primary key needs no NULLS NOT DISTINCT). Written (upsert) by job kind kpi_snapshot_daily; value, unit (the
--      kpis.yaml unit), source (where the number came from), data_as_of (the instant a point-in-time value was read),
--      computed_at and job_id (the shared.job row that wrote it; no FK: the job retention deletes old job rows).
--   2. shared.report_run: one row per generation of a report (report_id = a catalog.yaml ID) for a period
--      [period_start, period_end] (ICT days). status queued -> running -> succeeded | failed (draft / approved /
--      posted are for the semi-automatic reports of later slices); trigger schedule | manual | on_demand;
--      triggered_by (scheduler:aa-1003 or admin:<staff id>); job_id (the report_generate job; no FK, as above);
--      summary (one line), output (JSON), output_markdown (the rendered report), s3_key (NULL in R1: S3 delivery is a
--      later slice), error, approved_by / approved_at (semi reports, later). One scheduled run per report and period
--      (report_run_schedule_uq), so a re-tick of the scheduler never duplicates it; manual runs are unlimited.
--   Grants: cis_app SELECT, INSERT, UPDATE on both (the api and the worker). The code never deletes a row (data
--   standards Part B §7 row "shared.kpi_daily, shared.report_run": kept, root PR of AA-1003); cis_owner's default
--   privileges in shared also give cis_app DELETE, which an expand file cannot revoke (REVOKE is contract): a later
--   contract file may narrow it. No other role reads them.
--
-- Class: expand (root ADR 0017 d3): only new tables, their indexes, grants and comments, no change to any existing
-- object, no DO block. Auto-applied on Dev by the AA-CIS-Infra migration-apply pipeline after the app PR merges (the
-- ci-bot copy into db/migrations/cis/), before Deploy Dev's schema-gate lets the code roll
-- (readiness.REQUIRED_CIS_SCHEMA = 305 in the same PR).
--
-- Number. 303 is the highest on main; 304 is claimed by another S258 lane (LLM gateway). If that lane does not land
-- first, renumber this file to 304 (file name, this header, the registration below, readiness).
--
-- Rollback (a new forward migration, after the code that reads them is reverted):
--   DROP TABLE shared.report_run; DROP TABLE shared.kpi_daily;
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE shared.kpi_daily (
    kpi_id       text NOT NULL,
    day          date NOT NULL,
    scope        text NOT NULL DEFAULT 'all',
    kpi_version  smallint NOT NULL DEFAULT 1,
    value        numeric NOT NULL,
    unit         text NOT NULL,
    source       text NOT NULL,
    data_as_of   timestamp with time zone,
    computed_at  timestamp with time zone NOT NULL DEFAULT now(),
    job_id       uuid,
    CONSTRAINT kpi_daily_pkey PRIMARY KEY (kpi_id, day, scope),
    CONSTRAINT kpi_daily_kpi_id_check CHECK (kpi_id ~ '^K-[A-Z0-9]+(-[A-Z0-9]+)*$' AND char_length(kpi_id) <= 64),
    CONSTRAINT kpi_daily_scope_check
        CHECK (scope = 'all' OR (scope ~ '^(app|provider):[A-Za-z0-9_.-]+$' AND char_length(scope) <= 96)),
    CONSTRAINT kpi_daily_unit_check
        CHECK (unit IN ('count', 'ratio', 'usd', 'seconds', 'hours', 'days', 'score', 'status', 'text')),
    CONSTRAINT kpi_daily_version_check CHECK (kpi_version >= 1),
    CONSTRAINT kpi_daily_source_check CHECK (char_length(source) BETWEEN 1 AND 200)
);
CREATE INDEX kpi_daily_day_idx ON shared.kpi_daily (day DESC);

COMMENT ON TABLE shared.kpi_daily IS
    'AA-1003 R1 (CIS 305, AA-1001 EX-04): daily KPI snapshots. One value per kpi_id (root docs/reports/kpis.yaml), '
    'ICT day and scope (all, app:<app>, provider:<provider>). Written by job kind kpi_snapshot_daily (upsert); every '
    'periodic report reads it and never recomputes history. Platform numbers only: no tenant column, no personal data. '
    'Retention: kept (data standards Part B §7).';
COMMENT ON COLUMN shared.kpi_daily.day IS 'AA-1003 (305): the ICT (UTC+7) calendar day the value describes.';
COMMENT ON COLUMN shared.kpi_daily.scope IS
    'AA-1003 (305): the one dimension key: all, app:<app> (cis, tripplanner, ...) or provider:<provider>.';
COMMENT ON COLUMN shared.kpi_daily.source IS
    'AA-1003 (305): where the number came from (table or view, as kpis.yaml sources), for the report footnote.';
COMMENT ON COLUMN shared.kpi_daily.data_as_of IS
    'AA-1003 (305): the instant a point-in-time value (tours live) was read; NULL for a value over the whole day.';
COMMENT ON COLUMN shared.kpi_daily.job_id IS
    'AA-1003 (305): the shared.job row that wrote the value (no FK: job rows expire under their own retention).';

CREATE TABLE shared.report_run (
    id               uuid NOT NULL DEFAULT gen_random_uuid(),
    report_id        text NOT NULL,
    period_start     date NOT NULL,
    period_end       date NOT NULL,
    status           text NOT NULL DEFAULT 'queued',
    trigger          text NOT NULL DEFAULT 'manual',
    triggered_by     text,
    job_id           uuid,
    started_at       timestamp with time zone,
    finished_at      timestamp with time zone,
    summary          text,
    output           jsonb,
    output_markdown  text,
    s3_key           text,
    error            text,
    approved_by      text,
    approved_at      timestamp with time zone,
    created_at       timestamp with time zone NOT NULL DEFAULT now(),
    updated_at       timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT report_run_pkey PRIMARY KEY (id),
    CONSTRAINT report_run_report_id_check CHECK (report_id ~ '^[A-Z]{2,4}-[0-9]{2}$'),
    CONSTRAINT report_run_period_check CHECK (period_end >= period_start),
    CONSTRAINT report_run_status_check
        CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'draft', 'approved', 'posted')),
    CONSTRAINT report_run_trigger_check CHECK (trigger IN ('schedule', 'manual', 'on_demand')),
    CONSTRAINT report_run_text_check
        CHECK (coalesce(char_length(triggered_by), 0) <= 128 AND coalesce(char_length(summary), 0) <= 1000
               AND coalesce(char_length(error), 0) <= 4000 AND coalesce(char_length(s3_key), 0) <= 1024
               AND coalesce(char_length(approved_by), 0) <= 128),
    CONSTRAINT report_run_approval_check CHECK ((approved_by IS NULL) = (approved_at IS NULL))
);
CREATE INDEX report_run_report_created_idx ON shared.report_run (report_id, created_at DESC);
CREATE INDEX report_run_job_idx ON shared.report_run (job_id) WHERE job_id IS NOT NULL;
CREATE UNIQUE INDEX report_run_schedule_uq ON shared.report_run (report_id, period_start, period_end)
    WHERE trigger = 'schedule';

COMMENT ON TABLE shared.report_run IS
    'AA-1003 R1 (CIS 305, AA-1001 EX-06): the register of generated reports. One row per generation of a report '
    '(report_id = root docs/reports/catalog.yaml ID) for an ICT period; status queued, running, succeeded, failed '
    '(draft, approved, posted for semi-automatic reports later); output (JSON) and output_markdown hold the result. '
    'One scheduled run per report and period (report_run_schedule_uq). Written by POST /admin/reports/{id}/run and job '
    'kind report_generate. Platform rows only. Retention: kept (data standards Part B §7).';
COMMENT ON COLUMN shared.report_run.triggered_by IS
    'AA-1003 (305): scheduler:aa-1003 for the daily chain, admin:<staff id> for a run from /admin/reports.';
COMMENT ON COLUMN shared.report_run.job_id IS
    'AA-1003 (305): the report_generate job (no FK: job rows expire under their own retention).';
COMMENT ON COLUMN shared.report_run.s3_key IS 'AA-1003 (305): reserved for S3 delivery (later slice); NULL in R1.';

GRANT SELECT, INSERT, UPDATE ON shared.kpi_daily TO cis_app;
GRANT SELECT, INSERT, UPDATE ON shared.report_run TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('305', now(), 'AA-1003: shared.kpi_daily + shared.report_run (report core R1)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
