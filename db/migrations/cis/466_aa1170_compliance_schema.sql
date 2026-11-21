-- Migration 466: AA-1170 (S287, compliance readiness page, phase 1; tech lead decisions Q1-Q17 of the S287 decision
-- page, root docs/audits/2026-11-21-S287-compliance-tracking/README.md sections 4 C.2 and 8) — schema compliance: the
-- requirement catalogue of the in-scope frameworks, the common controls and their mapping, the evidence the
-- collectors publish and the daily score snapshot, plus the cis.compliance.* settings of the score.
--
-- Why. The admin has no place that shows how far the platform meets the security and AI standards: the S286 scores
-- (ISO 27001 45.8 %, SOC 2 44.0 %, ISO 42001 46.9 %, OWASP Top 10 64.8 %, OWASP LLM 66.7 %) were scored once, by hand.
-- Q2: the register lives in the database (the repos are public), the code reads it; Q3: the headline is Evidenced %
-- (only fresh, passing evidence counts), strict and weighted; Q4: every requirement of each framework is listed and
-- mapped onto a smaller set of common controls.
--
-- What:
--   1. CREATE SCHEMA compliance (owner = the runner, cis_owner on Dev; CREATE ON DATABASE from rl-002, as CIS 420).
--      USAGE for cis_app only; nothing for PUBLIC or aa_app_user.
--   2. Five tables, none with a tenant column (platform data; no row-level security, like shared.setting_definition
--      before tenants):
--        requirement          the catalogue: (framework, ref) of every requirement in scope — ISO/IEC 27001:2022
--                             clauses 4-10 and Annex A, SOC 2 Trust Services Criteria common criteria (2017, points
--                             of focus 2022), ISO/IEC 42001:2023 clauses and Annex A, OWASP Top 10 2021, OWASP Top 10
--                             for LLM Applications 2025, and the EU AI Act (Regulation (EU) 2024/1689) articles that
--                             apply to a deployer of limited-risk AI. Identifiers only, with a short label in OUR OWN
--                             words: the standards' text is copyrighted and never stored (the unit test of the code PR
--                             refuses a label over 80 characters or one that reads like normative text).
--                             applicable (the Statement of Applicability decision; true for every seeded row),
--                             sort_order for display.
--        control              the common control set (control_id such as ABC-IAM-03, title / intent in our words,
--                             domain, owner role, frequency, test type, checks = the evidence check ids it needs,
--                             scope, active). NOT seeded: the controls and their mapping come from the private S286
--                             matrix through the loader of the code PR (scripts/compliance/load_register.py, run by
--                             the orchestrator over ECS exec as cis_app), never from a public repo.
--        requirement_mapping  control x requirement, coverage full | partial (one control can satisfy requirements in
--                             several frameworks; a requirement can be covered by several controls).
--        evidence             append-only: one row per check result a collector published (source, check_id, status
--                             pass | fail | error | stale | manual, collected_at, valid_until, collector, collector
--                             version = git SHA, run reference, a short summary, detail = counts and dates only (no
--                             secret, no account ID, no personal data; at most 8 KiB), an https link). A trigger
--                             refuses UPDATE and TRUNCATE, and DELETE unless the transaction set
--                             compliance.retention_purge = 'on' (the retention job, before prod). Unique (source,
--                             check_id, collected_at): ingesting the same published file twice adds nothing.
--        score_snapshot       one row per UTC day and framework: requirement counts (met, partial, gap, stale,
--                             unmapped), strict and weighted Evidenced %, the reference %, the settings in force.
--      cis_app: SELECT, INSERT, UPDATE, DELETE on every table, plus default privileges FOR ROLE cis_owner IN SCHEMA
--      compliance (tables, sequences, functions), the shape the isolation probe expects (AA-CIS-Infra owners.yaml
--      schemas_from {compliance: "466"}). The evidence trigger keeps the rows append-only whatever the grant.
--      DM-6.1: no personal data column (control owner_role is a role word, never a name).
--   3. Seed: the 253 requirement rows (identifiers and our labels; JSON below, ON CONFLICT DO NOTHING).
--   4. Eight rows in shared.setting_definition, area compliance (settings-seed block below, read by
--      scripts/settings/gen_compiled_defaults.py into shared/settings/compiled_defaults.json in this PR; the keys are
--      named in api/services/compliance_settings.py), each with its plain label and EN + VI guide (CIS 416 rule):
--        cis.compliance.validity_hours.root_daily    int hours 1-2160, default 72: how long a result of the root daily
--                                                    collector counts; older = stale (lowers the score)
--        cis.compliance.collector_heartbeat_hours    int hours 1-720, default 36: a collector silent longer turns its
--                                                    checks to error
--        cis.compliance.partial_weight               numeric 0-1, default 0.5 (S286): weight of partial coverage
--        cis.compliance.drill_max_age_days           int days 1-730, default 90: last passed drill
--        cis.compliance.access_review_max_age_days   int days 1-730, default 100: last access review
--        cis.compliance.docs_overdue_max             int pages 0-1000, default 0: docs past their review date
--        cis.compliance.ci_scan_max_age_days         int days 1-90, default 8: the oldest of the newest image scans
--                                                    of the image repos (merge-queue CI runs)
--        cis.compliance.reference_scores             json, default the S286 scores: the reference line (display only)
--      Score-changing keys are maker_checker (with cis.settings.two_person_approval off, the administrator's own
--      approval is recorded as self-approved, tech lead Q13: no second signer for now); enforced (the code PR reads
--      them; until it is deployed nothing reads them, like CIS 461).
--   5. A post-check, then register 466.
--
-- Behaviour on apply. None for running code: new schema, empty controls / mappings / evidence / snapshots, config rows
-- nobody reads until the code PR (Platform › Compliance, /admin/platform/compliance) is deployed.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a new schema, REVOKE / ALTER DEFAULT
-- PRIVILEGES, a trigger function, seed rows and config rows INSERTed into shared.setting_definition, and a DO
-- post-check are outside the expand set. On Dev: Infra Migration Apply once every job table is idle (root ADR 0017a).
-- MIG-4: this migration-only PR, then the code PR (readiness raised to 466 there). Retention rows (DM-7.1): root data
-- standards Part B section 7, merged before the Infra copy (the Infra retention-row check reads the compliance tables
-- of the cis dir once AA-CIS-Infra lists compliance in RETENTION_SCHEMAS). Ownership registry: AA-CIS-Infra
-- db/owners.yaml lists compliance under cis with schemas_from 466 (merged before the Infra copy: the Copy Guard
-- ownership lint reads it; .github/workflows/ci.yml INFRA_TOOLS_SHA must name an Infra commit that has it).
--
-- Number. 464 is the highest on main (21/11/2026); 465 is reserved by another lane of the S287 wave. If the owner main
-- max + 1 differs at merge, renumber everywhere (git grep '466_' and '466' in this repo: this file,
-- tests/integration/test_aa1170_migration_466.py, docs/implementation-notes/AA-1170.md; AA-CIS-Infra owners.yaml and
-- isolation_probe.py schemas_from; the root data standards rows).
--
-- Locks. New objects only, plus one INSERT of eight config rows (the definition guard trigger allows the file's role,
-- cis_owner). lock_timeout 5s. Re-runnable (IF NOT EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING); one transaction,
-- self-registering.
--
-- X1. One BEGIN … COMMIT block, no role switch (Migration Apply runs cis/ files as cis_owner, the owner of schema
-- shared and, after this file, of schema compliance).
--
-- Rollback (a new forward migration, after the code PR is reverted): DROP SCHEMA compliance CASCADE and DELETE the
-- eight cis.compliance.* keys (their value rows first): a destructive file, DRY RUN (the evidence is audit history).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- 1. Schema ─────────────────────────────────────────────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS compliance;
COMMENT ON SCHEMA compliance IS
    'Compliance readiness register (AA-1170): requirement catalogue (identifiers and our own labels), common controls, '
    'their mapping, collector evidence (append-only) and daily score snapshots. Owner AA-CIS-App; cis_app only.';
REVOKE ALL ON SCHEMA compliance FROM PUBLIC;
GRANT USAGE ON SCHEMA compliance TO cis_app;

-- 2. Tables ─────────────────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS compliance.requirement (
    framework   text    NOT NULL,
    ref         text    NOT NULL,
    section     text    NOT NULL,
    title       text    NOT NULL,
    applicable  boolean NOT NULL DEFAULT true,
    sort_order  integer NOT NULL,
    CONSTRAINT requirement_pkey PRIMARY KEY (framework, ref),
    CONSTRAINT requirement_framework_check CHECK (framework IN ('iso27001:2022', 'soc2:2017', 'iso42001:2023',
                                                                'owasp-top10:2021', 'owasp-llm:2025', 'eu-ai-act:2024')),
    CONSTRAINT requirement_ref_check CHECK (ref ~ '^[A-Za-z0-9][A-Za-z0-9.()_-]{0,23}$'),
    CONSTRAINT requirement_section_check CHECK (char_length(section) BETWEEN 1 AND 80),
    CONSTRAINT requirement_title_check CHECK (char_length(title) BETWEEN 3 AND 80),
    CONSTRAINT requirement_sort_check CHECK (sort_order > 0)
);
COMMENT ON TABLE compliance.requirement IS
    'AA-1170 (CIS 466): every requirement of the in-scope frameworks, by identifier. title is a short label in our own '
    'words; the standards'' text is copyrighted and never stored. applicable = the Statement of Applicability decision.';

