-- Migration 306: AA-1002 (LLM gateway slice S2) — Anthropic API deployments (behind Bedrock) + the admin switch grant.
--
-- Why. Slice S2 adds the Anthropic Messages API adapter (shared/llm_client/adapters/anthropic_messages.py). The
-- gateway calls a catalog model through it only when the model's FIRST enabled deployment (lowest priority) on an
-- ENABLED connection is on an anthropic connection (shared/llm_client/vendor_route.py), or when a probe pins
-- "<model key>@anthropic-direct". The anthropic-direct connection (304) stays disabled; the admin switches it with
-- PATCH /admin/llm-connections/{connection_key} (audited), which needs UPDATE on three columns.
--
-- What.
--   1. GRANT UPDATE (enabled, updated_at, updated_by) ON shared.llm_provider_connection TO cis_app — the S2 admin
--      switch only (secret_name / base_url / limits stay SELECT-only until slice S4).
--   2. One anthropic-direct deployment per Anthropic Converse catalog row that has an acc3 profile:
--      wire_id = the acc3 profile without its region prefix ("global." / "us." / "eu." / "apac." / "jp." / "au."
--      + "anthropic.") and without a Bedrock version suffix ("-v1:0"), e.g. global.anthropic.claude-sonnet-5-5 ->
--      claude-sonnet-5-5; priority 100 (BEHIND the acc3 deployment, priority 10), enabled, origin 'seed',
--      request_defaults '{}' (the adapter sends the model family's default effort). ON CONFLICT DO NOTHING (an admin
--      edit is kept). Legacy keys (haiku / sonnet, api_style anthropic_native) get none: their aliasing is slice S3.
--      A derived wire id outside ^claude-[a-z0-9-]+$ is skipped (guard below lists it).
--   3. Register 306.
--
-- Behaviour. None changes on apply: the connection is disabled, and even once it is enabled every seeded row sits
-- behind an enabled acc3 deployment, so routes keep today's path; only a pinned probe reaches the API. Making the
-- Anthropic API the primary way in for a model is a deliberate per-model change of its deployment priority (below
-- 10), not part of this file (RUNBOOK).
--
-- Guards (RAISE rolls the whole file back):
--   before: 304 tables exist; the anthropic-direct connection exists, is kind anthropic and is disabled.
--   after:  every anthropic-direct deployment's wire_id matches ^claude-[a-z0-9-]+$ and every seeded one sorts
--           behind the model's enabled acc3 row (a catalog row whose acc3 profile yields no Claude API id gets no
--           deployment: NOTICE, it keeps today's path).
--
-- Number. 305 is taken by AA-1003 R1 (CIS #1161, open); no open PR or S258 worktree uses 306 (checked 30/10).
-- Apply through AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/, opened by the migration-sync bot) after
-- 304. Order with the code: either way works for routing (the S2 code takes today's path without these rows), but
-- the admin switch answers 500 (permission denied) until the grant exists, so apply this file before using it.
-- Contract file (no expand header): DB Migrate apply by hand with the job tables idle.
--
-- Rollback (a NEW forward migration):
--   DELETE FROM shared.llm_model_deployment WHERE connection_key = 'anthropic-direct' AND origin = 'seed';
--   REVOKE UPDATE (enabled, updated_at, updated_by) ON shared.llm_provider_connection FROM cis_app;
--
-- X1. One BEGIN … COMMIT block, no role switch; DB Migrate runs cis/ files as cis_owner, owner of both tables.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 0. Guard: predecessors ───────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('shared.llm_provider_connection') IS NULL OR to_regclass('shared.llm_model_deployment') IS NULL THEN
        RAISE EXCEPTION 'migration 306: the 304 tables shared.llm_provider_connection / llm_model_deployment are missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_provider_connection
                    WHERE connection_key = 'anthropic-direct' AND kind = 'anthropic') THEN
        RAISE EXCEPTION 'migration 306: connection anthropic-direct (kind anthropic, seeded by 304) is missing';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.llm_provider_connection WHERE connection_key = 'anthropic-direct' AND enabled) THEN
        RAISE NOTICE 'migration 306: anthropic-direct is already enabled (an admin switched it); rows are added behind '
                     'Bedrock, routes are unchanged';
    END IF;
