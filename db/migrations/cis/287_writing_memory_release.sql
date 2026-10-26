-- Migration 287: AA-919 (WM-18) — writing-memory releases: shared.writing_memory_release (versioned, approved
-- releases per writer with an active pointer, a rollback pointer, the monthly train and the reverify state),
-- shared.writing_memory_shadow (shadow outputs, tenant-scoped, deletable) and shared.writing_memory_writer (the
-- per-writer memory switch and the monthly train close).
--
-- Why. App ADR 0010 (governed writing memory): rules and examples reach a writer only inside a versioned release that
-- one human approved and that carries its evidence; rollback moves the active pointer back without a deploy; the gate
-- must hold even if the API has a bug (decision 1: "enforced twice: by a DB CHECK and by the API"). WM-17 (CIS 284)
-- built the run ledger (prompt_eval_runs widened: run_kind, verdict, finished_at) that a release points at.
--
-- What.
--   1. shared.writing_memory_release (RLS ENABLE + FORCE; ids only, no text: rules stay in writing_rule): release_id;
--      writer a1 | t2 | t9_blog | t9_social; scope platform | tenant with tenant_id NULL exactly for platform;
--      release_no (>= 0, unique per writer and owner; 0 = release 0, the empty baseline of WM-20); train_kind
--      baseline | regular | emergency | lexicon; content_class empty | lexicon_only | repair_hint_only | rules;
--      rule_ids (<= 40) and items_sha256 (sha256 of the sorted rule ids and texts at draft time); status draft ->
--      evaluated -> approved -> active -> retired (+ rejected); the evidence r0_run_id / eval_run_id / shadow_run_id
--      (FK prompt_eval_runs, ON DELETE RESTRICT); previous_release_id (the rollback target, FK self, ON DELETE SET
--      NULL); train_month (the month of a regular release, set at its first activation); emergency_reason
--      hard_stop_1 | hard_stop_2 | hard_stop_3 + emergency_ref (the run or signal that fired); reverify, its reasons
--      and time, reverify_run_id + reverify approval (a re-run needs approval, WM-18 scope 5); fingerprint (golden
--      set name@version, the writer / judge model routes, the gate taxonomy version, the writer prompt sha256: what a
--      reverify scan compares); approved_by / approved_at / approval_ref; activated_at; retired_at / retired_reason;
--      rejected_by / rejected_reason; notes; created_by; created_at / updated_at.
--      CHECKs:
--        writing_memory_release_evidence_check (WM-18 scope 2, "activate requires eval"): an active or retired
--          release has its evidence — empty: R0 replay + eval (the AA-729 baseline import, nothing to shadow);
--          lexicon_only: R0 only (the L0 path, D11); repair_hint_only / rules: eval + shadow;
--        the content class agrees with the train kind (empty = baseline, lexicon_only = lexicon) and with the rules
--        (empty = no rule); release 0 is empty; approved / active / retired need approved_by + approved_at; active /
--        retired need activated_at; retired needs retired_at + retired_reason; rejected needs rejected_by + reason;
--        emergency needs a hard-stop reason and its ref (and only emergency has them); a regular release that went
--        active has a train month (the first of a month), only a regular one has one; reverify agrees with its time
--        and reasons (closed list); a reverify run needs its approval; size caps.
--      Indexes: ONE active release per (writer, scope, tenant) (the active pointer, WM-18 scope 3); one regular
--      release per (writer, scope, tenant, month) (the monthly train, ADR 0010 decision 6 as amended: per writer per
--      owner); release_no unique per (writer, scope, tenant); (tenant_id, status) WHERE scope = 'tenant'; (writer,
--      status).
--      Trigger shared.writing_memory_release_guard (BEFORE INSERT OR UPDATE, invoker rights, search_path pinned):
--        a release is created as a draft; transitions draft -> evaluated | rejected, evaluated -> approved | rejected |
--        draft, approved -> active | rejected, active -> retired, retired -> active (a rollback target) and nothing
--        else (restrict_violation); a release retired by a rollback ('rollback: ...') is never re-activated (a new
--        release needs a new approval); after draft the identity and content (writer, owner, number, kinds, rules,
--        items hash, emergency) are fixed, from approval the evidence and approval are fixed, and a same-status
--        update may change only the reverify bookkeeping, notes and previous_release_id to NULL (the ON DELETE SET
--        NULL of an erasure); the rules belong to the release's writer and owner (a tenant release holds only its
--        tenant's rules) and their kinds match the class; on activation (check_violation): every evidence run is a
--        finished writing_memory run of the same writer with the right kind and verdict — r0_replay pass, and for an
--        empty release byte_diffs = 0 over >= 20 inputs (WM-20); eval r2 pass, or baseline_import baseline for an
--        empty release; shadow pass — the rules are approved or active on the first activation, a regular release
--        takes the current month unless that writer closed it; activated_at is set and the retire fields cleared.
--   2. shared.writing_memory_shadow (RLS ENABLE + FORCE; output is tenant text): one shadow output of a release run:
--      release, run, writer / channel, scope / tenant_id of the INPUT's owner (a cross-tenant probe row belongs to
--      the probed tenant and goes with it), probe, input_source content_piece | tenant_tour_version |
--      generated_content (never a golden item: WM-21 excludes them), input_id, input / prompt / output sha256, output,
--      control_ref, isolation, qa_artefacts, verdict pass | fail | error, cost_usd.
--   3. shared.writing_memory_writer (platform table, no tenant column, no RLS): one row per writer, seeded:
--      memory_enabled (the kill switch, default off; on needs an active platform release, trigger) and
--      train_closed_month (the monthly train close, WM-22).
--   4. shared.prompt_eval_runs.release_id stays WITHOUT a foreign key (284 announced one; decided against): the run
--      ledger is a platform table, and the AA-839 erasure planner turns every non-tenant child of an erased table into
--      a cascade node — an ON DELETE SET NULL key from runs to a tenant release would make an erasure delete platform
--      run rows. The code that writes release_id reads the release first; a run of an erased tenant release keeps a
--      dangling id (ids only, no text). The release names its runs (r0 / eval / shadow / reverify, FK RESTRICT).
--   5. RLS on release and shadow as on writing_rule (CIS 280): <t>_cis_app_all / <t>_cis_owner_all USING (true)
--      (X1 parity: cis_app code filters tenant_id explicitly), tenant_isolation TO aa_app_user (the tenant pool holds
--      no privilege: tenants never see releases).
--   6. Grants: REVOKE ALL from PUBLIC, cis_app, aa_app_user, catalog_owner first, then cis_app: release SELECT,
--      INSERT, UPDATE, DELETE (DELETE: the AA-839 erasure of tenant releases); shadow SELECT, INSERT, DELETE (outputs
--      are immutable); writer SELECT, UPDATE. EXECUTE on the trigger functions revoked from PUBLIC.
--   7. Register 287.
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before: the roles exist; aa_app_user is not superuser / BYPASSRLS; the runner may create in shared; 284, 285
--      and 286 are registered (readiness compares max(version): a gap would hide, AA-919 critic 17); prompt_eval_runs
--      has the 284 columns; the new tables, if present, have exactly this file's columns (re-run);
--   2. after: every named constraint validated; the indexes; the three triggers; RLS on and forced on release and
--      shadow; exactly the three policies on each; privileges exactly as in point 6, no column grants; the four writer
--      rows; the AA-859 invariant v3;
--   3. behaviour (a sub-block that always rolls back), through the same tables the API uses: release 0 of a writer
--      goes draft -> evaluated -> approved -> active on a passing R0 (20 inputs, 0 byte diffs) and the baseline
--      eval; refused: an active insert, an activation without R0 (CHECK), with an R0 of 1 byte diff or 19 inputs, with
--      an R0 that did not pass, a rules release without shadow (CHECK), a lexicon_only release holding a
--      writer_instruction rule, a tenant-A release holding a tenant-B rule, a second active release (unique), a second
--      regular release in one month (unique), rule_ids changed after draft, the memory switch with no active release,
--      re-activating a rolled-back release, a regular release for a closed month; accepted: the rollback (current ->
--      retired 'rollback: ...', previous retired -> active), the memory switch with an active release, the erasure of
--      a release another release names as previous (SET NULL).
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: 3, NULL x3):
--   SELECT (SELECT count(*) FROM shared.schema_versions WHERE version IN ('284', '285', '286')) AS predecessors,
--          to_regclass('shared.writing_memory_release') AS release, to_regclass('shared.writing_memory_shadow') AS shadow,
--          to_regclass('shared.writing_memory_writer') AS writer;
--
-- Locks. CREATE TABLE / INDEX / POLICY / TRIGGER on new, empty tables; the new foreign keys take SHARE ROW EXCLUSIVE
-- on shared.prompt_eval_runs (brief: a handful of rows, written only by on-demand CLIs). lock_timeout 5s.
-- Apply through AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/) with shared.job and booking.job idle
-- (DM-11.4), after 284, 285 and 286. Re-running is a no-op apart from the guards (IF NOT EXISTS, CREATE OR REPLACE,
-- DROP ... IF EXISTS + CREATE, the constraint dropped and re-added, grants from nothing, ON CONFLICT DO NOTHING).
--
-- Order with the code. The AA-919 WM-18 / WM-20 code reads the tables on every writer call (one resolver query) but
-- fails open: with the tables missing the writers run without memory, exactly as today, and the release routes answer
-- 503 `unavailable`. Apply this file before the code deploys anyway (REQUIRED_CIS_SCHEMA = 287). The erasure inventory
-- rows (AA-839) ship with this file.
--
-- Undo (a NEW forward migration, after the code that reads them is reverted):
--   DROP TABLE shared.writing_memory_shadow;                    -- -- migrate: destructive (MIG-9)
--   DROP TABLE shared.writing_memory_release;
--   DROP TABLE shared.writing_memory_writer;
--   DROP FUNCTION shared.writing_memory_release_guard(); DROP FUNCTION shared.writing_memory_writer_guard();
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243). DB Migrate runs cis/ files as cis_owner, the owner
-- of shared and of prompt_eval_runs (245), which then owns the new tables and functions.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── Guard 1: roles, runner rights, 284-286, the run ledger's shape, re-run shape ──────────────────────────────────
DO $$
DECLARE
    owner_ns  name;
    cols      text;
    want_rel  text := 'release_id uuid, writer text, scope text, tenant_id uuid, release_no integer, train_kind text, '
                      'content_class text, rule_ids uuid[], items_sha256 text, status text, r0_run_id uuid, '
                      'eval_run_id uuid, shadow_run_id uuid, previous_release_id uuid, train_month date, '
                      'emergency_reason text, emergency_ref uuid, reverify boolean, reverify_reasons text[], '
                      'reverify_at timestamp with time zone, reverify_run_id uuid, reverify_approved_by text, '
                      'reverify_approved_at timestamp with time zone, fingerprint jsonb, approved_by text, '
                      'approved_at timestamp with time zone, approval_ref text, activated_at timestamp with time zone, '
                      'retired_at timestamp with time zone, retired_reason text, rejected_by text, '
                      'rejected_reason text, notes text, created_by text, created_at timestamp with time zone, '
                      'updated_at timestamp with time zone';
    want_sh   text := 'shadow_id uuid, release_id uuid, run_id uuid, writer text, channel text, scope text, '
                      'tenant_id uuid, probe boolean, input_source text, input_id uuid, input_sha256 text, '
                      'prompt_sha256 text, output jsonb, output_sha256 text, control_ref jsonb, isolation jsonb, '
                      'qa_artefacts text[], verdict text, cost_usd numeric(10,6), created_at timestamp with time zone';
    want_wr   text := 'writer text, memory_enabled boolean, train_closed_month date, updated_by text, '
                      'updated_at timestamp with time zone';
    t         record;
