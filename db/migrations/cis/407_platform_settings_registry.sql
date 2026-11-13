-- migrate: expand
-- Migration 407: S279 thresholds lane L1 (tech lead S279: every threshold, limit, cap and policy value is editable on an
-- admin page by the administrator) — the platform settings registry: shared.setting_definition (one row per setting,
-- written only by migrations) and shared.setting_value (append-only, versioned values with a proposal / approval
-- trail), and the first CIS settings, seeded from today's effective values.
--
-- Why. The S279 thresholds audit (root docs/audits/2026-11-13-S279-session/thresholds-audit/, sections 5 and 6 lane L1)
-- found 780 thresholds, limits and caps; only 68 can be changed on an admin page. A code literal, an env var or a
-- registry YAML value needs a deploy. This file is the mechanism the audit designs (section 5.1): one table shape per
-- owner schema, one reader library (shared/settings, a 30 s cache with last-good fallback), one admin page (Platform ›
-- Settings, API /admin/settings/registry) and one CI guard (settings-lint).
--
-- What.
--   1. shared.setting_definition: key (PK, '<app>.<area>.<name>'), app, area, label, description, value_type (int |
--      numeric | bool | enum | duration_s | usd | pct | list | json), unit, min_value / max_value / allowed_values (the
--      bounds; widening one is a new migration, a reviewed PR), default_value (the approved seed = today's effective
--      value), scope_kind (platform | platform+tenant), impact (high | medium | low), approval (single |
--      maker_checker), evidence_required (an eval / replay reference is required on every change), env_override (the
--      emergency env var the reader still honours for one release, with a warning and a page badge), cache_s (reader
--      cache, 5-3600 s) and enforced (false = stored only: the page shows "not enforced yet"). CHECKs keep the default
--      inside its bounds. cis_app reads it only: rows come from migrations. The trigger
--      shared.setting_definition_guard refuses every write by a role outside cis_owner (CIS 245's default privileges
--      give cis_app INSERT / UPDATE / DELETE on every new shared table and an expand file cannot REVOKE them, as CIS 400
--      notes; the value trigger reads its bounds from this table, so a widened bound must not be writable by the app).
--   2. shared.setting_value: one row per proposed value of a key at a scope (tenant_id NULL = platform): value (jsonb),
--      version (per key and scope, optimistic lock: a proposal names the version it replaces, the API answers 409 on
--      a stale one), status proposed -> approved | rejected, approved -> superseded, effective_from (future dating
--      allowed), proposed_by / proposed_at, reason (>= 20 characters, the one break-glass minimum of the platform),
--      evidence_ref, self_approved (the dev-phase rule: the administrator may approve their own high-impact change
--      with a reason; the API e-mails the tech lead), decided_by / decided_at / decision_note. At most one open
--      proposal per key and scope.
--   3. Trigger shared.setting_value_guard (BEFORE INSERT / UPDATE / DELETE): an insert must be a proposal of a known
--      key whose value matches the definition (type, bounds, allowed values; scope platform+tenant for a tenant row;
--      evidence_ref when evidence_required); an update may only decide a proposal (approved / rejected, decider and
--      time set; maker_checker: the decider is not the proposer unless self_approved, and a self-approval only while
--      cis.settings.two_person_approval is off; the flag is maker_checker itself, so once on, the person it checks
--      cannot switch it off alone) or supersede an approved row;
--      every other column is immutable; a platform row is never deleted (a tenant row goes with its tenant: FK ON
--      DELETE CASCADE, the offboarding erase).
--   4. The 25 CIS settings of lane L1 (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json; tests/unit/test_s279_settings_seed_parity.py fails CI when the two
--      differ). No setting_value row is seeded: until an administrator approves a change, every key resolves to its
--      default_value, which is today's effective value (Terraform's where it differs from the code default:
--      T7_BLOG_MIN_SEED_WORDS 600 vs 0).
--   5. RLS on both tables (ENABLE + FORCE, the X1 cis_app / cis_owner parity policies; setting_value has a tenant_id
--      column: X2 allowlist rule a, CIS only, no tenant-pool grant). GRANT cis_app SELECT on the definitions; SELECT,
--      INSERT, UPDATE, DELETE on the values: DELETE only for the offboarding erasure of a tenant's own rows
--      (services/erasure/inventory.py); the trigger refuses deleting a platform row.
--
-- PII (DM-6.1). setting_value.reason and decision_note are free text typed by staff (pii:free_text, a business reason,
-- never personal data by rule); proposed_by / decided_by are actor ids (admin:<uuid>), never an e-mail.
--
-- Retention (DM-7.1). setting_definition: reference data, kept while the key exists. setting_value: kept for the life
-- of the platform (it is the change history the audit asks for, a few rows a month); a tenant's rows go with the
-- tenant (the offboarding erasure deletes them, services/erasure/inventory.py; FK cascade as the backstop). Rows in root data standards Part B section 7, in the root PR of this
-- change (merged before the Infra copy).
--
-- Behaviour. None on apply: no value row, so every reader keeps today's value (the default). The code PR that reads
-- the registry ships with this file; until the file is applied the reader serves the compiled defaults (the same
-- values) and the admin routes answer 503 "not migrated".
--
-- Class: expand (root ADR 0017 d3): two new tables with their constraints, indexes, RLS (ENABLE + FORCE, policies),
-- three new functions and the triggers on the new tables, an FK from a new table, grants and comments on new objects,
-- rows inserted only into a table this file creates (and the shared.schema_versions registration); no existing
-- object changes, no DO block.
--
-- Number. 406 is the highest on main (13/11/2026, the acc1 Bedrock connection).
--
-- Rollback (a new forward migration, after the code is reverted): DROP TABLE shared.setting_value,
-- shared.setting_definition and DROP FUNCTION shared.setting_value_guard, shared.setting_value_problem,
-- shared.setting_definition_guard (a destructive
-- file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of schema
-- shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.setting_definition (
    key                text        NOT NULL,
    app                text        NOT NULL,
    area               text        NOT NULL,
    label              text        NOT NULL,
    description        text        NOT NULL,
    value_type         text        NOT NULL,
    unit               text,
    min_value          numeric,
    max_value          numeric,
    allowed_values     jsonb,
    default_value      jsonb       NOT NULL,
    scope_kind         text        NOT NULL DEFAULT 'platform',
    impact             text        NOT NULL,
    approval           text        NOT NULL,
    evidence_required  boolean     NOT NULL DEFAULT false,
    env_override       text,
    cache_s            integer     NOT NULL DEFAULT 30,
    enforced           boolean     NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT setting_definition_pkey PRIMARY KEY (key),
    CONSTRAINT setting_definition_key_chk CHECK (key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){2,}$' AND char_length(key) <= 120),
    CONSTRAINT setting_definition_app_chk CHECK (app IN ('cis', 'tripplanner', 'booking', 'crm')
        AND key LIKE app || '.%'),
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

CREATE TABLE IF NOT EXISTS shared.setting_value (
    id                uuid        NOT NULL DEFAULT gen_random_uuid(),
    key               text        NOT NULL,
    tenant_id         uuid,
    value             jsonb       NOT NULL,
    version           integer     NOT NULL,
    status            text        NOT NULL DEFAULT 'proposed',
    effective_from    timestamptz NOT NULL DEFAULT now(),
    proposed_by       text        NOT NULL,
    proposed_at       timestamptz NOT NULL DEFAULT now(),
    reason            text        NOT NULL,
    evidence_ref      text,
    self_approved     boolean     NOT NULL DEFAULT false,
    decided_by        text,
    decided_at        timestamptz,
    decision_note     text,
    CONSTRAINT setting_value_pkey PRIMARY KEY (id),
    CONSTRAINT setting_value_key_fkey FOREIGN KEY (key) REFERENCES shared.setting_definition (key),
    CONSTRAINT setting_value_tenant_id_fkey FOREIGN KEY (tenant_id)
        REFERENCES shared.tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT setting_value_version_chk CHECK (version >= 1),
    CONSTRAINT setting_value_status_chk CHECK (status IN ('proposed', 'approved', 'rejected', 'superseded')),
    CONSTRAINT setting_value_reason_chk CHECK (char_length(btrim(reason)) BETWEEN 20 AND 2000),
    CONSTRAINT setting_value_evidence_chk CHECK (evidence_ref IS NULL OR char_length(btrim(evidence_ref)) BETWEEN 3 AND 500),
    CONSTRAINT setting_value_actor_chk CHECK (char_length(proposed_by) BETWEEN 1 AND 64
        AND (decided_by IS NULL OR char_length(decided_by) BETWEEN 1 AND 64)),
    CONSTRAINT setting_value_decision_chk CHECK (
        (status = 'proposed' AND decided_by IS NULL AND decided_at IS NULL AND NOT self_approved)
        OR (status <> 'proposed' AND decided_by IS NOT NULL AND decided_at IS NOT NULL AND decided_at >= proposed_at)),
    CONSTRAINT setting_value_rejected_chk CHECK (status <> 'rejected' OR char_length(btrim(coalesce(decision_note, ''))) >= 3),
    CONSTRAINT setting_value_note_chk CHECK (decision_note IS NULL OR char_length(decision_note) <= 2000),
    CONSTRAINT setting_value_self_chk CHECK (NOT self_approved OR (status IN ('approved', 'superseded')
                                                                    AND decided_by = proposed_by))
);

CREATE UNIQUE INDEX IF NOT EXISTS setting_value_version_key
    ON shared.setting_value (key, (coalesce(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid)), version);
CREATE UNIQUE INDEX IF NOT EXISTS setting_value_one_proposal_key
    ON shared.setting_value (key, (coalesce(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid)))
    WHERE status = 'proposed';
CREATE INDEX IF NOT EXISTS setting_value_approved_idx
    ON shared.setting_value (key, tenant_id, effective_from DESC, version DESC) WHERE status = 'approved';
CREATE INDEX IF NOT EXISTS setting_value_tenant_idx
    ON shared.setting_value (tenant_id) WHERE tenant_id IS NOT NULL;

-- Why a value does not fit its definition (NULL = it fits). Shared by the trigger; the API checks the same rules in
-- Python first (shared/settings/reader.py validate) so a person gets a 422 with the reason, never a raw SQL error.
CREATE FUNCTION shared.setting_value_problem(v jsonb, d shared.setting_definition) RETURNS text
    LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    n numeric;
    elem jsonb;
BEGIN
    IF d.value_type IN ('int', 'numeric', 'duration_s', 'usd', 'pct') THEN
        IF jsonb_typeof(v) <> 'number' THEN
            RETURN 'value must be a number';
        END IF;
        n := (v #>> '{}')::numeric;
        IF d.value_type IN ('int', 'duration_s') AND n <> trunc(n) THEN
            RETURN 'value must be a whole number';
        END IF;
        IF d.min_value IS NOT NULL AND n < d.min_value THEN
            RETURN 'value is below the minimum ' || d.min_value;
        END IF;
        IF d.max_value IS NOT NULL AND n > d.max_value THEN
            RETURN 'value is above the maximum ' || d.max_value;
        END IF;
    ELSIF d.value_type = 'bool' THEN
        IF jsonb_typeof(v) <> 'boolean' THEN
            RETURN 'value must be true or false';
        END IF;
    ELSIF d.value_type = 'enum' THEN
        IF jsonb_typeof(v) <> 'string' OR NOT d.allowed_values @> jsonb_build_array(v) THEN
            RETURN 'value must be one of ' || d.allowed_values::text;
        END IF;
    ELSIF d.value_type = 'list' THEN
        IF jsonb_typeof(v) <> 'array' THEN
            RETURN 'value must be a list';
        END IF;
        IF d.allowed_values IS NOT NULL THEN
            FOR elem IN SELECT e FROM jsonb_array_elements(v) AS t (e) LOOP
                IF NOT d.allowed_values @> jsonb_build_array(elem) THEN
                    RETURN 'list item ' || elem::text || ' is not allowed';
                END IF;
            END LOOP;
        END IF;
    ELSE
        IF jsonb_typeof(v) NOT IN ('object', 'array') THEN
            RETURN 'value must be a JSON object or list';
        END IF;
        -- json: every number of an object's top level stays inside the definition's bounds (a price table)
        IF jsonb_typeof(v) = 'object' THEN
            FOR elem IN SELECT e FROM jsonb_each(v) AS t (k, e) LOOP
                IF jsonb_typeof(elem) <> 'number' AND (d.min_value IS NOT NULL OR d.max_value IS NOT NULL) THEN
                    RETURN 'every entry must be a number';
                END IF;
                IF jsonb_typeof(elem) = 'number' THEN
                    n := (elem #>> '{}')::numeric;
                    IF (d.min_value IS NOT NULL AND n < d.min_value) OR (d.max_value IS NOT NULL AND n > d.max_value) THEN
                        RETURN 'entry ' || elem::text || ' is outside ' || coalesce(d.min_value::text, '-') || '..'
                               || coalesce(d.max_value::text, '-');
                    END IF;
                END IF;
            END LOOP;
        END IF;
    END IF;
    RETURN NULL;
END
$fn$;

CREATE FUNCTION shared.setting_value_guard() RETURNS trigger
    LANGUAGE plpgsql AS $fn$
DECLARE
    d shared.setting_definition%ROWTYPE;
    problem text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.tenant_id IS NULL THEN
            RAISE EXCEPTION 'shared.setting_value is append-only: a platform value is never deleted'
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN OLD;
    END IF;

    SELECT * INTO d FROM shared.setting_definition WHERE key = NEW.key;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown setting %', NEW.key USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'proposed' THEN
            RAISE EXCEPTION 'a setting value is inserted as a proposal (status proposed)' USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.tenant_id IS NOT NULL AND d.scope_kind <> 'platform+tenant' THEN
            RAISE EXCEPTION 'setting % has no per-tenant value (scope %)', NEW.key, d.scope_kind
                USING ERRCODE = 'check_violation';
        END IF;
        IF d.evidence_required AND NEW.evidence_ref IS NULL THEN
            RAISE EXCEPTION 'setting % needs an evidence reference (eval or replay run)', NEW.key
                USING ERRCODE = 'check_violation';
        END IF;
        problem := shared.setting_value_problem(NEW.value, d);
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
        RAISE EXCEPTION 'shared.setting_value is append-only: only the decision columns change'
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'proposed' AND NEW.status IN ('approved', 'rejected') THEN
        IF NEW.status = 'approved' AND d.approval = 'maker_checker' AND NEW.decided_by = NEW.proposed_by THEN
            IF NOT NEW.self_approved THEN
                RAISE EXCEPTION 'setting % needs a second person to approve (or a recorded self-approval)', NEW.key
                    USING ERRCODE = 'check_violation';
            END IF;
            -- A self-approval only while two-person approval is off: the latest approved platform value of
            -- cis.settings.two_person_approval in force, else its default (the API checks the same in the decision
            -- transaction first; this is the backstop). The flag is maker_checker itself, so once it is on the person
            -- it checks cannot switch it off alone.
            IF coalesce((SELECT v.value FROM shared.setting_value v
                          WHERE v.key = 'cis.settings.two_person_approval' AND v.tenant_id IS NULL
                            AND v.status = 'approved' AND v.effective_from <= now()
                          ORDER BY v.effective_from DESC, v.version DESC LIMIT 1),
                        (SELECT t.default_value FROM shared.setting_definition t
                          WHERE t.key = 'cis.settings.two_person_approval'),
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

CREATE TRIGGER setting_value_guard_trg
    BEFORE INSERT OR UPDATE OR DELETE ON shared.setting_value
    FOR EACH ROW EXECUTE FUNCTION shared.setting_value_guard();

-- Definitions come only from migrations (S279 review). cis_owner's default privileges (CIS 245) give cis_app INSERT,
-- UPDATE and DELETE on every new shared table, and an expand file cannot REVOKE them (CIS 400 states the same limit);
-- the FOR ALL policy does not narrow them either. Without this guard the app role (or an ECS exec script on
-- DATABASE_URL) could widen a bound, switch approval to single or drop evidence_required, and the value trigger reads
-- its bounds from this table. Only a member of cis_owner (Migration Apply runs cis/ files as cis_owner; the DB
-- migrator role is a member; a superuser counts as a member of every role) may write a definition.
CREATE FUNCTION shared.setting_definition_guard() RETURNS trigger
    LANGUAGE plpgsql AS $fn$
BEGIN
    IF NOT pg_has_role(current_user, 'cis_owner', 'MEMBER') THEN
        RAISE EXCEPTION 'shared.setting_definition is written only by migrations (cis_owner), not by %', current_user
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$fn$;

CREATE TRIGGER setting_definition_guard_trg
    BEFORE INSERT OR UPDATE OR DELETE ON shared.setting_definition
    FOR EACH ROW EXECUTE FUNCTION shared.setting_definition_guard();
CREATE TRIGGER setting_definition_guard_truncate_trg
    BEFORE TRUNCATE ON shared.setting_definition
    FOR EACH STATEMENT EXECUTE FUNCTION shared.setting_definition_guard();

COMMENT ON TABLE shared.setting_definition IS
    'S279 thresholds L1 (CIS 407): one row per admin-editable setting (threshold, limit, cap, policy value), written '
    'only by migrations; bounds widen only through a new migration. Resolution (shared/settings/reader.py): env '
    'override (warning) -> approved tenant value -> approved platform value -> default_value. Admin page Platform › '
    'Settings, API /admin/settings/registry.';
COMMENT ON TABLE shared.setting_value IS
    'S279 thresholds L1 (CIS 407): append-only, versioned values of shared.setting_definition keys (tenant_id NULL = '
    'platform). proposed -> approved | rejected, approved -> superseded; every decision writes an acp_shared.audit_log '
    'row (settings.value_*). The trigger setting_value_guard_trg keeps the rows immutable but for the decision.';
COMMENT ON COLUMN shared.setting_value.reason IS
    'pii:free_text; S279 (407): why the value changes, typed by staff (>= 20 characters). A business reason, never '
    'personal data.';
COMMENT ON COLUMN shared.setting_value.decision_note IS
    'pii:free_text; S279 (407): the approver''s note (required on a rejection), typed by staff.';
COMMENT ON COLUMN shared.setting_value.proposed_by IS
    'S279 (407): the staff actor of the proposal, admin:<admin_users.id> (the audit actor format). Never an e-mail.';
COMMENT ON COLUMN shared.setting_value.decided_by IS
    'S279 (407): the staff actor of the decision, admin:<admin_users.id>. Never an e-mail.';
COMMENT ON COLUMN shared.setting_value.self_approved IS
    'S279 (407): the proposer approved the change themselves (dev-phase rule, tech lead S279 Q2): allowed while the '
    'setting cis.settings.two_person_approval is off; the API e-mails the tech lead for a high-impact key.';

-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "cis.t7.blog_min_seed_words", "app": "cis", "area": "content", "label": "T7 Blog minimum seed (words)", "description": "A Subject whose grounded seed is shorter than this is not proposed on Blog (it stays on the shorter channels). 0 = off. Seeded from the Terraform value in force (600; the code default was 0). The effective floor is the larger of this and the length-sized floor (cis.t7.blog_chars_per_seed_word). No env override: the worker's old env var is no longer read, so the value here is the one the worker uses.", "value_type": "int", "unit": "words", "min_value": 0, "max_value": 5000, "allowed_values": null, "default_value": 600, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.t7.blog_chars_per_seed_word", "app": "cis", "area": "content", "label": "T7 Blog characters per seed word", "description": "Blog characters the T9 writer produces per grounded seed word; sizes the Blog seed floor as ceil(4,700 / ratio) while the flat minimum is on. 0 = no sizing. Seeded at today's effective 5.8 (811 words). The S279 $0 replay of stored blog pieces measured 3.364 (floor 1,398 words): the recommended value, to be proposed with that replay as evidence.", "value_type": "numeric", "unit": "chars/word", "min_value": 0, "max_value": 20, "allowed_values": null, "default_value": 5.8, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": true, "env_override": "T7_BLOG_CHARS_PER_SEED_WORD", "cache_s": 30, "enforced": true},
{"key": "cis.t9.repeat_drop_near_exact", "app": "cis", "area": "content", "label": "T9 blog repeat drop: near-exact share", "description": "The blog repeat drop deletes the later copy of a sentence the F13 gate quotes only when its words match an earlier sentence in order with at least this Dice share (1.0 = exact). Lower values drop paraphrases too.", "value_type": "numeric", "unit": "share", "min_value": 0.8, "max_value": 1.0, "allowed_values": null, "default_value": 0.9, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": true, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.t9.max_attempts", "app": "cis", "area": "content", "label": "T9 write attempts per piece", "description": "Attempts of the T9 writer loop per piece: 3 = first write, one repair and a third step; 2 = first write and one repair, no paid third step. In the default stop-and-label mode the third step is the $0 label, so 2 and 3 cost the same there; in legacy mode 3 adds a paid sentence repair of attempt 2. Trades cost against the hold rate.", "value_type": "int", "unit": "attempts", "min_value": 2, "max_value": 3, "allowed_values": null, "default_value": 3, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.a1.attempts_before_review", "app": "cis", "area": "content", "label": "A1 S1 rewrite attempts before review", "description": "A1 (S1) rewrite attempts of one tour before it goes to human review when the quality score stays under the pass line (the score-rule path; S1 contract mode routes by its own codes).", "value_type": "int", "unit": "attempts", "min_value": 1, "max_value": 5, "allowed_values": null, "default_value": 3, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.t2.version_writer_max", "app": "cis", "area": "content", "label": "T2 writer calls per tour version", "description": "Paid T2 writer calls (first write and field regenerations) one tenant tour version may spend, counted across a job retry.", "value_type": "int", "unit": "calls", "min_value": 1, "max_value": 5, "allowed_values": null, "default_value": 2, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.t2.version_repair_max", "app": "cis", "area": "content", "label": "T2 repair calls per tour version", "description": "Paid T2 flag-fix (repair) calls one tenant tour version may spend; a sentence repair is one call, a meta regenerate counts each real attempt.", "value_type": "int", "unit": "calls", "min_value": 0, "max_value": 6, "allowed_values": null, "default_value": 3, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.t2.version_voice_max", "app": "cis", "area": "content", "label": "T2 voice report calls per tour version", "description": "Report-only voice judge calls one tenant tour version may spend (0 = no voice report).", "value_type": "int", "unit": "calls", "min_value": 0, "max_value": 2, "allowed_values": null, "default_value": 1, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.t2.version_usd_max", "app": "cis", "area": "content", "label": "T2 spend cap per tour version", "description": "The billed model cost one tenant tour version may reach; no further call starts once it is reached.", "value_type": "usd", "unit": "USD", "min_value": 0.05, "max_value": 2.0, "allowed_values": null, "default_value": 0.25, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.writing_memory.month_cap_usd", "app": "cis", "area": "spend", "label": "Writing memory monthly LLM cap", "description": "Learning-loop LLM spend (mining, R2 eval, shadow and their one-off runs) per calendar month (UTC). A run whose estimate would pass it is refused before any call.", "value_type": "usd", "unit": "USD/month", "min_value": 0, "max_value": 200, "allowed_values": null, "default_value": 25, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.spend.segment_research_max_usd_per_run", "app": "cis", "area": "spend", "label": "Segment research DataForSEO cap per run", "description": "The most one segment research run may spend on DataForSEO: the route refuses a larger max_usd and a run whose budget row sets no limit is capped here.", "value_type": "usd", "unit": "USD/run", "min_value": 1, "max_value": 200, "allowed_values": null, "default_value": 50, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.spend.place_backfill_max_tours", "app": "cis", "area": "spend", "label": "Place backfill tours per run", "description": "Tours one place backfill run (by country) may process; bounds the paid locate / days calls of one run.", "value_type": "int", "unit": "tours", "min_value": 1, "max_value": 200, "allowed_values": null, "default_value": 50, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.spend.rerun_wave_max_tours", "app": "cis", "area": "spend", "label": "Rerun wave size", "description": "Tours one rerun wave may list (its expected set). The rerun runbook steps 3 tours, then at most 50, then a country.", "value_type": "int", "unit": "tours", "min_value": 1, "max_value": 5000, "allowed_values": null, "default_value": 2000, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.spend.question_topup_cap_usd", "app": "cis", "area": "spend", "label": "Question top-up total cap", "description": "The DataForSEO spend of the admin SERP question top-up in all, across every run (each call is logged and counted).", "value_type": "usd", "unit": "USD", "min_value": 0, "max_value": 20, "allowed_values": null, "default_value": 3, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.spend.dfs_call_estimate_usd", "app": "cis", "area": "spend", "label": "DataForSEO price per call (pre-call estimate)", "description": "Worst-case price of one DataForSEO call per endpoint label, used for the pre-call budget check before the real price is known. Keep it at or above the price DataForSEO charges (AA-1055: the queue prices were 2.4x off). Every price is above 0; a label left out keeps its seeded price.", "value_type": "json", "unit": "USD/call", "min_value": 0.0001, "max_value": 1, "allowed_values": null, "default_value": {"search_volume": 0.09, "search_volume_bulk": 0.09, "keywords_for_keywords": 0.09, "serp_advanced": 0.002, "serp_advanced_paa_deep": 0.01, "search_volume_bulk_queue": 0.06, "serp_advanced_queue": 0.0006}, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.publish.daily_limit_default", "app": "cis", "area": "publish", "label": "Daily publish limit (platform default)", "description": "Posts one tenant may publish per UTC day when the tenant has no own limit (Tenant 360 > Settings sets a per-tenant limit up to 1,000).", "value_type": "int", "unit": "posts/day", "min_value": 1, "max_value": 1000, "allowed_values": null, "default_value": 20, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.billing.rewrite_over_quota_mode", "app": "cis", "area": "billing", "label": "Rewrite over-quota rule", "description": "What happens when a tenant passes its monthly rewrite quota: soft = the rewrite runs and is billed as overage (today, trial); hard = the rewrite is refused until the quota resets or the plan grows.", "value_type": "enum", "unit": null, "min_value": null, "max_value": null, "allowed_values": ["soft", "hard"], "default_value": "soft", "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.lifecycle.tour_retirement_notice_days", "app": "cis", "area": "lifecycle", "label": "Tour retirement notice (platform default)", "description": "Days of notice a tenant gets before the automatic draft of its posts about a retired tour, when neither its own setting nor its plan names a number.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 30, "allowed_values": null, "default_value": 7, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.retention.llm_call_log_days", "app": "cis", "area": "retention", "label": "LLM call log retention", "description": "Days the raw shared.llm_call_log rows are kept before they are archived to S3 and rolled up per day (the pilot tenant is skipped). A changed window makes the next scheduled run a dry run first.", "value_type": "int", "unit": "days", "min_value": 30, "max_value": 1095, "allowed_values": null, "default_value": 180, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.retention.tenant_api_usage_days", "app": "cis", "area": "retention", "label": "Tenant API usage retention", "description": "Days the raw shared.tenant_api_usage rows are kept before they are archived and rolled up per month.", "value_type": "int", "unit": "days", "min_value": 35, "max_value": 730, "allowed_values": null, "default_value": 90, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.retention.job_succeeded_days", "app": "cis", "area": "retention", "label": "Succeeded job retention", "description": "Days a succeeded shared.job row is kept (no archive).", "value_type": "int", "unit": "days", "min_value": 7, "max_value": 365, "allowed_values": null, "default_value": 30, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.retention.job_failed_days", "app": "cis", "area": "retention", "label": "Failed job retention", "description": "Days a failed, cancelled or budget-stopped shared.job row is kept before it is archived to S3.", "value_type": "int", "unit": "days", "min_value": 14, "max_value": 730, "allowed_values": null, "default_value": 90, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "cis.erasure.tenant_retention_days", "app": "cis", "area": "retention", "label": "Offboarded tenant retention", "description": "Days after a tenant's offboarding before the data erasure may remove its CIS data (the apply switch itself stays in Terraform). The Dev erasure drill sets the env override to 0.", "value_type": "int", "unit": "days", "min_value": 0, "max_value": 365, "allowed_values": null, "default_value": 30, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": "ERASURE_TENANT_RETENTION_DAYS", "cache_s": 30, "enforced": true},
{"key": "cis.content.trash_retention_days", "app": "cis", "area": "retention", "label": "Trash retention", "description": "Days a deleted item stays in the trash before it is purged. Shown on Settings > Plan; no purge job reads it yet (not enforced).", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 365, "allowed_values": null, "default_value": 30, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": false},
{"key": "cis.settings.two_person_approval", "app": "cis", "area": "platform", "label": "Two-person approval of settings", "description": "On: a maker-checker setting needs a second staff member to approve. Off (dev phase, tech lead S279): the administrator may approve their own change with a reason, and a high-impact change e-mails the tech lead. Turn on at the first prod or paying tenant. This flag is maker-checker itself: while it is on, turning it off needs a second person.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": false, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean);
-- settings-seed:end

-- RLS (X1 parity, as every new shared table): ENABLE + FORCE with the cis_app / cis_owner policies. The values have a
-- tenant_id column (a per-tenant override), read and written only by the CIS API and reader: X2 allowlist rule a
-- (tests/integration/rls_catalogue_rules.py), no tenant-pool grant.
ALTER TABLE shared.setting_definition ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.setting_definition FORCE ROW LEVEL SECURITY;
CREATE POLICY setting_definition_cis_app_all ON shared.setting_definition AS PERMISSIVE FOR ALL
    TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY setting_definition_cis_owner_all ON shared.setting_definition AS PERMISSIVE FOR ALL
    TO cis_owner USING (true) WITH CHECK (true);

ALTER TABLE shared.setting_value ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.setting_value FORCE ROW LEVEL SECURITY;
CREATE POLICY setting_value_cis_app_all ON shared.setting_value AS PERMISSIVE FOR ALL
    TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY setting_value_cis_owner_all ON shared.setting_value AS PERMISSIVE FOR ALL
    TO cis_owner USING (true) WITH CHECK (true);

GRANT SELECT ON shared.setting_definition TO cis_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.setting_value TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('407', now(), 'S279 thresholds L1: shared.setting_definition + shared.setting_value (platform settings registry)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
