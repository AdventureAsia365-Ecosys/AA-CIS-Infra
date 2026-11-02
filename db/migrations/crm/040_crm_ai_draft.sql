-- migrate: expand
-- Migration crm-040: AA-1027 slice F3 (S263 gateway plan F3, gap CRM-4; design v3 M14, R39 "AI drafts, humans send",
-- A-21 AI cards; data-privacy-integrations §2.9 group H `ai_draft`) — one row per AI draft a member asked for in the
-- trip workspace, and the member's decision on it (accept / discard, with an optional feedback code).
--
-- Owner: AA-Partner (api/migrations/040_crm_ai_draft.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-040, after crm-039 (AA-939); if main moves, renumber: file name,
-- this header, the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS.
--
-- What (DM-7.1: crm.ai_draft already has its row in root data standards Part B §7, "until the agency deletes the trip
-- or offboards"; this table stores no prompt, so the 30-day clear of ai_draft.prompt_scrubbed has nothing to clear):
--   1. crm.ai_draft (base template): the trip, the kind (reply | follow_up, the draft endpoint's kinds), the ledger row
--      of the call that wrote it (crm.llm_call.llm_call_id, no key: the ledger is purged after 180 days, the draft
--      stays with its trip), the prompt version, the draft as the model wrote it (placeholders in, never restored at
--      rest) under the agency's vault DEK (output_enc, AAD = tenant, ai_draft, output_enc, row id), the member's
--      decision (pending -> accepted | discarded, once), who decided and when, and a feedback code from a fixed list
--      (R39). One draft per ledger call.
--   2. The decision column is `decision`, not `status`: its one move (pending -> accepted | discarded) is held by the
--      guard below, so no crm.status_transition rows are seeded (seeding config rows would make this a contract file).
--   3. Erasure without a replaced crm.erase_subject (the crm-029 / crm-034 pattern): crm.ai_draft cascades from its
--      trip, so a trip or agency erase removes it and the agency erase's "nothing left" check finds none.
--      tests/integration/test_crm010_schema.py lists it as cascade-erased.
--   4. Write guard (SQLSTATE CRM47; crm-035 used CRM46): crm.guard_ai_draft — a draft is inserted by a member
--      (member:<id>) as pending; only its decision, feedback code, decided_at / decided_by (and updated_at) change, once,
--      from pending; no crm_app DELETE (a row leaves with its trip). A cascade (trigger depth > 1) and crm_owner pass.
--   5. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles); crm_app keeps the default DML of crm-001 (the guard
--      decides); no reader grant: AI context, insights and support never read a draft.
--
-- Class: expand (root ADR 0017 d3): one new table and one new trigger function with its constraints, indexes,
-- triggers, policy and comments; foreign keys from the new table (the RI triggers they add on crm.trip and crm.tenant
-- are allowed); no change to an existing object, no DO block, no CREATE OR REPLACE. DB Migrate never applies a
-- registered file twice and the test conftest skips it. The code PR carries this file and raises
-- REQUIRED_SCHEMA_VERSIONS to crm-040 (expand: one PR).
--
-- Rollback (a forward crm- file, after the code that reads it is reverted): DROP TABLE crm.ai_draft;
-- DROP FUNCTION crm.guard_ai_draft().
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- ── 1. crm.ai_draft ──────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.ai_draft (
    ai_draft_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                    REFERENCES crm.tenant (tenant_id),
    trip_id         UUID NOT NULL,
    kind            TEXT NOT NULL,
    llm_call_id     UUID NOT NULL,
    prompt_version  TEXT NOT NULL,
    output_enc      BYTEA NOT NULL,
    decision        TEXT NOT NULL DEFAULT 'pending',
    feedback_code   TEXT,
    decided_at      TIMESTAMPTZ,
    decided_by      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ,
    deleted_by      TEXT,
    purge_after     TIMESTAMPTZ,
    CONSTRAINT ai_draft_tenant_id_uq UNIQUE (tenant_id, ai_draft_id),
    CONSTRAINT ai_draft_call_uq UNIQUE (tenant_id, llm_call_id),
    CONSTRAINT ai_draft_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT ai_draft_kind_chk CHECK (kind IN ('reply', 'follow_up')),
    CONSTRAINT ai_draft_version_chk CHECK (prompt_version ~ '^[A-Za-z0-9._-]{1,40}$'),
    CONSTRAINT ai_draft_enc_chk CHECK (octet_length(output_enc) BETWEEN 30 AND 65536),
    -- pending until the member decides, once; feedback only with a decision, from the fixed list (R39).
    CONSTRAINT ai_draft_decision_chk CHECK (
        decision IN ('pending', 'accepted', 'discarded')
        AND (decision = 'pending') = (decided_at IS NULL)
        AND (decided_at IS NULL) = (decided_by IS NULL)
        AND (feedback_code IS NULL OR decision <> 'pending')
        AND (feedback_code IS NULL
             OR feedback_code IN ('good', 'wrong_facts', 'wrong_tone', 'not_relevant', 'too_long', 'other'))
    ),
    CONSTRAINT ai_draft_by_chk CHECK (decided_by IS NULL OR decided_by ~ '^[A-Za-z0-9:_-]{1,80}$'),
    CONSTRAINT ai_draft_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
-- The trip's drafts, newest first (the workspace panel and a later R39 report).
CREATE INDEX IF NOT EXISTS ai_draft_trip_idx ON crm.ai_draft (tenant_id, trip_id, created_at DESC);

ALTER TABLE crm.ai_draft ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.ai_draft FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.ai_draft
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE TRIGGER ai_draft_set_updated_at
    BEFORE UPDATE ON crm.ai_draft
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();

CREATE FUNCTION crm.guard_ai_draft() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    -- The columns a decision may change; everything else must stay as it was.
    v_decision_cols text[] := ARRAY['decision', 'feedback_code', 'decided_at', 'decided_by', 'updated_at'];
BEGIN
    -- A cascade from the trip (an erase or a trash purge, trigger depth > 1) passes: the trip's own rules ruled.
    IF pg_catalog.pg_trigger_depth() > 1 OR current_user = 'crm_owner' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF v_actor NOT LIKE 'member:%' THEN
            RAISE EXCEPTION 'crm: ai_draft_guard (a draft is asked for by a member, actor %)', v_actor
                USING ERRCODE = 'CRM47';
        END IF;
        IF NEW.decision <> 'pending' THEN
            RAISE EXCEPTION 'crm: ai_draft_guard (a new draft is pending)' USING ERRCODE = 'CRM47';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'crm: ai_draft_guard (a draft leaves only with its trip)' USING ERRCODE = 'CRM47';
    END IF;
    -- UPDATE: one decision, by a member, from pending; nothing else changes.
    IF v_actor NOT LIKE 'member:%' THEN
        RAISE EXCEPTION 'crm: ai_draft_guard (a member decides on a draft, actor %)', v_actor USING ERRCODE = 'CRM47';
    END IF;
    IF OLD.decision <> 'pending' OR NEW.decision = 'pending' THEN
        RAISE EXCEPTION 'crm: ai_draft_guard (a draft is decided once, from pending)' USING ERRCODE = 'CRM47';
    END IF;
    IF (pg_catalog.to_jsonb(NEW) - v_decision_cols) IS DISTINCT FROM (pg_catalog.to_jsonb(OLD) - v_decision_cols) THEN
        RAISE EXCEPTION 'crm: ai_draft_guard (only the decision of a draft changes)' USING ERRCODE = 'CRM47';
    END IF;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION crm.guard_ai_draft() IS 'AA-1027 F3 (crm-040, SQLSTATE CRM47): who may write crm.ai_draft. INSERT: a member (member:<id>) only, pending. UPDATE: a member only, once, from pending to accepted or discarded; only decision, feedback_code, decided_at, decided_by (and updated_at) change. DELETE: refused (the row leaves with its trip by cascade, depth > 1). crm_owner unguarded (migrations, tests). Invoker rights.';
CREATE TRIGGER ai_draft_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.ai_draft
    FOR EACH ROW EXECUTE FUNCTION crm.guard_ai_draft();

COMMENT ON TABLE crm.ai_draft IS 'AA-1027 F3 (crm-040; design v3 M14, R39, A-21; data-privacy-integrations §2.9 group H): one AI draft a member asked for in the trip workspace (POST /crm/v1/trips/{id}/ai/draft, outcome ok), stored with its placeholders under the agency vault DEK, and the member''s one decision on it (accepted / discarded, optional feedback code). A draft is a suggestion: nothing is sent from it. No prompt text is stored (the ledger row keeps the prompt hash). Cascades from its trip. No reader role is granted it.';
COMMENT ON COLUMN crm.ai_draft.output_enc IS 'pii:free_text; the draft as the model wrote it (placeholders such as <PERSON_1> kept, never restored at rest), under the tenant vault DEK, AAD = tenant, ai_draft, output_enc, row id';
COMMENT ON COLUMN crm.ai_draft.llm_call_id IS 'the crm.llm_call row of the call that wrote the draft (no key: the ledger row is purged after 180 days, the draft stays with its trip)';
COMMENT ON COLUMN crm.ai_draft.decision IS 'pending, then accepted or discarded once by a member (crm.guard_ai_draft holds the move; no crm.status_transition rows)';
COMMENT ON COLUMN crm.ai_draft.feedback_code IS 'R39: the member''s optional reason with the decision (good, wrong_facts, wrong_tone, not_relevant, too_long, other)';
COMMENT ON COLUMN crm.ai_draft.decided_by IS 'the actor who decided (member:<id>)';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-040', now(), 'AA-1027 F3 AI draft UI: crm.ai_draft (one row per draft asked for in the trip workspace, output under the vault DEK, one accept / discard decision with a feedback code); guard CRM47; cascades from its trip, no erase_subject change')
ON CONFLICT (version) DO NOTHING;

COMMIT;
