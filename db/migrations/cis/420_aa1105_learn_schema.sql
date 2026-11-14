-- Migration 420: AA-1105 (S280, root ADR 0022, decisions D3 / D7 / D11) — schema learn: the AA Academy learner
-- records, and the learn settings of the platform settings registry.
--
-- Why. AA Academy (root ADR 0022) keeps its courses as files in the root repo (docs/learn/, published as the learn
-- bundle under the docs reader prefix) and its learner records in CIS, in a new schema owned by AA-CIS-App in the CIS
-- key space (decision D3). The learning API (/learn/v1, contract learn.http.v1) reads and writes these tables; the
-- academy pages on the CRM web never read them by SQL. Design ERD: AA-Ecosys docs/architecture/erd/design/learn.md.
--
-- What:
--   1. CREATE SCHEMA learn (owner = the runner, cis_owner on Dev; CREATE ON DATABASE from rl-002, as in CIS 294).
--      USAGE for cis_app only; nothing for PUBLIC or aa_app_user (the agency academy, P7, decides that grant).
--   2. Nine tables (the design ERD):
--        learner            one row per verified identity (iss, sub); kind staff (admin_user_id -> shared.admin_users,
--                           ON DELETE SET NULL; tenant_id NULL) or partner (tenant_id set; P7); display_name snapshot
--                           for the certificate verify view; is_test for the Dev E2E identities; inactive_since starts
--                           the retention clock (D11).
--        enrollment         learner x path (unique).
--        statement          xAPI-shaped learning record; APPEND-ONLY: a trigger refuses every UPDATE and TRUNCATE, and
--                           a DELETE unless the transaction set learn.retention_purge = 'on' (the learn_retention job,
--                           also when it deletes a learner and the cascade reaches its statements).
--        lesson_progress    learner x lesson.
--        quiz_attempt       one sitting, bound to the drawn item ids, the bundle sha and the module versions; at most
--                           one open attempt per learner, scope and target (partial unique index).
--        review_card        learner x quiz item, the ts-fsrs card state checked by the API.
--        lab_run            stays empty until the lab provisioner (P4b, D14 / D15).
--        certificate        one per learner and path; Open Badges 3.0 fields in badge; code_sha256 = SHA-256 of the
--                           128-bit verification code (never the code); revoked_* by an administrator.
--        content_review_item  a stale lesson source for its module owner (research section 6.4); no tenant column.
--      Every table with tenant_id gets the CIS row-level security template of every CIS tenant table since 277 (360,
--      386, 407): ENABLE + FORCE, the X1 parity policies <table>_cis_app_all TO cis_app and <table>_cis_owner_all TO
--      cis_owner (data standards SEC-7: FORCE waited only for the X1 role split, done since X1 S18), and a
--      tenant_isolation policy TO aa_app_user on NULLIF(current_setting('app.tenant_id', true), '')::uuid (the research
--      section 7 rule: agency rows carry tenant_id under the RLS template with FORCE RLS). aa_app_user holds no
--      privilege until P7.
--      cis_app: SELECT, INSERT, UPDATE, DELETE on every table, plus default privileges FOR ROLE cis_owner IN SCHEMA
--      learn (tables, sequences, functions), the shape the isolation probe expects (owners.yaml schemas_from 420).
--      DM-6.1 tags: learner.iss / sub pii:online_id, learner.display_name pii:name, certificate.revoke_reason and
--      content_review_item.note pii:free_text.
--   3. Twelve rows in shared.setting_definition, area learn (seed block below, read by
--      scripts/settings/gen_compiled_defaults.py into shared/settings/compiled_defaults.json in this PR): the pass
--      marks (80), the retake delay (24 h), the items per quiz (10) and per module in the final quiz (2), the
--      certificate validity (12 months) and the paths it applies to (engineer-on-duty, tech-lead), the video link
--      lifetime (300 s), the learner retention (365 days, D11), the review target (0.9) and daily cap (20), and the
--      verify rate limit (30 per minute). Each with its plain label and EN + VI operator guide. Seeded
--      enforced = false: the learning API that reads them ships in the next PR (MIG-4); a later migration marks them
--      enforced.
--   4. A post-check, then register 420.
--
-- Behaviour on apply. None for running code: empty tables, nothing reads them until the learning API is deployed.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a new schema, REVOKE / ALTER DEFAULT
-- PRIVILEGES and a DO post-check are outside the expand set (the tenant tables take the ENABLE + FORCE template
-- above). On Dev: Infra Migration Apply once every job table is idle
-- (root ADR 0017a). Retention rows (DM-7.1): root data standards Part B section 7, merged before the Infra copy (the
-- Infra retention-row check reads the learn tables of the cis dir). Ownership registry: AA-CIS-Infra db/owners.yaml
-- lists learn under cis (merged before the Infra copy: the Copy Guard ownership lint reads it).
--
-- Number. 419 is the highest on main (14/11/2026). If main moves before the merge, renumber to main max + 1 everywhere
-- (git grep '420_' and '420' in this repo, AA-CIS-Infra owners.yaml schemas_from and the probe, and the root docs).
--
-- Locks. New objects only, plus one INSERT of twelve config rows (the definition guard trigger allows the file's
-- role, cis_owner). lock_timeout 5s. Idempotent where it can be (IF NOT EXISTS, ON CONFLICT DO NOTHING); one
-- transaction, self-registering.
--
-- Rollback (a new forward migration, after the learning API is reverted): DROP SCHEMA learn CASCADE and DELETE the
-- twelve cis.learn.* keys (a destructive file, DRY RUN: learner rows are personal data).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- 1. Schema ─────────────────────────────────────────────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS learn;
COMMENT ON SCHEMA learn IS
    'AA Academy learner records (root ADR 0022, AA-1105): learners, enrollments, statements, progress, quiz attempts, '
    'review cards, lab runs, certificates, content review items. Owner AA-CIS-App; cis_app only (aa_app_user from P7).';
