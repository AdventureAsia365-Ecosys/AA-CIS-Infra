-- Migration 374: AA-1036 (R3, S268) — shared.tenant_addon_request: the add-on requests an agency sends from the agency
-- app ("Request add-on") and AA staff approve or decline in Tenant 360 › Subscription.
--
-- Why. Root ADR 0019 d7: "A tenant always lands on Content. Add-ons open per entitlement or after a 'Request' to the
-- account manager." Clarifications TL-7 step 4: the owner asks for the CRM, the account manager approves, CIS writes
-- the entitlement. Until now "Request add-on" in the agency app was a mailto: link (AA-Partner web/lib/apps.ts): nothing
-- was stored, staff saw nothing in the admin, and the tenant could not see that it had asked.
--
-- What.
--   1. shared.tenant_addon_request: one row per request of one tenant for one add-on product (crm | tripplanner).
--      status pending -> approved | declined, set once by a staff decision (decided_at, decided_by = the audit actor
--      admin:<id>, decision_note: the decline reason, required, or an optional approval note). An approval names the
--      plan it attached (plan_key) and the tenant_provision job that attached it (provision_job_id, a shared.job id;
--      no foreign key: shared.job rows are pruned by retention, the request outlives them). note: the tenant's own
--      optional message (at most 500 characters, pii:free_text). requested_by: the tenant actor (the Content studio
--      membership id of the person, or tenant:<id>), never an e-mail. A partial unique index allows at most one
--      pending request per tenant and product (a second "Request" answers the open one).
--   2. Grants. REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner first (the Dev default ACL of cis_owner in
--      shared, CIS 245, gives cis_app DML on every new table), then cis_app SELECT, INSERT, UPDATE, DELETE: the tenant
--      route (POST /v1/account/add-on-requests) and the staff routes (approve / decline) run on the main pool as
--      cis_app with the tenant id from the verified token or the path; DELETE for the AA-839 tenant erasure. Nothing for
--      aa_app_user or catalog_owner. No RLS, like shared.tenant_subscription and shared.tenant_entitlement_override
--      (the R1 control plane tables): read only by the CIS API, never by a tenant role (rls_catalogue_rules rule a).
--   3. Register 374.
--
-- Class: contract (root ADR 0017 d3; no '-- migrate:' directive). The content is additive (one new table, its
-- constraints and indexes, grants and comments; the foreign key only adds the internal RI triggers on shared.tenants;
-- no row in an existing table except the schema_versions registration), but it is not expand: the table has a
-- tenant_id column with RLS off on purpose (a CIS control-plane table, rule a allowlist) and the expand classify
-- refuses a new tenant_id table without ENABLE and FORCE ROW LEVEL SECURITY; it also needs REVOKE ALL (see 2), which
-- the expand lint refuses. Applied by hand on Dev (the CIS auto-apply waits behind 336) once every job table is idle.
-- Retention row (DM-7.1): root data standards Part B section 7, in the root PR of this change (merged before the Infra
-- copy).
--
-- Number. 373 is the highest on main (05/11/2026). Migration-only PR (MIG-4); the code PR that reads the table adds
-- 374 to REQUIRED_CIS_ABOVE_GAP (api/core/readiness.py), and its routes answer 503 while the table is missing.
--
-- Behaviour on apply: none. The table is empty; nothing reads it until the AA-1036 add-on request code ships.
--
-- Rollback (a new forward migration, after the code is reverted; destructive file, DRY RUN first):
--   DROP TABLE shared.tenant_addon_request;
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.tenant_addon_request (
    request_id        uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id         uuid        NOT NULL,
    product           text        NOT NULL,
    status            text        NOT NULL DEFAULT 'pending',
    note              text,
    requested_by      text        NOT NULL,
    requested_at      timestamptz NOT NULL DEFAULT now(),
    decided_at        timestamptz,
    decided_by        text,
    decision_note     text,
    plan_key          text,
    provision_job_id  uuid,
    CONSTRAINT tenant_addon_request_pkey PRIMARY KEY (request_id),
    CONSTRAINT tenant_addon_request_tenant_id_fkey FOREIGN KEY (tenant_id)
        REFERENCES shared.tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT tenant_addon_request_product_chk CHECK (product IN ('crm', 'tripplanner')),
    CONSTRAINT tenant_addon_request_status_chk CHECK (status IN ('pending', 'approved', 'declined')),
    CONSTRAINT tenant_addon_request_note_chk CHECK (note IS NULL OR char_length(note) BETWEEN 1 AND 500),
    CONSTRAINT tenant_addon_request_requested_by_chk CHECK (char_length(requested_by) BETWEEN 1 AND 64),
    CONSTRAINT tenant_addon_request_decision_chk CHECK (
        (status = 'pending' AND decided_at IS NULL AND decided_by IS NULL AND decision_note IS NULL)
        OR (status <> 'pending' AND decided_at IS NOT NULL AND decided_at >= requested_at
            AND char_length(decided_by) BETWEEN 1 AND 64
            AND (decision_note IS NULL OR char_length(decision_note) BETWEEN 1 AND 500))),
    CONSTRAINT tenant_addon_request_declined_chk CHECK (status <> 'declined' OR decision_note IS NOT NULL),
    CONSTRAINT tenant_addon_request_plan_chk CHECK (
        (status = 'approved') = (plan_key IS NOT NULL)
        AND (plan_key IS NULL OR plan_key ~ '^[a-z]+\.[a-z][a-z0-9_]*$')
        AND (provision_job_id IS NULL OR status = 'approved'))
);

