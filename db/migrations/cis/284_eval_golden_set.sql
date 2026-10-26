-- Migration 284: AA-919 (WM-17) — the golden set as first-class tables (shared.eval_golden_set, eval_golden_item,
-- eval_item_result) and shared.prompt_eval_runs widened into the run ledger of the writing-memory eval ladder.
--
-- Why. App ADR 0010 (governed writing memory): a release reaches a writer only after R0 / R1 / R2 / shadow evidence,
-- and R2 runs against the AA-729 golden set. Today the set is one JSON file in S3 bronze and shared.prompt_eval_runs is
-- S1-only (pipeline s1_old / s1_from_atom, results in a details jsonb, 0 rows on Dev). WM-18 (release tables, CHECK
-- "active requires eval") needs run rows to point at, and WM-19 (R2 runner) needs items with a fixed tune / holdout
-- split, tiers, traps and per-item results. The golden items of T2 / T9 are tenant text (inputs, tenant brand packs,
-- outputs), so they live only in deletable, RLS-forced tables (ADR 0010 decisions 10 and 11).
--
-- What.
--   1. shared.eval_golden_set (platform table, no tenant column, no RLS; cis_app SELECT / INSERT / UPDATE): one row per
--      imported fixture version — name (aa729), version (semver), status active | superseded (one active per name),
--      source_uri (an S3 key or a file name: never a bucket, an ARN or an account, CHECK), source_sha256 (the fixture
--      bytes; a re-import of the same version must match it), seed, holdout_pct, tier_rules (how the derived tiers
--      were computed: thresholds and cuts per writer), shared_inputs (PLATFORM inputs only: the s1:* brand packs; a
--      tenant brand pack is inlined on that tenant's items, CHECK), meta (mix, quotas, selection counts),
--      label_history, item_count (the count at import time: the AA-839 erasure later deletes tenant items, the
--      column is not kept in step), imported_by, created_at, superseded_at.
--   2. shared.eval_golden_item (RLS ENABLE + FORCE): one golden sample — sample_id, writer a1 | t2 | t9_blog |
--      t9_social, channel (NULL for a1 / t2, blog for t9_blog, another channel for t9_social), scope / tenant_id (the
--      writing_signal pattern; a1 is platform, every other writer tenant), split tune | holdout | trap with trap =
--      (split = 'trap'), kind real | synthetic, tiers (a closed list, CHECK: a new tier is a new migration), country,
--      days, input (the frozen writer input, tenant brand pack inlined), control_output (the frozen output),
--      post_edit (the frozen output was edited by a human: never a writer control, see 3), pipeline_verdict, label
--      (verdict, reason, evidence), label_verdict, label_source, injection_spec (traps only), refs (ids only),
--      input_sha256, pick_reason. Size caps on every jsonb.
--   3. shared.eval_item_result (RLS ENABLE + FORCE): one scored output per (run, item, arm, mode) — writer / scope /
--      tenant_id copied from the item (RLS and erasure; the trigger below keeps them equal), arm control | candidate,
--      mode score_only (judge the item's frozen output) | regenerate (a new writer output, stored in `output`) |
--      rejudge (re-judge a stored result: scored_result_id), phase probe | tune | holdout (= the item's split: a
--      holdout item is never scored in the tune phase), verdict pass | fail | error | skipped, score, failure_codes,
--      hard_stop, judge_model / judge_version, cost_usd, details (ids and counts only). Results are immutable
--      (cis_app SELECT / INSERT / DELETE, no UPDATE). There is no release back-link: a release names its eval run
--      (WM-18), which is enough (AA-919 critic 16).
--      Trigger shared.eval_item_result_guard (BEFORE INSERT OR UPDATE): writer / scope / tenant_id equal the item's;
--      phase matches the item's split; a control of mode score_only never scores a post_edit item (its frozen output
--      is human text, critic 10); a result belongs to a writing_memory run of the item's writer; a control of mode
--      regenerate only in a baseline_import or reverify run (controls are never regenerated elsewhere, critic 24); a
--      rejudge points at a result of the same item; the run's golden_set_id is the item's set.
--      Trigger shared.prompt_eval_runs_freeze (BEFORE UPDATE on the run ledger): once a run has results, its
--      pipeline / writer / run_kind / golden_set_id cannot change (what the result guard checked stays true).
--   4. shared.prompt_eval_runs widened (the table is empty on Dev; services/eval/regression.py keeps working:
--      pipeline s1_old, run_kind defaults to regression, every new column is nullable or has a default):
--        pipeline CHECK + 'writing_memory';
--        run_kind regression | baseline_import | r0_replay | r1 | r2 | reverify | probe | shadow (default regression);
--        writer (a1 | t2 | t9_blog | t9_social), release_id (uuid, NO foreign key: the release table comes with
--        WM-18, which adds it), golden_set_id (FK eval_golden_set, ON DELETE RESTRICT), tiers (the affected tiers of
--        an R2 run), stop_reason completed | hard_stop | futility | budget_cap | probe_fail | error, verdict pass |
--        fail | baseline | informative | invalid, cost_cap_usd, judge_kappa (-1..1) and judge_counts (the judge's
--        verdict counts only when calibrated: kappa >= 0.6, ADR 0010 alternatives / WM-19 scope 4), fingerprint
--        (golden set version, model route, taxonomy version: what a reverify compares), finished_at;
--        CHECKs: a writing_memory run has a writer, a non-regression kind, a cost and an object details; a legacy
--        run is kind regression without a writer; a finished run has a stop_reason and a verdict; tour_count >= 0.
--      The existing NOT NULL columns of a writing_memory run: prompt_version = the writer prompt hash when the run
--      knows it (r0_replay, r1, r2, reverify, probe, shadow), `aa729-frozen@<fixture version>` for a baseline_import
--      (the frozen outputs come from several historic prompts); tour_count = the number of items (results) of the
--      run; regression_detected = false (the verdict carries the outcome); triggered_by = the job id or the
--      importer's actor.
--   5. RLS on eval_golden_item and eval_item_result as on writing_rule (CIS 280): <t>_cis_app_all TO cis_app and
--      <t>_cis_owner_all TO cis_owner USING (true) WITH CHECK (true) (X1 parity, CIS 244 / 245: cis_app code filters
--      tenant_id explicitly), tenant_isolation TO aa_app_user (own tenant rows, never a platform row; the tenant pool
--      gets no privilege: tenants never see the golden set).
--   6. Grants. REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner on the three new tables first, then
--      cis_app: set SELECT, INSERT, UPDATE (supersede); item SELECT, INSERT, DELETE (a relabel is a new set version;
--      DELETE for the AA-839 tenant erasure); result SELECT, INSERT, DELETE. prompt_eval_runs grants are unchanged.
--      EXECUTE on the trigger functions revoked from PUBLIC.
--   7. Register 284.
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before: the roles exist; aa_app_user is not superuser / BYPASSRLS; the runner may create in shared; 281, 282
--      and 283 are registered (the readiness check compares max(version), so once 284 is in it would hide any missing
--      predecessor, AA-919 critic 17; all three are applied on Dev: 281 / 282 per the 25/10 schema dump, 283 by
--      AA-816 A10b); prompt_eval_runs exists with exactly the 089 columns or exactly this file's columns (re-run);
--      the new tables, if present, have exactly this file's columns;
--   2. after: every named constraint validated; the indexes; the two triggers; RLS on AND forced on item and result;
--      exactly the three policies on each; privileges exactly as in point 6, no column grants; the AA-859 invariant
--      v3;
--   3. behaviour (a sub-block that always rolls back): a legacy s1_old regression row (the services/eval/regression.py
--      INSERT) and a platform item / tenant item / baseline run / control result insert and read back; refused
--      (check_violation): an a1 item with a tenant, a T9 item without one, a t9_blog item on linkedin, an unknown
--      tier, a trap flag that disagrees with the split, a writing_memory run without a writer, an output on a
--      score_only result, a result whose tenant differs from its item's, a result in the wrong phase, a score_only
--      control on a post_edit item, a regenerated control in an r2 run, a result in a run of another golden set, a
--      run with results changing its run_kind or golden_set_id, a source_uri holding an account id, a tenant brand
--      pack in shared_inputs.
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: 3, NULL x3, 0):
--   SELECT (SELECT count(*) FROM shared.schema_versions WHERE version IN ('281', '282', '283')) AS predecessors,
--          to_regclass('shared.eval_golden_set') AS golden_set, to_regclass('shared.eval_golden_item') AS item,
--          to_regclass('shared.eval_item_result') AS result,
--          (SELECT count(*) FROM shared.prompt_eval_runs) AS eval_runs;
--
-- Locks. CREATE TABLE / INDEX / POLICY / TRIGGER on new, empty tables; ALTER TABLE and CREATE TRIGGER on
-- shared.prompt_eval_runs (ACCESS EXCLUSIVE / SHARE ROW EXCLUSIVE, brief: the table is empty on Dev and only the
-- on-demand regression script writes it). lock_timeout 5s.
-- Apply through AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/) with shared.job and booking.job idle
-- (DM-11.4), after 281, 282 and 283. Re-running is a no-op apart from the guards (IF NOT EXISTS, CREATE OR REPLACE,
-- DROP ... IF EXISTS + CREATE, constraints dropped and re-added, grants from nothing).
--
-- Order with the code. Nothing at request time reads or writes the new tables or columns (the API readiness constant
-- stays where it is). The importer (services/golden_set/importer.py, AA-919) is a CLI run by ECS exec after the apply.
-- The erasure inventory rows (AA-839) ship with this file: the planner reports a registered table that is not applied
-- yet as missing and skips it.
--
-- Undo (a NEW forward migration, after the code that writes them is reverted):
--   DROP TABLE shared.eval_item_result;                        -- -- migrate: destructive (MIG-9)
--   DROP TABLE shared.eval_golden_item;
--   DROP FUNCTION shared.eval_item_result_guard();
--   DROP TRIGGER prompt_eval_runs_freeze ON shared.prompt_eval_runs; DROP FUNCTION shared.prompt_eval_runs_freeze();
--   ALTER TABLE shared.prompt_eval_runs DROP COLUMN run_kind, ... (the 12 new columns, their constraints with them);
--   DROP TABLE shared.eval_golden_set;
--   restore prompt_eval_runs_pipeline_check to ('s1_old', 's1_from_atom') once no writing_memory row is left.
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243). DB Migrate runs cis/ files as cis_owner, the owner
-- of shared and of prompt_eval_runs (245), which then owns the new tables and the function.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── Guard 1: roles, runner rights, 281-283, the run table's shape, re-run shape ───────────────────────────────────
DO $$
DECLARE
    owner_ns  name;
    cols      text;
    runs_089  text := 'id uuid, pipeline text, prompt_version text, tour_count integer, avg_quality_score numeric, '
                      'avg_words_per_citation numeric, gate_pass_count integer, gate_fail_count integer, '
                      'cost_usd numeric, regression_detected boolean, baseline_prompt_version text, '
                      'baseline_avg_quality_score numeric, details jsonb, triggered_by text, '
                      'created_at timestamp with time zone';
    runs_284  text := runs_089 || ', run_kind text, writer text, release_id uuid, golden_set_id uuid, tiers text[], '
                      'stop_reason text, verdict text, cost_cap_usd numeric(10,4), judge_kappa numeric(4,3), '
                      'judge_counts boolean, fingerprint jsonb, finished_at timestamp with time zone';
    want_set  text := 'set_id uuid, name text, version text, status text, source_uri text, source_sha256 text, '
                      'seed integer, holdout_pct numeric(4,3), tier_rules jsonb, shared_inputs jsonb, meta jsonb, '
                      'label_history jsonb, item_count integer, imported_by text, '
                      'created_at timestamp with time zone, superseded_at timestamp with time zone';
    want_item text := 'item_id uuid, set_id uuid, sample_id text, writer text, channel text, scope text, '
                      'tenant_id uuid, split text, trap boolean, kind text, tiers text[], country text, days integer, '
                      'input jsonb, control_output jsonb, post_edit boolean, pipeline_verdict jsonb, label jsonb, '
                      'label_verdict text, label_source text, injection_spec jsonb, refs jsonb, input_sha256 text, '
                      'pick_reason text, created_at timestamp with time zone';
    want_res  text := 'result_id uuid, run_id uuid, item_id uuid, writer text, scope text, tenant_id uuid, arm text, '
                      'mode text, phase text, scored_result_id uuid, output jsonb, output_sha256 text, verdict text, '
                      'score numeric, failure_codes text[], hard_stop boolean, judge_model text, judge_version text, '
                      'cost_usd numeric(10,6), details jsonb, created_at timestamp with time zone';
    t         record;