BEGIN
    IF to_regrole('cis_app') IS NULL OR to_regrole('aa_app_user') IS NULL OR to_regrole('cis_owner') IS NULL
       OR to_regrole('catalog_owner') IS NULL THEN
        RAISE EXCEPTION 'migration 287: roles cis_app, aa_app_user, cis_owner and catalog_owner must exist';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aa_app_user' AND (rolsuper OR rolbypassrls)) THEN
        RAISE EXCEPTION 'migration 287: aa_app_user is superuser or BYPASSRLS: RLS would not apply to it';
    END IF;
    SELECT pg_get_userbyid(n.nspowner) INTO owner_ns FROM pg_namespace n WHERE n.nspname = 'shared';
    IF NOT has_schema_privilege(current_user, 'shared', 'CREATE') THEN
        RAISE EXCEPTION 'migration 287: % may not create in shared (owner %); run it through DB Migrate (cis_owner)',
                        current_user, owner_ns;
    END IF;
    SELECT string_agg(v, ', ' ORDER BY v) INTO cols
      FROM unnest(ARRAY['284', '285', '286']) v
     WHERE NOT EXISTS (SELECT 1 FROM shared.schema_versions s WHERE s.version = v);
    IF cols IS NOT NULL THEN
        RAISE EXCEPTION 'migration 287: % not registered; apply the earlier CIS migrations first (readiness compares '
                        'max(version) and would hide the gap, AA-919 critic 17)', cols;
    END IF;
    IF to_regclass('shared.writing_rule') IS NULL OR to_regclass('shared.eval_golden_set') IS NULL THEN
        RAISE EXCEPTION 'migration 287: shared.writing_rule (280) and shared.eval_golden_set (284) must exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = 'shared.prompt_eval_runs'::regclass
                     AND a.attname = 'release_id' AND NOT a.attisdropped AND a.atttypid = 'uuid'::regtype)
       OR NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = 'shared.prompt_eval_runs'::regclass
                        AND a.attname = 'run_kind' AND NOT a.attisdropped) THEN
        RAISE EXCEPTION 'migration 287: shared.prompt_eval_runs lacks the 284 columns (release_id uuid, run_kind)';
    END IF;
    FOR t IN SELECT * FROM (VALUES ('shared.writing_memory_release', want_rel), ('shared.writing_memory_shadow', want_sh),
                                   ('shared.writing_memory_writer', want_wr)) v(tbl, want)
    LOOP
        IF to_regclass(t.tbl) IS NOT NULL THEN
            SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
              INTO cols
              FROM pg_attribute a
             WHERE a.attrelid = t.tbl::regclass AND a.attnum > 0 AND NOT a.attisdropped;
            IF cols IS DISTINCT FROM t.want THEN
                RAISE EXCEPTION 'migration 287: % exists with other columns: %', t.tbl, cols;
            END IF;
        END IF;
    END LOOP;
END $$;

-- ── 1. The memory switch and the monthly close (one row per writer) ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.writing_memory_writer (
    writer              text NOT NULL,
    memory_enabled      boolean NOT NULL DEFAULT false,
    train_closed_month  date,
    updated_by          text,
    updated_at          timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT writing_memory_writer_pkey PRIMARY KEY (writer),
    CONSTRAINT writing_memory_writer_writer_check CHECK (writer IN ('a1', 't2', 't9_blog', 't9_social')),
    CONSTRAINT writing_memory_writer_actor_check
        CHECK ((NOT memory_enabled OR updated_by IS NOT NULL) AND coalesce(char_length(updated_by), 0) <= 128
               AND (train_closed_month IS NULL OR extract(day FROM train_closed_month) = 1))
);
INSERT INTO shared.writing_memory_writer (writer)
VALUES ('a1'), ('t2'), ('t9_blog'), ('t9_social')
ON CONFLICT (writer) DO NOTHING;

COMMENT ON TABLE shared.writing_memory_writer IS
    'AA-919 WM-18 (CIS 287, app ADR 0010): per writer, the writing-memory switch (memory_enabled, default off: the '
    'writers resolve no release; on needs an active platform release, trigger writing_memory_writer_guard) and the '
    'monthly train close (train_closed_month: no regular release of that month or earlier activates). Platform table.';
COMMENT ON COLUMN shared.writing_memory_writer.updated_by IS
    'AA-919 (287): the shared.admin_users id of the admin, or agent:<session> for the release-0 CLI (ADR 0010 note).';