CREATE UNIQUE INDEX IF NOT EXISTS tenant_addon_request_one_pending_key
    ON shared.tenant_addon_request (tenant_id, product) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS tenant_addon_request_tenant_idx
    ON shared.tenant_addon_request (tenant_id, requested_at DESC);
CREATE INDEX IF NOT EXISTS tenant_addon_request_pending_idx
    ON shared.tenant_addon_request (requested_at) WHERE status = 'pending';

COMMENT ON TABLE shared.tenant_addon_request IS
    'AA-1036 (CIS 374, root ADR 0019 d7): an agency''s request for an add-on (crm | tripplanner) sent from the agency '
    'app, and the AA staff decision. pending -> approved (the plan attached through the tenant_provision saga, '
    'provision_job_id) | declined (a reason). At most one pending request per tenant and product. Written by '
    'POST /v1/account/add-on-requests (Content studio owner) and the Tenant 360 approve / decline routes (admin role, '
    'audited tenant.addon_request_* in acp_shared.audit_log).';
COMMENT ON COLUMN shared.tenant_addon_request.note IS
    'pii:free_text; AA-1036 (374): the tenant''s optional message with the request (typed by the agency, may name a '
    'person).';
COMMENT ON COLUMN shared.tenant_addon_request.requested_by IS
    'AA-1036 (374): the tenant actor of the request: membership:<shared.tenant_members id> of the person, or '
    'tenant:<id>. Never an e-mail.';
COMMENT ON COLUMN shared.tenant_addon_request.decided_by IS
    'AA-1036 (374): the staff actor of the decision, admin:<admin_users.id> (the audit actor format).';
COMMENT ON COLUMN shared.tenant_addon_request.decision_note IS
    'pii:free_text; AA-1036 (374): the decline reason (required) or an optional approval note, typed by staff and shown '
    'to the tenant.';
COMMENT ON COLUMN shared.tenant_addon_request.provision_job_id IS
    'AA-1036 (374): the shared.job id of the tenant_provision attach job an approval enqueued (no foreign key: job '
    'rows are pruned by retention).';

-- ── Grants (REVOKE first: the Dev default ACL of cis_owner in shared, CIS 245) ─────────────────────────────────────
REVOKE ALL ON shared.tenant_addon_request FROM PUBLIC, cis_app, aa_app_user, catalog_owner;
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.tenant_addon_request TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('374', now(), 'AA-1036: shared.tenant_addon_request (agency add-on requests, root ADR 0019 d7)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
