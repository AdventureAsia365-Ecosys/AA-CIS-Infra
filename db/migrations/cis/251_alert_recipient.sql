-- Migration 251: AA-913 — shared.alert_recipient: the platform alert mailboxes the CIS admin page manages.
--
-- Why. Platform alerts (CloudWatch alarms of CIS / Booking / TripPlanner / shared, security EventBridge rules, cost
-- anomalies and, after the AA-913 Infra change, AWS Budgets) are delivered by the SNS alerts topic, and the CIS
-- spend e-mails (job ops_alert_email) by SES. Until now each had one hard-coded recipient in Terraform
-- (var.alert_email / ALERT_EMAIL_TO). The owner wants to pick the recipients on the admin page
-- (Platform › People & access › Alert recipients). This table is the CIS side of that list: one row per e-mail
-- subscription the CIS api created on the alerts topic. The Terraform bootstrap subscription is NOT stored here
-- (it is shown locked in the UI, read from ALERT_BOOTSTRAP_EMAIL).
--
-- What.
--   1. shared.alert_recipient (CIS-owned, docs/database/schema-ownership.md "shared.* by table"): e-mail, note,
--      status pending / confirmed / removed (+ removed_reason admin / unsubscribed / expired), the SNS subscription
--      ARN (never returned to the browser), who / when, and what SNS said at the last reconcile. Rows are never
--      deleted: a removed row is history, re-adding an address inserts a new row (partial unique index: one active
--      row per address).
--   2. Privileges: cis_app (CIS runtime, X1) SELECT / INSERT / UPDATE only — no DELETE (history stays); nothing for
--      aa_app_user, tripplanner, booking or PUBLIC. The grants are explicit because the CI replay runs as a superuser
--      without CIS 244/245's default privileges.
--   3. COMMENT ON TABLE / COLUMN (DM-6.1; email is pii:contact).
--   4. Register 251.
--   No RLS: a platform table without tenant_id, like shared.spend_budget (RLS catalogue rule a does not apply; no
--   policy, so the X1 standing check has nothing to require).
--
-- Guards (RAISE on failure, nothing changes):
--   0. before: shared.admin_users and acp_shared.audit_log exist (the api resolves created_by against the first and
--      writes alert_recipient.* audit rows to the second).
--   1. after: the columns with their types; the 4 named CHECK constraints and the partial unique index; RLS off;
--      cis_app holds exactly SELECT, INSERT, UPDATE; aa_app_user, tripplanner, booking and PUBLIC hold nothing (each
--      role only when it exists).
--
-- Locks. A new table and its indexes: nothing else is locked. lock_timeout 5s. Re-running is a no-op (IF NOT EXISTS,
-- idempotent GRANT / REVOKE / COMMENT, ON CONFLICT DO NOTHING).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243, AA-CIS-Infra db/owners.yaml). DB Migrate runs
-- cis/ files as cis_owner, which therefore owns the new table. If CIS 244 is ever re-applied it re-grants DELETE on
-- every shared table to cis_app; guard 1 here only checks this file's own result.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the
-- two byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).
--
-- Rollback: remove the app-created subscriptions from SNS first (admin page or console), then a NEW migration
-- `DROP TABLE shared.alert_recipient` (destructive directive, DRY RUN procedure). The Terraform bootstrap
-- subscription keeps receiving every alert throughout.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: what the api needs next to the table ───────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('shared.admin_users') IS NULL THEN
        RAISE EXCEPTION 'migration 251: shared.admin_users does not exist (migration 074)';
    END IF;
    IF to_regclass('acp_shared.audit_log') IS NULL THEN
        RAISE EXCEPTION 'migration 251: acp_shared.audit_log does not exist (migration 030)';
    END IF;
END $$;

