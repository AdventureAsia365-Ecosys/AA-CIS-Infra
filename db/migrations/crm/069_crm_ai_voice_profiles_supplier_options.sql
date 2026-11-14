-- Migration crm-069: AA-965 (design v3 §6.3 card CRM-33b; R10 AI reads supplier confirmations, R40 notes -> AA
-- options, R41 voice profiles; data-privacy-integrations §2.9 group H `ai_draft`, `voice_profile`) — the tables and the
-- AI stages behind the three CRM-33b features.
--
-- Owner: AA-Partner (api/migrations/069_crm_ai_voice_profiles_supplier_options.sql). AA-CIS-Infra db/migrations/crm/
-- holds the byte copy Migration Apply runs (Migration Copy Guard). Key crm-069: crm main max was crm-065 on 15/11/2026
-- and the other lanes of the S281 wave hold crm-066 .. crm-075; if the numbers move, renumber: file name, this header,
-- Guard 0 and the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS (code PR) and the tests that name it
-- (git grep '076_' and 'crm-069').
--
-- What (DM-7.1: crm.voice_profile already has its row in root data standards Part B §7, "while the agency is active;
-- hard delete at offboarding"; crm.ai_draft keeps its row):
--   1. crm.voice_profile (base template, R41): one writing voice of the agency, made by a member: name (1..60, the
--      agency's label, never client data), locale (en | vi), channel (email | whatsapp), descriptors (a JSON object of
--      fixed codes only, at most 1000 bytes: formality, warmth, length, emoji, greeting, sign_off; the API checks each
--      key and value against its closed list; the draft turns the codes into fixed sentences of ours, so no member text
--      ever reaches the model). How many voices one member may keep is the admin-editable setting
--      crm.ai.voice_profiles_per_member_max (the API checks it; not a database rule). Never trashed: delete is a hard
--      delete. Cascades from the agency's crm.tenant_settings row (the agency erase) and from its member.
--   2. crm.ai_draft (crm-040): kind + 'supplier_confirmation' (R10) and 'notes_to_options' (R40); voice_profile_id (the
--      voice a reply draft used, R41; no foreign key, like llm_call_id: a deleted voice leaves the id as history and
--      the draft stays with its trip); validation (R39 / R40: the code's check of the
--      model's answer: the lines or AA codes it kept, how many it rejected and why, as ids, codes and short supplier
--      references; a JSON object of at most 16 KB, placeholders kept, never restored at rest). The guard
--      crm.guard_ai_draft is unchanged: a member inserts (any column), then only the decision columns change once.
--   3. AI stages crm_supplier_confirm (R10) and crm_notes_options (R40), role writer: the profile and the route of
--      crm_draft_reply as they are when this file runs (copied, so both follow the route control in force: today
--      Amazon Nova Lite on acc2, crm-042). Platform configuration, no tenant column, no personal data.
--
-- Behaviour on apply: none for running code. No voice exists, no draft uses the new kinds or columns and no request
-- names the new stages until the AA-Partner code PR deploys (it raises the readiness to crm-069).
--
-- Class: contract (ALTER of crm.ai_draft: a replaced kind CHECK, two new columns and a new CHECK; config rows
-- in crm.llm_stage_profile / crm.llm_stage_route). No '-- migrate:' directive. MIG-4: this migration-only PR, applied
-- on Dev by Infra Migration Apply once every job table is idle (root ADR 0017a), then the code PR. No crm.erase_subject
-- change: crm.voice_profile cascades from crm.tenant_settings and crm.member, both of which the erase already deletes
-- (tests/integration/test_crm010_schema.py CASCADE_ERASED lists it).
--
-- Rollback (a NEW forward migration, after the code is reverted): DELETE FROM crm.llm_stage_profile WHERE stage IN
-- ('crm_supplier_confirm', 'crm_notes_options') (the routes cascade); DELETE FROM crm.ai_draft WHERE kind IN
-- ('supplier_confirmation', 'notes_to_options') as crm_owner; put back the crm-040 kind CHECK; ALTER TABLE crm.ai_draft
-- DROP COLUMN validation, DROP COLUMN voice_profile_id; DROP TABLE crm.voice_profile.
--
-- Runs as crm_owner (Migration Apply / DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (IF NOT
-- EXISTS, DROP … IF EXISTS before each ADD, ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-065 and the CRM-33a objects ────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-069: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-065') THEN
        RAISE EXCEPTION 'crm-069: crm-065 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-069' AND description NOT LIKE 'AA-965 CRM-33b:%') THEN
        RAISE EXCEPTION 'crm-069: the key crm-069 is already held by another migration (not AA-965): renumber one';
    END IF;
    IF to_regclass('crm.ai_draft') IS NULL OR to_regclass('crm.member') IS NULL
       OR to_regclass('crm.tenant_settings') IS NULL
       OR to_regprocedure('crm.guard_ai_draft()') IS NULL THEN
        RAISE EXCEPTION 'crm-069: crm.ai_draft (crm-040), crm.member or crm.tenant_settings is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM crm.llm_stage_profile WHERE stage = 'crm_draft_reply' AND role = 'writer') THEN
        RAISE EXCEPTION 'crm-069: the crm_draft_reply writer profile (crm-037) is missing';
    END IF;
END $$;

-- ── 1. crm.voice_profile (R41) ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.voice_profile (
    voice_profile_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    member_id        UUID NOT NULL,
    name             TEXT NOT NULL,
    locale           TEXT NOT NULL DEFAULT 'en',
    channel          TEXT NOT NULL DEFAULT 'email',
    descriptors      JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT voice_profile_tenant_id_uq UNIQUE (tenant_id, voice_profile_id),
    CONSTRAINT voice_profile_settings_fk FOREIGN KEY (tenant_id)
        REFERENCES crm.tenant_settings (tenant_id) ON DELETE CASCADE,
    CONSTRAINT voice_profile_member_fk FOREIGN KEY (tenant_id, member_id)
        REFERENCES crm.member (tenant_id, member_id) ON DELETE CASCADE,
    CONSTRAINT voice_profile_values_chk CHECK (
        char_length(name) BETWEEN 1 AND 60 AND name = btrim(name) AND name !~ '[[:cntrl:]]'
        AND locale IN ('en', 'vi')
        AND channel IN ('email', 'whatsapp')
        AND jsonb_typeof(descriptors) = 'object' AND octet_length(descriptors::text) <= 1000
    ),
    CONSTRAINT voice_profile_never_trashed_chk CHECK (deleted_at IS NULL),
    CONSTRAINT voice_profile_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS voice_profile_member_idx ON crm.voice_profile (tenant_id, member_id, created_at);

ALTER TABLE crm.voice_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.voice_profile FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.voice_profile;
CREATE POLICY tenant_isolation ON crm.voice_profile
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE OR REPLACE TRIGGER voice_profile_set_updated_at
    BEFORE UPDATE ON crm.voice_profile
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();

COMMENT ON TABLE crm.voice_profile IS 'AA-965 (crm-069, R41; data-privacy-integrations §2.9 group H): one writing voice of the agency, made by a member and offered on the AI reply draft: name (agency label, never client data), locale, channel, descriptors (fixed codes only: formality, warmth, length, emoji, greeting, sign_off; turned into fixed sentences by the draft, never member text). At most crm.ai.voice_profiles_per_member_max per member (API). Never trashed: delete is a hard delete. Cascades from the agency''s tenant_settings row and from its member. No reader role is granted it.';
COMMENT ON COLUMN crm.voice_profile.name IS 'AA-965 (crm-069): the agency''s label of the voice (1..60 characters); agency wording, never client data, never sent to a model';
COMMENT ON COLUMN crm.voice_profile.descriptors IS 'AA-965 (crm-069): a JSON object of fixed codes (formality formal|neutral|casual, warmth warm|neutral|direct, length short|medium|long, emoji none|light, greeting first_name|full_name|none, sign_off agent_name|agency_name|none), checked by the API; at most 1000 bytes; no free text';

-- ── 2. crm.ai_draft: the new kinds, the voice, the code's check ──────────────────────────────────
ALTER TABLE crm.ai_draft DROP CONSTRAINT IF EXISTS ai_draft_kind_chk;
ALTER TABLE crm.ai_draft ADD CONSTRAINT ai_draft_kind_chk
    CHECK (kind IN ('reply', 'follow_up', 'supplier_confirmation', 'notes_to_options'));
ALTER TABLE crm.ai_draft ADD COLUMN IF NOT EXISTS voice_profile_id UUID;
ALTER TABLE crm.ai_draft ADD COLUMN IF NOT EXISTS validation JSONB;
ALTER TABLE crm.ai_draft DROP CONSTRAINT IF EXISTS ai_draft_validation_chk;
ALTER TABLE crm.ai_draft ADD CONSTRAINT ai_draft_validation_chk CHECK (
    (validation IS NULL OR (jsonb_typeof(validation) = 'object' AND octet_length(validation::text) <= 16384))
    AND (voice_profile_id IS NULL OR kind IN ('reply', 'follow_up'))
);
COMMENT ON COLUMN crm.ai_draft.kind IS 'AA-1027 F3 / AA-965 (crm-040, crm-069): reply | follow_up (the message draft), supplier_confirmation (R10: a proposed update of the trip''s agency lines from one supplier''s confirmation), notes_to_options (R40: AA options picked from the day''s closed list)';
COMMENT ON COLUMN crm.ai_draft.voice_profile_id IS 'AA-965 (crm-069, R41): the voice a reply / follow-up draft was written in (NULL = none); no foreign key: a voice deleted since leaves the id as history';
COMMENT ON COLUMN crm.ai_draft.validation IS 'AA-965 (crm-069, R39 / R40): the code''s check of the model''s answer (the line ids or AA codes kept, the count and reasons of what was rejected, short supplier references with placeholders kept); ids, codes and numbers, never restored at rest; at most 16 KB';

-- ── 3. AI stages: copies of the crm_draft_reply profile and route (route control in force) ───────
INSERT INTO crm.llm_stage_profile (stage, role, is_active, max_attempts, route_deadline_s, degrade_mode, updated_by)
SELECT s.stage, 'writer', p.is_active, p.max_attempts, p.route_deadline_s, p.degrade_mode, 'migration:crm-069'
  FROM crm.llm_stage_profile p
 CROSS JOIN (VALUES ('crm_supplier_confirm'), ('crm_notes_options')) AS s (stage)
 WHERE p.stage = 'crm_draft_reply'
ON CONFLICT (stage) DO NOTHING;
INSERT INTO crm.llm_stage_route (stage, position, provider, model, family, price_in_per_mtok, price_out_per_mtok,
                                 is_enabled, updated_by)
SELECT s.stage, r.position, r.provider, r.model, r.family, r.price_in_per_mtok, r.price_out_per_mtok, r.is_enabled,
       'migration:crm-069'
  FROM crm.llm_stage_route r
 CROSS JOIN (VALUES ('crm_supplier_confirm'), ('crm_notes_options')) AS s (stage)
 WHERE r.stage = 'crm_draft_reply'
ON CONFLICT (stage, position) DO NOTHING;

-- ── Post-check: both stages exist with the draft's enabled route ─────────────────────────────────
DO $$
DECLARE
    v_draft int;
    v_bad text;
BEGIN
    SELECT count(*) INTO v_draft FROM crm.llm_stage_route WHERE stage = 'crm_draft_reply' AND is_enabled;
    SELECT string_agg(s.stage, ', ') INTO v_bad
      FROM (VALUES ('crm_supplier_confirm'), ('crm_notes_options')) AS s (stage)
     WHERE NOT EXISTS (SELECT 1 FROM crm.llm_stage_profile p WHERE p.stage = s.stage AND p.role = 'writer')
        OR (SELECT count(*) FROM crm.llm_stage_route r WHERE r.stage = s.stage AND r.is_enabled) <> v_draft;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'crm-069: stage % has no writer profile or not the draft''s % enabled route entries',
            v_bad, v_draft;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-069', now(), 'AA-965 CRM-33b: crm.voice_profile (R41 voices, fixed codes only, cascades from tenant_settings and member); crm.ai_draft kinds supplier_confirmation / notes_to_options + voice_profile_id + validation; AI stages crm_supplier_confirm and crm_notes_options copied from the crm_draft_reply profile and route')
ON CONFLICT (version) DO NOTHING;

COMMIT;
