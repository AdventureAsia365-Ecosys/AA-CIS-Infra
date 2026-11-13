-- Migration crm-064: AA-1096 lane L4 (S279 thresholds audit; tech lead S279: every threshold, limit, cap and policy
-- value is editable on an admin page by the administrator) — the CRM settings registry: crm.setting_definition (one
-- row per setting, written only by migrations) and crm.setting_value (append-only, versioned values with a proposal /
-- approval trail, platform values and per-agency overrides), and the first CRM settings, seeded from today's
-- effective values.
--
-- Owner: AA-Partner (api/migrations/064_crm_settings_registry.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-064 = crm main max + 1 (crm-063 is the highest); if main moves,
-- renumber: file name, this header, the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS and the tests that name
-- it (git grep '064_' and 'crm-064').
--
-- Why. The S279 thresholds audit (root docs/audits/2026-11-13-S279-session/thresholds-audit/, sections 3.1, 5 and 6
-- lane L4) found 126 CRM thresholds, limits and caps; two can be changed on an AA admin page. A code literal or an env
-- var needs a deploy. CIS 407 (lane L1) built the mechanism for CIS: one table shape per owner schema, one reader
-- library (AA-CIS-App shared/settings/reader.py, vendored here as a byte copy), one admin page (CIS Platform ›
-- Settings, whose CRM tab relays to crm.ops.v1 /settings) and one CI guard (settings-lint). This file is the CRM's
-- copy of the tables, in schema crm (root ADR 0008a: the CRM reads no shared table).
--
-- What.
--   1. crm.setting_definition (platform table: AA configuration, no tenant column, no personal data): the CIS 407
--      shape — key (PK, 'crm.<area>.<name>'), app ('crm'), area, label, description, value_type (int | numeric | bool
--      | enum | duration_s | usd | pct | list | json), unit, min_value / max_value / allowed_values (the bounds;
--      widening one is a new migration, a reviewed PR), default_value (the approved seed = today's effective value),
--      scope_kind (platform | platform+tenant: an AA administrator may set one agency's own value), impact, approval
--      (single | maker_checker), evidence_required, env_override (the emergency env var the reader still honours for
--      one release, with a warning and a page badge), cache_s (reader cache, 5-3600 s) and enforced (false = stored
--      only). CHECKs keep the default inside its bounds. crm-001's default privileges give crm_app INSERT / UPDATE /
--      DELETE on every new crm table; the trigger crm.setting_definition_guard refuses every write by a role outside
--      crm_owner (a trigger, not a REVOKE, so a later blanket GRANT cannot reopen it) (the CIS 407 / 400 pattern: the
--      value trigger reads its bounds from this table, so the app role must not widen them).
--   2. crm.setting_value: one row per proposed value of a key at a scope (tenant_id NULL = the platform value; else one
--      agency's override, only for a platform+tenant key): value (jsonb), version (per key and scope, optimistic lock:
--      a proposal names the version it replaces, the API answers 409 on a stale one), status proposed -> approved |
--      rejected, approved -> superseded, effective_from (future dating allowed), proposed_by / proposed_at, reason
--      (>= 20 characters, the one break-glass minimum of the platform), evidence_ref, self_approved (dev-phase rule,
--      tech lead S279 Q2: while crm.settings.two_person_approval is off the administrator may approve their own
--      change), decided_by / decided_at / decision_note. At most one open proposal per key and scope. The key is
--      checked by the trigger, not by a foreign key: the agency erase removes an agency's rows through the one
--      foreign key, to crm.tenant_settings (ON DELETE CASCADE; tests/integration/test_crm010_schema.py
--      CASCADE_ERASED), and a second key to another parent would keep a row alive.
--   3. Trigger crm.setting_value_guard (BEFORE INSERT / UPDATE / DELETE, and TRUNCATE): an insert is a proposal of a
--      known key whose value matches the definition (type, bounds, allowed values; scope platform+tenant for a tenant
--      row; evidence_ref when evidence_required); an update may only decide a proposal (approved / rejected; for a
--      maker_checker key the decider is not the proposer unless self_approved, and a self-approval only while
--      crm.settings.two_person_approval is off; that flag is maker_checker itself, so once on, the person it checks
--      cannot switch it off alone; it is a platform row, read with app.tenant_id cleared for that one statement when
--      the decision is on an agency's row) or supersede an approved row; every other column is immutable. Outside crm_owner
--      the writer must be an AA staff context (app.actor platform:<staff sub>, the L1 console's actor) and the row's
--      proposed_by / decided_by must be that actor, so no agency request can write a setting. A platform row is never
--      deleted; an agency row goes with its agency (the erase deletes crm.tenant_settings; the FK cascades).
--   4. RLS on crm.setting_value (ENABLE + FORCE, policy setting_value_scope TO crm_owner, crm_app): a platform row is
--      seen only outside an agency context (the reader's snapshot, the ops routes), an agency row only inside that
--      agency's context (app.tenant_id: the agency's request or job transaction, the L1 console's platform_tx). Not a
--      tenant table of the base template (no trash columns: append-only history): listed in the platform tables of
--      tests/integration/test_crm002_tenancy.py with the reason. crm.setting_definition has no RLS (no tenant rows,
--      like crm.llm_stage_profile). No reader grant (AI context, insights and support never read either table).
--   5. The 27 CRM settings of lane L4 (seed block below, read by api/scripts/gen_settings_defaults.py into
--      api/app/platform_settings/compiled_defaults.json; tests/unit/test_aa1096_settings_seed_parity.py fails CI when
--      the two differ). No setting_value row is seeded: until an administrator approves a change every key resolves to
--      its default_value, which is today's effective value (Terraform's where it differs from the code default:
--      RATE_LIMIT_PUBLIC_PER_MINUTE 60 vs 120).
--
-- Retention (DM-7.1: root data standards Part B §7, rows added with this key). setting_definition: reference data,
-- kept while the key exists. setting_value: the change history of the CRM settings, kept for the life of the platform
-- (a few rows a month); an agency's own rows go with the agency (the erase deletes crm.tenant_settings, the FK
-- cascades).
-- PII (DM-6.1). reason and decision_note are free text typed by AA staff (a business reason, never personal data by
-- rule); proposed_by / decided_by are actor ids (platform:<staff sub>), never an e-mail.
--
-- Behaviour. None on apply: no value row, so every reader keeps today's value (the default). Nothing reads the tables
-- before the AA-Partner code PR; until this file is applied that code serves the compiled defaults (the same values)
-- and the ops /settings routes answer 503 settings_unavailable.
--
-- Class: contract (root ADR 0017 d3), so no migrate directive line. Everything is new (two tables, their constraints,
-- indexes, RLS on crm.setting_value, two functions and the triggers on the new tables, a foreign key from a new table,
-- comments, rows only in a table this file creates, and the shared.schema_versions registration), but the expand
-- post-check requires ENABLE + FORCE RLS on every new crm table (owners.yaml expand_rls_schemas) and
-- crm.setting_definition holds no agency rows: its only honest policy would be USING (true), which the RLS catalogue
-- guard refuses (rule t). It stays a platform table without RLS (like crm.llm_stage_profile; listed in the platform
-- tables of tests/integration/test_crm002_tenancy.py), and the file ships as contract: Infra Migration Apply applies it
-- once every job table is idle (root ADR 0017a), before the code PR (MIG-4). Re-runnable as a no-op like every contract
-- file (tests/integration/test_crm_migrations.py test_reapply_is_a_no_op): IF NOT EXISTS tables and indexes, CREATE OR
-- REPLACE functions and triggers, DROP POLICY IF EXISTS + CREATE POLICY, the seed ON CONFLICT (key) DO NOTHING.
--
-- Rollback (a forward crm- file, after the code that reads it is reverted): DROP TABLE crm.setting_value,
-- crm.setting_definition; DROP FUNCTION crm.setting_value_guard(),
-- crm.setting_definition_guard() (a destructive file, DRY RUN).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

CREATE TABLE IF NOT EXISTS crm.setting_definition (
    key                TEXT        NOT NULL,
    app                TEXT        NOT NULL,
    area               TEXT        NOT NULL,
    label              TEXT        NOT NULL,
    description        TEXT        NOT NULL,
    value_type         TEXT        NOT NULL,
    unit               TEXT,
    min_value          NUMERIC,
    max_value          NUMERIC,
    allowed_values     JSONB,
    default_value      JSONB       NOT NULL,
    scope_kind         TEXT        NOT NULL DEFAULT 'platform',
    impact             TEXT        NOT NULL,
    approval           TEXT        NOT NULL,
    evidence_required  BOOLEAN     NOT NULL DEFAULT false,
    env_override       TEXT,
    cache_s            INTEGER     NOT NULL DEFAULT 30,
    enforced           BOOLEAN     NOT NULL DEFAULT true,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT setting_definition_pkey PRIMARY KEY (key),
    CONSTRAINT setting_definition_key_chk CHECK (key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){2,}$' AND char_length(key) <= 120),
    CONSTRAINT setting_definition_app_chk CHECK (app = 'crm' AND key LIKE 'crm.%'),
    CONSTRAINT setting_definition_area_chk CHECK (area ~ '^[a-z][a-z0-9_]*$' AND char_length(area) <= 40),
    CONSTRAINT setting_definition_label_chk CHECK (char_length(label) BETWEEN 3 AND 120),
    CONSTRAINT setting_definition_description_chk CHECK (char_length(description) BETWEEN 20 AND 2000),
    CONSTRAINT setting_definition_type_chk CHECK (value_type IN ('int', 'numeric', 'bool', 'enum', 'duration_s', 'usd',
                                                                 'pct', 'list', 'json')),
    CONSTRAINT setting_definition_unit_chk CHECK (unit IS NULL OR char_length(unit) BETWEEN 1 AND 30),
    CONSTRAINT setting_definition_bounds_chk CHECK (min_value IS NULL OR max_value IS NULL OR min_value <= max_value),
    CONSTRAINT setting_definition_allowed_chk CHECK (
        (value_type = 'enum') = (allowed_values IS NOT NULL AND jsonb_typeof(allowed_values) = 'array'
                                 AND jsonb_array_length(allowed_values) >= 2)
        OR (value_type = 'list' AND (allowed_values IS NULL OR jsonb_typeof(allowed_values) = 'array'))),
    CONSTRAINT setting_definition_default_type_chk CHECK (CASE
        WHEN value_type IN ('int', 'numeric', 'duration_s', 'usd', 'pct') THEN jsonb_typeof(default_value) = 'number'
        WHEN value_type = 'bool' THEN jsonb_typeof(default_value) = 'boolean'
        WHEN value_type = 'enum' THEN jsonb_typeof(default_value) = 'string' AND allowed_values @> jsonb_build_array(default_value)
        WHEN value_type = 'list' THEN jsonb_typeof(default_value) = 'array'
        ELSE jsonb_typeof(default_value) IN ('object', 'array') END),
    CONSTRAINT setting_definition_default_bounds_chk CHECK (
        value_type NOT IN ('int', 'numeric', 'duration_s', 'usd', 'pct') OR jsonb_typeof(default_value) <> 'number'
        OR ((min_value IS NULL OR (default_value #>> '{}')::numeric >= min_value)
            AND (max_value IS NULL OR (default_value #>> '{}')::numeric <= max_value))),
    CONSTRAINT setting_definition_scope_chk CHECK (scope_kind IN ('platform', 'platform+tenant')),
    CONSTRAINT setting_definition_impact_chk CHECK (impact IN ('high', 'medium', 'low')),
    CONSTRAINT setting_definition_approval_chk CHECK (approval IN ('single', 'maker_checker')),
    CONSTRAINT setting_definition_env_chk CHECK (env_override IS NULL OR env_override ~ '^[A-Z][A-Z0-9_]{2,63}$'),
    CONSTRAINT setting_definition_cache_chk CHECK (cache_s BETWEEN 5 AND 3600)
);

CREATE TABLE IF NOT EXISTS crm.setting_value (
    id                UUID        NOT NULL DEFAULT gen_random_uuid(),
    key               TEXT        NOT NULL,
    tenant_id         UUID,
    value             JSONB       NOT NULL,
    version           INTEGER     NOT NULL,
    status            TEXT        NOT NULL DEFAULT 'proposed',
    effective_from    TIMESTAMPTZ NOT NULL DEFAULT now(),
    proposed_by       TEXT        NOT NULL,
    proposed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    reason            TEXT        NOT NULL,
    evidence_ref      TEXT,
    self_approved     BOOLEAN     NOT NULL DEFAULT false,
    decided_by        TEXT,
    decided_at        TIMESTAMPTZ,
    decision_note     TEXT,
    CONSTRAINT setting_value_pkey PRIMARY KEY (id),
    CONSTRAINT setting_value_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES crm.tenant_settings (tenant_id) ON DELETE CASCADE,
    CONSTRAINT setting_value_key_chk CHECK (key ~ '^crm(\.[a-z0-9_]+){2,}$' AND char_length(key) <= 120),
    CONSTRAINT setting_value_version_chk CHECK (version >= 1),
    CONSTRAINT setting_value_status_chk CHECK (status IN ('proposed', 'approved', 'rejected', 'superseded')),
    CONSTRAINT setting_value_reason_chk CHECK (char_length(btrim(reason)) BETWEEN 20 AND 2000),
    CONSTRAINT setting_value_evidence_chk CHECK (evidence_ref IS NULL OR char_length(btrim(evidence_ref)) BETWEEN 3 AND 500),
    CONSTRAINT setting_value_actor_chk CHECK (proposed_by ~ '^[A-Za-z0-9._:@-]{1,120}$'
        AND (decided_by IS NULL OR decided_by ~ '^[A-Za-z0-9._:@-]{1,120}$')),
    CONSTRAINT setting_value_decision_chk CHECK (
        (status = 'proposed' AND decided_by IS NULL AND decided_at IS NULL AND NOT self_approved)
        OR (status <> 'proposed' AND decided_by IS NOT NULL AND decided_at IS NOT NULL AND decided_at >= proposed_at)),
    CONSTRAINT setting_value_rejected_chk CHECK (status <> 'rejected' OR char_length(btrim(coalesce(decision_note, ''))) >= 3),
    CONSTRAINT setting_value_note_chk CHECK (decision_note IS NULL OR char_length(decision_note) <= 2000),
    CONSTRAINT setting_value_self_chk CHECK (NOT self_approved OR (status IN ('approved', 'superseded')
                                                                    AND decided_by = proposed_by))
);

CREATE UNIQUE INDEX IF NOT EXISTS setting_value_version_uq
    ON crm.setting_value (key, (coalesce(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid)), version);
CREATE UNIQUE INDEX IF NOT EXISTS setting_value_one_proposal_uq
    ON crm.setting_value (key, (coalesce(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid)))
    WHERE status = 'proposed';
CREATE INDEX IF NOT EXISTS setting_value_approved_idx
    ON crm.setting_value (key, tenant_id, effective_from DESC, version DESC) WHERE status = 'approved';
CREATE INDEX IF NOT EXISTS setting_value_tenant_idx
    ON crm.setting_value (tenant_id) WHERE tenant_id IS NOT NULL;

CREATE OR REPLACE FUNCTION crm.setting_value_guard() RETURNS trigger
    LANGUAGE plpgsql AS $fn$
DECLARE
    d crm.setting_definition%ROWTYPE;
    problem text;
    v jsonb;
    n numeric;
    elem jsonb;
    flag jsonb;
    agency text;
    staff text := NULLIF(current_setting('app.actor', true), '');
    is_owner boolean := pg_has_role(current_user, 'crm_owner', 'MEMBER');
BEGIN
    IF TG_OP = 'TRUNCATE' THEN
        RAISE EXCEPTION 'crm.setting_value is append-only: never truncated' USING ERRCODE = 'check_violation';
    END IF;
    IF TG_OP = 'DELETE' THEN
        IF OLD.tenant_id IS NULL THEN
            RAISE EXCEPTION 'crm.setting_value is append-only: a platform value is never deleted'
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN OLD;  -- an agency's own row, with its agency (the erase deletes crm.tenant_settings; the FK cascades)
    END IF;

    -- Only AA staff write settings: the L1 console's actor (platform:<staff sub>), named on the row it writes.
    IF NOT is_owner AND (staff IS NULL OR staff NOT LIKE 'platform:%') THEN
        RAISE EXCEPTION 'crm.setting_value is written by AA staff only (app.actor platform:<staff sub>), not by %',
            coalesce(staff, current_user) USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT * INTO d FROM crm.setting_definition WHERE key = NEW.key;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown setting %', NEW.key USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'proposed' THEN
            RAISE EXCEPTION 'a setting value is inserted as a proposal (status proposed)' USING ERRCODE = 'check_violation';
        END IF;
        IF NOT is_owner AND NEW.proposed_by <> staff THEN
            RAISE EXCEPTION 'proposed_by must be the acting staff member' USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.tenant_id IS NOT NULL AND d.scope_kind <> 'platform+tenant' THEN
            RAISE EXCEPTION 'setting % has no per-agency value (scope %)', NEW.key, d.scope_kind
                USING ERRCODE = 'check_violation';
        END IF;
        IF d.evidence_required AND NEW.evidence_ref IS NULL THEN
            RAISE EXCEPTION 'setting % needs an evidence reference', NEW.key USING ERRCODE = 'check_violation';
        END IF;
        -- the value against its definition (the API checks the same rules first, app/aa_settings/reader.py validate)
        v := NEW.value;
        <<check_value>>
        BEGIN
        IF d.value_type IN ('int', 'numeric', 'duration_s', 'usd', 'pct') THEN
            IF jsonb_typeof(v) <> 'number' THEN
                problem := 'value must be a number';
                EXIT check_value;
            END IF;
            n := (v #>> '{}')::numeric;
            IF d.value_type IN ('int', 'duration_s') AND n <> trunc(n) THEN
                problem := 'value must be a whole number';
                EXIT check_value;
            END IF;
            IF d.min_value IS NOT NULL AND n < d.min_value THEN
                problem := 'value is below the minimum ' || d.min_value;
                EXIT check_value;
            END IF;
            IF d.max_value IS NOT NULL AND n > d.max_value THEN
                problem := 'value is above the maximum ' || d.max_value;
                EXIT check_value;
            END IF;
        ELSIF d.value_type = 'bool' THEN
            IF jsonb_typeof(v) <> 'boolean' THEN
                problem := 'value must be true or false';
                EXIT check_value;
            END IF;
        ELSIF d.value_type = 'enum' THEN
            IF jsonb_typeof(v) <> 'string' OR NOT d.allowed_values @> jsonb_build_array(v) THEN
                problem := 'value must be one of ' || d.allowed_values::text;
                EXIT check_value;
            END IF;
        ELSIF d.value_type = 'list' THEN
            IF jsonb_typeof(v) <> 'array' THEN
                problem := 'value must be a list';
                EXIT check_value;
            END IF;
            IF d.allowed_values IS NOT NULL THEN
                FOR elem IN SELECT e FROM jsonb_array_elements(v) AS t (e) LOOP
                    IF NOT d.allowed_values @> jsonb_build_array(elem) THEN
                        problem := 'list item ' || elem::text || ' is not allowed';
                        EXIT check_value;
                    END IF;
                END LOOP;
            END IF;
        ELSE
            IF jsonb_typeof(v) NOT IN ('object', 'array') THEN
                problem := 'value must be a JSON object or list';
                EXIT check_value;
            END IF;
            IF jsonb_typeof(v) = 'object' THEN
                FOR elem IN SELECT e FROM jsonb_each(v) AS t (k, e) LOOP
                    IF jsonb_typeof(elem) <> 'number' AND (d.min_value IS NOT NULL OR d.max_value IS NOT NULL) THEN
                        problem := 'every entry must be a number';
                        EXIT check_value;
                    END IF;
                    IF jsonb_typeof(elem) = 'number' THEN
                        n := (elem #>> '{}')::numeric;
                        IF (d.min_value IS NOT NULL AND n < d.min_value) OR (d.max_value IS NOT NULL AND n > d.max_value) THEN
                            problem := 'entry ' || elem::text || ' is outside ' || coalesce(d.min_value::text, '-')
                                       || '..' || coalesce(d.max_value::text, '-');
                            EXIT check_value;
                        END IF;
                    END IF;
                END LOOP;
            END IF;
        END IF;
        END check_value;
        IF problem IS NOT NULL THEN
            RAISE EXCEPTION 'setting %: %', NEW.key, problem USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;

    -- UPDATE: only a decision on a proposal, or an approved row superseded by a newer approved one.
    IF NEW.id <> OLD.id OR NEW.key <> OLD.key OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.value <> OLD.value OR NEW.version <> OLD.version OR NEW.effective_from <> OLD.effective_from
       OR NEW.proposed_by <> OLD.proposed_by OR NEW.proposed_at <> OLD.proposed_at OR NEW.reason <> OLD.reason
       OR NEW.evidence_ref IS DISTINCT FROM OLD.evidence_ref THEN
        RAISE EXCEPTION 'crm.setting_value is append-only: only the decision columns change'
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'proposed' AND NEW.status IN ('approved', 'rejected') THEN
        IF NOT is_owner AND NEW.decided_by <> staff THEN
            RAISE EXCEPTION 'decided_by must be the acting staff member' USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.status = 'approved' AND d.approval = 'maker_checker' AND NEW.decided_by = NEW.proposed_by THEN
            IF NOT NEW.self_approved THEN
                RAISE EXCEPTION 'setting % needs a second person to approve (or a recorded self-approval)', NEW.key
                    USING ERRCODE = 'check_violation';
            END IF;
            -- A self-approval only while two-person approval is off: the latest approved platform value of
            -- crm.settings.two_person_approval in force, else its default (the API checks the same in the decision
            -- transaction first; this is the backstop). The flag is maker_checker itself. The platform row is seen
            -- only outside an agency context (RLS, FORCE: the owner too), so a decision on an agency's row reads it
            -- with app.tenant_id cleared for that one statement, then puts the agency context back.
            agency := current_setting('app.tenant_id', true);
            PERFORM set_config('app.tenant_id', '', true);
            SELECT v.value INTO flag FROM crm.setting_value v
             WHERE v.key = 'crm.settings.two_person_approval' AND v.tenant_id IS NULL
               AND v.status = 'approved' AND v.effective_from <= now()
             ORDER BY v.effective_from DESC, v.version DESC LIMIT 1;
            PERFORM set_config('app.tenant_id', coalesce(agency, ''), true);
            IF coalesce(flag,
                        (SELECT t.default_value FROM crm.setting_definition t
                          WHERE t.key = 'crm.settings.two_person_approval'),
                        'false'::jsonb) <> 'false'::jsonb THEN
                RAISE EXCEPTION 'setting % needs a second person to approve (two-person approval is on)', NEW.key
                    USING ERRCODE = 'check_violation';
            END IF;
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.status = 'approved' AND NEW.status = 'superseded' THEN
        IF NEW.decided_by IS DISTINCT FROM OLD.decided_by OR NEW.decided_at IS DISTINCT FROM OLD.decided_at
           OR NEW.decision_note IS DISTINCT FROM OLD.decision_note OR NEW.self_approved <> OLD.self_approved THEN
            RAISE EXCEPTION 'a superseded value keeps its decision' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'setting value status % -> % is not allowed', OLD.status, NEW.status USING ERRCODE = 'check_violation';
END
$fn$;

CREATE OR REPLACE TRIGGER setting_value_guard_trg
    BEFORE INSERT OR UPDATE OR DELETE ON crm.setting_value
    FOR EACH ROW EXECUTE FUNCTION crm.setting_value_guard();
CREATE OR REPLACE TRIGGER setting_value_guard_truncate_trg
    BEFORE TRUNCATE ON crm.setting_value
    FOR EACH STATEMENT EXECUTE FUNCTION crm.setting_value_guard();

-- Definitions come only from migrations. crm-001's default privileges give crm_app INSERT, UPDATE and DELETE on every
-- new crm table (the trigger holds even after a later blanket GRANT); without this guard the app role (or a script on its DSN) could
-- widen a bound, switch approval to single or drop evidence_required, and the value trigger reads its bounds from this
-- table. Only a member of crm_owner (DB Migrate runs crm/ files as crm_owner) may write a definition.
CREATE OR REPLACE FUNCTION crm.setting_definition_guard() RETURNS trigger
    LANGUAGE plpgsql AS $fn$
BEGIN
    IF NOT pg_has_role(current_user, 'crm_owner', 'MEMBER') THEN
        RAISE EXCEPTION 'crm.setting_definition is written only by migrations (crm_owner), not by %', current_user
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$fn$;

CREATE OR REPLACE TRIGGER setting_definition_guard_trg
    BEFORE INSERT OR UPDATE OR DELETE ON crm.setting_definition
    FOR EACH ROW EXECUTE FUNCTION crm.setting_definition_guard();
CREATE OR REPLACE TRIGGER setting_definition_guard_truncate_trg
    BEFORE TRUNCATE ON crm.setting_definition
    FOR EACH STATEMENT EXECUTE FUNCTION crm.setting_definition_guard();

-- RLS: a platform row only outside an agency context, an agency row only inside its own agency's context.
ALTER TABLE crm.setting_value ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.setting_value FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS setting_value_scope ON crm.setting_value;
CREATE POLICY setting_value_scope ON crm.setting_value
    TO crm_owner, crm_app
    USING ((tenant_id IS NULL AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL)
           OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK ((tenant_id IS NULL AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL)
                OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

COMMENT ON TABLE crm.setting_definition IS 'AA-1096 L4 (crm-064, S279 thresholds audit): one row per admin-editable CRM setting (threshold, limit, cap, policy value, platform default and range of an agency setting), written only by migrations (trigger setting_definition_guard); bounds widen only through a new migration. Resolution (app/platform_settings): env override (warning) -> approved agency value -> approved platform value -> default_value. Edited on CIS Platform › Settings (CRM tab) over crm.ops.v1 /settings. Platform configuration, no tenant column, no PII.';
COMMENT ON TABLE crm.setting_value IS 'AA-1096 L4 (crm-064): append-only, versioned values of crm.setting_definition keys (tenant_id NULL = the platform value, else one agency''s override of a platform+tenant key). proposed -> approved | rejected, approved -> superseded; written by AA staff only (app.actor platform:<staff sub>, the trigger setting_value_guard_trg). RLS: platform rows outside an agency context, an agency''s rows in its own. An agency''s rows go with its crm.tenant_settings row (erase, FK cascade).';
COMMENT ON COLUMN crm.setting_value.reason IS 'AA-1096 (crm-064): why the value changes, typed by AA staff (>= 20 characters). A business reason, never personal data.';
COMMENT ON COLUMN crm.setting_value.decision_note IS 'AA-1096 (crm-064): the approver''s note (required on a rejection), typed by AA staff.';
COMMENT ON COLUMN crm.setting_value.proposed_by IS 'AA-1096 (crm-064): the AA staff actor of the proposal, platform:<staff sub> (the L1 console actor). Never an e-mail.';
COMMENT ON COLUMN crm.setting_value.decided_by IS 'AA-1096 (crm-064): the AA staff actor of the decision, platform:<staff sub>. Never an e-mail.';
COMMENT ON COLUMN crm.setting_value.self_approved IS 'AA-1096 (crm-064): the proposer approved the change themselves (dev-phase rule, tech lead S279 Q2): allowed while crm.settings.two_person_approval is off; a high-impact one raises an AA ops e-mail.';

-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "crm.ai.budget_max_usd", "app": "crm", "area": "ai", "label": "AI budget ceiling per agency", "description": "The highest monthly AI budget an agency owner may set on Settings > AI (AA pays for the calls). An administrator may give one agency its own ceiling. Seeded from AI_BUDGET_MAX_USD (2 USD, the code default; Terraform does not set it).", "value_type": "usd", "unit": "USD/month", "min_value": 0, "max_value": 10000, "allowed_values": null, "default_value": 2, "scope_kind": "platform+tenant", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": "AI_BUDGET_MAX_USD", "cache_s": 30, "enforced": true},
{"key": "crm.ai.budget_default_usd", "app": "crm", "area": "ai", "label": "AI budget of a new agency", "description": "The monthly AI budget a new agency starts with, and the budget of an agency that has no settings row yet. Never above the agency's ceiling (the lower of the two applies).", "value_type": "usd", "unit": "USD/month", "min_value": 0, "max_value": 10000, "allowed_values": null, "default_value": 2, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.ai.draft_reply_max_tokens", "app": "crm", "area": "ai", "label": "AI draft reply output token cap", "description": "Output token cap of every route entry of the crm_draft_reply stage (the only CRM AI stage that writes text); a reply cut at the cap is logged truncated and the draft says reply by hand. Seeded from CRM_LLM_MAX_TOKENS (800, Terraform and code).", "value_type": "int", "unit": "tokens", "min_value": 50, "max_value": 4000, "allowed_values": null, "default_value": 800, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": "CRM_LLM_MAX_TOKENS", "cache_s": 30, "enforced": true},
{"key": "crm.rate.public_per_minute", "app": "crm", "area": "rate_limit", "label": "Public routes per address", "description": "Requests per client address per minute on the unauthenticated /crm/public routes and the health routes; 0 turns the limit off. Seeded from the Terraform value in force (60; the code default was 120).", "value_type": "int", "unit": "requests/min", "min_value": 0, "max_value": 10000, "allowed_values": null, "default_value": 60, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": "RATE_LIMIT_PUBLIC_PER_MINUTE", "cache_s": 30, "enforced": true},
{"key": "crm.rate.intake_per_minute", "app": "crm", "area": "rate_limit", "label": "Inquiry form and client page writes per address", "description": "Inquiry-form submissions and every anonymous client-page write (proposal page, sign-in code, Book now booking, hold, accept, pay) per client address per minute; 0 turns the limit off. Seeded from Terraform (5).", "value_type": "int", "unit": "writes/min", "min_value": 0, "max_value": 1000, "allowed_values": null, "default_value": 5, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": "RATE_LIMIT_INTAKE_PER_MINUTE", "cache_s": 30, "enforced": true},
{"key": "crm.rate.intake_form_per_hour", "app": "crm", "area": "rate_limit", "label": "Submissions per inquiry form per hour", "description": "Submissions one inquiry form (and the Book now bookings of its key) takes per hour whatever the address, charged only after every other check; 0 turns the quota off. An administrator may give a busy agency its own quota. Seeded from Terraform (200).", "value_type": "int", "unit": "submissions/hour", "min_value": 0, "max_value": 100000, "allowed_values": null, "default_value": 200, "scope_kind": "platform+tenant", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": "RATE_LIMIT_INTAKE_FORM_PER_HOUR", "cache_s": 30, "enforced": true},
{"key": "crm.rate.member_per_minute", "app": "crm", "area": "rate_limit", "label": "Requests per member per agency", "description": "Requests one member makes to /crm/v1 for one agency per minute (429 rate_limited above it), the same for every plan; 0 turns the limit off. Seeded from the code default (600; Terraform does not set it).", "value_type": "int", "unit": "requests/min", "min_value": 0, "max_value": 100000, "allowed_values": null, "default_value": 600, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": "RATE_LIMIT_MEMBER_PER_MINUTE", "cache_s": 30, "enforced": true},
{"key": "crm.rate.ai_per_minute", "app": "crm", "area": "rate_limit", "label": "AI calls per agency per minute", "description": "CRM AI gateway calls one agency makes per minute; above it a call is refused rate_limited before anything is scrubbed or paid. 0 turns the limit off. Seeded from the code default (6).", "value_type": "int", "unit": "calls/min", "min_value": 0, "max_value": 600, "allowed_values": null, "default_value": 6, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": "RATE_LIMIT_AI_PER_MINUTE", "cache_s": 30, "enforced": true},
{"key": "crm.payments.refund_owner_threshold_default", "app": "crm", "area": "payments", "label": "Refund owner-approval threshold of a new agency", "description": "A refund or cancellation-fee change above this amount (in the agency's base currency) needs the owner; an agent approves up to it. The value a new agency starts with, and the threshold of an agency with no settings row.", "value_type": "numeric", "unit": "base currency", "min_value": 0, "max_value": 10000000, "allowed_values": null, "default_value": 1000, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.payments.invoice_reminder_every_days", "app": "crm", "area": "payments", "label": "Overdue invoice reminder every", "description": "Days between two reminders of one overdue invoice to the trip owner (the first is the day after the due date). The CRM never writes to the client by itself; the agent chases.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 30, "allowed_values": null, "default_value": 3, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.payments.invoice_reminder_max", "app": "crm", "area": "payments", "label": "Overdue invoice reminders at most", "description": "Reminders one overdue invoice gives the trip owner at most; 0 stops the reminders.", "value_type": "int", "unit": "reminders", "min_value": 0, "max_value": 20, "allowed_values": null, "default_value": 5, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.agency_defaults.discount_owner_limit_pct", "app": "crm", "area": "agency_defaults", "label": "Discount owner limit of a new agency", "description": "A proposal discount above this percent needs the owner's approval. The value a new agency starts with (the owner changes it on Settings > Pricing, 0 to 100 %).", "value_type": "pct", "unit": "%", "min_value": 0, "max_value": 100, "allowed_values": null, "default_value": 10, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.agency_defaults.markup_max_pct", "app": "crm", "area": "agency_defaults", "label": "Retail markup ceiling", "description": "The highest default retail markup an agency owner may set per AA product type on Settings > Retail markup (from 0 %).", "value_type": "pct", "unit": "%", "min_value": 0, "max_value": 300, "allowed_values": null, "default_value": 300, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.agency_defaults.price_checks_per_minute", "app": "crm", "area": "agency_defaults", "label": "Book now price checks of a new agency", "description": "Book now price checks a minute an agency's page takes from every address together: the value a new agency starts with, and the ceiling of an agency with no settings row.", "value_type": "int", "unit": "checks/min", "min_value": 10, "max_value": 600, "allowed_values": null, "default_value": 60, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.agency_defaults.price_checks_per_minute_min", "app": "crm", "area": "agency_defaults", "label": "Book now price checks: lowest an owner may set", "description": "The lowest Book now price checks a minute an agency owner may set on Settings > Online booking (inside the database bounds 10 to 600).", "value_type": "int", "unit": "checks/min", "min_value": 10, "max_value": 600, "allowed_values": null, "default_value": 10, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.agency_defaults.price_checks_per_minute_max", "app": "crm", "area": "agency_defaults", "label": "Book now price checks: highest an owner may set", "description": "The highest Book now price checks a minute an agency owner may set on Settings > Online booking (inside the database bounds 10 to 600).", "value_type": "int", "unit": "checks/min", "min_value": 10, "max_value": 600, "allowed_values": null, "default_value": 600, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.agency_defaults.trash_days", "app": "crm", "area": "agency_defaults", "label": "Trash window of a new agency", "description": "Days a deleted record stays restorable before the daily lifecycle run purges it: the value a new agency starts with, and the window of an agency with no settings row.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 30, "allowed_values": null, "default_value": 7, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.agency_defaults.trash_days_min", "app": "crm", "area": "agency_defaults", "label": "Trash window: shortest an owner may set", "description": "The shortest trash window an agency owner may set on Settings > Data and privacy (inside the database bounds 1 to 30 days).", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 30, "allowed_values": null, "default_value": 1, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.agency_defaults.trash_days_max", "app": "crm", "area": "agency_defaults", "label": "Trash window: longest an owner may set", "description": "The longest trash window an agency owner may set on Settings > Data and privacy (inside the database bounds 1 to 30 days).", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 30, "allowed_values": null, "default_value": 30, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.agency_defaults.auto_archive_months", "app": "crm", "area": "agency_defaults", "label": "Auto-archive after (new agency)", "description": "Months without activity after which the daily lifecycle run archives a client: the value a new agency starts with, and the window of an agency with no settings row.", "value_type": "int", "unit": "months", "min_value": 12, "max_value": 120, "allowed_values": null, "default_value": 36, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.agency_defaults.auto_archive_months_min", "app": "crm", "area": "agency_defaults", "label": "Auto-archive: shortest an owner may set", "description": "The shortest auto-archive window an agency owner may set on Settings > Data and privacy (inside the database bounds 12 to 120 months).", "value_type": "int", "unit": "months", "min_value": 12, "max_value": 120, "allowed_values": null, "default_value": 12, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.agency_defaults.auto_archive_months_max", "app": "crm", "area": "agency_defaults", "label": "Auto-archive: longest an owner may set", "description": "The longest auto-archive window an agency owner may set on Settings > Data and privacy (inside the database bounds 12 to 120 months).", "value_type": "int", "unit": "months", "min_value": 12, "max_value": 120, "allowed_values": null, "default_value": 120, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.retention.lifecycle_dry_run", "app": "crm", "area": "retention", "label": "Lifecycle deletes: dry run", "description": "On: every hard delete of agency data (submission redaction, LLM-call purge, trash purge, auto-archive, an owner's erasure or offboarding erase) only counts. Off lets them run, but only while Terraform's LIFECYCLE_DRY_RUN floor is off too (two keys: Terraform keeps a hard never-delete floor, tech lead S279 Q7).", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": true, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.retention.job_dry_run", "app": "crm", "area": "retention", "label": "Job row retention: dry run", "description": "On: the daily crm_job_retention run only counts the finished crm.job rows it would delete. Off deletes them, but only while Terraform's JOB_RETENTION_DRY_RUN floor is off too.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": true, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.retention.audit_dry_run", "app": "crm", "area": "retention", "label": "Audit partition drop: dry run", "description": "On: the daily audit retention only reports the monthly audit partitions past 12 months it would drop (both Object Lock copies stay). Off drops them, but only while Terraform's AUDIT_RETENTION_DRY_RUN floor is off too.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": true, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.retention.partner_account_cleanup_dry_run", "app": "crm", "area": "retention", "label": "Unused partner account clean-up: dry run", "description": "On: the partner-account clean-up only counts the never-used partner pool accounts it would delete. Off deletes them while Terraform's PARTNER_ACCOUNT_CLEANUP_DRY_RUN floor is off (it is today). Seeded off: today's effective value.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": false, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.settings.two_person_approval", "app": "crm", "area": "platform", "label": "Two-person approval of CRM settings", "description": "On: a maker-checker CRM setting needs a second AA staff member to approve. Off (dev phase, tech lead S279 Q2): the administrator may approve their own change with a reason, and a high-impact change e-mails AA ops. Turn on at the first prod or paying tenant. This flag is maker-checker itself: while it is on, turning it off needs a second person.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": false, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-064', now(), 'AA-1096 L4: crm.setting_definition + crm.setting_value (the CRM settings registry, 27 seeded settings; RLS: platform rows outside an agency context, agency rows in their own)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