END $$;

-- ── 1. The admin switch (S2): three columns only ────────────────────────────────────────────────────────────────
GRANT UPDATE (enabled, updated_at, updated_by) ON shared.llm_provider_connection TO cis_app;

-- ── 2. Anthropic API deployments, behind the acc3 deployment ────────────────────────────────────────────────────
INSERT INTO shared.llm_model_deployment
    (model_key, connection_key, wire_id, priority, enabled, origin, notes, updated_by)
SELECT s.model_key, 'anthropic-direct', s.wire_id, 100, true, 'seed',
       'Anthropic Messages API (AA-1002 S2). Behind the acc3 deployment (priority 10): used only by a pinned probe '
       'until its priority is set below 10 and the connection is enabled.',
       'migration-306-aa1002'
  FROM (SELECT m.model_key,
               regexp_replace(regexp_replace(m.bedrock_profile_ids ->> 'acc3',
                                             '^(global|us|eu|apac|jp|au)\.anthropic\.', ''),
                              '-v[0-9]+:[0-9]+$', '') AS wire_id
          FROM shared.llm_model_catalog m
         WHERE m.vendor = 'anthropic' AND m.provider = 'bedrock' AND m.api_style = 'converse'
           AND coalesce(m.bedrock_profile_ids ->> 'acc3', '') <> '') AS s
 WHERE s.wire_id ~ '^claude-[a-z0-9-]+$'
ON CONFLICT (model_key, connection_key) DO NOTHING;

-- ── 3. Guard: the seed describes what the code expects ──────────────────────────────────────────────────────────
DO $$
DECLARE
    missing text;
    bad     text;
    ahead   text;
BEGIN
    SELECT string_agg(m.model_key, ', ' ORDER BY m.model_key) INTO missing
      FROM shared.llm_model_catalog m
     WHERE m.vendor = 'anthropic' AND m.provider = 'bedrock' AND m.api_style = 'converse'
       AND coalesce(m.bedrock_profile_ids ->> 'acc3', '') <> ''
       AND NOT EXISTS (SELECT 1 FROM shared.llm_model_deployment d
                        WHERE d.model_key = m.model_key AND d.connection_key = 'anthropic-direct');
    IF missing IS NOT NULL THEN
        -- not an error: such a model simply keeps today's path only (no Claude API id could be derived)
        RAISE NOTICE 'migration 306: Anthropic catalog rows left without an anthropic-direct deployment '
                     '(acc3 profile not of the form <region>.anthropic.claude-...): %', missing;
    END IF;

    SELECT string_agg(model_key || '=' || wire_id, ', ' ORDER BY model_key) INTO bad
      FROM shared.llm_model_deployment
     WHERE connection_key = 'anthropic-direct' AND wire_id !~ '^claude-[a-z0-9-]+$';
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 306: anthropic-direct wire ids that are not Claude API model ids: %', bad;
    END IF;

    SELECT string_agg(d.model_key, ', ' ORDER BY d.model_key) INTO ahead
      FROM shared.llm_model_deployment d
      JOIN shared.llm_model_deployment a
        ON a.model_key = d.model_key AND a.connection_key = 'acc3' AND a.enabled
     WHERE d.connection_key = 'anthropic-direct' AND d.origin = 'seed' AND d.priority <= a.priority;
    IF ahead IS NOT NULL THEN
        RAISE EXCEPTION 'migration 306: seeded Anthropic API deployments that would sort ahead of acc3: %', ahead;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('306', now(), 'AA-1002 S2: anthropic-direct deployments (priority 100, behind acc3) + cis_app UPDATE on '
                      'llm_provider_connection (enabled, updated_at, updated_by)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