-- ── 1. The table ─────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.alert_recipient (
    id                         uuid        NOT NULL DEFAULT gen_random_uuid(),
    email                      text        NOT NULL,
    note                       text,
    status                     text        NOT NULL DEFAULT 'pending',
    removed_reason             text,
    subscription_arn           text,
    created_at                 timestamptz NOT NULL DEFAULT now(),
    created_by                 text        NOT NULL,           -- 'admin:<shared.admin_users.id>'
    confirmed_at               timestamptz,
    removed_at                 timestamptz,
    removed_by                 text,                           -- 'admin:<id>', 'reconcile' or 'job:<kind>'
    last_confirmation_sent_at  timestamptz,
    last_seen_state            text,                           -- what SNS said at the last reconcile
    last_reconciled_at         timestamptz,
    updated_at                 timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT alert_recipient_pkey PRIMARY KEY (id),
    CONSTRAINT alert_recipient_email_chk CHECK (
        email = lower(email) AND length(email) <= 254
        AND email ~ '^[^@[:space:],;<>"]+@[^@[:space:],;<>"]+\.[^@[:space:],;<>"]+$'),
    CONSTRAINT alert_recipient_note_chk CHECK (note IS NULL OR length(note) <= 80),
    CONSTRAINT alert_recipient_status_chk CHECK (status IN ('pending', 'confirmed', 'removed')),
    CONSTRAINT alert_recipient_removed_chk CHECK (
        (status = 'removed') = (removed_at IS NOT NULL)
        AND (status = 'removed') = (removed_reason IS NOT NULL)
        AND (removed_reason IS NULL OR removed_reason IN ('admin', 'unsubscribed', 'expired'))),
    CONSTRAINT alert_recipient_seen_chk CHECK (
        last_seen_state IS NULL OR last_seen_state IN ('confirmed', 'pending', 'missing'))
);

-- one active row per address; removed rows are history
CREATE UNIQUE INDEX IF NOT EXISTS alert_recipient_active_email_uq
    ON shared.alert_recipient (email) WHERE status <> 'removed';
CREATE INDEX IF NOT EXISTS alert_recipient_status_idx ON shared.alert_recipient (status, created_at DESC);

-- ── 2. Privileges ────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON shared.alert_recipient FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON shared.alert_recipient TO cis_app;
REVOKE DELETE, TRUNCATE, REFERENCES, TRIGGER ON shared.alert_recipient FROM cis_app;   -- history stays
REVOKE ALL ON shared.alert_recipient FROM aa_app_user;
DO $$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['tripplanner', 'booking'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r) THEN
            EXECUTE format('REVOKE ALL ON shared.alert_recipient FROM %I', r);
        END IF;
    END LOOP;
END $$;

-- ── 3. Comments (DM-6.1) ─────────────────────────────────────────────────────────────────────────
COMMENT ON TABLE shared.alert_recipient IS
    'AA-913 (251): platform alert mailboxes managed by the CIS api (admin page Platform › Alert recipients). Mirrors the e-mail subscriptions the api created on the SNS alerts topic; the Terraform bootstrap subscription is not stored. Confirmed rows also receive the CIS ops_alert_email (SES). Rows are never deleted.';
COMMENT ON COLUMN shared.alert_recipient.email IS 'pii:contact; AA-913 alert recipient mailbox (lower case)';
COMMENT ON COLUMN shared.alert_recipient.subscription_arn IS
    'SNS subscription ARN (contains the account id: never returned to the browser)';
COMMENT ON COLUMN shared.alert_recipient.removed_reason IS
    'admin (removed on the admin page) / unsubscribed (gone from SNS after it was confirmed) / expired (never confirmed within 3 days)';
COMMENT ON COLUMN shared.alert_recipient.last_seen_state IS
    'What ListSubscriptionsByTopic said at the last reconcile: confirmed / pending / missing';

