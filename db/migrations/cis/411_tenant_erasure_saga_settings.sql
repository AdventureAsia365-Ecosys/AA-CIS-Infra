-- Migration 411: AA-1093 lane L2 — the settings of the tenant offboarding erasure saga in the platform settings registry
-- (CIS 407; tech lead S279: a threshold, window or switch is a setting on Platform › Settings, never a code literal or
-- an env var alone).
--
-- Why. The saga (CIS 408-410, contract tenant.erasure.v1) needs three values the contract calls "CIS settings in the
-- admin-editable settings registry": the CRM exit window (decision D2: 90 days; AA erases the agency's CRM data after
-- it without the owner's click), how long a combined fingerprint may be approved and how long an approval stays valid
-- (decision D7: 24 hours), and the default-off apply switch. The exit window of CIS, Booking and TripPlanner is the
-- existing setting cis.erasure.tenant_retention_days (407, 30 days, decision D1): the saga reads it, so the saga and the
-- data_erasure job can never disagree on the CIS date.
--
-- What:
--   1. Three rows in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR):
--        cis.erasure.crm_window_days           int days 30..365, default 90, high impact, maker-checker
--        cis.erasure.saga_approval_valid_hours int hours 1..72, default 24, high impact, maker-checker
--        cis.erasure.saga_apply_enabled        bool, default false, high impact, maker-checker
--      Seeded with enforced = false (the page badge "not enforced yet"): the saga code that reads them ships in the
--      next PR of this wave (MIG-4), and the settings-lint guard (tests/unit/test_s279_settings_lint.py) refuses an
--      enforced key that no code reads. A later migration sets enforced = true once that code is deployed (follow-up
--      recorded in docs/implementation-notes/AA-1093-l14-cis-saga.md).
--   2. Register 411.
--
-- Behaviour on apply. None for running code: no value row is seeded, nothing reads the keys until the saga code is
-- deployed, and then every key resolves to its default (today's decisions) until an administrator approves a change.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no '-- migrate:' directive): config rows INSERTed into an existing table.
-- MIG-4: one migration-only PR with 408-410 (batch cis 408-411); applied on Dev by Infra Migration Apply when the job
-- tables are idle (ADR 0017a). DM-7.1: no new table.
--
-- Number. 408 is this wave's first file; if the owner main max + 1 differs at merge, renumber (git grep '411_' and
-- '411' here, in compiled_defaults.json and in the code that names the file).
--
-- Locks. One INSERT of three rows (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
-- Idempotent (ON CONFLICT (key) DO NOTHING), one transaction, self-registering.
--
-- Rollback (a new forward migration, after the saga code is reverted): DELETE the three keys (no value row can exist
-- before the code reads them; a value row would have to go first).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "cis.erasure.crm_window_days", "app": "cis", "area": "retention", "label": "Offboarded tenant CRM window", "description": "Days after a tenant's offboarding before the erasure saga erases its partner CRM data (stage 2), without the owner's click (decision D2). CIS, Booking and TripPlanner use the offboarded tenant retention instead (stage 1). Read by the tenant erasure saga from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "days", "min_value": 30, "max_value": 365, "allowed_values": null, "default_value": 90, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": false},
{"key": "cis.erasure.saga_approval_valid_hours", "app": "cis", "area": "retention", "label": "Erasure approval validity", "description": "Hours a combined erasure fingerprint may still be approved after it was computed, and hours an approval stays valid for the apps to apply (decision D7). Past it the tech lead starts a new DRY RUN round. Read by the tenant erasure saga from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "hours", "min_value": 1, "max_value": 72, "allowed_values": null, "default_value": 24, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": false},
{"key": "cis.erasure.saga_apply_enabled", "app": "cis", "area": "retention", "label": "Erasure saga apply switch", "description": "On: a Cognito administrator may approve a tenant erasure round and the apps then erase the tenant's data (CIS also needs its own data_erasure switch). Off (default): DRY RUNs only. Read by the tenant erasure saga from the release that ships it; marked enforced by a later migration.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": false, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": false}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('411', now(), 'AA-1093: settings of the tenant erasure saga (CRM window, approval validity, apply switch)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
