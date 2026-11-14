-- Migration 421: AA-1105 (S281, root ADR 0022 decision 9) — every learn child row carries its learner's tenant, and
-- learn.lab_run gets its learner index (two follow-ups of the S280 review of CIS 420).
--
-- Why.
--   1. CIS 420 gives every learner-data table a tenant_id under the row-level security template (tenant_isolation TO
--      aa_app_user), but nothing ties a child row's tenant_id to the tenant of the learner it hangs below: a child row
--      of an agency learner could carry another agency's tenant (or none), and the tenant policy would then show it to
--      the wrong agency, or hide it from the right one. That must hold before the agency academy (P7) grants anything
--      to aa_app_user.
--      A composite FK (learner_id, tenant_id) -> learner (learner_id, tenant_id) cannot say it: staff rows carry a NULL
--      tenant, and a composite FK skips its check whenever one column is NULL (MATCH SIMPLE) or refuses the staff row
--      outright (MATCH FULL, learner_id is never NULL). So a trigger checks it.
--   2. learn.lab_run has no index on learner_id: the learner cascade (learn_retention) and the lab state read of the
--      learning API scan the table.
--
-- What:
--   1. learn.child_tenant_matches_learner(): BEFORE INSERT OR UPDATE OF learner_id, tenant_id on the seven child
--      tables (enrollment, statement, lesson_progress, quiz_attempt, review_card, lab_run, certificate). The row's
--      tenant_id must be the learner's tenant_id (IS NOT DISTINCT FROM: NULL for a staff learner); else
--      check_violation. A learner the caller cannot see (no row, or hidden by the caller's row-level security, as for
--      aa_app_user of another tenant from P7) is refused with foreign_key_violation. SECURITY INVOKER on purpose: the
--      lookup runs under the caller's own policies, so a learner of another tenant is never found.
--      learn.statement keeps its append-only trigger (420): an UPDATE is refused there before this one matters.
--   2. learn.learner_tenant_fixed(): BEFORE UPDATE OF tenant_id on learn.learner refuses any change of a learner's
--      tenant (the children would drift from it); a new tenant means a new learner row.
--   3. Index lab_run_learner_idx ON learn.lab_run (learner_id, module_id, started_at): the cascade and the API's
--      "latest run of this module" read. The table is empty (the lab provisioner is P4b), so a plain CREATE INDEX.
--   4. A post-check (no existing child row disagrees with its learner, every trigger and the index exist), then
--      register 421.
--
-- Behaviour on apply. None for running code: on Dev only staff learners exist (tenant NULL everywhere) and the
-- learning API that writes these tables writes the learner's own tenant (NULL for staff).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): triggers on existing tables, a function and an
-- index on an existing table. MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply once every job table
-- is idle (root ADR 0017a). DM-7.1: no new table.
--
-- Number. 420 is the highest on main (15/11/2026). If main moves before the merge, renumber to main max + 1 everywhere
-- (git grep '421_' and '421' in this repo).
--
-- Locks. CREATE TRIGGER takes SHARE ROW EXCLUSIVE on each table and CREATE INDEX a SHARE lock on lab_run: tiny tables,
-- no long scan. lock_timeout 5s. Idempotent (CREATE OR REPLACE, DROP TRIGGER IF EXISTS, IF NOT EXISTS), one
-- transaction, self-registering.
--
-- Rollback (a new forward migration): DROP the eight triggers, the two functions and the index; nothing else depends
-- on them.

BEGIN;
SET LOCAL lock_timeout = '5s';

-- 1. A child row carries its learner's tenant ───────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION learn.child_tenant_matches_learner() RETURNS trigger
    LANGUAGE plpgsql AS $fn$
DECLARE
    learner_tenant uuid;
BEGIN
    SELECT l.tenant_id INTO learner_tenant FROM learn.learner l WHERE l.learner_id = NEW.learner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'learn.%: learner % not found', TG_TABLE_NAME, NEW.learner_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF NEW.tenant_id IS DISTINCT FROM learner_tenant THEN
        RAISE EXCEPTION 'learn.%: tenant_id must be the tenant of its learner', TG_TABLE_NAME
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION learn.child_tenant_matches_learner() FROM PUBLIC;
COMMENT ON FUNCTION learn.child_tenant_matches_learner() IS
    'AA-1105 (CIS 421): a learn child row''s tenant_id equals its learner''s tenant_id (NULL for staff); runs under '
    'the caller''s row-level security, so a learner of another tenant is never found.';

DROP TRIGGER IF EXISTS enrollment_tenant_trg ON learn.enrollment;
CREATE TRIGGER enrollment_tenant_trg BEFORE INSERT OR UPDATE OF learner_id, tenant_id ON learn.enrollment
    FOR EACH ROW EXECUTE FUNCTION learn.child_tenant_matches_learner();
DROP TRIGGER IF EXISTS statement_tenant_trg ON learn.statement;
CREATE TRIGGER statement_tenant_trg BEFORE INSERT OR UPDATE OF learner_id, tenant_id ON learn.statement
    FOR EACH ROW EXECUTE FUNCTION learn.child_tenant_matches_learner();