CREATE TABLE IF NOT EXISTS compliance.control (
    control_id  text        NOT NULL,
    title       text        NOT NULL,
    intent      text,
    domain      text        NOT NULL,
    owner_role  text        NOT NULL,
    frequency   text        NOT NULL,
    test_type   text        NOT NULL,
    checks      jsonb       NOT NULL DEFAULT '[]'::jsonb,
    scope       text        NOT NULL DEFAULT 'dev',
    active      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT control_pkey PRIMARY KEY (control_id),
    CONSTRAINT control_id_check CHECK (control_id ~ '^[A-Z][A-Z0-9]{1,9}(-[A-Z0-9]{1,10}){1,3}$'),
    CONSTRAINT control_title_check CHECK (char_length(title) BETWEEN 3 AND 160),
    CONSTRAINT control_intent_check CHECK (intent IS NULL OR char_length(intent) <= 1000),
    CONSTRAINT control_domain_check CHECK (domain ~ '^[a-z][a-z0-9_]{1,40}$'),
    CONSTRAINT control_owner_role_check CHECK (char_length(owner_role) BETWEEN 2 AND 60),
    CONSTRAINT control_frequency_check CHECK (frequency IN ('continuous', 'daily', 'weekly', 'monthly', 'quarterly',
                                                            'annual')),
    CONSTRAINT control_test_type_check CHECK (test_type IN ('auto', 'manual', 'hybrid')),
    CONSTRAINT control_checks_check CHECK (jsonb_typeof(checks) = 'array' AND jsonb_array_length(checks) <= 20),
    CONSTRAINT control_scope_check CHECK (scope IN ('dev', 'prod', 'all'))
);
COMMENT ON TABLE compliance.control IS
    'AA-1170 (CIS 466): the common control set (what we do and prove). checks = [{"check_id", "required"}], the '
    'evidence checks it needs. Loaded from the private register by scripts/compliance/load_register.py; never seeded '
    'from a public repo.';
COMMENT ON COLUMN compliance.control.owner_role IS
    'AA-1170 (466): the role that owns the control ("tech lead", "business owner"), never a person''s name.';

CREATE TABLE IF NOT EXISTS compliance.requirement_mapping (
    control_id  text NOT NULL REFERENCES compliance.control (control_id) ON DELETE CASCADE,
    framework   text NOT NULL,
    ref         text NOT NULL,
    coverage    text NOT NULL,
    note        text,
    CONSTRAINT requirement_mapping_pkey PRIMARY KEY (control_id, framework, ref),
    CONSTRAINT requirement_mapping_requirement_fkey FOREIGN KEY (framework, ref)
        REFERENCES compliance.requirement (framework, ref) ON DELETE RESTRICT,
    CONSTRAINT requirement_mapping_coverage_check CHECK (coverage IN ('full', 'partial')),
    CONSTRAINT requirement_mapping_note_check CHECK (note IS NULL OR char_length(note) <= 300)
);
CREATE INDEX IF NOT EXISTS requirement_mapping_requirement_idx ON compliance.requirement_mapping (framework, ref);
COMMENT ON TABLE compliance.requirement_mapping IS
    'AA-1170 (CIS 466): which control covers which requirement, full or partial.';

