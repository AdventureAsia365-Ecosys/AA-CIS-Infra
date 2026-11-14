-- Migration crm-068: AA-1096 (lane l5, tech lead S279: "env vars stay for one release as an emergency override, then
-- go") — the one-release env overrides of the CRM settings registry are retired.
--
-- Owner: AA-Partner (api/migrations/068_crm_retire_settings_env_overrides.sql). AA-CIS-Infra db/migrations/crm/ holds
-- the byte copy Migration Apply runs. Key crm-068: crm-066..crm-067 are taken by other lanes of this wave (crm main max
-- is crm-065 on 15/11/2026); if main moves, renumber: file name, this header, Guard 0 and the registration below, and
-- the tests that name it (git grep '068_' and 'crm-068').
--
-- Why: crm-064 gave 7 definitions an env_override (AI_BUDGET_MAX_USD, CRM_LLM_MAX_TOKENS, RATE_LIMIT_PUBLIC_PER_MINUTE,
-- RATE_LIMIT_INTAKE_PER_MINUTE, RATE_LIMIT_INTAKE_FORM_PER_HOUR, RATE_LIMIT_MEMBER_PER_MINUTE, RATE_LIMIT_AI_PER_MINUTE),
-- the old env value of the setting kept for one release. The release has passed (S279 settings shipped, S280 deployed
-- again) and the CRM task definition sets none of them (AA-CIS-Infra lane L6). While a definition names an env var, a
-- stray value on the task wins over the administrator's value and blocks every agency value (409
-- env_override_active); the CIS admin page (CRM tab) is the one place to change these values now.
--
-- What: the block between "settings-edit:begin" and "settings-edit:end" (read by api/scripts/gen_settings_defaults.py
-- into app/platform_settings/compiled_defaults.json, the file the reader serves; the seed-parity test keeps the two
-- equal): env_override null on the 7 keys, and two descriptions without the env var name. A post-check: every row of
-- the block is in force and no definition names an env var any more. Register crm-068.
--
-- Behaviour on apply: none for running code. The reader serves the compiled defaults (regenerated from this block in
-- the same PR), not this table's column; no value, bound, approval rule or enforcement flag changes. The env_override
-- mechanism stays (tests/unit/test_aa1096_settings_env_lint.py: a future override needs a dated one-release window).
--
-- Class: contract (UPDATEs of existing config rows; no '-- migrate:' directive). No readiness raise. MIG-4 deviation
-- (recorded in the implementation notes): this file ships in ONE PR with the code that stops naming the retired env
-- vars, not as a migration-only PR, because the seed-parity and migration tests bind this block, the generator and
-- compiled_defaults.json together (either half alone is red), and no code reads the column, so a deploy before the
-- apply changes nothing. On Dev, Infra Migration Apply once every job table is idle (root ADR 0017a). No new table
-- (no DM-7.1 row), no crm.erase_subject change, no personal data.
--
-- Rollback (a new forward migration): put env_override back on the keys from crm-064 (only to re-open an emergency
-- override; the code needs no change).
--
-- Runs as crm_owner (DB Migrate switch; the crm-064 definition guard allows it), one BEGIN … COMMIT block, no role
-- DDL. Re-runnable (the UPDATE skips equal rows, ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-064 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-068: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-064') THEN
        RAISE EXCEPTION 'crm-068: crm-064 (AA-1096 settings registry) lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-068' AND description NOT LIKE 'AA-1096 l5: retire%') THEN
        RAISE EXCEPTION 'crm-068: the key crm-068 is already held by another migration (not AA-1096 l5): renumber one';
    END IF;
END $$;

-- settings-edit:begin (api/scripts/gen_settings_defaults.py reads the JSON array of the dollar-quoted block)
CREATE TEMP TABLE IF NOT EXISTS m068_edit (key text PRIMARY KEY, doc jsonb NOT NULL) ON COMMIT DROP;
INSERT INTO m068_edit (key, doc)
SELECT e.doc ->> 'key', e.doc
  FROM jsonb_array_elements($edit$[
{"key": "crm.ai.budget_max_usd", "env_override": null, "description": "The highest monthly AI budget an agency owner may set on Settings > AI (AA pays for the calls). An administrator may give one agency its own ceiling. Seeded at 2 USD (the old code default)."},
{"key": "crm.ai.draft_reply_max_tokens", "env_override": null, "description": "Output token cap of every route entry of the crm_draft_reply stage (the only CRM AI stage that writes text); a reply cut at the cap is logged truncated and the draft says reply by hand. Seeded at 800 (the old Terraform and code value)."},
{"key": "crm.rate.ai_per_minute", "env_override": null},
{"key": "crm.rate.intake_form_per_hour", "env_override": null},
{"key": "crm.rate.intake_per_minute", "env_override": null},
{"key": "crm.rate.member_per_minute", "env_override": null},
{"key": "crm.rate.public_per_minute", "env_override": null}
]$edit$::jsonb) AS e (doc)
ON CONFLICT (key) DO UPDATE SET doc = EXCLUDED.doc;
-- settings-edit:end

UPDATE crm.setting_definition AS d
   SET env_override = CASE WHEN e.doc ? 'env_override' THEN e.doc ->> 'env_override' ELSE d.env_override END,
       description  = COALESCE(e.doc ->> 'description', d.description)
  FROM m068_edit AS e
 WHERE d.key = e.key
   AND (d.env_override IS DISTINCT FROM CASE WHEN e.doc ? 'env_override' THEN e.doc ->> 'env_override'
                                             ELSE d.env_override END
        OR d.description IS DISTINCT FROM COALESCE(e.doc ->> 'description', d.description));

-- Post-check: every row of the block is in force, and no definition names an env var any more.
DO $$
DECLARE
    missing text;
    still text;
BEGIN
    SELECT string_agg(e.key, ', ' ORDER BY e.key) INTO missing
      FROM m068_edit AS e
     WHERE NOT EXISTS (
           SELECT 1 FROM crm.setting_definition AS d
            WHERE d.key = e.key
              AND (NOT e.doc ? 'env_override' OR d.env_override IS NULL)
              AND (NOT e.doc ? 'description' OR d.description = e.doc ->> 'description'));
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'crm-068: no definition or not edited: %', missing;
    END IF;
    SELECT string_agg(d.key || ' (' || d.env_override || ')', ', ' ORDER BY d.key) INTO still
      FROM crm.setting_definition AS d
     WHERE d.env_override IS NOT NULL;
    IF still IS NOT NULL THEN
        RAISE EXCEPTION 'crm-068: definitions still name an env override: %', still;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-068', now(), 'AA-1096 l5: retire the one-release env overrides of the CRM settings registry')
ON CONFLICT (version) DO NOTHING;

COMMIT;
