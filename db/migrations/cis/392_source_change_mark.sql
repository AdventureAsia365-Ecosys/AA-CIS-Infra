-- migrate: expand
-- Migration 392: AA-1052 (Quality W6, root ADR 0020 layer 3 "lineage and versions") — the source-change fan-out marks:
-- which stored writer objects were written from a source that changed after them.
--
-- Why. ADR 0020 W6 asks for a $0 source-change fan-out: "a change to raw tours, facts, place cards, atoms or the
-- Master re-checks the dependent objects". The lineage of every writer object is stored since CIS #1390 (fs_id,
-- policy_sha, prompt and route versions), but nothing records that its SOURCE moved: an S1 Master version written
-- before an admin corrected the raw tour, a T2 tenant version of a Master that was re-published, a T9 blog whose atom
-- was edited or whose place card facts were corrected keep looking current. The fan-out (job kind source_fanout,
-- services/quality/source_fanout.py) finds those objects from their lineage and marks them here, with a typed
-- reason. It never regenerates, never calls a model and never changes an object's own status.
--
-- What.
--   1. shared.source_change_mark: one row per (dependent object, changed source) while it is open.
--        object_kind        s1 (silver_aa_internal.generated_content.id), t2 (gold_aa_internal.tenant_tour_versions.id),
--                           t9 (acp_shared.content_piece.piece_id); object_id is that id (no FK: the owners prune and
--                           erase on their own windows; a mark of a deleted object is pruned with it);
--        tour_id            the raw_tours tour whose source changed (for an atom or a place card: the atom's tour);
--        source_kind        raw_tour | master | atom | place_card; source_ref the atom_id, the place card id or the
--                           published_tours id of the new Master ('' = the whole tour);
--        reason             the typed cause: raw_tour_edited, master_published, atom_edited, atom_deleted,
--                           place_card_facts_edited, place_card_status_changed, place_cards_merged, manual_recheck;
--        changed_at         when the source changed; object_created_at when the object was written (always earlier:
--                           an object written after the change already read the new source);
--        detected_at / last_seen_at / hits   first and last fan-out that found it, and how many;
--        job_id             the source_fanout job of the last hit; details (jsonb object, ids and field NAMES only,
--                           never text: the fs_id the object read, the changed raw fields, the atom ids);
--        cleared_at / cleared_by   set when a person or a later check closes the mark (both or neither).
--      One OPEN mark per (object_kind, object_id, source_kind, source_ref): a partial unique index; a later fan-out of
--      the same source bumps last_seen_at / hits instead of adding a row.
--   2. GRANT cis_app SELECT, INSERT, UPDATE, DELETE (the job writes, the admin route reads, the TTL job deletes).
--   3. Register 392.
--
-- PII (DM-6.1). None: ids, source kinds, typed reasons and raw field names; no text, no tenant column (an object's
-- tenant is read from the object). Never read by a tenant route.
--
-- Retention (DM-7.1). Proposed: a cleared mark older than 180 days (cleared_at), and any mark whose object no longer
-- exists, is deleted by a future TTL kind (retention_source_change_mark, DRY RUN first); open marks stay. Row in root
-- data standards Part B section 7, in the root PR of this change (merged before the Infra copy).
--
-- Behaviour. None on apply: the table is empty. The code that ships with this file enqueues source_fanout after the
-- admin raw-tour edit, a Master publish, an admin atom edit and the admin place card edits; until it runs no row is
-- written. Before this file is applied the job fails closed (UndefinedTable, retried) and the read route answers 503.
--
-- Class: expand (root ADR 0017 d3): one new table, its constraints and indexes, a grant on it and comments; no FK, no
-- existing object changes, no seed row, no DO block. Ships in the code PR (ADR 0017 d1).
--
-- Number. 390 is the highest on main (08/11); 391 is held by a parallel lane of S273 (orchestrator hint): renumber to
-- main max + 1 when this lands first.
--
-- Rollback (a new forward migration, after the code is reverted): DROP TABLE shared.source_change_mark; (a destructive
-- file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of schema
-- shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.source_change_mark (
    mark_id            uuid          NOT NULL DEFAULT gen_random_uuid(),
    object_kind        text          NOT NULL,
    object_id          uuid          NOT NULL,
    tour_id            uuid          NOT NULL,
    source_kind        text          NOT NULL,
    source_ref         text          NOT NULL DEFAULT '',
    reason             text          NOT NULL,
    changed_at         timestamptz   NOT NULL,
    object_created_at  timestamptz   NOT NULL,
    detected_at        timestamptz   NOT NULL DEFAULT now(),
    last_seen_at       timestamptz   NOT NULL DEFAULT now(),
    hits               integer       NOT NULL DEFAULT 1,
    job_id             uuid,
    details            jsonb         NOT NULL DEFAULT '{}'::jsonb,
    cleared_at         timestamptz,
    cleared_by         text,
    CONSTRAINT source_change_mark_pkey PRIMARY KEY (mark_id),
    CONSTRAINT source_change_mark_object_kind_check CHECK (object_kind IN ('s1', 't2', 't9')),
    CONSTRAINT source_change_mark_source_kind_check CHECK (source_kind IN ('raw_tour', 'master', 'atom', 'place_card')),
    CONSTRAINT source_change_mark_reason_check CHECK (reason IN (
        'raw_tour_edited', 'master_published', 'atom_edited', 'atom_deleted', 'place_card_facts_edited',
        'place_card_status_changed', 'place_cards_merged', 'manual_recheck')),
    CONSTRAINT source_change_mark_ref_check CHECK (length(source_ref) <= 128),
    CONSTRAINT source_change_mark_hits_check CHECK (hits >= 1),
    CONSTRAINT source_change_mark_order_check CHECK (object_created_at <= changed_at),
    CONSTRAINT source_change_mark_details_check CHECK (jsonb_typeof(details) = 'object'),
    CONSTRAINT source_change_mark_cleared_check CHECK (
        (cleared_at IS NULL) = (cleared_by IS NULL) AND (cleared_by IS NULL OR length(cleared_by) <= 128))
);

CREATE UNIQUE INDEX IF NOT EXISTS source_change_mark_open_key
    ON shared.source_change_mark (object_kind, object_id, source_kind, source_ref) WHERE cleared_at IS NULL;
CREATE INDEX IF NOT EXISTS source_change_mark_tour_idx ON shared.source_change_mark (tour_id, detected_at DESC);
CREATE INDEX IF NOT EXISTS source_change_mark_object_idx ON shared.source_change_mark (object_kind, object_id);

COMMENT ON TABLE shared.source_change_mark IS
    'AA-1052 (CIS 392, root ADR 0020 W6): the source-change fan-out. One open row per stored writer object (s1 Master '
    'version, t2 tenant version, t9 piece) written before a source it read changed (raw tour, Master, atom, place '
    'card), with a typed reason. Written by job kind source_fanout ($0, no model call, never changes the object), read '
    'by GET /admin/quality/lineage/fanout/{tour_id}. Ids only, no text, no tenant column.';
COMMENT ON COLUMN shared.source_change_mark.source_ref IS
    'AA-1052 (392): the atom_id, place card id or new published_tours id of the change; empty = the whole tour.';
COMMENT ON COLUMN shared.source_change_mark.details IS
    'AA-1052 (392): ids and field names only (the fs_id the object read, the raw fields edited, the atom ids it cites).';
COMMENT ON COLUMN shared.source_change_mark.cleared_at IS
    'AA-1052 (392): set (with cleared_by) when a person or a later check closes the mark; NULL = open.';

GRANT SELECT, INSERT, UPDATE, DELETE ON shared.source_change_mark TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('392', now(), 'AA-1052: shared.source_change_mark (source-change fan-out marks of the writer objects)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
