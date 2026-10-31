-- Migration 320: AA-1017 (AI gateway v2, registry v2 part 1; root ADR 0009 §2-§4) — model families as data, stage x
-- model parameters, a per-deployment api_style, the truncated health class and a route deadline column.
--
-- Why. The catalog's maker was a closed CHECK (vendor IN anthropic, openai, cohere, typesafe): cataloguing a model of
-- another maker (Amazon Nova, Meta Llama, Moonshot Kimi on Bedrock) needed a migration of the CHECK and code. Request
-- parameters (max tokens, temperature, effort) lived only in code and in deployment request_defaults, the api style
-- of a deployment could only be the catalog's, the provider-health class list had no 'truncated' (ledger v2 has it,
-- migration 319), and a route had no place for a deadline. Design step 4 (S261, approved): families, parameters and
-- capabilities are data; the gateway code reads them and keeps today's behaviour while they are empty.
--
-- What.
--   1. shared.llm_model_family (family_key PK, label, maker, notes, audit columns): the maker of a logical model.
--      Seeded with the four vendors the catalog uses today (anthropic, openai, cohere, typesafe) and three makers the
--      design names for acc2 Bedrock trials (amazon, meta, moonshot). No catalog row uses those three yet.
--   2. shared.llm_model_catalog.family text, NULL = read vendor (code: coalesce(family, vendor)); backfilled from
--      vendor for every row whose vendor is a family; FK to llm_model_family (ON UPDATE CASCADE, ON DELETE RESTRICT)
--      added NOT VALID, then validated. Nullable on purpose: TripPlanner and older tests insert catalog rows without
--      it, and a NOT NULL would break them for no gain (the code falls back to vendor).
--   3. DROP the closed CHECK llm_model_catalog_vendor_check (vendor stays as a free text column, kept for TripPlanner
--      and the admin; the maker list is the family table now).
--   4. shared.stage_model_params (stage, model_key) -> max_tokens, min_output_tokens, temperature, effort,
--      reasoning_mode, notes, audit columns. EMPTY: the gateway reads it (shared/llm_client/stage_params.py, precedence
--      call site -> stage x model -> protocol default), so an empty table changes nothing. FK model_key -> catalog
--      (ON DELETE CASCADE). Changed by migration only (cis_app SELECT).
--   5. shared.llm_model_deployment.api_style text, NULL = the catalog row's api_style (every row today), CHECK the
--      catalog's api_style list.
--   6. shared.llm_provider_health: the class CHECK gains 'truncated' (a reply cut at its token limit is recorded, not
--      counted as a failure; migration 319 has the same class on the ledger). Replaced NOT VALID, then validated.
--   7. shared.llm_role_config.route_deadline_s integer, NULL = no deadline (every row; read from AA-1018 part 2).
--      Migration-only: no cis_app column grant.
--   8. Register 320.
--   Grants: cis_app SELECT on the two new tables; tripplanner none (it reads the catalog, which keeps its columns).
--
-- Behaviour. None on apply: the route snapshot (Q0 of the S262 plan: role config, deployment, connection, catalog
-- model_key / enabled / api_style / profiles, alias rows) is unchanged, no row of an existing table changes except
-- catalog.family (a new column), and the code that reads these tables keeps today's behaviour on empty / NULL values.
--
-- Class: contract (root ADR 0017 d3), so no "-- migrate: expand" header: a dropped CHECK, a replaced CHECK and a new FK
-- on existing tables. The tables are tiny (catalog 14 rows, health a few dozen); lock_timeout bounds each lock.
-- Order (ADR 0017 d1, MIG-4): (1) this migration-only PR merges to AA-CIS-App main (with 321); (2) the byte copy in
-- AA-CIS-Infra db/migrations/cis/ merges (Copy Guard green); (3) a manual DB Migrate apply (check, then apply);
-- (4) the bot/db-schema-reference PR merges; (5) only then the AA-1017 code PR merges (it raises readiness to 322).
--
-- Rollback (a NEW forward migration, after the code is reverted; the old code ignores every object added here):
--   ALTER TABLE shared.llm_role_config DROP COLUMN route_deadline_s;
--   restore llm_provider_health_class_check without 'truncated' (once no row holds it);
--   ALTER TABLE shared.llm_model_deployment DROP COLUMN api_style;
--   DROP TABLE shared.stage_model_params;
--   restore llm_model_catalog_vendor_check (once every vendor is one of the four);
--   ALTER TABLE shared.llm_model_catalog DROP COLUMN family; DROP TABLE shared.llm_model_family;     (a destructive file)
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of every table here.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.llm_model_catalog') IS NULL OR to_regclass('shared.llm_model_deployment') IS NULL
       OR to_regclass('shared.llm_provider_health') IS NULL OR to_regclass('shared.llm_role_config') IS NULL THEN
        RAISE EXCEPTION 'migration 320: a registry table is missing (llm_model_catalog, llm_model_deployment, '
                        'llm_provider_health, llm_role_config): apply 304 and 309 first';
    END IF;
