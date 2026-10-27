-- Migration 292: AA-919 (WM-19 / WM-21 review) — the release guard checks that the evidence runs belong to the release.
--
-- Why. CIS 287's trigger shared.writing_memory_release_guard accepts as a release's eval run ANY finished r2 run of the
-- same writer with verdict pass, and as its shadow run any finished passing shadow run of the writer. It never compared
-- prompt_eval_runs.release_id with the release. With the R2 runner and the targeted shadow (this branch) real runs
-- exist that must never be evidence for a rules release: code-train r2 runs (release_id NULL, details.candidate
-- 'current'), seeded-fault operator checks (release_id NULL, details.seeded_fault), and runs of OTHER releases. Any of
-- them ending `pass` would satisfy activation: the gate of app ADR 0010 decision 1 could be bypassed. The API half
-- (services/writing_memory/releases.py evidence_problem / attach_evidence) refuses the same since this branch; this
-- file is the DB half ("enforced twice").
--
-- What. CREATE OR REPLACE the trigger function only (the trigger, CHECK and table are unchanged). On activation:
--   * eval run of kind r2: release_id = the release's, details.seeded_fault empty, details.candidate absent or
--     'release'. The baseline_import exception of an empty release (release 0, release_id NULL) is kept.
--   * shadow run: release_id = the release's.
-- Everything else is 287's body, byte for byte. No table, grant or data change. Existing Dev releases: release 0 of each
-- writer activated on a baseline_import (unchanged rule); no r2 / shadow run existed before this branch, so no active
-- release depends on the old rule (preflight below). A retired release re-activated by a rollback is re-checked by the
-- same rules (its own runs: they name it).
--
-- Order with the code. None: the app checks the same rule itself; REQUIRED_CIS_SCHEMA stays 287. Apply through
-- AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/), after 291. NOTE: re-running 287 (its own idempotent
-- re-apply) puts 287's function body back; re-run 292 after it.
--
-- Preflight (read-only; expected: 291 registered = 1; active releases whose eval / shadow run would now be refused = 0):
--   SELECT (SELECT count(*) FROM shared.schema_versions WHERE version = '291') AS predecessor,
--          (SELECT count(*) FROM shared.writing_memory_release w
--             LEFT JOIN shared.prompt_eval_runs e ON e.id = w.eval_run_id
--             LEFT JOIN shared.prompt_eval_runs s ON s.id = w.shadow_run_id
--            WHERE w.status = 'active'
--              AND ((e.run_kind = 'r2' AND e.release_id IS DISTINCT FROM w.release_id)
--                   OR (w.shadow_run_id IS NOT NULL AND s.release_id IS DISTINCT FROM w.release_id))) AS would_refuse;
--
-- Rollback: re-apply 287's function definition (section 5 of 287) in a new forward migration.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '287') THEN
        RAISE EXCEPTION 'migration 292: 287 (shared.writing_memory_release) is not applied';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '291') THEN
        RAISE NOTICE 'migration 292: 291 is not registered (Dev applies in version order)';
    END IF;
    IF to_regprocedure('shared.writing_memory_release_guard()') IS NULL THEN
        RAISE EXCEPTION 'migration 292: shared.writing_memory_release_guard() is missing';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION shared.writing_memory_release_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    run        record;
    bad        text;
    kinds      text[];
    unready    integer;
    closed     date;
    first_act  boolean := false;
    activating boolean := false;
    rules_changed boolean := TG_OP = 'INSERT';
    diffs      numeric;
    inputs     numeric;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status IS DISTINCT FROM 'draft' THEN
            RAISE EXCEPTION 'shared.writing_memory_release: a release is created as a draft (AA-919)'
                  USING ERRCODE = 'restrict_violation';
        END IF;
    ELSE
        IF OLD.status <> 'draft'
           AND (NEW.writer, NEW.scope, NEW.tenant_id, NEW.release_no, NEW.train_kind, NEW.content_class, NEW.rule_ids,
                NEW.items_sha256, NEW.emergency_reason, NEW.emergency_ref, NEW.created_by, NEW.created_at)
               IS DISTINCT FROM
               (OLD.writer, OLD.scope, OLD.tenant_id, OLD.release_no, OLD.train_kind, OLD.content_class, OLD.rule_ids,
                OLD.items_sha256, OLD.emergency_reason, OLD.emergency_ref, OLD.created_by, OLD.created_at) THEN
            RAISE EXCEPTION 'shared.writing_memory_release: writer, owner, number, kinds, rules and items are fixed '
                            'once a release leaves draft (AA-919)' USING ERRCODE = 'restrict_violation';
        END IF;
        IF OLD.status IN ('approved', 'active', 'retired', 'rejected')
           AND (NEW.r0_run_id, NEW.eval_run_id, NEW.shadow_run_id, NEW.approved_by, NEW.approved_at, NEW.approval_ref)
               IS DISTINCT FROM
               (OLD.r0_run_id, OLD.eval_run_id, OLD.shadow_run_id, OLD.approved_by, OLD.approved_at, OLD.approval_ref)
           THEN
            RAISE EXCEPTION 'shared.writing_memory_release: evidence and approval are fixed from approval on (AA-919)'
                  USING ERRCODE = 'restrict_violation';
        END IF;
        IF NEW.status = OLD.status THEN
            -- a same-status update: only the reverify bookkeeping, notes and previous_release_id -> NULL (the ON DELETE
            -- SET NULL of an erasure) once the release left evaluation (critic 18)
            IF OLD.status NOT IN ('draft', 'evaluated')
               AND ((NEW.fingerprint, NEW.activated_at, NEW.retired_at, NEW.retired_reason, NEW.train_month,
                     NEW.rejected_by, NEW.rejected_reason)
                    IS DISTINCT FROM
                    (OLD.fingerprint, OLD.activated_at, OLD.retired_at, OLD.retired_reason, OLD.train_month,
                     OLD.rejected_by, OLD.rejected_reason)
                    OR (NEW.previous_release_id IS DISTINCT FROM OLD.previous_release_id
                        AND NEW.previous_release_id IS NOT NULL)) THEN
                RAISE EXCEPTION 'shared.writing_memory_release: a % release changes only its reverify state and notes '
                                '(AA-919)', OLD.status USING ERRCODE = 'restrict_violation';
            END IF;
        ELSE
            IF (OLD.status, NEW.status) NOT IN (('draft', 'evaluated'), ('draft', 'rejected'), ('evaluated', 'approved'),
                                                ('evaluated', 'rejected'), ('evaluated', 'draft'),
                                                ('approved', 'active'), ('approved', 'rejected'),
                                                ('active', 'retired'), ('retired', 'active')) THEN
                RAISE EXCEPTION 'shared.writing_memory_release: % -> % is not a release transition (AA-919)',
                                OLD.status, NEW.status USING ERRCODE = 'restrict_violation';
            END IF;
            IF OLD.status = 'retired' AND NEW.status = 'active' AND OLD.retired_reason LIKE 'rollback:%' THEN
                RAISE EXCEPTION 'shared.writing_memory_release: a rolled-back release is never re-activated; draft a '
                                'new release (AA-919, critic 19)' USING ERRCODE = 'restrict_violation';
            END IF;
            activating := NEW.status = 'active';
            first_act := OLD.status = 'approved' AND NEW.status = 'active';
            IF NEW.status = 'retired' THEN
                NEW.retired_at := coalesce(NEW.retired_at, now());
            END IF;
        END IF;
    END IF;

    -- the rules: the release's writer and owner only (a tenant release never holds another tenant's rule), kinds as
    -- the class says
    IF TG_OP = 'UPDATE' THEN
        rules_changed := NEW.rule_ids IS DISTINCT FROM OLD.rule_ids;
    END IF;
    IF cardinality(NEW.rule_ids) > 0 AND (rules_changed OR activating) THEN
        SELECT string_agg(u.id::text, ', ') INTO bad
          FROM unnest(NEW.rule_ids) u(id)
          LEFT JOIN shared.writing_rule r ON r.rule_id = u.id
         WHERE r.rule_id IS NULL OR r.writer <> NEW.writer OR r.scope <> NEW.scope
            OR r.tenant_id IS DISTINCT FROM NEW.tenant_id;
        IF bad IS NOT NULL THEN
            RAISE EXCEPTION 'shared.writing_memory_release: rules % are not % rules of this owner (AA-919)',
                            left(bad, 200), NEW.writer USING ERRCODE = 'check_violation';
        END IF;
        SELECT array_agg(DISTINCT r.kind ORDER BY r.kind), count(*) FILTER (WHERE r.status NOT IN ('approved', 'active'))
          INTO kinds, unready
          FROM shared.writing_rule r WHERE r.rule_id = ANY (NEW.rule_ids);
        IF (NEW.content_class = 'lexicon_only' AND kinds <> ARRAY['lexicon'])
           OR (NEW.content_class = 'repair_hint_only' AND kinds <> ARRAY['repair_hint'])
           OR (NEW.content_class = 'rules' AND kinds IN (ARRAY['lexicon'], ARRAY['repair_hint'])) THEN
            RAISE EXCEPTION 'shared.writing_memory_release: a % release cannot hold rules of kinds % (AA-919)',
                            NEW.content_class, kinds USING ERRCODE = 'check_violation';
        END IF;
        IF first_act AND unready > 0 THEN
            RAISE EXCEPTION 'shared.writing_memory_release: % rules are not approved or active (AA-919)', unready
                  USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    IF activating THEN
        IF NEW.content_class IN ('empty', 'lexicon_only') THEN
            SELECT r.pipeline, r.writer, r.run_kind, r.verdict, r.finished_at, r.details INTO run
              FROM shared.prompt_eval_runs r WHERE r.id = NEW.r0_run_id;
            IF NOT FOUND OR run.pipeline <> 'writing_memory' OR run.writer IS DISTINCT FROM NEW.writer
               OR run.run_kind <> 'r0_replay' OR run.verdict IS DISTINCT FROM 'pass' OR run.finished_at IS NULL THEN
                RAISE EXCEPTION 'shared.writing_memory_release: activation needs a finished, passing r0_replay run of '
                                'writer % (AA-919)', NEW.writer USING ERRCODE = 'check_violation';
            END IF;
            IF NEW.content_class = 'empty' THEN
                diffs := CASE WHEN jsonb_typeof(run.details -> 'byte_diffs') = 'number'
                              THEN (run.details ->> 'byte_diffs')::numeric END;
                inputs := CASE WHEN jsonb_typeof(run.details -> 'inputs') = 'number'
                               THEN (run.details ->> 'inputs')::numeric END;
                IF diffs IS DISTINCT FROM 0 OR coalesce(inputs, 0) < 20 THEN
                    RAISE EXCEPTION 'shared.writing_memory_release: an empty release needs an R0 replay with 0 byte '
                                    'diffs over >= 20 inputs (got % diffs, % inputs; WM-20)', diffs, inputs
                          USING ERRCODE = 'check_violation';
                END IF;
            END IF;
        END IF;
        IF NEW.content_class IN ('empty', 'repair_hint_only', 'rules') THEN
            SELECT r.pipeline, r.writer, r.run_kind, r.verdict, r.finished_at, r.release_id, r.details INTO run
              FROM shared.prompt_eval_runs r WHERE r.id = NEW.eval_run_id;
            IF NOT FOUND OR run.pipeline <> 'writing_memory' OR run.writer IS DISTINCT FROM NEW.writer
               OR run.finished_at IS NULL
               OR NOT ((run.run_kind = 'r2' AND run.verdict = 'pass')
                       OR (NEW.content_class = 'empty' AND run.run_kind = 'baseline_import'
                           AND run.verdict = 'baseline')) THEN
                RAISE EXCEPTION 'shared.writing_memory_release: activation needs a finished eval run of writer % that '
                                'passed (r2 pass; the baseline import for an empty release) (AA-919)', NEW.writer
                      USING ERRCODE = 'check_violation';
            END IF;
            -- 292: an r2 run is evidence only for the release it evaluated (not a code-train run, not a seeded-fault
            -- operator check, not another release's run); the baseline import (no release) stays release 0's
            IF run.run_kind = 'r2'
               AND (run.release_id IS DISTINCT FROM NEW.release_id
                    OR coalesce(run.details ->> 'seeded_fault', '') <> ''
                    OR coalesce(run.details ->> 'candidate', 'release') <> 'release') THEN
                RAISE EXCEPTION 'shared.writing_memory_release: the eval run is not an r2 run of this release (it '
                                'evaluated another release, no release, or a seeded fault) (AA-919, CIS 292)'
                      USING ERRCODE = 'check_violation';
            END IF;
        END IF;
        IF NEW.content_class IN ('repair_hint_only', 'rules') THEN
            SELECT r.pipeline, r.writer, r.run_kind, r.verdict, r.finished_at, r.release_id INTO run
              FROM shared.prompt_eval_runs r WHERE r.id = NEW.shadow_run_id;
            IF NOT FOUND OR run.pipeline <> 'writing_memory' OR run.writer IS DISTINCT FROM NEW.writer
               OR run.run_kind <> 'shadow' OR run.verdict IS DISTINCT FROM 'pass' OR run.finished_at IS NULL THEN
                RAISE EXCEPTION 'shared.writing_memory_release: activation needs a finished, passing shadow run of '
                                'writer % (AA-919)', NEW.writer USING ERRCODE = 'check_violation';
            END IF;
            IF run.release_id IS DISTINCT FROM NEW.release_id THEN          -- 292
                RAISE EXCEPTION 'shared.writing_memory_release: the shadow run is not a shadow run of this release '
                                '(AA-919, CIS 292)' USING ERRCODE = 'check_violation';
            END IF;
        END IF;
        IF NEW.train_kind = 'regular' AND first_act THEN
            NEW.train_month := coalesce(NEW.train_month, date_trunc('month', now() AT TIME ZONE 'UTC')::date);
            SELECT w.train_closed_month INTO closed FROM shared.writing_memory_writer w WHERE w.writer = NEW.writer;
            IF closed IS NOT NULL AND closed >= NEW.train_month THEN
                RAISE EXCEPTION 'shared.writing_memory_release: the % train of % is closed (AA-919)',
                                to_char(NEW.train_month, 'YYYY-MM'), NEW.writer USING ERRCODE = 'check_violation';
            END IF;
        END IF;
        NEW.activated_at := now();
        NEW.retired_at := NULL;
        NEW.retired_reason := NULL;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION shared.writing_memory_release_guard() FROM PUBLIC;
COMMENT ON FUNCTION shared.writing_memory_release_guard() IS
    'AA-919 WM-18 (CIS 287): BEFORE INSERT OR UPDATE row trigger of shared.writing_memory_release: drafts only on '
    'insert; the release transitions; no re-activation of a rolled-back release; identity fixed after draft, evidence '
    'after approval, same-status updates limited to the reverify state / notes / previous -> NULL; rules of the '
    'release''s writer and owner with matching kinds; on activation the evidence runs (kind, verdict, finished, R0 '
    'byte_diffs = 0 over >= 20 inputs for an empty release; since CIS 292 an r2 eval run and the shadow run must name '
    'this release (release_id), the r2 run not seeded and not a code-train run), approved rules, the monthly train. '
    'SECURITY INVOKER.';


-- ── Behaviour probe (a sub-block that always rolls back) ─────────────────────────────────────────────────────────
DO $$
DECLARE
    tenant_a  uuid := gen_random_uuid();
    rule_wi   uuid;
    r2_none   uuid;
    sh_none   uuid;
    rel_x     uuid;
    st        text;
    refused   boolean;
    probe     text := 'migration-292-probe';
    sha       text := repeat('d', 64);
BEGIN
    BEGIN
        UPDATE shared.writing_memory_writer SET train_closed_month = NULL, updated_by = probe WHERE writer = 't9_social';
        INSERT INTO shared.writing_rule (kind, scope, tenant_id, writer, cluster_key, rule_text, status, approved_by,
                                         approved_at, support_tenants)
        VALUES ('writer_instruction', 'tenant', tenant_a, 't9_social', 'zz292-a', 'Open on the place.', 'approved',
                probe, now(), 1)
        RETURNING rule_id INTO rule_wi;
        INSERT INTO shared.prompt_eval_runs (pipeline, prompt_version, tour_count, cost_usd, details, triggered_by,
                                             run_kind, writer, stop_reason, verdict, finished_at)
        VALUES ('writing_memory', 'zz292', 5, 0, '{"candidate": "current"}', probe, 'r2', 't9_social', 'completed',
                'pass', now())
        RETURNING id INTO r2_none;
        INSERT INTO shared.prompt_eval_runs (pipeline, prompt_version, tour_count, cost_usd, details, triggered_by,
                                             run_kind, writer, stop_reason, verdict, finished_at)
        VALUES ('writing_memory', 'zz292', 20, 0, '{}', probe, 'shadow', 't9_social', 'completed', 'pass', now())
        RETURNING id INTO sh_none;
        INSERT INTO shared.writing_memory_release (writer, scope, tenant_id, release_no, train_kind, content_class,
                                                   rule_ids, items_sha256, created_by, eval_run_id, shadow_run_id)
        VALUES ('t9_social', 'tenant', tenant_a, 1, 'regular', 'rules', ARRAY[rule_wi], sha, probe, r2_none, sh_none)
        RETURNING release_id INTO rel_x;
        UPDATE shared.writing_memory_release SET status = 'evaluated' WHERE release_id = rel_x;
        UPDATE shared.writing_memory_release SET status = 'approved', approved_by = probe, approved_at = now()
         WHERE release_id = rel_x;

        -- 1. a code-train r2 pass (no release) as the eval run: refused
        refused := false;
        BEGIN
            UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = rel_x;
        EXCEPTION WHEN check_violation THEN refused := true;
        END;
        IF NOT refused THEN RAISE EXCEPTION 'migration 292: activated on an r2 run of no release'; END IF;
        -- 2. the r2 run names the release but is a seeded-fault run: refused (the r2 row is still editable here)
        UPDATE shared.prompt_eval_runs SET release_id = rel_x, details = '{"seeded_fault": "qa_trace"}'
         WHERE id = r2_none;
        refused := false;
        BEGIN
            UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = rel_x;
        EXCEPTION WHEN check_violation THEN refused := true;
        END;
        IF NOT refused THEN RAISE EXCEPTION 'migration 292: activated on a seeded-fault r2 run'; END IF;
        -- 3. the eval run is right, the shadow run names no release: refused
        UPDATE shared.prompt_eval_runs SET details = '{"candidate": "release"}' WHERE id = r2_none;
        refused := false;
        BEGIN
            UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = rel_x;
        EXCEPTION WHEN check_violation THEN refused := true;
        END;
        IF NOT refused THEN RAISE EXCEPTION 'migration 292: activated on a shadow run of no release'; END IF;
        -- 4. both runs name the release: active
        UPDATE shared.prompt_eval_runs SET release_id = rel_x WHERE id = sh_none;
        UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = rel_x;
        SELECT status INTO st FROM shared.writing_memory_release WHERE release_id = rel_x;
        IF st <> 'active' THEN RAISE EXCEPTION 'migration 292: a release with its own passing runs did not activate';
        END IF;

        RAISE EXCEPTION 'probe done' USING ERRCODE = 'ZZ292';
    EXCEPTION WHEN SQLSTATE 'ZZ292' THEN
        NULL;
    END;
    IF EXISTS (SELECT 1 FROM shared.writing_memory_release WHERE created_by = probe)
       OR EXISTS (SELECT 1 FROM shared.prompt_eval_runs WHERE triggered_by = probe)
       OR EXISTS (SELECT 1 FROM shared.writing_rule WHERE cluster_key LIKE 'zz292-%') THEN
        RAISE EXCEPTION 'migration 292: the behaviour probe was not rolled back';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('292', now(), 'AA-919 (WM-19 / WM-21 review): release guard requires the r2 eval run and the shadow run to '
                      'name the release (no code-train, seeded-fault or other release''s run as evidence)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
