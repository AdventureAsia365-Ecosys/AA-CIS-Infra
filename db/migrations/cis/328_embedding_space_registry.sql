-- Migration 328: AA-1026 D5 (AI gateway v2, S263 gap OPS-13) — the embedding space registry: which model, dimension
-- and input types produced the vectors of every vector column, so a model change is a data change plus a re-embed,
-- never a silent mix of two vector spaces in one column.
--
-- Why. Five vector(1536) columns hold Cohere Embed v4 vectors (stages f10_embed and a3_place_embed; TripPlanner embeds
-- its search queries with the same model, tp_search_embed). Nothing in the schema says so: the model is a route row
-- (shared.llm_role_config) that an admin can change, and a vector from another model compared with these is
-- meaningless (same dimension) or an error (another dimension). The S263 audit (OPS-13, corrected) also found the
-- weakness is one embedding model and vendor, not one account (cohere-embed-v4-acc3 is the same space on acc3).
-- Tech lead decision T-15 (S263): registry first ($0), a ready fallback model of another vendor, a re-embed runbook.
--
-- What. Two new tables in shared (no change to any existing object):
--   shared.embedding_space: one row per vector space — space_key '<model>/<dimension>/v<version>', the model family
--     and vendor model id, the catalog keys that produce vectors IN this space (cohere-embed-v4 on acc2 and
--     cohere-embed-v4-acc3 on acc3 give the same vector; primary first), the dimension, the input types for stored
--     text (document) and for search text (query), the version and a status: active (a column serves it), standby (a
--     ready target for a re-embed, no column serves it), retired.
--   shared.embedding_column: one row per vector column — the column, its space, its swap group (columns that are
--     compared with each other, or written by one stage, change space together: f10_embed = atom, question and
--     content piece vectors), the key columns (re-embed batches and resume), the writer stages, the code key of the
--     re-embed text source (services/embeddings/sources.py; NULL = no source, cannot be re-embedded), and the shadow /
--     previous column of an ongoing or just finished re-embed (migration 329 functions write them).
--   Seeds: the active space cohere-embed-v4/1536/v1 and the standby space titan-embed-text-v2/1024/v1 (Amazon Titan
--   Text Embeddings V2, another vendor, on acc2 in us-west-2; its catalog / connection / deployment rows come with
--   migration 329, disabled), and the five vector columns of db-schema-reference (the views acp_contract.
--   v_trip_registry, catalog.v_component_embedding and catalog.v_tour_component only read them).
--   Grants: SELECT to cis_app (the gateway, the re-embed job, the admin listing) and catalog_owner (329's TripPlanner
--   view). Only a migration or the 329 functions (owner, DB Migrate run-script) change rows: the schema's default
--   privileges also give cis_app DML on new tables, and an expand file may not REVOKE, so 329 revokes it.
--
-- Class: expand (root ADR 0017 d3): two new tables, their seeds, grants and comments; no DO block, no change to an
-- existing object. Readiness is not raised: the code reads these rows with a built-in mirror as the fallback
-- (shared/llm_client/embedding_space.py), so it runs before and after the apply alike.
--
-- Number. Main max is 324 on 01/11/2026; S263 lanes hold 325-339. Renumber at merge to main max + 1 if needed
-- (file name, header, registration, tests, docs; `git grep '328_'` and `git grep '328'` must then be empty).
--
-- Rollback (a new forward migration, after the code that reads them is reverted and 329 is rolled back):
-- DROP TABLE shared.embedding_column; DROP TABLE shared.embedding_space;
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, which then owns the tables.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE shared.embedding_space (
    space_key            text NOT NULL,
    model_family         text NOT NULL,
    model_id             text NOT NULL,
    model_keys           text[] NOT NULL,
    dimension            integer NOT NULL,
    document_input_type  text,
    query_input_type     text,
    version              integer NOT NULL DEFAULT 1,
    status               text NOT NULL,
    notes                text,
    created_at           timestamp with time zone NOT NULL DEFAULT now(),
    updated_at           timestamp with time zone NOT NULL DEFAULT now(),
    updated_by           text NOT NULL,
    CONSTRAINT embedding_space_pkey PRIMARY KEY (space_key),
    CONSTRAINT embedding_space_key_check CHECK (space_key ~ '^[a-z0-9][a-z0-9.-]*/[0-9]{2,5}/v[0-9]{1,3}$'),
    CONSTRAINT embedding_space_key_matches_check CHECK (
        split_part(space_key, '/', 2) = dimension::text AND split_part(space_key, '/', 3) = 'v' || version::text),
    CONSTRAINT embedding_space_family_check CHECK (model_family ~ '^[a-z][a-z0-9-]{1,30}$'),
    CONSTRAINT embedding_space_model_id_check CHECK (length(model_id) BETWEEN 1 AND 200),
    CONSTRAINT embedding_space_model_keys_check CHECK (cardinality(model_keys) BETWEEN 1 AND 10),
    CONSTRAINT embedding_space_dimension_check CHECK (dimension BETWEEN 16 AND 4096),
    CONSTRAINT embedding_space_version_check CHECK (version BETWEEN 1 AND 999),
    CONSTRAINT embedding_space_status_check CHECK (status IN ('active', 'standby', 'retired'))
);

