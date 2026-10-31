-- migrate: expand
--
-- Migration crm-030: AA-962 CRM-31 onboarding + import (design v3 §2.7 "Onboarding (Fix E2)", §11.5, R6, R43 in-app;
-- errata S247 §1 / §2: the Connections page, the controller settings and the one-time owner acknowledgement of the
-- shared responsibility) — the columns the onboarding checklist and the staged client import need.
--
-- Owner: AA-Partner (api/migrations/030_crm_onboarding_import.sql). AA-CIS-Infra Migration Sync copies it to
-- db/migrations/crm/ and Migration Apply applies it on Dev as crm_owner (root ADR 0017: an expand file needs no hand
-- step). Never run it from a laptop.
--
-- What (only ADDS; no constraint, policy, trigger, unique index or function change on an existing object):
--   1. crm.traveler.import_ref_bidx, crm.trip.import_ref_bidx, crm.note.import_ref_bidx (bytea, nullable): the blind
--      index (16-byte truncated HMAC under the agency's index key, app.vault) of the agency's own reference of the row
--      in the file it was imported from (client_ref, trip_ref, note_ref; for a note without a ref, a hash of its
--      subject and text). Re-running an import finds the row by it and adds nothing (card CRM-31 E test). Like every
--      blind index here there is no unique index (crm-003 rule: dedupe runs under per-agency advisory locks,
--      app.imports.apply); a partial non-unique index per table serves the lookup. A *_bidx column is never exported
--      (app.portability.tables) and goes with its row on erase (no crm.erase_subject change).
--      crm.traveler.import_ref_alias_bidx (bytea[], default empty): the other client_refs this client answers to, so
--      every ref an import accepted keeps resolving: the ref of a client merged into this one (app.travellers.merge),
--      the ref of a row that matched this client by e-mail / phone while it already had a ref, and the ref of a later
--      row of the same file sharing its e-mail / phone (app.imports.engine). A non-unique GIN index serves the lookup.
--   2. crm.tenant_settings onboarding and controller settings (errata S247 §1 CRM-31):
--      onboarding_later / onboarding_done (text[] of step codes, default empty: the optional steps the owner put on
--      "Later" and the steps the owner marked done by hand, app.onboarding.STEPS); privacy_notice_url (the agency's
--      privacy notice, linked on its forms), data_request_contact (where its clients send data requests),
--      consent_text (the agency's own consent wording; none = the CRM's default text); responsibility_ack_version /
--      _at / _member_id (the owner acknowledgement of the shared responsibility: the version of the text acknowledged,
--      when, by which owner; one audit event each time). Values are checked by app.onboarding (expand files add no
--      CHECK on an existing table; ADR 0017 d3).
--
-- Class: expand (ADR 0017 d3: nullable columns or columns with a constant default, non-unique partial indexes, column
-- comments). The tables are small (dump of 2026-10-30: traveler ~51 rows, trip ~59, note ~0, tenant_settings ~4), far
-- below the 100k-row lock-risk limit, so plain CREATE INDEX in the normal transaction. No DO block (opaque to the expand
-- lint): the runner checks the role. Readiness: api/app/db.py requires crm-030, so Deploy Dev's schema-gate waits for
-- this key.
-- Order: after crm-027 (AA-961). The lanes of S261 hold crm-028 / crm-029; this file names none of their objects.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS + ON CONFLICT DO NOTHING.
-- Undo (a later crm- file): DROP INDEX IF EXISTS crm.traveler_import_ref_idx, crm.trip_import_ref_idx,
-- crm.note_import_ref_idx, crm.traveler_import_ref_alias_idx; ALTER TABLE ... DROP COLUMN IF EXISTS for each column
-- below (code first).

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. Import references (blind indexes) ─────────────────────────────────────────────────────────
ALTER TABLE crm.traveler ADD COLUMN IF NOT EXISTS import_ref_bidx bytea;
ALTER TABLE crm.trip ADD COLUMN IF NOT EXISTS import_ref_bidx bytea;
ALTER TABLE crm.note ADD COLUMN IF NOT EXISTS import_ref_bidx bytea;
ALTER TABLE crm.traveler ADD COLUMN IF NOT EXISTS import_ref_alias_bidx bytea[] NOT NULL DEFAULT '{}';

CREATE INDEX IF NOT EXISTS traveler_import_ref_idx ON crm.traveler (tenant_id, import_ref_bidx)
    WHERE import_ref_bidx IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS trip_import_ref_idx ON crm.trip (tenant_id, import_ref_bidx)
    WHERE import_ref_bidx IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS note_import_ref_idx ON crm.note (tenant_id, import_ref_bidx)
    WHERE import_ref_bidx IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS traveler_import_ref_alias_idx ON crm.traveler USING gin (import_ref_alias_bidx)
    WHERE deleted_at IS NULL;

COMMENT ON COLUMN crm.traveler.import_ref_bidx IS 'pii:online_id; AA-962 (crm-030): blind index of the client_ref the agency gave this client in an import file (16-byte truncated HMAC, per-tenant key); a re-run of the import finds the client by it';
COMMENT ON COLUMN crm.traveler.import_ref_alias_bidx IS 'pii:online_id; AA-962 (crm-030): blind indexes of the other client_refs this client answers to (a client merged into it, an import row matched to it by e-mail or phone), so a re-run of an import still finds the client';
COMMENT ON COLUMN crm.trip.import_ref_bidx IS 'pii:travel; AA-962 (crm-030): blind index of the trip_ref of an imported trip (16-byte truncated HMAC, per-tenant key); a re-run of the import finds the trip by it';
COMMENT ON COLUMN crm.note.import_ref_bidx IS 'pii:free_text; AA-962 (crm-030): blind index of the note_ref of an imported note, or of a hash of its subject and text (16-byte truncated HMAC, per-tenant key); a re-run adds nothing';

-- ── 2. Onboarding and controller settings ────────────────────────────────────────────────────────
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS onboarding_later text[] NOT NULL DEFAULT '{}';
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS onboarding_done text[] NOT NULL DEFAULT '{}';
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS privacy_notice_url text;
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS data_request_contact text;
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS consent_text text;
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS responsibility_ack_version text;
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS responsibility_ack_at timestamptz;
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS responsibility_ack_member_id uuid;

COMMENT ON COLUMN crm.tenant_settings.onboarding_later IS 'AA-962 (crm-030): codes of the optional onboarding steps the owner put on "Later" (app.onboarding.STEPS)';
COMMENT ON COLUMN crm.tenant_settings.onboarding_done IS 'AA-962 (crm-030): codes of the onboarding steps the owner marked done by hand (the others are computed from the agency''s data)';
COMMENT ON COLUMN crm.tenant_settings.privacy_notice_url IS 'AA-962 (crm-030, errata S247 controller settings): https link to the agency''s privacy notice, shown on its forms';
COMMENT ON COLUMN crm.tenant_settings.data_request_contact IS 'pii:contact; AA-962 (crm-030, errata S247 controller settings): the agency''s address or link for data requests from its clients';
COMMENT ON COLUMN crm.tenant_settings.consent_text IS 'AA-962 (crm-030, errata S247 controller settings): the agency''s own consent wording on its forms; NULL = the CRM default text';
COMMENT ON COLUMN crm.tenant_settings.responsibility_ack_version IS 'AA-962 (crm-030, errata S247): version of the shared-responsibility text the owner acknowledged (app.onboarding.ACK_VERSION)';
COMMENT ON COLUMN crm.tenant_settings.responsibility_ack_at IS 'AA-962 (crm-030): when the owner acknowledged the shared responsibility';
COMMENT ON COLUMN crm.tenant_settings.responsibility_ack_member_id IS 'AA-962 (crm-030): the owner (crm.member) who acknowledged the shared responsibility';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-030', now(), 'AA-962 CRM-31 onboarding + import: import_ref_bidx on traveler / trip / note and traveler import_ref_alias_bidx (idempotent re-runs), tenant_settings onboarding steps, controller settings and the shared-responsibility acknowledgement')
ON CONFLICT (version) DO NOTHING;

COMMIT;