-- ── Guard 1: the table this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    want text[][] := ARRAY[
        ARRAY['id', 'uuid'], ARRAY['email', 'text'], ARRAY['note', 'text'], ARRAY['status', 'text'],
        ARRAY['removed_reason', 'text'], ARRAY['subscription_arn', 'text'],
        ARRAY['created_at', 'timestamp with time zone'], ARRAY['created_by', 'text'],
        ARRAY['confirmed_at', 'timestamp with time zone'], ARRAY['removed_at', 'timestamp with time zone'],
        ARRAY['removed_by', 'text'], ARRAY['last_confirmation_sent_at', 'timestamp with time zone'],
        ARRAY['last_seen_state', 'text'], ARRAY['last_reconciled_at', 'timestamp with time zone'],
        ARRAY['updated_at', 'timestamp with time zone']];
    i int;
    got text;
    missing text;
    r text;
BEGIN
    FOR i IN 1 .. array_length(want, 1) LOOP
        SELECT pg_catalog.format_type(atttypid, atttypmod) INTO got
          FROM pg_catalog.pg_attribute
         WHERE attrelid = 'shared.alert_recipient'::regclass AND attname = want[i][1] AND NOT attisdropped;
        IF got IS DISTINCT FROM want[i][2] THEN
            RAISE EXCEPTION 'migration 251: shared.alert_recipient.% is %, expected %', want[i][1], got, want[i][2];
        END IF;
    END LOOP;

    SELECT string_agg(c, ', ') INTO missing
      FROM unnest(ARRAY['alert_recipient_email_chk', 'alert_recipient_note_chk', 'alert_recipient_status_chk',
                        'alert_recipient_removed_chk', 'alert_recipient_seen_chk']) AS c
     WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                        WHERE conrelid = 'shared.alert_recipient'::regclass AND conname = c AND contype = 'c'
                          AND convalidated);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 251: shared.alert_recipient lacks CHECK constraint(s) %', missing;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_index x
                     JOIN pg_catalog.pg_class ic ON ic.oid = x.indexrelid
                    WHERE x.indrelid = 'shared.alert_recipient'::regclass
                      AND ic.relname = 'alert_recipient_active_email_uq'
                      AND x.indisunique AND x.indpred IS NOT NULL) THEN
        RAISE EXCEPTION 'migration 251: the partial unique index alert_recipient_active_email_uq is missing';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_catalog.pg_class
                WHERE oid = 'shared.alert_recipient'::regclass AND (relrowsecurity OR relforcerowsecurity)) THEN
        RAISE EXCEPTION 'migration 251: shared.alert_recipient must not have RLS (platform table, no tenant_id)';
    END IF;

    IF NOT (pg_catalog.has_table_privilege('cis_app', 'shared.alert_recipient', 'SELECT')
            AND pg_catalog.has_table_privilege('cis_app', 'shared.alert_recipient', 'INSERT')
            AND pg_catalog.has_table_privilege('cis_app', 'shared.alert_recipient', 'UPDATE')) THEN
        RAISE EXCEPTION 'migration 251: cis_app lacks SELECT / INSERT / UPDATE on shared.alert_recipient';
    END IF;
    IF pg_catalog.has_table_privilege('cis_app', 'shared.alert_recipient', 'DELETE, TRUNCATE') THEN
        RAISE EXCEPTION 'migration 251: cis_app may DELETE / TRUNCATE shared.alert_recipient (history must stay)';
    END IF;

    FOREACH r IN ARRAY ARRAY['aa_app_user', 'tripplanner', 'booking'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, 'shared.alert_recipient',
                   'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER') THEN
            RAISE EXCEPTION 'migration 251: % has a privilege on shared.alert_recipient', r;
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c, LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) x
                WHERE c.oid = 'shared.alert_recipient'::regclass AND x.grantee = 0) THEN
        RAISE EXCEPTION 'migration 251: PUBLIC has a privilege on shared.alert_recipient';
    END IF;
END $$;

-- ── 4. Register ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('251', now(), 'AA-913: shared.alert_recipient (alert mailboxes managed from the CIS admin page; SNS alerts topic + ops e-mail)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