COMMENT ON TABLE shared.embedding_space IS
    'AA-1026 D5 (CIS 328): one row per embedding vector space. Vectors of two spaces are never compared or stored in '
    'one column; a model change is a new space + a re-embed into a shadow column (runbook embedding-re-embed).';
COMMENT ON COLUMN shared.embedding_space.model_keys IS
    'AA-1026 (328): shared.llm_model_catalog keys whose vectors are in this space (same model on other accounts), '
    'primary first. The gateway embed path only tries these for a column of this space.';
COMMENT ON COLUMN shared.embedding_space.document_input_type IS
    'AA-1026 (328): the input type for stored text (Cohere search_document); NULL = the model has none (Titan).';
COMMENT ON COLUMN shared.embedding_space.query_input_type IS
    'AA-1026 (328): the input type for search text compared with stored vectors (Cohere search_query); NULL = none.';
COMMENT ON COLUMN shared.embedding_space.status IS
    'AA-1026 (328): active (a column serves it) | standby (ready re-embed target) | retired.';

CREATE TABLE shared.embedding_column (
    table_schema         text NOT NULL,
    table_name           text NOT NULL,
    column_name          text NOT NULL,
    space_key            text NOT NULL,
    swap_group           text NOT NULL,
    key_columns          text[] NOT NULL,
    writer_stages        text[] NOT NULL DEFAULT '{}'::text[],
    source_key           text,
    shadow_column        text,
    shadow_space_key     text,
    previous_column      text,
    previous_space_key   text,
    readers              text,
    notes                text,
    updated_at           timestamp with time zone NOT NULL DEFAULT now(),
    updated_by           text NOT NULL,
    CONSTRAINT embedding_column_pkey PRIMARY KEY (table_schema, table_name, column_name),
    CONSTRAINT embedding_column_space_fkey FOREIGN KEY (space_key) REFERENCES shared.embedding_space (space_key),
    CONSTRAINT embedding_column_shadow_space_fkey FOREIGN KEY (shadow_space_key)
        REFERENCES shared.embedding_space (space_key),
    CONSTRAINT embedding_column_previous_space_fkey FOREIGN KEY (previous_space_key)
        REFERENCES shared.embedding_space (space_key),
    CONSTRAINT embedding_column_swap_group_check CHECK (swap_group ~ '^[a-z][a-z0-9_]{1,40}$'),
    CONSTRAINT embedding_column_key_columns_check CHECK (cardinality(key_columns) BETWEEN 1 AND 4),
    CONSTRAINT embedding_column_source_key_check CHECK (source_key IS NULL OR source_key ~ '^[a-z][a-z0-9_]{1,40}$'),
    CONSTRAINT embedding_column_shadow_check CHECK (
        (shadow_column IS NULL) = (shadow_space_key IS NULL)
        AND (shadow_column IS NULL OR shadow_column = column_name || '__shadow')
        AND shadow_space_key IS DISTINCT FROM space_key),
    CONSTRAINT embedding_column_previous_check CHECK (
        (previous_column IS NULL) = (previous_space_key IS NULL)
        AND (previous_column IS NULL OR previous_column = column_name || '__prev')
        AND previous_space_key IS DISTINCT FROM space_key)
);
CREATE INDEX embedding_column_space_idx ON shared.embedding_column (space_key);
CREATE INDEX embedding_column_group_idx ON shared.embedding_column (swap_group);

COMMENT ON TABLE shared.embedding_column IS
    'AA-1026 D5 (CIS 328): the space of every vector column. Writers and searches read it (one space per column, one '
    'space per query); the re-embed job fills shadow_column; shared.embedding_swap (329) swaps a whole swap_group.';