-- ── 2. The releases ────────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.writing_memory_release (
    release_id            uuid NOT NULL DEFAULT gen_random_uuid(),
    writer                text NOT NULL,
    scope                 text NOT NULL,
    tenant_id             uuid,
    release_no            integer NOT NULL,
    train_kind            text NOT NULL,
    content_class         text NOT NULL,
    rule_ids              uuid[] NOT NULL DEFAULT '{}'::uuid[],
    items_sha256          text NOT NULL,
    status                text NOT NULL DEFAULT 'draft',
    r0_run_id             uuid,
    eval_run_id           uuid,
    shadow_run_id         uuid,
    previous_release_id   uuid,
    train_month           date,
    emergency_reason      text,
    emergency_ref         uuid,
    reverify              boolean NOT NULL DEFAULT false,
    reverify_reasons      text[] NOT NULL DEFAULT '{}'::text[],
    reverify_at           timestamp with time zone,
    reverify_run_id       uuid,
    reverify_approved_by  text,
    reverify_approved_at  timestamp with time zone,
    fingerprint           jsonb NOT NULL DEFAULT '{}'::jsonb,
    approved_by           text,
    approved_at           timestamp with time zone,
    approval_ref          text,
    activated_at          timestamp with time zone,
    retired_at            timestamp with time zone,
    retired_reason        text,
    rejected_by           text,
    rejected_reason       text,
    notes                 text,
    created_by            text NOT NULL,
    created_at            timestamp with time zone NOT NULL DEFAULT now(),
    updated_at            timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT writing_memory_release_pkey PRIMARY KEY (release_id),
    CONSTRAINT writing_memory_release_r0_fkey FOREIGN KEY (r0_run_id) REFERENCES shared.prompt_eval_runs (id)
        ON DELETE RESTRICT,
    CONSTRAINT writing_memory_release_eval_fkey FOREIGN KEY (eval_run_id) REFERENCES shared.prompt_eval_runs (id)
        ON DELETE RESTRICT,
    CONSTRAINT writing_memory_release_shadow_fkey FOREIGN KEY (shadow_run_id) REFERENCES shared.prompt_eval_runs (id)
        ON DELETE RESTRICT,
    CONSTRAINT writing_memory_release_reverify_fkey FOREIGN KEY (reverify_run_id)
        REFERENCES shared.prompt_eval_runs (id) ON DELETE RESTRICT,
    CONSTRAINT writing_memory_release_previous_fkey FOREIGN KEY (previous_release_id)
        REFERENCES shared.writing_memory_release (release_id) ON DELETE SET NULL,
    CONSTRAINT writing_memory_release_writer_check CHECK (writer IN ('a1', 't2', 't9_blog', 't9_social')),
    CONSTRAINT writing_memory_release_scope_check CHECK (scope IN ('platform', 'tenant')),
    CONSTRAINT writing_memory_release_scope_tenant_ck
        CHECK ((scope = 'platform' AND tenant_id IS NULL) OR (scope = 'tenant' AND tenant_id IS NOT NULL)),
    CONSTRAINT writing_memory_release_kind_check
        CHECK (train_kind IN ('baseline', 'regular', 'emergency', 'lexicon')
               AND content_class IN ('empty', 'lexicon_only', 'repair_hint_only', 'rules')),
    CONSTRAINT writing_memory_release_class_check
        CHECK ((content_class = 'empty') = (train_kind = 'baseline')
               AND (content_class = 'lexicon_only') = (train_kind = 'lexicon')
               AND (content_class = 'empty') = (cardinality(rule_ids) = 0)
               AND (release_no <> 0 OR content_class = 'empty') AND release_no >= 0),
    CONSTRAINT writing_memory_release_status_check
        CHECK (status IN ('draft', 'evaluated', 'approved', 'active', 'retired', 'rejected')),
    CONSTRAINT writing_memory_release_evidence_check
        CHECK (status NOT IN ('active', 'retired')
               OR (content_class = 'empty' AND r0_run_id IS NOT NULL AND eval_run_id IS NOT NULL)
               OR (content_class = 'lexicon_only' AND r0_run_id IS NOT NULL)
               OR (content_class IN ('repair_hint_only', 'rules') AND eval_run_id IS NOT NULL
                   AND shadow_run_id IS NOT NULL)),
    CONSTRAINT writing_memory_release_approval_check
        CHECK ((status NOT IN ('approved', 'active', 'retired') OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
               AND (status NOT IN ('active', 'retired') OR activated_at IS NOT NULL)
               AND (status <> 'retired' OR (retired_at IS NOT NULL AND retired_reason IS NOT NULL))
               AND (status <> 'rejected' OR (rejected_by IS NOT NULL AND rejected_reason IS NOT NULL))),
    CONSTRAINT writing_memory_release_emergency_check
        CHECK ((train_kind = 'emergency') = (emergency_reason IS NOT NULL)
               AND (emergency_reason IS NULL) = (emergency_ref IS NULL)
               AND (emergency_reason IS NULL OR emergency_reason IN ('hard_stop_1', 'hard_stop_2', 'hard_stop_3'))),
    CONSTRAINT writing_memory_release_train_check
        CHECK ((train_month IS NULL OR (train_kind = 'regular' AND extract(day FROM train_month) = 1))
               AND (train_kind <> 'regular' OR status NOT IN ('active', 'retired') OR train_month IS NOT NULL)),
    CONSTRAINT writing_memory_release_reverify_check
        CHECK (reverify = (reverify_at IS NOT NULL)
               AND (reverify OR cardinality(reverify_reasons) = 0)
               AND reverify_reasons <@ ARRAY['golden_set', 'model_route', 'gate_taxonomy',
                                             'prompt_version_mismatch']::text[]
               AND (reverify_run_id IS NULL OR (reverify_approved_by IS NOT NULL AND reverify_approved_at IS NOT NULL))),
    CONSTRAINT writing_memory_release_size_check
        CHECK (cardinality(rule_ids) <= 40 AND items_sha256 ~ '^[0-9a-f]{64}$'
               AND jsonb_typeof(fingerprint) = 'object' AND pg_column_size(fingerprint) <= 8192
               AND coalesce(char_length(approved_by), 0) <= 128 AND coalesce(char_length(approval_ref), 0) <= 300
               AND coalesce(char_length(retired_reason), 0) <= 500 AND coalesce(char_length(rejected_by), 0) <= 128
               AND coalesce(char_length(rejected_reason), 0) <= 500 AND coalesce(char_length(notes), 0) <= 1000
               AND coalesce(char_length(reverify_approved_by), 0) <= 128
               AND char_length(created_by) BETWEEN 1 AND 128 AND cardinality(reverify_reasons) <= 4)
);
CREATE UNIQUE INDEX IF NOT EXISTS writing_memory_release_one_active
    ON shared.writing_memory_release (writer, scope,
                                      coalesce(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid))
    WHERE status = 'active';
CREATE UNIQUE INDEX IF NOT EXISTS writing_memory_release_train_slot
    ON shared.writing_memory_release (writer, scope,
                                      coalesce(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), train_month)
    WHERE train_kind = 'regular' AND train_month IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS writing_memory_release_number_uq
    ON shared.writing_memory_release (writer, scope,
                                      coalesce(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), release_no);
CREATE INDEX IF NOT EXISTS writing_memory_release_tenant_idx
    ON shared.writing_memory_release (tenant_id, status) WHERE scope = 'tenant';
CREATE INDEX IF NOT EXISTS writing_memory_release_writer_status_idx
    ON shared.writing_memory_release (writer, status);

COMMENT ON TABLE shared.writing_memory_release IS
    'AA-919 WM-18 (CIS 287, app ADR 0010): a versioned release of learned writing memory for one writer (platform or '
    'one tenant). Ids only (rules by id; their text stays in writing_rule). One active release per writer and owner '
    '(the pointer the writers resolve); rollback = previous retired -> active. Activation needs its evidence: CHECK '
    'writing_memory_release_evidence_check + trigger writing_memory_release_guard (runs, kinds, verdicts), and the API '
    'checks the same (services/writing_memory/releases.py evidence_problem). RLS ENABLE + FORCE; tenant rows deleted '
    'with the tenant (AA-839).';
COMMENT ON COLUMN shared.writing_memory_release.release_no IS
    'AA-919 (287): per writer and owner; 0 = release 0, the empty baseline (WM-20: byte-identical prompts).';
COMMENT ON COLUMN shared.writing_memory_release.items_sha256 IS
    'AA-919 (287): sha256 of the sorted (rule_id, rule_text, replacement) at draft time; release 0 hashes an empty list.';
COMMENT ON COLUMN shared.writing_memory_release.fingerprint IS
    'AA-919 (287): what a reverify scan compares: golden set name@version, the writer and judge stage routes, the gate '
    'taxonomy version, the writer prompt sha256 (the prompt register of WM-22).';
COMMENT ON COLUMN shared.writing_memory_release.approved_by IS
    'AA-919 (287): the shared.admin_users id of the human who approved it (one human click, ADR 0010 decision 1), or '
    'agent:<session> on the release-0 CLI with approval_ref naming the human decision (ADR 0010 note, empty class only).';
COMMENT ON COLUMN shared.writing_memory_release.approval_ref IS
    'AA-919 (287): a link or id of the approval record (e.g. the decision page); no free text from tenants.';
COMMENT ON COLUMN shared.writing_memory_release.notes IS
    'pii:free_text; AA-919 (287): admin notes on the release (staff text; never tenant text).';
COMMENT ON COLUMN shared.writing_memory_release.retired_reason IS
    'pii:free_text; AA-919 (287): superseded, or rollback: <reason> (a rolled-back release is never re-activated).';
COMMENT ON COLUMN shared.writing_memory_release.rejected_reason IS
    'pii:free_text; AA-919 (287): why the release was rejected (staff text).';
COMMENT ON COLUMN shared.writing_memory_release.reverify IS
    'AA-919 (287): the golden set, a model route or the gate taxonomy changed since the evidence: the release keeps '
    'serving, flagged; a re-run (reverify_run_id) needs approval (WM-18 scope 5).';

-- ── 3. Shadow outputs ──────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.writing_memory_shadow (
    shadow_id      uuid NOT NULL DEFAULT gen_random_uuid(),
    release_id     uuid NOT NULL,
    run_id         uuid NOT NULL,
    writer         text NOT NULL,
    channel        text,
    scope          text NOT NULL,
    tenant_id      uuid,
    probe          boolean NOT NULL DEFAULT false,
    input_source   text NOT NULL,
    input_id       uuid NOT NULL,
    input_sha256   text NOT NULL,
    prompt_sha256  text,
    output         jsonb,
    output_sha256  text,
    control_ref    jsonb,
    isolation      jsonb NOT NULL DEFAULT '{}'::jsonb,
    qa_artefacts   text[] NOT NULL DEFAULT '{}'::text[],
    verdict        text NOT NULL,
    cost_usd       numeric(10,6) NOT NULL DEFAULT 0,
    created_at     timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT writing_memory_shadow_pkey PRIMARY KEY (shadow_id),
    CONSTRAINT writing_memory_shadow_release_fkey FOREIGN KEY (release_id)
        REFERENCES shared.writing_memory_release (release_id) ON DELETE CASCADE,
    CONSTRAINT writing_memory_shadow_run_fkey FOREIGN KEY (run_id) REFERENCES shared.prompt_eval_runs (id)
        ON DELETE CASCADE,
    CONSTRAINT writing_memory_shadow_input_key UNIQUE (run_id, input_source, input_id),
    CONSTRAINT writing_memory_shadow_writer_check CHECK (writer IN ('a1', 't2', 't9_blog', 't9_social')),
    CONSTRAINT writing_memory_shadow_channel_check
        CHECK ((writer IN ('a1', 't2') AND channel IS NULL)
               OR (writer = 't9_blog' AND channel = 'blog')
               OR (writer = 't9_social' AND channel IS NOT NULL AND channel <> 'blog'
                   AND channel ~ '^[a-z_]{1,32}$')),
    CONSTRAINT writing_memory_shadow_scope_check CHECK (scope IN ('platform', 'tenant')),
    CONSTRAINT writing_memory_shadow_scope_tenant_ck
        CHECK ((scope = 'platform' AND tenant_id IS NULL) OR (scope = 'tenant' AND tenant_id IS NOT NULL)),
    CONSTRAINT writing_memory_shadow_source_check
        CHECK (input_source IN ('content_piece', 'tenant_tour_version', 'generated_content')),
    CONSTRAINT writing_memory_shadow_verdict_check CHECK (verdict IN ('pass', 'fail', 'error')),
    CONSTRAINT writing_memory_shadow_output_check
        CHECK ((output IS NULL OR (jsonb_typeof(output) = 'object' AND pg_column_size(output) <= 131072))
               AND (output IS NULL) = (output_sha256 IS NULL)
               AND (output_sha256 IS NULL OR output_sha256 ~ '^[0-9a-f]{64}$')
               AND input_sha256 ~ '^[0-9a-f]{64}$' AND (prompt_sha256 IS NULL OR prompt_sha256 ~ '^[0-9a-f]{64}$')),
    CONSTRAINT writing_memory_shadow_size_check
        CHECK (jsonb_typeof(isolation) = 'object' AND pg_column_size(isolation) <= 8192
               AND (control_ref IS NULL OR (jsonb_typeof(control_ref) = 'object' AND pg_column_size(control_ref) <= 4096))
               AND cardinality(qa_artefacts) <= 50 AND cost_usd >= 0)
);
CREATE INDEX IF NOT EXISTS writing_memory_shadow_release_idx ON shared.writing_memory_shadow (release_id);
CREATE INDEX IF NOT EXISTS writing_memory_shadow_tenant_idx ON shared.writing_memory_shadow (tenant_id)
    WHERE scope = 'tenant';

COMMENT ON TABLE shared.writing_memory_shadow IS
    'AA-919 WM-18 (CIS 287, app ADR 0010 decisions 7 and 11): one shadow output of a release run (WM-21), never shown to '
    'a tenant. scope / tenant_id are the INPUT''s owner (a cross-tenant probe row goes with the probed tenant). RLS '
    'ENABLE + FORCE; tenant rows deleted with the tenant (AA-839); immutable (no UPDATE grant).';
COMMENT ON COLUMN shared.writing_memory_shadow.output IS
    'pii:free_text; AA-919 (287): the shadow writer output (tenant text on T2 / T9 inputs).';
COMMENT ON COLUMN shared.writing_memory_shadow.isolation IS
    'AA-919 (287): the isolation probe result (counts, scores and ids only).';

-- ── 4. The run ledger names its release by id only (no FK: see point 4 above) ────────────────────────────────────
COMMENT ON COLUMN shared.prompt_eval_runs.release_id IS
    'AA-919 (284 / 287): the shared.writing_memory_release the run evaluated; no foreign key on purpose (a platform '
    'ledger: an erased tenant release leaves a dangling id, never a cascade into the runs; CIS 287 point 4).';

-- ── 5. The release guard (trigger) ────────────────────────────────────────────────────────────────────────────────
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
            SELECT r.pipeline, r.writer, r.run_kind, r.verdict, r.finished_at INTO run
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
        END IF;
        IF NEW.content_class IN ('repair_hint_only', 'rules') THEN
            SELECT r.pipeline, r.writer, r.run_kind, r.verdict, r.finished_at INTO run
              FROM shared.prompt_eval_runs r WHERE r.id = NEW.shadow_run_id;
            IF NOT FOUND OR run.pipeline <> 'writing_memory' OR run.writer IS DISTINCT FROM NEW.writer
               OR run.run_kind <> 'shadow' OR run.verdict IS DISTINCT FROM 'pass' OR run.finished_at IS NULL THEN
                RAISE EXCEPTION 'shared.writing_memory_release: activation needs a finished, passing shadow run of '
                                'writer % (AA-919)', NEW.writer USING ERRCODE = 'check_violation';
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
    'byte_diffs = 0 over >= 20 inputs for an empty release), approved rules, the monthly train. SECURITY INVOKER.';

DROP TRIGGER IF EXISTS writing_memory_release_guard ON shared.writing_memory_release;
CREATE TRIGGER writing_memory_release_guard
    BEFORE INSERT OR UPDATE ON shared.writing_memory_release
    FOR EACH ROW EXECUTE FUNCTION shared.writing_memory_release_guard();

CREATE OR REPLACE FUNCTION shared.writing_memory_writer_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.memory_enabled AND NOT OLD.memory_enabled
       AND NOT EXISTS (SELECT 1 FROM shared.writing_memory_release r
                        WHERE r.writer = NEW.writer AND r.scope = 'platform' AND r.status = 'active') THEN
        RAISE EXCEPTION 'shared.writing_memory_writer: memory for % needs an active platform release (release 0 '
                        'first, WM-20) (AA-919)', NEW.writer USING ERRCODE = 'check_violation';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION shared.writing_memory_writer_guard() FROM PUBLIC;
COMMENT ON FUNCTION shared.writing_memory_writer_guard() IS
    'AA-919 WM-18 (CIS 287): BEFORE UPDATE row trigger of shared.writing_memory_writer: memory on needs an active '
    'platform release of the writer. SECURITY INVOKER.';

DROP TRIGGER IF EXISTS writing_memory_writer_guard ON shared.writing_memory_writer;
CREATE TRIGGER writing_memory_writer_guard
    BEFORE UPDATE ON shared.writing_memory_writer
    FOR EACH ROW EXECUTE FUNCTION shared.writing_memory_writer_guard();

-- ── 6. RLS ─────────────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.writing_memory_release ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.writing_memory_release FORCE ROW LEVEL SECURITY;
ALTER TABLE shared.writing_memory_shadow ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.writing_memory_shadow FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS writing_memory_release_cis_app_all ON shared.writing_memory_release;
CREATE POLICY writing_memory_release_cis_app_all ON shared.writing_memory_release AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS writing_memory_release_cis_owner_all ON shared.writing_memory_release;
CREATE POLICY writing_memory_release_cis_owner_all ON shared.writing_memory_release AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON shared.writing_memory_release;
CREATE POLICY tenant_isolation ON shared.writing_memory_release AS PERMISSIVE FOR ALL TO aa_app_user
    USING (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.writing_memory_release IS
    'AA-919 (CIS 287): own tenant rows only, never a platform row; the tenant pool holds no privilege (tenants never '
    'see releases), the policy is the floor if one is ever granted.';

DROP POLICY IF EXISTS writing_memory_shadow_cis_app_all ON shared.writing_memory_shadow;
CREATE POLICY writing_memory_shadow_cis_app_all ON shared.writing_memory_shadow AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS writing_memory_shadow_cis_owner_all ON shared.writing_memory_shadow;
CREATE POLICY writing_memory_shadow_cis_owner_all ON shared.writing_memory_shadow AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON shared.writing_memory_shadow;
CREATE POLICY tenant_isolation ON shared.writing_memory_shadow AS PERMISSIVE FOR ALL TO aa_app_user
    USING (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.writing_memory_shadow IS
    'AA-919 (CIS 287): own tenant rows only, never a platform row; no tenant-pool privilege today.';

-- ── 7. Grants ──────────────────────────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON shared.writing_memory_release, shared.writing_memory_shadow, shared.writing_memory_writer FROM PUBLIC;
REVOKE ALL ON shared.writing_memory_release, shared.writing_memory_shadow, shared.writing_memory_writer
    FROM cis_app, aa_app_user, catalog_owner;                     -- also column grants: from nothing
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.writing_memory_release TO cis_app;
GRANT SELECT, INSERT, DELETE ON shared.writing_memory_shadow TO cis_app;
GRANT SELECT, UPDATE ON shared.writing_memory_writer TO cis_app;

-- ── Guard 2: constraints, indexes, triggers, RLS, policies, privileges, seed rows, AA-859 invariant ────────────────
DO $$
DECLARE
    missing text;
    pols    text;
    privs   text;
    bad     text;
    t       record;
    iso     text := 'tenant_isolation:permissive:*:aa_app_user:'
                    || '((scope = ''tenant''::text) AND (tenant_id = (NULLIF(current_setting(''app.tenant_id''::text, '
                    || 'true), ''''::text))::uuid)):'
                    || '((scope = ''tenant''::text) AND (tenant_id = (NULLIF(current_setting(''app.tenant_id''::text, '
                    || 'true), ''''::text))::uuid))';
BEGIN
    SELECT string_agg(want, ', ' ORDER BY want) INTO missing
      FROM unnest(ARRAY[
          'shared.writing_memory_writer:writing_memory_writer_pkey',
          'shared.writing_memory_writer:writing_memory_writer_writer_check',
          'shared.writing_memory_writer:writing_memory_writer_actor_check',
          'shared.writing_memory_release:writing_memory_release_pkey',
          'shared.writing_memory_release:writing_memory_release_r0_fkey',
          'shared.writing_memory_release:writing_memory_release_eval_fkey',
          'shared.writing_memory_release:writing_memory_release_shadow_fkey',
          'shared.writing_memory_release:writing_memory_release_reverify_fkey',
          'shared.writing_memory_release:writing_memory_release_previous_fkey',
          'shared.writing_memory_release:writing_memory_release_writer_check',
          'shared.writing_memory_release:writing_memory_release_scope_check',
          'shared.writing_memory_release:writing_memory_release_scope_tenant_ck',
          'shared.writing_memory_release:writing_memory_release_kind_check',
          'shared.writing_memory_release:writing_memory_release_class_check',
          'shared.writing_memory_release:writing_memory_release_status_check',
          'shared.writing_memory_release:writing_memory_release_evidence_check',
          'shared.writing_memory_release:writing_memory_release_approval_check',
          'shared.writing_memory_release:writing_memory_release_emergency_check',
          'shared.writing_memory_release:writing_memory_release_train_check',
          'shared.writing_memory_release:writing_memory_release_reverify_check',
          'shared.writing_memory_release:writing_memory_release_size_check',
          'shared.writing_memory_shadow:writing_memory_shadow_pkey',
          'shared.writing_memory_shadow:writing_memory_shadow_release_fkey',
          'shared.writing_memory_shadow:writing_memory_shadow_run_fkey',
          'shared.writing_memory_shadow:writing_memory_shadow_input_key',
          'shared.writing_memory_shadow:writing_memory_shadow_writer_check',
          'shared.writing_memory_shadow:writing_memory_shadow_channel_check',
          'shared.writing_memory_shadow:writing_memory_shadow_scope_check',
          'shared.writing_memory_shadow:writing_memory_shadow_scope_tenant_ck',
          'shared.writing_memory_shadow:writing_memory_shadow_source_check',
          'shared.writing_memory_shadow:writing_memory_shadow_verdict_check',
          'shared.writing_memory_shadow:writing_memory_shadow_output_check',
          'shared.writing_memory_shadow:writing_memory_shadow_size_check']) AS want
     WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                        WHERE c.conrelid = split_part(want, ':', 1)::regclass AND c.conname = split_part(want, ':', 2)
                          AND c.convalidated);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 287: constraints missing or not validated: %', missing;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = 'shared.prompt_eval_runs'::regclass
                 AND c.contype = 'f' AND c.confrelid = 'shared.writing_memory_release'::regclass) THEN
        RAISE EXCEPTION 'migration 287: prompt_eval_runs must not reference writing_memory_release (erasure planner)';
    END IF;

    SELECT string_agg(want, ', ' ORDER BY want) INTO missing
      FROM unnest(ARRAY['writing_memory_release_one_active', 'writing_memory_release_train_slot',
                        'writing_memory_release_number_uq', 'writing_memory_release_tenant_idx',
                        'writing_memory_release_writer_status_idx', 'writing_memory_shadow_release_idx',
                        'writing_memory_shadow_tenant_idx']) AS want
     WHERE NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                        JOIN pg_namespace n ON n.oid = c.relnamespace
                       WHERE n.nspname = 'shared' AND c.relname = want AND x.indisvalid);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 287: indexes missing or invalid: %', missing;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                    WHERE c.relname = 'writing_memory_release_one_active' AND x.indisunique
                      AND pg_get_expr(x.indpred, x.indrelid) = '(status = ''active''::text)')
       OR NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                       WHERE c.relname = 'writing_memory_release_train_slot' AND x.indisunique
                         AND pg_get_expr(x.indpred, x.indrelid)
                             = '((train_kind = ''regular''::text) AND (train_month IS NOT NULL))') THEN
        RAISE EXCEPTION 'migration 287: the active-pointer / train-slot indexes are not as this file defines them';
    END IF;

    FOR t IN SELECT * FROM (VALUES ('shared.writing_memory_release'::regclass, 'writing_memory_release_guard',
                                    'shared.writing_memory_release_guard()'),
                                   ('shared.writing_memory_writer'::regclass, 'writing_memory_writer_guard',
                                    'shared.writing_memory_writer_guard()')) v(tbl, tg, fn)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_trigger tg
                        WHERE tg.tgrelid = t.tbl AND tg.tgname = t.tg AND NOT tg.tgisinternal
                          AND tg.tgfoid = t.fn::regprocedure AND tg.tgenabled = 'O') THEN
            RAISE EXCEPTION 'migration 287: trigger % missing or disabled', t.tg;
        END IF;
        IF has_function_privilege('public', t.fn, 'EXECUTE') THEN
            RAISE EXCEPTION 'migration 287: PUBLIC may execute %', t.fn;
        END IF;
    END LOOP;

    FOR t IN SELECT * FROM (VALUES ('shared.writing_memory_release'::regclass, 'writing_memory_release'),
                                   ('shared.writing_memory_shadow'::regclass, 'writing_memory_shadow')) v(tbl, short)
    LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = t.tbl) THEN
            RAISE EXCEPTION 'migration 287: % RLS is not on and forced (ADR 0010 decision 10)', t.tbl;
        END IF;
        SELECT string_agg(p.polname || ':' || CASE WHEN p.polpermissive THEN 'permissive' ELSE 'restrictive' END
                          || ':' || p.polcmd::text || ':'
                          || array_to_string(ARRAY(SELECT pg_get_userbyid(r) FROM unnest(p.polroles) r ORDER BY 1), ',')
                          || ':' || pg_get_expr(p.polqual, p.polrelid) || ':' || pg_get_expr(p.polwithcheck, p.polrelid),
                          ' | ' ORDER BY p.polname)
          INTO pols FROM pg_policy p WHERE p.polrelid = t.tbl;
        IF pols IS DISTINCT FROM          -- polname order: tenant_isolation sorts before writing_memory_*
             iso || ' | ' || t.short || '_cis_app_all:permissive:*:cis_app:true:true | '
             || t.short || '_cis_owner_all:permissive:*:cis_owner:true:true' THEN
            RAISE EXCEPTION 'migration 287: unexpected policies on %: %', t.tbl, pols;
        END IF;
    END LOOP;

    FOR t IN SELECT * FROM (VALUES ('shared.writing_memory_release'::regclass,
                                    'cis_app:DELETE, cis_app:INSERT, cis_app:SELECT, cis_app:UPDATE'),
                                   ('shared.writing_memory_shadow'::regclass,
                                    'cis_app:DELETE, cis_app:INSERT, cis_app:SELECT'),
                                   ('shared.writing_memory_writer'::regclass, 'cis_app:SELECT, cis_app:UPDATE'))
                           v(tbl, want)
    LOOP
        SELECT string_agg(r || ':' || p, ', ' ORDER BY r COLLATE "C", p COLLATE "C") INTO privs FROM (
            SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r, a.privilege_type AS p
              FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
             WHERE c.oid = t.tbl
               AND (a.grantee = 0 OR a.grantee IN ('cis_app'::regrole, 'aa_app_user'::regrole,
                                                   'catalog_owner'::regrole))) x;
        IF privs IS DISTINCT FROM t.want THEN
            RAISE EXCEPTION 'migration 287: unexpected privileges on %: %', t.tbl, privs;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = t.tbl AND a.attacl IS NOT NULL) THEN
            RAISE EXCEPTION 'migration 287: column-level grants on %', t.tbl;
        END IF;
    END LOOP;

    IF (SELECT count(*) FROM shared.writing_memory_writer WHERE writer IN ('a1', 't2', 't9_blog', 't9_social')) <> 4 THEN
        RAISE EXCEPTION 'migration 287: the four writer rows are missing';
    END IF;

    -- the AA-859 invariant, version 3 (same text as 284 guard 2 / NO_PRIVILEGE_WITHOUT_RLS_SQL_V3)
    SELECT string_agg(rel || ' ' || privilege_type || COALESCE('(' || column_name || ')', ''), ', ') INTO bad FROM (
SELECT c.oid::regclass::text AS rel, a.privilege_type, NULL::text AS column_name
  FROM pg_class c
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
 CROSS JOIN LATERAL aclexplode(c.relacl) a
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND NOT c.relrowsecurity
   AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
   AND ns.nspname NOT LIKE 'pg_toast%'
   AND a.grantee = 'aa_app_user'::regrole
   AND NOT (ns.nspname = 'catalog'
            AND c.relowner IS NOT DISTINCT FROM to_regrole('catalog_owner')
            AND a.privilege_type = 'SELECT')
   AND NOT (ns.nspname || '.' || c.relname = ANY (ARRAY['acp_contract.route', 'acp_contract.atom_segment',
                                                        'acp_contract.atom_segment_member',
                                                        'acp_contract.atom_segment_alias',
                                                        'acp_shared.place_card_alias', 'acp_shared.atom_place_card',
                                                        'gold_aa_internal.v_tour_liveness'])
            AND a.privilege_type = 'SELECT')
UNION ALL
SELECT c.oid::regclass::text, a.privilege_type, att.attname::text
  FROM pg_class c
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
  JOIN pg_attribute att ON att.attrelid = c.oid AND att.attacl IS NOT NULL AND NOT att.attisdropped
 CROSS JOIN LATERAL aclexplode(att.attacl) a
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND NOT c.relrowsecurity
   AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
   AND ns.nspname NOT LIKE 'pg_toast%'
   AND a.grantee = 'aa_app_user'::regrole
   AND NOT (ns.nspname || '.' || c.relname = 'acp_shared.place_card'
            AND att.attname IN ('card_id', 'status')
            AND a.privilege_type = 'SELECT')
ORDER BY 1, 3, 2
    ) v;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 287: aa_app_user holds privileges on relations without RLS: % (AA-859 invariant v3)',
            bad;
    END IF;
