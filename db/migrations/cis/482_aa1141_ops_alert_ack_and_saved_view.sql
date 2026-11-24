-- migrate: expand
-- Migration 482: AA-1141 (S291, the P1 features of the Ecosystem status page) — who handles an alert (ack, snooze,
-- mute with an end time) and the named saved views of each staff member.
--
-- Why. The S285 review of the status page mockup (root docs/audits/2026-11-19-S285-session/ops-overview-v2-review.md,
-- ideas 2 and 7) picked them as P1: an alert repeats on every refresh and nobody can say "I have it"; the view is in
-- the URL but a useful one cannot be kept under a name. Both are free (database only).
--
-- What:
--   1. acp_shared.ops_alert_ack: one row per ack / snooze / mute of one Needs-attention item of the status page
--      (item_id = the item's id in GET /admin/overview/status, e.g. errors-cis, alarm-<event id>, svc-<service>).
--      action ack | snooze | mute, until (when it ends by itself: ack after cis.ops.status_ack_hours, snooze 1 h,
--      4 h or until tomorrow, mute at the end time the person picked, at most cis.ops.status_mute_max_days ahead),
--      reason (at least cis.ops.status_ack_reason_min_chars characters, checked by the API; the table keeps a floor of
--      10, the setting's lowest bound), actor (admin:<admin_users.id>, never an e-mail), the item's app, severity and
--      title as the person saw them, and when it was cleared before its end (cleared_at / cleared_by /
--      cleared_reason). The page reads the rows in force (cleared_at IS NULL AND until > now()): the item shows
--      "Acked by ... at ..." and leaves the open count. A new ack of the same item clears the one in force in the
--      same transaction (the API), so at most one row of an item is in force. Every write is also an audit row
--      (acp_shared.audit_log, action ops_alert_ack / ops_alert_ack_cleared).
--   2. acp_shared.ops_saved_view: one row per named view of one staff member (staff_id = admin_users.id): name (1-80
--      characters, unique per staff member ignoring case and outer spaces) and query (the page's view keys as a
--      JSON object of at most 4 KiB: range, compare, apps, filters, hidden series, sorts). Read and written only by
--      its owner through /admin/overview/views.
--   3. GRANT cis_app SELECT, INSERT, UPDATE on the acks (no DELETE: an ack is cleared, never deleted; see Retention)
--      and SELECT, INSERT, UPDATE, DELETE on the saved views (a person deletes their own view).
--   4. Register 482.
--
-- Schema. DM-1.5: both tables are CIS-private (only the CIS status page reads them), so they live in acp_shared next
-- to acp_shared.ops_event and ops_sample (CIS 475), not in shared.
--
-- PII (DM-6.1). ops_alert_ack.reason and cleared_reason are free text typed by staff (pii:free_text, an operational
-- reason, never personal data by rule); actor / cleared_by are actor ids. ops_saved_view.name is free text
-- (pii:free_text, a view name); staff_id is an admin_users id. No tenant column (platform operations).
--
-- Retention (DM-7.1). Proposed: ops_alert_ack 90 days after until (the ack trail of a quarter; the audit log keeps
-- every write for good), ops_saved_view while the staff member's account exists (deleted with it). No deletion job
-- yet; nothing is deleted until the tech lead approves the windows before prod (DM-7.5). A few rows a day. Rows in
-- root data standards Part B section 7, in the root PR of this change (merged before the Infra copy).
--
-- Class: expand (root ADR 0017 d3): two new tables with their constraints and indexes, grants to the owner's runtime
-- role, comments on new objects and the shared.schema_versions registration; no existing object changes, no seed row,
-- no DO block, no REVOKE (the cis_owner default ACL in acp_shared gives cis_app DML on a new table; the explicit GRANT
-- documents what the code needs). Migration-only PR (MIG-4) together with CIS 483 (the settings, contract); the code
-- PR adds 482 and 483 to REQUIRED_CIS_ABOVE_GAP.
--
-- Behaviour on apply: none. Both tables are empty; nothing reads them until the AA-1141 code ships.
--
-- Number. Owner main max (481) + 1, with 483 in the same CIS migration batch (482-483). If the owner main max + 1
-- differs at merge, renumber (git grep '482_' and "'482'" here, in tests/integration/test_aa1141_migration_482_483.py,
-- api/core/readiness.py and docs/implementation-notes/AA-1141.md).
--
-- Locks. Two CREATE TABLE and their indexes (new objects). lock_timeout 5s.
--
-- Rollback (a new forward migration, after the code PR is reverted): DROP TABLE acp_shared.ops_saved_view,
-- acp_shared.ops_alert_ack (a destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of schema
-- acp_shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. Ack / snooze / mute ───────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS acp_shared.ops_alert_ack (
    ack_id          bigint       GENERATED ALWAYS AS IDENTITY,
    item_id         text         NOT NULL,
    app             text,
    severity        text,
    title           text,
    action          text         NOT NULL,
    until           timestamptz  NOT NULL,
    reason          text         NOT NULL,
    actor           text         NOT NULL,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    cleared_at      timestamptz,
    cleared_by      text,
    cleared_reason  text,
    CONSTRAINT ops_alert_ack_pkey PRIMARY KEY (ack_id),
    CONSTRAINT ops_alert_ack_item_chk CHECK (char_length(item_id) BETWEEN 1 AND 200),
    CONSTRAINT ops_alert_ack_app_chk CHECK (app IS NULL OR app IN ('cis', 'tripplanner', 'booking', 'crm', 'shared')),
    CONSTRAINT ops_alert_ack_severity_chk CHECK (severity IS NULL OR severity IN ('sev1', 'sev2', 'sev3')),
    CONSTRAINT ops_alert_ack_title_chk CHECK (title IS NULL OR char_length(title) <= 300),
    CONSTRAINT ops_alert_ack_action_chk CHECK (action IN ('ack', 'snooze', 'mute')),
    CONSTRAINT ops_alert_ack_until_chk CHECK (until > created_at),
    CONSTRAINT ops_alert_ack_reason_chk CHECK (char_length(btrim(reason)) BETWEEN 10 AND 2000),
    CONSTRAINT ops_alert_ack_actor_chk CHECK (char_length(actor) BETWEEN 1 AND 64),
    CONSTRAINT ops_alert_ack_cleared_chk CHECK ((cleared_at IS NULL) = (cleared_by IS NULL)
        AND (cleared_at IS NULL OR cleared_at >= created_at)
        AND (cleared_by IS NULL OR char_length(cleared_by) BETWEEN 1 AND 64)
        AND (cleared_reason IS NULL OR char_length(cleared_reason) <= 2000))
);

CREATE INDEX IF NOT EXISTS ops_alert_ack_open_idx ON acp_shared.ops_alert_ack (item_id, until DESC)
    WHERE cleared_at IS NULL;
CREATE INDEX IF NOT EXISTS ops_alert_ack_created_idx ON acp_shared.ops_alert_ack (created_at DESC);

COMMENT ON TABLE acp_shared.ops_alert_ack IS
    'AA-1141 (CIS 482): who acknowledged, snoozed or muted a Needs-attention item of the Ecosystem status page, why and '
    'until when (POST /admin/overview/status/acks, ops.write, never the business owner). In force while cleared_at '
    'IS NULL AND until > now(); ends by itself at until. Every write is also an audit row. Proposed retention 90 days '
    'after until (DM-7.1), no deletion job yet.';
COMMENT ON COLUMN acp_shared.ops_alert_ack.item_id IS
    'AA-1141 (482): the item id of GET /admin/overview/status (errors-cis, alarm-<event id>, svc-<service>, ...).';
COMMENT ON COLUMN acp_shared.ops_alert_ack.action IS
    'AA-1141 (482): ack (until cis.ops.status_ack_hours later), snooze (1 h, 4 h or until tomorrow), mute (an end '
    'time the person picked, at most cis.ops.status_mute_max_days ahead).';
COMMENT ON COLUMN acp_shared.ops_alert_ack.reason IS
    'pii:free_text; AA-1141 (482): why, at least cis.ops.status_ack_reason_min_chars characters (API), 10 here.';
COMMENT ON COLUMN acp_shared.ops_alert_ack.cleared_reason IS
    'pii:free_text; AA-1141 (482): why it was cleared before its end (optional).';
COMMENT ON COLUMN acp_shared.ops_alert_ack.actor IS
    'AA-1141 (482): admin:<admin_users.id> of the staff member (the audit actor format). Never an e-mail.';

GRANT SELECT, INSERT, UPDATE ON acp_shared.ops_alert_ack TO cis_app;

-- ── 2. Saved views ──────────────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS acp_shared.ops_saved_view (
    view_id     uuid         NOT NULL DEFAULT gen_random_uuid(),
    staff_id    uuid         NOT NULL,
    name        text         NOT NULL,
    query       jsonb        NOT NULL,
    created_at  timestamptz  NOT NULL DEFAULT now(),
    updated_at  timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT ops_saved_view_pkey PRIMARY KEY (view_id),
    CONSTRAINT ops_saved_view_name_chk CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
    CONSTRAINT ops_saved_view_query_chk CHECK (jsonb_typeof(query) = 'object' AND octet_length(query::text) <= 4096),
    CONSTRAINT ops_saved_view_time_chk CHECK (updated_at >= created_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS ops_saved_view_staff_name_uq
    ON acp_shared.ops_saved_view (staff_id, lower(btrim(name)));

COMMENT ON TABLE acp_shared.ops_saved_view IS
    'AA-1141 (CIS 482): the named views of the Ecosystem status page of one staff member (/admin/overview/views): the '
    'page''s view keys (range, compare, filters, hidden series, sorts) under a name. Read and written only by its '
    'owner. Proposed retention: while the staff account exists (DM-7.1).';
COMMENT ON COLUMN acp_shared.ops_saved_view.name IS
    'pii:free_text; AA-1141 (482): the view name the staff member typed (1-80 characters).';
COMMENT ON COLUMN acp_shared.ops_saved_view.query IS
    'AA-1141 (482): the view keys of the page URL as a JSON object of strings (at most 4 KiB).';

GRANT SELECT, INSERT, UPDATE, DELETE ON acp_shared.ops_saved_view TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('482', now(), 'AA-1141: acp_shared.ops_alert_ack and acp_shared.ops_saved_view (Ecosystem status ack and views)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