COMMENT ON COLUMN shared.embedding_column.swap_group IS
    'AA-1026 (328): columns compared with each other or written by one stage; they always share a space and swap '
    'together.';
COMMENT ON COLUMN shared.embedding_column.source_key IS
    'AA-1026 (328): the re-embed text source in code (services/embeddings/sources.py); NULL = cannot be re-embedded.';
COMMENT ON COLUMN shared.embedding_column.shadow_column IS
    'AA-1026 (328): <column>__shadow while a re-embed into shadow_space_key runs (329 embedding_prepare_shadow).';
COMMENT ON COLUMN shared.embedding_column.previous_column IS
    'AA-1026 (328): <column>__prev after a swap, the old vectors kept for a rollback until embedding_drop_previous.';

INSERT INTO shared.embedding_space
    (space_key, model_family, model_id, model_keys, dimension, document_input_type, query_input_type, version,
     status, notes, updated_by)
VALUES
    ('cohere-embed-v4/1536/v1', 'cohere', 'cohere.embed-v4:0', ARRAY['cohere-embed-v4', 'cohere-embed-v4-acc3'],
     1536, 'search_document', 'search_query', 1, 'active',
     'Cohere Embed v4, output_dimension 1536, float. acc2 (global profile) and acc3 give the same vector.',
     'migration-328-aa1026'),
    ('titan-embed-text-v2/1024/v1', 'amazon', 'amazon.titan-embed-text-v2:0', ARRAY['titan-embed-text-v2'],
     1024, NULL, NULL, 1, 'standby',
     'Amazon Titan Text Embeddings V2, dimensions 1024, normalize true (no input type). Another vendor on acc2 '
     '(us-west-2, on demand): the fallback space. A column moves here only by a re-embed + swap.',
     'migration-328-aa1026');

INSERT INTO shared.embedding_column
    (table_schema, table_name, column_name, space_key, swap_group, key_columns, writer_stages, source_key, readers,
     notes, updated_by)
VALUES
    ('acp_contract', 'atom_embedding', 'embedding', 'cohere-embed-v4/1536/v1', 'f10_embed',
     ARRAY['atom_id', 'view'], ARRAY['f10_embed'], 'atom_view',
     'atom_matching.land_question_on_atom (question vectors against atom vectors)',
     'Two views per atom (place, place_action); text from acp_contract.tour_atoms.', 'migration-328-aa1026'),
    ('acp_contract', 'question_embedding', 'embedding', 'cohere-embed-v4/1536/v1', 'f10_embed',
     ARRAY['question_hash'], ARRAY['f10_embed'], 'question_text',
     'atom_matching (question cache, compared with atom_embedding)',
     'The smallest table: the T-15 re-embed test target.', 'migration-328-aa1026'),
    ('acp_shared', 'content_piece', 'content_embedding', 'cohere-embed-v4/1536/v1', 'f10_embed',
     ARRAY['piece_id'], ARRAY['f10_embed'], 'content_piece_text',
     'piece_similarity.find_similar_pieces (cannibalization gate, reuse)',
     'Text = content_text without citation tags; only rows that have a vector are re-embedded.',
     'migration-328-aa1026'),
    ('geo', 'tour_place', 'embedding', 'cohere-embed-v4/1536/v1', 'tour_place',
     ARRAY['component_id'], ARRAY['a3_place_embed'], 'tour_place_text',
     'catalog.v_component_embedding, catalog.v_tour_component; TripPlanner browse search (tp_search_embed query '
     'vectors) and suggestions',
     'Text = text_extract.', 'migration-328-aa1026'),
    ('gold_aa_internal', 'published_tours', 'content_embedding', 'cohere-embed-v4/1536/v1', 'published_tours',
     ARRAY['id'], ARRAY[]::text[], NULL,
     'acp_contract.v_trip_registry; scripts/calibrate_pgvector_threshold.py',
     'No writer in code since migration 041; values (if any) are of unknown origin. Not re-embeddable: a swap needs '
     'allow_missing and leaves the column empty.', 'migration-328-aa1026');

GRANT SELECT ON shared.embedding_space TO cis_app;
GRANT SELECT ON shared.embedding_column TO cis_app;
GRANT SELECT ON shared.embedding_space TO catalog_owner;
GRANT SELECT ON shared.embedding_column TO catalog_owner;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('328', now(), 'AA-1026 D5 embedding space registry: shared.embedding_space (cohere-embed-v4/1536/v1 active, '
                      'titan-embed-text-v2/1024/v1 standby) and shared.embedding_column (5 vector columns)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