END $$;

-- ── Guard 3: behaviour (a sub-block that always rolls back) ────────────────────────────────────────────────────────
DO $$
DECLARE
    tenant_a   uuid := gen_random_uuid();
    tenant_b   uuid := gen_random_uuid();
    gset       uuid;
    base_run   uuid;
    r0_ok      uuid;
    r0_diff    uuid;
    r0_few     uuid;
    r0_fail    uuid;
    r2_ok      uuid;
    rule_wi    uuid;
    rule_lex   uuid;
    rule_b     uuid;
    rel0       uuid;
    rel1       uuid;
    rel_x      uuid;
    rel_t0     uuid;
    rel_t1     uuid;
    n          bigint;
    st         text;
    refused    boolean;
    bad        text;
    sha        text := repeat('b', 64);
    probe      text := 'migration-287-probe';
BEGIN
    BEGIN
        INSERT INTO shared.eval_golden_set (name, version, source_uri, source_sha256, seed, item_count, imported_by)
        VALUES ('zz287_probe', '0.0.1', 'file:zz287.json', sha, 729, 0, probe)
        RETURNING set_id INTO gset;
        INSERT INTO shared.prompt_eval_runs (pipeline, prompt_version, tour_count, cost_usd, details, triggered_by,
                                             run_kind, writer, golden_set_id, stop_reason, verdict, finished_at)
        VALUES ('writing_memory', 'aa729-frozen@0.0.1', 0, 0, '{}', probe, 'baseline_import', 't9_social', gset,
                'completed', 'baseline', now())
        RETURNING id INTO base_run;
        INSERT INTO shared.prompt_eval_runs (pipeline, prompt_version, tour_count, cost_usd, details, triggered_by,
                                             run_kind, writer, stop_reason, verdict, finished_at)
        VALUES ('writing_memory', 'zz287', 20, 0, '{"inputs": 20, "byte_diffs": 0}', probe, 'r0_replay', 't9_social',
                'completed', 'pass', now())
        RETURNING id INTO r0_ok;
        INSERT INTO shared.prompt_eval_runs (pipeline, prompt_version, tour_count, cost_usd, details, triggered_by,
                                             run_kind, writer, stop_reason, verdict, finished_at)
        VALUES ('writing_memory', 'zz287', 20, 0, '{"inputs": 20, "byte_diffs": 1}', probe, 'r0_replay', 't9_social',
                'completed', 'pass', now())
        RETURNING id INTO r0_diff;
        INSERT INTO shared.prompt_eval_runs (pipeline, prompt_version, tour_count, cost_usd, details, triggered_by,
                                             run_kind, writer, stop_reason, verdict, finished_at)
        VALUES ('writing_memory', 'zz287', 19, 0, '{"inputs": 19, "byte_diffs": 0}', probe, 'r0_replay', 't9_social',
                'completed', 'pass', now())
        RETURNING id INTO r0_few;
        INSERT INTO shared.prompt_eval_runs (pipeline, prompt_version, tour_count, cost_usd, details, triggered_by,
                                             run_kind, writer, stop_reason, verdict, finished_at)
        VALUES ('writing_memory', 'zz287', 20, 0, '{"inputs": 20, "byte_diffs": 0}', probe, 'r0_replay', 't9_social',
                'completed', 'fail', now())
        RETURNING id INTO r0_fail;
        INSERT INTO shared.prompt_eval_runs (pipeline, prompt_version, tour_count, cost_usd, details, triggered_by,
                                             run_kind, writer, stop_reason, verdict, finished_at)
        VALUES ('writing_memory', 'zz287', 5, 0, '{}', probe, 'r2', 't9_social', 'completed', 'pass', now())
        RETURNING id INTO r2_ok;
        INSERT INTO shared.writing_rule (kind, scope, writer, cluster_key, rule_text, status, approved_by, approved_at)
        VALUES ('writer_instruction', 'platform', 't9_social', 'zz287-a', 'Open on the place, not on the reader.',
                'approved', probe, now())
        RETURNING rule_id INTO rule_wi;
        INSERT INTO shared.writing_rule (kind, scope, writer, cluster_key, rule_text, status, approved_by, approved_at)
        VALUES ('lexicon', 'platform', 't9_social', 'zz287-b', 'Do not write zzword.', 'approved', probe, now())
        RETURNING rule_id INTO rule_lex;
        INSERT INTO shared.writing_rule (kind, scope, tenant_id, writer, cluster_key, rule_text, status, approved_by,
                                         approved_at, support_tenants)
        VALUES ('writer_instruction', 'tenant', tenant_b, 't9_social', 'zz287-c', 'Keep the first line short.',
                'approved', probe, now(), 1)
        RETURNING rule_id INTO rule_b;

        -- the switch cannot go on before a platform release is active
        refused := false;
        BEGIN
            UPDATE shared.writing_memory_writer SET memory_enabled = true, updated_by = probe WHERE writer = 't9_social';
        EXCEPTION WHEN check_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 287: memory switched on with no active release';
        END IF;

        -- release 0 of t9_social: draft -> evaluated -> approved -> active, on R0 + the baseline eval
        INSERT INTO shared.writing_memory_release (writer, scope, release_no, train_kind, content_class, items_sha256,
                                                   created_by)
        VALUES ('t9_social', 'platform', 0, 'baseline', 'empty', sha, probe)
        RETURNING release_id INTO rel0;
        UPDATE shared.writing_memory_release SET r0_run_id = r0_diff, eval_run_id = base_run, status = 'evaluated'
         WHERE release_id = rel0;
        UPDATE shared.writing_memory_release SET status = 'approved', approved_by = probe, approved_at = now()
         WHERE release_id = rel0;
        -- the CHECK refuses an activation without R0 even if the trigger were bypassed: tested by the API mirror and
        -- the integration test; here the approved row holds r0_diff (1 byte diff): refused by the trigger
        FOREACH bad IN ARRAY ARRAY[
            format($q$UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = %L$q$, rel0)]
        LOOP
            refused := false;
            BEGIN EXECUTE bad; EXCEPTION WHEN check_violation THEN refused := true; END;
            IF NOT refused THEN RAISE EXCEPTION 'migration 287: activated release 0 on an R0 with 1 byte diff'; END IF;
        END LOOP;
        -- evidence is fixed from approval on: a new release (number 9) with the passing runs instead
        INSERT INTO shared.writing_memory_release (writer, scope, release_no, train_kind, content_class, items_sha256,
                                                   created_by, r0_run_id, eval_run_id)
        VALUES ('t9_social', 'platform', 9, 'baseline', 'empty', sha, probe, r0_few, base_run)
        RETURNING release_id INTO rel_x;
        UPDATE shared.writing_memory_release SET status = 'evaluated' WHERE release_id = rel_x;
        UPDATE shared.writing_memory_release SET status = 'approved', approved_by = probe, approved_at = now()
         WHERE release_id = rel_x;
        refused := false;
        BEGIN
            UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = rel_x;
        EXCEPTION WHEN check_violation THEN refused := true;
        END;
        IF NOT refused THEN RAISE EXCEPTION 'migration 287: activated on an R0 over 19 inputs'; END IF;
        UPDATE shared.writing_memory_release SET status = 'rejected', rejected_by = probe, rejected_reason = 'probe'
         WHERE release_id = rel_x;

        INSERT INTO shared.writing_memory_release (writer, scope, release_no, train_kind, content_class, items_sha256,
                                                   created_by, r0_run_id, eval_run_id, status)
        VALUES ('t9_social', 'platform', 8, 'baseline', 'empty', sha, probe, r0_fail, base_run, 'draft')
        RETURNING release_id INTO rel_x;
        UPDATE shared.writing_memory_release SET status = 'evaluated' WHERE release_id = rel_x;
        UPDATE shared.writing_memory_release SET status = 'approved', approved_by = probe, approved_at = now()
         WHERE release_id = rel_x;
        refused := false;
        BEGIN
            UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = rel_x;
        EXCEPTION WHEN check_violation THEN refused := true;
        END;
        IF NOT refused THEN RAISE EXCEPTION 'migration 287: activated on an R0 that did not pass'; END IF;
        UPDATE shared.writing_memory_release SET status = 'rejected', rejected_by = probe, rejected_reason = 'probe'
         WHERE release_id = rel_x;

        -- the good release 1 (number 1, baseline, the passing R0): active
        INSERT INTO shared.writing_memory_release (writer, scope, release_no, train_kind, content_class, items_sha256,
                                                   created_by, r0_run_id, eval_run_id)
        VALUES ('t9_social', 'platform', 1, 'baseline', 'empty', sha, probe, r0_ok, base_run)
        RETURNING release_id INTO rel1;
        UPDATE shared.writing_memory_release SET status = 'evaluated' WHERE release_id = rel1;
        UPDATE shared.writing_memory_release SET status = 'approved', approved_by = probe, approved_at = now()
         WHERE release_id = rel1;
        UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = rel1;
        SELECT status INTO st FROM shared.writing_memory_release WHERE release_id = rel1;
        IF st <> 'active' OR (SELECT activated_at FROM shared.writing_memory_release WHERE release_id = rel1) IS NULL THEN
            RAISE EXCEPTION 'migration 287: a release with passing evidence did not activate';
        END IF;
        UPDATE shared.writing_memory_writer SET memory_enabled = true, updated_by = probe WHERE writer = 't9_social';

        -- release 2 (rules) supersedes release 1, then rolls back to it
        INSERT INTO shared.writing_memory_release (writer, scope, release_no, train_kind, content_class, rule_ids,
                                                   items_sha256, created_by, r0_run_id, eval_run_id, shadow_run_id)
        VALUES ('t9_social', 'platform', 2, 'regular', 'rules', ARRAY[rule_wi], sha, probe, r0_ok, r2_ok, r2_ok)
        RETURNING release_id INTO rel_x;
        UPDATE shared.writing_memory_release SET status = 'evaluated' WHERE release_id = rel_x;
        UPDATE shared.writing_memory_release SET status = 'approved', approved_by = probe, approved_at = now()
         WHERE release_id = rel_x;
        refused := false;
        BEGIN
            UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = rel_x;   -- shadow is an r2
        EXCEPTION WHEN check_violation THEN refused := true;
        END;
        IF NOT refused THEN RAISE EXCEPTION 'migration 287: activated a rules release with an r2 as its shadow'; END IF;
        UPDATE shared.writing_memory_release SET status = 'rejected', rejected_by = probe, rejected_reason = 'probe'
         WHERE release_id = rel_x;
        UPDATE shared.prompt_eval_runs SET run_kind = 'shadow' WHERE id = r0_fail;      -- reused as a passing shadow
        UPDATE shared.prompt_eval_runs SET verdict = 'pass' WHERE id = r0_fail;
        INSERT INTO shared.writing_memory_release (writer, scope, release_no, train_kind, content_class, rule_ids,
                                                   items_sha256, created_by, eval_run_id, shadow_run_id)
        VALUES ('t9_social', 'platform', 3, 'regular', 'rules', ARRAY[rule_wi], sha, probe, r2_ok, r0_fail)
        RETURNING release_id INTO rel_x;
        UPDATE shared.writing_memory_release SET status = 'evaluated' WHERE release_id = rel_x;
        UPDATE shared.writing_memory_release SET status = 'approved', approved_by = probe, approved_at = now()
         WHERE release_id = rel_x;
        -- a second active release of the writer: unique_violation (the pointer)
        refused := false;
        BEGIN
            UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = rel_x;
        EXCEPTION WHEN unique_violation THEN refused := true;
        END;
        IF NOT refused THEN RAISE EXCEPTION 'migration 287: two active releases for one writer'; END IF;
        UPDATE shared.writing_memory_release SET status = 'retired', retired_reason = 'superseded' WHERE release_id = rel1;
        UPDATE shared.writing_memory_release SET status = 'active', previous_release_id = rel1 WHERE release_id = rel_x;
        IF (SELECT train_month FROM shared.writing_memory_release WHERE release_id = rel_x)
           IS DISTINCT FROM date_trunc('month', now() AT TIME ZONE 'UTC')::date THEN
            RAISE EXCEPTION 'migration 287: a regular release did not take the current month';
        END IF;
        -- rollback: current -> retired (rollback: ...), previous -> active
        UPDATE shared.writing_memory_release SET status = 'retired', retired_reason = 'rollback: probe'
         WHERE release_id = rel_x;
        UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = rel1;
        SELECT status INTO st FROM shared.writing_memory_release WHERE release_id = rel1;
        IF st <> 'active' THEN RAISE EXCEPTION 'migration 287: the rollback target did not become active'; END IF;

        FOREACH bad IN ARRAY ARRAY[
            -- an active insert; a rolled-back release re-activated; rule_ids changed after draft
            format($q$INSERT INTO shared.writing_memory_release (writer, scope, release_no, train_kind, content_class,
                      items_sha256, created_by, status) VALUES ('a1', 'platform', 0, 'baseline', 'empty', %L, 'x',
                      'active')$q$, sha),
            format($q$UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = %L$q$, rel_x),
            format($q$UPDATE shared.writing_memory_release SET rule_ids = ARRAY[%L]::uuid[] WHERE release_id = %L$q$,
                   rule_lex, rel_x),
            format($q$UPDATE shared.writing_memory_release SET retired_reason = 'superseded' WHERE release_id = %L$q$,
                   rel_x)]
        LOOP
            refused := false;
            BEGIN EXECUTE bad; EXCEPTION WHEN restrict_violation THEN refused := true; END;
            IF NOT refused THEN RAISE EXCEPTION 'migration 287: accepted %', left(bad, 200); END IF;
        END LOOP;

        FOREACH bad IN ARRAY ARRAY[
            -- a lexicon_only release holding a writer_instruction rule; a tenant-A release holding a tenant-B rule; a
            -- platform release holding a tenant rule
            format($q$INSERT INTO shared.writing_memory_release (writer, scope, release_no, train_kind, content_class,
                      rule_ids, items_sha256, created_by) VALUES ('t9_social', 'platform', 20, 'lexicon',
                      'lexicon_only', ARRAY[%L]::uuid[], %L, 'x')$q$, rule_wi, sha),
            format($q$INSERT INTO shared.writing_memory_release (writer, scope, tenant_id, release_no, train_kind,
                      content_class, rule_ids, items_sha256, created_by) VALUES ('t9_social', 'tenant', %L, 21,
                      'regular', 'rules', ARRAY[%L]::uuid[], %L, 'x')$q$, tenant_a, rule_b, sha),
            format($q$INSERT INTO shared.writing_memory_release (writer, scope, release_no, train_kind, content_class,
                      rule_ids, items_sha256, created_by) VALUES ('t9_social', 'platform', 22, 'regular', 'rules',
                      ARRAY[%L]::uuid[], %L, 'x')$q$, rule_b, sha)]
        LOOP
            refused := false;
            BEGIN EXECUTE bad; EXCEPTION WHEN check_violation THEN refused := true; END;
            IF NOT refused THEN RAISE EXCEPTION 'migration 287: accepted %', left(bad, 200); END IF;
        END LOOP;
        -- the CHECK alone, with the trigger off for these statements (the runner owns the table; the probe rolls
        -- back): an empty release without R0 and a rules release without shadow cannot be active
        ALTER TABLE shared.writing_memory_release DISABLE TRIGGER writing_memory_release_guard;
        FOREACH bad IN ARRAY ARRAY[
            format($q$UPDATE shared.writing_memory_release SET r0_run_id = NULL WHERE release_id = %L$q$, rel1),
            format($q$UPDATE shared.writing_memory_release SET shadow_run_id = NULL, status = 'active',
                      activated_at = now() WHERE release_id = %L$q$, rel_x)]
        LOOP
            refused := false;
            BEGIN EXECUTE bad; EXCEPTION WHEN check_violation THEN refused := true; END;
            IF NOT refused THEN RAISE EXCEPTION 'migration 287: the evidence CHECK accepted %', left(bad, 200); END IF;
        END LOOP;
        ALTER TABLE shared.writing_memory_release ENABLE TRIGGER writing_memory_release_guard;

        -- a second regular release in one month: unique_violation (the train slot)
        INSERT INTO shared.writing_memory_release (writer, scope, release_no, train_kind, content_class, rule_ids,
                                                   items_sha256, created_by, eval_run_id, shadow_run_id)
        VALUES ('t9_social', 'platform', 4, 'regular', 'rules', ARRAY[rule_wi], sha, probe, r2_ok, r0_fail)
        RETURNING release_id INTO rel_x;
        UPDATE shared.writing_memory_release SET status = 'evaluated' WHERE release_id = rel_x;
        UPDATE shared.writing_memory_release SET status = 'approved', approved_by = probe, approved_at = now()
         WHERE release_id = rel_x;
        UPDATE shared.writing_memory_release SET status = 'retired', retired_reason = 'superseded' WHERE release_id = rel1;
        refused := false;
        BEGIN
            UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = rel_x;
        EXCEPTION WHEN unique_violation THEN refused := true;
        END;
        IF NOT refused THEN RAISE EXCEPTION 'migration 287: two regular releases in one month'; END IF;
        -- the month closed: refused (check_violation) before the slot is even looked at
        UPDATE shared.writing_memory_writer SET train_closed_month = date_trunc('month', now() AT TIME ZONE 'UTC')::date
         WHERE writer = 't9_social';
        refused := false;
        BEGIN
            UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = rel_x;
        EXCEPTION WHEN check_violation THEN refused := true;
        END;
        IF NOT refused THEN RAISE EXCEPTION 'migration 287: activated a regular release of a closed month'; END IF;

        -- tenant releases: release 1 names release 0 as previous; erasing the tenant's release 0 sets it NULL
        INSERT INTO shared.writing_memory_release (writer, scope, tenant_id, release_no, train_kind, content_class,
                                                   items_sha256, created_by, r0_run_id, eval_run_id)
        VALUES ('t9_social', 'tenant', tenant_a, 0, 'baseline', 'empty', sha, probe, r0_ok, base_run)
        RETURNING release_id INTO rel_t0;
        INSERT INTO shared.writing_memory_release (writer, scope, tenant_id, release_no, train_kind, content_class,
                                                   items_sha256, created_by, r0_run_id, eval_run_id, previous_release_id)
        VALUES ('t9_social', 'tenant', tenant_a, 1, 'baseline', 'empty', sha, probe, r0_ok, base_run, rel_t0)
        RETURNING release_id INTO rel_t1;
        UPDATE shared.writing_memory_release SET status = 'evaluated' WHERE release_id = rel_t1;
        UPDATE shared.writing_memory_release SET status = 'approved', approved_by = probe, approved_at = now()
         WHERE release_id = rel_t1;
        UPDATE shared.writing_memory_release SET status = 'active' WHERE release_id = rel_t1;
        DELETE FROM shared.writing_memory_release WHERE release_id = rel_t0;
        IF (SELECT previous_release_id FROM shared.writing_memory_release WHERE release_id = rel_t1) IS NOT NULL THEN
            RAISE EXCEPTION 'migration 287: the erasure did not clear previous_release_id';
        END IF;
        SELECT count(*) INTO n FROM shared.writing_memory_release WHERE created_by = probe;
        IF n < 5 THEN
            RAISE EXCEPTION 'migration 287: the runner reads % of its probe releases (FORCE RLS without its policy?)', n;
        END IF;

        RAISE EXCEPTION 'probe done' USING ERRCODE = 'ZZ287';
    EXCEPTION WHEN SQLSTATE 'ZZ287' THEN
        NULL;
    END;
    IF EXISTS (SELECT 1 FROM shared.eval_golden_set WHERE name LIKE 'zz287%')
       OR EXISTS (SELECT 1 FROM shared.writing_memory_release WHERE created_by = probe)
       OR EXISTS (SELECT 1 FROM shared.writing_memory_writer WHERE updated_by = probe)
       OR EXISTS (SELECT 1 FROM shared.writing_rule WHERE cluster_key LIKE 'zz287-%') THEN
        RAISE EXCEPTION 'migration 287: the behaviour probe was not rolled back';
    END IF;
    SELECT count(*) INTO n FROM shared.writing_memory_release;
    RAISE NOTICE 'migration 287: writing-memory releases under RLS (forced), % releases', n;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('287', now(), 'AA-919 WM-18: shared.writing_memory_release (active pointer, rollback, monthly train, reverify; '
                      'activation needs eval + shadow: CHECK + trigger), writing_memory_shadow, writing_memory_writer '
                      '(memory switch)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
