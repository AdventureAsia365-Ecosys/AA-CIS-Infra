-- Migration 370: AA-1042 (S268, AI gateway route control center, slice "Admin controls") — the route order mode as a
-- DB setting, versioned route configs with who / when / diff, the route config version on every CIS ledger row, the
-- provider order per model editable by the admin, and the retired gpt-4.1 deployment switched off.
--
-- Why. The tech lead (S267): "every routing setting is editable in the admin, and every change is audited, previewed
-- and revertible". Until now the route order mode was the ECS env var LLM_ROUTE_AWS_FIRST (a deploy to change it), the
-- provider order of a model (which deployment of the same model is tried first: acc3 or its vendor API) only changed
-- by migration, and no route change could be reverted in one click. The daily probe still calls the gpt-4.1 deployment
-- on openai-direct although the model was retired in S235 (migration 224 disabled its catalog row only).
--
-- What.
--   1. shared.llm_route_settings: ONE row (singleton = true).
--        order_mode       text NOT NULL: model_first (each model on all its deployments before the next model, the
--                         tech lead's S267 default) | aws_first (every AWS deployment of the route first, then the
--                         vendor APIs). Read by the gateway (shared/llm_client/route_settings.py, 20 s cache per
--                         process); the env var LLM_ROUTE_AWS_FIRST is only the bootstrap default while this row
--                         cannot be read. Seeded model_first: the env var is not set on Dev (the gateway's default).
--        current_version  bigint NOT NULL: the route config version in force (shared.llm_route_config_version).
--        updated_at / updated_by.
--   2. shared.llm_route_config_version: one row per route config version, never updated or deleted by the app.
--        version          bigint PK (current_version + 1, under the settings row lock);
--        created_at / created_by (the staff actor, 'migration-370-aa1042' for the baseline, 'external' for a change
--                         the app did not make, e.g. a later migration, recorded when the next admin change starts);
--        action           baseline | save | preset | revert | external;
--        preset           the preset key of a preset action; reverted_from: the version a revert restored;
--        note             at most 500 characters (the admin's why);
--        snapshot         jsonb {order_mode, routes: {stage: {model_id, fallback_model_ids}}, priorities:
--                         {model_key: {connection_key: priority}}}: what one click restores;
--        diff             jsonb array of the changes against the previous version (kind order_mode / route /
--                         provider_order, before, after).
--      Version 1 = the baseline: the routes and priorities after this file, order_mode model_first.
--   3. shared.llm_call_log.route_config_version bigint NULL: the route config version in force when a CIS row was
--      written. Set by the BEFORE INSERT trigger llm_call_log_route_version (function
--      shared.llm_call_log_stamp_route_version(), SECURITY INVOKER: X1 / MIG-6 allow no SECURITY DEFINER routine in
--      shared, migration 245's guard) on rows whose app is 'cis' (or NULL) and that carry no value, when the inserting
--      role may read shared.llm_route_settings (cis_app, step 4; a role that may not gets NULL instead of a refused
--      ledger row); TripPlanner rows (app 'tripplanner', its own gateway) stay NULL, and so does every row written
--      before this file. The ledger INSERT statements of the CIS gateway and of the shared core
--      (shared/aa_llm/ledger.py, synced to other repos) are unchanged. The trigger reads one row by primary key and
--      never raises: no settings row = NULL.
--   4. cis_app: SELECT, UPDATE on shared.llm_route_settings; SELECT, INSERT on shared.llm_route_config_version (no
--      UPDATE / DELETE: the history is append-only for the app); UPDATE (priority, updated_at, updated_by) on
--      shared.llm_model_deployment (the provider order per model; enabled, wire_id and prices stay migration-only).
--      REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner first (and EXECUTE on the trigger function from
--      PUBLIC and cis_app): on Dev cis_owner's default privileges (245) would give cis_app every table right and
--      EXECUTE on the function. A guard checks the result.
--   5. The gpt-4.1 deployment on openai-direct: enabled = false (catalog row disabled since 224, model retired S235;
--      the daily probe calls every enabled deployment). No route names gpt-4.1 (guard).
--   6. Register 370.
--
-- Class: contract (ALTERs shared.llm_call_log, adds a trigger to it, changes rows and grants of
-- shared.llm_model_deployment). On Dev it is applied by Infra Migration Apply once every job table is idle (root ADR
-- 0017a). The code PR (admin route control, the gateway reading the order mode from the DB) merges after the apply; the
-- code tolerates this file missing (the admin tab answers 503, the gateway falls back to the env var).
--
-- Guards (RAISE rolls the whole file back):
--   before: shared.llm_role_config, shared.llm_model_deployment, shared.llm_call_log exist; 367 registered.
--   after:  one settings row with a version row behind it; no enabled gpt-4.1 deployment; no stage route names gpt-4.1;
--           cis_app holds exactly the step 4 rights (no UPDATE / DELETE on the versions, no EXECUTE on the trigger
--           function), aa_app_user and catalog_owner read neither table.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.llm_role_config') IS NULL OR to_regclass('shared.llm_model_deployment') IS NULL
       OR to_regclass('shared.llm_call_log') IS NULL THEN
        RAISE EXCEPTION 'migration 370: a gateway table is missing (llm_role_config, llm_model_deployment, '
                        'llm_call_log)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '367') THEN
        RAISE EXCEPTION 'migration 370: apply 367 first';
    END IF;
END $$;

-- ── 1. the route settings (one row) ──────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS shared.llm_route_settings (
    singleton        boolean     NOT NULL DEFAULT true,
    order_mode       text        NOT NULL DEFAULT 'model_first',
    current_version  bigint      NOT NULL,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       text        NOT NULL DEFAULT 'migration-370-aa1042',
    CONSTRAINT llm_route_settings_pkey PRIMARY KEY (singleton),
    CONSTRAINT llm_route_settings_singleton_check CHECK (singleton),
    CONSTRAINT llm_route_settings_order_mode_check CHECK (order_mode IN ('model_first', 'aws_first')),
    CONSTRAINT llm_route_settings_version_check CHECK (current_version >= 1),
    CONSTRAINT llm_route_settings_updated_by_check CHECK (length(updated_by) BETWEEN 1 AND 128)
);

COMMENT ON TABLE shared.llm_route_settings IS
    'AA-1042 (CIS 370): the route settings of the AI gateway, one row. order_mode is read by the gateway '
    '(shared/llm_client/route_settings.py, 20 s cache per process; the env var LLM_ROUTE_AWS_FIRST only while this '
    'row cannot be read); current_version is the route config version in force. Edited by the admin route control '
    '(/admin/ai-gateway/route-control), each change a new shared.llm_route_config_version row.';

-- ── 2. the route config versions ─────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS shared.llm_route_config_version (
    version        bigint      NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     text        NOT NULL,
    action         text        NOT NULL,
    preset         text,
    reverted_from  bigint,
    note           text,
    snapshot       jsonb       NOT NULL,
    diff           jsonb       NOT NULL DEFAULT '[]'::jsonb,
    CONSTRAINT llm_route_config_version_pkey PRIMARY KEY (version),
    CONSTRAINT llm_route_config_version_reverted_from_fkey FOREIGN KEY (reverted_from)
        REFERENCES shared.llm_route_config_version (version),
    CONSTRAINT llm_route_config_version_version_check CHECK (version >= 1),
    CONSTRAINT llm_route_config_version_action_check
        CHECK (action IN ('baseline', 'save', 'preset', 'revert', 'external')),
    CONSTRAINT llm_route_config_version_preset_check
        CHECK ((action = 'preset') = (preset IS NOT NULL) AND (preset IS NULL OR preset ~ '^[a-z0-9_]{1,40}$')),
    CONSTRAINT llm_route_config_version_revert_check CHECK ((action = 'revert') = (reverted_from IS NOT NULL)),
    CONSTRAINT llm_route_config_version_note_check CHECK (note IS NULL OR length(note) <= 500),
    CONSTRAINT llm_route_config_version_created_by_check CHECK (length(created_by) BETWEEN 1 AND 128),
    CONSTRAINT llm_route_config_version_snapshot_check CHECK (jsonb_typeof(snapshot) = 'object'),
    CONSTRAINT llm_route_config_version_diff_check CHECK (jsonb_typeof(diff) = 'array')
);

COMMENT ON TABLE shared.llm_route_config_version IS
    'AA-1042 (CIS 370): every route config of the AI gateway, one row per change (admin save, preset, revert; '
    'external = a change the app did not make, recorded before the next admin change). snapshot = what a one-click '
    'revert restores (order_mode, each stage''s primary + fallbacks, each model''s deployment priorities); diff = the '
    'changes against the previous version. Append-only for the app (cis_app: SELECT, INSERT).';
COMMENT ON COLUMN shared.llm_route_config_version.snapshot IS
    'AA-1042 (370): {"order_mode": "model_first"|"aws_first", "routes": {stage: {"model_id": key, '
    '"fallback_model_ids": [key, ...]}}, "priorities": {model_key: {connection_key: priority}}}.';

-- the baseline: version 1, the state after this file (step 5 runs first so the snapshot has no enabled gpt-4.1 row;
-- priorities are not changed by it)

-- ── 5. the retired gpt-4.1 deployment off ────────────────────────────────────────────────────────────────────────

UPDATE shared.llm_model_deployment
   SET enabled = false,
       notes = 'Retired (S235, catalog row disabled by 224); switched off by 370 so the daily probe stops calling it.',
       updated_at = now(),
       updated_by = 'migration-370-aa1042'
 WHERE model_key = 'gpt-4.1' AND enabled;

INSERT INTO shared.llm_route_config_version (version, created_by, action, note, snapshot, diff)
SELECT 1, 'migration-370-aa1042', 'baseline',
       'Baseline: the routes and provider order when route versions started (CIS 370).',
       jsonb_build_object(
           'order_mode', 'model_first',
           'routes', COALESCE((SELECT jsonb_object_agg(stage, jsonb_build_object(
                                          'model_id', model_id,
                                          'fallback_model_ids', to_jsonb(COALESCE(fallback_model_ids, '{}'::text[]))))
                                 FROM shared.llm_role_config), '{}'::jsonb),
           'priorities', COALESCE((SELECT jsonb_object_agg(model_key, p)
                                     FROM (SELECT model_key, jsonb_object_agg(connection_key, priority) AS p
                                             FROM shared.llm_model_deployment GROUP BY model_key) d), '{}'::jsonb)),
       '[]'::jsonb
 WHERE NOT EXISTS (SELECT 1 FROM shared.llm_route_config_version);

INSERT INTO shared.llm_route_settings (singleton, order_mode, current_version, updated_by)
SELECT true, 'model_first', max(version), 'migration-370-aa1042' FROM shared.llm_route_config_version
ON CONFLICT (singleton) DO NOTHING;

-- ── 3. the route config version on every CIS ledger row ──────────────────────────────────────────────────────────

ALTER TABLE shared.llm_call_log ADD COLUMN IF NOT EXISTS route_config_version bigint;

COMMENT ON COLUMN shared.llm_call_log.route_config_version IS
    'AA-1042 (CIS 370): the route config version (shared.llm_route_config_version) in force when this CIS row was '
    'written, set by the trigger llm_call_log_route_version. NULL: TripPlanner rows and every row before 370. The '
    'gateway reloads its route caches within 20 s of a new version, so a row written in those seconds may name the '
    'new version for a call routed by the previous one.';

CREATE OR REPLACE FUNCTION shared.llm_call_log_stamp_route_version() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.route_config_version IS NULL AND COALESCE(NEW.app, 'cis') = 'cis'
       AND has_table_privilege('shared.llm_route_settings', 'SELECT') THEN
        SELECT s.current_version INTO NEW.route_config_version FROM shared.llm_route_settings s WHERE s.singleton;
    END IF;
    RETURN NEW;
END
$fn$;

COMMENT ON FUNCTION shared.llm_call_log_stamp_route_version() IS
    'AA-1042 (CIS 370): BEFORE INSERT on shared.llm_call_log: a CIS row (app cis or NULL) without a value gets '
    'shared.llm_route_settings.current_version when the inserting role may read it (else NULL: a ledger row is '
    'never refused for it); reads nothing else, writes nothing.';

DROP TRIGGER IF EXISTS llm_call_log_route_version ON shared.llm_call_log;
CREATE TRIGGER llm_call_log_route_version
    BEFORE INSERT ON shared.llm_call_log
    FOR EACH ROW EXECUTE FUNCTION shared.llm_call_log_stamp_route_version();

-- ── 4. grants ────────────────────────────────────────────────────────────────────────────────────────────────────

-- REVOKE from cis_app, aa_app_user and catalog_owner too (the 345 / 353 pattern): on Dev DB Migrate creates these
-- objects as cis_owner, whose default privileges (245) give cis_app SELECT, INSERT, UPDATE, DELETE on every new table
-- and EXECUTE on every new function. Without it the app could rewrite or delete the version history.
REVOKE ALL ON shared.llm_route_settings, shared.llm_route_config_version
    FROM PUBLIC, cis_app, aa_app_user, catalog_owner;
-- A trigger function needs no EXECUTE right of the inserting role (X1 rule, test_aa860_migration_244).
REVOKE ALL ON FUNCTION shared.llm_call_log_stamp_route_version() FROM PUBLIC, cis_app;
GRANT SELECT, UPDATE ON shared.llm_route_settings TO cis_app;
GRANT SELECT, INSERT ON shared.llm_route_config_version TO cis_app;
GRANT UPDATE (priority, updated_at, updated_by) ON shared.llm_model_deployment TO cis_app;

-- ── guards ───────────────────────────────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    routed text;
BEGIN
    IF (SELECT count(*) FROM shared.llm_route_settings) <> 1 THEN
        RAISE EXCEPTION 'migration 370: expected one route settings row';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_route_settings s
                     JOIN shared.llm_route_config_version v ON v.version = s.current_version) THEN
        RAISE EXCEPTION 'migration 370: the current route config version has no version row';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.llm_model_deployment WHERE model_key = 'gpt-4.1' AND enabled) THEN
        RAISE EXCEPTION 'migration 370: an enabled gpt-4.1 deployment is left';
    END IF;
    SELECT string_agg(stage, ', ' ORDER BY stage) INTO routed
      FROM shared.llm_role_config
     WHERE model_id = 'gpt-4.1' OR 'gpt-4.1' = ANY (fallback_model_ids) OR shadow_model_id = 'gpt-4.1';
    IF routed IS NOT NULL THEN
        RAISE EXCEPTION 'migration 370: stages still route to the retired gpt-4.1: %', routed;
    END IF;
    -- the grants as step 4 leaves them, checked here so Dev (cis_owner default privileges) fails loudly
    IF NOT has_table_privilege('cis_app', 'shared.llm_route_settings', 'SELECT')
       OR NOT has_table_privilege('cis_app', 'shared.llm_route_settings', 'UPDATE')
       OR NOT has_table_privilege('cis_app', 'shared.llm_route_config_version', 'SELECT')
       OR NOT has_table_privilege('cis_app', 'shared.llm_route_config_version', 'INSERT') THEN
        RAISE EXCEPTION 'migration 370: cis_app lacks a right step 4 grants';
    END IF;
    IF has_table_privilege('cis_app', 'shared.llm_route_config_version', 'UPDATE')
       OR has_table_privilege('cis_app', 'shared.llm_route_config_version', 'DELETE')
       OR has_table_privilege('cis_app', 'shared.llm_route_config_version', 'TRUNCATE')
       OR has_table_privilege('cis_app', 'shared.llm_route_settings', 'INSERT')
       OR has_table_privilege('cis_app', 'shared.llm_route_settings', 'DELETE')
       OR has_table_privilege('cis_app', 'shared.llm_route_settings', 'TRUNCATE')
       OR has_column_privilege('cis_app', 'shared.llm_model_deployment', 'enabled', 'UPDATE')
       OR has_function_privilege('cis_app', 'shared.llm_call_log_stamp_route_version()', 'EXECUTE')
       OR has_function_privilege('public', 'shared.llm_call_log_stamp_route_version()', 'EXECUTE') THEN
        RAISE EXCEPTION 'migration 370: cis_app or PUBLIC holds a right this file does not grant (default privileges '
                        'of the creating role?)';
    END IF;
    IF has_table_privilege('aa_app_user', 'shared.llm_route_config_version', 'SELECT')
       OR has_table_privilege('catalog_owner', 'shared.llm_route_config_version', 'SELECT')
       OR has_table_privilege('aa_app_user', 'shared.llm_route_settings', 'SELECT')
       OR has_table_privilege('catalog_owner', 'shared.llm_route_settings', 'SELECT') THEN
        RAISE EXCEPTION 'migration 370: aa_app_user or catalog_owner may read the route control tables';
    END IF;
END $$;

-- ── 6. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('370', now(), 'AA-1042 route control: shared.llm_route_settings (order mode, current version), '
                      'shared.llm_route_config_version (versions with snapshot and diff), '
                      'llm_call_log.route_config_version (trigger), deployment priority editable by cis_app, '
                      'gpt-4.1 deployment off')
ON CONFLICT (version) DO NOTHING;

COMMIT;
