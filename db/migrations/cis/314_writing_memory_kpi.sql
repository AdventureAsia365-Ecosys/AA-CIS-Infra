-- migrate: expand
-- Migration 314: AA-922 (WM-30 / WM-31) — the writing-memory weekly KPI reports, the "keep" decisions that stop a
-- soft-stop rollback, and the weekly judge / human disagreement queue.
--
-- Why. App ADR 0010 / S245 audit §8: hard stops are checked per write (WM-26, AA-920); the soft stops (re-flag over 8%,
-- a light-edit share drop, minutes_to_fix +20%, tenant edit rate up, cost per piece +20%) need a scheduled job that
-- measures the loop every week and rolls a release back unless a human recorded a reason to keep it. The reviewer gets
-- a 5-10 item weekly queue of the cases where the judge (or the gates) and a human label disagree (D15).
--
-- What. Three new tables in shared:
--   1. shared.writing_memory_kpi_report (platform table: numbers and ids only, no text, no tenant column): one stored
--      weekly report. week_start (the Monday, UTC) and trigger schedule | manual; kpis (per writer, overall and per
--      tenant id: counts and rates), soft_stops (per active release with content: the codes that fired, with their
--      numbers), actions (what the job did per release: rolled_back / retired_alone / memory_off / kept / none),
--      rules (expired / reconfirmed counts and ids), project_stop (the P3 stop rule: two releases without improvement),
--      disagreements (how many items the queue got), job_id (no FK: job rows expire), created_at. One scheduled report
--      per week (writing_memory_kpi_report_week_uq).
--   2. shared.writing_memory_keep: a human decision to keep a release despite a soft stop. release_id (FK, ON DELETE
--      CASCADE), its writer / scope / tenant_id (RLS and the erasure key), codes (the soft-stop codes it covers; empty =
--      every code), reason (required), kept_by, kept_until (<= 30 days ahead: a keep expires), created_at.
--   3. shared.writing_memory_disagreement: one queue item. source golden (an R2 result whose judge verdict differs
--      from the golden item's human label) | piece_label (a T9 piece the gates passed but a human labelled heavy /
--      reject, or one the gates held that a human labelled as_is / light); source_ref (the result or piece id; unique
--      per source), writer, scope / tenant_id, machine_verdict, human_label, week_start, status open | resolved,
--      resolution judge_right | human_right | unclear, note (the admin's words, <= 500 characters: pii:free_text),
--      resolved_by, resolved_at, created_at. Ids and verdicts only; the texts stay where they are.
--   RLS ENABLE + FORCE on keep and disagreement (tenant ids; the CIS 280 / 287 / 313 policy shape: <t>_cis_app_all,
--   <t>_cis_owner_all USING (true) — cis_app code filters tenant_id explicitly — and tenant_isolation TO aa_app_user,
--   which holds no privilege). The report table is a platform table and has no RLS (no tenant column).
--   Grants: cis_app SELECT, INSERT on the report; SELECT, INSERT, DELETE on keep (DELETE: the erasure); SELECT,
--   INSERT, UPDATE, DELETE on the disagreement queue (UPDATE: a resolution).
--
-- Class: expand (root ADR 0017 d3): three new tables with their indexes, RLS flags, policies, grants and comments; the
-- FK from keep to shared.writing_memory_release adds only its internal RI triggers there; no DO block, no REVOKE.
-- Auto-applied on Dev by the AA-CIS-Infra migration-apply pipeline after the app PR merges, before Deploy Dev's schema
-- gate lets the code roll (readiness.REQUIRED_CIS_SCHEMA = 314 in the same PR).
--
-- Number. Stacked on 313 (AA-921). Renumber at merge to main max + 1 (file name, this header, the registration,
-- readiness, tests, CONTEXT.md).
--
-- Rollback (a new forward migration, after the code that reads them is reverted):
--   DROP TABLE shared.writing_memory_disagreement; DROP TABLE shared.writing_memory_keep;
--   DROP TABLE shared.writing_memory_kpi_report;
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE shared.writing_memory_kpi_report (
    report_id      uuid NOT NULL DEFAULT gen_random_uuid(),
    week_start     date NOT NULL,
    trigger        text NOT NULL,
    kpis           jsonb NOT NULL DEFAULT '{}'::jsonb,
    soft_stops     jsonb NOT NULL DEFAULT '[]'::jsonb,
    actions        jsonb NOT NULL DEFAULT '[]'::jsonb,
    rules          jsonb NOT NULL DEFAULT '{}'::jsonb,
    project_stop   jsonb NOT NULL DEFAULT '{}'::jsonb,
    disagreements  integer NOT NULL DEFAULT 0,
    job_id         uuid,
    created_by     text NOT NULL,
    created_at     timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT writing_memory_kpi_report_pkey PRIMARY KEY (report_id),
    CONSTRAINT writing_memory_kpi_report_trigger_check CHECK (trigger IN ('schedule', 'manual')),
    CONSTRAINT writing_memory_kpi_report_week_check CHECK (extract(isodow FROM week_start) = 1),
    CONSTRAINT writing_memory_kpi_report_shape_check
        CHECK (jsonb_typeof(kpis) = 'object' AND jsonb_typeof(soft_stops) = 'array' AND jsonb_typeof(actions) = 'array'
               AND jsonb_typeof(rules) = 'object' AND jsonb_typeof(project_stop) = 'object' AND disagreements >= 0
               AND char_length(created_by) BETWEEN 1 AND 128)
);
CREATE UNIQUE INDEX writing_memory_kpi_report_week_uq ON shared.writing_memory_kpi_report (week_start)
    WHERE trigger = 'schedule';
CREATE INDEX writing_memory_kpi_report_created_idx ON shared.writing_memory_kpi_report (created_at DESC);

COMMENT ON TABLE shared.writing_memory_kpi_report IS
    'AA-922 WM-30 (CIS 314, app ADR 0010): the weekly writing-memory KPI report: per writer (and per tenant id) counts '
    'and rates, the soft stops per active release, what the job did, the expired / reconfirmed rules and the project '
    'stop flag. Numbers and ids only (no text, no tenant column). One scheduled report per week.';
COMMENT ON COLUMN shared.writing_memory_kpi_report.week_start IS
    'AA-922 (314): the Monday (UTC) of the week the report measures (Monday 00:00 to the next Monday 00:00).';

CREATE TABLE shared.writing_memory_keep (
    keep_id     uuid NOT NULL DEFAULT gen_random_uuid(),
    release_id  uuid NOT NULL,
    writer      text NOT NULL,
    scope       text NOT NULL,
    tenant_id   uuid,
    codes       text[] NOT NULL DEFAULT '{}'::text[],
    reason      text NOT NULL,
    kept_by     text NOT NULL,
    kept_until  date NOT NULL,
    created_at  timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT writing_memory_keep_pkey PRIMARY KEY (keep_id),
    CONSTRAINT writing_memory_keep_release_fkey FOREIGN KEY (release_id)
        REFERENCES shared.writing_memory_release (release_id) ON DELETE CASCADE,
    CONSTRAINT writing_memory_keep_scope_tenant_ck
        CHECK ((scope = 'platform' AND tenant_id IS NULL) OR (scope = 'tenant' AND tenant_id IS NOT NULL)),
    CONSTRAINT writing_memory_keep_writer_check CHECK (writer IN ('a1', 't2', 't9_blog', 't9_social')),
    CONSTRAINT writing_memory_keep_codes_check
        CHECK (codes <@ ARRAY['reflag_over_8pct', 'light_edit_drop', 'minutes_to_fix_up', 'tenant_edit_up',
                              'cost_up']::text[]),
    CONSTRAINT writing_memory_keep_text_check
        CHECK (char_length(reason) BETWEEN 3 AND 500 AND char_length(kept_by) BETWEEN 1 AND 128
               AND kept_until <= (created_at AT TIME ZONE 'utc')::date + 30)
);
CREATE INDEX writing_memory_keep_release_idx ON shared.writing_memory_keep (release_id, kept_until DESC);
CREATE INDEX writing_memory_keep_tenant_idx ON shared.writing_memory_keep (tenant_id) WHERE scope = 'tenant';

COMMENT ON TABLE shared.writing_memory_keep IS
    'AA-922 WM-30 (CIS 314): a human decision to keep a release although a soft stop fired (the weekly job then does '
    'not roll it back) for the listed codes (empty = all) until kept_until (<= 30 days). Ids and the reason only.';
COMMENT ON COLUMN shared.writing_memory_keep.reason IS 'pii:free_text — AA-922 (314): why the release is kept.';

CREATE TABLE shared.writing_memory_disagreement (
    item_id          uuid NOT NULL DEFAULT gen_random_uuid(),
    source           text NOT NULL,
    source_ref       uuid NOT NULL,
    writer           text NOT NULL,
    scope            text NOT NULL,
    tenant_id        uuid,
    machine_verdict  text NOT NULL,
    human_label      text NOT NULL,
    week_start       date NOT NULL,
    status           text NOT NULL DEFAULT 'open',
    resolution       text,
    note             text,
    resolved_by      text,
    resolved_at      timestamp with time zone,
    created_at       timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT writing_memory_disagreement_pkey PRIMARY KEY (item_id),
    CONSTRAINT writing_memory_disagreement_source_check CHECK (source IN ('golden', 'piece_label')),
    CONSTRAINT writing_memory_disagreement_scope_tenant_ck
        CHECK ((scope = 'platform' AND tenant_id IS NULL) OR (scope = 'tenant' AND tenant_id IS NOT NULL)),
    CONSTRAINT writing_memory_disagreement_writer_check CHECK (writer IN ('a1', 't2', 't9_blog', 't9_social')),
    CONSTRAINT writing_memory_disagreement_status_check
        CHECK ((status = 'open' AND resolution IS NULL AND resolved_by IS NULL AND resolved_at IS NULL)
               OR (status = 'resolved' AND resolution IN ('judge_right', 'human_right', 'unclear')
                   AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL)),
    CONSTRAINT writing_memory_disagreement_text_check
        CHECK (char_length(machine_verdict) BETWEEN 1 AND 40 AND char_length(human_label) BETWEEN 1 AND 40
               AND coalesce(char_length(note), 0) <= 500 AND coalesce(char_length(resolved_by), 0) <= 128
               AND extract(isodow FROM week_start) = 1)
);
CREATE UNIQUE INDEX writing_memory_disagreement_source_uq ON shared.writing_memory_disagreement (source, source_ref);
CREATE INDEX writing_memory_disagreement_open_idx ON shared.writing_memory_disagreement (status, week_start DESC);
CREATE INDEX writing_memory_disagreement_tenant_idx ON shared.writing_memory_disagreement (tenant_id)
    WHERE scope = 'tenant';

COMMENT ON TABLE shared.writing_memory_disagreement IS
    'AA-922 WM-31 (CIS 314, D15): the weekly 5-10 item queue where the judge (an R2 result) or the gates (a T9 piece) '
    'and a human label disagree, with the one-click resolution. Ids and verdicts only.';
COMMENT ON COLUMN shared.writing_memory_disagreement.note IS 'pii:free_text — AA-922 (314): the reviewer''s note.';

ALTER TABLE shared.writing_memory_keep ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.writing_memory_keep FORCE ROW LEVEL SECURITY;
ALTER TABLE shared.writing_memory_disagreement ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.writing_memory_disagreement FORCE ROW LEVEL SECURITY;

CREATE POLICY writing_memory_keep_cis_app_all ON shared.writing_memory_keep AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
CREATE POLICY writing_memory_keep_cis_owner_all ON shared.writing_memory_keep AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
CREATE POLICY tenant_isolation ON shared.writing_memory_keep AS PERMISSIVE FOR ALL TO aa_app_user
    USING (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE POLICY writing_memory_disagreement_cis_app_all ON shared.writing_memory_disagreement AS PERMISSIVE FOR ALL
    TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY writing_memory_disagreement_cis_owner_all ON shared.writing_memory_disagreement AS PERMISSIVE FOR ALL
    TO cis_owner USING (true) WITH CHECK (true);
CREATE POLICY tenant_isolation ON shared.writing_memory_disagreement AS PERMISSIVE FOR ALL TO aa_app_user
    USING (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

GRANT SELECT, INSERT ON shared.writing_memory_kpi_report TO cis_app;
GRANT SELECT, INSERT, DELETE ON shared.writing_memory_keep TO cis_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.writing_memory_disagreement TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('314', now(), 'AA-922: writing-memory weekly KPI reports, keep decisions, disagreement queue')
ON CONFLICT (version) DO NOTHING;

COMMIT;
