-- Migration crm-009: AA-938 (partner CRM, design v3 card CRM-10) — F3 PII scrubber: the encrypted placeholder map
-- and a value-free guard on the LLM call receipt.
--
-- Owner: AA-Partner (api/migrations/009_crm_scrub_placeholder_map.sql). AA-CIS-Infra db/migrations/crm/ holds the
-- byte copy DB Migrate applies (Migration Copy Guard). Key crm-009 (fixed in S249 with crm-007 = AA-940 and
-- crm-008 = AA-939 so the three parallel cards never collide).
--
-- Why. Design v3 §4.5 (PII filter before any LLM call: "the placeholder map is encrypted (scrub DEK), lives 24 h, and
-- is restored only in the agency session"), §3.3 group H (`placeholder_map`), §3.6 (retention "OTP, placeholder map:
-- 24 h"), lane §2.9 (`placeholder_map`: `map_enc` purpose scrub, `expires_at` 24 h; `llm_call.scrub_receipt`: entity
-- counts and the scrubber version, no text) and §5.4.
--
-- What:
--   1. crm.placeholder_map: one row per scrubbed LLM call that replaced at least one value. map_enc = the JSON map
--      placeholder -> original value, AES-256-GCM under the tenant `scrub` DEK (AAD = tenant, placeholder_map, map_enc,
--      row id), sealed by the app (app.privacy.placeholder_store) before the call. llm_call_id is a same-agency
--      (tenant_id, llm_call_id) key to the call it served (referential checks bypass FORCE RLS, so a single-column
--      key could point at another agency's call). ai_draft_id is filled by CRM-33a (AA-964), which adds the table and
--      its key. expires_at is at most 24 h after created_at (CHECK). Base template (FORCE RLS, tenant_isolation, trash
--      columns, updated_at trigger); crm_app may INSERT, SELECT and DELETE but never UPDATE: a map is written once.
--      No NOLOGIN reader gets anything on it (it holds identity values, like the F1 tables).
--   2. The purge path: policy placeholder_map_expired_purge (FOR DELETE TO crm_app) lets the hourly job
--      crm_placeholder_purge delete expired maps of every agency in one statement, only inside a transaction that set
--      app.purge_scope = 'placeholder_map' (app.privacy.purge) and only rows whose expires_at has passed. It grants no
--      SELECT, so the job never reads a map.
--   3. crm.llm_call.scrub_receipt: only the receipt app.privacy.scrubber writes, closed at every level: the keys
--      scrubber, detector, entities, counts, passes, known_persons; versions as short codes; numbers as numbers; the
--      keys of counts (placeholder kinds, A-Z and _) and passes (known, regex, detector) with numbers only. So a value
--      can never be stored under a new key or as a value. The AA-936 stub receipts ({scrubber, entities}) and {}
--      pass; before apply, DB Migrate check confirms no Dev row holds anything else (an ADD CONSTRAINT validates
--      existing rows). UNIQUE (tenant_id, llm_call_id) for the composite key of 1.
--
-- Order: needs crm-006 (AA-937) only; it does not touch any object of crm-007 / crm-008, so DB Migrate may apply it
-- before or after them. Guard 0 refuses to run before crm-006 is registered.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); before AA-938
-- deploys nothing reads these objects.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-006 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-009: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-006') THEN
        RAISE EXCEPTION 'crm-009: crm-006 is not registered (F1/F2 complete, AA-937, lands first)';
    END IF;
END $$;

-- ── 3. crm.llm_call: same-agency key target + value-free receipt ─────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'crm.llm_call'::regclass AND conname = 'llm_call_tenant_id_uq') THEN
        ALTER TABLE crm.llm_call ADD CONSTRAINT llm_call_tenant_id_uq UNIQUE (tenant_id, llm_call_id);
    END IF;
END $$;
ALTER TABLE crm.llm_call DROP CONSTRAINT IF EXISTS llm_call_receipt_keys_chk;
-- Every level is closed: the top-level keys, the version strings (short codes), the numbers, and the keys of the two
-- nested objects (counts: placeholder kinds such as PERSON / EMAIL; passes: known / regex / detector), each with a
-- number. So neither a key nor a value can carry a name ({"counts": {"Hoa Nguyen": 1}} is refused).
ALTER TABLE crm.llm_call ADD CONSTRAINT llm_call_receipt_keys_chk CHECK (
    (scrub_receipt - ARRAY['scrubber', 'detector', 'entities', 'counts', 'passes', 'known_persons']) = '{}'::jsonb
    AND (NOT scrub_receipt ? 'scrubber' OR (jsonb_typeof(scrub_receipt -> 'scrubber') = 'string'
         AND (scrub_receipt ->> 'scrubber') ~ '^[a-z0-9][a-z0-9.-]{0,19}$'))
    AND (NOT scrub_receipt ? 'detector' OR (jsonb_typeof(scrub_receipt -> 'detector') = 'string'
         AND (scrub_receipt ->> 'detector') ~ '^[a-z0-9][a-z0-9_.-]{0,39}$'))
    AND (NOT scrub_receipt ? 'entities' OR jsonb_typeof(scrub_receipt -> 'entities') = 'number')
    AND (NOT scrub_receipt ? 'known_persons' OR jsonb_typeof(scrub_receipt -> 'known_persons') = 'number')
    AND (NOT scrub_receipt ? 'counts' OR (jsonb_typeof(scrub_receipt -> 'counts') = 'object'
         AND NOT jsonb_path_exists(scrub_receipt -> 'counts',
             'strict $.keyvalue() ? (!(@.key like_regex "^[A-Z][A-Z_]{1,23}$") || @.value.type() != "number")')))
    AND (NOT scrub_receipt ? 'passes' OR (jsonb_typeof(scrub_receipt -> 'passes') = 'object'
         AND ((scrub_receipt -> 'passes') - ARRAY['known', 'regex', 'detector']) = '{}'::jsonb
         AND NOT jsonb_path_exists(scrub_receipt -> 'passes', 'strict $.keyvalue() ? (@.value.type() != "number")')))
);
COMMENT ON CONSTRAINT llm_call_receipt_keys_chk ON crm.llm_call IS 'AA-938 (crm-009): the F3 receipt holds counts and versions only (app.privacy.scrubber): known keys at every level, short version codes, numbers; anything else is refused';