CREATE TABLE IF NOT EXISTS compliance.evidence (
    evidence_id       bigint      GENERATED ALWAYS AS IDENTITY,
    source            text        NOT NULL,
    check_id          text        NOT NULL,
    status            text        NOT NULL,
    collected_at      timestamptz NOT NULL,
    valid_until       timestamptz,
    collector         text        NOT NULL,
    collector_version text,
    run_ref           text,
    summary           text,
    detail            jsonb       NOT NULL DEFAULT '{}'::jsonb,
    link              text,
    ingested_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT evidence_pkey PRIMARY KEY (evidence_id),
    CONSTRAINT evidence_once_key UNIQUE (source, check_id, collected_at),
    CONSTRAINT evidence_source_check CHECK (source ~ '^[a-z][a-z0-9_]{1,40}$'),
    CONSTRAINT evidence_check_id_check CHECK (check_id ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT evidence_status_check CHECK (status IN ('pass', 'fail', 'error', 'stale', 'manual')),
    CONSTRAINT evidence_valid_until_check CHECK (valid_until IS NULL OR valid_until > collected_at),
    CONSTRAINT evidence_collector_check CHECK (char_length(collector) BETWEEN 1 AND 120),
    CONSTRAINT evidence_version_check CHECK (collector_version IS NULL OR collector_version ~ '^[0-9a-f]{7,40}$'),
    CONSTRAINT evidence_run_ref_check CHECK (run_ref IS NULL OR char_length(run_ref) <= 120),
    CONSTRAINT evidence_summary_check CHECK (summary IS NULL OR char_length(summary) <= 300),
    CONSTRAINT evidence_detail_check CHECK (jsonb_typeof(detail) = 'object' AND octet_length(detail::text) <= 8192),
    CONSTRAINT evidence_link_check CHECK (link IS NULL OR (link LIKE 'https://%' AND char_length(link) <= 500))
);
CREATE INDEX IF NOT EXISTS evidence_check_idx ON compliance.evidence (check_id, collected_at DESC);
CREATE INDEX IF NOT EXISTS evidence_source_idx ON compliance.evidence (source, collected_at DESC);
COMMENT ON TABLE compliance.evidence IS
    'AA-1170 (CIS 466): one row per check result a collector published; append-only (trigger). stale is also derived '
    'at read time from collected_at and the validity setting of the source. detail holds counts and dates only.';
COMMENT ON COLUMN compliance.evidence.collector_version IS
    'AA-1170 (466): the git SHA of the collector code that produced the result (IPE: the auditor can re-run it).';

CREATE TABLE IF NOT EXISTS compliance.score_snapshot (
    snapshot_date  date         NOT NULL,
    framework      text         NOT NULL,
    n_requirements integer      NOT NULL,
    n_met          integer      NOT NULL,
    n_partial      integer      NOT NULL,
    n_gap          integer      NOT NULL,
    n_stale        integer      NOT NULL,
    n_unmapped     integer      NOT NULL,
    strict_pct     numeric(5,2) NOT NULL,
    weighted_pct   numeric(5,2) NOT NULL,
    reference_pct  numeric(5,2),
    settings       jsonb        NOT NULL DEFAULT '{}'::jsonb,
    computed_at    timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT score_snapshot_pkey PRIMARY KEY (snapshot_date, framework),
    CONSTRAINT score_snapshot_framework_check CHECK (framework IN ('iso27001:2022', 'soc2:2017', 'iso42001:2023',
                                                                   'owasp-top10:2021', 'owasp-llm:2025',
                                                                   'eu-ai-act:2024')),
    CONSTRAINT score_snapshot_counts_check CHECK (n_requirements >= 0 AND n_met >= 0 AND n_partial >= 0
                                                  AND n_gap >= 0 AND n_stale >= 0 AND n_unmapped >= 0
                                                  AND n_met + n_partial + n_gap <= n_requirements),
    CONSTRAINT score_snapshot_pct_check CHECK (strict_pct BETWEEN 0 AND 100 AND weighted_pct BETWEEN 0 AND 100
                                               AND (reference_pct IS NULL OR reference_pct BETWEEN 0 AND 100)),
    CONSTRAINT score_snapshot_settings_check CHECK (jsonb_typeof(settings) = 'object')
);
COMMENT ON TABLE compliance.score_snapshot IS
    'AA-1170 (CIS 466): the Evidenced % of each framework once per UTC day (the trend and the history an auditor '
    'samples), with the settings in force when it was computed.';

-- Append-only guard of compliance.evidence ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION compliance.evidence_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' AND current_setting('compliance.retention_purge', true) = 'on' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'compliance.evidence is append-only (% refused; only the retention purge deletes)', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END
$fn$;
REVOKE ALL ON FUNCTION compliance.evidence_append_only() FROM PUBLIC;
DROP TRIGGER IF EXISTS evidence_append_only_trg ON compliance.evidence;
CREATE TRIGGER evidence_append_only_trg BEFORE UPDATE OR DELETE ON compliance.evidence
    FOR EACH ROW EXECUTE FUNCTION compliance.evidence_append_only();
DROP TRIGGER IF EXISTS evidence_no_truncate_trg ON compliance.evidence;
CREATE TRIGGER evidence_no_truncate_trg BEFORE TRUNCATE ON compliance.evidence
    FOR EACH STATEMENT EXECUTE FUNCTION compliance.evidence_append_only();

-- Grants: cis_app DML, the default privileges the isolation probe expects ──────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA compliance TO cis_app;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA compliance TO cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE cis_owner IN SCHEMA compliance GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE cis_owner IN SCHEMA compliance GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE cis_owner IN SCHEMA compliance GRANT EXECUTE ON FUNCTIONS TO cis_app;

-- 3. Requirement catalogue (identifiers + our own labels) ──────────────────────────────────────────────────────────
INSERT INTO compliance.requirement (framework, ref, section, title, sort_order)
SELECT r.framework, r.ref, r.section, r.title, r.sort_order
  FROM jsonb_to_recordset($catalogue$
[
{"framework": "iso27001:2022", "ref": "4.1", "section": "Clause 4 Context", "title": "Know the internal and external issues that shape the ISMS", "sort_order": 1},
{"framework": "iso27001:2022", "ref": "4.2", "section": "Clause 4 Context", "title": "Know the interested parties and what they expect on security", "sort_order": 2},
{"framework": "iso27001:2022", "ref": "4.3", "section": "Clause 4 Context", "title": "Write down what the ISMS covers and what it leaves out", "sort_order": 3},
{"framework": "iso27001:2022", "ref": "4.4", "section": "Clause 4 Context", "title": "Run the ISMS as a set of linked processes and improve it", "sort_order": 4},
{"framework": "iso27001:2022", "ref": "5.1", "section": "Clause 5 Leadership", "title": "Top management backs the ISMS and gives it what it needs", "sort_order": 5},
{"framework": "iso27001:2022", "ref": "5.2", "section": "Clause 5 Leadership", "title": "A written security policy, approved and shared", "sort_order": 6},
{"framework": "iso27001:2022", "ref": "5.3", "section": "Clause 5 Leadership", "title": "Security roles and who decides what are assigned", "sort_order": 7},
{"framework": "iso27001:2022", "ref": "6.1.1", "section": "Clause 6 Planning", "title": "Plan how to handle security risks and opportunities", "sort_order": 8},
{"framework": "iso27001:2022", "ref": "6.1.2", "section": "Clause 6 Planning", "title": "A repeatable method to find and rate security risks", "sort_order": 9},
{"framework": "iso27001:2022", "ref": "6.1.3", "section": "Clause 6 Planning", "title": "Pick risk treatments and keep a statement of which controls apply", "sort_order": 10},
{"framework": "iso27001:2022", "ref": "6.2", "section": "Clause 6 Planning", "title": "Set measurable security goals and plan how to reach them", "sort_order": 11},
{"framework": "iso27001:2022", "ref": "6.3", "section": "Clause 6 Planning", "title": "Plan changes to the ISMS before making them", "sort_order": 12},
{"framework": "iso27001:2022", "ref": "7.1", "section": "Clause 7 Support", "title": "Give the ISMS the people, time and tools it needs", "sort_order": 13},
{"framework": "iso27001:2022", "ref": "7.2", "section": "Clause 7 Support", "title": "People doing security work have the skills for it", "sort_order": 14},
{"framework": "iso27001:2022", "ref": "7.3", "section": "Clause 7 Support", "title": "Everyone knows the policy and their part in it", "sort_order": 15},
{"framework": "iso27001:2022", "ref": "7.4", "section": "Clause 7 Support", "title": "Decide what to tell whom about security, and when", "sort_order": 16},
{"framework": "iso27001:2022", "ref": "7.5.1", "section": "Clause 7 Support", "title": "Keep the written records the ISMS relies on", "sort_order": 17},
{"framework": "iso27001:2022", "ref": "7.5.2", "section": "Clause 7 Support", "title": "Write and update documents with a review and approval", "sort_order": 18},
{"framework": "iso27001:2022", "ref": "7.5.3", "section": "Clause 7 Support", "title": "Control documents: who reads them, versions, how long kept", "sort_order": 19},
{"framework": "iso27001:2022", "ref": "8.1", "section": "Clause 8 Operation", "title": "Plan and run the security processes as designed", "sort_order": 20},
{"framework": "iso27001:2022", "ref": "8.2", "section": "Clause 8 Operation", "title": "Assess risks on a schedule and after big changes", "sort_order": 21},
{"framework": "iso27001:2022", "ref": "8.3", "section": "Clause 8 Operation", "title": "Carry out the chosen risk treatments", "sort_order": 22},
{"framework": "iso27001:2022", "ref": "9.1", "section": "Clause 9 Performance evaluation", "title": "Measure how well security works and report it", "sort_order": 23},
{"framework": "iso27001:2022", "ref": "9.2.1", "section": "Clause 9 Performance evaluation", "title": "Audit the ISMS internally on a schedule", "sort_order": 24},
{"framework": "iso27001:2022", "ref": "9.2.2", "section": "Clause 9 Performance evaluation", "title": "Keep an audit plan with scope, criteria and reports", "sort_order": 25},
{"framework": "iso27001:2022", "ref": "9.3.1", "section": "Clause 9 Performance evaluation", "title": "Management looks at the ISMS on a schedule", "sort_order": 26},
{"framework": "iso27001:2022", "ref": "9.3.2", "section": "Clause 9 Performance evaluation", "title": "That review covers status, changes, feedback and risks", "sort_order": 27},
{"framework": "iso27001:2022", "ref": "9.3.3", "section": "Clause 9 Performance evaluation", "title": "That review leaves a record of its decisions", "sort_order": 28},
{"framework": "iso27001:2022", "ref": "10.1", "section": "Clause 10 Improvement", "title": "Keep making the ISMS better", "sort_order": 29},
{"framework": "iso27001:2022", "ref": "10.2", "section": "Clause 10 Improvement", "title": "Fix what failed, find why, and stop it coming back", "sort_order": 30},
{"framework": "iso27001:2022", "ref": "A.5.1", "section": "Annex A.5 Organisational", "title": "Security policies set, approved and shared with staff", "sort_order": 31},
{"framework": "iso27001:2022", "ref": "A.5.2", "section": "Annex A.5 Organisational", "title": "Security duties given to named roles", "sort_order": 32},
{"framework": "iso27001:2022", "ref": "A.5.3", "section": "Annex A.5 Organisational", "title": "Duties that conflict kept with different people", "sort_order": 33},
{"framework": "iso27001:2022", "ref": "A.5.4", "section": "Annex A.5 Organisational", "title": "Managers make staff follow the security rules", "sort_order": 34},
{"framework": "iso27001:2022", "ref": "A.5.5", "section": "Annex A.5 Organisational", "title": "Contacts with the authorities kept ready", "sort_order": 35},
{"framework": "iso27001:2022", "ref": "A.5.6", "section": "Annex A.5 Organisational", "title": "Contacts with security forums and peer groups kept", "sort_order": 36},
{"framework": "iso27001:2022", "ref": "A.5.7", "section": "Annex A.5 Organisational", "title": "Threat news gathered and acted on", "sort_order": 37},
{"framework": "iso27001:2022", "ref": "A.5.8", "section": "Annex A.5 Organisational", "title": "Security built into every project", "sort_order": 38},
{"framework": "iso27001:2022", "ref": "A.5.9", "section": "Annex A.5 Organisational", "title": "A list of information and assets, each with an owner", "sort_order": 39},
{"framework": "iso27001:2022", "ref": "A.5.10", "section": "Annex A.5 Organisational", "title": "Rules for the proper use of information and assets", "sort_order": 40},
{"framework": "iso27001:2022", "ref": "A.5.11", "section": "Annex A.5 Organisational", "title": "Assets handed back when people leave", "sort_order": 41},
{"framework": "iso27001:2022", "ref": "A.5.12", "section": "Annex A.5 Organisational", "title": "Information sorted into classes by how much it needs protecting", "sort_order": 42},
{"framework": "iso27001:2022", "ref": "A.5.13", "section": "Annex A.5 Organisational", "title": "Information marked with its class", "sort_order": 43},
{"framework": "iso27001:2022", "ref": "A.5.14", "section": "Annex A.5 Organisational", "title": "Rules for sending information to others", "sort_order": 44},
{"framework": "iso27001:2022", "ref": "A.5.15", "section": "Annex A.5 Organisational", "title": "Rules for who may reach which information", "sort_order": 45},
{"framework": "iso27001:2022", "ref": "A.5.16", "section": "Annex A.5 Organisational", "title": "Identities created, changed and removed under control", "sort_order": 46},
{"framework": "iso27001:2022", "ref": "A.5.17", "section": "Annex A.5 Organisational", "title": "Passwords and other sign-in secrets handled safely", "sort_order": 47},
{"framework": "iso27001:2022", "ref": "A.5.18", "section": "Annex A.5 Organisational", "title": "Access rights given, checked and taken back", "sort_order": 48},
{"framework": "iso27001:2022", "ref": "A.5.19", "section": "Annex A.5 Organisational", "title": "Security risks of suppliers handled", "sort_order": 49},
{"framework": "iso27001:2022", "ref": "A.5.20", "section": "Annex A.5 Organisational", "title": "Security terms written into supplier contracts", "sort_order": 50},
{"framework": "iso27001:2022", "ref": "A.5.21", "section": "Annex A.5 Organisational", "title": "Security risks of the ICT supply chain handled", "sort_order": 51},
{"framework": "iso27001:2022", "ref": "A.5.22", "section": "Annex A.5 Organisational", "title": "Supplier services watched and their changes reviewed", "sort_order": 52},
{"framework": "iso27001:2022", "ref": "A.5.23", "section": "Annex A.5 Organisational", "title": "Cloud services bought, used and left securely", "sort_order": 53},
{"framework": "iso27001:2022", "ref": "A.5.24", "section": "Annex A.5 Organisational", "title": "Incident handling planned and roles ready", "sort_order": 54},
{"framework": "iso27001:2022", "ref": "A.5.25", "section": "Annex A.5 Organisational", "title": "Security events judged: incident or not", "sort_order": 55},
{"framework": "iso27001:2022", "ref": "A.5.26", "section": "Annex A.5 Organisational", "title": "Incidents handled by the written procedure", "sort_order": 56},
{"framework": "iso27001:2022", "ref": "A.5.27", "section": "Annex A.5 Organisational", "title": "What incidents teach is fed back", "sort_order": 57},
{"framework": "iso27001:2022", "ref": "A.5.28", "section": "Annex A.5 Organisational", "title": "Evidence of events collected and kept intact", "sort_order": 58},
{"framework": "iso27001:2022", "ref": "A.5.29", "section": "Annex A.5 Organisational", "title": "Security kept up during a disruption", "sort_order": 59},
{"framework": "iso27001:2022", "ref": "A.5.30", "section": "Annex A.5 Organisational", "title": "ICT ready to keep the business running", "sort_order": 60},
{"framework": "iso27001:2022", "ref": "A.5.31", "section": "Annex A.5 Organisational", "title": "Laws, rules and contract duties on security known", "sort_order": 61},
{"framework": "iso27001:2022", "ref": "A.5.32", "section": "Annex A.5 Organisational", "title": "Others' intellectual property respected", "sort_order": 62},
{"framework": "iso27001:2022", "ref": "A.5.33", "section": "Annex A.5 Organisational", "title": "Records kept safe from loss and tampering", "sort_order": 63},
{"framework": "iso27001:2022", "ref": "A.5.34", "section": "Annex A.5 Organisational", "title": "Personal data protected as the law asks", "sort_order": 64},
{"framework": "iso27001:2022", "ref": "A.5.35", "section": "Annex A.5 Organisational", "title": "Security reviewed by someone independent", "sort_order": 65},
{"framework": "iso27001:2022", "ref": "A.5.36", "section": "Annex A.5 Organisational", "title": "Policies and standards checked as actually followed", "sort_order": 66},
{"framework": "iso27001:2022", "ref": "A.5.37", "section": "Annex A.5 Organisational", "title": "Operating steps written down and at hand", "sort_order": 67},
{"framework": "iso27001:2022", "ref": "A.6.1", "section": "Annex A.6 People", "title": "Candidates checked before they join", "sort_order": 68},
{"framework": "iso27001:2022", "ref": "A.6.2", "section": "Annex A.6 People", "title": "Security duties written into the job terms", "sort_order": 69},
{"framework": "iso27001:2022", "ref": "A.6.3", "section": "Annex A.6 People", "title": "Staff made aware and trained on security", "sort_order": 70},
{"framework": "iso27001:2022", "ref": "A.6.4", "section": "Annex A.6 People", "title": "A disciplinary process for security breaches", "sort_order": 71},
{"framework": "iso27001:2022", "ref": "A.6.5", "section": "Annex A.6 People", "title": "Security duties that last after leaving or moving", "sort_order": 72},
{"framework": "iso27001:2022", "ref": "A.6.6", "section": "Annex A.6 People", "title": "Non-disclosure agreements in place", "sort_order": 73},
{"framework": "iso27001:2022", "ref": "A.6.7", "section": "Annex A.6 People", "title": "Working from elsewhere made safe", "sort_order": 74},
{"framework": "iso27001:2022", "ref": "A.6.8", "section": "Annex A.6 People", "title": "Staff report security events quickly", "sort_order": 75},
{"framework": "iso27001:2022", "ref": "A.7.1", "section": "Annex A.7 Physical", "title": "Secure areas have a defined boundary", "sort_order": 76},
{"framework": "iso27001:2022", "ref": "A.7.2", "section": "Annex A.7 Physical", "title": "Entry to secure areas controlled", "sort_order": 77},
{"framework": "iso27001:2022", "ref": "A.7.3", "section": "Annex A.7 Physical", "title": "Offices and rooms secured", "sort_order": 78},
{"framework": "iso27001:2022", "ref": "A.7.4", "section": "Annex A.7 Physical", "title": "Premises watched for unauthorised entry", "sort_order": 79},
{"framework": "iso27001:2022", "ref": "A.7.5", "section": "Annex A.7 Physical", "title": "Protection from fire, flood and other physical threats", "sort_order": 80},
{"framework": "iso27001:2022", "ref": "A.7.6", "section": "Annex A.7 Physical", "title": "Rules for working inside secure areas", "sort_order": 81},
{"framework": "iso27001:2022", "ref": "A.7.7", "section": "Annex A.7 Physical", "title": "Desks cleared and screens locked", "sort_order": 82},
{"framework": "iso27001:2022", "ref": "A.7.8", "section": "Annex A.7 Physical", "title": "Equipment placed and guarded with care", "sort_order": 83},
{"framework": "iso27001:2022", "ref": "A.7.9", "section": "Annex A.7 Physical", "title": "Assets kept safe when taken off site", "sort_order": 84},
{"framework": "iso27001:2022", "ref": "A.7.10", "section": "Annex A.7 Physical", "title": "Storage media handled safely through their life", "sort_order": 85},
{"framework": "iso27001:2022", "ref": "A.7.11", "section": "Annex A.7 Physical", "title": "Power and other utilities kept running", "sort_order": 86},
{"framework": "iso27001:2022", "ref": "A.7.12", "section": "Annex A.7 Physical", "title": "Power and data cables protected", "sort_order": 87},
{"framework": "iso27001:2022", "ref": "A.7.13", "section": "Annex A.7 Physical", "title": "Equipment kept maintained", "sort_order": 88},
{"framework": "iso27001:2022", "ref": "A.7.14", "section": "Annex A.7 Physical", "title": "Equipment wiped before it is reused or thrown away", "sort_order": 89},
{"framework": "iso27001:2022", "ref": "A.8.1", "section": "Annex A.8 Technological", "title": "Laptops and other user devices protected", "sort_order": 90},
{"framework": "iso27001:2022", "ref": "A.8.2", "section": "Annex A.8 Technological", "title": "Admin-level access kept narrow and controlled", "sort_order": 91},
{"framework": "iso27001:2022", "ref": "A.8.3", "section": "Annex A.8 Technological", "title": "Reach to information limited to what is allowed", "sort_order": 92},
{"framework": "iso27001:2022", "ref": "A.8.4", "section": "Annex A.8 Technological", "title": "Read and write access to source code controlled", "sort_order": 93},
{"framework": "iso27001:2022", "ref": "A.8.5", "section": "Annex A.8 Technological", "title": "Sign-in done securely", "sort_order": 94},
{"framework": "iso27001:2022", "ref": "A.8.6", "section": "Annex A.8 Technological", "title": "Capacity watched and planned", "sort_order": 95},
{"framework": "iso27001:2022", "ref": "A.8.7", "section": "Annex A.8 Technological", "title": "Protection from malicious software", "sort_order": 96},
{"framework": "iso27001:2022", "ref": "A.8.8", "section": "Annex A.8 Technological", "title": "Known weaknesses found and fixed in time", "sort_order": 97},
{"framework": "iso27001:2022", "ref": "A.8.9", "section": "Annex A.8 Technological", "title": "System configurations set, kept and checked", "sort_order": 98},
{"framework": "iso27001:2022", "ref": "A.8.10", "section": "Annex A.8 Technological", "title": "Information deleted when no longer needed", "sort_order": 99},
{"framework": "iso27001:2022", "ref": "A.8.11", "section": "Annex A.8 Technological", "title": "Sensitive data hidden where it is not needed", "sort_order": 100},
{"framework": "iso27001:2022", "ref": "A.8.12", "section": "Annex A.8 Technological", "title": "Data kept from leaking out", "sort_order": 101},
{"framework": "iso27001:2022", "ref": "A.8.13", "section": "Annex A.8 Technological", "title": "Backups taken and restores proven", "sort_order": 102},
{"framework": "iso27001:2022", "ref": "A.8.14", "section": "Annex A.8 Technological", "title": "Spare capacity so a failure does not stop service", "sort_order": 103},
{"framework": "iso27001:2022", "ref": "A.8.15", "section": "Annex A.8 Technological", "title": "Activity and security logs recorded and kept", "sort_order": 104},
{"framework": "iso27001:2022", "ref": "A.8.16", "section": "Annex A.8 Technological", "title": "Systems watched for unusual behaviour", "sort_order": 105},
{"framework": "iso27001:2022", "ref": "A.8.17", "section": "Annex A.8 Technological", "title": "System clocks kept in step", "sort_order": 106},
{"framework": "iso27001:2022", "ref": "A.8.18", "section": "Annex A.8 Technological", "title": "Powerful utility programs kept restricted", "sort_order": 107},
{"framework": "iso27001:2022", "ref": "A.8.19", "section": "Annex A.8 Technological", "title": "Software installs on running systems controlled", "sort_order": 108},
{"framework": "iso27001:2022", "ref": "A.8.20", "section": "Annex A.8 Technological", "title": "Networks and the devices on them protected", "sort_order": 109},
{"framework": "iso27001:2022", "ref": "A.8.21", "section": "Annex A.8 Technological", "title": "Network services secured and agreed", "sort_order": 110},
{"framework": "iso27001:2022", "ref": "A.8.22", "section": "Annex A.8 Technological", "title": "Networks split into separate zones", "sort_order": 111},
{"framework": "iso27001:2022", "ref": "A.8.23", "section": "Annex A.8 Technological", "title": "Access to harmful websites limited", "sort_order": 112},
{"framework": "iso27001:2022", "ref": "A.8.24", "section": "Annex A.8 Technological", "title": "Encryption and keys used by agreed rules", "sort_order": 113},
{"framework": "iso27001:2022", "ref": "A.8.25", "section": "Annex A.8 Technological", "title": "Security built into the whole development cycle", "sort_order": 114},
{"framework": "iso27001:2022", "ref": "A.8.26", "section": "Annex A.8 Technological", "title": "Security needs written down for each application", "sort_order": 115},
{"framework": "iso27001:2022", "ref": "A.8.27", "section": "Annex A.8 Technological", "title": "Systems designed and built on secure principles", "sort_order": 116},
{"framework": "iso27001:2022", "ref": "A.8.28", "section": "Annex A.8 Technological", "title": "Code written to secure coding rules", "sort_order": 117},
{"framework": "iso27001:2022", "ref": "A.8.29", "section": "Annex A.8 Technological", "title": "Security tested before release", "sort_order": 118},
{"framework": "iso27001:2022", "ref": "A.8.30", "section": "Annex A.8 Technological", "title": "Outsourced development directed and checked", "sort_order": 119},
{"framework": "iso27001:2022", "ref": "A.8.31", "section": "Annex A.8 Technological", "title": "Development, test and live systems kept apart", "sort_order": 120},
{"framework": "iso27001:2022", "ref": "A.8.32", "section": "Annex A.8 Technological", "title": "Changes to systems controlled and approved", "sort_order": 121},
{"framework": "iso27001:2022", "ref": "A.8.33", "section": "Annex A.8 Technological", "title": "Test data chosen and protected", "sort_order": 122},
{"framework": "iso27001:2022", "ref": "A.8.34", "section": "Annex A.8 Technological", "title": "Audit tests planned so they do not harm live systems", "sort_order": 123},
{"framework": "soc2:2017", "ref": "CC1.1", "section": "CC1 Control environment", "title": "Commitment to integrity and ethical values", "sort_order": 1},
{"framework": "soc2:2017", "ref": "CC1.2", "section": "CC1 Control environment", "title": "An oversight body independent of management watches controls", "sort_order": 2},
{"framework": "soc2:2017", "ref": "CC1.3", "section": "CC1 Control environment", "title": "Structures, reporting lines and authorities set", "sort_order": 3},
{"framework": "soc2:2017", "ref": "CC1.4", "section": "CC1 Control environment", "title": "Competent people hired, developed and kept", "sort_order": 4},
{"framework": "soc2:2017", "ref": "CC1.5", "section": "CC1 Control environment", "title": "People held to account for their control duties", "sort_order": 5},
{"framework": "soc2:2017", "ref": "CC2.1", "section": "CC2 Communication and information", "title": "Good quality information used to run controls", "sort_order": 6},
{"framework": "soc2:2017", "ref": "CC2.2", "section": "CC2 Communication and information", "title": "Control duties and information shared inside the company", "sort_order": 7},
{"framework": "soc2:2017", "ref": "CC2.3", "section": "CC2 Communication and information", "title": "Control matters shared with outside parties", "sort_order": 8},
{"framework": "soc2:2017", "ref": "CC3.1", "section": "CC3 Risk assessment", "title": "Objectives clear enough to find the risks to them", "sort_order": 9},
{"framework": "soc2:2017", "ref": "CC3.2", "section": "CC3 Risk assessment", "title": "Risks to objectives found and analysed", "sort_order": 10},
{"framework": "soc2:2017", "ref": "CC3.3", "section": "CC3 Risk assessment", "title": "Fraud risk taken into account", "sort_order": 11},
{"framework": "soc2:2017", "ref": "CC3.4", "section": "CC3 Risk assessment", "title": "Big changes checked for new risks", "sort_order": 12},
{"framework": "soc2:2017", "ref": "CC4.1", "section": "CC4 Monitoring activities", "title": "Controls evaluated on an ongoing or separate basis", "sort_order": 13},
{"framework": "soc2:2017", "ref": "CC4.2", "section": "CC4 Monitoring activities", "title": "Control gaps reported and fixed in time", "sort_order": 14},
{"framework": "soc2:2017", "ref": "CC5.1", "section": "CC5 Control activities", "title": "Control activities chosen to bring risks down", "sort_order": 15},
{"framework": "soc2:2017", "ref": "CC5.2", "section": "CC5 Control activities", "title": "General controls over technology chosen", "sort_order": 16},
{"framework": "soc2:2017", "ref": "CC5.3", "section": "CC5 Control activities", "title": "Controls put in place through policies and procedures", "sort_order": 17},
{"framework": "soc2:2017", "ref": "CC6.1", "section": "CC6 Logical and physical access", "title": "Logical access to protected assets secured", "sort_order": 18},
{"framework": "soc2:2017", "ref": "CC6.2", "section": "CC6 Logical and physical access", "title": "Users registered and approved before they get access", "sort_order": 19},
{"framework": "soc2:2017", "ref": "CC6.3", "section": "CC6 Logical and physical access", "title": "Access given, changed and removed by role", "sort_order": 20},
{"framework": "soc2:2017", "ref": "CC6.4", "section": "CC6 Logical and physical access", "title": "Physical access to facilities and assets limited", "sort_order": 21},
{"framework": "soc2:2017", "ref": "CC6.5", "section": "CC6 Logical and physical access", "title": "Data and devices disposed of safely", "sort_order": 22},
{"framework": "soc2:2017", "ref": "CC6.6", "section": "CC6 Logical and physical access", "title": "Threats from outside the system boundary blocked", "sort_order": 23},
{"framework": "soc2:2017", "ref": "CC6.7", "section": "CC6 Logical and physical access", "title": "Data protected in transit and on removable media", "sort_order": 24},
{"framework": "soc2:2017", "ref": "CC6.8", "section": "CC6 Logical and physical access", "title": "Unwanted or malicious software stopped or found", "sort_order": 25},
{"framework": "soc2:2017", "ref": "CC7.1", "section": "CC7 System operations", "title": "Configuration changes and new weaknesses detected", "sort_order": 26},
{"framework": "soc2:2017", "ref": "CC7.2", "section": "CC7 System operations", "title": "Components watched for signs of attack or failure", "sort_order": 27},
{"framework": "soc2:2017", "ref": "CC7.3", "section": "CC7 System operations", "title": "Security events judged to decide if they are incidents", "sort_order": 28},
{"framework": "soc2:2017", "ref": "CC7.4", "section": "CC7 System operations", "title": "Incidents handled under a response program", "sort_order": 29},
{"framework": "soc2:2017", "ref": "CC7.5", "section": "CC7 System operations", "title": "Recovery from incidents carried out", "sort_order": 30},
{"framework": "soc2:2017", "ref": "CC8.1", "section": "CC8 Change management", "title": "Changes approved, tested and recorded before they go live", "sort_order": 31},
{"framework": "soc2:2017", "ref": "CC9.1", "section": "CC9 Risk mitigation", "title": "Risks of business disruption reduced", "sort_order": 32},
{"framework": "soc2:2017", "ref": "CC9.2", "section": "CC9 Risk mitigation", "title": "Risks from vendors and partners managed", "sort_order": 33},
{"framework": "iso42001:2023", "ref": "4.1", "section": "Clause 4 Context", "title": "Know the context, including the role taken towards AI", "sort_order": 1},
{"framework": "iso42001:2023", "ref": "4.2", "section": "Clause 4 Context", "title": "Know the interested parties and their AI expectations", "sort_order": 2},
{"framework": "iso42001:2023", "ref": "4.3", "section": "Clause 4 Context", "title": "Write down what the AI management system covers", "sort_order": 3},
{"framework": "iso42001:2023", "ref": "4.4", "section": "Clause 4 Context", "title": "Run the AI management system and improve it", "sort_order": 4},
{"framework": "iso42001:2023", "ref": "5.1", "section": "Clause 5 Leadership", "title": "Top management backs the AI management system", "sort_order": 5},
{"framework": "iso42001:2023", "ref": "5.2", "section": "Clause 5 Leadership", "title": "A written AI policy, approved and shared", "sort_order": 6},
{"framework": "iso42001:2023", "ref": "5.3", "section": "Clause 5 Leadership", "title": "AI roles and who decides what are assigned", "sort_order": 7},
{"framework": "iso42001:2023", "ref": "6.1.1", "section": "Clause 6 Planning", "title": "Plan how to handle AI risks and opportunities", "sort_order": 8},
{"framework": "iso42001:2023", "ref": "6.1.2", "section": "Clause 6 Planning", "title": "A repeatable method to find and rate AI risks", "sort_order": 9},
{"framework": "iso42001:2023", "ref": "6.1.3", "section": "Clause 6 Planning", "title": "Pick AI risk treatments and record which controls apply", "sort_order": 10},
{"framework": "iso42001:2023", "ref": "6.1.4", "section": "Clause 6 Planning", "title": "Assess what AI systems do to people and society", "sort_order": 11},
{"framework": "iso42001:2023", "ref": "6.2", "section": "Clause 6 Planning", "title": "Set measurable AI goals and plan how to reach them", "sort_order": 12},
{"framework": "iso42001:2023", "ref": "6.3", "section": "Clause 6 Planning", "title": "Plan changes to the AI management system", "sort_order": 13},
{"framework": "iso42001:2023", "ref": "7.1", "section": "Clause 7 Support", "title": "Give the AI management system what it needs", "sort_order": 14},
{"framework": "iso42001:2023", "ref": "7.2", "section": "Clause 7 Support", "title": "People working on AI have the skills for it", "sort_order": 15},
{"framework": "iso42001:2023", "ref": "7.3", "section": "Clause 7 Support", "title": "Everyone knows the AI policy and their part", "sort_order": 16},
{"framework": "iso42001:2023", "ref": "7.4", "section": "Clause 7 Support", "title": "Decide what to tell whom about AI, and when", "sort_order": 17},
{"framework": "iso42001:2023", "ref": "7.5.1", "section": "Clause 7 Support", "title": "Keep the written records the system relies on", "sort_order": 18},
{"framework": "iso42001:2023", "ref": "7.5.2", "section": "Clause 7 Support", "title": "Write and update those records with review", "sort_order": 19},
{"framework": "iso42001:2023", "ref": "7.5.3", "section": "Clause 7 Support", "title": "Control those records: access, versions, retention", "sort_order": 20},
{"framework": "iso42001:2023", "ref": "8.1", "section": "Clause 8 Operation", "title": "Plan and run AI work as designed", "sort_order": 21},
{"framework": "iso42001:2023", "ref": "8.2", "section": "Clause 8 Operation", "title": "Assess AI risks on a schedule and on change", "sort_order": 22},
{"framework": "iso42001:2023", "ref": "8.3", "section": "Clause 8 Operation", "title": "Carry out the chosen AI risk treatments", "sort_order": 23},
{"framework": "iso42001:2023", "ref": "8.4", "section": "Clause 8 Operation", "title": "Run AI impact assessments on a schedule and on change", "sort_order": 24},
{"framework": "iso42001:2023", "ref": "9.1", "section": "Clause 9 Performance evaluation", "title": "Measure how well the AI management system works", "sort_order": 25},
{"framework": "iso42001:2023", "ref": "9.2.1", "section": "Clause 9 Performance evaluation", "title": "Audit the AI management system on a schedule", "sort_order": 26},
{"framework": "iso42001:2023", "ref": "9.2.2", "section": "Clause 9 Performance evaluation", "title": "Keep an audit plan with scope and reports", "sort_order": 27},
{"framework": "iso42001:2023", "ref": "9.3.1", "section": "Clause 9 Performance evaluation", "title": "Management looks at the system on a schedule", "sort_order": 28},
{"framework": "iso42001:2023", "ref": "9.3.2", "section": "Clause 9 Performance evaluation", "title": "That review covers status, changes and feedback", "sort_order": 29},
{"framework": "iso42001:2023", "ref": "9.3.3", "section": "Clause 9 Performance evaluation", "title": "That review leaves a record of its decisions", "sort_order": 30},
{"framework": "iso42001:2023", "ref": "10.1", "section": "Clause 10 Improvement", "title": "Keep making the AI management system better", "sort_order": 31},
{"framework": "iso42001:2023", "ref": "10.2", "section": "Clause 10 Improvement", "title": "Fix what failed, find why, and stop it coming back", "sort_order": 32},
{"framework": "iso42001:2023", "ref": "A.2.2", "section": "Annex A.2 AI policy", "title": "An AI policy is written down", "sort_order": 33},
{"framework": "iso42001:2023", "ref": "A.2.3", "section": "Annex A.2 AI policy", "title": "The AI policy fits the other company policies", "sort_order": 34},
{"framework": "iso42001:2023", "ref": "A.2.4", "section": "Annex A.2 AI policy", "title": "The AI policy is reviewed on a schedule", "sort_order": 35},
{"framework": "iso42001:2023", "ref": "A.3.2", "section": "Annex A.3 Internal organisation", "title": "AI duties given to named roles", "sort_order": 36},
{"framework": "iso42001:2023", "ref": "A.3.3", "section": "Annex A.3 Internal organisation", "title": "A way for people to raise concerns about AI", "sort_order": 37},
{"framework": "iso42001:2023", "ref": "A.4.2", "section": "Annex A.4 Resources", "title": "The resources each AI system uses are listed", "sort_order": 38},
{"framework": "iso42001:2023", "ref": "A.4.3", "section": "Annex A.4 Resources", "title": "The data each AI system uses is documented", "sort_order": 39},
{"framework": "iso42001:2023", "ref": "A.4.4", "section": "Annex A.4 Resources", "title": "The tools each AI system uses are documented", "sort_order": 40},
{"framework": "iso42001:2023", "ref": "A.4.5", "section": "Annex A.4 Resources", "title": "The compute and systems behind AI are documented", "sort_order": 41},
{"framework": "iso42001:2023", "ref": "A.4.6", "section": "Annex A.4 Resources", "title": "The people and skills behind AI are documented", "sort_order": 42},
{"framework": "iso42001:2023", "ref": "A.5.2", "section": "Annex A.5 Impact assessment", "title": "A process to assess the impact of AI systems", "sort_order": 43},
{"framework": "iso42001:2023", "ref": "A.5.3", "section": "Annex A.5 Impact assessment", "title": "Impact assessments are written down and kept", "sort_order": 44},
{"framework": "iso42001:2023", "ref": "A.5.4", "section": "Annex A.5 Impact assessment", "title": "Impact on people and groups is assessed", "sort_order": 45},
{"framework": "iso42001:2023", "ref": "A.5.5", "section": "Annex A.5 Impact assessment", "title": "Impact on society is assessed", "sort_order": 46},
{"framework": "iso42001:2023", "ref": "A.6.1.2", "section": "Annex A.6 AI life cycle", "title": "Goals for building AI responsibly are set", "sort_order": 47},
{"framework": "iso42001:2023", "ref": "A.6.1.3", "section": "Annex A.6 AI life cycle", "title": "Design and build steps for responsible AI are defined", "sort_order": 48},
{"framework": "iso42001:2023", "ref": "A.6.2.2", "section": "Annex A.6 AI life cycle", "title": "Requirements of each AI system written down", "sort_order": 49},
{"framework": "iso42001:2023", "ref": "A.6.2.3", "section": "Annex A.6 AI life cycle", "title": "How each AI system was designed and built is recorded", "sort_order": 50},
{"framework": "iso42001:2023", "ref": "A.6.2.4", "section": "Annex A.6 AI life cycle", "title": "AI systems are checked and validated before use", "sort_order": 51},
{"framework": "iso42001:2023", "ref": "A.6.2.5", "section": "Annex A.6 AI life cycle", "title": "Putting AI systems live is planned", "sort_order": 52},
{"framework": "iso42001:2023", "ref": "A.6.2.6", "section": "Annex A.6 AI life cycle", "title": "AI systems in use are run and watched", "sort_order": 53},
{"framework": "iso42001:2023", "ref": "A.6.2.7", "section": "Annex A.6 AI life cycle", "title": "Technical documents for AI systems are kept", "sort_order": 54},
{"framework": "iso42001:2023", "ref": "A.6.2.8", "section": "Annex A.6 AI life cycle", "title": "AI systems record logs of their events", "sort_order": 55},
{"framework": "iso42001:2023", "ref": "A.7.2", "section": "Annex A.7 Data for AI", "title": "Data used to build and improve AI is managed", "sort_order": 56},
{"framework": "iso42001:2023", "ref": "A.7.3", "section": "Annex A.7 Data for AI", "title": "Where and how data was obtained is recorded", "sort_order": 57},
{"framework": "iso42001:2023", "ref": "A.7.4", "section": "Annex A.7 Data for AI", "title": "Data quality is defined and checked", "sort_order": 58},
{"framework": "iso42001:2023", "ref": "A.7.5", "section": "Annex A.7 Data for AI", "title": "The origin of data is traceable", "sort_order": 59},
{"framework": "iso42001:2023", "ref": "A.7.6", "section": "Annex A.7 Data for AI", "title": "How data is prepared is documented", "sort_order": 60},
{"framework": "iso42001:2023", "ref": "A.8.2", "section": "Annex A.8 Information for interested parties", "title": "Users get the information they need about the AI system", "sort_order": 61},
{"framework": "iso42001:2023", "ref": "A.8.3", "section": "Annex A.8 Information for interested parties", "title": "Others can report harmful effects of the AI system", "sort_order": 62},
{"framework": "iso42001:2023", "ref": "A.8.4", "section": "Annex A.8 Information for interested parties", "title": "AI incidents are told to those affected", "sort_order": 63},
{"framework": "iso42001:2023", "ref": "A.8.5", "section": "Annex A.8 Information for interested parties", "title": "Duties to inform interested parties are met", "sort_order": 64},
{"framework": "iso42001:2023", "ref": "A.9.2", "section": "Annex A.9 Use of AI systems", "title": "Steps for using AI responsibly are defined", "sort_order": 65},
{"framework": "iso42001:2023", "ref": "A.9.3", "section": "Annex A.9 Use of AI systems", "title": "Goals for responsible AI use are set", "sort_order": 66},
{"framework": "iso42001:2023", "ref": "A.9.4", "section": "Annex A.9 Use of AI systems", "title": "AI systems are used only as intended", "sort_order": 67},
{"framework": "iso42001:2023", "ref": "A.10.2", "section": "Annex A.10 Third parties and customers", "title": "AI duties split clearly with suppliers and partners", "sort_order": 68},
{"framework": "iso42001:2023", "ref": "A.10.3", "section": "Annex A.10 Third parties and customers", "title": "Suppliers of AI parts are chosen and checked", "sort_order": 69},
{"framework": "iso42001:2023", "ref": "A.10.4", "section": "Annex A.10 Third parties and customers", "title": "Customer needs and expectations of AI are considered", "sort_order": 70},
{"framework": "owasp-top10:2021", "ref": "A01", "section": "OWASP Top 10 2021", "title": "Users cannot act outside their permissions", "sort_order": 1},
{"framework": "owasp-top10:2021", "ref": "A02", "section": "OWASP Top 10 2021", "title": "Data protected with sound cryptography", "sort_order": 2},
{"framework": "owasp-top10:2021", "ref": "A03", "section": "OWASP Top 10 2021", "title": "Untrusted input never runs as code or a query", "sort_order": 3},
{"framework": "owasp-top10:2021", "ref": "A04", "section": "OWASP Top 10 2021", "title": "Threats designed out from the start", "sort_order": 4},
{"framework": "owasp-top10:2021", "ref": "A05", "section": "OWASP Top 10 2021", "title": "Hardened, secure configuration everywhere", "sort_order": 5},
{"framework": "owasp-top10:2021", "ref": "A06", "section": "OWASP Top 10 2021", "title": "Components kept current and free of known flaws", "sort_order": 6},
{"framework": "owasp-top10:2021", "ref": "A07", "section": "OWASP Top 10 2021", "title": "Strong identification, sign-in and session handling", "sort_order": 7},
{"framework": "owasp-top10:2021", "ref": "A08", "section": "OWASP Top 10 2021", "title": "Code, builds and data checked for integrity", "sort_order": 8},
{"framework": "owasp-top10:2021", "ref": "A09", "section": "OWASP Top 10 2021", "title": "Security events logged and watched", "sort_order": 9},
{"framework": "owasp-top10:2021", "ref": "A10", "section": "OWASP Top 10 2021", "title": "Server-side calls to attacker-chosen addresses blocked", "sort_order": 10},
{"framework": "owasp-llm:2025", "ref": "LLM01", "section": "OWASP Top 10 for LLM 2025", "title": "Model input cannot take over the instructions", "sort_order": 1},
{"framework": "owasp-llm:2025", "ref": "LLM02", "section": "OWASP Top 10 for LLM 2025", "title": "Models do not reveal sensitive data", "sort_order": 2},
{"framework": "owasp-llm:2025", "ref": "LLM03", "section": "OWASP Top 10 for LLM 2025", "title": "Model and package sources trusted and checked", "sort_order": 3},
{"framework": "owasp-llm:2025", "ref": "LLM04", "section": "OWASP Top 10 for LLM 2025", "title": "Training and grounding data protected from tampering", "sort_order": 4},
{"framework": "owasp-llm:2025", "ref": "LLM05", "section": "OWASP Top 10 for LLM 2025", "title": "Model output treated as untrusted before it is used", "sort_order": 5},
{"framework": "owasp-llm:2025", "ref": "LLM06", "section": "OWASP Top 10 for LLM 2025", "title": "Model actions limited to what the task needs", "sort_order": 6},
{"framework": "owasp-llm:2025", "ref": "LLM07", "section": "OWASP Top 10 for LLM 2025", "title": "System prompts hold no secrets and no access rules", "sort_order": 7},
{"framework": "owasp-llm:2025", "ref": "LLM08", "section": "OWASP Top 10 for LLM 2025", "title": "Embedding stores access-controlled and checked", "sort_order": 8},
{"framework": "owasp-llm:2025", "ref": "LLM09", "section": "OWASP Top 10 for LLM 2025", "title": "Model claims checked against sources", "sort_order": 9},
{"framework": "owasp-llm:2025", "ref": "LLM10", "section": "OWASP Top 10 for LLM 2025", "title": "Model use and spend bounded", "sort_order": 10},
{"framework": "eu-ai-act:2024", "ref": "Art.4", "section": "Regulation (EU) 2024/1689", "title": "Staff who use or run AI have enough AI literacy", "sort_order": 1},
{"framework": "eu-ai-act:2024", "ref": "Art.5", "section": "Regulation (EU) 2024/1689", "title": "No banned AI practice is used", "sort_order": 2},
{"framework": "eu-ai-act:2024", "ref": "Art.6", "section": "Regulation (EU) 2024/1689", "title": "Each AI use checked against the high-risk categories", "sort_order": 3},
{"framework": "eu-ai-act:2024", "ref": "Art.50(1)", "section": "Regulation (EU) 2024/1689", "title": "People are told when they deal with an AI system", "sort_order": 4},
{"framework": "eu-ai-act:2024", "ref": "Art.50(2)", "section": "Regulation (EU) 2024/1689", "title": "AI-made content carries a machine-readable mark", "sort_order": 5},
{"framework": "eu-ai-act:2024", "ref": "Art.50(4)", "section": "Regulation (EU) 2024/1689", "title": "AI-made text published to inform the public is disclosed", "sort_order": 6},
{"framework": "eu-ai-act:2024", "ref": "Art.50(5)", "section": "Regulation (EU) 2024/1689", "title": "Those notices are clear and given at the first contact", "sort_order": 7}
]
$catalogue$::jsonb) AS r (framework text, ref text, section text, title text, sort_order integer)
ON CONFLICT (framework, ref) DO NOTHING;

-- 4. Settings ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$
[
{"key": "cis.compliance.validity_hours.root_daily", "app": "cis", "area": "compliance", "label": "Compliance: hours a daily repository check stays valid", "description": "Platform > Compliance (AA-1170): how many hours a result of the root daily collector (AA-Ecosys workflow compliance-evidence.yml: branch rules, CodeQL, scheduled guards, the SBOM and Trivy gate, the registers kept in the repo) counts after it was collected. Older evidence is stale: its check no longer passes and the Evidenced % of every framework it maps to drops. Applied whenever the page or the daily snapshot computes a score, to evidence already stored too.", "value_type": "int", "unit": "hours", "min_value": 1, "max_value": 2160, "allowed_values": null, "default_value": 72, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How long a result of the daily repository check still counts as proof on the Compliance page.", "raise": "Proof stays valid longer; a collector that stopped is noticed later, because its old passes still count.", "lower": "Proof must be fresher; one or two missed daily runs turn checks stale and the score drops.", "when": "Keep it a little above one day times the runs you accept to miss; set 1 hour only to show the stale path.", "example": "With the default 72, a check collected on Monday at 02:00 stops counting on Thursday at 02:00."}, "vi": {"what": "Một kết quả của lượt kiểm repo hằng ngày còn được tính là bằng chứng trên trang Compliance trong bao lâu.", "raise": "Bằng chứng còn hiệu lực lâu hơn; collector ngừng chạy bị phát hiện muộn hơn vì các kết quả đạt cũ vẫn được tính.", "lower": "Bằng chứng phải mới hơn; lỡ một hai lượt chạy hằng ngày là các check thành cũ và điểm giảm.", "when": "Giữ cao hơn một ngày nhân số lượt chạy chấp nhận bị lỡ một chút; chỉ đặt 1 giờ khi muốn cho thấy đường cũ (stale).", "example": "Với mặc định 72, một check thu lúc 02:00 thứ Hai hết được tính lúc 02:00 thứ Năm."}}},
{"key": "cis.compliance.collector_heartbeat_hours", "app": "cis", "area": "compliance", "label": "Compliance: hours before a silent collector counts as down", "description": "Platform > Compliance (AA-1170): a collector (phase 1: the root daily workflow compliance-evidence.yml) whose newest published run is older than this many hours is shown as silent, and every check it feeds counts as an error instead of keeping its last result. The heartbeat itself is a check that controls can map to.", "value_type": "int", "unit": "hours", "min_value": 1, "max_value": 720, "allowed_values": null, "default_value": 36, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How long the page waits for a new run of a collector before it treats the collector as down.", "raise": "A late or failed run is tolerated longer before the checks of that collector turn to errors.", "lower": "A single late run turns the checks of the collector to errors sooner.", "when": "Keep it a little above the collector's schedule (daily: about a day and a half).", "example": "With the default 36, a daily collector that last published on Monday at 02:00 counts as down on Tuesday at 14:00."}, "vi": {"what": "Trang chờ bao lâu cho lượt chạy mới của một collector trước khi coi collector đó là ngừng.", "raise": "Lượt chạy trễ hoặc lỗi được chấp nhận lâu hơn trước khi các check của collector đó chuyển thành lỗi.", "lower": "Chỉ một lượt chạy trễ là các check của collector đó chuyển thành lỗi sớm hơn.", "when": "Giữ cao hơn lịch chạy của collector một chút (hằng ngày: khoảng một ngày rưỡi).", "example": "Với mặc định 36, collector hằng ngày công bố lần cuối lúc 02:00 thứ Hai bị coi là ngừng lúc 14:00 thứ Ba."}}},
{"key": "cis.compliance.partial_weight", "app": "cis", "area": "compliance", "label": "Compliance: weight of a partial match in the weighted score", "description": "Platform > Compliance (AA-1170): the weighted Evidenced % counts a requirement that is only partly covered (a met control mapped as partial, or a partly met control however it is mapped) as this fraction of a met requirement. The strict % ignores partial coverage. The November 2026 hand assessment used 0.5.", "value_type": "numeric", "unit": "ratio", "min_value": 0, "max_value": 1, "allowed_values": null, "default_value": 0.5, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How much a requirement that is only partly covered adds to the weighted score.", "raise": "Partial coverage counts more; the weighted score rises and moves away from the strict score.", "lower": "Partial coverage counts less; at 0 the weighted score equals the strict score.", "when": "Keep 0.5 to compare with the November 2026 hand assessment; change it only with a written reason.", "example": "With the default 0.5, ten requirements of which four are met and two partly covered score 50% weighted and 40% strict."}, "vi": {"what": "Một yêu cầu chỉ được đáp ứng một phần đóng góp bao nhiêu vào điểm có trọng số.", "raise": "Đáp ứng một phần được tính nhiều hơn; điểm có trọng số tăng và xa dần điểm chặt.", "lower": "Đáp ứng một phần được tính ít hơn; ở mức 0 điểm có trọng số bằng điểm chặt.", "when": "Giữ 0,5 để so được với bản chấm tay tháng 11/2026; chỉ đổi khi có lý do ghi rõ.", "example": "Với mặc định 0,5, mười yêu cầu trong đó bốn đạt và hai đạt một phần cho 50% có trọng số và 40% chặt."}}},
{"key": "cis.compliance.drill_max_age_days", "app": "cis", "area": "compliance", "label": "Compliance: days a passed restore drill counts", "description": "Platform > Compliance (AA-1170): the check last_restore_drill passes while the newest passed drill in the root drill index (docs/ops/drills/README.md) is at most this many days old. Older, the check fails and the backup and continuity controls it feeds drop.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 730, "allowed_values": null, "default_value": 90, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How recent the last passed restore or rollback drill must be for the drill check to pass.", "raise": "Older drills still count; recovery may have changed since the last real test.", "lower": "Drills must be repeated more often to keep the check green.", "when": "Keep it at a quarter while on Dev; shorten it once prod runs.", "example": "With the default 90, a drill passed on 1 September counts until 30 November."}, "vi": {"what": "Lượt diễn tập khôi phục hoặc rollback gần nhất phải mới tới đâu thì check diễn tập mới đạt.", "raise": "Diễn tập cũ hơn vẫn được tính; cách khôi phục có thể đã đổi từ lần thử thật gần nhất.", "lower": "Phải diễn tập thường hơn để giữ check xanh.", "when": "Giữ ở một quý khi còn ở Dev; rút ngắn khi có prod.", "example": "Với mặc định 90, lượt diễn tập đạt ngày 1 tháng 9 được tính tới ngày 30 tháng 11."}}},
{"key": "cis.compliance.access_review_max_age_days", "app": "cis", "area": "compliance", "label": "Compliance: days an access review counts", "description": "Platform > Compliance (AA-1170): the check last_access_review passes while the newest access review listed in the root security index (docs/security/README.md, Access reviews) is at most this many days old. Older, the check fails and the access controls it feeds drop.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 730, "allowed_values": null, "default_value": 100, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How recent the last access review must be for the access review check to pass.", "raise": "An older review still counts; access that should have been removed may stay longer unnoticed.", "lower": "Access reviews must happen more often to keep the check green.", "when": "Keep it a little above a quarter: reviews are quarterly.", "example": "With the default 100, a review dated 17 November counts until 25 February."}, "vi": {"what": "Lần rà soát quyền truy cập gần nhất phải mới tới đâu thì check rà soát quyền mới đạt.", "raise": "Lần rà soát cũ hơn vẫn được tính; quyền đáng lẽ phải thu hồi có thể tồn tại lâu hơn mà không ai thấy.", "lower": "Phải rà soát quyền thường hơn để giữ check xanh.", "when": "Giữ cao hơn một quý một chút: rà soát quyền làm hằng quý.", "example": "Với mặc định 100, lần rà soát ngày 17 tháng 11 được tính tới ngày 25 tháng 2."}}},
{"key": "cis.compliance.docs_overdue_max", "app": "cis", "area": "compliance", "label": "Compliance: docs pages allowed past their review date", "description": "Platform > Compliance (AA-1170): the check docs_review_overdue passes while at most this many root docs pages are past their last_reviewed plus review_every_days (the same rule as the weekly docs freshness report).", "value_type": "int", "unit": "pages", "min_value": 0, "max_value": 1000, "allowed_values": null, "default_value": 0, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How many documentation pages may be past their review date while the documentation check still passes.", "raise": "The check tolerates more stale pages; outdated procedures are less visible.", "lower": "Every page past its date turns the check red.", "when": "Keep 0; raise it only for a short catch-up period, with a reason.", "example": "With the default 0, one page past its review date fails the check."}, "vi": {"what": "Bao nhiêu trang tài liệu được phép quá hạn rà soát mà check tài liệu vẫn đạt.", "raise": "Check chấp nhận nhiều trang cũ hơn; quy trình lỗi thời khó thấy hơn.", "lower": "Mỗi trang quá hạn đều làm check đỏ.", "when": "Giữ 0; chỉ tăng trong một đợt bù việc ngắn, có lý do.", "example": "Với mặc định 0, một trang quá hạn rà soát làm check không đạt."}}},
{"key": "cis.compliance.ci_scan_max_age_days", "app": "cis", "area": "compliance", "label": "Compliance: days an image scan counts", "description": "Platform > Compliance (AA-1170): the check ci_image_scan_sbom passes while the newest CI run of every image repo that reached main (the merge queue) scanned the image, wrote an SBOM and is at most this many days old; the oldest of those scans decides. Older, the check fails and the vulnerability controls it feeds drop: a scan that stopped running is not fresh evidence.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 90, "allowed_values": null, "default_value": 8, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How recent the newest image scan and SBOM of each image repo must be for the image scan check to pass.", "raise": "Older scans still count; vulnerabilities published since the last scan may go unseen longer.", "lower": "Every image repo must merge (and so scan) more often to keep the check green.", "when": "Keep it a little above a week: the weekly release merges scan every image repo at least once a week.", "example": "With the default 8, a repo whose last merge-queue scan ran on 10 November fails the check from 19 November."}, "vi": {"what": "Lần quét image và SBOM mới nhất của mỗi repo có image phải mới tới đâu thì check quét image mới đạt.", "raise": "Lần quét cũ hơn vẫn được tính; lỗ hổng công bố sau lần quét cuối có thể bị bỏ sót lâu hơn.", "lower": "Mỗi repo có image phải merge (tức là quét lại) thường hơn để giữ check xanh.", "when": "Giữ cao hơn một tuần một chút: các lần merge bản phát hành hằng tuần quét mỗi repo ít nhất một lần mỗi tuần.", "example": "Với mặc định 8, repo có lần quét qua merge queue cuối cùng ngày 10 tháng 11 sẽ trượt check từ ngày 19 tháng 11."}}},
{"key": "cis.compliance.reference_scores", "app": "cis", "area": "compliance", "label": "Compliance: assessed reference score per framework", "description": "Platform > Compliance (AA-1170): the one-off assessed score per framework (percent, the hand assessment of 20/11/2026) drawn as a reference line beside the Evidenced %. Display only: it never changes a computed score. Keys are framework ids of the compliance register (iso27001:2022, soc2:2017, iso42001:2023, owasp-top10:2021, owasp-llm:2025); a framework without a key has no reference line.", "value_type": "json", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": {"iso27001:2022": 45.8, "soc2:2017": 44.0, "iso42001:2023": 46.9, "owasp-top10:2021": 64.8, "owasp-llm:2025": 66.7}, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The scores of the last hand assessment, shown as a dotted reference beside the measured score.", "raise": "A higher reference makes the gap to the measured score look larger.", "lower": "A lower reference makes the gap look smaller; it never changes the measured score.", "when": "Update it after a new full assessment, with the assessment folder as the reason.", "example": "With the default, ISO 27001 shows a reference line at 45.8% beside its Evidenced %."}, "vi": {"what": "Điểm của lần chấm tay gần nhất, hiện thành đường tham chiếu chấm chấm cạnh điểm đo được.", "raise": "Tham chiếu cao hơn làm khoảng cách tới điểm đo được trông lớn hơn.", "lower": "Tham chiếu thấp hơn làm khoảng cách trông nhỏ hơn; nó không bao giờ đổi điểm đo được.", "when": "Cập nhật sau một lần chấm đầy đủ mới, ghi thư mục bản chấm làm lý do.", "example": "Với mặc định, ISO 27001 hiện đường tham chiếu 45,8% cạnh Evidenced %."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- 5. Post-check ─────────────────────────────────────────────────────────────────────────────────────────────────────
DO $check$
DECLARE
    bad text;
    n   integer;
BEGIN
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'compliance' AND c.relkind IN ('r', 'p')
       AND (has_table_privilege('aa_app_user', c.oid, 'SELECT, INSERT, UPDATE, DELETE')
            OR NOT has_table_privilege('cis_app', c.oid, 'SELECT')
            OR NOT has_table_privilege('cis_app', c.oid, 'INSERT')
            OR NOT has_table_privilege('cis_app', c.oid, 'UPDATE')
            OR NOT has_table_privilege('cis_app', c.oid, 'DELETE'));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 466: grants are not cis_app DML only on compliance.%', bad;
    END IF;
    SELECT count(*) INTO n FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'compliance' AND c.relkind = 'r'
       AND c.relname IN ('requirement', 'control', 'requirement_mapping', 'evidence', 'score_snapshot');
    IF n <> 5 THEN
        RAISE EXCEPTION 'migration 466: % of the five compliance tables exist', n;
    END IF;
    IF (SELECT count(*) FROM compliance.requirement) < 253 THEN
        RAISE EXCEPTION 'migration 466: the requirement catalogue is not seeded (253 rows expected)';
    END IF;
    IF (SELECT count(*) FROM shared.setting_definition
         WHERE key LIKE 'cis.compliance.%' AND guide IS NOT NULL) < 8 THEN
        RAISE EXCEPTION 'migration 466: the eight cis.compliance.* settings are not all seeded with a guide';
    END IF;
END
$check$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('466', now(), 'AA-1170: schema compliance (requirement catalogue, controls, mapping, evidence, score snapshots) and the cis.compliance.* settings')
ON CONFLICT (version) DO NOTHING;

COMMIT;
