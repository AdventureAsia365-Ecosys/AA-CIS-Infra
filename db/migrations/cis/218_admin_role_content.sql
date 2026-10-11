-- Migration 218: AA-656 — 'content' staff role in shared.admin_role.
--
-- The content team used to log in with a shared CONTENT_PASSWORD checked by the Next.js BFF; the
-- session had no JWT, only a client-writable cis_role=content cookie. Content staff now get rows in
-- shared.admin_users with role 'content' and log in through /auth/admin-login like admin/reviewer,
-- so every staff session carries a signed, verifiable token (frontend/lib/rbac.ts holds the matrix).
--
-- ADD VALUE is allowed inside a transaction on Postgres 12+; the new value is not used in this
-- transaction. Accounts are created separately (no password hashes in git).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate
-- workflow); keep the two identical.
BEGIN;

ALTER TYPE shared.admin_role ADD VALUE IF NOT EXISTS 'content';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('218', now(), 'AA-656: shared.admin_role gains content (staff JWT for the content team)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
