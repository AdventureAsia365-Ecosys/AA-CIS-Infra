-- migrate: expand
-- Migration 454: AA-1133 (S284, docs reader v2) — acp_shared.docs_feedback: the "Was this page helpful?" answers and
-- the "Report a problem" notes staff leave on a page of the /admin/docs reader.
--
-- Why. Tech lead S283 decision c-s283-docs-feedback ("a CIS table"): the reader opens to every staff role (AA-1133 B7),
-- and the pages people mark unhelpful, with what they say is wrong, are the cheapest signal of which page to fix next.
-- Until now a reader had no way to say so except a message to the tech lead.
--
-- What.
--   1. acp_shared.docs_feedback: one row per staff member and page (repo, path; the English page and its translation
--      are separate rows, lang says which one was read). helpful (yes / no) is the latest answer; comment is the latest
--      optional note (at most 1000 characters, pii:free_text: typed by staff, may name a person). actor is the audit
--      actor of the staff member (admin:<admin_users.id>, or "machine" for the admin secret without a person), never an
--      e-mail; role is the CIS staff role the answer was given with. A second answer from the same person on the same
--      page replaces the first (unique key (repo, path, actor)); created_at stays, updated_at moves.
--      Index (updated_at) for the admin view (newest first); the unique key serves the per-page aggregates.
--      DM-1.5: a CIS-private table, so not in `shared`; acp_shared already holds the staff audit log.
--   2. GRANT cis_app SELECT, INSERT, UPDATE (the reader's POST upserts, the admin view reads; no DELETE for the runtime
--      role: nothing deletes yet, see Retention).
--   3. Register 454.
--
-- PII (DM-6.1). comment: pii:free_text (staff typed). actor: the staff id, not a name or an e-mail. No tenant column:
-- the docs are AA-internal.
--
-- Retention (DM-7.1). Proposed 24 months after updated_at, no deletion job yet; nothing is deleted until the tech lead
-- approves the window before prod (DM-7.5, N4). Row in root data standards Part B section 7, in the root PR of this
-- change (merged before the Infra copy).
--
-- Class: expand (root ADR 0017 d3): a new table with its constraints and indexes, a grant to the owner's runtime role
-- and comments; no existing object changes, no seed row, no DO block, no REVOKE (the cis_owner default ACL in
-- acp_shared gives cis_app DML on a new table; the explicit GRANT documents what the code needs).
--
-- Number. 447 is the newest CIS migration on main (18/11/2026); 448-453 are taken by other lanes of the S284 wave
-- (453 by the AA-1113 lane). If the owner main max + 1 differs at merge, renumber (git grep '454_' and "'454'" here,
-- in tests/integration/test_aa1133_migration_454.py, api/core/readiness.py and docs/implementation-notes/AA-1133.md).
-- Migration-only PR (MIG-4); the code PR adds 454 to REQUIRED_CIS_ABOVE_GAP and its feedback routes answer 503 while
-- the table is missing.
--
-- Behaviour on apply: none. The table is empty; nothing reads it until the AA-1133 reader code ships.
--
-- Rollback (a new forward migration, after the code PR is reverted): DROP TABLE acp_shared.docs_feedback (a
-- destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of schema
-- acp_shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS acp_shared.docs_feedback (
    feedback_id  uuid         NOT NULL DEFAULT gen_random_uuid(),
    repo         text         NOT NULL,
    path         text         NOT NULL,
    lang         text         NOT NULL DEFAULT 'en',
    helpful      boolean      NOT NULL,
    comment      text,
    actor        text         NOT NULL,
    role         text,
    created_at   timestamptz  NOT NULL DEFAULT now(),
    updated_at   timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT docs_feedback_pkey PRIMARY KEY (feedback_id),
    CONSTRAINT docs_feedback_page_actor_key UNIQUE (repo, path, actor),
    CONSTRAINT docs_feedback_repo_check CHECK (repo ~ '^[A-Za-z0-9._-]{1,64}$'),
    CONSTRAINT docs_feedback_path_check CHECK (char_length(path) BETWEEN 4 AND 300 AND path ~ '\.md$'),
    CONSTRAINT docs_feedback_lang_check CHECK (lang ~ '^[a-z]{2}$'),
    CONSTRAINT docs_feedback_comment_check CHECK (comment IS NULL OR char_length(comment) BETWEEN 1 AND 1000),
    CONSTRAINT docs_feedback_actor_check CHECK (char_length(actor) BETWEEN 1 AND 64),
    CONSTRAINT docs_feedback_role_check CHECK (role IS NULL OR char_length(role) BETWEEN 1 AND 32),
    CONSTRAINT docs_feedback_time_check CHECK (updated_at >= created_at)
);

CREATE INDEX IF NOT EXISTS docs_feedback_updated_idx ON acp_shared.docs_feedback (updated_at DESC);

COMMENT ON TABLE acp_shared.docs_feedback IS
    'AA-1133 (CIS 454): the latest "Was this page helpful?" answer and optional note of one staff member on one page '
    'of the /admin/docs reader (POST /admin/docs/feedback). Read by the admin view GET /admin/docs/feedback (pages '
    'with the most "no" answers first). One row per (repo, path, actor); a new answer replaces the old one.';
COMMENT ON COLUMN acp_shared.docs_feedback.comment IS
    'pii:free_text; AA-1133 (454): the staff member''s optional note on what is wrong or missing (at most 1000 '
    'characters).';
COMMENT ON COLUMN acp_shared.docs_feedback.actor IS
    'AA-1133 (454): admin:<admin_users.id> of the staff member (the audit actor format), or machine. Never an e-mail.';
COMMENT ON COLUMN acp_shared.docs_feedback.lang IS
    'AA-1133 (454): the language of the page that was read (en, or vi for a translation).';

GRANT SELECT, INSERT, UPDATE ON acp_shared.docs_feedback TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('454', now(), 'AA-1133: acp_shared.docs_feedback (docs reader page feedback)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