BEGIN
    IF to_regrole('cis_app') IS NULL OR to_regrole('aa_app_user') IS NULL OR to_regrole('cis_owner') IS NULL
       OR to_regrole('catalog_owner') IS NULL THEN
        RAISE EXCEPTION 'migration 284: roles cis_app, aa_app_user, cis_owner and catalog_owner must exist';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aa_app_user' AND (rolsuper OR rolbypassrls)) THEN
        RAISE EXCEPTION 'migration 284: aa_app_user is superuser or BYPASSRLS: RLS would not apply to it';
    END IF;
    SELECT pg_get_userbyid(n.nspowner) INTO owner_ns FROM pg_namespace n WHERE n.nspname = 'shared';
    IF NOT has_schema_privilege(current_user, 'shared', 'CREATE') THEN
        RAISE EXCEPTION 'migration 284: % may not create in shared (owner %); run it through DB Migrate (cis_owner)',
                        current_user, owner_ns;
    END IF;
    SELECT string_agg(v, ', ' ORDER BY v) INTO cols
      FROM unnest(ARRAY['281', '282', '283']) v
     WHERE NOT EXISTS (SELECT 1 FROM shared.schema_versions s WHERE s.version = v);
    IF cols IS NOT NULL THEN
        RAISE EXCEPTION 'migration 284: % not registered; apply the earlier CIS migrations first (readiness compares '
                        'max(version) and would hide the gap, AA-919 critic 17)', cols;
    END IF;
    IF to_regclass('shared.prompt_eval_runs') IS NULL THEN
        RAISE EXCEPTION 'migration 284: shared.prompt_eval_runs (CIS 089) is missing';
    END IF;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a
     WHERE a.attrelid = 'shared.prompt_eval_runs'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM runs_089 AND cols IS DISTINCT FROM runs_284 THEN
        RAISE EXCEPTION 'migration 284: shared.prompt_eval_runs has neither the 089 nor the 284 columns: %', cols;
    END IF;
    FOR t IN SELECT * FROM (VALUES ('shared.eval_golden_set', want_set), ('shared.eval_golden_item', want_item),
                                   ('shared.eval_item_result', want_res)) v(tbl, want)
    LOOP
        IF to_regclass(t.tbl) IS NOT NULL THEN
            SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
              INTO cols
              FROM pg_attribute a
             WHERE a.attrelid = t.tbl::regclass AND a.attnum > 0 AND NOT a.attisdropped;
            IF cols IS DISTINCT FROM t.want THEN
                RAISE EXCEPTION 'migration 284: % exists with other columns: %', t.tbl, cols;
            END IF;
        END IF;
    END LOOP;
END $$;

