-- migrate: expand
-- Migration crm-061: AA-960 (design v3 §6.3 card CRM-29b; R3 tags + tag workflows, R29 system-tag workflows, R36
-- ready to travel again) — the agency's tags on trips and clients and the system tags the app computes.
--
-- Owner: AA-Partner (api/migrations/061_crm_tags.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy Migration
-- Apply runs (Migration Copy Guard). Key crm-061 (crm-059 and crm-060 came before it in the same wave); if main moves,
-- renumber: file name, this header, the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS and the tests that name
-- it (git grep '061_' and 'crm-061').
--
-- What (DM-7.1: root data standards Part B §7 rows added with this key):
--   1. crm.tag (base template): one tag of the agency's vocabulary. kind agency (the agency's own words: VIP,
--      Honeymoon, Repeat client) | system (computed by the app and never set by hand: the AA catalogue facets of a
--      trip's AA tours, R29, and "ready to travel again", R36); applies_to trip | client; code (^[a-z][a-z0-9_]{0,39}$,
--      fixed once made: the conditions of a workflow name it; a system code starts with sys_, an agency code never
--      does); name (1..60 characters, the agency's wording, the app's English label for a system tag; the editor says
--      no client data goes in a tag name); tone (one of the kit badge tones); archived_at (an agency tag no longer
--      offered; its links stay). One tag per (agency, applies_to, code). Never trashed: removing a tag deletes it and
--      its links. Agency wording, no personal data. Cascades from the agency's crm.tenant_settings row (the agency
--      erase deletes it).
--   2. crm.tag_link (base template): one tag on one trip or one client (exactly one of trip_id / traveler_id, the
--      tag's applies_to); source member (a member put it there) | system (the app's refresh did, with its reasons: a
--      JSON array of codes and numbers, at most 2000 bytes, NULL on a member's link). One link per (tag, trip) and per
--      (tag, client). Never trashed: removing a tag from a record deletes the link. Ids and codes, no personal data
--      (the link says which agency tag a client carries; the export of a client takes it). Cascades from its tag, its
--      trip and its client.
--   3. crm.guard_tag() and crm.guard_tag_link() (SQLSTATE CRM55): a crm_app session writes a system tag or a system
--      link only as a job:, platform: or seed: actor (system_tag_app_only); a tag's kind, applies_to and code and a
--      link's tag, subject and source never change (tag_fixed); a link names the subject its tag applies to
--      (tag_subject_mismatch) and has the tag's source (a system tag only from the app, an agency tag only from a
--      member: tag_source_mismatch). A cascade (trigger depth > 1) and crm_owner pass.
--   4. Hold rule 4h on crm.tag_link: crm.guard_held_travel_doc() (crm-054 / crm-058): a delete or a move of a link of
--      a held trip or client of the agency is refused (CRM10), also inside a cascade.
--   5. Erasure without a replaced crm.erase_subject: every foreign key of the new tables cascades from a row the erase
--      already deletes (tests/integration/test_crm010_schema.py CASCADE_ERASED lists both with their parents).
--   6. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles) on both tables; crm_app keeps the default DML of
--      crm-001; no reader grant (AI context, insights and support never read them).
--
-- Class: expand (root ADR 0017 d3): two new tables and two new trigger functions with their constraints, indexes,
-- triggers (plus the existing hold guard function), policies and comments; foreign keys from the new tables only; no
-- change to an existing object, no DO block, no CREATE OR REPLACE. Not re-runnable by itself (plain CREATE POLICY /
-- TRIGGER / FUNCTION); Migration Apply never applies a registered key again and the test conftest skips it. Ships in
-- its own migration-only PR, applied before the code PR (the code PR raises the readiness to crm-061).
--
-- Rollback (a forward crm- file, after the code that reads them is reverted): DROP TABLE crm.tag_link, crm.tag;
-- DROP FUNCTION crm.guard_tag_link(), crm.guard_tag().
--
-- Runs as crm_owner (Migration Apply / DB Migrate switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- ── 1. crm.tag ───────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.tag (
    tag_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                REFERENCES crm.tenant (tenant_id),
    kind        TEXT NOT NULL DEFAULT 'agency',
    applies_to  TEXT NOT NULL,
    code        TEXT NOT NULL,
    name        TEXT NOT NULL,
    tone        TEXT NOT NULL DEFAULT 'neutral',
    archived_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ,
    deleted_by  TEXT,
    purge_after TIMESTAMPTZ,
    CONSTRAINT tag_tenant_id_uq UNIQUE (tenant_id, tag_id),
    CONSTRAINT tag_settings_fk FOREIGN KEY (tenant_id)
        REFERENCES crm.tenant_settings (tenant_id) ON DELETE CASCADE,
    CONSTRAINT tag_values_chk CHECK (
        kind IN ('agency', 'system')
        AND applies_to IN ('trip', 'client')
        AND code ~ '^[a-z][a-z0-9_]{0,39}$'
        AND (kind = 'system') = (code ~ '^sys_')
        AND char_length(name) BETWEEN 1 AND 60 AND name = btrim(name) AND name !~ '[[:cntrl:]]'
        AND tone IN ('neutral', 'accent', 'success', 'warning', 'danger', 'info', 'purple')
        AND (kind = 'agency' OR archived_at IS NULL)
    ),
    CONSTRAINT tag_never_trashed_chk CHECK (deleted_at IS NULL),
    CONSTRAINT tag_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS tag_code_uq ON crm.tag (tenant_id, applies_to, code);
ALTER TABLE crm.tag ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.tag FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.tag
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER tag_set_updated_at
    BEFORE UPDATE ON crm.tag
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
-- CRM55 (crm-054 used CRM53, crm-056 CRM54): a system tag is the app's; what a tag is (kind, subject, code) is fixed.
CREATE FUNCTION crm.guard_tag() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_app boolean := COALESCE(current_setting('app.actor', true), '') ~ '^(job|platform|seed):';
BEGIN
    IF pg_catalog.pg_trigger_depth() > 1 OR current_user::text <> 'crm_app' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'UPDATE' AND (NEW.kind, NEW.applies_to, NEW.code) IS DISTINCT FROM (OLD.kind, OLD.applies_to, OLD.code)
    THEN
        RAISE EXCEPTION 'crm: tag_fixed (a tag keeps its kind, subject and code)' USING ERRCODE = 'CRM55';
    END IF;
    IF NOT v_app AND ((TG_OP <> 'INSERT' AND OLD.kind = 'system') OR (TG_OP <> 'DELETE' AND NEW.kind = 'system')) THEN
        RAISE EXCEPTION 'crm: system_tag_app_only (system tags are computed by the app)' USING ERRCODE = 'CRM55';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
COMMENT ON FUNCTION crm.guard_tag() IS 'AA-960 (crm-061): CRM55 tag_fixed when an update changes a tag''s kind, applies_to or code; CRM55 system_tag_app_only when a crm_app session that is not a job:, platform: or seed: actor inserts, updates or deletes a system tag. A cascade (trigger depth > 1) and crm_owner pass. Invoker rights.';
CREATE TRIGGER tag_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.tag
    FOR EACH ROW EXECUTE FUNCTION crm.guard_tag();
COMMENT ON TABLE crm.tag IS 'AA-960 (crm-061, R3 / R29 / R36): one tag of the agency''s vocabulary: kind agency (the agency''s own words) | system (computed by the app: AA catalogue facets of a trip''s AA tours, ready to travel again; guard CRM55), applies_to trip | client, code (fixed; workflow conditions name it; system codes start with sys_), name (agency wording, no client data), tone (a kit badge tone), archived_at (an agency tag no longer offered). One tag per agency, subject and code. Never trashed: removing a tag deletes it and its links. Cascades from the agency''s tenant_settings row.';
COMMENT ON COLUMN crm.tag.code IS 'the tag''s fixed key (^[a-z][a-z0-9_]{0,39}$): a workflow condition tags_any names it; sys_ prefix = a system tag';
COMMENT ON COLUMN crm.tag.name IS 'the agency''s wording of the tag (1..60 characters; the app''s English label for a system tag, the web words system tags itself); agency vocabulary, never client data';

-- ── 2. crm.tag_link ──────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.tag_link (
    tag_link_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                REFERENCES crm.tenant (tenant_id),
    tag_id      UUID NOT NULL,
    trip_id     UUID,
    traveler_id UUID,
    source      TEXT NOT NULL DEFAULT 'member',
    reasons     JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ,
    deleted_by  TEXT,
    purge_after TIMESTAMPTZ,
    CONSTRAINT tag_link_tenant_id_uq UNIQUE (tenant_id, tag_link_id),
    CONSTRAINT tag_link_tag_fk FOREIGN KEY (tenant_id, tag_id)
        REFERENCES crm.tag (tenant_id, tag_id) ON DELETE CASCADE,
    CONSTRAINT tag_link_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT tag_link_traveler_fk FOREIGN KEY (tenant_id, traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id) ON DELETE CASCADE,
    CONSTRAINT tag_link_subject_chk CHECK (num_nonnulls(trip_id, traveler_id) = 1),
    CONSTRAINT tag_link_values_chk CHECK (
        source IN ('member', 'system')
        AND (reasons IS NULL OR (jsonb_typeof(reasons) = 'array' AND octet_length(reasons::text) <= 2000))
        AND (source = 'system' OR reasons IS NULL)
    ),
    CONSTRAINT tag_link_never_trashed_chk CHECK (deleted_at IS NULL),
    CONSTRAINT tag_link_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS tag_link_trip_uq ON crm.tag_link (tenant_id, tag_id, trip_id)
    WHERE trip_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS tag_link_traveler_uq ON crm.tag_link (tenant_id, tag_id, traveler_id)
    WHERE traveler_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS tag_link_trip_idx ON crm.tag_link (trip_id) WHERE trip_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS tag_link_traveler_idx ON crm.tag_link (traveler_id) WHERE traveler_id IS NOT NULL;
ALTER TABLE crm.tag_link ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.tag_link FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.tag_link
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER tag_link_set_updated_at
    BEFORE UPDATE ON crm.tag_link
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE FUNCTION crm.guard_tag_link() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_app boolean := COALESCE(current_setting('app.actor', true), '') ~ '^(job|platform|seed):';
    v_kind text;
    v_applies text;
BEGIN
    IF pg_catalog.pg_trigger_depth() > 1 OR current_user::text <> 'crm_app' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'DELETE' THEN
        IF OLD.source = 'system' AND NOT v_app THEN
            RAISE EXCEPTION 'crm: system_tag_app_only (system tags are computed by the app)' USING ERRCODE = 'CRM55';
        END IF;
        RETURN OLD;
    END IF;
    IF TG_OP = 'UPDATE' AND (NEW.tag_id, NEW.trip_id, NEW.traveler_id, NEW.source)
                            IS DISTINCT FROM (OLD.tag_id, OLD.trip_id, OLD.traveler_id, OLD.source) THEN
        RAISE EXCEPTION 'crm: tag_fixed (a tag link keeps its tag, subject and source)' USING ERRCODE = 'CRM55';
    END IF;
    IF NEW.source = 'system' AND NOT v_app THEN
        RAISE EXCEPTION 'crm: system_tag_app_only (system tags are computed by the app)' USING ERRCODE = 'CRM55';
    END IF;
    SELECT t.kind, t.applies_to INTO v_kind, v_applies
      FROM crm.tag t WHERE t.tenant_id = NEW.tenant_id AND t.tag_id = NEW.tag_id;
    IF NOT FOUND THEN
        RETURN NEW;  -- the foreign key refuses it
    END IF;
    IF (v_applies = 'trip') <> (NEW.trip_id IS NOT NULL) THEN
        RAISE EXCEPTION 'crm: tag_subject_mismatch (a % tag goes on a %)', v_applies, v_applies USING ERRCODE = 'CRM55';
    END IF;
    IF (v_kind = 'system') <> (NEW.source = 'system') THEN
        RAISE EXCEPTION 'crm: tag_source_mismatch (a % tag is set by %)', v_kind,
            CASE WHEN v_kind = 'system' THEN 'the app' ELSE 'a member' END USING ERRCODE = 'CRM55';
    END IF;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION crm.guard_tag_link() IS 'AA-960 (crm-061): CRM55 when a crm_app session puts a link of the wrong subject (tag_subject_mismatch: a trip tag on a client or the reverse) or source (tag_source_mismatch: a system tag from a member, an agency tag from the app), changes a link''s tag, trip, client or source (tag_fixed), or writes or deletes a system link as an actor that is not job:, platform: or seed: (system_tag_app_only). A cascade (trigger depth > 1) and crm_owner pass. Invoker rights; reads the tag of the row''s own agency.';
CREATE TRIGGER tag_link_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.tag_link
    FOR EACH ROW EXECUTE FUNCTION crm.guard_tag_link();
CREATE TRIGGER tag_link_hold_guard
    BEFORE DELETE OR UPDATE ON crm.tag_link
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_travel_doc();
COMMENT ON TABLE crm.tag_link IS 'AA-960 (crm-061, R3 / R29 / R36): one tag on one trip or one client (exactly one of trip_id / traveler_id, the tag''s applies_to; guard CRM55), source member | system (the app''s refresh, with its reasons as a JSON array of codes and numbers). One link per tag and subject. Never trashed: removing a tag from a record deletes the link. Hold rule 4h (crm.guard_held_travel_doc, CRM10). Every foreign key cascades (tag, trip, traveller). No reader grant.';
COMMENT ON COLUMN crm.tag_link.reasons IS 'a system link''s reasons: a JSON array of {code, ...numbers / codes} (for example the months since the last trip of a ready-to-travel client); NULL on a member''s link; no free text';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-061', now(), 'AA-960: tags: crm.tag (agency and system tags of trips and clients), crm.tag_link (one tag on one trip or client, member or system with reasons); guards crm.guard_tag, crm.guard_tag_link (CRM55), hold rule 4h on crm.tag_link')
ON CONFLICT (version) DO NOTHING;

COMMIT;
