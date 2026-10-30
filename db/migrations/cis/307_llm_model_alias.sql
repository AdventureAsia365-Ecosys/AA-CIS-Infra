-- migrate: expand
-- Migration 307: AA-1002 (LLM gateway slice S3) — shared.llm_model_alias: what a legacy Model Key runs, as data.
--
-- Why. The legacy keys `haiku` and `sonnet` are served by a hard-coded chain (shared/llm_client/client.py
-- _legacy_chain): Sonnet 4.6 on the acc3 satellite, then Haiku 4.5 on acc3, from inference-profile constants. Slice S3
-- lets them resolve through the catalog and the deployments (migration 304: sonnet@acc3, haiku@acc3 with the same
-- profiles, origin legacy_constant) instead: an alias names the ordered catalog models a key runs, and each model is
-- tried on its own enabled deployments (vendor_route.deployment_plan). Repointing a legacy key later (to logical
-- Converse rows, slice S11) is then a data change, not a code change.
--
-- What.
--   1. shared.llm_model_alias (alias_key, position, model_key): PK (alias_key, position), UNIQUE (alias_key,
--      model_key); model_key FK -> shared.llm_model_catalog ON DELETE RESTRICT (a catalog row an alias names cannot be
--      deleted under it). alias_key and model_key follow the catalog key shape; position 1..20.
--   2. Rows = the legacy chain's order today (LLM_LEGACY_ACC2_NATIVE off, AA-843):
--        haiku  1 haiku            (T2.5a: Haiku 4.5 on acc3)
--        sonnet 1 sonnet, 2 haiku  (T1.5a: Sonnet 4.6 on acc3, then T2.5a: Haiku 4.5 on acc3)
--      An alias target that is a legacy key itself keeps the legacy wire format (api_style anthropic_native: the
--      InvokeModel Messages body of the chain, prompt cache included), so the alias path sends the very same requests.
--      gpt-6-luna-openai gets no alias row: with deployment routing (S3) it already resolves through its catalog row
--      and its openai-direct deployment, and pointing it at gpt-6-luna would bypass the S235 OpenAI gate (keyed on the
--      provider='openai' catalog row) until slice S5 turns that policy into data scopes. gpt-4.1 stays retired.
--   3. GRANT SELECT to cis_app (the api and the worker read it, cached 5 minutes). cis_owner's default privileges in
--      shared also give cis_app INSERT / UPDATE / DELETE, which an expand file cannot revoke (REVOKE is contract); the
--      code only reads it. No tripplanner grant (TripPlanner keeps its own gateway until slice S8).
--   4. Register 307.
--
-- Behaviour. None on apply: the code reads the table only with LLM_LEGACY_ALIASES=on (default off), and without a row
-- (or before this file) a legacy key runs the hard-coded chain, unchanged.
--
-- Not in this file (contract by root ADR 0017 d3, so not auto-applied; they wait for a contract migration applied by
-- hand, see docs/implementation-notes/AA-1002.md, slice S3): the logical catalog rows sonnet-4-6 / haiku-4-5 (an INSERT
-- into an existing table), their deployments, and replacing the llm_role_config CHECK account_route = 'acc3' with an FK
-- to shared.llm_provider_connection (a constraint change on an existing table).
--
-- Class: expand (root ADR 0017 d3): one new table, its index-backed constraints, rows in that new table, a grant and
-- comments; no change to any existing object (the FK only adds the internal RI triggers on the catalog), no DO block.
-- Auto-applied on Dev by the AA-CIS-Infra migration-apply pipeline after the app PR merges. The code does not need it
-- (no readiness bump): without the table the aliases are empty and every legacy key keeps _legacy_chain.
--
-- Number. 306 is the highest on main (30/10); lane "reports" of S259 owns 308.
--
-- Rollback (a new forward migration, after the code that reads it is reverted or LLM_LEGACY_ALIASES is off):
--   DROP TABLE shared.llm_model_alias;   (a destructive file)
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.llm_model_alias (
    alias_key   text        NOT NULL,
    position    smallint    NOT NULL,
    model_key   text        NOT NULL,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  text        NOT NULL,
    CONSTRAINT llm_model_alias_pkey PRIMARY KEY (alias_key, position),
    CONSTRAINT llm_model_alias_model_uq UNIQUE (alias_key, model_key),
    CONSTRAINT llm_model_alias_model_fkey FOREIGN KEY (model_key)
        REFERENCES shared.llm_model_catalog (model_key) ON DELETE RESTRICT,
    CONSTRAINT llm_model_alias_key_check CHECK (alias_key ~ '^[a-z0-9][a-z0-9.-]{0,62}$'),
    CONSTRAINT llm_model_alias_position_check CHECK (position BETWEEN 1 AND 20)
);

COMMENT ON TABLE shared.llm_model_alias IS
    'AA-1002 (CIS 307, gateway slice S3): the ordered catalog models a legacy Model Key (haiku, sonnet) runs; each '
    'model is tried on its own enabled deployments (shared.llm_model_deployment). Read by shared/llm_client/'
    'deployments.py only when LLM_LEGACY_ALIASES=on; no row = the hard-coded legacy chain.';
COMMENT ON COLUMN shared.llm_model_alias.position IS
    'AA-1002 (307): try order, 1 first (sonnet: 1 sonnet, 2 haiku = the legacy chain''s Sonnet -> Haiku degrade).';
COMMENT ON COLUMN shared.llm_model_alias.model_key IS
    'AA-1002 (307): a catalog row; a legacy key target keeps its own wire format (anthropic_native InvokeModel body).';

INSERT INTO shared.llm_model_alias (alias_key, position, model_key, notes, updated_by)
VALUES
    ('haiku',  1, 'haiku',  'Legacy chain T2.5a: Haiku 4.5 on its deployments (haiku@acc3).', 'migration-307-aa1002'),
    ('sonnet', 1, 'sonnet', 'Legacy chain T1.5a: Sonnet 4.6 on its deployments (sonnet@acc3).', 'migration-307-aa1002'),
    ('sonnet', 2, 'haiku',  'Legacy chain T2.5a: Sonnet degrades to Haiku 4.5 (fallback_used).', 'migration-307-aa1002')
ON CONFLICT (alias_key, position) DO NOTHING;

GRANT SELECT ON shared.llm_model_alias TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('307', now(), 'AA-1002 S3: shared.llm_model_alias (legacy haiku / sonnet -> ordered catalog models; read only '
                      'with LLM_LEGACY_ALIASES=on)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