REVOKE ALL ON SCHEMA learn FROM PUBLIC;
GRANT USAGE ON SCHEMA learn TO cis_app;

-- 2. Tables ─────────────────────────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS learn.learner (
    learner_id      uuid NOT NULL DEFAULT gen_random_uuid(),
    iss             text NOT NULL,
    sub             text NOT NULL,
    kind            text NOT NULL,
    admin_user_id   uuid REFERENCES shared.admin_users (id) ON DELETE SET NULL,
    tenant_id       uuid,
    display_name    text,
    is_test         boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    last_seen_at    timestamptz NOT NULL DEFAULT now(),
    inactive_since  timestamptz,
    CONSTRAINT learner_pkey PRIMARY KEY (learner_id),
    CONSTRAINT learner_identity_key UNIQUE (iss, sub),
    CONSTRAINT learner_iss_check CHECK (iss LIKE 'https://%' AND char_length(iss) <= 300),
    CONSTRAINT learner_sub_check CHECK (char_length(sub) BETWEEN 1 AND 128),
    CONSTRAINT learner_kind_check CHECK (
        (kind = 'staff' AND tenant_id IS NULL)
        OR (kind = 'partner' AND tenant_id IS NOT NULL AND admin_user_id IS NULL)),
    CONSTRAINT learner_display_name_check CHECK (display_name IS NULL OR char_length(display_name) <= 200)
);
CREATE INDEX IF NOT EXISTS learner_admin_user_idx ON learn.learner (admin_user_id);
CREATE INDEX IF NOT EXISTS learner_inactive_idx ON learn.learner (inactive_since) WHERE inactive_since IS NOT NULL;
COMMENT ON TABLE learn.learner IS
    'AA-1105: one row per verified identity (iss, sub) that opened the academy; every learn row hangs below it.';
COMMENT ON COLUMN learn.learner.iss IS 'pii:online_id — token issuer of the learner (Cognito pool URL).';
COMMENT ON COLUMN learn.learner.sub IS 'pii:online_id — token subject of the learner.';
COMMENT ON COLUMN learn.learner.display_name IS
    'pii:name — the name shown on the learner''s certificate verify view, refreshed on sign-in.';
COMMENT ON COLUMN learn.learner.inactive_since IS
    'Set by learn_retention when the staff account is inactive or gone; the learner is deleted 365 days later '
    '(cis.learn.learner_retention_days, D11); cleared when the account is active again.';

