-- Migration crm-084: AA-1147 (S285 decision T18; tech lead S279 "a threshold or a client-facing wording is a setting")
-- — the two values of the agency's own services (crm-083) that the tech lead edits on the CIS Platform > Settings page
-- (CRM tab), as CRM settings.
--
-- Owner: AA-Partner (api/migrations/084_crm_agency_lines_settings.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy Migration Apply runs. Key crm-084, right after crm-083 (the agency extras schema, its own migration-only PR);
-- if the numbers move, renumber: file name, this header, Guard 0 and the registration below, and the tests that name it
-- (git grep '084_' and 'crm-084').
--
-- What:
--   1. Two crm.setting_definition rows (settings-seed block, read by api/scripts/gen_settings_defaults.py into
--      app/platform_settings/compiled_defaults.json; guides in app/platform_settings/guides.json; readers in
--      app/ledger/agency_extras.py, shipped in this PR):
--        crm.agency_lines.due_lead_days  int days, default 3 (0 to 60), platform+tenant: how long before an agency
--                                        line's deadline its task opens (app/ledger/agency_due.py).
--        crm.agency_lines.disclaimer     json {en, vi}, platform+tenant: the sentence printed under "Services provided
--                                        by <agency>" on the client page, the proposal text and PDF and the invoice.
--   2. Register crm-084.
--
-- Behaviour on apply: none for running code (the readers serve the compiled defaults, the same values, until a value
-- is approved).
--
-- Class: contract (INSERT of config rows into an existing table; no '-- migrate:' directive). Shipped with its readers
-- in the code PR like crm-082 (#363): the readers fall back to the compiled defaults and readiness does not wait for
-- crm-084, so the code deploying before Infra Migration Apply registers the file changes nothing (root ADR 0017a). No
-- new table (no DM-7.1 row), no personal data, no crm.erase_subject change.
--
-- Rollback (a new forward migration, after the code is reverted): DELETE FROM crm.setting_value /
-- crm.setting_definition WHERE key IN the two keys, as crm_owner.
--
-- Runs as crm_owner (the crm-064 definition guard allows only the owner), one BEGIN … COMMIT block, no role DDL.
-- Re-runnable (ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-083 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-084: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-083') THEN
        RAISE EXCEPTION 'crm-084: crm-083 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-084' AND description NOT LIKE 'AA-1147 agency lines settings:%') THEN
        RAISE EXCEPTION 'crm-084: the key crm-084 is already held by another migration (not AA-1147): renumber one';
    END IF;
END $$;

-- ── 1. The agency services settings ──────────────────────────────────────────────────────────────
-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "crm.agency_lines.due_lead_days", "app": "crm", "area": "agency_lines", "label": "Agency services: days before a deadline that its task opens", "description": "An agency's own service line (flight, visa, travel insurance, agency fee) can carry a deadline: the flight's ticketing time limit, the visa file's submission date, the day to buy the insurance. The hourly workflow tick opens one task for the trip owner when a planning or requested line comes within this many days of its deadline (0 = on the day). An administrator may give one agency its own value. Read by app/ledger/agency_extras.py (the task: app/ledger/agency_due.py).", "value_type": "int", "unit": "days", "min_value": 0, "max_value": 60, "allowed_values": null, "default_value": 3, "scope_kind": "platform+tenant", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.agency_lines.disclaimer", "app": "crm", "area": "agency_lines", "label": "Agency services: disclaimer printed under the agency's own services", "description": "The sentence printed under the group \"Services provided by <agency>\" (flights, visa, travel insurance, the agency fee) on the client's proposal (page, e-mail text, PDF) and invoice (printable page and PDF), one text per language: {\"en\": \"...\", \"vi\": \"...\"}. It tells the client that the agency, not Adventure Asia, provides and answers for these services. An administrator may give one agency its own wording. Read by app/ledger/agency_extras.py.", "value_type": "json", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": {"en": "These services are arranged and provided by the agency named above, which is responsible for them. Airline, visa and insurance terms are those of the airline, the issuing authority and the insurer.", "vi": "Các dịch vụ này do đại lý nêu trên sắp xếp, cung cấp và chịu trách nhiệm. Điều kiện vé máy bay, thị thực và bảo hiểm theo quy định của hãng bay, cơ quan cấp thị thực và công ty bảo hiểm."}, "scope_kind": "platform+tenant", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── Post-check ────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT count(*) FROM crm.setting_definition
         WHERE key IN ('crm.agency_lines.due_lead_days', 'crm.agency_lines.disclaimer')) <> 2 THEN
        RAISE EXCEPTION 'crm-084: the agency lines settings are not defined';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-084', now(), 'AA-1147 agency lines settings: crm.agency_lines.due_lead_days (days before a deadline that its task opens) and crm.agency_lines.disclaimer (the sentence under "Services provided by <agency>")')
ON CONFLICT (version) DO NOTHING;

COMMIT;