-- ── 1. crm.placeholder_map ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.placeholder_map (
    placeholder_map_id UUID PRIMARY KEY,
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    llm_call_id        UUID NOT NULL,
    ai_draft_id        UUID,
    map_enc            BYTEA NOT NULL,
    placeholder_count  INTEGER NOT NULL,
    scrubber_version   TEXT NOT NULL,
    expires_at         TIMESTAMPTZ NOT NULL DEFAULT now() + interval '24 hours',
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,
    deleted_by         TEXT,
    purge_after        TIMESTAMPTZ,
    CONSTRAINT placeholder_map_call_uq UNIQUE (llm_call_id),
    CONSTRAINT placeholder_map_call_fk FOREIGN KEY (tenant_id, llm_call_id)
        REFERENCES crm.llm_call (tenant_id, llm_call_id),
    -- key_version ‖ nonce ‖ ciphertext ‖ tag (2 + 12 + 16 bytes at least); 64 KiB is far above 500 placeholders.
    CONSTRAINT placeholder_map_enc_chk CHECK (octet_length(map_enc) BETWEEN 30 AND 65536),
    CONSTRAINT placeholder_map_count_chk CHECK (placeholder_count BETWEEN 1 AND 500),
    CONSTRAINT placeholder_map_version_chk CHECK (scrubber_version ~ '^[a-z0-9][a-z0-9.-]{0,19}$'),
    CONSTRAINT placeholder_map_ttl_chk CHECK (expires_at > created_at AND expires_at <= created_at + interval '24 hours'),
    CONSTRAINT placeholder_map_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS placeholder_map_expires_idx ON crm.placeholder_map (expires_at);
COMMENT ON TABLE crm.placeholder_map IS 'AA-938 (crm-009): the F3 placeholder map of one scrubbed LLM call (design §4.5, lane §2.9): placeholder -> original value as JSON, AES-256-GCM under the tenant scrub DEK (AAD = tenant, placeholder_map, map_enc, row id). Written once (crm_app has no UPDATE), restored only in an agency member''s session (app.privacy.placeholder_store), expires 24 h after creation and is deleted by the hourly crm_placeholder_purge job (policy placeholder_map_expired_purge). No NOLOGIN reader is granted it.';
COMMENT ON COLUMN crm.placeholder_map.map_enc IS 'pii:free_text; the names, contacts and ids one prompt mentioned, encrypted (scrub DEK)';
COMMENT ON COLUMN crm.placeholder_map.ai_draft_id IS 'AA-938 (crm-009): the draft the call produced; CRM-33a (AA-964) adds crm.ai_draft and the (tenant_id, ai_draft_id) key';

ALTER TABLE crm.placeholder_map ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.placeholder_map FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.placeholder_map;
CREATE POLICY tenant_isolation ON crm.placeholder_map
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

-- ── 2. The purge path (DELETE only, expired rows only, only with app.purge_scope set) ────────────
DROP POLICY IF EXISTS placeholder_map_expired_purge ON crm.placeholder_map;
CREATE POLICY placeholder_map_expired_purge ON crm.placeholder_map
    FOR DELETE TO crm_app
    USING (current_setting('app.purge_scope', true) = 'placeholder_map' AND expires_at < now());

CREATE OR REPLACE TRIGGER placeholder_map_set_updated_at
    BEFORE UPDATE ON crm.placeholder_map
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();

-- Written once: no UPDATE for the runtime role (trash is not offered for a 24 h technical record).
REVOKE UPDATE, TRUNCATE ON crm.placeholder_map FROM crm_app;
REVOKE ALL ON crm.placeholder_map FROM crm_ai_reader, crm_insights, crm_support_reader, crm_eraser;

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    r text;
    p text;
BEGIN
    IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class
             WHERE oid = 'crm.placeholder_map'::regclass) THEN
        RAISE EXCEPTION 'crm-009: crm.placeholder_map must have ENABLE + FORCE row level security';
    END IF;
    FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
        FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
            IF pg_catalog.has_table_privilege(r, 'crm.placeholder_map', p) THEN
                RAISE EXCEPTION 'crm-009: % may % on crm.placeholder_map (identity values)', r, p;
            END IF;
        END LOOP;
    END LOOP;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.placeholder_map', 'UPDATE') THEN
        RAISE EXCEPTION 'crm-009: crm_app may UPDATE crm.placeholder_map (a map is written once)';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol
                WHERE pol.polrelid = 'crm.placeholder_map'::regclass
                  AND pol.polname <> 'tenant_isolation'
                  AND (pol.polcmd <> 'd' OR pol.polroles <> ARRAY['crm_app'::regrole::oid])) THEN
        RAISE EXCEPTION 'crm-009: an extra policy on crm.placeholder_map other than the crm_app DELETE purge';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-009: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-009', now(), 'AA-938: F3 scrubber: crm.placeholder_map (scrub DEK, 24 h, purge policy), value-free llm_call receipt')
ON CONFLICT (version) DO NOTHING;

COMMIT;