-- ── 1. The golden set ──────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.eval_golden_set (
    set_id         uuid NOT NULL DEFAULT gen_random_uuid(),
    name           text NOT NULL,
    version        text NOT NULL,
    status         text NOT NULL DEFAULT 'active',
    source_uri     text NOT NULL,
    source_sha256  text NOT NULL,
    seed           integer NOT NULL,
    holdout_pct    numeric(4,3) NOT NULL DEFAULT 0.300,
    tier_rules     jsonb NOT NULL DEFAULT '{}'::jsonb,
    shared_inputs  jsonb NOT NULL DEFAULT '{}'::jsonb,
    meta           jsonb NOT NULL DEFAULT '{}'::jsonb,
    label_history  jsonb NOT NULL DEFAULT '[]'::jsonb,
    item_count     integer NOT NULL,
    imported_by    text NOT NULL,
    created_at     timestamp with time zone NOT NULL DEFAULT now(),
    superseded_at  timestamp with time zone,
    CONSTRAINT eval_golden_set_pkey PRIMARY KEY (set_id),
    CONSTRAINT eval_golden_set_name_version_key UNIQUE (name, version),
    CONSTRAINT eval_golden_set_name_check CHECK (name ~ '^[a-z0-9_]{1,40}$'),
    CONSTRAINT eval_golden_set_version_check CHECK (version ~ '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$'),
    CONSTRAINT eval_golden_set_status_check CHECK (status IN ('active', 'superseded')),
    CONSTRAINT eval_golden_set_superseded_check CHECK ((status = 'superseded') = (superseded_at IS NOT NULL)),
    CONSTRAINT eval_golden_set_source_uri_check
        CHECK (char_length(source_uri) BETWEEN 1 AND 300 AND source_uri !~ '[0-9]{12}'
               AND source_uri !~* '^(arn:|s3://)'),
    CONSTRAINT eval_golden_set_sha_check CHECK (source_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT eval_golden_set_holdout_check CHECK (holdout_pct > 0 AND holdout_pct < 1),
    CONSTRAINT eval_golden_set_json_check
        CHECK (jsonb_typeof(tier_rules) = 'object' AND jsonb_typeof(shared_inputs) = 'object'
               AND jsonb_typeof(meta) = 'object' AND jsonb_typeof(label_history) = 'array'
               AND pg_column_size(tier_rules) <= 16384 AND pg_column_size(shared_inputs) <= 131072
               AND pg_column_size(meta) <= 16384 AND pg_column_size(label_history) <= 16384),
    CONSTRAINT eval_golden_set_platform_inputs_check
        CHECK (NOT jsonb_path_exists(shared_inputs, 'lax $.brand_rules.keyvalue() ? (!(@.key starts with "s1:"))')),
    CONSTRAINT eval_golden_set_count_check
        CHECK (item_count >= 0 AND char_length(imported_by) BETWEEN 1 AND 128)
);
CREATE UNIQUE INDEX IF NOT EXISTS eval_golden_set_one_active ON shared.eval_golden_set (name) WHERE status = 'active';

COMMENT ON TABLE shared.eval_golden_set IS
    'AA-919 WM-17 (CIS 284, app ADR 0010): one imported version of an eval golden set (AA-729: name aa729). Platform '
    'table: no tenant text (tenant brand packs are inlined on the tenant''s items). One active version per name; a '
    're-import of the same version must have the same source_sha256. Imported by services/golden_set/importer.py.';
COMMENT ON COLUMN shared.eval_golden_set.source_uri IS
    'AA-919 (284): where the fixture was read: s3:<key> in the bronze bucket (the bucket comes from the environment) '
    'or file:<name>. Never a bucket name, ARN or account (CHECK: no 12-digit run).';
COMMENT ON COLUMN shared.eval_golden_set.tier_rules IS
    'AA-919 (284): how the derived tiers and the split were computed (long_9d days >= 9, fact_dense cut per writer from '
    'services.quality.s1_facts.build_fact_table, post_edit, split seed and rounding).';
COMMENT ON COLUMN shared.eval_golden_set.shared_inputs IS
    'AA-919 (284): platform inputs only (brand_rules s1:*, CHECK). A tenant brand pack lives on its items.';
COMMENT ON COLUMN shared.eval_golden_set.label_history IS
    'pii:online_id; AA-919 (284): the fixture''s label history as imported (version, date, change, approved_by: '
    'a staff handle). Platform row, no tenant text; staff handles follow the staff-account retention (DM-6.1).';
COMMENT ON COLUMN shared.eval_golden_set.item_count IS
    'AA-919 (284): the number of items at import time. Not kept in step: the AA-839 tenant erasure deletes the '
    'tenant''s items later; count eval_golden_item for the current number.';

-- ── 2. The golden items ────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.eval_golden_item (
    item_id           uuid NOT NULL DEFAULT gen_random_uuid(),
    set_id            uuid NOT NULL,
    sample_id         text NOT NULL,
    writer            text NOT NULL,
    channel           text,
    scope             text NOT NULL,
    tenant_id         uuid,
    split             text NOT NULL,
    trap              boolean NOT NULL DEFAULT false,
    kind              text NOT NULL,
    tiers             text[] NOT NULL DEFAULT '{}'::text[],
    country           text,
    days              integer,
    input             jsonb NOT NULL,
    control_output    jsonb,
    post_edit         boolean NOT NULL DEFAULT false,
    pipeline_verdict  jsonb,
    label             jsonb NOT NULL,
    label_verdict     text NOT NULL,
    label_source      text NOT NULL,
    injection_spec    jsonb,
    refs              jsonb NOT NULL DEFAULT '{}'::jsonb,
    input_sha256      text NOT NULL,
    pick_reason       text,
    created_at        timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT eval_golden_item_pkey PRIMARY KEY (item_id),
    CONSTRAINT eval_golden_item_set_fkey FOREIGN KEY (set_id) REFERENCES shared.eval_golden_set (set_id)
        ON DELETE CASCADE,
    CONSTRAINT eval_golden_item_sample_key UNIQUE (set_id, sample_id),
    CONSTRAINT eval_golden_item_sample_check CHECK (sample_id ~ '^[a-z0-9-]{1,40}$'),
    CONSTRAINT eval_golden_item_writer_check CHECK (writer IN ('a1', 't2', 't9_blog', 't9_social')),
    CONSTRAINT eval_golden_item_channel_check
        CHECK ((writer IN ('a1', 't2') AND channel IS NULL)
               OR (writer = 't9_blog' AND channel = 'blog')
               OR (writer = 't9_social' AND channel IS NOT NULL AND channel <> 'blog'
                   AND channel ~ '^[a-z_]{1,32}$')),
    CONSTRAINT eval_golden_item_scope_check CHECK (scope IN ('platform', 'tenant')),
    CONSTRAINT eval_golden_item_scope_tenant_ck
        CHECK ((scope = 'platform' AND tenant_id IS NULL) OR (scope = 'tenant' AND tenant_id IS NOT NULL)),
    CONSTRAINT eval_golden_item_writer_scope_check CHECK ((writer = 'a1') = (scope = 'platform')),
    CONSTRAINT eval_golden_item_split_check CHECK (split IN ('tune', 'holdout', 'trap')),
    CONSTRAINT eval_golden_item_trap_check
        CHECK (trap = (split = 'trap') AND trap = (injection_spec IS NOT NULL)),
    CONSTRAINT eval_golden_item_kind_check CHECK (kind IN ('real', 'synthetic')),
    CONSTRAINT eval_golden_item_tiers_check
        CHECK (tiers <@ ARRAY['cycle_bike', 'trek_hike', 'water', 'wildlife', 'culinary', 'long_9d', 'long_18d',
                              'poor_raw', 'known_failure', 'held', 'fact_dense', 'prompt_injection',
                              'post_edit']::text[]
               AND cardinality(tiers) <= 13 AND ('post_edit' = ANY (tiers)) = post_edit),
    CONSTRAINT eval_golden_item_days_check
        CHECK ((days IS NULL OR days BETWEEN 1 AND 60) AND coalesce(char_length(country), 0) <= 60),
    CONSTRAINT eval_golden_item_label_check
        CHECK (label_verdict IN ('pass', 'fail')
               AND label_source IN ('agent_panel', 'synthetic', 'admin_edit', 'tenant_edit', 'human_label')),
    CONSTRAINT eval_golden_item_json_check
        CHECK (jsonb_typeof(input) = 'object' AND jsonb_typeof(label) = 'object' AND jsonb_typeof(refs) = 'object'
               AND (control_output IS NULL OR jsonb_typeof(control_output) = 'object')
               AND (pipeline_verdict IS NULL OR jsonb_typeof(pipeline_verdict) = 'object')
               AND (injection_spec IS NULL OR jsonb_typeof(injection_spec) = 'object')),
    CONSTRAINT eval_golden_item_size_check
        CHECK (pg_column_size(input) <= 262144 AND coalesce(pg_column_size(control_output), 0) <= 131072
               AND coalesce(pg_column_size(pipeline_verdict), 0) <= 16384 AND pg_column_size(label) <= 32768
               AND coalesce(pg_column_size(injection_spec), 0) <= 8192 AND pg_column_size(refs) <= 4096
               AND coalesce(char_length(pick_reason), 0) <= 80),
    CONSTRAINT eval_golden_item_sha_check CHECK (input_sha256 ~ '^[0-9a-f]{64}$')
);
CREATE INDEX IF NOT EXISTS eval_golden_item_set_writer_split_idx ON shared.eval_golden_item (set_id, writer, split);
CREATE INDEX IF NOT EXISTS eval_golden_item_tenant_idx ON shared.eval_golden_item (tenant_id) WHERE scope = 'tenant';

COMMENT ON TABLE shared.eval_golden_item IS
    'AA-919 WM-17 (CIS 284, app ADR 0010): one golden sample of a set: the frozen writer input and output, its label, '
    'tune / holdout / trap split and tiers. T2 / T9 items are tenant text: RLS ENABLE + FORCE, cis_app filters '
    'tenant_id in code, the tenant pool has no privilege; deleted with the tenant (AA-839 erasure inventory).';
COMMENT ON COLUMN shared.eval_golden_item.input IS
    'pii:free_text; AA-919 (284): the frozen writer input (S1 tour + SEO, T2 tour + the tenant brand pack inlined, T9 '
    'context). Tenant text on T2 / T9 items.';
COMMENT ON COLUMN shared.eval_golden_item.control_output IS
    'pii:free_text; AA-919 (284): the frozen output of the writer at selection time (human-edited when post_edit).';
COMMENT ON COLUMN shared.eval_golden_item.post_edit IS
    'AA-919 (284): control_output was edited by a human after the writer: never scored as a writer control '
    '(trigger eval_item_result_guard).';
COMMENT ON COLUMN shared.eval_golden_item.pipeline_verdict IS
    'pii:free_text; AA-919 (284): the production gate verdict on the frozen output at selection time (held reasons '
    'may quote text).';
COMMENT ON COLUMN shared.eval_golden_item.label IS
    'pii:free_text; AA-919 (284): the label (verdict, grade, reason, evidence quotes, source, strength).';
COMMENT ON COLUMN shared.eval_golden_item.refs IS
    'AA-919 (284): ids only (tour, generated content, version, piece, request, job, tenant slug, host sample).';
COMMENT ON COLUMN shared.eval_golden_item.tiers IS
    'AA-919 (284): fixture tags plus the derived long_9d, fact_dense and post_edit (closed list: a new tier is a new '
    'migration, lesson 211).';

-- ── 3. Per-item results ────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.eval_item_result (
    result_id         uuid NOT NULL DEFAULT gen_random_uuid(),
    run_id            uuid NOT NULL,
    item_id           uuid NOT NULL,
    writer            text NOT NULL,
    scope             text NOT NULL,
    tenant_id         uuid,
    arm               text NOT NULL,
    mode              text NOT NULL,
    phase             text NOT NULL,
    scored_result_id  uuid,
    output            jsonb,
    output_sha256     text,
    verdict           text NOT NULL,
    score             numeric,
    failure_codes     text[] NOT NULL DEFAULT '{}'::text[],
    hard_stop         boolean NOT NULL DEFAULT false,
    judge_model       text,
    judge_version     text,
    cost_usd          numeric(10,6) NOT NULL DEFAULT 0,
    details           jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at        timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT eval_item_result_pkey PRIMARY KEY (result_id),
    CONSTRAINT eval_item_result_run_fkey FOREIGN KEY (run_id) REFERENCES shared.prompt_eval_runs (id)
        ON DELETE CASCADE,
    CONSTRAINT eval_item_result_item_fkey FOREIGN KEY (item_id) REFERENCES shared.eval_golden_item (item_id)
        ON DELETE CASCADE,
    CONSTRAINT eval_item_result_scored_fkey FOREIGN KEY (scored_result_id)
        REFERENCES shared.eval_item_result (result_id) ON DELETE CASCADE,
    CONSTRAINT eval_item_result_key UNIQUE (run_id, item_id, arm, mode),
    CONSTRAINT eval_item_result_writer_check CHECK (writer IN ('a1', 't2', 't9_blog', 't9_social')),
    CONSTRAINT eval_item_result_scope_check CHECK (scope IN ('platform', 'tenant')),
    CONSTRAINT eval_item_result_scope_tenant_ck
        CHECK ((scope = 'platform' AND tenant_id IS NULL) OR (scope = 'tenant' AND tenant_id IS NOT NULL)),
    CONSTRAINT eval_item_result_arm_check CHECK (arm IN ('control', 'candidate')),
    CONSTRAINT eval_item_result_mode_check CHECK (mode IN ('score_only', 'regenerate', 'rejudge')),
    CONSTRAINT eval_item_result_phase_check CHECK (phase IN ('probe', 'tune', 'holdout')),
    CONSTRAINT eval_item_result_rejudge_check
        CHECK ((mode = 'rejudge') = (scored_result_id IS NOT NULL) AND scored_result_id IS DISTINCT FROM result_id),
    CONSTRAINT eval_item_result_output_check
        CHECK ((output IS NULL OR (mode = 'regenerate' AND jsonb_typeof(output) = 'object'
                                   AND pg_column_size(output) <= 131072))
               AND (output IS NULL) = (output_sha256 IS NULL)
               AND (output_sha256 IS NULL OR output_sha256 ~ '^[0-9a-f]{64}$')),
    CONSTRAINT eval_item_result_verdict_check CHECK (verdict IN ('pass', 'fail', 'error', 'skipped')),
    CONSTRAINT eval_item_result_size_check
        CHECK (cardinality(failure_codes) <= 50 AND coalesce(char_length(judge_model), 0) <= 128
               AND coalesce(char_length(judge_version), 0) <= 128 AND cost_usd >= 0
               AND jsonb_typeof(details) = 'object' AND pg_column_size(details) <= 16384)
);
CREATE INDEX IF NOT EXISTS eval_item_result_item_idx ON shared.eval_item_result (item_id);
CREATE INDEX IF NOT EXISTS eval_item_result_scored_idx ON shared.eval_item_result (scored_result_id)
    WHERE scored_result_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS eval_item_result_tenant_idx ON shared.eval_item_result (tenant_id) WHERE scope = 'tenant';

COMMENT ON TABLE shared.eval_item_result IS
    'AA-919 WM-17 (CIS 284, app ADR 0010): one scored output of a golden item in a writing_memory run of '
    'shared.prompt_eval_runs (arm control / candidate, mode score_only / regenerate / rejudge, phase = the item''s '
    'split). Immutable (no UPDATE grant). writer / scope / tenant_id copied from the item (trigger '
    'eval_item_result_guard). RLS ENABLE + FORCE; tenant rows deleted with the tenant (AA-839).';
COMMENT ON COLUMN shared.eval_item_result.output IS
    'pii:free_text; AA-919 (284): the new writer output of a regenerate result (tenant text on T2 / T9 items).';
COMMENT ON COLUMN shared.eval_item_result.details IS
    'AA-919 (284): ids and counts only (source run id, gate names, degraded counts).';

-- ── 4. The run ledger: shared.prompt_eval_runs widened ────────────────────────────────────────────────────────────
ALTER TABLE shared.prompt_eval_runs
    ADD COLUMN IF NOT EXISTS run_kind      text NOT NULL DEFAULT 'regression',
    ADD COLUMN IF NOT EXISTS writer        text,
    ADD COLUMN IF NOT EXISTS release_id    uuid,
    ADD COLUMN IF NOT EXISTS golden_set_id uuid,
    ADD COLUMN IF NOT EXISTS tiers         text[] NOT NULL DEFAULT '{}'::text[],
    ADD COLUMN IF NOT EXISTS stop_reason   text,
    ADD COLUMN IF NOT EXISTS verdict       text,
    ADD COLUMN IF NOT EXISTS cost_cap_usd  numeric(10,4),
    ADD COLUMN IF NOT EXISTS judge_kappa   numeric(4,3),
    ADD COLUMN IF NOT EXISTS judge_counts  boolean,
    ADD COLUMN IF NOT EXISTS fingerprint   jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS finished_at   timestamp with time zone;

ALTER TABLE shared.prompt_eval_runs
    DROP CONSTRAINT IF EXISTS prompt_eval_runs_pipeline_check,
    DROP CONSTRAINT IF EXISTS prompt_eval_runs_golden_set_fkey,
    DROP CONSTRAINT IF EXISTS prompt_eval_runs_run_kind_check,
    DROP CONSTRAINT IF EXISTS prompt_eval_runs_writer_check,
    DROP CONSTRAINT IF EXISTS prompt_eval_runs_wm_shape_check,
    DROP CONSTRAINT IF EXISTS prompt_eval_runs_legacy_kind_check,
    DROP CONSTRAINT IF EXISTS prompt_eval_runs_finished_check,
    DROP CONSTRAINT IF EXISTS prompt_eval_runs_values_check;
ALTER TABLE shared.prompt_eval_runs
    ADD CONSTRAINT prompt_eval_runs_pipeline_check
        CHECK (pipeline IN ('s1_old', 's1_from_atom', 'writing_memory')),
    ADD CONSTRAINT prompt_eval_runs_golden_set_fkey FOREIGN KEY (golden_set_id)
        REFERENCES shared.eval_golden_set (set_id) ON DELETE RESTRICT,
    ADD CONSTRAINT prompt_eval_runs_run_kind_check
        CHECK (run_kind IN ('regression', 'baseline_import', 'r0_replay', 'r1', 'r2', 'reverify', 'probe', 'shadow')),
    ADD CONSTRAINT prompt_eval_runs_writer_check
        CHECK (writer IS NULL OR writer IN ('a1', 't2', 't9_blog', 't9_social')),
    ADD CONSTRAINT prompt_eval_runs_wm_shape_check
        CHECK (pipeline <> 'writing_memory'
               OR (writer IS NOT NULL AND run_kind <> 'regression' AND cost_usd IS NOT NULL
                   AND jsonb_typeof(details) = 'object')),
    ADD CONSTRAINT prompt_eval_runs_legacy_kind_check
        CHECK (pipeline = 'writing_memory' OR (run_kind = 'regression' AND writer IS NULL)),
    ADD CONSTRAINT prompt_eval_runs_finished_check
        CHECK (finished_at IS NULL OR (stop_reason IS NOT NULL AND verdict IS NOT NULL)),
    ADD CONSTRAINT prompt_eval_runs_values_check
        CHECK ((stop_reason IS NULL
                OR stop_reason IN ('completed', 'hard_stop', 'futility', 'budget_cap', 'probe_fail', 'error'))
               AND (verdict IS NULL OR verdict IN ('pass', 'fail', 'baseline', 'informative', 'invalid'))
               AND tour_count >= 0 AND (cost_usd IS NULL OR cost_usd >= 0)
               AND (cost_cap_usd IS NULL OR cost_cap_usd >= 0)
               AND (judge_kappa IS NULL OR judge_kappa BETWEEN -1 AND 1)
               AND (judge_counts IS NOT TRUE OR judge_kappa >= 0.6)
               AND tiers <@ ARRAY['cycle_bike', 'trek_hike', 'water', 'wildlife', 'culinary', 'long_9d', 'long_18d',
                                  'poor_raw', 'known_failure', 'held', 'fact_dense', 'prompt_injection',
                                  'post_edit']::text[]
               AND jsonb_typeof(fingerprint) = 'object');
CREATE INDEX IF NOT EXISTS prompt_eval_runs_wm_writer_idx
    ON shared.prompt_eval_runs (writer, run_kind, created_at DESC) WHERE pipeline = 'writing_memory';
CREATE INDEX IF NOT EXISTS prompt_eval_runs_golden_set_idx
    ON shared.prompt_eval_runs (golden_set_id) WHERE golden_set_id IS NOT NULL;

COMMENT ON COLUMN shared.prompt_eval_runs.run_kind IS
    'AA-919 (284): regression (the legacy s1_old script) or a writing-memory ladder run: baseline_import, r0_replay, '
    'r1, r2, reverify, probe, shadow.';
COMMENT ON COLUMN shared.prompt_eval_runs.release_id IS
    'AA-919 (284): the shared.writing_memory_release the run evaluated (WM-18 adds the foreign key).';
COMMENT ON COLUMN shared.prompt_eval_runs.prompt_version IS
    'AA-289 (089) / AA-919 (284): the writer prompt hash of the run; a baseline_import holds aa729-frozen@<fixture '
    'version> (frozen outputs of several historic prompts).';
COMMENT ON COLUMN shared.prompt_eval_runs.judge_counts IS
    'AA-919 (284): the judge verdict counts toward the gate only when calibrated (judge_kappa >= 0.6, CHECK).';
COMMENT ON COLUMN shared.prompt_eval_runs.fingerprint IS
    'AA-919 (284): what a reverify compares: golden set name@version, the writer / judge model routes, the gate '
    'taxonomy version.';

-- ── 5. The result guard (trigger) ─────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION shared.eval_item_result_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    it  record;
    run record;
    sc  uuid;
BEGIN
    SELECT i.set_id, i.writer, i.scope, i.tenant_id, i.split, i.post_edit INTO it
      FROM shared.eval_golden_item i WHERE i.item_id = NEW.item_id;
    IF NOT FOUND THEN
        RETURN NEW;                                   -- the foreign key refuses it
    END IF;
    IF NEW.writer IS DISTINCT FROM it.writer OR NEW.scope IS DISTINCT FROM it.scope
       OR NEW.tenant_id IS DISTINCT FROM it.tenant_id THEN
        RAISE EXCEPTION 'shared.eval_item_result: writer / scope / tenant_id must equal the item''s (AA-919)'
              USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.phase IS DISTINCT FROM (CASE WHEN it.split = 'trap' THEN 'probe' ELSE it.split END) THEN
        RAISE EXCEPTION 'shared.eval_item_result: phase % does not match the item''s split % (AA-919)',
                        NEW.phase, it.split USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.arm = 'control' AND NEW.mode = 'score_only' AND it.post_edit THEN
        RAISE EXCEPTION 'shared.eval_item_result: a post_edit item''s frozen output is human text, never a writer '
                        'control (AA-919)' USING ERRCODE = 'check_violation';
    END IF;
    SELECT r.pipeline, r.writer, r.run_kind, r.golden_set_id INTO run
      FROM shared.prompt_eval_runs r WHERE r.id = NEW.run_id;
    IF FOUND THEN
        IF run.pipeline <> 'writing_memory' OR run.writer IS DISTINCT FROM it.writer THEN
            RAISE EXCEPTION 'shared.eval_item_result: the run must be a writing_memory run of writer % (AA-919)',
                            it.writer USING ERRCODE = 'check_violation';
        END IF;
        IF run.golden_set_id IS DISTINCT FROM it.set_id THEN
            RAISE EXCEPTION 'shared.eval_item_result: the run''s golden set must be the item''s (AA-919)'
                  USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.arm = 'control' AND NEW.mode = 'regenerate' AND run.run_kind NOT IN ('baseline_import', 'reverify') THEN
            RAISE EXCEPTION 'shared.eval_item_result: a control is regenerated only in a baseline_import or reverify '
                            'run, not in % (AA-919)', run.run_kind USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF NEW.scored_result_id IS NOT NULL THEN
        SELECT s.item_id INTO sc FROM shared.eval_item_result s WHERE s.result_id = NEW.scored_result_id;
        IF FOUND AND sc IS DISTINCT FROM NEW.item_id THEN
            RAISE EXCEPTION 'shared.eval_item_result: a rejudge scores a result of the same item (AA-919)'
                  USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION shared.eval_item_result_guard() FROM PUBLIC;
COMMENT ON FUNCTION shared.eval_item_result_guard() IS
    'AA-919 WM-17 (CIS 284): BEFORE INSERT OR UPDATE row trigger of shared.eval_item_result: tenant copy equals the '
    'item''s, phase = split, no post_edit score_only control, run = writing_memory of the item''s writer and of the '
    'item''s golden set, controls regenerated only in baseline_import / reverify runs, a rejudge scores a result of '
    'the same item.';

DROP TRIGGER IF EXISTS eval_item_result_guard ON shared.eval_item_result;
CREATE TRIGGER eval_item_result_guard
    BEFORE INSERT OR UPDATE ON shared.eval_item_result
    FOR EACH ROW EXECUTE FUNCTION shared.eval_item_result_guard();

-- A run that has results keeps what the result guard checked: pipeline, writer, run_kind and golden_set_id are frozen
-- once one eval_item_result row names the run (cis_app keeps UPDATE on the ledger for finished_at / verdict / cost).
CREATE OR REPLACE FUNCTION shared.prompt_eval_runs_freeze() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF (NEW.pipeline, NEW.writer, NEW.run_kind, NEW.golden_set_id)
       IS DISTINCT FROM (OLD.pipeline, OLD.writer, OLD.run_kind, OLD.golden_set_id)
       AND EXISTS (SELECT 1 FROM shared.eval_item_result r WHERE r.run_id = OLD.id) THEN
        RAISE EXCEPTION 'shared.prompt_eval_runs: pipeline / writer / run_kind / golden_set_id of a run with results '
                        'are frozen (AA-919)' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION shared.prompt_eval_runs_freeze() FROM PUBLIC;
COMMENT ON FUNCTION shared.prompt_eval_runs_freeze() IS
    'AA-919 WM-17 (CIS 284): BEFORE UPDATE row trigger of shared.prompt_eval_runs: once a run has eval_item_result '
    'rows, its pipeline / writer / run_kind / golden_set_id cannot change (they are what eval_item_result_guard '
    'checked). Runs with SECURITY INVOKER: the updater reads eval_item_result (cis_app / cis_owner policies).';

DROP TRIGGER IF EXISTS prompt_eval_runs_freeze ON shared.prompt_eval_runs;
CREATE TRIGGER prompt_eval_runs_freeze
    BEFORE UPDATE ON shared.prompt_eval_runs
    FOR EACH ROW EXECUTE FUNCTION shared.prompt_eval_runs_freeze();

-- ── 6. RLS ─────────────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.eval_golden_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.eval_golden_item FORCE ROW LEVEL SECURITY;
ALTER TABLE shared.eval_item_result ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.eval_item_result FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS eval_golden_item_cis_app_all ON shared.eval_golden_item;
CREATE POLICY eval_golden_item_cis_app_all ON shared.eval_golden_item AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS eval_golden_item_cis_owner_all ON shared.eval_golden_item;
CREATE POLICY eval_golden_item_cis_owner_all ON shared.eval_golden_item AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON shared.eval_golden_item;
CREATE POLICY tenant_isolation ON shared.eval_golden_item AS PERMISSIVE FOR ALL TO aa_app_user
    USING (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.eval_golden_item IS
    'AA-919 (CIS 284): own tenant rows only, never a platform row; the tenant pool holds no privilege on the table '
    '(tenants never see the golden set), the policy is the floor if one is ever granted.';

DROP POLICY IF EXISTS eval_item_result_cis_app_all ON shared.eval_item_result;
CREATE POLICY eval_item_result_cis_app_all ON shared.eval_item_result AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS eval_item_result_cis_owner_all ON shared.eval_item_result;
CREATE POLICY eval_item_result_cis_owner_all ON shared.eval_item_result AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON shared.eval_item_result;
CREATE POLICY tenant_isolation ON shared.eval_item_result AS PERMISSIVE FOR ALL TO aa_app_user
    USING (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.eval_item_result IS
    'AA-919 (CIS 284): own tenant rows only, never a platform row; no tenant-pool privilege today.';

-- ── 7. Grants ──────────────────────────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON shared.eval_golden_set, shared.eval_golden_item, shared.eval_item_result FROM PUBLIC;
REVOKE ALL ON shared.eval_golden_set, shared.eval_golden_item, shared.eval_item_result
    FROM cis_app, aa_app_user, catalog_owner;                     -- also column grants: from nothing
GRANT SELECT, INSERT, UPDATE ON shared.eval_golden_set TO cis_app;
GRANT SELECT, INSERT, DELETE ON shared.eval_golden_item TO cis_app;
GRANT SELECT, INSERT, DELETE ON shared.eval_item_result TO cis_app;

-- ── Guard 2: constraints, indexes, trigger, RLS, policies, privileges, AA-859 invariant ───────────────────────────
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
          'shared.eval_golden_set:eval_golden_set_pkey', 'shared.eval_golden_set:eval_golden_set_name_version_key',
          'shared.eval_golden_set:eval_golden_set_name_check', 'shared.eval_golden_set:eval_golden_set_version_check',
          'shared.eval_golden_set:eval_golden_set_status_check',
          'shared.eval_golden_set:eval_golden_set_superseded_check',
          'shared.eval_golden_set:eval_golden_set_source_uri_check', 'shared.eval_golden_set:eval_golden_set_sha_check',
          'shared.eval_golden_set:eval_golden_set_holdout_check', 'shared.eval_golden_set:eval_golden_set_json_check',
          'shared.eval_golden_set:eval_golden_set_platform_inputs_check',
          'shared.eval_golden_set:eval_golden_set_count_check',
          'shared.eval_golden_item:eval_golden_item_pkey', 'shared.eval_golden_item:eval_golden_item_set_fkey',
          'shared.eval_golden_item:eval_golden_item_sample_key', 'shared.eval_golden_item:eval_golden_item_sample_check',
          'shared.eval_golden_item:eval_golden_item_writer_check',
          'shared.eval_golden_item:eval_golden_item_channel_check',
          'shared.eval_golden_item:eval_golden_item_scope_check',
          'shared.eval_golden_item:eval_golden_item_scope_tenant_ck',
          'shared.eval_golden_item:eval_golden_item_writer_scope_check',
          'shared.eval_golden_item:eval_golden_item_split_check', 'shared.eval_golden_item:eval_golden_item_trap_check',
          'shared.eval_golden_item:eval_golden_item_kind_check', 'shared.eval_golden_item:eval_golden_item_tiers_check',
          'shared.eval_golden_item:eval_golden_item_days_check', 'shared.eval_golden_item:eval_golden_item_label_check',
          'shared.eval_golden_item:eval_golden_item_json_check', 'shared.eval_golden_item:eval_golden_item_size_check',
          'shared.eval_golden_item:eval_golden_item_sha_check',
          'shared.eval_item_result:eval_item_result_pkey', 'shared.eval_item_result:eval_item_result_run_fkey',
          'shared.eval_item_result:eval_item_result_item_fkey', 'shared.eval_item_result:eval_item_result_scored_fkey',
          'shared.eval_item_result:eval_item_result_key', 'shared.eval_item_result:eval_item_result_writer_check',
          'shared.eval_item_result:eval_item_result_scope_check',
          'shared.eval_item_result:eval_item_result_scope_tenant_ck',
          'shared.eval_item_result:eval_item_result_arm_check', 'shared.eval_item_result:eval_item_result_mode_check',
          'shared.eval_item_result:eval_item_result_phase_check',
          'shared.eval_item_result:eval_item_result_rejudge_check',
          'shared.eval_item_result:eval_item_result_output_check',
          'shared.eval_item_result:eval_item_result_verdict_check',
          'shared.eval_item_result:eval_item_result_size_check',
          'shared.prompt_eval_runs:prompt_eval_runs_pipeline_check',
          'shared.prompt_eval_runs:prompt_eval_runs_golden_set_fkey',
          'shared.prompt_eval_runs:prompt_eval_runs_run_kind_check',
          'shared.prompt_eval_runs:prompt_eval_runs_writer_check',
          'shared.prompt_eval_runs:prompt_eval_runs_wm_shape_check',
          'shared.prompt_eval_runs:prompt_eval_runs_legacy_kind_check',
          'shared.prompt_eval_runs:prompt_eval_runs_finished_check',
          'shared.prompt_eval_runs:prompt_eval_runs_values_check']) AS want
     WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                        WHERE c.conrelid = split_part(want, ':', 1)::regclass AND c.conname = split_part(want, ':', 2)
                          AND c.convalidated);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 284: constraints missing or not validated: %', missing;
    END IF;
    IF (SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
         WHERE c.conrelid = 'shared.prompt_eval_runs'::regclass AND c.conname = 'prompt_eval_runs_pipeline_check')
       NOT LIKE '%writing_memory%' THEN
        RAISE EXCEPTION 'migration 284: prompt_eval_runs_pipeline_check does not allow writing_memory';
    END IF;

    SELECT string_agg(want, ', ' ORDER BY want) INTO missing
      FROM unnest(ARRAY['eval_golden_set_one_active', 'eval_golden_item_set_writer_split_idx',
                        'eval_golden_item_tenant_idx', 'eval_item_result_item_idx', 'eval_item_result_scored_idx',
                        'eval_item_result_tenant_idx', 'prompt_eval_runs_wm_writer_idx',
                        'prompt_eval_runs_golden_set_idx']) AS want
     WHERE NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                        JOIN pg_namespace n ON n.oid = c.relnamespace
                       WHERE n.nspname = 'shared' AND c.relname = want AND x.indisvalid);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 284: indexes missing or invalid: %', missing;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                    WHERE c.relname = 'eval_golden_set_one_active' AND x.indisunique
                      AND pg_get_expr(x.indpred, x.indrelid) = '(status = ''active''::text)')
       OR NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                       WHERE c.relname = 'eval_golden_item_tenant_idx'
                         AND pg_get_expr(x.indpred, x.indrelid) = '(scope = ''tenant''::text)')
       OR NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                       WHERE c.relname = 'eval_item_result_tenant_idx'
                         AND pg_get_expr(x.indpred, x.indrelid) = '(scope = ''tenant''::text)') THEN
        RAISE EXCEPTION 'migration 284: the partial indexes are not as this file defines them';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger tg
                    WHERE tg.tgrelid = 'shared.eval_item_result'::regclass AND tg.tgname = 'eval_item_result_guard'
                      AND NOT tg.tgisinternal AND tg.tgfoid = 'shared.eval_item_result_guard()'::regprocedure
                      AND tg.tgenabled = 'O') THEN
        RAISE EXCEPTION 'migration 284: trigger eval_item_result_guard missing or disabled';
    END IF;
    IF has_function_privilege('public', 'shared.eval_item_result_guard()', 'EXECUTE') THEN
        RAISE EXCEPTION 'migration 284: PUBLIC may execute shared.eval_item_result_guard()';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger tg
                    WHERE tg.tgrelid = 'shared.prompt_eval_runs'::regclass AND tg.tgname = 'prompt_eval_runs_freeze'
                      AND NOT tg.tgisinternal AND tg.tgfoid = 'shared.prompt_eval_runs_freeze()'::regprocedure
                      AND tg.tgenabled = 'O') THEN
        RAISE EXCEPTION 'migration 284: trigger prompt_eval_runs_freeze missing or disabled';
    END IF;
    IF has_function_privilege('public', 'shared.prompt_eval_runs_freeze()', 'EXECUTE') THEN
        RAISE EXCEPTION 'migration 284: PUBLIC may execute shared.prompt_eval_runs_freeze()';
    END IF;

    FOR t IN SELECT * FROM (VALUES ('shared.eval_golden_item'::regclass, 'eval_golden_item'),
                                   ('shared.eval_item_result'::regclass, 'eval_item_result')) v(tbl, short)
    LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = t.tbl) THEN
            RAISE EXCEPTION 'migration 284: % RLS is not on and forced (ADR 0010 decision 10)', t.tbl;
        END IF;
        SELECT string_agg(p.polname || ':' || CASE WHEN p.polpermissive THEN 'permissive' ELSE 'restrictive' END
                          || ':' || p.polcmd::text || ':'
                          || array_to_string(ARRAY(SELECT pg_get_userbyid(r) FROM unnest(p.polroles) r ORDER BY 1), ',')
                          || ':' || pg_get_expr(p.polqual, p.polrelid) || ':' || pg_get_expr(p.polwithcheck, p.polrelid),
                          ' | ' ORDER BY p.polname)
          INTO pols FROM pg_policy p WHERE p.polrelid = t.tbl;
        IF pols IS DISTINCT FROM
             t.short || '_cis_app_all:permissive:*:cis_app:true:true | '
             || t.short || '_cis_owner_all:permissive:*:cis_owner:true:true | ' || iso THEN
            RAISE EXCEPTION 'migration 284: unexpected policies on %: %', t.tbl, pols;
        END IF;
    END LOOP;

    FOR t IN SELECT * FROM (VALUES ('shared.eval_golden_set'::regclass, 'cis_app:INSERT, cis_app:SELECT, cis_app:UPDATE'),
                                   ('shared.eval_golden_item'::regclass, 'cis_app:DELETE, cis_app:INSERT, cis_app:SELECT'),
                                   ('shared.eval_item_result'::regclass, 'cis_app:DELETE, cis_app:INSERT, cis_app:SELECT'))
                           v(tbl, want)
    LOOP
        SELECT string_agg(r || ':' || p, ', ' ORDER BY r COLLATE "C", p COLLATE "C") INTO privs FROM (
            SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r, a.privilege_type AS p
              FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
             WHERE c.oid = t.tbl
               AND (a.grantee = 0 OR a.grantee IN ('cis_app'::regrole, 'aa_app_user'::regrole,
                                                   'catalog_owner'::regrole))) x;
        IF privs IS DISTINCT FROM t.want THEN
            RAISE EXCEPTION 'migration 284: unexpected privileges on %: %', t.tbl, privs;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = t.tbl AND a.attacl IS NOT NULL) THEN
            RAISE EXCEPTION 'migration 284: column-level grants on %', t.tbl;
        END IF;
    END LOOP;

    -- the AA-859 invariant, version 3 (same text as 280 guard 2 / NO_PRIVILEGE_WITHOUT_RLS_SQL_V3)
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
        RAISE EXCEPTION 'migration 284: aa_app_user holds privileges on relations without RLS: % (AA-859 invariant v3)',
            bad;
    END IF;
