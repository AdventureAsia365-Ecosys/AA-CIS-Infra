-- migrate: expand
-- Migration crm-059: AA-1070 item crm-35 (S275 study of a tour and travel app, root docs/research/2026-11-10-odoo-
-- tour-travel-plugin-comparison.md row 24; behaviour only, no plugin code) — the "Included" / "Not included" lists of
-- a proposal: the agency's library of standard lines and the lines one builder proposal version shows.
--
-- Owner: AA-Partner (api/migrations/059_crm_proposal_inclusions.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy Migration Apply runs (Migration Copy Guard). Key crm-059: crm-058 is the highest on main; if main moves,
-- renumber: file name, this header, the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS and the tests that
-- name it (git grep '059_' and 'crm-059').
--
-- What (DM-7.1: root data standards Part B §7 rows added with this key):
--   1. crm.inclusion_item (base template): one line of the agency's library: kind included | not_included, the
--      English text (the default) and an optional Vietnamese text (1..500 characters each, no control character),
--      sort order 0..999, archived (an archived line is no longer offered in the builder; versions that picked it keep
--      their copy). One live line per (agency, kind, English text, case-insensitive). Commercial wording, no personal
--      data. Cascades from the agency's crm.tenant_settings row (the agency erase deletes it).
--   2. crm.proposal_inclusion (base template): one line one builder proposal version shows under "Included" or "Not
--      included": source library (picked from crm.inclusion_item: inclusion_item_id is a snapshot reference without
--      a foreign key, so editing, archiving or deleting the library line never changes a version), custom (typed for
--      this version only) or aa_tour (the inclusions / exclusions of an AA tour the version holds, copied from the CIS
--      tour content in crm.aa_catalog_tour when the version is published: aa_tour_source_id + aa_tour_title). The
--      text itself is copied (text_en, text_vi), sort order 0..199, source_inclusion_id = the row of the base version a
--      working copy copied. A library line is picked at most once per version. Changes only while its proposal is a
--      draft (crm.guard_proposal_draft, CRM35), so a published / sent / accepted version keeps the lists it went out
--      with; the trip hold guard (crm.guard_held_change, CRM10). Commercial wording, no personal data. Cascades from
--      its proposal (the trip and agency erase, the trash purge).
--   3. Erasure without a replaced crm.erase_subject: both tables cascade from a row the erase already deletes
--      (tests/integration/test_crm010_schema.py CASCADE_ERASED lists them with their parents).
--   4. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles) on both tables; crm_app SELECT, INSERT, UPDATE, DELETE
--      (the default privileges of crm-001 give the same); no reader grant (AI context, insights and support never
--      read them).
--
-- Class: expand (root ADR 0017 d3): two new tables with their constraints, indexes, triggers (existing trigger
-- functions only), policies, grants and comments; foreign keys from the new tables only; no change to an existing
-- object, no DO block, no CREATE OR REPLACE. Not re-runnable by itself (plain CREATE POLICY / TRIGGER); Migration Apply
-- never applies a registered key again and the test conftest skips it. Ships alone in the migration-only PR, applied
-- before the code PR (the code PR raises the readiness to crm-059).
--
-- Rollback (a forward crm- file, after the code that reads them is reverted): DROP TABLE crm.proposal_inclusion,
-- crm.inclusion_item.
--
-- Runs as crm_owner (Migration Apply / DB Migrate switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- ── 1. crm.inclusion_item ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.inclusion_item (
    inclusion_item_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                      REFERENCES crm.tenant (tenant_id),
    kind              TEXT NOT NULL,
    text_en           TEXT NOT NULL,
    text_vi           TEXT,
    sort_order        SMALLINT NOT NULL DEFAULT 0,
    archived          BOOLEAN NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,
    deleted_by        TEXT,
    purge_after       TIMESTAMPTZ,
    CONSTRAINT inclusion_item_tenant_id_uq UNIQUE (tenant_id, inclusion_item_id),
    CONSTRAINT inclusion_item_settings_fk FOREIGN KEY (tenant_id)
        REFERENCES crm.tenant_settings (tenant_id) ON DELETE CASCADE,
    CONSTRAINT inclusion_item_values_chk CHECK (
        kind IN ('included', 'not_included')
        AND char_length(btrim(text_en)) BETWEEN 1 AND 500 AND text_en !~ '[[:cntrl:]]'
        AND (text_vi IS NULL OR (char_length(btrim(text_vi)) BETWEEN 1 AND 500 AND text_vi !~ '[[:cntrl:]]'))
        AND sort_order BETWEEN 0 AND 999
    ),
    CONSTRAINT inclusion_item_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS inclusion_item_text_uq
    ON crm.inclusion_item (tenant_id, kind, lower(btrim(text_en))) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS inclusion_item_list_idx ON crm.inclusion_item (tenant_id, kind, sort_order)
    WHERE deleted_at IS NULL;
ALTER TABLE crm.inclusion_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.inclusion_item FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.inclusion_item
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER inclusion_item_set_updated_at
    BEFORE UPDATE ON crm.inclusion_item
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
GRANT SELECT, INSERT, UPDATE, DELETE ON crm.inclusion_item TO crm_app;
COMMENT ON TABLE crm.inclusion_item IS 'AA-1070 (crm-059, item crm-35): one line of the agency''s library of standard "Included" / "Not included" lines for proposals: kind, English text (default), optional Vietnamese text, sort order, archived (not offered any more; versions that picked it keep their copy). One live line per kind and English text (case-insensitive). Written by the owner or an agent. Commercial wording, no personal data. Cascades from the agency''s tenant_settings row.';
COMMENT ON COLUMN crm.inclusion_item.kind IS 'included (what the price covers) | not_included (what it does not, e.g. international flights)';
COMMENT ON COLUMN crm.inclusion_item.archived IS 'true = no longer offered in the builder picker; a version that picked it keeps its own copy of the text';

-- ── 2. crm.proposal_inclusion ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.proposal_inclusion (
    proposal_inclusion_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                          REFERENCES crm.tenant (tenant_id),
    trip_id               UUID NOT NULL,
    proposal_id           UUID NOT NULL,
    kind                  TEXT NOT NULL,
    source                TEXT NOT NULL,
    inclusion_item_id     UUID,
    aa_tour_source_id     TEXT,
    aa_tour_title         TEXT,
    text_en               TEXT NOT NULL,
    text_vi               TEXT,
    sort_order            SMALLINT NOT NULL DEFAULT 0,
    source_inclusion_id   UUID,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at            TIMESTAMPTZ,
    deleted_by            TEXT,
    purge_after           TIMESTAMPTZ,
    CONSTRAINT proposal_inclusion_tenant_id_uq UNIQUE (tenant_id, proposal_inclusion_id),
    CONSTRAINT proposal_inclusion_proposal_fk FOREIGN KEY (tenant_id, proposal_id, trip_id)
        REFERENCES crm.proposal (tenant_id, proposal_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT proposal_inclusion_values_chk CHECK (
        kind IN ('included', 'not_included')
        AND char_length(btrim(text_en)) BETWEEN 1 AND 500 AND text_en !~ '[[:cntrl:]]'
        AND (text_vi IS NULL OR (char_length(btrim(text_vi)) BETWEEN 1 AND 500 AND text_vi !~ '[[:cntrl:]]'))
        AND sort_order BETWEEN 0 AND 199
    ),
    CONSTRAINT proposal_inclusion_source_chk CHECK (COALESCE(
        CASE source
            WHEN 'library' THEN inclusion_item_id IS NOT NULL AND aa_tour_source_id IS NULL AND aa_tour_title IS NULL
            WHEN 'custom' THEN inclusion_item_id IS NULL AND aa_tour_source_id IS NULL AND aa_tour_title IS NULL
            WHEN 'aa_tour' THEN inclusion_item_id IS NULL
                                AND aa_tour_source_id IS NOT NULL AND aa_tour_title IS NOT NULL
                                AND aa_tour_source_id ~ '^[A-Za-z0-9:_.-]{1,128}$'
                                AND char_length(btrim(aa_tour_title)) BETWEEN 1 AND 300
                                AND aa_tour_title !~ '[[:cntrl:]]'
            ELSE false
        END, false)
    ),
    CONSTRAINT proposal_inclusion_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS proposal_inclusion_item_uq
    ON crm.proposal_inclusion (tenant_id, proposal_id, inclusion_item_id)
    WHERE inclusion_item_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS proposal_inclusion_proposal_idx
    ON crm.proposal_inclusion (tenant_id, proposal_id, kind, sort_order);
CREATE INDEX IF NOT EXISTS proposal_inclusion_trip_idx ON crm.proposal_inclusion (tenant_id, trip_id);
ALTER TABLE crm.proposal_inclusion ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.proposal_inclusion FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.proposal_inclusion
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER proposal_inclusion_set_updated_at
    BEFORE UPDATE ON crm.proposal_inclusion
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
-- A published / sent / accepted version's lists never change (CRM35), whatever path writes.
CREATE TRIGGER proposal_inclusion_draft_only
    BEFORE INSERT OR UPDATE OR DELETE ON crm.proposal_inclusion
    FOR EACH ROW EXECUTE FUNCTION crm.guard_proposal_draft();
CREATE TRIGGER proposal_inclusion_hold_guard
    BEFORE DELETE OR UPDATE ON crm.proposal_inclusion
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_change('trip_id');
GRANT SELECT, INSERT, UPDATE, DELETE ON crm.proposal_inclusion TO crm_app;
COMMENT ON TABLE crm.proposal_inclusion IS 'AA-1070 (crm-059, item crm-35): one line a builder proposal version shows under "Included" or "Not included": source library (copied from crm.inclusion_item; inclusion_item_id is a snapshot reference without a foreign key), custom (typed for this version) or aa_tour (an AA tour''s inclusion / exclusion copied from the CIS tour content at publish: aa_tour_source_id, aa_tour_title). Text copied (English default, optional Vietnamese). Changes only while its proposal is a draft (crm.guard_proposal_draft, CRM35), so a published version keeps its lists; a working copy copies the agency lines (source_inclusion_id). Trip hold guard. Commercial wording, no personal data. Cascades from its proposal.';
COMMENT ON COLUMN crm.proposal_inclusion.inclusion_item_id IS 'the crm.inclusion_item the line was picked from (a snapshot reference, no foreign key); NULL for a custom or AA tour line';
COMMENT ON COLUMN crm.proposal_inclusion.source_inclusion_id IS 'the row of the base version a working copy copied this one from (no foreign key); NULL when picked or typed in this version';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-059', now(), 'AA-1070 crm-35: proposal inclusion lists: crm.inclusion_item (the agency library of included / not included lines), crm.proposal_inclusion (the lines of one builder proposal version: library, custom or AA tour copy; draft-only CRM35, trip hold guard)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
