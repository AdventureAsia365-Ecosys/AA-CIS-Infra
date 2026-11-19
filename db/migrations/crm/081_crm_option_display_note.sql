-- Migration crm-081: AA-1144 (S285 decision D9, advisory r3 permissions P7) — in a quote, the name of an Adventure
-- Asia item is read only for the agency (AA books exactly that service: a renamed "Hotel A, Deluxe room" would tell the
-- traveller one thing while AA books another); the agency may add one display note line per item instead.
--
-- Owner: AA-Partner (api/migrations/081_crm_option_display_note.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy Migration Apply runs (Migration Copy Guard). Key crm-081, right after crm-080; if the numbers move, renumber:
-- file name, this header, Guard 0 and the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS (code PR) and the
-- tests that name it (git grep '081_' and 'crm-081').
--
-- What:
--   1. crm.option.display_note (text, NULL = no note): one line the agency shows under the item in the quote, the
--      client page and the next version of the quote. Any item (AA or agency). CHECK option_display_note_chk: NULL, or
--      1..200 characters with no control character (one line, like the title).
--   2. Register crm-081.
--
-- Not here (code PR, readiness crm-081): the builder API refuses a new title for an AA item (403 aa_title_read_only)
-- and reads / writes the note; the web shows the AA name as text with an "Add note" action.
--
-- Class: contract (root ADR 0017 d3: ALTER of an existing table, a new CHECK), so no migrate directive. MIG-4: this
-- migration-only PR, applied on Dev by Infra Migration Apply once every job table is idle (root ADR 0017a), then the
-- code PR. No new table (no DM-7.1 row), no data change, no personal data expected (a display line like the title;
-- crm.option already goes with its trip in erasure and export).
--
-- Rollback (a NEW forward migration, MIG-14): drop the CHECK and the column (the notes are lost; the titles never
-- changed).
--
-- Runs as crm_owner (Migration Apply live-owner switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (ADD COLUMN
-- IF NOT EXISTS, the constraint replaced by name).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ── Guard 0: runs as the owner, after crm-080 ─────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-081: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-080') THEN
        RAISE EXCEPTION 'crm-081: crm-080 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-081' AND description NOT LIKE 'AA-1144 option display note:%') THEN
        RAISE EXCEPTION 'crm-081: the key crm-081 is already held by another migration (not AA-1144): renumber one';
    END IF;
END $$;

-- ── 1. one display note line per item ────────────────────────────────────────────────────────────
ALTER TABLE crm.option ADD COLUMN IF NOT EXISTS display_note text;
ALTER TABLE crm.option DROP CONSTRAINT IF EXISTS option_display_note_chk;
ALTER TABLE crm.option ADD CONSTRAINT option_display_note_chk CHECK (
    display_note IS NULL OR (char_length(display_note) BETWEEN 1 AND 200 AND display_note !~ '[[:cntrl:]]')
);
COMMENT ON COLUMN crm.option.display_note IS 'AA-1144 (crm-081, S285 D9): one line the agency shows under the item in the quote and on the client page (an AA item''s title is read only for the agency). NULL = no note. One line, 1..200 characters.';

-- ── guard: the result ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'crm.option'::regclass AND conname = 'option_display_note_chk')
       OR NOT has_column_privilege('crm_app', 'crm.option', 'display_note', 'UPDATE') THEN
        RAISE EXCEPTION 'crm-081: option_display_note_chk or the crm_app UPDATE on crm.option.display_note is missing';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-081', now(), 'AA-1144 option display note: crm.option.display_note (one line, 1..200 characters) for the agency under an item of a quote; an AA item''s title stays read only (S285 D9)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