END $$;

-- ── 1. shared.llm_model_family ──────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS shared.llm_model_family (
    family_key  text        PRIMARY KEY,
    label       text        NOT NULL,
    maker       text        NOT NULL,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  text        NOT NULL,
    CONSTRAINT llm_model_family_key_check CHECK (family_key ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
    CONSTRAINT llm_model_family_label_check CHECK (length(label) BETWEEN 1 AND 100),
    CONSTRAINT llm_model_family_maker_check CHECK (length(maker) BETWEEN 1 AND 100)
);

COMMENT ON TABLE shared.llm_model_family IS
    'AA-1017 (ADR 0009 §3): the maker of a logical model (llm_model_catalog.family). The host comes from the '
    'connection kind, the path from the deployment. Changed by migration only.';

INSERT INTO shared.llm_model_family (family_key, label, maker, notes, updated_by) VALUES
    ('anthropic', 'Claude',          'Anthropic',   'Claude models (Bedrock and the Anthropic API).',
     'migration-320-aa1017'),
    ('openai',    'GPT',             'OpenAI',      'GPT models (Bedrock and the OpenAI API).', 'migration-320-aa1017'),
    ('cohere',    'Cohere Embed',    'Cohere',      'Embedding models on Bedrock.', 'migration-320-aa1017'),
    ('typesafe',  'Jev',             'TypeSafe',    'The Jev decision model (TypeSafe API).', 'migration-320-aa1017'),
    ('amazon',    'Nova',            'Amazon',      'No catalog row yet (acc2 trial candidate, design step 4).',
     'migration-320-aa1017'),
    ('meta',      'Llama',           'Meta',        'No catalog row yet (acc2 trial candidate, design step 4).',
     'migration-320-aa1017'),
    ('moonshot',  'Kimi',            'Moonshot AI', 'No catalog row yet (acc2 trial candidate, design step 4).',
     'migration-320-aa1017')
ON CONFLICT (family_key) DO NOTHING;

-- ── 2-3. shared.llm_model_catalog: family (FK), the closed vendor CHECK dropped ──────────────────────────────────

ALTER TABLE shared.llm_model_catalog ADD COLUMN IF NOT EXISTS family text;

COMMENT ON COLUMN shared.llm_model_catalog.family IS
    'AA-1017: the model''s family (shared.llm_model_family). NULL = read vendor (code: coalesce(family, vendor)).';

UPDATE shared.llm_model_catalog c
   SET family = c.vendor
 WHERE c.family IS NULL
   AND EXISTS (SELECT 1 FROM shared.llm_model_family f WHERE f.family_key = c.vendor);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_model_catalog_family_fk'
                      AND conrelid = 'shared.llm_model_catalog'::regclass) THEN
        ALTER TABLE shared.llm_model_catalog ADD CONSTRAINT llm_model_catalog_family_fk
            FOREIGN KEY (family) REFERENCES shared.llm_model_family (family_key)
            ON UPDATE CASCADE ON DELETE RESTRICT NOT VALID;
        ALTER TABLE shared.llm_model_catalog VALIDATE CONSTRAINT llm_model_catalog_family_fk;
    END IF;
END $$;

ALTER TABLE shared.llm_model_catalog DROP CONSTRAINT IF EXISTS llm_model_catalog_vendor_check;