END $$;

-- ── Guard 3: behaviour (a sub-block that always rolls back) ────────────────────────────────────────────────────────
DO $$
DECLARE
    probe_tenant uuid := gen_random_uuid();
    probe_set    uuid;
    plat_item    uuid;
    ten_item     uuid;
    edit_item    uuid;
    wm_run       uuid;
    r2_run       uuid;
    other_set    uuid;
    other_run    uuid;
    legacy       uuid;
    n            bigint;
    refused      boolean;
    bad          text;
    sha          text := repeat('a', 64);
BEGIN
    BEGIN
        -- the legacy writer (services/eval/regression.py _write_eval_run) is unaffected: defaults fill the new columns
        INSERT INTO shared.prompt_eval_runs (pipeline, prompt_version, tour_count, avg_quality_score,
                                             avg_words_per_citation, gate_pass_count, gate_fail_count, cost_usd,
                                             regression_detected, baseline_prompt_version,
                                             baseline_avg_quality_score, details, triggered_by)
        VALUES ('s1_old', 'migration-284-probe', 3, 7.5, NULL, NULL, NULL, 0.12, false, NULL, NULL, '{}'::jsonb,
                'manual')
        RETURNING id INTO legacy;
        IF (SELECT run_kind FROM shared.prompt_eval_runs WHERE id = legacy) IS DISTINCT FROM 'regression' THEN
            RAISE EXCEPTION 'migration 284: the legacy regression insert did not get run_kind regression';
        END IF;

        INSERT INTO shared.eval_golden_set (name, version, source_uri, source_sha256, seed, item_count, imported_by,
                                            shared_inputs)
        VALUES ('zz284_probe', '0.0.1', 'file:zz284.json', sha, 729, 3, 'migration-284-probe',
                '{"brand_rules": {"s1:default": {}}}'::jsonb)
        RETURNING set_id INTO probe_set;
        INSERT INTO shared.eval_golden_item (set_id, sample_id, writer, scope, split, kind, input, label,
                                             label_verdict, label_source, input_sha256, tiers, days)
        VALUES (probe_set, 'zz-a1', 'a1', 'platform', 'tune', 'real', '{}'::jsonb, '{}'::jsonb, 'fail', 'agent_panel',
                sha, ARRAY['long_9d'], 10)
        RETURNING item_id INTO plat_item;
        INSERT INTO shared.eval_golden_item (set_id, sample_id, writer, channel, scope, tenant_id, split, kind, input,
                                             label, label_verdict, label_source, input_sha256)
        VALUES (probe_set, 'zz-blog', 't9_blog', 'blog', 'tenant', probe_tenant, 'holdout', 'real', '{}'::jsonb,
                '{}'::jsonb, 'pass', 'agent_panel', sha)
        RETURNING item_id INTO ten_item;
        INSERT INTO shared.eval_golden_item (set_id, sample_id, writer, scope, tenant_id, split, kind, input, label,
                                             label_verdict, label_source, input_sha256, post_edit, tiers,
                                             control_output)
        VALUES (probe_set, 'zz-t2', 't2', 'tenant', probe_tenant, 'tune', 'real', '{}'::jsonb, '{}'::jsonb, 'pass',
                'tenant_edit', sha, true, ARRAY['post_edit'], '{}'::jsonb)
        RETURNING item_id INTO edit_item;
        SELECT count(*) INTO n FROM shared.eval_golden_item WHERE set_id = probe_set;
        IF n <> 3 THEN
            RAISE EXCEPTION 'migration 284: the runner reads % of its 3 probe items (FORCE RLS without its policy?)', n;
        END IF;

        INSERT INTO shared.prompt_eval_runs (pipeline, prompt_version, tour_count, cost_usd, details, triggered_by,
                                             run_kind, writer, golden_set_id, stop_reason, verdict, finished_at)
        VALUES ('writing_memory', 'aa729-frozen@0.0.1', 1, 0, '{}'::jsonb, 'migration-284-probe', 'baseline_import',
                't9_blog', probe_set, 'completed', 'baseline', now())
        RETURNING id INTO wm_run;
        INSERT INTO shared.eval_item_result (run_id, item_id, writer, scope, tenant_id, arm, mode, phase, verdict)
        VALUES (wm_run, ten_item, 't9_blog', 'tenant', probe_tenant, 'control', 'score_only', 'holdout', 'pass');
        INSERT INTO shared.prompt_eval_runs (pipeline, prompt_version, tour_count, cost_usd, details, triggered_by,
                                             run_kind, writer, golden_set_id)
        VALUES ('writing_memory', 'migration-284', 0, 0, '{}'::jsonb, 'migration-284-probe', 'r2', 't2', probe_set)
        RETURNING id INTO r2_run;
        INSERT INTO shared.eval_golden_set (name, version, source_uri, source_sha256, seed, item_count, imported_by)
        VALUES ('zz284_probe_other', '0.0.1', 'file:zz284.json', sha, 729, 0, 'migration-284-probe')
        RETURNING set_id INTO other_set;
        INSERT INTO shared.prompt_eval_runs (pipeline, prompt_version, tour_count, cost_usd, details, triggered_by,
                                             run_kind, writer, golden_set_id)
        VALUES ('writing_memory', 'migration-284', 0, 0, '{}'::jsonb, 'migration-284-probe', 'r2', 't9_blog',
                other_set)
        RETURNING id INTO other_run;
        SELECT count(*) INTO n FROM shared.eval_item_result WHERE run_id = wm_run;
        IF n <> 1 THEN
            RAISE EXCEPTION 'migration 284: the runner reads % of its 1 probe result', n;
        END IF;

        FOREACH bad IN ARRAY ARRAY[
            -- items: an a1 item with a tenant, a T9 item without one, a t9_blog item on linkedin, an unknown tier,
            -- a trap flag that disagrees with the split
            format($q$INSERT INTO shared.eval_golden_item (set_id, sample_id, writer, scope, tenant_id, split, kind,
                      input, label, label_verdict, label_source, input_sha256)
                      VALUES (%L, 'zz-x', 'a1', 'platform', gen_random_uuid(), 'tune', 'real', '{}', '{}', 'pass',
                      'agent_panel', %L)$q$, probe_set, sha),
            format($q$INSERT INTO shared.eval_golden_item (set_id, sample_id, writer, channel, scope, split, kind,
                      input, label, label_verdict, label_source, input_sha256)
                      VALUES (%L, 'zz-x', 't9_social', 'linkedin', 'platform', 'tune', 'real', '{}', '{}', 'pass',
                      'agent_panel', %L)$q$, probe_set, sha),
            format($q$INSERT INTO shared.eval_golden_item (set_id, sample_id, writer, channel, scope, tenant_id, split,
                      kind, input, label, label_verdict, label_source, input_sha256)
                      VALUES (%L, 'zz-x', 't9_blog', 'linkedin', 'tenant', gen_random_uuid(), 'tune', 'real', '{}',
                      '{}', 'pass', 'agent_panel', %L)$q$, probe_set, sha),
            format($q$INSERT INTO shared.eval_golden_item (set_id, sample_id, writer, scope, split, kind, input, label,
                      label_verdict, label_source, input_sha256, tiers)
                      VALUES (%L, 'zz-x', 'a1', 'platform', 'tune', 'real', '{}', '{}', 'pass', 'agent_panel', %L,
                      ARRAY['long_7d'])$q$, probe_set, sha),
            format($q$INSERT INTO shared.eval_golden_item (set_id, sample_id, writer, scope, split, trap, kind, input,
                      label, label_verdict, label_source, input_sha256)
                      VALUES (%L, 'zz-x', 'a1', 'platform', 'tune', true, 'synthetic', '{}', '{}', 'fail',
                      'synthetic', %L)$q$, probe_set, sha),
            -- runs: a writing_memory run without a writer
            $q$INSERT INTO shared.prompt_eval_runs (pipeline, prompt_version, tour_count, cost_usd, details,
                      run_kind) VALUES ('writing_memory', 'x', 0, 0, '{}', 'r2')$q$,
            -- results: an output on score_only, a tenant other than the item's, the wrong phase, a score_only control
            -- on a post_edit item, a regenerated control in an r2 run
            format($q$INSERT INTO shared.eval_item_result (run_id, item_id, writer, scope, tenant_id, arm, mode, phase,
                      verdict, output, output_sha256)
                      VALUES (%L, %L, 't9_blog', 'tenant', %L, 'candidate', 'score_only', 'holdout', 'pass', '{}',
                      %L)$q$, wm_run, ten_item, probe_tenant, sha),
            format($q$INSERT INTO shared.eval_item_result (run_id, item_id, writer, scope, tenant_id, arm, mode, phase,
                      verdict) VALUES (%L, %L, 't9_blog', 'tenant', gen_random_uuid(), 'candidate', 'score_only',
                      'holdout', 'pass')$q$, wm_run, ten_item),
            format($q$INSERT INTO shared.eval_item_result (run_id, item_id, writer, scope, tenant_id, arm, mode, phase,
                      verdict) VALUES (%L, %L, 't9_blog', 'tenant', %L, 'candidate', 'score_only', 'tune',
                      'pass')$q$, wm_run, ten_item, probe_tenant),
            format($q$INSERT INTO shared.eval_item_result (run_id, item_id, writer, scope, tenant_id, arm, mode, phase,
                      verdict) VALUES (%L, %L, 't2', 'tenant', %L, 'control', 'score_only', 'tune', 'pass')$q$,
                   r2_run, edit_item, probe_tenant),
            format($q$INSERT INTO shared.eval_item_result (run_id, item_id, writer, scope, tenant_id, arm, mode, phase,
                      verdict) VALUES (%L, %L, 't2', 'tenant', %L, 'control', 'regenerate', 'tune', 'error')$q$,
                   r2_run, edit_item, probe_tenant),
            -- a result in a run of another golden set; a run with results changing its kind or its writer
            format($q$INSERT INTO shared.eval_item_result (run_id, item_id, writer, scope, tenant_id, arm, mode, phase,
                      verdict) VALUES (%L, %L, 't9_blog', 'tenant', %L, 'candidate', 'score_only', 'holdout',
                      'pass')$q$, other_run, ten_item, probe_tenant),
            format($q$UPDATE shared.prompt_eval_runs SET run_kind = 'r2' WHERE id = %L$q$, wm_run),
            format($q$UPDATE shared.prompt_eval_runs SET golden_set_id = %L WHERE id = %L$q$, other_set, wm_run),
            -- sets: an account id in source_uri, a tenant brand pack in shared_inputs
            format($q$INSERT INTO shared.eval_golden_set (name, version, source_uri, source_sha256, seed, item_count,
                      imported_by) VALUES ('zz284_x', '0.0.1', 's3:aa-cis-bronze-' || repeat('9', 12) || '/x', %L, 1,
                      0, 'x')$q$, sha),
            format($q$INSERT INTO shared.eval_golden_set (name, version, source_uri, source_sha256, seed, item_count,
                      imported_by, shared_inputs) VALUES ('zz284_x', '0.0.1', 'file:x.json', %L, 1, 0, 'x',
                      '{"brand_rules": {"t2:some-tenant": {}}}')$q$, sha)]
        LOOP
            refused := false;
            BEGIN
                EXECUTE bad;
            EXCEPTION WHEN check_violation THEN refused := true;
            END;
            IF NOT refused THEN
                RAISE EXCEPTION 'migration 284: accepted %', left(bad, 200);
            END IF;
        END LOOP;

        RAISE EXCEPTION 'probe done' USING ERRCODE = 'ZZ284';
    EXCEPTION WHEN SQLSTATE 'ZZ284' THEN
        NULL;
    END;
    IF EXISTS (SELECT 1 FROM shared.eval_golden_set WHERE name LIKE 'zz284%')
       OR EXISTS (SELECT 1 FROM shared.prompt_eval_runs WHERE triggered_by = 'migration-284-probe'
                                                            OR prompt_version = 'migration-284-probe') THEN
        RAISE EXCEPTION 'migration 284: the behaviour probe was not rolled back';
    END IF;
    SELECT count(*) INTO n FROM shared.eval_golden_item;
    RAISE NOTICE 'migration 284: golden set tables under RLS (forced), % items', n;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('284', now(), 'AA-919 WM-17: shared.eval_golden_set / eval_golden_item / eval_item_result (items and results '
                      'RLS forced, tenant rows erasable), prompt_eval_runs widened into the writing-memory run ledger')
ON CONFLICT (version) DO NOTHING;

COMMIT;
