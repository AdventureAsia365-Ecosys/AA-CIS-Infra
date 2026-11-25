-- migrate: expand
-- Migration 490: AA-1154 (S293, phase A2 of the CIS admin assistant) — the record of each action card a person ran,
-- with what the card predicted and what was measured afterwards.
--
-- Why. Phases A0 (CIS 481) and A1 (CIS 487) make ranked action cards for a Needs-attention item of the Ecosystem
-- status page and let a model rank and explain them; every card says what it predicts ("the queued jobs of the wave go
-- to 0", "refused calls on the connection fall"), but nothing checks it. Tech lead decision S285 (root
-- docs/audits/2026-11-19-S285-session/advisory-ai-assistants.md sections 3.7, 6 and 8, phase A2): each executed card
-- records predicted against actual at +10 and +30 minutes, read again by the worker ($0, no model), and the digest
-- shows the hit rate; a card's "right k of n" track record (shown from cis.ops.assist_history_min_n outcomes) comes
-- from these rows.
--
-- What:
--   1. acp_shared.ops_assist_run: one row per card a person marked as done from the status page's Analyse drawer
--      (POST /admin/ops-assist/runs; the card is rebuilt on the server, never taken from the browser):
--        item_id, card_id, action (the catalogue action id), playbook, risk_level R0-R4, range_key (the status page
--        range the card was built for), incident_id (the open acp_shared.ops_incident of the same item, when there is
--        one; CIS 485), predicted (the card's predictions as shown: text, confidence source, basis), measures (what is
--        read again: metric, its parameters, the expected direction, the value read when the card was marked done),
--        check_after_min (the checkpoints, minutes, copied from cis.ops.assist_check_after_min at record time so a
--        later edit of the setting never changes an open run), checks (one entry per checkpoint taken: minutes,
--        time, values, verdict hit / miss / unclear), verdict (the last checkpoint's verdict) and checked_at (set
--        with it), recorded_by (admin:<admin_users.id>, never an e-mail) and recorded_at.
--      The 5-minute status sampler (job kind ops_status_sample, the monitoring lane of the job runner, AA-1178) takes
--      every due checkpoint: a partial index serves "verdict IS NULL".
--   2. GRANT cis_app SELECT, INSERT, UPDATE (no DELETE: a run is a fact; its checks are filled in, never removed).
--   3. Register 490.
--
-- Schema. DM-1.5: CIS-private (only the CIS admin assistant reads it), so in acp_shared next to the status page tables
-- (CIS 475, 482, 485), not in shared.
--
-- PII (DM-6.1). No free text typed by a person: the predictions are the rule-made card texts (aggregates, keys, error
-- classes); recorded_by is an actor id. No tenant column (platform operations).
--
-- Retention (DM-7.1). Proposed: kept for good (the track record of each action is its whole history; a few rows a
-- month on Dev). No deletion job; revisit before prod (DM-7.5). Row in root data standards Part B section 7, in the
-- root PR of this change (merged before the Infra copy).
--
-- Class: expand (root ADR 0017 d3): one new table with its constraints and indexes, the grant to the owner's runtime
-- role, comments on new objects and the shared.schema_versions registration; no existing object changes, no seed row,
-- no DO block, no REVOKE. Migration-only PR (MIG-4) together with CIS 491 (the A2 settings, contract).
--
-- Behaviour on apply: none. The table is empty; nothing reads it until the A2 code ships (the code answers "not set
-- up yet" while the table is missing).
--
-- Number. Owner main max (489, AA-1178) + 1, with 491 in the same CIS migration batch (490-491). If the owner main
-- max + 1 differs at merge, renumber: git grep '490_' and "'490'" (this file,
-- tests/integration/test_aa1154_migration_490_491.py, docs/implementation-notes/AA-1154.md).
--
-- Locks. One CREATE TABLE and its indexes (new objects); one foreign key to acp_shared.ops_incident (a SHARE ROW
-- EXCLUSIVE lock on that small table for the instant of the CREATE). lock_timeout 5s.
--
-- Rollback (a new forward migration, after the code PR is reverted): DROP TABLE acp_shared.ops_assist_run (a
-- destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of schema
-- acp_shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS acp_shared.ops_assist_run (
    run_id           bigint       GENERATED ALWAYS AS IDENTITY,
    item_id          text         NOT NULL,
    card_id          text         NOT NULL,
    action           text         NOT NULL,
    playbook         text,
    risk_level       text         NOT NULL,
    range_key        text         NOT NULL DEFAULT '24h',
    incident_id      bigint,
    predicted        jsonb        NOT NULL DEFAULT '[]'::jsonb,
    measures         jsonb        NOT NULL DEFAULT '[]'::jsonb,
    check_after_min  integer[]    NOT NULL,
    checks           jsonb        NOT NULL DEFAULT '[]'::jsonb,
    verdict          text,
    checked_at       timestamptz,
    recorded_by      text         NOT NULL,
    recorded_at      timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT ops_assist_run_pkey PRIMARY KEY (run_id),
    CONSTRAINT ops_assist_run_incident_fk FOREIGN KEY (incident_id)
        REFERENCES acp_shared.ops_incident (incident_id),
    CONSTRAINT ops_assist_run_item_chk CHECK (char_length(item_id) BETWEEN 1 AND 200),
    CONSTRAINT ops_assist_run_card_chk CHECK (char_length(card_id) BETWEEN 1 AND 300),
    CONSTRAINT ops_assist_run_action_chk CHECK (action ~ '^[a-z][a-z0-9_]{0,63}$'),
    CONSTRAINT ops_assist_run_playbook_chk CHECK (playbook IS NULL OR playbook ~ '^[a-z][a-z0-9_]{0,63}$'),
    CONSTRAINT ops_assist_run_risk_chk CHECK (risk_level IN ('R0', 'R1', 'R2', 'R3', 'R4')),
    CONSTRAINT ops_assist_run_range_chk CHECK (range_key IN ('1h', '6h', '24h', '7d')),
    CONSTRAINT ops_assist_run_predicted_chk CHECK (jsonb_typeof(predicted) = 'array'
        AND octet_length(predicted::text) <= 16384),
    CONSTRAINT ops_assist_run_measures_chk CHECK (jsonb_typeof(measures) = 'array'
        AND octet_length(measures::text) <= 16384),
    CONSTRAINT ops_assist_run_check_after_chk CHECK (cardinality(check_after_min) BETWEEN 1 AND 10
        AND 0 < ALL (check_after_min)),
    CONSTRAINT ops_assist_run_checks_chk CHECK (jsonb_typeof(checks) = 'array'
        AND octet_length(checks::text) <= 32768),
    CONSTRAINT ops_assist_run_verdict_chk CHECK (verdict IS NULL OR verdict IN ('hit', 'miss', 'unclear')),
    CONSTRAINT ops_assist_run_checked_chk CHECK ((verdict IS NULL) = (checked_at IS NULL)
        AND (checked_at IS NULL OR checked_at >= recorded_at)),
    CONSTRAINT ops_assist_run_recorded_by_chk CHECK (char_length(recorded_by) BETWEEN 1 AND 64)
);

CREATE INDEX IF NOT EXISTS ops_assist_run_recorded_idx ON acp_shared.ops_assist_run (recorded_at DESC);
CREATE INDEX IF NOT EXISTS ops_assist_run_open_idx ON acp_shared.ops_assist_run (recorded_at) WHERE verdict IS NULL;
CREATE INDEX IF NOT EXISTS ops_assist_run_action_idx ON acp_shared.ops_assist_run (action, verdict);
CREATE INDEX IF NOT EXISTS ops_assist_run_item_idx ON acp_shared.ops_assist_run (item_id, recorded_at DESC);

COMMENT ON TABLE acp_shared.ops_assist_run IS
    'AA-1154 A2 (CIS 490): one action card of the CIS admin assistant that a person marked as done (POST '
    '/admin/ops-assist/runs), with its predictions, what is measured again and the checks the status sampler takes at '
    'the minutes of cis.ops.assist_check_after_min (hit / miss / unclear). The source of the hit rate on the status '
    'page and in the digest, and of each action''s track record. Proposed retention: kept for good (DM-7.1).';
COMMENT ON COLUMN acp_shared.ops_assist_run.measures IS
    'AA-1154 (490): [{metric, params, expect (zero | down | up | nonzero), label, baseline}]: what the checks read '
    'again and in which direction the card predicts it moves; baseline = the value when the card was marked done.';
COMMENT ON COLUMN acp_shared.ops_assist_run.checks IS
    'AA-1154 (490): [{after_min, at, values, verdict, late}]: one entry per checkpoint taken by the status sampler.';
COMMENT ON COLUMN acp_shared.ops_assist_run.verdict IS
    'AA-1154 (490): the verdict of the last checkpoint (hit, miss, unclear); NULL while a checkpoint is still due.';
COMMENT ON COLUMN acp_shared.ops_assist_run.recorded_by IS
    'AA-1154 (490): admin:<admin_users.id> of the person who marked the card as done. Never an e-mail.';

GRANT SELECT, INSERT, UPDATE ON acp_shared.ops_assist_run TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('490', now(), 'AA-1154 A2: acp_shared.ops_assist_run, the action cards a person ran with predicted against '
                      'measured outcomes')
ON CONFLICT (version) DO NOTHING;

COMMIT;