-- ── 4. shared.stage_model_params (empty) ─────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS shared.stage_model_params (
    stage              text         NOT NULL,
    model_key          text         NOT NULL REFERENCES shared.llm_model_catalog (model_key) ON DELETE CASCADE,
    max_tokens         integer,
    min_output_tokens  integer,
    temperature        numeric(3,2),
    effort             text,
    reasoning_mode     text,
    notes              text,
    created_at         timestamptz  NOT NULL DEFAULT now(),
    updated_at         timestamptz  NOT NULL DEFAULT now(),
    updated_by         text         NOT NULL,
    PRIMARY KEY (stage, model_key),
    CONSTRAINT stage_model_params_stage_check CHECK (stage ~ '^[a-z0-9][a-z0-9_]{0,62}$'),
    CONSTRAINT stage_model_params_max_tokens_check CHECK (max_tokens IS NULL OR max_tokens BETWEEN 1 AND 1000000),
    CONSTRAINT stage_model_params_min_output_check CHECK (
        min_output_tokens IS NULL OR (min_output_tokens BETWEEN 1 AND 1000000
                                      AND (max_tokens IS NULL OR min_output_tokens <= max_tokens))),
    CONSTRAINT stage_model_params_temperature_check CHECK (temperature IS NULL OR temperature BETWEEN 0 AND 2),
    CONSTRAINT stage_model_params_effort_check CHECK (
        effort IS NULL OR effort IN ('low', 'medium', 'high', 'xhigh', 'max')),
    CONSTRAINT stage_model_params_reasoning_mode_check CHECK (
        reasoning_mode IS NULL OR reasoning_mode IN ('off', 'adaptive'))
);

COMMENT ON TABLE shared.stage_model_params IS
    'AA-1017 (ADR 0009 §4): request parameters per stage x model. Precedence: the call site''s explicit value, then '
    'this row, then the protocol default (shared/llm_client/stage_params.py). NULL = not set. Empty = today''s '
    'behaviour. Changed by migration only.';

GRANT SELECT ON shared.llm_model_family TO cis_app;
GRANT SELECT ON shared.stage_model_params TO cis_app;

-- ── 5. shared.llm_model_deployment.api_style ─────────────────────────────────────────────────────────────────────

ALTER TABLE shared.llm_model_deployment ADD COLUMN IF NOT EXISTS api_style text;

COMMENT ON COLUMN shared.llm_model_deployment.api_style IS
    'AA-1017 (design D2): how this deployment is called. NULL = the catalog row''s api_style (every row at 320).';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_model_deployment_api_style_check'
                      AND conrelid = 'shared.llm_model_deployment'::regclass) THEN
        ALTER TABLE shared.llm_model_deployment ADD CONSTRAINT llm_model_deployment_api_style_check CHECK (
            api_style IS NULL OR api_style IN ('anthropic_native', 'converse', 'openai_chat', 'embed', 'decide',
                                               'anthropic_messages', 'openai_responses')) NOT VALID;
        ALTER TABLE shared.llm_model_deployment VALIDATE CONSTRAINT llm_model_deployment_api_style_check;
    END IF;
END $$;

-- ── 6. shared.llm_provider_health: + 'truncated' ─────────────────────────────────────────────────────────────────

DO $$
DECLARE
    class_def text;
BEGIN
    SELECT pg_get_constraintdef(oid) INTO class_def FROM pg_constraint
     WHERE conname = 'llm_provider_health_class_check' AND conrelid = 'shared.llm_provider_health'::regclass;
    IF class_def IS NULL OR position('truncated' IN class_def) = 0 THEN
        ALTER TABLE shared.llm_provider_health DROP CONSTRAINT IF EXISTS llm_provider_health_class_check;
        ALTER TABLE shared.llm_provider_health ADD CONSTRAINT llm_provider_health_class_check CHECK (
            last_error_class IS NULL OR last_error_class IN ('access_denied', 'quota_exhausted', 'throttled',
                                                             'credential', 'other', 'truncated')) NOT VALID;
        ALTER TABLE shared.llm_provider_health VALIDATE CONSTRAINT llm_provider_health_class_check;
    END IF;
END $$;

-- ── 7. shared.llm_role_config.route_deadline_s ───────────────────────────────────────────────────────────────────

ALTER TABLE shared.llm_role_config ADD COLUMN IF NOT EXISTS route_deadline_s integer;

COMMENT ON COLUMN shared.llm_role_config.route_deadline_s IS
    'AA-1017 / AA-1018: the wall-time budget of the whole route in seconds. NULL = no deadline (every row at 320).';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_role_config_route_deadline_check'
                      AND conrelid = 'shared.llm_role_config'::regclass) THEN
        ALTER TABLE shared.llm_role_config ADD CONSTRAINT llm_role_config_route_deadline_check CHECK (
            route_deadline_s IS NULL OR route_deadline_s BETWEEN 1 AND 3600) NOT VALID;
        ALTER TABLE shared.llm_role_config VALIDATE CONSTRAINT llm_role_config_route_deadline_check;
    END IF;
END $$;

-- ── 8. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('320', now(), 'AA-1017 registry v2: llm_model_family + catalog.family, vendor CHECK dropped, '
                      'stage_model_params (empty), deployment api_style, health class truncated, route_deadline_s')
ON CONFLICT (version) DO NOTHING;

COMMIT;
