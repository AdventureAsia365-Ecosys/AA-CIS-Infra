-- migrate: expand
-- Migration 485: AA-1142 (S292, the P2 features of the Ecosystem status page) — the incident record with its timeline
-- of updates, and the results of the external synthetic checks.
--
-- Why. The S285 review of the status page (root docs/audits/2026-11-19-S285-session/ops-overview-v2-review.md, ideas
-- 10 and 11) picked them as P2 before the first prod: an incident lives only in a session log today, and every
-- internal check runs inside the VPC, so a DNS or certificate fault a customer would meet is not seen. Both are free
-- (database only; the checks run on GitHub Actions of the public root repo).
--
-- What:
--   1. acp_shared.ops_incident: one row per incident declared from the status page (POST /admin/overview/incidents,
--      ops.write, never the business owner). title, severity sev1-sev3 (root docs/ops/incident-response.md), status
--      investigating | identified | monitoring | resolved, the app, the Needs-attention item it was declared from
--      (item_id, the item's id in GET /admin/overview/status), the owner (admin:<admin_users.id>), an optional summary,
--      who declared it and when, resolved_at (set exactly when the status is resolved). At most one unresolved
--      incident per item (partial unique index), so the same alert is not declared twice. This is the minimal
--      incident record the S285 advisory names (ops_incident); the admin assistant may link its runs to incident_id.
--   2. acp_shared.ops_incident_update: the incident's own trail (declared, status, severity, owner, note) with the
--      old and new value and an optional note. The page builds the timeline from these rows and the
--      acp_shared.ops_event rows (deploys, alarms, service drops) of the incident's app from
--      cis.ops.status_incident_lookback_min before it was declared until it was resolved.
--   3. acp_shared.ops_external_check: one row per check of one public target per run of the root repo workflow
--      "External checks" (every 15 minutes, GitHub Actions, 0 USD): DNS answered, TLS handshake valid, the
--      certificate's end date, the HTTP status and time of the health path, and the state the CIS sampler derived
--      (ok, warn, degraded, down, unknown). The workflow publishes its newest results next to the delivery summary
--      (docs-reader/ops/external-checks.json, the existing Docs sync role); the 5-minute status sampler copies a run it
--      has not seen yet into this table (ON CONFLICT (target, checked_at) DO NOTHING), so the page draws an external
--      strip over any range of the history window.
--   4. GRANT cis_app SELECT, INSERT, UPDATE on the incident tables (no DELETE: an incident is resolved, never
--      deleted) and SELECT, INSERT on the check results (rows are facts, never changed).
--   5. Register 485.
--
-- Schema. DM-1.5: the three tables are CIS-private (only the CIS status page reads them), so they live in acp_shared
-- next to acp_shared.ops_event and ops_sample (CIS 475), not in shared.
--
-- PII (DM-6.1). ops_incident.title / summary and ops_incident_update.note are free text typed by staff
-- (pii:free_text, an operational description, never personal data by rule); owner, declared_by and actor are actor
-- ids, never e-mails. ops_external_check holds public host names and numbers only. No tenant column (platform
-- operations).
--
-- Retention (DM-7.1). Proposed: ops_incident and ops_incident_update kept for good (the incident history the
-- postmortems and lessons cite; a few rows a month), ops_external_check like acp_shared.ops_sample (CIS 475): the
-- page's history window, cis.ops.status_history_days. No deletion job yet; nothing is deleted until the tech lead
-- approves the windows before prod (DM-7.5). About 800 check rows a day. Rows in root data standards Part B section 7,
-- in the root PR of this change (merged before the Infra copy).
--
-- Class: expand (root ADR 0017 d3): three new tables with their constraints and indexes, grants to the owner's runtime
-- role, comments on new objects and the shared.schema_versions registration; no existing object changes, no seed row,
-- no DO block, no REVOKE. Migration-only PR (MIG-4) together with CIS 486 (the settings, contract); the code PR adds 485
-- and 486 to REQUIRED_CIS_ABOVE_GAP.
--
-- Behaviour on apply: none. The tables are empty; nothing reads them until the AA-1142 code ships.
--
-- Number. Owner main max (484, AA-1169) + 1, with 486 in the same CIS migration batch (485-486). If the owner main max + 1
-- differs at merge, renumber (git grep '485_' and "'485'" here, in tests/integration/test_aa1142_migration_485_486.py,
-- api/core/readiness.py and docs/implementation-notes/AA-1142.md).
--
-- Locks. Three CREATE TABLE and their indexes (new objects). lock_timeout 5s.
--
-- Rollback (a new forward migration, after the code PR is reverted): DROP TABLE acp_shared.ops_external_check,
-- acp_shared.ops_incident_update, acp_shared.ops_incident (a destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of schema
-- acp_shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. Incident record ──────────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS acp_shared.ops_incident (
    incident_id   bigint       GENERATED ALWAYS AS IDENTITY,
    title         text         NOT NULL,
    severity      text         NOT NULL,
    status        text         NOT NULL DEFAULT 'investigating',
    app           text,
    item_id       text,
    owner         text         NOT NULL,
    summary       text,
    declared_by   text         NOT NULL,
    declared_at   timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz  NOT NULL DEFAULT now(),
    resolved_at   timestamptz,
    CONSTRAINT ops_incident_pkey PRIMARY KEY (incident_id),
    CONSTRAINT ops_incident_title_chk CHECK (char_length(btrim(title)) BETWEEN 3 AND 300),
    CONSTRAINT ops_incident_severity_chk CHECK (severity IN ('sev1', 'sev2', 'sev3')),
    CONSTRAINT ops_incident_status_chk CHECK (status IN ('investigating', 'identified', 'monitoring', 'resolved')),
    CONSTRAINT ops_incident_app_chk CHECK (app IS NULL OR app IN ('cis', 'tripplanner', 'booking', 'crm', 'shared')),
    CONSTRAINT ops_incident_item_chk CHECK (item_id IS NULL OR char_length(item_id) BETWEEN 1 AND 200),
    CONSTRAINT ops_incident_owner_chk CHECK (char_length(owner) BETWEEN 1 AND 64),
    CONSTRAINT ops_incident_declared_by_chk CHECK (char_length(declared_by) BETWEEN 1 AND 64),
    CONSTRAINT ops_incident_summary_chk CHECK (summary IS NULL OR char_length(summary) <= 2000),
    CONSTRAINT ops_incident_resolved_chk CHECK ((status = 'resolved') = (resolved_at IS NOT NULL)
        AND (resolved_at IS NULL OR resolved_at >= declared_at)),
    CONSTRAINT ops_incident_time_chk CHECK (updated_at >= declared_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS ops_incident_open_item_uq ON acp_shared.ops_incident (item_id)
    WHERE status <> 'resolved' AND item_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ops_incident_declared_idx ON acp_shared.ops_incident (declared_at DESC);

COMMENT ON TABLE acp_shared.ops_incident IS
    'AA-1142 (CIS 485): an incident declared from the Ecosystem status page (POST /admin/overview/incidents, ops.write, '
    'never the business owner): SEV, status, owner, the Needs-attention item it came from. At most one unresolved '
    'incident per item. Every write is also an ops_incident_update row and an audit row. Proposed retention: kept for '
    'good (DM-7.1).';
COMMENT ON COLUMN acp_shared.ops_incident.title IS
    'pii:free_text; AA-1142 (485): what is wrong, as the person who declared it wrote it (3-300 characters).';
COMMENT ON COLUMN acp_shared.ops_incident.summary IS
    'pii:free_text; AA-1142 (485): an optional longer description (at most 2000 characters).';
COMMENT ON COLUMN acp_shared.ops_incident.item_id IS
    'AA-1142 (485): the Needs-attention item id of GET /admin/overview/status it was declared from (NULL: by hand).';
COMMENT ON COLUMN acp_shared.ops_incident.owner IS
    'AA-1142 (485): admin:<admin_users.id> of the person handling it (the audit actor format). Never an e-mail.';
COMMENT ON COLUMN acp_shared.ops_incident.declared_by IS
    'AA-1142 (485): admin:<admin_users.id> of the person who declared it. Never an e-mail.';

GRANT SELECT, INSERT, UPDATE ON acp_shared.ops_incident TO cis_app;

-- ── 2. Incident updates (its own timeline) ──────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS acp_shared.ops_incident_update (
    update_id     bigint       GENERATED ALWAYS AS IDENTITY,
    incident_id   bigint       NOT NULL,
    at            timestamptz  NOT NULL DEFAULT now(),
    actor         text         NOT NULL,
    kind          text         NOT NULL,
    from_value    text,
    to_value      text,
    note          text,
    CONSTRAINT ops_incident_update_pkey PRIMARY KEY (update_id),
    CONSTRAINT ops_incident_update_incident_fk FOREIGN KEY (incident_id)
        REFERENCES acp_shared.ops_incident (incident_id),
    CONSTRAINT ops_incident_update_kind_chk CHECK (kind IN ('declared', 'status', 'severity', 'owner', 'note')),
    CONSTRAINT ops_incident_update_actor_chk CHECK (char_length(actor) BETWEEN 1 AND 64),
    CONSTRAINT ops_incident_update_values_chk CHECK ((from_value IS NULL OR char_length(from_value) <= 64)
        AND (to_value IS NULL OR char_length(to_value) <= 64)),
    CONSTRAINT ops_incident_update_note_chk CHECK (note IS NULL OR char_length(note) <= 2000),
    CONSTRAINT ops_incident_update_note_kind_chk CHECK (kind <> 'note' OR char_length(btrim(note)) >= 1)
);

CREATE INDEX IF NOT EXISTS ops_incident_update_incident_idx ON acp_shared.ops_incident_update (incident_id, at);

COMMENT ON TABLE acp_shared.ops_incident_update IS
    'AA-1142 (CIS 485): the trail of one incident (declared, status, severity, owner, note) with the old and new value; '
    'the status page merges it with the ops_event rows of the incident''s app into the timeline. Kept with its '
    'incident (DM-7.1).';
COMMENT ON COLUMN acp_shared.ops_incident_update.note IS
    'pii:free_text; AA-1142 (485): what the person wrote with the update (at most 2000 characters).';
COMMENT ON COLUMN acp_shared.ops_incident_update.actor IS
    'AA-1142 (485): admin:<admin_users.id> of the person who made the update. Never an e-mail.';

GRANT SELECT, INSERT ON acp_shared.ops_incident_update TO cis_app;

-- ── 3. External synthetic check results ─────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS acp_shared.ops_external_check (
    check_id        bigint       GENERATED ALWAYS AS IDENTITY,
    checked_at      timestamptz  NOT NULL,
    target          text         NOT NULL,
    app             text,
    host            text         NOT NULL,
    state           text         NOT NULL,
    dns_ok          boolean,
    tls_ok          boolean,
    cert_not_after  timestamptz,
    http_status     integer,
    latency_ms      integer,
    error           text,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT ops_external_check_pkey PRIMARY KEY (check_id),
    CONSTRAINT ops_external_check_target_chk CHECK (target ~ '^[a-z0-9][a-z0-9-]{0,59}$'),
    CONSTRAINT ops_external_check_app_chk CHECK (app IS NULL OR app IN ('cis', 'tripplanner', 'booking', 'crm',
                                                                          'shared')),
    CONSTRAINT ops_external_check_host_chk CHECK (host ~ '^[a-z0-9.-]{1,253}$'),
    CONSTRAINT ops_external_check_state_chk CHECK (state IN ('ok', 'warn', 'degraded', 'down', 'unknown')),
    CONSTRAINT ops_external_check_http_chk CHECK (http_status IS NULL OR http_status BETWEEN 100 AND 599),
    CONSTRAINT ops_external_check_latency_chk CHECK (latency_ms IS NULL OR latency_ms BETWEEN 0 AND 600000),
    CONSTRAINT ops_external_check_error_chk CHECK (error IS NULL OR char_length(error) <= 300)
);

CREATE UNIQUE INDEX IF NOT EXISTS ops_external_check_target_at_key
    ON acp_shared.ops_external_check (target, checked_at);
CREATE INDEX IF NOT EXISTS ops_external_check_checked_at_idx ON acp_shared.ops_external_check (checked_at);

COMMENT ON TABLE acp_shared.ops_external_check IS
    'AA-1142 (CIS 485): one result of the external synthetic checks (root repo workflow External checks, every 15 '
    'minutes on GitHub Actions) for one public target: DNS, TLS and its certificate end date, the health path. Copied '
    'by the 5-minute status sampler from docs-reader/ops/external-checks.json. Proposed retention: '
    'cis.ops.status_history_days like ops_sample (DM-7.1), no deletion job yet.';
COMMENT ON COLUMN acp_shared.ops_external_check.target IS
    'AA-1142 (485): the check''s id in the workflow config (root tools/ops/external_checks.json), e.g. cis-api.';
COMMENT ON COLUMN acp_shared.ops_external_check.state IS
    'AA-1142 (485): ok, warn (certificate within cis.ops.status_cert_warn_days), degraded (certificate within the '
    'critical days, or an unexpected HTTP status), down (DNS, TLS or the request failed), unknown.';

GRANT SELECT, INSERT ON acp_shared.ops_external_check TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('485', now(), 'AA-1142: acp_shared.ops_incident, ops_incident_update and ops_external_check (status P2)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