CREATE TABLE IF NOT EXISTS learn.enrollment (
    enrollment_id   uuid NOT NULL DEFAULT gen_random_uuid(),
    learner_id      uuid NOT NULL REFERENCES learn.learner (learner_id) ON DELETE CASCADE,
    tenant_id       uuid,
    path_id         text NOT NULL,
    status          text NOT NULL DEFAULT 'active',
    enrolled_at     timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz,
    CONSTRAINT enrollment_pkey PRIMARY KEY (enrollment_id),
    CONSTRAINT enrollment_learner_path_key UNIQUE (learner_id, path_id),
    CONSTRAINT enrollment_path_check CHECK (path_id ~ '^[a-z][a-z0-9-]{1,40}$'),
    CONSTRAINT enrollment_status_check CHECK (status IN ('active', 'completed', 'withdrawn')),
    CONSTRAINT enrollment_completed_check CHECK ((status = 'completed') = (completed_at IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS learn.statement (
    statement_id    uuid NOT NULL DEFAULT gen_random_uuid(),
    learner_id      uuid NOT NULL REFERENCES learn.learner (learner_id) ON DELETE CASCADE,
    tenant_id       uuid,
    verb            text NOT NULL,
    object_type     text NOT NULL,
    object_id       text NOT NULL,
    module_version  text,
    bundle_sha      text,
    result          jsonb NOT NULL DEFAULT '{}'::jsonb,
    context         jsonb NOT NULL DEFAULT '{}'::jsonb,
    body_sha256     text NOT NULL,
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    stored_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT statement_pkey PRIMARY KEY (statement_id),
    CONSTRAINT statement_verb_check CHECK (verb IN ('enrolled', 'opened', 'check_answered', 'completed', 'attempted',
                                                    'passed', 'failed', 'reviewed', 'certified', 'revoked')),
    CONSTRAINT statement_object_type_check CHECK (object_type IN ('path', 'module', 'lesson', 'quiz', 'item',
                                                                  'certificate')),
    CONSTRAINT statement_object_id_check CHECK (char_length(object_id) BETWEEN 1 AND 80),
    CONSTRAINT statement_body_sha_check CHECK (body_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT statement_result_check CHECK (jsonb_typeof(result) = 'object'),
    CONSTRAINT statement_context_check CHECK (jsonb_typeof(context) = 'object')
);
CREATE INDEX IF NOT EXISTS statement_learner_idx ON learn.statement (learner_id, stored_at);
COMMENT ON TABLE learn.statement IS
    'AA-1105: xAPI-shaped learning record (actor = learner, verb, object, result, context), append-only by trigger.';
COMMENT ON COLUMN learn.statement.body_sha256 IS
    'SHA-256 of the canonical request body: the same statement_id with another body answers 409.';

CREATE TABLE IF NOT EXISTS learn.lesson_progress (
    learner_id      uuid NOT NULL REFERENCES learn.learner (learner_id) ON DELETE CASCADE,
    lesson_id       text NOT NULL,
    tenant_id       uuid,
    module_id       text NOT NULL,
    module_version  text NOT NULL,
    status          text NOT NULL DEFAULT 'opened',
    lang            text NOT NULL DEFAULT 'en',
    opened_at       timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT lesson_progress_pkey PRIMARY KEY (learner_id, lesson_id),
    CONSTRAINT lesson_progress_lesson_check CHECK (lesson_id ~ '^[A-Z][0-9]{1,2}-[0-9]{2}$'),
    CONSTRAINT lesson_progress_module_check CHECK (module_id ~ '^[A-Z][0-9]{1,2}$'),
    CONSTRAINT lesson_progress_status_check CHECK (status IN ('opened', 'completed')),
    CONSTRAINT lesson_progress_completed_check CHECK ((status = 'completed') = (completed_at IS NOT NULL)),
    CONSTRAINT lesson_progress_lang_check CHECK (lang IN ('en', 'vi'))
);

CREATE TABLE IF NOT EXISTS learn.quiz_attempt (
    attempt_id      uuid NOT NULL DEFAULT gen_random_uuid(),
    learner_id      uuid NOT NULL REFERENCES learn.learner (learner_id) ON DELETE CASCADE,
    tenant_id       uuid,
    scope           text NOT NULL,
    target_id       text NOT NULL,
    item_ids        text[] NOT NULL,
    module_versions jsonb NOT NULL,
    bundle_sha      text NOT NULL,
    pass_mark_pct   integer NOT NULL,
    status          text NOT NULL DEFAULT 'open',
    started_at      timestamptz NOT NULL DEFAULT now(),
    submitted_at    timestamptz,
    responses       jsonb,
    score_pct       numeric(5, 2),
    passed          boolean,
    CONSTRAINT quiz_attempt_pkey PRIMARY KEY (attempt_id),
    CONSTRAINT quiz_attempt_scope_check CHECK (scope IN ('module', 'final')),
    CONSTRAINT quiz_attempt_target_check CHECK (
        (scope = 'module' AND target_id ~ '^[A-Z][0-9]{1,2}$')
        OR (scope = 'final' AND target_id ~ '^[a-z][a-z0-9-]{1,40}$')),
    CONSTRAINT quiz_attempt_items_check CHECK (cardinality(item_ids) BETWEEN 1 AND 200),
    CONSTRAINT quiz_attempt_versions_check CHECK (jsonb_typeof(module_versions) = 'object'),
    CONSTRAINT quiz_attempt_pass_mark_check CHECK (pass_mark_pct BETWEEN 0 AND 100),
    CONSTRAINT quiz_attempt_status_check CHECK (status IN ('open', 'submitted', 'expired')),
    CONSTRAINT quiz_attempt_submitted_check CHECK (
        (status = 'submitted') = (submitted_at IS NOT NULL AND score_pct IS NOT NULL AND passed IS NOT NULL
                                  AND responses IS NOT NULL)),
    CONSTRAINT quiz_attempt_score_check CHECK (score_pct IS NULL OR score_pct BETWEEN 0 AND 100)
);
CREATE UNIQUE INDEX IF NOT EXISTS quiz_attempt_one_open_idx
    ON learn.quiz_attempt (learner_id, scope, target_id) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS quiz_attempt_learner_idx ON learn.quiz_attempt (learner_id, scope, target_id, started_at);
COMMENT ON COLUMN learn.quiz_attempt.item_ids IS
    'The items the server drew at start; a submission is graded against this set only, never the browser''s list.';

CREATE TABLE IF NOT EXISTS learn.review_card (
    learner_id      uuid NOT NULL REFERENCES learn.learner (learner_id) ON DELETE CASCADE,
    item_id         text NOT NULL,
    tenant_id       uuid,
    module_id       text NOT NULL,
    card            jsonb NOT NULL,
    due_at          timestamptz NOT NULL,
    last_review_at  timestamptz,
    reps            integer NOT NULL DEFAULT 0,
    lapses          integer NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT review_card_pkey PRIMARY KEY (learner_id, item_id),
    CONSTRAINT review_card_item_check CHECK (item_id ~ '^[A-Z][0-9]{1,2}-Q[0-9]{1,3}$'),
    CONSTRAINT review_card_card_check CHECK (jsonb_typeof(card) = 'object'),
    CONSTRAINT review_card_counts_check CHECK (reps >= 0 AND lapses >= 0)
);
CREATE INDEX IF NOT EXISTS review_card_due_idx ON learn.review_card (learner_id, due_at);

CREATE TABLE IF NOT EXISTS learn.lab_run (
    lab_run_id      uuid NOT NULL DEFAULT gen_random_uuid(),
    learner_id      uuid NOT NULL REFERENCES learn.learner (learner_id) ON DELETE CASCADE,
    tenant_id       uuid,
    module_id       text NOT NULL,
    status          text NOT NULL DEFAULT 'queued',
    started_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz,
    result          jsonb NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT lab_run_pkey PRIMARY KEY (lab_run_id),
    CONSTRAINT lab_run_status_check CHECK (status IN ('queued', 'running', 'passed', 'failed')),
    CONSTRAINT lab_run_result_check CHECK (jsonb_typeof(result) = 'object')
);
COMMENT ON TABLE learn.lab_run IS
    'AA-1105: lab check runs; empty until the lab provisioner (P4b, decisions D14 / D15); the API answers lab_closed.';

CREATE TABLE IF NOT EXISTS learn.certificate (
    certificate_id   uuid NOT NULL DEFAULT gen_random_uuid(),
    learner_id       uuid NOT NULL REFERENCES learn.learner (learner_id) ON DELETE CASCADE,
    tenant_id        uuid,
    path_id          text NOT NULL,
    path_title       text NOT NULL,
    code_sha256      text NOT NULL,
    status           text NOT NULL DEFAULT 'valid',
    issued_at        timestamptz NOT NULL DEFAULT now(),
    expires_at       timestamptz,
    module_versions  jsonb NOT NULL,
    final_attempt_id uuid REFERENCES learn.quiz_attempt (attempt_id) ON DELETE SET NULL,
    badge            jsonb NOT NULL DEFAULT '{}'::jsonb,
    renewal_reason   text,
    revoked_at       timestamptz,
    revoked_by       text,
    revoke_reason    text,
    CONSTRAINT certificate_pkey PRIMARY KEY (certificate_id),
    CONSTRAINT certificate_code_sha256_key UNIQUE (code_sha256),
    CONSTRAINT certificate_learner_path_key UNIQUE (learner_id, path_id),
    CONSTRAINT certificate_code_check CHECK (code_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT certificate_status_check CHECK (status IN ('valid', 'renewal_due', 'revoked')),
    CONSTRAINT certificate_revoked_check CHECK (
        (status = 'revoked') = (revoked_at IS NOT NULL AND revoked_by IS NOT NULL)),
    CONSTRAINT certificate_revoked_by_check CHECK (revoked_by IS NULL OR revoked_by ~ '^admin:[0-9a-f-]{36}$'),
    CONSTRAINT certificate_renewal_check CHECK (
        renewal_reason IS NULL OR renewal_reason IN ('major_version', 'module_added', 'expired')),
    CONSTRAINT certificate_versions_check CHECK (jsonb_typeof(module_versions) = 'object'),
    CONSTRAINT certificate_badge_check CHECK (jsonb_typeof(badge) = 'object'),
    CONSTRAINT certificate_reason_check CHECK (revoke_reason IS NULL OR char_length(revoke_reason) <= 1000)
);
COMMENT ON COLUMN learn.certificate.code_sha256 IS
    'SHA-256 (hex) of the 128-bit verification code; the code itself is shown once to the learner, never stored.';
COMMENT ON COLUMN learn.certificate.revoke_reason IS
    'pii:free_text — why an administrator revoked the certificate (audited).';
COMMENT ON COLUMN learn.certificate.badge IS
    'Open Badges 3.0 fields of the credential (achievement = the path, criteria, issuer), no personal data.';

CREATE TABLE IF NOT EXISTS learn.content_review_item (
    review_item_id  uuid NOT NULL DEFAULT gen_random_uuid(),
    module_id       text NOT NULL,
    lesson_id       text,
    source_ref      text NOT NULL,
    pinned_sha      text,
    current_sha     text,
    bundle_sha      text NOT NULL,
    reason          text NOT NULL,
    status          text NOT NULL DEFAULT 'open',
    opened_at       timestamptz NOT NULL DEFAULT now(),
    resolved_at     timestamptz,
    resolved_by     text,
    note            text,
    CONSTRAINT content_review_item_pkey PRIMARY KEY (review_item_id),
    CONSTRAINT content_review_item_module_check CHECK (module_id ~ '^[A-Z][0-9]{1,2}$'),
    CONSTRAINT content_review_item_reason_check CHECK (
        reason IN ('source_changed', 'source_unavailable', 'review_overdue')),
    CONSTRAINT content_review_item_status_check CHECK (status IN ('open', 'resolved', 'dismissed')),
    CONSTRAINT content_review_item_resolved_check CHECK (
        (status = 'open') = (resolved_at IS NULL) AND (status = 'open') = (resolved_by IS NULL)),
    CONSTRAINT content_review_item_resolved_by_check CHECK (
        resolved_by IS NULL OR resolved_by ~ '^admin:[0-9a-f-]{36}$'),
    CONSTRAINT content_review_item_note_check CHECK (note IS NULL OR char_length(note) <= 2000)
);
CREATE UNIQUE INDEX IF NOT EXISTS content_review_item_open_idx
    ON learn.content_review_item (module_id, coalesce(lesson_id, ''), source_ref, coalesce(current_sha, ''))
    WHERE status = 'open';
COMMENT ON COLUMN learn.content_review_item.note IS
    'pii:free_text — the module owner''s note when resolving or dismissing the item.';

-- Append-only guard of learn.statement ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION learn.statement_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' AND current_setting('learn.retention_purge', true) = 'on' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'learn.statement is append-only (% refused; only the learn_retention purge deletes)', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END
$fn$;
REVOKE ALL ON FUNCTION learn.statement_append_only() FROM PUBLIC;
DROP TRIGGER IF EXISTS statement_append_only_trg ON learn.statement;
CREATE TRIGGER statement_append_only_trg BEFORE UPDATE OR DELETE ON learn.statement
    FOR EACH ROW EXECUTE FUNCTION learn.statement_append_only();
DROP TRIGGER IF EXISTS statement_no_truncate_trg ON learn.statement;
CREATE TRIGGER statement_no_truncate_trg BEFORE TRUNCATE ON learn.statement
    FOR EACH STATEMENT EXECUTE FUNCTION learn.statement_append_only();

-- Row-level security: the CIS template on every table with a tenant_id (ENABLE + FORCE, X1 parity as CIS 360 / 407) 
ALTER TABLE learn.learner ENABLE ROW LEVEL SECURITY;
ALTER TABLE learn.learner FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS learner_cis_app_all ON learn.learner;
CREATE POLICY learner_cis_app_all ON learn.learner AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS learner_cis_owner_all ON learn.learner;
CREATE POLICY learner_cis_owner_all ON learn.learner AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON learn.learner;
CREATE POLICY tenant_isolation ON learn.learner AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE learn.enrollment ENABLE ROW LEVEL SECURITY;
ALTER TABLE learn.enrollment FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS enrollment_cis_app_all ON learn.enrollment;
CREATE POLICY enrollment_cis_app_all ON learn.enrollment AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS enrollment_cis_owner_all ON learn.enrollment;
CREATE POLICY enrollment_cis_owner_all ON learn.enrollment AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON learn.enrollment;
CREATE POLICY tenant_isolation ON learn.enrollment AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE learn.statement ENABLE ROW LEVEL SECURITY;
ALTER TABLE learn.statement FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS statement_cis_app_all ON learn.statement;
CREATE POLICY statement_cis_app_all ON learn.statement AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS statement_cis_owner_all ON learn.statement;
CREATE POLICY statement_cis_owner_all ON learn.statement AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON learn.statement;
CREATE POLICY tenant_isolation ON learn.statement AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE learn.lesson_progress ENABLE ROW LEVEL SECURITY;
ALTER TABLE learn.lesson_progress FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lesson_progress_cis_app_all ON learn.lesson_progress;
CREATE POLICY lesson_progress_cis_app_all ON learn.lesson_progress AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS lesson_progress_cis_owner_all ON learn.lesson_progress;
CREATE POLICY lesson_progress_cis_owner_all ON learn.lesson_progress AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON learn.lesson_progress;
CREATE POLICY tenant_isolation ON learn.lesson_progress AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE learn.quiz_attempt ENABLE ROW LEVEL SECURITY;
ALTER TABLE learn.quiz_attempt FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS quiz_attempt_cis_app_all ON learn.quiz_attempt;
CREATE POLICY quiz_attempt_cis_app_all ON learn.quiz_attempt AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS quiz_attempt_cis_owner_all ON learn.quiz_attempt;
CREATE POLICY quiz_attempt_cis_owner_all ON learn.quiz_attempt AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON learn.quiz_attempt;
CREATE POLICY tenant_isolation ON learn.quiz_attempt AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE learn.review_card ENABLE ROW LEVEL SECURITY;
ALTER TABLE learn.review_card FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS review_card_cis_app_all ON learn.review_card;
CREATE POLICY review_card_cis_app_all ON learn.review_card AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS review_card_cis_owner_all ON learn.review_card;
CREATE POLICY review_card_cis_owner_all ON learn.review_card AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON learn.review_card;
CREATE POLICY tenant_isolation ON learn.review_card AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE learn.lab_run ENABLE ROW LEVEL SECURITY;
ALTER TABLE learn.lab_run FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lab_run_cis_app_all ON learn.lab_run;
CREATE POLICY lab_run_cis_app_all ON learn.lab_run AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS lab_run_cis_owner_all ON learn.lab_run;
CREATE POLICY lab_run_cis_owner_all ON learn.lab_run AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON learn.lab_run;
CREATE POLICY tenant_isolation ON learn.lab_run AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE learn.certificate ENABLE ROW LEVEL SECURITY;
ALTER TABLE learn.certificate FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS certificate_cis_app_all ON learn.certificate;
CREATE POLICY certificate_cis_app_all ON learn.certificate AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS certificate_cis_owner_all ON learn.certificate;
CREATE POLICY certificate_cis_owner_all ON learn.certificate AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON learn.certificate;
CREATE POLICY tenant_isolation ON learn.certificate AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

-- Grants: cis_app only; default privileges for what cis_owner creates in learn later ─────────────────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA learn TO cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE cis_owner IN SCHEMA learn GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE cis_owner IN SCHEMA learn GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE cis_owner IN SCHEMA learn GRANT EXECUTE ON FUNCTIONS TO cis_app;

-- 3. Settings ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$[
{"key": "cis.learn.quiz_pass_mark_pct", "app": "cis", "area": "learn", "label": "Academy: module quiz pass mark", "description": "Decision D7 of the AA Academy research: the lowest score, in percent of the drawn items, that passes a module quiz. A module is complete when its required lessons are done and its quiz is passed at or above this mark. Read by the AA Academy learning API (/learn/v1) from the release that ships it; marked enforced by a later migration.", "value_type": "pct", "unit": "%", "min_value": 50, "max_value": 100, "allowed_values": null, "default_value": 80, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "The score a learner needs on a module quiz to pass it. A passed quiz (with the module's lessons read) completes the module.", "raise": "Passing proves more, but more learners need a second try, which waits for the retake delay.", "lower": "More learners pass at the first try, but a pass says less about what they remember.", "when": "Raise it for modules where a mistake is costly (deploys, money); lower it only if many learners who do the work well still fail.", "example": "With the default of 80, a learner who answers 8 of 10 questions correctly passes."}, "vi": {"what": "Điểm người học cần đạt ở bài kiểm tra của một module để qua. Qua bài kiểm tra (và đã đọc các bài học của module) là hoàn thành module.", "raise": "Qua bài kiểm tra chứng minh được nhiều hơn, nhưng nhiều người phải làm lại, và phải chờ hết thời gian chờ làm lại.", "lower": "Nhiều người qua ngay lần đầu hơn, nhưng việc qua bài nói ít hơn về điều họ thật sự nhớ.", "when": "Tăng cho các module mà sai sót gây hậu quả lớn (triển khai, tiền); chỉ giảm khi nhiều người làm việc tốt vẫn trượt.", "example": "Với mặc định 80, người học trả lời đúng 8 trên 10 câu là qua."}}},
{"key": "cis.learn.final_quiz_pass_mark_pct", "app": "cis", "area": "learn", "label": "Academy: final path quiz pass mark", "description": "Decision D7 / research section 4.3: the lowest score, in percent, that passes the final mixed quiz of a learning path (drawn from every required module). Passing it, with every required module complete, issues the path certificate. Read by the AA Academy learning API (/learn/v1) from the release that ships it; marked enforced by a later migration.", "value_type": "pct", "unit": "%", "min_value": 50, "max_value": 100, "allowed_values": null, "default_value": 80, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "The score a learner needs on the final quiz of a learning path. Passing it, after every required module, earns the path certificate.", "raise": "A certificate proves more, but more learners need another try before they get it.", "lower": "Certificates come sooner, but they say less about what the holder remembers across the path.", "when": "Raise it for paths that lead to on-duty work; lower it only when the final quiz itself is shown to be too hard.", "example": "With the default of 80, 8 correct answers out of 10 earn the certificate."}, "vi": {"what": "Điểm người học cần đạt ở bài kiểm tra cuối của một lộ trình. Qua bài này, sau khi xong mọi module bắt buộc, là nhận chứng chỉ của lộ trình.", "raise": "Chứng chỉ có giá trị hơn, nhưng nhiều người phải làm lại trước khi nhận được.", "lower": "Chứng chỉ đến sớm hơn, nhưng nói ít hơn về điều người giữ nó nhớ được trên cả lộ trình.", "when": "Tăng cho các lộ trình dẫn tới việc trực vận hành; chỉ giảm khi chính bài kiểm tra cuối được chứng minh là quá khó.", "example": "Với mặc định 80, đúng 8 trên 10 câu là nhận chứng chỉ."}}},
{"key": "cis.learn.quiz_retake_delay_hours", "app": "cis", "area": "learn", "label": "Academy: wait before a quiz retake", "description": "Decision D7: how many hours a learner waits after a failed quiz (module or final) before the next attempt opens. The wait makes a retake a second recall, not a guess at the answers just shown. Read by the AA Academy learning API (/learn/v1) from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "hours", "min_value": 0, "max_value": 168, "allowed_values": null, "default_value": 24, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How long a learner waits after failing a quiz before trying again. The explanations are shown after each try, so the wait keeps the next try a real test of memory.", "raise": "Retakes test memory better, but a learner who just misread a question waits longer.", "lower": "Learners can try again sooner, but a quick retake can pass on the answers they just saw.", "when": "Lower it during an onboarding week when people must finish fast; keep it at a day otherwise.", "example": "With the default of 24, a learner who fails at 10:00 can try again at 10:00 the next day."}, "vi": {"what": "Thời gian người học phải chờ sau khi trượt một bài kiểm tra trước khi làm lại. Phần giải thích hiện sau mỗi lần làm, nên thời gian chờ giữ cho lần sau vẫn là bài kiểm tra trí nhớ thật.", "raise": "Lần làm lại kiểm tra trí nhớ tốt hơn, nhưng người chỉ đọc nhầm một câu phải chờ lâu hơn.", "lower": "Người học làm lại sớm hơn, nhưng làm lại ngay có thể qua nhờ đáp án vừa thấy.", "when": "Giảm trong tuần nhập môn khi mọi người cần xong nhanh; ngoài ra giữ ở một ngày.", "example": "Với mặc định 24, người trượt lúc 10:00 có thể làm lại lúc 10:00 hôm sau."}}},
{"key": "cis.learn.quiz_items_per_attempt", "app": "cis", "area": "learn", "label": "Academy: questions per module quiz", "description": "Research section 4.2: the most questions the server draws for one module quiz attempt, from the module's items that are not suspended. A module with fewer items uses all of them. Read by the AA Academy learning API (/learn/v1) from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "items", "min_value": 3, "max_value": 20, "allowed_values": null, "default_value": 10, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How many questions one module quiz shows at most. The server picks them from the module's questions that are not on hold for review.", "raise": "Each quiz covers more of the module, but takes longer.", "lower": "Quizzes are shorter, but one question weighs more in the score.", "when": "Raise it when modules get bigger question banks; lower it if learners drop out of long quizzes.", "example": "With the default of 10, a module with 6 questions shows all 6 and one with 14 shows 10 of them."}, "vi": {"what": "Số câu hỏi tối đa một bài kiểm tra module hiển thị. Máy chủ chọn từ các câu của module không bị tạm ngưng chờ rà soát.", "raise": "Mỗi bài kiểm tra phủ được nhiều nội dung hơn, nhưng lâu hơn.", "lower": "Bài kiểm tra ngắn hơn, nhưng mỗi câu chiếm phần lớn hơn trong điểm.", "when": "Tăng khi các module có ngân hàng câu hỏi lớn hơn; giảm nếu người học bỏ dở bài dài.", "example": "Với mặc định 10, module có 6 câu hiện cả 6, module có 14 câu hiện 10 câu."}}},
{"key": "cis.learn.final_quiz_items_per_module", "app": "cis", "area": "learn", "label": "Academy: final quiz questions per module", "description": "Research section 4.3: how many questions the final mixed quiz of a path draws from each required module (fewer when a module has fewer items that are not suspended). Read by the AA Academy learning API (/learn/v1) from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "items", "min_value": 1, "max_value": 10, "allowed_values": null, "default_value": 2, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How many questions the final quiz of a path takes from each required module.", "raise": "The final quiz checks each module more closely, but gets long on paths with many modules.", "lower": "The final quiz is short, but checks each module only lightly.", "when": "Raise it for short paths; lower it for long paths so the final quiz stays under about 30 questions.", "example": "With the default of 2, a path of 6 required modules has a final quiz of 12 questions."}, "vi": {"what": "Số câu hỏi bài kiểm tra cuối của một lộ trình lấy từ mỗi module bắt buộc.", "raise": "Bài kiểm tra cuối kiểm từng module kỹ hơn, nhưng dài ra với lộ trình nhiều module.", "lower": "Bài kiểm tra cuối ngắn, nhưng chỉ kiểm sơ qua từng module.", "when": "Tăng cho lộ trình ngắn; giảm cho lộ trình dài để bài cuối dưới khoảng 30 câu.", "example": "Với mặc định 2, lộ trình 6 module bắt buộc có bài kiểm tra cuối 12 câu."}}},
{"key": "cis.learn.recert_months", "app": "cis", "area": "learn", "label": "Academy: certificate validity", "description": "Decision D7: how many months a certificate of a path listed in cis.learn.recert_paths stays valid before it expires and the holder certifies again. Certificates of other paths do not expire (they still need renewal when a required module gets a major version). Read by the AA Academy learning API (/learn/v1) from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "months", "min_value": 1, "max_value": 60, "allowed_values": null, "default_value": 12, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How long a certificate stays valid for the paths that must be renewed (the on-duty and tech-lead paths by default).", "raise": "People certify less often, but knowledge of changed rules may be older.", "lower": "Knowledge stays fresher, but people spend more time certifying again.", "when": "Lower it when the on-duty rules change often; raise it when they have been stable for a long time.", "example": "With the default of 12, a certificate issued on 1 March expires on 1 March the next year."}, "vi": {"what": "Thời hạn hiệu lực của chứng chỉ với các lộ trình phải gia hạn (mặc định là lộ trình trực vận hành và tech lead).", "raise": "Mọi người ít phải thi lại hơn, nhưng hiểu biết về các quy tắc đã đổi có thể cũ hơn.", "lower": "Kiến thức luôn mới hơn, nhưng mọi người tốn thời gian thi lại nhiều hơn.", "when": "Giảm khi quy tắc trực vận hành đổi thường xuyên; tăng khi chúng đã ổn định lâu.", "example": "Với mặc định 12, chứng chỉ cấp ngày 1 tháng 3 hết hạn ngày 1 tháng 3 năm sau."}}},
{"key": "cis.learn.recert_paths", "app": "cis", "area": "learn", "label": "Academy: paths whose certificates expire", "description": "Decision D7: the learning path ids whose certificates expire after cis.learn.recert_months. Every other path certificate stays valid until a required module gets a major version or a new required module is added. Read by the AA Academy learning API (/learn/v1) from the release that ships it; marked enforced by a later migration.", "value_type": "list", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": ["engineer-on-duty", "tech-lead"], "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "The learning paths whose certificates expire after the validity period and must be earned again.", "raise": "Adding a path makes its holders certify again on a schedule, keeping them current at a time cost.", "lower": "Removing a path lets its certificates stay valid until the course itself changes in a major way.", "when": "Add a path when its work carries risk on production; remove one only when its content no longer changes.", "example": "With the default, engineer-on-duty and tech-lead certificates expire; a Fundamentals certificate does not."}, "vi": {"what": "Các lộ trình mà chứng chỉ hết hạn sau thời hạn hiệu lực và phải thi lại.", "raise": "Thêm một lộ trình làm người giữ chứng chỉ phải thi lại theo lịch, giữ kiến thức mới nhưng tốn thời gian.", "lower": "Bỏ một lộ trình làm chứng chỉ của nó còn hiệu lực cho tới khi chính khoá học thay đổi lớn.", "when": "Thêm khi công việc của lộ trình có rủi ro trên môi trường thật; chỉ bỏ khi nội dung không còn thay đổi.", "example": "Với mặc định, chứng chỉ engineer-on-duty và tech-lead hết hạn; chứng chỉ Fundamentals thì không."}}},
{"key": "cis.learn.video_url_ttl_seconds", "app": "cis", "area": "learn", "label": "Academy: lesson video link lifetime", "description": "Decision D8: how long the presigned S3 link to a lesson video (and its captions) works after the learning API issues it. The browser starts the video within that time; a seek keeps working on the open stream, a page reload asks for a new link. Read by the AA Academy learning API (/learn/v1) from the release that ships it; marked enforced by a later migration.", "value_type": "duration_s", "unit": "seconds", "min_value": 60, "max_value": 3600, "allowed_values": null, "default_value": 300, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How long a link to a lesson video keeps working once the academy page asked for it.", "raise": "Slow connections and long pauses before playing work better, but a copied link works for longer.", "lower": "A copied link stops working sooner, but a learner who waits long before pressing play needs to reload.", "when": "Raise it if learners report videos that stop loading; keep it short otherwise.", "example": "With the default of 300, a link asked for at 10:00 stops working at 10:05."}, "vi": {"what": "Thời gian một đường dẫn tới video bài học còn dùng được sau khi trang academy xin nó.", "raise": "Mạng chậm và tạm dừng lâu trước khi phát chạy tốt hơn, nhưng một đường dẫn bị chép ra cũng dùng được lâu hơn.", "lower": "Đường dẫn bị chép ra hết hiệu lực sớm hơn, nhưng người chờ lâu trước khi bấm phát phải tải lại trang.", "when": "Tăng nếu người học báo video ngừng tải; ngoài ra giữ ngắn.", "example": "Với mặc định 300, đường dẫn xin lúc 10:00 hết hiệu lực lúc 10:05."}}},
{"key": "cis.learn.learner_retention_days", "app": "cis", "area": "learn", "label": "Academy: keep learning records after an account ends", "description": "Decision D11 (data standards DM-7.1 learn rows): learning records are kept while the account is active, and deleted this many days after the staff account was deactivated or removed, by the learn_retention job (its first run is a DRY RUN). A change of this window is a DM-7.5 amendment. Read by the AA Academy learning API (/learn/v1) from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "days", "min_value": 30, "max_value": 1825, "allowed_values": null, "default_value": 365, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": true, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How long the learning records of a person (progress, quiz results, review cards, certificates) are kept after their account is closed.", "raise": "Records and certificates of people who left stay longer, which keeps history but holds personal data longer.", "lower": "Personal data goes sooner, but a person who comes back starts over and their certificates stop verifying sooner.", "when": "Change it only with the data protection owner, and record the reason; the default follows the approved privacy decision.", "example": "With the default of 365, the records of someone whose account closed on 1 January are deleted the next January."}, "vi": {"what": "Thời gian giữ hồ sơ học tập của một người (tiến độ, kết quả kiểm tra, thẻ ôn tập, chứng chỉ) sau khi tài khoản của họ đóng.", "raise": "Hồ sơ và chứng chỉ của người đã nghỉ được giữ lâu hơn, giữ được lịch sử nhưng giữ dữ liệu cá nhân lâu hơn.", "lower": "Dữ liệu cá nhân bị xoá sớm hơn, nhưng người quay lại phải học lại từ đầu và chứng chỉ của họ ngừng xác minh sớm hơn.", "when": "Chỉ đổi khi đã bàn với người phụ trách bảo vệ dữ liệu và ghi lý do; mặc định theo quyết định quyền riêng tư đã duyệt.", "example": "Với mặc định 365, hồ sơ của người có tài khoản đóng ngày 1 tháng 1 bị xoá vào tháng 1 năm sau."}}},
{"key": "cis.learn.review_target_retention", "app": "cis", "area": "learn", "label": "Academy: review recall target", "description": "Research section 5.4 (spaced review with FSRS, ts-fsrs in the browser): the share of review cards a learner should still recall when a card comes due. The browser schedules with it; the API returns it with the due cards. Read by the AA Academy learning API (/learn/v1) from the release that ships it; marked enforced by a later migration.", "value_type": "numeric", "unit": "ratio", "min_value": 0.7, "max_value": 0.97, "allowed_values": null, "default_value": 0.9, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How sure the review schedule wants to be that a learner still remembers a missed question when it comes back.", "raise": "Questions come back sooner and more often: better memory, more review time.", "lower": "Questions come back later and less often: less review time, more forgetting.", "when": "Lower it if learners say the review queue takes too long; raise it for paths where recall must be near perfect.", "example": "With the default of 0.9, a question is shown again when there is about a 90% chance it is still remembered."}, "vi": {"what": "Mức chắc chắn mà lịch ôn tập muốn có rằng người học vẫn nhớ một câu từng trả lời sai khi nó quay lại.", "raise": "Câu hỏi quay lại sớm và thường hơn: nhớ tốt hơn, tốn thời gian ôn hơn.", "lower": "Câu hỏi quay lại muộn và ít hơn: ít thời gian ôn hơn, quên nhiều hơn.", "when": "Giảm nếu người học thấy hàng ôn tập quá lâu; tăng cho lộ trình cần nhớ gần như tuyệt đối.", "example": "Với mặc định 0,9, một câu hiện lại khi còn khoảng 90% khả năng người học vẫn nhớ."}}},
{"key": "cis.learn.review_max_cards_per_day", "app": "cis", "area": "learn", "label": "Academy: review cards per day", "description": "Research section 4.3: the most spaced-review cards the due list returns to one learner per day; the rest wait for the next day. Read by the AA Academy learning API (/learn/v1) from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "cards", "min_value": 5, "max_value": 200, "allowed_values": null, "default_value": 20, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How many review questions one learner gets at most in a day.", "raise": "Learners clear their backlog faster, but a long daily queue can feel like a chore.", "lower": "Each day is short, but missed questions pile up and come back late.", "when": "Raise it after a large module change that suspended many questions; lower it if learners skip their reviews.", "example": "With the default of 20, a learner with 35 due cards sees 20 today and 15 tomorrow."}, "vi": {"what": "Số câu ôn tập tối đa một người học nhận trong một ngày.", "raise": "Người học xử lý hết phần tồn nhanh hơn, nhưng hàng ôn dài mỗi ngày có thể thành gánh nặng.", "lower": "Mỗi ngày ngắn, nhưng các câu sai dồn lại và quay lại muộn.", "when": "Tăng sau một thay đổi module lớn làm tạm ngưng nhiều câu; giảm nếu người học bỏ qua phần ôn.", "example": "Với mặc định 20, người có 35 thẻ đến hạn thấy 20 thẻ hôm nay và 15 thẻ ngày mai."}}},
{"key": "cis.learn.verify_requests_per_minute", "app": "cis", "area": "learn", "label": "Academy: certificate checks per minute", "description": "ADR 0022 decision 6 (accepted, S280): how many public certificate verify requests one client address may make per minute on /learn/public/v1/certificates/{code}; more answer 429. Slows down guessing codes (128-bit, stored as SHA-256). Read by the AA Academy learning API (/learn/v1) from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "requests", "min_value": 5, "max_value": 600, "allowed_values": null, "default_value": 30, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How many times per minute one visitor may check certificates on the public verify page.", "raise": "Partners who check many certificates at once are not slowed down, but guessing codes gets a little easier.", "lower": "Guessing codes gets harder, but a visitor checking many certificates quickly is told to wait.", "when": "Raise it if a partner checks a batch of certificates and is refused; lower it if the logs show code guessing.", "example": "With the default of 30, the 31st check within one minute from the same address waits until the minute ends."}, "vi": {"what": "Số lần mỗi phút một người truy cập được kiểm chứng chỉ trên trang xác minh công khai.", "raise": "Đối tác kiểm nhiều chứng chỉ cùng lúc không bị chậm, nhưng việc đoán mã dễ hơn một chút.", "lower": "Đoán mã khó hơn, nhưng người kiểm nhiều chứng chỉ nhanh sẽ được báo chờ.", "when": "Tăng nếu một đối tác kiểm cả loạt chứng chỉ và bị từ chối; giảm nếu nhật ký cho thấy có người đoán mã.", "example": "Với mặc định 30, lần kiểm thứ 31 trong một phút từ cùng một địa chỉ phải chờ hết phút đó."}}}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- 4. Post-check ──────────────────────────────────────────────────────────────────────────────────────────────────────
DO $check$
DECLARE
    bad text;
