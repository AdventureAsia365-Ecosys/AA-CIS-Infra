-- migrate: expand
-- Migration 457: AA-1146 (S285, slice L3 part 1; tech lead approvals D1-D11 of S285) — tour edits are versioned and
-- a published hand edit is locked: the history table of the source tour, the draft fields of a wording version and the
-- lock of a Master.
--
-- Why. Content staff edited a tour in the drawer and the save went straight into the record: the source tour
-- (silver_aa_internal.raw_tours) with no author, no reason and no old value; the AI text (generated_content) by
-- overwriting the newest version, which may not be the live one. A wave rerun or an S1 auto publish could then replace a
-- Master a person had corrected. Option B of the content-editing advisory (root docs/audits/2026-11-19-S285-session/
-- advisory-content-editing.md section 5): every edit is a version with an author and a reason, a diff against the live
-- version, a publish through one gate, and a lock on the Master that only a person lifts.
--
-- What.
--   1. silver_aa_internal.raw_tour_revision: one row per change of a source tour's fields, append-only.
--        id            bigint identity
--        tour_id       the raw tour (no foreign key: raw_tours rows are kept on soft delete, and an append-only child
--                      would block a hard delete by cascade; the writer checks the tour first)
--        revision_num  1, 2, ... per tour (UNIQUE (tour_id, revision_num): two writers of one tour, one wins, the
--                      other retries)
--        source        staff_edit (the drawer, PATCH /admin/tours/{id}/raw) | excel_merge (an Excel re-import merged
--                      field by field into the existing tour, AA-1146 T1)
--        fields        the field names the change touched (text[], 1..32 names)
--        before, after jsonb objects {field: value} of exactly those fields (the old value is kept: tech lead D5)
--        actor         admin:<admin_users.id>, or admin / machine for a secret session (the audit actor format)
--        reason        why, 3..500 characters, optional on an inline edit (the drawer), required by the API on a merge
--        resolutions   excel_merge only: {field: "incoming" | "current"} for the fields a person decided (the
--                      hand-edited ones); NULL otherwise
--        created_at    now()
--      Triggers raw_tour_revision_append_only (BEFORE UPDATE / DELETE per row, BEFORE TRUNCATE): refuse both.
--      "Which fields did a person edit" (T1: they win over an Excel re-import) is answered from this table: a field
--      named in a staff_edit row (or decided "current" in an excel_merge row) after the tour's last import.
--   1b. silver_aa_internal.raw_tour_fact_draft: an Excel re-import merged field by field is a DRAFT of the source
--      tour's facts (AA-1146 T1: "the result is a draft"), not a write into raw_tours. It goes live only through the
--      publish gate (POST /admin/tours/{id}/fact-draft/publish: the two-person rule, a stale check against the values
--      it was merged from, price edits only with reference_price.write); a discard keeps it as history.
--        id            bigint identity
--        tour_id       the raw tour (no foreign key, same reason as raw_tour_revision)
--        staging_id    the upload_staging row it came from (that row is removed by the decision; no foreign key)
--        fields        the field names the draft changes (text[], 1..32 names)
--        before, after jsonb objects {field: value}: the tour's values when merged, the values publishing writes
--        resolutions   {field: "incoming" | "current"} for the hand-edited fields a person decided ({} when none)
--        author        who merged: admin:<admin_users.id>, admin or machine (1..64 characters)
--        reason        why, 3..500 characters (required)
--        status        draft | published | discarded; one open draft per tour (partial unique index)
--        decided_by, decided_at   who published or discarded it, and when (NULL while it is a draft)
--        revision_num  the raw_tour_revision row its publish wrote (NULL otherwise)
--        created_at    now()
--      cis_app may SELECT, INSERT and UPDATE it (the status moves; no DELETE: it is history).
--   2. silver_aa_internal.generated_content, four nullable columns (the wording version of AA-1146):
--        origin              llm (a writer run) | human (a person's draft); NULL = rows written before this file
--                            (read as llm, or human when human_edited)
--        parent_version_num  the version a human draft was copied from (the live version by default)
--        edit_reason         why the person made the draft (3..500 characters, checked by the API)
--        author_id           who made the draft: admin:<admin_users.id>, or admin for a secret session; the
--                            two-person publish rule (cis.content.publish_two_person, CIS 458) compares it with the
--                            publisher
--      A human draft is a new row with status 'draft' (content_status_enum already has it; no writer path uses it
--      today), never an UPDATE of an existing version.
--   3. gold_aa_internal.published_tours, three nullable columns (the lock):
--        human_lock_at, human_lock_by, human_lock_reason: set when a person publishes a hand-edited version; while set,
--        the automatic exits (an S1 run's auto publish, a wave rerun, the recompose path, the legacy Lambda) leave the
--        Master as it is and log why; a person clears it (POST /admin/tours/{id}/unlock, master.admin).
--   4. GRANT cis_app SELECT, INSERT on raw_tour_revision (no UPDATE / DELETE: append-only); SELECT, INSERT, UPDATE on
--      raw_tour_fact_draft (no DELETE).
--   5. Register 457.
--
-- PII (DM-6.1). raw_tour_revision.before / after and raw_tour_fact_draft.before / after hold source tour fields
-- (supplier text: names, prices, itineraries; no personal data of travellers); reason is staff typed (pii:free_text).
-- actor / author / author_id / decided_by are staff ids, never an e-mail.
--
-- Retention (DM-7.1). raw_tour_revision and raw_tour_fact_draft: kept while their tour exists (the history of a source
-- record, like the audit log), no deletion job; rows in root data standards Part B section 7, in the root PR of this
-- change (merged before the Infra copy). The new columns follow their table's retention.
--
-- Class: expand (root ADR 0017 d3): two new tables with their constraints, indexes, trigger function and triggers; nullable
-- columns without default on two existing tables (generated_content ~2.4k rows, published_tours ~0.9k rows, far below
-- EXPAND_MAX_ROWS; neither is a hot table), a grant to the owner's runtime role, comments and the registration. No
-- CHECK on the new columns of the existing tables (a constraint on an existing table is contract): the API checks the
-- values; a later contract file may add the CHECKs once the code has run.
--
-- Number. 455 and 456 (AA-1143) are the newest CIS migrations on main (19/11/2026). 458 (same PR, contract) seeds the
-- settings. If the owner main max + 1 differs at merge, renumber both (git grep '457_' and '458_', "'457'", "'458'",
-- 'CIS 457', 'CIS 458' here, in tests/integration/test_aa1146_migration_457_458.py, compiled_defaults.json,
-- api/services/content_publish_gate.py and docs/implementation-notes/AA-1146.md).
-- Migration-only PR (MIG-4); the code PR reads the new columns only after a feature check (SQLSTATE 42703 / 42P01:
-- versions and the lock are off, today's behaviour stays) and raises no readiness key.
--
-- Behaviour on apply: none. The tables are empty, every new column NULL; nothing reads them until the AA-1146 code ships.
--
-- Rollback (a new forward migration, after the code PR is reverted): DROP TABLE silver_aa_internal.raw_tour_revision
-- and its function, DROP TABLE silver_aa_internal.raw_tour_fact_draft, DROP the seven columns (a destructive file,
-- DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of the
-- silver_aa_internal and gold_aa_internal schemas and of both altered tables.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS silver_aa_internal.raw_tour_revision (
    id            bigint       GENERATED ALWAYS AS IDENTITY,
    tour_id       uuid         NOT NULL,
    revision_num  integer      NOT NULL,
    source        text         NOT NULL,
    fields        text[]       NOT NULL,
    before        jsonb        NOT NULL,
    after         jsonb        NOT NULL,
    actor         text         NOT NULL,
    reason        text,
    resolutions   jsonb,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT raw_tour_revision_pkey PRIMARY KEY (id),
    CONSTRAINT raw_tour_revision_tour_num_key UNIQUE (tour_id, revision_num),
    CONSTRAINT raw_tour_revision_num_check CHECK (revision_num >= 1),
    CONSTRAINT raw_tour_revision_source_check CHECK (source IN ('staff_edit', 'excel_merge')),
    CONSTRAINT raw_tour_revision_fields_check CHECK (cardinality(fields) BETWEEN 1 AND 32),
    CONSTRAINT raw_tour_revision_before_check CHECK (jsonb_typeof(before) = 'object'),
    CONSTRAINT raw_tour_revision_after_check CHECK (jsonb_typeof(after) = 'object'),
    CONSTRAINT raw_tour_revision_actor_check CHECK (char_length(actor) BETWEEN 1 AND 64),
    CONSTRAINT raw_tour_revision_reason_check CHECK (reason IS NULL OR char_length(reason) BETWEEN 3 AND 500),
    CONSTRAINT raw_tour_revision_resolutions_check CHECK (
        (source = 'excel_merge' AND resolutions IS NOT NULL AND jsonb_typeof(resolutions) = 'object')
        OR (source <> 'excel_merge' AND resolutions IS NULL))
);

CREATE INDEX IF NOT EXISTS raw_tour_revision_tour_idx
    ON silver_aa_internal.raw_tour_revision (tour_id, revision_num DESC);

CREATE FUNCTION silver_aa_internal.raw_tour_revision_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'silver_aa_internal.raw_tour_revision is append-only (% refused)', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END
$fn$;

CREATE TRIGGER raw_tour_revision_append_only
    BEFORE UPDATE OR DELETE ON silver_aa_internal.raw_tour_revision
    FOR EACH ROW EXECUTE FUNCTION silver_aa_internal.raw_tour_revision_append_only();
CREATE TRIGGER raw_tour_revision_no_truncate
    BEFORE TRUNCATE ON silver_aa_internal.raw_tour_revision
    FOR EACH STATEMENT EXECUTE FUNCTION silver_aa_internal.raw_tour_revision_append_only();

CREATE TABLE IF NOT EXISTS silver_aa_internal.raw_tour_fact_draft (
    id            bigint       GENERATED ALWAYS AS IDENTITY,
    tour_id       uuid         NOT NULL,
    staging_id    uuid,
    fields        text[]       NOT NULL,
    before        jsonb        NOT NULL,
    after         jsonb        NOT NULL,
    resolutions   jsonb        NOT NULL DEFAULT '{}'::jsonb,
    author        text         NOT NULL,
    reason        text         NOT NULL,
    status        text         NOT NULL DEFAULT 'draft',
    decided_by    text,
    decided_at    timestamptz,
    revision_num  integer,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT raw_tour_fact_draft_pkey PRIMARY KEY (id),
    CONSTRAINT raw_tour_fact_draft_fields_check CHECK (cardinality(fields) BETWEEN 1 AND 32),
    CONSTRAINT raw_tour_fact_draft_before_check CHECK (jsonb_typeof(before) = 'object'),
    CONSTRAINT raw_tour_fact_draft_after_check CHECK (jsonb_typeof(after) = 'object'),
    CONSTRAINT raw_tour_fact_draft_resolutions_check CHECK (jsonb_typeof(resolutions) = 'object'),
    CONSTRAINT raw_tour_fact_draft_author_check CHECK (char_length(author) BETWEEN 1 AND 64),
    CONSTRAINT raw_tour_fact_draft_reason_check CHECK (char_length(reason) BETWEEN 3 AND 500),
    CONSTRAINT raw_tour_fact_draft_status_check CHECK (status IN ('draft', 'published', 'discarded')),
    CONSTRAINT raw_tour_fact_draft_decided_check CHECK (
        (status = 'draft' AND decided_at IS NULL AND decided_by IS NULL)
        OR (status <> 'draft' AND decided_at IS NOT NULL AND char_length(decided_by) BETWEEN 1 AND 64)),
    CONSTRAINT raw_tour_fact_draft_revision_check CHECK (revision_num IS NULL OR status = 'published')
);

CREATE UNIQUE INDEX IF NOT EXISTS raw_tour_fact_draft_open_key
    ON silver_aa_internal.raw_tour_fact_draft (tour_id) WHERE status = 'draft';
CREATE INDEX IF NOT EXISTS raw_tour_fact_draft_tour_idx
    ON silver_aa_internal.raw_tour_fact_draft (tour_id, created_at DESC);

ALTER TABLE silver_aa_internal.generated_content ADD COLUMN IF NOT EXISTS origin text;
ALTER TABLE silver_aa_internal.generated_content ADD COLUMN IF NOT EXISTS parent_version_num smallint;
ALTER TABLE silver_aa_internal.generated_content ADD COLUMN IF NOT EXISTS edit_reason text;
ALTER TABLE silver_aa_internal.generated_content ADD COLUMN IF NOT EXISTS author_id text;

ALTER TABLE gold_aa_internal.published_tours ADD COLUMN IF NOT EXISTS human_lock_at timestamptz;
ALTER TABLE gold_aa_internal.published_tours ADD COLUMN IF NOT EXISTS human_lock_by text;
ALTER TABLE gold_aa_internal.published_tours ADD COLUMN IF NOT EXISTS human_lock_reason text;

COMMENT ON TABLE silver_aa_internal.raw_tour_revision IS
    'AA-1146 (CIS 457): append-only history of a source tour''s fields: one row per staff edit (PATCH '
    '/admin/tours/{id}/raw) or Excel merge (re-import of an existing tour, field by field), with the fields, their old '
    'and new values, the actor and the reason. A field named in a staff_edit row after the last import is hand-edited: '
    'it wins over the next Excel import unless a person accepts the incoming value.';
COMMENT ON COLUMN silver_aa_internal.raw_tour_revision.reason IS
    'pii:free_text; AA-1146 (457): why the staff member changed the fields (3..500 characters).';
COMMENT ON COLUMN silver_aa_internal.raw_tour_revision.actor IS
    'AA-1146 (457): admin:<admin_users.id> of the staff member (the audit actor format), admin or machine. Never an '
    'e-mail.';
COMMENT ON TABLE silver_aa_internal.raw_tour_fact_draft IS
    'AA-1146 T1 (CIS 457): an Excel re-import merged field by field into an existing tour, held as a draft of the '
    'source facts until a person publishes it (POST /admin/tours/{id}/fact-draft/publish, the publish gate); one open '
    'draft per tour; published and discarded drafts are kept as history.';
COMMENT ON COLUMN silver_aa_internal.raw_tour_fact_draft.reason IS
    'pii:free_text; AA-1146 (457): why the staff member merged the sheet (3..500 characters).';
COMMENT ON COLUMN silver_aa_internal.raw_tour_fact_draft.author IS
    'AA-1146 (457): admin:<admin_users.id> of the staff member who merged the sheet (the audit actor format), admin '
    'or machine. Never an e-mail. The two-person publish rule compares it with the publisher.';
COMMENT ON COLUMN silver_aa_internal.raw_tour_fact_draft.decided_by IS
    'AA-1146 (457): admin:<admin_users.id> (or admin) of the person who published or discarded the draft.';
COMMENT ON COLUMN silver_aa_internal.generated_content.origin IS
    'AA-1146 (457): llm (a writer run) or human (a person''s draft version); NULL on rows written before 457.';
COMMENT ON COLUMN silver_aa_internal.generated_content.parent_version_num IS
    'AA-1146 (457): the version a human draft was copied from.';
COMMENT ON COLUMN silver_aa_internal.generated_content.edit_reason IS
    'pii:free_text; AA-1146 (457): why the person made this draft version.';
COMMENT ON COLUMN silver_aa_internal.generated_content.author_id IS
    'AA-1146 (457): admin:<admin_users.id> (or admin) of the person who made this draft version; the two-person '
    'publish rule compares it with the publisher.';
COMMENT ON COLUMN gold_aa_internal.published_tours.human_lock_at IS
    'AA-1146 (457): set when a person published a hand-edited version; while set, automatic exits (S1 auto publish, '
    'wave reruns, recompose, the legacy Lambda) leave this Master as it is. Cleared by POST /admin/tours/{id}/unlock.';
COMMENT ON COLUMN gold_aa_internal.published_tours.human_lock_by IS
    'AA-1146 (457): admin:<admin_users.id> (or admin) of the person whose publish set the lock.';
COMMENT ON COLUMN gold_aa_internal.published_tours.human_lock_reason IS
    'pii:free_text; AA-1146 (457): the reason of the publish that set the lock.';

GRANT SELECT, INSERT ON silver_aa_internal.raw_tour_revision TO cis_app;
GRANT SELECT, INSERT, UPDATE ON silver_aa_internal.raw_tour_fact_draft TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('457', now(), 'AA-1146: raw_tour_revision, raw_tour_fact_draft, the draft fields of generated_content, the '
        'published_tours lock')
ON CONFLICT (version) DO NOTHING;

COMMIT;