DROP TRIGGER IF EXISTS lesson_progress_tenant_trg ON learn.lesson_progress;
CREATE TRIGGER lesson_progress_tenant_trg BEFORE INSERT OR UPDATE OF learner_id, tenant_id ON learn.lesson_progress
    FOR EACH ROW EXECUTE FUNCTION learn.child_tenant_matches_learner();
DROP TRIGGER IF EXISTS quiz_attempt_tenant_trg ON learn.quiz_attempt;
CREATE TRIGGER quiz_attempt_tenant_trg BEFORE INSERT OR UPDATE OF learner_id, tenant_id ON learn.quiz_attempt
    FOR EACH ROW EXECUTE FUNCTION learn.child_tenant_matches_learner();
DROP TRIGGER IF EXISTS review_card_tenant_trg ON learn.review_card;
CREATE TRIGGER review_card_tenant_trg BEFORE INSERT OR UPDATE OF learner_id, tenant_id ON learn.review_card
    FOR EACH ROW EXECUTE FUNCTION learn.child_tenant_matches_learner();
DROP TRIGGER IF EXISTS lab_run_tenant_trg ON learn.lab_run;
CREATE TRIGGER lab_run_tenant_trg BEFORE INSERT OR UPDATE OF learner_id, tenant_id ON learn.lab_run
    FOR EACH ROW EXECUTE FUNCTION learn.child_tenant_matches_learner();
DROP TRIGGER IF EXISTS certificate_tenant_trg ON learn.certificate;
CREATE TRIGGER certificate_tenant_trg BEFORE INSERT OR UPDATE OF learner_id, tenant_id ON learn.certificate
    FOR EACH ROW EXECUTE FUNCTION learn.child_tenant_matches_learner();

-- 2. A learner's tenant never changes ───────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION learn.learner_tenant_fixed() RETURNS trigger
    LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
        RAISE EXCEPTION 'learn.learner: the tenant of a learner never changes (a new tenant is a new learner)'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION learn.learner_tenant_fixed() FROM PUBLIC;
DROP TRIGGER IF EXISTS learner_tenant_fixed_trg ON learn.learner;
CREATE TRIGGER learner_tenant_fixed_trg BEFORE UPDATE OF tenant_id ON learn.learner
    FOR EACH ROW EXECUTE FUNCTION learn.learner_tenant_fixed();

-- 3. lab_run by learner ─────────────────────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS lab_run_learner_idx ON learn.lab_run (learner_id, module_id, started_at);

-- 4. Post-check ──────────────────────────────────────────────────────────────────────────────────────────────────────
DO $check$
DECLARE
    bad text;
BEGIN
    SELECT string_agg(t, ', ' ORDER BY t) INTO bad
      FROM unnest(ARRAY['enrollment', 'statement', 'lesson_progress', 'quiz_attempt', 'review_card', 'lab_run',
                        'certificate']) AS t
     WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger g JOIN pg_catalog.pg_class c ON c.oid = g.tgrelid
                        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                       WHERE n.nspname = 'learn' AND c.relname = t AND g.tgname = t || '_tenant_trg'
                         AND NOT g.tgisinternal);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 421: tenant trigger missing on learn.%', bad;
    END IF;
    SELECT string_agg(x.t, ', ' ORDER BY x.t) INTO bad FROM (
        SELECT 'enrollment' AS t FROM learn.enrollment c JOIN learn.learner l USING (learner_id)
         WHERE c.tenant_id IS DISTINCT FROM l.tenant_id
        UNION SELECT 'statement' FROM learn.statement c JOIN learn.learner l USING (learner_id)
         WHERE c.tenant_id IS DISTINCT FROM l.tenant_id
        UNION SELECT 'lesson_progress' FROM learn.lesson_progress c JOIN learn.learner l USING (learner_id)
         WHERE c.tenant_id IS DISTINCT FROM l.tenant_id
        UNION SELECT 'quiz_attempt' FROM learn.quiz_attempt c JOIN learn.learner l USING (learner_id)
         WHERE c.tenant_id IS DISTINCT FROM l.tenant_id
        UNION SELECT 'review_card' FROM learn.review_card c JOIN learn.learner l USING (learner_id)
         WHERE c.tenant_id IS DISTINCT FROM l.tenant_id
        UNION SELECT 'lab_run' FROM learn.lab_run c JOIN learn.learner l USING (learner_id)
         WHERE c.tenant_id IS DISTINCT FROM l.tenant_id
        UNION SELECT 'certificate' FROM learn.certificate c JOIN learn.learner l USING (learner_id)
         WHERE c.tenant_id IS DISTINCT FROM l.tenant_id) x;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 421: rows whose tenant differs from their learner''s in learn.%', bad;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_indexes WHERE schemaname = 'learn' AND indexname = 'lab_run_learner_idx')
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger g WHERE g.tgname = 'learner_tenant_fixed_trg'
                       AND g.tgrelid = 'learn.learner'::regclass) THEN
        RAISE EXCEPTION 'migration 421: lab_run_learner_idx or learner_tenant_fixed_trg missing';
    END IF;
END
$check$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('421', now(), 'AA-1105: learn child rows carry their learner''s tenant (trigger); lab_run learner index')
ON CONFLICT (version) DO NOTHING;

COMMIT;