BEGIN
    SELECT string_agg(t, ', ' ORDER BY t) INTO bad
      FROM unnest(ARRAY['learner', 'enrollment', 'statement', 'lesson_progress', 'quiz_attempt', 'review_card',
                        'lab_run', 'certificate']) AS t
     WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                        WHERE n.nspname = 'learn' AND c.relname = t AND c.relrowsecurity
                          AND c.relforcerowsecurity)
        OR (SELECT count(*) FROM pg_catalog.pg_policies p
             WHERE p.schemaname = 'learn' AND p.tablename = t
               AND p.policyname IN (t || '_cis_app_all', t || '_cis_owner_all', 'tenant_isolation')) <> 3;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 420: RLS (ENABLE + FORCE) or its three policies missing on learn.%', bad;
    END IF;
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'learn' AND c.relkind IN ('r', 'p')
       AND (has_table_privilege('aa_app_user', c.oid, 'SELECT, INSERT, UPDATE, DELETE')
            OR NOT has_table_privilege('cis_app', c.oid, 'SELECT')
            OR NOT has_table_privilege('cis_app', c.oid, 'INSERT')
            OR NOT has_table_privilege('cis_app', c.oid, 'UPDATE')
            OR NOT has_table_privilege('cis_app', c.oid, 'DELETE'));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 420: grants are not cis_app DML only on learn.%', bad;
    END IF;
    IF (SELECT count(*) FROM shared.setting_definition
         WHERE key LIKE 'cis.learn.%' AND guide IS NOT NULL) < 12 THEN
        RAISE EXCEPTION 'migration 420: the twelve cis.learn.* settings are not all seeded with a guide';
    END IF;
END
$check$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('420', now(), 'AA-1105: schema learn (AA Academy learner records) and the cis.learn.* settings')
ON CONFLICT (version) DO NOTHING;

COMMIT;
