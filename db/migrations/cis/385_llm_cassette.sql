-- Migration 385: AA-900 (S271 writing-quality restructure, wave W0; root ADR 0020 "Gateway amendments" d8) — the
-- cassette of raw model replies, written by the AI gateway in record-only mode.
--
-- Why. ADR 0020 d8: "A cassette stores the raw reply, request and prompt shas for replay." Today a reply leaves no
-- trace once its caller has parsed it: the ledger (shared.llm_call_log) keeps tokens, cost and outcome but never the
-- text (DM-6.4 / DM-10.4), T9 keeps the writer input, T2 its generation_meta, the eval at most 8 claims. A judge
-- verdict, a cut writer reply or a fallback answer cannot be re-read, replayed at $0 against a changed rule, or
-- compared across model versions. The audit (root docs/audits/2026-11-06-S271-writing-quality-audit/,
-- data/design-review.json arch.shared_components "Cassette recorder") makes it the substrate of the replay ladder,
-- the audits and the verdict cache.
--
-- What.
--   1. shared.llm_cassette: one row per provider attempt that returned a reply through LLMClient._attempt (every
--      role, every stage, shadows and the truncation retry included; a billed reply the gateway refused as unusable
--      raises before it and is not recorded yet). Columns:
--        request_sha256     sha256 of the canonical JSON of the request (messages: system, few-shots, user; params:
--                           model key, max_tokens, temperature, seed, json_schema, effort): the replay key;
--        prompt_sha256 / prompt_version  the system prompt's sha (= llm_call_log.prompt_hash) and its registered
--                           version; the prompt text itself is never stored;
--        reply_text         the raw reply, at most 262144 bytes of UTF-8 (256 KiB; reply_truncated marks a cut),
--                           NULL when withheld ('pii_stage': a stage of data class pii; none in CIS today);
--        reply_sha256 / reply_bytes      of the WHOLE reply, before the cap;
--        model_key, answered_model (the id the provider says answered, when it reports one), deployment_wire_id,
--        connection_key, provider, provider_request_id, rung (route position, 0 = the stage's first model),
--        attempt_no, effort, max_tokens, stop_reason, is_shadow, is_truncation_retry;
--        the links: route_trace + attempt_no (the answered llm_call_log row carries quality_signal.route_trace and
--        attempt_no: the read helper resolves a ledger id through them, no foreign key), tenant_id, job_id,
--        content_piece_id, tour_id, eval_run, eval_item (each when the gateway knows it: the bound job / tenant /
--        eval run, or a caller's cassette.bind_owner()).
--      No foreign key (the ledger and the owning tables are pruned on their own windows).
--   2. Indexes for the read helpers (route_trace, request_sha256) and for the prune / erasure paths (created_at,
--      tenant_id, job_id, content_piece_id, tour_id, eval_run).
--   3. Grants: REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner first (the 321 / 345 / 370 pattern:
--      Migration Apply creates the table as cis_owner, whose default privileges in shared (CIS 245) give cis_app
--      SELECT, INSERT, UPDATE, DELETE on every new table), then GRANT cis_app SELECT, INSERT, DELETE (the gateway
--      writes as cis_app, the replay helpers read; the tenant erasure job, AA-839 services/erasure/inventory.py
--      action delete, and the future TTL job kind delete as the runtime role). No UPDATE: a row is never changed.
--   4. Register 385.
--
-- PII (DM-6.1, DM-6.4). reply_text may hold tenant content (an agency's tour text) and is tagged pii:free_text;
-- prompts carry no identifying personal data by DM-6.4, so a reply has none by construction, but the column is
-- treated as free text: the table is never read by a tenant route, never exported, never copied to a public repo.
-- A stage of data class pii stores no text (reply_withheld). Tenant erasure (AA-839) deletes the tenant's rows
-- (by tenant_id).
--
-- Retention (DM-7.1). Proposed 30 days raw, no rollup, no archive (a replay older than a month re-runs the call);
-- row in root data standards Part B section 7, in the root PR of this change (merged before the Infra copy). Until a
-- TTL job kind exists (follow-up: services/retention/policy.py spec retention_llm_cassette, archive off, DRY RUN
-- first) nothing is deleted; Dev volume is about one row per paid chat call (a few KB each, TOAST-compressed).
--
-- Behaviour. None on apply: the table is empty. The gateway code PR writes it best-effort (LLM_CASSETTE=record, the
-- default; off writes nothing); before this file is applied a write meets UndefinedTable, is counted and skipped
-- for 5 minutes, and the call goes on.
--
-- Class: contract (no '-- migrate:' directive). One new table, its constraints and indexes, grants on it and
-- comments; no existing object changes. It is not expand because shared.llm_cassette has a tenant_id column with RLS
-- off on purpose (a CIS-only gateway store like shared.llm_call_log; tenant_id is attribution and the erasure key;
-- X2 allowlist rule a, tests/integration/rls_catalogue_rules.py), and the expand classify refuses a new tenant_id
-- table without ENABLE and FORCE ROW LEVEL SECURITY.
--
-- Number. 383 is the highest on CIS main (06/11); 384-386 are held by parallel S271 lanes. Renumber to main max + 1
-- at merge: git grep '385_' and 'llm_cassette' (the test, the notes, the register line below).
--
-- Rollback (a new forward migration, after the code is reverted or LLM_CASSETTE=off): DROP TABLE shared.llm_cassette
-- (a destructive file, DRY RUN). Nothing reads it on a live path.
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.llm_cassette (
    id                   uuid         NOT NULL DEFAULT gen_random_uuid(),
    created_at           timestamptz  NOT NULL DEFAULT now(),
    app                  text         NOT NULL DEFAULT 'cis',
    stage                text         NOT NULL,
    role                 text         NOT NULL,
    request_sha256       text         NOT NULL,
    prompt_sha256        text,
    prompt_version       text,
    model_key            text         NOT NULL,
    answered_model       text,
    deployment_wire_id   text,
    connection_key       text,
    provider             text,
    provider_request_id  text,
    route_trace          uuid,
    rung                 smallint,
    attempt_no           integer,
    effort               text,
    max_tokens           integer,
    stop_reason          text,
    is_shadow            boolean      NOT NULL DEFAULT false,
    is_truncation_retry  boolean      NOT NULL DEFAULT false,
    reply_text           text,
    reply_sha256         text         NOT NULL,
    reply_bytes          integer      NOT NULL,
    reply_truncated      boolean      NOT NULL DEFAULT false,
    reply_withheld       text,
    tenant_id            uuid,
    job_id               uuid,
    content_piece_id     uuid,
    tour_id              uuid,
    eval_run             text,
    eval_item            text,
    CONSTRAINT llm_cassette_pkey PRIMARY KEY (id),
    CONSTRAINT llm_cassette_app_check CHECK (app ~ '^[a-z][a-z0-9_]{0,31}$'),
    CONSTRAINT llm_cassette_stage_check CHECK (length(stage) BETWEEN 1 AND 128),
    CONSTRAINT llm_cassette_role_check CHECK (
        role IN ('writer', 'judge', 'validate', 'embed', 'decide', 'data', 'guard')),
    CONSTRAINT llm_cassette_sha_check CHECK (
        request_sha256 ~ '^[0-9a-f]{64}$' AND reply_sha256 ~ '^[0-9a-f]{64}$'
        AND (prompt_sha256 IS NULL OR prompt_sha256 ~ '^[0-9a-f]{64}$')),
    CONSTRAINT llm_cassette_text_sizes_check CHECK (
        length(model_key) BETWEEN 1 AND 200
        AND (prompt_version IS NULL OR length(prompt_version) <= 128)
        AND (answered_model IS NULL OR length(answered_model) <= 200)
        AND (deployment_wire_id IS NULL OR length(deployment_wire_id) <= 300)
        AND (connection_key IS NULL OR length(connection_key) <= 128)
        AND (provider IS NULL OR length(provider) <= 64)
        AND (provider_request_id IS NULL OR length(provider_request_id) <= 256)
        AND (effort IS NULL OR length(effort) <= 32)
        AND (stop_reason IS NULL OR length(stop_reason) <= 64)
        AND (eval_run IS NULL OR length(eval_run) <= 128)
        AND (eval_item IS NULL OR length(eval_item) <= 256)),
    CONSTRAINT llm_cassette_counts_check CHECK (
        (rung IS NULL OR rung >= 0) AND (attempt_no IS NULL OR attempt_no >= 1)
        AND (max_tokens IS NULL OR max_tokens >= 0) AND reply_bytes >= 0),
    -- 256 KiB of UTF-8: the gateway cuts at a character boundary and sets reply_truncated.
    CONSTRAINT llm_cassette_reply_cap_check CHECK (reply_text IS NULL OR octet_length(reply_text) <= 262144),
    CONSTRAINT llm_cassette_withheld_check CHECK (
        reply_withheld IS NULL OR (reply_withheld = 'pii_stage' AND reply_text IS NULL))
);

CREATE INDEX IF NOT EXISTS llm_cassette_created_idx ON shared.llm_cassette (created_at, id);
CREATE INDEX IF NOT EXISTS llm_cassette_trace_idx ON shared.llm_cassette (route_trace, attempt_no)
    WHERE route_trace IS NOT NULL;
CREATE INDEX IF NOT EXISTS llm_cassette_request_idx ON shared.llm_cassette (request_sha256, created_at DESC);
CREATE INDEX IF NOT EXISTS llm_cassette_tenant_idx ON shared.llm_cassette (tenant_id, created_at)
    WHERE tenant_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS llm_cassette_job_idx ON shared.llm_cassette (job_id) WHERE job_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS llm_cassette_piece_idx ON shared.llm_cassette (content_piece_id)
    WHERE content_piece_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS llm_cassette_tour_idx ON shared.llm_cassette (tour_id) WHERE tour_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS llm_cassette_eval_idx ON shared.llm_cassette (eval_run, eval_item)
    WHERE eval_run IS NOT NULL;

COMMENT ON TABLE shared.llm_cassette IS
    'AA-900 (CIS 385, root ADR 0020 d8): the raw reply of every provider attempt that returned one through the AI '
    'gateway (shared/llm_client/cassette.py, record-only, LLM_CASSETTE=record|off), with the request and prompt '
    'shas for replay. Linked to its llm_call_log row through route_trace + attempt_no (no FK) and to the owning '
    'object when known. CIS only: no tenant route reads it. Retention: 30 days proposed (data standards DM-7.1).';
COMMENT ON COLUMN shared.llm_cassette.request_sha256 IS
    'AA-900 (385): sha256 hex of the canonical JSON (sorted keys, no spaces) of the request: messages (system, '
    'few-shots, user) and params (model key, max_tokens, temperature, seed, json_schema, effort). cassette.request_sha.';
COMMENT ON COLUMN shared.llm_cassette.prompt_sha256 IS
    'AA-900 (385): sha256 hex of the system prompt (= llm_call_log.prompt_hash). The prompt text is never stored.';
COMMENT ON COLUMN shared.llm_cassette.answered_model IS
    'AA-900 (385): the model id the provider says answered (LLMResponse.provider_model), when it reports one.';
COMMENT ON COLUMN shared.llm_cassette.rung IS
    'AA-900 (385): the route position that answered (0 = the stage''s first model; llm_call_log quality_signal '
    'route_position).';
COMMENT ON COLUMN shared.llm_cassette.route_trace IS
    'AA-900 (385): the gateway request (llm_call_log quality_signal.route_trace); with attempt_no it finds the '
    'ledger row of this reply.';
COMMENT ON COLUMN shared.llm_cassette.reply_text IS
    'pii:free_text; AA-900 (385): the raw model reply (may hold tenant content), at most 262144 bytes of UTF-8 '
    '(reply_truncated marks a cut); NULL when withheld (reply_withheld). Never shown to a tenant, never exported.';
COMMENT ON COLUMN shared.llm_cassette.reply_sha256 IS
    'AA-900 (385): sha256 hex of the whole reply before the 256 KiB cap.';
COMMENT ON COLUMN shared.llm_cassette.reply_withheld IS
    'AA-900 (385): why reply_text is NULL: pii_stage (the stage''s data class is pii, DM-6.4). NULL = stored.';
COMMENT ON COLUMN shared.llm_cassette.tenant_id IS
    'AA-900 (385): the tenant whose content the call served (the bound job tenant), attribution and erasure key.';

-- Narrow cis_owner's default privileges (CIS 245) before the grant: without the REVOKE cis_app could UPDATE a reply.
REVOKE ALL ON shared.llm_cassette FROM PUBLIC;
REVOKE ALL ON shared.llm_cassette FROM cis_app, aa_app_user, catalog_owner;   -- cis_owner's default privileges (CIS 245)
GRANT SELECT, INSERT, DELETE ON shared.llm_cassette TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('385', now(), 'AA-900: shared.llm_cassette (raw model replies of the AI gateway, record-only, for replay)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
