-- Migration crm-074: AA-968 (design v3 §6.3 card CRM-36; tech lead S279: every threshold, limit and cap is an
-- admin-editable setting) — the two limits of the campaigns in the CRM settings registry (crm-064).
--
-- Owner: AA-Partner (api/migrations/074_crm_campaign_settings.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- Migration Apply runs. Key crm-074, right after crm-073 (the campaign tables, same lane); if the numbers move,
-- renumber: file name, this header, Guard 0 and the registration below, and the tests that name it (git grep '074_'
-- and 'crm-074').
--
-- What: two crm.setting_definition rows, area campaigns, maker-checker, enforced, no env override (the block between
-- "settings-seed:begin" and "settings-seed:end" is read by api/scripts/gen_settings_defaults.py into
-- app/platform_settings/compiled_defaults.json, the file the reader serves when the table has no row; the seed-parity
-- test keeps the two equal):
--   crm.campaign.mailbox_daily_limit (400 e-mails a day, platform+tenant: card CRM-36 E "a list over the mailbox daily
--     limit is spread over days"; the platform value with an administrator's value per agency, 1..10000; 400 stays
--     under the 500 a day of a free Gmail account, the smallest provider limit of the agency's own mailboxes),
--   crm.campaign.max_recipients (2000 clients per campaign, platform+tenant, 1..50000).
-- The CIS admin page (Platform > Settings, CRM tab) edits them; the guides are app/platform_settings/guides.json.
--
-- Behaviour on apply: none for running code. The reader already serves these defaults from the compiled file; the rows
-- only make the keys editable on the CIS page.
--
-- Class: contract (INSERTs of config rows; no '-- migrate:' directive). MIG-4 deviation, the same as crm-068 and
-- crm-070: this file ships in the code PR, not in the migration-only PR of crm-073, because the settings lint (an
-- enforced key must be read by code), the guide lint and the seed-parity test bind this block, the readers and
-- compiled_defaults.json together (either half alone is red), and the code works before the apply (compiled defaults).
-- On Dev, Infra Migration Apply once every job table is idle (root ADR 0017a). No new table (no DM-7.1 row), no
-- crm.erase_subject change, no personal data.
--
-- Rollback (a new forward migration, after the code that reads them is reverted): DELETE FROM crm.setting_value /
-- crm.setting_definition WHERE key IN (the two keys) as crm_owner.
--
-- Runs as crm_owner (the crm-064 definition guard allows only the owner), one BEGIN … COMMIT block, no role DDL.
-- Re-runnable (ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-064 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-074: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-064') THEN
        RAISE EXCEPTION 'crm-074: crm-064 (settings registry) lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-074' AND description NOT LIKE 'AA-968 campaign settings:%') THEN
        RAISE EXCEPTION 'crm-074: the key crm-074 is already held by another migration (not AA-968): renumber one';
    END IF;
END $$;

-- settings-seed:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO crm.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced
  FROM jsonb_to_recordset($seed$[
{"key": "crm.campaign.mailbox_daily_limit", "app": "crm", "area": "campaigns", "label": "Campaign e-mails per mailbox per day", "description": "The most campaign e-mails one of the agency's own mailboxes sends in one day (agency timezone), all campaigns together; a longer list is spread over the next days. An administrator may give one agency its own value (for example a Google Workspace or Microsoft 365 mailbox that allows more).", "value_type": "int", "unit": "e-mails/day", "min_value": 1, "max_value": 10000, "allowed_values": null, "default_value": 400, "scope_kind": "platform+tenant", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true},
{"key": "crm.campaign.max_recipients", "app": "crm", "area": "campaigns", "label": "Clients per campaign", "description": "The most clients one campaign may go to; scheduling a larger audience is refused until the agency narrows it with client tags. An administrator may give one agency its own value.", "value_type": "int", "unit": "clients", "min_value": 1, "max_value": 50000, "allowed_values": null, "default_value": 2000, "scope_kind": "platform+tenant", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── Post-check: the two keys are defined ─────────────────────────────────────────────────────────
DO $$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM crm.setting_definition
     WHERE key IN ('crm.campaign.mailbox_daily_limit', 'crm.campaign.max_recipients');
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'crm-074: expected the 2 campaign settings, found %', v_n;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-074', now(), 'AA-968 campaign settings: the mailbox daily send limit of a campaign (spread over days above it) and the clients per campaign (platform+tenant, area campaigns, maker-checker)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
