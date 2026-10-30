-- migrate: expand
-- Migration 313: AA-921 (WM-27) — writing-memory Pinned Exemplars: shared.writing_exemplar (the pool of entity-masked
-- voice examples, platform or tenant) and shared.writing_memory_release_exemplar (the two examples per channel a
-- release pins, fixed at draft time).
--
-- Why. App ADR 0010 / S245 decisions E3 and D12: T2 and T9 learn a tenant's voice from two pinned, entity-masked
-- examples chosen inside a release, never from per-call nearest-neighbour retrieval (no embeddings, no ivfflat, no
-- kNN). The release shows exactly what will run; no runtime lookup can pick a wrong paragraph. A1 (S1) gets no example
-- (E3). Examples are tenant text: they live only in deletable, RLS-forced tables (ADR 0010 decision 11).
--
-- What. Two new tables in shared (tenant text, RLS ENABLE + FORCE, the CIS 280 / 287 policy shape):
--   1. shared.writing_exemplar: one masked example. exemplar_id; scope platform | tenant with tenant_id NULL exactly
--      for platform; writer t2 | t9_blog | t9_social (never a1: E3); channel (the T9 channel, `tour_page` for T2);
--      masked_text (pii:free_text, <= 2000 characters: the excerpt the prompt shows, numbers, prices, times, links and
--      names masked as [N], [PRICE], [TIME], [URL], [NAME]); text_sha256 and word_count of the masked text; the source
--      (source_table content_piece | tenant_tour_version | generated_content, source_id, source_signal_id: the
--      "use as example" signal of WM-07, no FK: signals and examples go with the tenant together); status candidate |
--      pinned | never (pinned: an admin keeps it in the next draft release; never: an admin excluded it for good),
--      status_reason / status_by / status_at (the last pin / unpin / never, with the admin's reason); created_at,
--      updated_at. One row per (writer, channel, owner, masked text) (writing_exemplar_text_uq: a refresh is
--      idempotent).
--   2. shared.writing_memory_release_exemplar: one example pinned in one release. release_id (FK, ON DELETE CASCADE:
--      a release erased with its tenant takes its links), exemplar_id (FK, ON DELETE CASCADE: an erased example leaves
--      the release's items hash unmatched, so the writer renders nothing from that release part: fail closed), the
--      release's writer / scope / tenant_id (RLS and the erasure key), channel and position (1 or 2: at most two per
--      channel). Trigger shared.writing_memory_release_exemplar_guard (BEFORE INSERT OR UPDATE): a link is never
--      updated; it is written only in the transaction that created its release (created_at = now(): the items hash is
--      computed at draft time and fixed after, CIS 287), only for a `rules` release (its activation needs an R2 pass
--      and a shadow pass, CIS 287 CHECK + trigger), never for A1; the example has the release's writer, channel and
--      owner (a tenant release links only its own tenant's examples; a platform release only platform examples) and is
--      not `never`. Deleting a link is allowed (the erasure, the FK cascades).
--   RLS on both: <t>_cis_app_all / <t>_cis_owner_all USING (true) (X1 parity: cis_app code filters tenant_id
--   explicitly), tenant_isolation TO aa_app_user (the tenant pool holds no privilege: tenants never see examples; the
--   policy is the floor if one is ever granted).
--   Grants: cis_app SELECT, INSERT, UPDATE, DELETE on writing_exemplar (DELETE: the AA-839 erasure and the AA-923
--   offboarding); SELECT, INSERT, DELETE on the link table. Nothing for aa_app_user or catalog_owner.
--
-- Class: expand (root ADR 0017 d3): two new tables with their indexes, RLS flags, policies, one new trigger function
-- and its trigger on the new link table, grants and comments; no change to any existing object (the FK from the new
-- link table adds only the internal RI triggers on shared.writing_memory_release), no DO block, no REVOKE.
-- Auto-applied on Dev by the AA-CIS-Infra migration-apply pipeline after the app PR merges, before Deploy Dev's
-- schema gate lets the code roll (readiness.REQUIRED_CIS_SCHEMA = 313 in the same PR).
--
-- Number. 312 is the highest on main (S260, gateway S5 / S6); this is main max + 1. If main moves before the merge,
-- renumber to main max + 1 (file name, this header, the registration below, readiness, tests, CONTEXT.md).
--
-- Rollback (a new forward migration, after the code that reads them is reverted):
--   DROP TABLE shared.writing_memory_release_exemplar; DROP TABLE shared.writing_exemplar;
--   DROP FUNCTION shared.writing_memory_release_exemplar_guard();
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared,
-- which then owns the tables and the function.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE shared.writing_exemplar (
    exemplar_id       uuid NOT NULL DEFAULT gen_random_uuid(),
    scope             text NOT NULL,
    tenant_id         uuid,
    writer            text NOT NULL,
    channel           text NOT NULL,
    masked_text       text NOT NULL,
    text_sha256       text NOT NULL,
    word_count        integer NOT NULL,
    source_table      text NOT NULL,
    source_id         text NOT NULL,
    source_signal_id  uuid,
    status            text NOT NULL DEFAULT 'candidate',
    status_reason     text,
    status_by         text,
    status_at         timestamp with time zone,
    created_at        timestamp with time zone NOT NULL DEFAULT now(),
    updated_at        timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT writing_exemplar_pkey PRIMARY KEY (exemplar_id),
    CONSTRAINT writing_exemplar_scope_check CHECK (scope IN ('platform', 'tenant')),
    CONSTRAINT writing_exemplar_scope_tenant_ck
        CHECK ((scope = 'platform' AND tenant_id IS NULL) OR (scope = 'tenant' AND tenant_id IS NOT NULL)),
    CONSTRAINT writing_exemplar_writer_check CHECK (writer IN ('t2', 't9_blog', 't9_social')),
    CONSTRAINT writing_exemplar_channel_check
        CHECK (channel ~ '^[a-z][a-z0-9_]{0,39}$' AND (writer <> 't2' OR channel = 'tour_page')
               AND (writer <> 't9_blog' OR channel = 'blog') AND (writer <> 't9_social' OR channel <> 'blog')),
    CONSTRAINT writing_exemplar_text_check
        CHECK (char_length(masked_text) BETWEEN 1 AND 2000 AND word_count BETWEEN 1 AND 400
               AND text_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT writing_exemplar_source_check
        CHECK (source_table IN ('content_piece', 'tenant_tour_version', 'generated_content')
               AND char_length(source_id) BETWEEN 1 AND 128),
    CONSTRAINT writing_exemplar_status_check CHECK (status IN ('candidate', 'pinned', 'never')),
    CONSTRAINT writing_exemplar_status_meta_check
        CHECK ((status = 'candidate' OR (status_by IS NOT NULL AND status_at IS NOT NULL AND status_reason IS NOT NULL))
               AND coalesce(char_length(status_reason), 0) <= 500 AND coalesce(char_length(status_by), 0) <= 128)
);
CREATE UNIQUE INDEX writing_exemplar_text_uq ON shared.writing_exemplar
    (writer, channel, scope, coalesce(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), text_sha256);
CREATE INDEX writing_exemplar_tenant_status_idx ON shared.writing_exemplar (tenant_id, status)
    WHERE scope = 'tenant';
CREATE INDEX writing_exemplar_writer_channel_idx ON shared.writing_exemplar (writer, channel, status, created_at DESC);
CREATE INDEX writing_exemplar_source_idx ON shared.writing_exemplar (source_table, source_id);

COMMENT ON TABLE shared.writing_exemplar IS
    'AA-921 WM-27 (CIS 313, app ADR 0010, E3 / D12): the pool of entity-masked voice examples for T2 and T9 (never '
    'A1). A release pins two per writer and channel (shared.writing_memory_release_exemplar); no retrieval at write '
    'time. Tenant rows are tenant text (RLS forced, no tenant-pool privilege) and go with the tenant (AA-839 erasure, '
    'AA-923 offboarding).';
COMMENT ON COLUMN shared.writing_exemplar.masked_text IS
    'pii:free_text — AA-921 (313): the excerpt the prompt shows, labelled "voice only, reuse no fact"; numbers, '
    'prices, times, links and names masked ([N], [PRICE], [TIME], [URL], [NAME]).';
COMMENT ON COLUMN shared.writing_exemplar.channel IS
    'AA-921 (313): the T9 channel (blog, facebook, linkedin, ...); tour_page for T2.';
COMMENT ON COLUMN shared.writing_exemplar.source_signal_id IS
    'AA-921 (313): the "use as example" writing_signal (WM-07) that proposed it; no FK (both go with the tenant).';
COMMENT ON COLUMN shared.writing_exemplar.status IS
    'AA-921 (313): candidate (eligible), pinned (an admin keeps it in the next draft), never (excluded for good).';

CREATE TABLE shared.writing_memory_release_exemplar (
    release_id   uuid NOT NULL,
    exemplar_id  uuid NOT NULL,
    writer       text NOT NULL,
    scope        text NOT NULL,
    tenant_id    uuid,
    channel      text NOT NULL,
    position     smallint NOT NULL,
    created_at   timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT writing_memory_release_exemplar_pkey PRIMARY KEY (release_id, exemplar_id),
    CONSTRAINT writing_memory_release_exemplar_release_fkey FOREIGN KEY (release_id)
        REFERENCES shared.writing_memory_release (release_id) ON DELETE CASCADE,
    CONSTRAINT writing_memory_release_exemplar_exemplar_fkey FOREIGN KEY (exemplar_id)
        REFERENCES shared.writing_exemplar (exemplar_id) ON DELETE CASCADE,
    CONSTRAINT writing_memory_release_exemplar_scope_tenant_ck
        CHECK ((scope = 'platform' AND tenant_id IS NULL) OR (scope = 'tenant' AND tenant_id IS NOT NULL)),
    CONSTRAINT writing_memory_release_exemplar_writer_check CHECK (writer IN ('t2', 't9_blog', 't9_social')),
    CONSTRAINT writing_memory_release_exemplar_position_check CHECK (position IN (1, 2))
);
CREATE UNIQUE INDEX writing_memory_release_exemplar_slot_uq ON shared.writing_memory_release_exemplar
    (release_id, channel, position);
CREATE INDEX writing_memory_release_exemplar_exemplar_idx ON shared.writing_memory_release_exemplar (exemplar_id);
CREATE INDEX writing_memory_release_exemplar_tenant_idx ON shared.writing_memory_release_exemplar (tenant_id)
    WHERE scope = 'tenant';

COMMENT ON TABLE shared.writing_memory_release_exemplar IS
    'AA-921 WM-27 (CIS 313): the examples a release pins (<= 2 per channel), written in the draft''s own transaction '
    'and part of its items hash; never updated (trigger writing_memory_release_exemplar_guard). Ids only.';

CREATE FUNCTION shared.writing_memory_release_exemplar_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $fn$
DECLARE
    rel  record;
    ex   record;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'writing_memory_release_exemplar: a pinned example is never changed (delete and redraft)'
            USING ERRCODE = 'restrict_violation';
    END IF;
    SELECT r.writer, r.scope, r.tenant_id, r.status, r.content_class, r.created_at
      INTO rel FROM shared.writing_memory_release r WHERE r.release_id = NEW.release_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'writing_memory_release_exemplar: release % does not exist', NEW.release_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF rel.status <> 'draft' OR rel.created_at <> now() THEN
        RAISE EXCEPTION 'writing_memory_release_exemplar: examples are pinned only in the transaction that drafts the '
                        'release (its items hash is fixed at draft time)' USING ERRCODE = 'restrict_violation';
    END IF;
    IF rel.content_class <> 'rules' OR rel.writer = 'a1' THEN
        RAISE EXCEPTION 'writing_memory_release_exemplar: only a rules release of T2 or T9 pins examples (got % %)',
                        rel.writer, rel.content_class USING ERRCODE = 'check_violation';
    END IF;
    SELECT e.writer, e.channel, e.scope, e.tenant_id, e.status
      INTO ex FROM shared.writing_exemplar e WHERE e.exemplar_id = NEW.exemplar_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'writing_memory_release_exemplar: example % does not exist', NEW.exemplar_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF ex.status = 'never' THEN
        RAISE EXCEPTION 'writing_memory_release_exemplar: example % is marked never use', NEW.exemplar_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.writer IS DISTINCT FROM rel.writer OR NEW.scope IS DISTINCT FROM rel.scope
       OR NEW.tenant_id IS DISTINCT FROM rel.tenant_id OR ex.writer IS DISTINCT FROM rel.writer
       OR ex.scope IS DISTINCT FROM rel.scope OR ex.tenant_id IS DISTINCT FROM rel.tenant_id
       OR ex.channel IS DISTINCT FROM NEW.channel THEN
        RAISE EXCEPTION 'writing_memory_release_exemplar: example % is not a % % example of this owner',
                        NEW.exemplar_id, rel.writer, NEW.channel USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$fn$;
COMMENT ON FUNCTION shared.writing_memory_release_exemplar_guard() IS
    'AA-921 (CIS 313): a release pins only its own owner''s examples of its writer and channel, never a "never use" '
    'one, only in the draft''s own transaction, only for a rules release of T2 / T9; links are never updated.';

CREATE TRIGGER writing_memory_release_exemplar_guard
    BEFORE INSERT OR UPDATE ON shared.writing_memory_release_exemplar
    FOR EACH ROW EXECUTE FUNCTION shared.writing_memory_release_exemplar_guard();

ALTER TABLE shared.writing_exemplar ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.writing_exemplar FORCE ROW LEVEL SECURITY;
ALTER TABLE shared.writing_memory_release_exemplar ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.writing_memory_release_exemplar FORCE ROW LEVEL SECURITY;

CREATE POLICY writing_exemplar_cis_app_all ON shared.writing_exemplar AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
CREATE POLICY writing_exemplar_cis_owner_all ON shared.writing_exemplar AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
CREATE POLICY tenant_isolation ON shared.writing_exemplar AS PERMISSIVE FOR ALL TO aa_app_user
    USING (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.writing_exemplar IS
    'AA-921 (CIS 313): own tenant rows only, never a platform row; the tenant pool holds no privilege (tenants never '
    'see examples), the policy is the floor if one is ever granted.';

CREATE POLICY writing_memory_release_exemplar_cis_app_all ON shared.writing_memory_release_exemplar
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY writing_memory_release_exemplar_cis_owner_all ON shared.writing_memory_release_exemplar
    AS PERMISSIVE FOR ALL TO cis_owner USING (true) WITH CHECK (true);
CREATE POLICY tenant_isolation ON shared.writing_memory_release_exemplar AS PERMISSIVE FOR ALL TO aa_app_user
    USING (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.writing_memory_release_exemplar IS
    'AA-921 (CIS 313): own tenant rows only; no tenant-pool privilege today.';

GRANT SELECT, INSERT, UPDATE, DELETE ON shared.writing_exemplar TO cis_app;
GRANT SELECT, INSERT, DELETE ON shared.writing_memory_release_exemplar TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('313', now(), 'AA-921: shared.writing_exemplar + shared.writing_memory_release_exemplar (pinned exemplars)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
