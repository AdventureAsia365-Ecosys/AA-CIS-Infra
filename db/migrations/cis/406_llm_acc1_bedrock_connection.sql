-- Migration 406: AA-1095 (S278) — Bedrock connection `acc1` (the payer account of acc3's organization) and its 13
-- chat-model deployments, seeded SWITCHED OFF; the route order is set afterwards by one route-control version.
-- break-glass: tech lead S278 12/11: AWS refuses chat models on acc3; acc1 rows seeded off, behind every live row
--
-- Why. AWS refuses 7 chat models on acc3 (the LLM account) at account level since 29/10 (AccessDeniedException "not
-- available for this account", TPM quota 0 on five; AWS cases open), so every Claude 5.x / GPT stage falls to the
-- vendor APIs. On 12/11/2026 every chat model the gateway uses answered a real Converse call on acc1 through its
-- global. inference profile (tech lead's SSO session, us-west-1). Tech lead decision S278: serve Bedrock from acc1
-- while acc3 is blocked; acc3 stays configured behind it. Root ADR 0001a, Note S278 (acc1 holds the Bedrock invoker
-- role only); AA-CIS-Infra accounts/acc1-bedrock (role AA1-Bedrock-Invoker, ExternalId below).
--
-- What.
--   1. llm_provider_connection_account_id_env_check: + 'BEDROCK_ACCT_PAYER' (the env var AA-CIS-Infra sets on the
--      api and worker task definitions with acc1's ID; this public repo writes no account ID down). Values added only.
--   2. Connection acc1: bedrock / assume_role, role AA1-Bedrock-Invoker, ExternalId aa1095-satellite-bedrock-acc1,
--      us-west-1, account from env BEDROCK_ACCT_PAYER, aws_only, served_roles writer / judge / validate (no embedding
--      deployment), balance_source none (acc1 has no Cost Explorer reader; spend comes from the ledger), failure
--      domain bedrock:BEDROCK_ACCT_PAYER:aws_only. Timeout, retries, concurrency, rpm and the monthly cap are copied
--      from acc3 (cap 100 USD when acc3 has none: migration 366's value). ENABLED = false: the code that resolves
--      BEDROCK_ACCT_PAYER (AA-CIS-App PR "acc1 Bedrock connection", REQUIRED_CIS_SCHEMA not raised) and the Infra env
--      must be live first; the admin Test connection works on a switched-off connection, so the 13 models are probed
--      before the switch. ON CONFLICT DO NOTHING: an admin's later edit is kept.
--   3. Its shared.llm_connection_cost_policy row, copied from acc3's (alert 80 % / hard stop when acc3 has none).
--   4. 13 deployments on acc1 (origin seed, enabled = the catalog row's AND the acc3 row's enabled, priority 90 =
--      behind every live deployment of the model (Dev: 10 to 30), and still ahead of the Anthropic API rows 306 / 376
--      seed at 100, whose re-run guard refuses an AWS row sorting after them): wire id = global.<Bedrock model id>,
--      the profiles that answered on 12/11:
--        sonnet-5-5 opus-5-5 haiku-5-5 sonnet-5 sonnet-4-6 opus-4-6 haiku-4-5 (Claude)
--        gpt-6-luna gpt-6-astra gpt-6-sol gpt-5.6-luna gpt-6.1-sol gpt-6.1-terra (GPT). The candidates (gpt-6-sol,
--        gpt-6.1-sol, gpt-6.1-terra: catalog row off; opus-4-6: acc3 row off, served by the Anthropic API since 376)
--        get an acc1 row that is off too, so no candidate becomes routable by this file; the admin Test connection
--        still probes a switched-off deployment, and switching one on is an admin decision
--      A model with no catalog row is skipped (NOTICE).
--   5. The same 13 catalog rows (same predicate as the deployments) get an "acc1" key in bedrock_profile_ids = the
--      deployment's wire id, only where the row has none (a re-run changes nothing). Standing invariant of the
--      wire-drift guard (tests/integration/test_aa1002_deployment_wire_drift.py): an enabled Bedrock deployment calls
--      bedrock_profile_ids ->> connection_key, so the catalog and the deployment row change together. TripPlanner
--      reads the profiles too and never calls acc1: its gateway skips every account but BEDROCK_ACCT_PRIMARY's (acc3)
--      and acc2. updated_by and updated_at of the catalog rows are not touched (only the profile key and a note):
--      the older replays key on them. This re-adds the key 295 (AA-998) removed, now with an account that holds the
--      Bedrock invoker role only (root ADR 0001a, Note S278); 295's own guards (no acc1-only row, no account_route
--      'acc1') stay true. The replay tests of 295 / 367 set the key aside (tests/integration/_later_deployments.py).
--   6. Register 406.
--   The route order (tech lead S278, 15:45; model-first: Claude = Anthropic API, then acc1, then acc3; GPT = acc1,
--   then acc3 (skipped while it refuses), then the model's OpenAI API twin) is NOT set here: after the deploy one run-script of the root repo (tools/llm/, on the CIS
--   container) switches acc1 on and saves the per-family provider order (api/services/llm_family_order.py) as one
--   route-control version (audited, one-click revert).
--   Chains, scopes, account_route and every existing deployment / connection row are not touched.
--
-- Behaviour on Dev. None until the switch: the connection is off, so deployment_plan never picks an acc1 row. The
-- static attempt count of the route rules (llm_route_chains attempt_cap) counts every deployment row, on or off: a chain's
-- count grows by one per model with an acc1 row, so some chains count more than 6; the route control reports them as
-- existing warnings (never a blocking error: the rows exist before any save). At run time refused acc3 rows are skipped
-- by the refusal circuit at 0 USD and are not attempts. The replay tests of 366 / 376 / 383 set these rows aside before
-- re-running those files (tests/integration/_later_deployments.py).
--
-- Guards (RAISE rolls the whole file back):
--   before: the registry tables (304, 317, 322); connection acc3 is a bedrock assume_role row; no acc1 row of another
--           kind / role / ExternalId (a key collision).
--   after:  the acc1 row is bedrock / assume_role / aws_only with the role, ExternalId, region and env above and is
--           off unless an admin had switched it on; every seeded deployment's wire id is the decided global. profile;
--           every acc1 deployment's catalog row has bedrock_profile_ids ->> 'acc1' = that wire id (a catalog acc1 key
--           with another value is refused, never overwritten); an acc3 deployment of the same model with another
--           wire id is a NOTICE.
--
-- Order with the code. Before the AA-CIS-App code PR (MIG-4: this migration-only PR, then the code). Old code never
-- calls acc1 (connection off). Contract file (it changes a CHECK and inserts config rows): applied on Dev by the Infra
-- Migration Apply once every job table is idle (root ADR 0017a).
--
-- Preflight (read-only, as cis_app; expected: acc3_rows = 1, acc1_rows = 0, acc1_profiles = 0, models = 13):
--   SELECT (SELECT count(*) FROM shared.llm_provider_connection WHERE connection_key = 'acc3') AS acc3_rows,
--          (SELECT count(*) FROM shared.llm_provider_connection WHERE connection_key = 'acc1') AS acc1_rows,
--          (SELECT count(*) FROM shared.llm_model_catalog WHERE bedrock_profile_ids ? 'acc1') AS acc1_profiles,
--          (SELECT count(*) FROM shared.llm_model_catalog WHERE model_key IN ('sonnet-5-5', 'opus-5-5', 'haiku-5-5',
--             'sonnet-5', 'sonnet-4-6', 'opus-4-6', 'haiku-4-5', 'gpt-6-luna', 'gpt-6-astra', 'gpt-6-sol',
--             'gpt-5.6-luna', 'gpt-6.1-sol', 'gpt-6.1-terra')) AS models;
--
-- Rollback (a NEW forward migration): switch acc1 off (PATCH /admin/llm-connections/acc1 {"enabled": false}) first,
-- revert the route-control version, then DELETE the 13 acc1 deployments, the cost policy row and the connection, and
-- remove the "acc1" key of bedrock_profile_ids (bedrock_profile_ids - 'acc1') on the 13 catalog rows.
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of these tables.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    actor     constant text := 'migration-406-aa1095';
    ext_id    constant text := 'aa1095-satellite-bedrock-acc1';
    models    constant jsonb := '{
        "sonnet-5-5":    "global.anthropic.claude-sonnet-5-5",
        "opus-5-5":      "global.anthropic.claude-opus-5-5",
        "haiku-5-5":     "global.anthropic.claude-haiku-5-5",
        "sonnet-5":      "global.anthropic.claude-sonnet-5",
        "sonnet-4-6":    "global.anthropic.claude-sonnet-4-6",
        "opus-4-6":      "global.anthropic.claude-opus-4-6-v1",
        "haiku-4-5":     "global.anthropic.claude-haiku-4-5-20251001-v1:0",
        "gpt-6-luna":    "global.openai.gpt-6-luna",
        "gpt-6-astra":   "global.openai.gpt-6-astra",
        "gpt-6-sol":     "global.openai.gpt-6-sol",
        "gpt-5.6-luna":  "global.openai.gpt-5.6-luna",
        "gpt-6.1-sol":   "global.openai.gpt-6.1-sol",
        "gpt-6.1-terra": "global.openai.gpt-6.1-terra"
    }'::jsonb;
    acc3      record;
    pol       record;
    c         record;
    missing   text;
    bad       text;
    seeded    int;
BEGIN
    -- ── 0. Guards: predecessors ─────────────────────────────────────────────────────────────────────────────────
    IF to_regclass('shared.llm_provider_connection') IS NULL OR to_regclass('shared.llm_model_deployment') IS NULL
       OR to_regclass('shared.llm_connection_cost_policy') IS NULL THEN
        RAISE EXCEPTION 'migration 406: the connection registry (304), the cost policy (317) is missing';
    END IF;
    SELECT * INTO acc3 FROM shared.llm_provider_connection WHERE connection_key = 'acc3';
    IF NOT FOUND OR acc3.kind <> 'bedrock' OR acc3.auth_mode <> 'assume_role' THEN
        RAISE EXCEPTION 'migration 406: connection acc3 is missing or not a bedrock assume_role row';
    END IF;
    SELECT * INTO c FROM shared.llm_provider_connection WHERE connection_key = 'acc1';
    IF FOUND AND (c.kind <> 'bedrock' OR c.auth_mode <> 'assume_role' OR c.external_id IS DISTINCT FROM ext_id
                  OR c.role_name IS DISTINCT FROM 'AA1-Bedrock-Invoker') THEN
        RAISE EXCEPTION 'migration 406: a connection acc1 exists with another kind / role / ExternalId';
    END IF;

    -- ── 1. The account env allowlist: + BEDROCK_ACCT_PAYER ────────────────────────────────────────────────────
    ALTER TABLE shared.llm_provider_connection DROP CONSTRAINT IF EXISTS llm_provider_connection_account_id_env_check;
    ALTER TABLE shared.llm_provider_connection
        ADD CONSTRAINT llm_provider_connection_account_id_env_check
        CHECK (account_id_env IS NULL OR account_id_env IN ('BEDROCK_ACCT_PRIMARY', 'BEDROCK_ACCT_PAYER'));
    COMMENT ON CONSTRAINT llm_provider_connection_account_id_env_check ON shared.llm_provider_connection IS
        'AA-1095 (CIS 406): + BEDROCK_ACCT_PAYER (acc1, Bedrock serving while acc3 is blocked); was '
        'BEDROCK_ACCT_PRIMARY only (304). Same list as shared/llm_client/connections.ACCOUNT_ID_ENVS.';

    -- ── 2. The connection (off) ───────────────────────────────────────────────────────────────────────────────
    INSERT INTO shared.llm_provider_connection
        (connection_key, kind, auth_mode, label, account_id, account_id_env, region, role_name, external_id,
         secret_name, credential_env, base_url, data_scope, timeout_s, max_retries, max_concurrency, rpm_limit,
         monthly_budget_usd, enabled, notes, updated_by, failure_domain, served_roles, balance_source)
    VALUES
        ('acc1', 'bedrock', 'assume_role', 'Bedrock, payer account (assume role)', NULL, 'BEDROCK_ACCT_PAYER',
         'us-west-1', 'AA1-Bedrock-Invoker', ext_id, NULL, NULL, NULL, 'aws_only', acc3.timeout_s, acc3.max_retries,
         acc3.max_concurrency, acc3.rpm_limit, coalesce(acc3.monthly_budget_usd, 100), false,
         'AA-1095 (S278): Bedrock chat models while acc3 is blocked (root ADR 0001a, Note S278). Seeded off; '
         'a route-control version switches it on and sets the provider order per model family.',
         actor, 'bedrock:BEDROCK_ACCT_PAYER:aws_only', ARRAY['writer', 'judge', 'validate']::text[], 'none')
    ON CONFLICT (connection_key) DO NOTHING;

    -- ── 3. Its cost policy (acc3's) ───────────────────────────────────────────────────────────────────────────
    SELECT alert_pct, hard_stop INTO pol FROM shared.llm_connection_cost_policy WHERE connection_key = 'acc3';
    INSERT INTO shared.llm_connection_cost_policy (connection_key, alert_pct, hard_stop, notes, updated_by)
    VALUES ('acc1', coalesce(pol.alert_pct, 80), coalesce(pol.hard_stop, true),
            'AA-1095 (S278): copied from acc3 (migration 406).', actor)
    ON CONFLICT (connection_key) DO NOTHING;

    -- ── 4. The 13 deployments, behind every existing deployment of the model ─────────────────────────────────
    SELECT string_agg(m.key, ', ' ORDER BY m.key) INTO missing
      FROM jsonb_each_text(models) AS m (key, value)
     WHERE NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog k WHERE k.model_key = m.key);
    IF missing IS NOT NULL THEN
        RAISE NOTICE 'migration 406: no catalog row, no acc1 deployment: %', missing;
    END IF;

    INSERT INTO shared.llm_model_deployment
        (model_key, connection_key, wire_id, priority, enabled, origin, notes, updated_by)
    SELECT m.key, 'acc1', m.value, 90,
           k.enabled AND coalesce((SELECT a.enabled FROM shared.llm_model_deployment a
                                    WHERE a.model_key = m.key AND a.connection_key = 'acc3'), true),
           'seed',
           'AA-1095 (S278): answered a Converse call on acc1 through this profile (12/11/2026).', actor
      FROM jsonb_each_text(models) AS m (key, value)
      JOIN shared.llm_model_catalog k ON k.model_key = m.key
    ON CONFLICT (model_key, connection_key) DO NOTHING;

    -- ── 5. The catalog profile those deployments call (the wire-drift invariant), only where none is set ───────
    UPDATE shared.llm_model_catalog k
       SET bedrock_profile_ids = k.bedrock_profile_ids || jsonb_build_object('acc1', m.value),
           notes = COALESCE(k.notes || ' ', '') || 'AA-1095 (S278): acc1 profile = its acc1 deployment (CIS 406).'
      FROM jsonb_each_text(models) AS m (key, value)
     WHERE k.model_key = m.key
       AND NOT (k.bedrock_profile_ids ? 'acc1');

    -- ── 6. Guards: the rows as decided ────────────────────────────────────────────────────────────────────────
    SELECT * INTO c FROM shared.llm_provider_connection WHERE connection_key = 'acc1';
    IF c.kind <> 'bedrock' OR c.auth_mode <> 'assume_role' OR c.data_scope <> 'aws_only'
       OR c.role_name <> 'AA1-Bedrock-Invoker' OR c.external_id <> ext_id OR c.region <> 'us-west-1'
       OR c.account_id_env IS DISTINCT FROM 'BEDROCK_ACCT_PAYER' OR c.account_id IS NOT NULL THEN
        RAISE EXCEPTION 'migration 406: connection acc1 is not the decided row';
    END IF;
    IF c.enabled THEN
        RAISE NOTICE 'migration 406: connection acc1 is already switched on (kept)';
    END IF;

    SELECT string_agg(d.model_key, ', ' ORDER BY d.model_key) INTO bad
      FROM shared.llm_model_deployment d
     WHERE d.connection_key = 'acc1' AND d.wire_id IS DISTINCT FROM models ->> d.model_key;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 406: acc1 deployments whose wire id is not the decided profile: %', bad;
    END IF;

    SELECT string_agg(d.model_key || ' (' || COALESCE(k.bedrock_profile_ids ->> 'acc1', '<none>') || ')', ', '
                      ORDER BY d.model_key) INTO bad
      FROM shared.llm_model_deployment d
      JOIN shared.llm_model_catalog k ON k.model_key = d.model_key
     WHERE d.connection_key = 'acc1' AND k.bedrock_profile_ids ->> 'acc1' IS DISTINCT FROM d.wire_id;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 406: catalog acc1 profiles that are not the acc1 deployment''s wire id: %', bad;
    END IF;

    SELECT string_agg(d.model_key || ' (' || d.wire_id || ')', ', ' ORDER BY d.model_key) INTO bad
      FROM shared.llm_model_deployment d
     WHERE d.connection_key = 'acc3' AND models ? d.model_key AND d.wire_id <> models ->> d.model_key;
    IF bad IS NOT NULL THEN
        RAISE NOTICE 'migration 406: acc3 deployments with another wire id than acc1''s: %', bad;
    END IF;

    SELECT count(*) INTO seeded FROM shared.llm_model_deployment WHERE connection_key = 'acc1';
    RAISE NOTICE 'migration 406: % acc1 deployments, connection acc1 enabled=%, monthly cap % USD', seeded, c.enabled,
        c.monthly_budget_usd;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('406', now(), 'AA-1095: Bedrock connection acc1 (off) + 13 chat-model deployments and their acc1 catalog '
                      'profiles, account env allowlist + BEDROCK_ACCT_PAYER')
ON CONFLICT (version) DO NOTHING;

COMMIT;
