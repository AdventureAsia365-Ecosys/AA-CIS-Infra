-- Migration crm-010: AA-942 (partner CRM, design v3 card CRM-14) — data lifecycle: trash windows per agency, the
-- delete block, archive at the dispatcher, legal holds, erasure and agency offboarding through one deletion function.
--
-- Owner: AA-Partner (api/migrations/010_crm_data_lifecycle.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-010 (crm-008 = AA-939, crm-009 = AA-938).
--
-- Why. Design v3 §3.5 "Trash, delete block, archive" (R21, R23, Fix B7), §3.6 retention, §4.10 (erasure through
-- crm.erase_subject() + crm_eraser, Fix B16), lane §3.3, §5.1 (tenant offboarding: delete every row, destroy the
-- DEKs), §5.8. Every user-deletable table has had its trash columns since its first migration (Fix B6); this file adds
-- the behaviour behind them.
--
-- What:
--   1. crm.tenant: status adds offboarding (members locked out, erase confirmed) and offboarded (erased, keys
--      destroyed; the row stays until the audit partitions drop, crm-007 offboarding path).
--   2. crm.tenant_settings: trash_days (1-30, default 7, Fix E3) and auto_archive_months (12-120, default 36, est.).
--   3. crm.traveler: archived_by; archive_reason from a fixed list (agent, client_request, auto_inactive, duplicate,
--      other); archived_at, archive_reason and archived_by set together.
--   4. crm.legal_hold (base template, ids and codes only): an active hold on the agency, a trip or a traveller
--      suspends every deletion that reaches it. A hold placed by a platform actor is released only by one
--      (crm.guard_legal_hold); crm_app never deletes a hold and never trashes one (state moves only: the trash columns
--      stay NULL, legal_hold_never_trashed_chk + the guard).
--      THE HOLD RULE — one rule, used by every deletion path (crm.erase_subject in every scope, crm.legal_hold_blocks
--      = the trash pre-check, the daily redaction and LLM-call purge, offboarding):
--        a. A trip is held when an active hold names it (scope trip), or names (scope traveler) a traveller on its
--           party (crm.trip_traveler): crm.hold_trip(trip).
--        b. A traveller is held when an active hold names them (scope traveler), or names (scope trip) a trip whose
--           party they are on: crm.hold_traveler(traveler). One level, not transitive.
--        c. An active agency hold (scope tenant) holds every trip and every traveller of the agency.
--        d. A row is held when its trip_id is a held trip or its traveler_id is a held traveller (a relation: either
--           end; a referrer link: the referred client's own row): crm.hold_row(trip, traveler).
--        e. An erase computes every row it would DELETE or UPDATE (its delete steps, trip_id / referrer_traveler_id
--           set to NULL, both rows of a relation) and refuses with CRM10, dry run too, when ANY of them is held. No row
--           is skipped, nothing is erased in part: crm.erase_held(scope, subject, token). The agency erase
--           (offboarding) refuses under any active hold of the agency.
--        f. crm.legal_hold_blocks(scope, subject) = crm.erase_held(scope, subject, NULL), "erase_subject would
--           refuse", so the trash pre-check and the purge always agree. Subject-less data (llm_call, placeholder_map):
--           the agency hold only.
--        g. crm.erase_subject and crm.lifecycle_purge_expired first take LOCK TABLE crm.legal_hold IN SHARE MODE: a
--           hold being placed or released (ROW EXCLUSIVE) waits until the erase commits, and an erase waits for a hold
--           being placed and then sees it. Placing and releasing are unchanged.
--   5. crm.trip_commitment (base template): the ledger the delete block reads (design §3.5): AA lines, invoices,
--      payments, signatures, commissions of a trip with their current line_status, written by the cards that own those
--      records (CRM-16/19/23/25/27) and by the Booking re-check of a restore. line_status mirrors the source system,
--      so it has no transitions table. crm.trip_delete_blockers(trip) returns has_money, has_signature,
--      has_commission, has_aa_line.
--   6. crm.dispatch_queue (base template, ids only): the single choke point of every outbound send (lane §2.8); the
--      crm_dispatch job gates each row at send time (archived, trashed, consent) — card R "an archived contact's
--      queued message is dropped".
--   7. crm.erasure_request (base template): a traveller erasure (done at once, the receipt) or an agency offboarding
--      (requested -> export_ready -> erasing -> erased); dry-run counts, export reference, receipt (codes, counts,
--      dates). crm_app never deletes one.
--   8. crm.lifecycle_run (append-only): one row per agency per lifecycle job run, counts only.
--   9. crm.erasable_append_only(): the append-only trigger of consent, trip_stage_history and llm_call, which
--      refuses UPDATE and TRUNCATE always and DELETE unless current_user = crm_owner AND app.erasing = 'on' (set only
--      by the two deletion functions below). audit_event, its partitions and audit_export_manifest keep
--      crm.reject_append_only_change(), unchanged: no path here deletes an audit row.
--  10. crm.erase_subject(scope, subject, profile_token, dry_run): SECURITY DEFINER, EXECUTE for crm_eraser only. Scopes
--      trip, traveler, task, note, document, relation, tenant. Refuses when the hold rule (4e) reaches any row it would
--      delete or update (SQLSTATE CRM10), a blocked trip (CRM11), a traveller on a live trip (CRM12), an unknown
--      subject (CRM13), a tenant that is not offboarding (CRM14), a profile token that does not belong to the traveller (CRM15); after a tenant erase, any row left in a
--      tenant table outside the keep list fails the whole run (CRM16). Returns {scope, dry_run, counts}.
--  11. crm.lifecycle_purge_expired(dry_run): SECURITY DEFINER, EXECUTE for crm_eraser only: llm_call rows older than
--      180 days (design §3.6; crm.llm_usage_daily keeps the rollup), skipped under an agency hold (4c). The crm-009
--      placeholder maps of those calls (24 h maps the hourly purge missed) go first, so placeholder_map_call_fk never
--      stops the purge; when crm-009 is not applied yet the step is skipped.
--  Every function here pins search_path = pg_catalog, pg_temp (pg_temp last: a temporary object never shadows a
--  catalogue name inside the definer functions) and names crm objects schema-qualified.
--   No NOLOGIN reader gets anything on the new tables; crm_eraser gets EXECUTE on the two deletion functions only.
--
-- Order: needs crm-007 (AA-940) only; it does not touch any object of crm-008 / crm-009, so DB Migrate may apply it
-- after either. Guard 0 refuses to run before crm-007 is registered.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); before AA-942
-- deploys nothing reads these objects.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-007 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-010: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-007') THEN
        RAISE EXCEPTION 'crm-010: crm-007 is not registered (the F5 audit, AA-940, lands first)';
    END IF;
    IF to_regclass('crm.document') IS NULL OR to_regclass('crm.audit_export_tenant') IS NULL THEN
        RAISE EXCEPTION 'crm-010: crm.document / crm.audit_export_tenant are missing (crm-006 / crm-007)';
    END IF;
END $$;

-- ── 1. Agency statuses ───────────────────────────────────────────────────────────────────────────
ALTER TABLE crm.tenant DROP CONSTRAINT IF EXISTS tenant_status_chk;
ALTER TABLE crm.tenant ADD CONSTRAINT tenant_status_chk
    CHECK (status IN ('active', 'locked', 'offboarding', 'offboarded'));
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('tenant', 'active', 'offboarding'),
    ('tenant', 'locked', 'offboarding'),
    ('tenant', 'offboarding', 'offboarded'),
    -- An erase the database refused (a hold placed after the confirmation, CRM16) deleted nothing (one transaction):
    -- the crm_offboard job, or a platform recovery, gives the agency back (docs/implementation-notes/AA-942.md).
    ('tenant', 'offboarding', 'active')
ON CONFLICT DO NOTHING;
COMMENT ON COLUMN crm.tenant.status IS 'active | locked (crm-002) | offboarding (AA-942: the owner confirmed the erase; no member context opens; back to active only when the erase was refused and deleted nothing) | offboarded (every row erased, keys destroyed; the row stays until the audit partitions drop, crm-007)';

-- ── 2. Trash window and auto-archive per agency ──────────────────────────────────────────────────
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS trash_days SMALLINT NOT NULL DEFAULT 7;
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS auto_archive_months SMALLINT NOT NULL DEFAULT 36;
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_trash_days_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_trash_days_chk CHECK (trash_days BETWEEN 1 AND 30);
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_auto_archive_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_auto_archive_chk
    CHECK (auto_archive_months BETWEEN 12 AND 120);
COMMENT ON COLUMN crm.tenant_settings.trash_days IS 'AA-942 (crm-010, design §3.5, Fix E3): days a deleted object stays restorable before crm_lifecycle purges it (default 7, 1-30)';
COMMENT ON COLUMN crm.tenant_settings.auto_archive_months IS 'AA-942 (crm-010, design §3.6, est.): months without trip activity after which crm_lifecycle archives a client (default 36, 12-120)';

-- ── 3. Archive columns of the traveller ──────────────────────────────────────────────────────────
ALTER TABLE crm.traveler ADD COLUMN IF NOT EXISTS archived_by TEXT;
ALTER TABLE crm.traveler DROP CONSTRAINT IF EXISTS traveler_archive_reason_chk;
ALTER TABLE crm.traveler ADD CONSTRAINT traveler_archive_reason_chk CHECK (
    (archived_at IS NULL) = (archive_reason IS NULL) AND (archived_at IS NULL) = (archived_by IS NULL)
    AND (archive_reason IS NULL OR archive_reason IN ('agent', 'client_request', 'auto_inactive', 'duplicate', 'other'))
    AND (archived_by IS NULL OR archived_by ~ '^[A-Za-z0-9:_-]{1,80}$')
);
CREATE INDEX IF NOT EXISTS traveler_archived_idx ON crm.traveler (tenant_id, archived_at)
    WHERE archived_at IS NOT NULL AND deleted_at IS NULL;
COMMENT ON COLUMN crm.traveler.archived_by IS 'AA-942 (crm-010): who archived the client (member:<id> or job:crm_lifecycle), set with archived_at and archive_reason';

-- ── 4. crm.legal_hold ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.legal_hold (
    hold_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                 REFERENCES crm.tenant (tenant_id),
    scope        TEXT NOT NULL,
    subject_id   UUID,
    reason_code  TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'active',
    placed_by    TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    released_at  TIMESTAMPTZ,
    released_by  TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ,
    deleted_by   TEXT,
    purge_after  TIMESTAMPTZ,
    CONSTRAINT legal_hold_scope_chk CHECK (
        scope IN ('tenant', 'trip', 'traveler') AND (scope = 'tenant') = (subject_id IS NULL)
    ),
    CONSTRAINT legal_hold_reason_chk CHECK (
        reason_code IN ('litigation', 'regulator_request', 'dispute', 'insurance_claim', 'other')
    ),
    CONSTRAINT legal_hold_status_chk CHECK (status IN ('active', 'released')),
    CONSTRAINT legal_hold_release_chk CHECK (
        (status = 'released') = (released_at IS NOT NULL) AND (released_at IS NULL) = (released_by IS NULL)
    ),
    CONSTRAINT legal_hold_actor_chk CHECK (
        placed_by ~ '^[A-Za-z0-9:_-]{1,80}$' AND (released_by IS NULL OR released_by ~ '^[A-Za-z0-9:_-]{1,80}$')
    ),
    CONSTRAINT legal_hold_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    ),
    -- A hold is never deleted, not even into the trash: it moves to released (design §3.5). The trash columns exist
    -- for the base template only (Fix B6) and stay NULL, so no update can hide an active hold.
    CONSTRAINT legal_hold_never_trashed_chk CHECK (deleted_at IS NULL AND deleted_by IS NULL AND purge_after IS NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS legal_hold_active_uq
    ON crm.legal_hold (tenant_id, scope, coalesce(subject_id, '00000000-0000-0000-0000-000000000000'::uuid))
    WHERE status = 'active';
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('legal_hold', 'active', 'released')
ON CONFLICT DO NOTHING;
REVOKE DELETE, TRUNCATE ON crm.legal_hold FROM crm_app;

CREATE OR REPLACE FUNCTION crm.guard_legal_hold() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
BEGIN
    IF (NEW.hold_id, NEW.tenant_id, NEW.scope, NEW.subject_id, NEW.reason_code, NEW.placed_by, NEW.created_at,
        NEW.created_by, NEW.deleted_at, NEW.deleted_by, NEW.purge_after)
       IS DISTINCT FROM (OLD.hold_id, OLD.tenant_id, OLD.scope, OLD.subject_id, OLD.reason_code, OLD.placed_by,
                         OLD.created_at, OLD.created_by, OLD.deleted_at, OLD.deleted_by, OLD.purge_after) THEN
        RAISE EXCEPTION 'crm: a legal hold only moves to released' USING ERRCODE = 'CRM17';
    END IF;
    IF OLD.status = 'released' AND (NEW.released_at, NEW.released_by) IS DISTINCT FROM (OLD.released_at, OLD.released_by) THEN
        RAISE EXCEPTION 'crm: a released legal hold does not change' USING ERRCODE = 'CRM17';
    END IF;
    IF (NEW.status IS DISTINCT FROM OLD.status OR NEW.released_at IS DISTINCT FROM OLD.released_at
        OR NEW.released_by IS DISTINCT FROM OLD.released_by)
       AND OLD.placed_by LIKE 'platform:%' AND actor NOT LIKE 'platform:%' THEN
        RAISE EXCEPTION 'crm: hold_platform_only (a hold AA placed is released by AA)' USING ERRCODE = 'CRM17';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_legal_hold() FROM PUBLIC;
CREATE OR REPLACE TRIGGER legal_hold_guard
    BEFORE UPDATE ON crm.legal_hold
    FOR EACH ROW EXECUTE FUNCTION crm.guard_legal_hold();
COMMENT ON TABLE crm.legal_hold IS 'AA-942 (crm-010): a legal hold of the agency (scope tenant), a trip or a traveller: while active, no deletion reaches the subject (trash purge, redaction, LLM-call purge, erasure; crm.legal_hold_blocks, crm.erase_subject), and any active hold suspends the agency offboarding. The hold rule (file header, item 4): a trip is held by a hold on it or on a traveller on its party, a traveller by a hold on them or on a trip whose party they are on (one level); a row is held when its trip or traveller is; an erase that would change any held row refuses (crm.erase_held). A hold placed by platform:* is released only by platform:* (crm.guard_legal_hold). Ids and codes only. crm_app never deletes or trashes a hold (legal_hold_never_trashed_chk).';


-- ── 5. crm.trip_commitment (the delete-block ledger) ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.trip_commitment (
    commitment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                  REFERENCES crm.tenant (tenant_id),
    trip_id       UUID NOT NULL,
    kind          TEXT NOT NULL,
    line_status   TEXT NOT NULL,
    source_ref    TEXT NOT NULL,
    checked_at    TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at    TIMESTAMPTZ,
    deleted_by    TEXT,
    purge_after   TIMESTAMPTZ,
    CONSTRAINT trip_commitment_trip_fk FOREIGN KEY (tenant_id, trip_id) REFERENCES crm.trip (tenant_id, trip_id),
    CONSTRAINT trip_commitment_source_uq UNIQUE (tenant_id, kind, source_ref),
    CONSTRAINT trip_commitment_kind_status_chk CHECK (
        (kind = 'aa_line' AND line_status IN ('requested', 'held', 'confirmed', 'released', 'expired', 'cancelled', 'declined'))
        OR (kind = 'invoice' AND line_status IN ('draft', 'open', 'payment_claimed', 'paid', 'paid_unfulfillable', 'void', 'expired'))
        OR (kind = 'payment' AND line_status IN ('pending', 'succeeded', 'failed', 'refunded'))
        OR (kind = 'signature' AND line_status IN ('pending', 'signed', 'declined', 'expired'))
        OR (kind = 'commission' AND line_status IN ('expected', 'claimed', 'received', 'cancelled'))
    ),
    CONSTRAINT trip_commitment_source_chk CHECK (source_ref ~ '^[A-Za-z0-9:_.-]{1,80}$'),
    CONSTRAINT trip_commitment_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS trip_commitment_trip_idx ON crm.trip_commitment (trip_id);
COMMENT ON TABLE crm.trip_commitment IS 'AA-942 (crm-010): what commits a trip (design §3.5 delete block): AA lines (Booking hold / booking id), invoices, payments, signature requests, commissions, each with the source''s current line_status. Written by the cards that own those records (CRM-16/19/23/25/27) and by the Booking re-check when a trip is restored. Read by crm.trip_delete_blockers. Ids and codes only.';
COMMENT ON COLUMN crm.trip_commitment.line_status IS 'the source system''s status (Booking feed, invoice, payment provider, e-sign): a mirror, so no transitions table; the kind decides the allowed codes';
COMMENT ON COLUMN crm.trip_commitment.source_ref IS 'the source id (Booking b2b hold or booking id, or the CRM row id of the invoice / payment / signature / commission); never personal data';

CREATE OR REPLACE FUNCTION crm.trip_delete_blockers(p_trip uuid) RETURNS text[]
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT coalesce(array_agg(DISTINCT x.code ORDER BY x.code), '{}'::text[])
      FROM (
          SELECT CASE
                     WHEN c.kind = 'invoice' AND c.line_status IN ('payment_claimed', 'paid', 'paid_unfulfillable') THEN 'has_money'
                     WHEN c.kind = 'payment' AND c.line_status IN ('succeeded', 'refunded') THEN 'has_money'
                     WHEN c.kind = 'signature' AND c.line_status = 'signed' THEN 'has_signature'
                     WHEN c.kind = 'commission' AND c.line_status IN ('claimed', 'received') THEN 'has_commission'
                     WHEN c.kind = 'aa_line' AND c.line_status IN ('held', 'confirmed') THEN 'has_aa_line'
                 END AS code
            FROM crm.trip_commitment c
           WHERE c.trip_id = p_trip AND c.deleted_at IS NULL
      ) x
     WHERE x.code IS NOT NULL;
$$;
REVOKE ALL ON FUNCTION crm.trip_delete_blockers(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.trip_delete_blockers(uuid) TO crm_app;
COMMENT ON FUNCTION crm.trip_delete_blockers(uuid) IS 'AA-942 (crm-010, design §3.5, Fix B7): why a trip cannot be deleted: has_money (paid / claimed invoice, succeeded or refunded payment), has_signature, has_commission (claimed / received), has_aa_line (held / confirmed). Empty = deletable (released, expired, cancelled, declined AA lines do not block). Invoker rights.';

-- ── 6. crm.dispatch_queue ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.dispatch_queue (
    dispatch_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                 REFERENCES crm.tenant (tenant_id),
    traveler_id  UUID NOT NULL,
    trip_id      UUID,
    channel      TEXT NOT NULL,
    purpose      TEXT NOT NULL,
    origin       TEXT NOT NULL,
    message_ref  UUID,
    not_before   TIMESTAMPTZ NOT NULL DEFAULT now(),
    status       TEXT NOT NULL DEFAULT 'queued',
    gate_result  TEXT,
    attempts     SMALLINT NOT NULL DEFAULT 0,
    decided_at   TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ,
    deleted_by   TEXT,
    purge_after  TIMESTAMPTZ,
    CONSTRAINT dispatch_queue_traveler_fk FOREIGN KEY (tenant_id, traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id),
    CONSTRAINT dispatch_queue_trip_fk FOREIGN KEY (tenant_id, trip_id) REFERENCES crm.trip (tenant_id, trip_id),
    CONSTRAINT dispatch_queue_channel_chk CHECK (channel IN ('email', 'sms', 'whatsapp')),
    CONSTRAINT dispatch_queue_purpose_chk CHECK (purpose IN ('transactional', 'marketing')),
    CONSTRAINT dispatch_queue_origin_chk CHECK (origin IN ('user_action', 'workflow', 'system')),
    CONSTRAINT dispatch_queue_status_chk CHECK (status IN ('queued', 'held', 'sent', 'dropped', 'cancelled')),
    CONSTRAINT dispatch_queue_gate_chk CHECK (
        (status = 'queued') = (gate_result IS NULL)
        AND (gate_result IS NULL OR gate_result IN (
            'sent', 'archived', 'traveler_trashed', 'trip_trashed', 'no_consent', 'no_sender', 'undone'
        ))
        AND (status = 'queued') = (decided_at IS NULL)
    ),
    CONSTRAINT dispatch_queue_attempts_chk CHECK (attempts BETWEEN 0 AND 100),
    CONSTRAINT dispatch_queue_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS dispatch_queue_traveler_idx ON crm.dispatch_queue (traveler_id);
CREATE INDEX IF NOT EXISTS dispatch_queue_due_idx ON crm.dispatch_queue (tenant_id, not_before) WHERE status = 'queued';
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('dispatch_queue', 'queued', 'sent'),
    ('dispatch_queue', 'queued', 'dropped'),
    ('dispatch_queue', 'queued', 'cancelled'),
    ('dispatch_queue', 'queued', 'held'),
    ('dispatch_queue', 'held', 'queued'),
    ('dispatch_queue', 'held', 'dropped'),
    ('dispatch_queue', 'held', 'cancelled')
ON CONFLICT DO NOTHING;
COMMENT ON TABLE crm.dispatch_queue IS 'AA-942 (crm-010, lane §2.8, design §3.5): every outbound message to a traveller passes here; the crm_dispatch job gates the row at send time: archived traveller -> dropped/archived (R23), trashed traveller or trip -> dropped/traveler_trashed or trip_trashed, marketing without a current marketing consent -> dropped/no_consent, no sender configured -> held/no_sender (CRM-17 re-queues). not_before = now + 10 s for a user action (Undo, Fix B8). Ids and codes only; the message itself lives with CRM-17 (message_ref).';

-- ── 6b. The hold rule (item 4a-4f) ───────────────────────────────────────────────────────────────
-- Defined after crm.dispatch_queue: a SQL function body is checked when it is created. Invoker rights everywhere: RLS
-- limits every read to the agency of app.tenant_id (crm_app for the pre-checks, crm_owner inside the definer
-- functions).

-- 4a + 4c: a held trip.
CREATE OR REPLACE FUNCTION crm.hold_trip(p_trip uuid) RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM crm.legal_hold h
         WHERE h.status = 'active'
           AND (h.scope = 'tenant'
                OR (p_trip IS NOT NULL AND h.scope = 'trip' AND h.subject_id = p_trip)
                OR (p_trip IS NOT NULL AND h.scope = 'traveler'
                    AND h.subject_id IN (SELECT tt.traveler_id FROM crm.trip_traveler tt WHERE tt.trip_id = p_trip)))
    );
$$;

-- 4b + 4c: a held traveller.
CREATE OR REPLACE FUNCTION crm.hold_traveler(p_traveler uuid) RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM crm.legal_hold h
         WHERE h.status = 'active'
           AND (h.scope = 'tenant'
                OR (p_traveler IS NOT NULL AND h.scope = 'traveler' AND h.subject_id = p_traveler)
                OR (p_traveler IS NOT NULL AND h.scope = 'trip'
                    AND h.subject_id IN (SELECT tt.trip_id FROM crm.trip_traveler tt WHERE tt.traveler_id = p_traveler)))
    );
$$;

-- 4d: a held row (NULL trip and traveller: the agency hold only).
CREATE OR REPLACE FUNCTION crm.hold_row(p_trip uuid, p_traveler uuid) RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT crm.hold_trip(p_trip) OR crm.hold_traveler(p_traveler);
$$;

-- 4e: does erase_subject(scope, subject, token) reach a held row? Every row the scope's steps DELETE or UPDATE, read
-- by the same predicates as those steps (keep the two in step: a new step needs its rows here).
CREATE OR REPLACE FUNCTION crm.erase_held(p_scope text, p_subject uuid, p_token uuid DEFAULT NULL) RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM crm.legal_hold h WHERE h.status = 'active') THEN
        RETURN false;  -- nothing is held in this agency
    END IF;
    IF p_scope = 'tenant' THEN
        RETURN true;  -- the agency erase reaches every subject: any active hold stops it
    END IF;
    IF p_subject IS NULL THEN
        RETURN crm.hold_row(NULL, NULL);
    END IF;
    IF p_scope = 'trip' THEN
        -- dispatch_queue, trip_commitment, document, note, task, trip_stage_history, trip_party, trip_traveler,
        -- form_submission (trip_id := NULL) and the trip: all carry trip_id = the trip (4d through hold_trip), and
        -- these name a traveller too.
        RETURN crm.hold_trip(p_subject) OR EXISTS (
            SELECT 1
              FROM (SELECT tt.traveler_id FROM crm.trip_traveler tt WHERE tt.trip_id = p_subject
                    UNION ALL
                    SELECT n.traveler_id FROM crm.note n WHERE n.trip_id = p_subject
                    UNION ALL
                    SELECT d.traveler_id FROM crm.document d WHERE d.trip_id = p_subject
                    UNION ALL
                    SELECT f.traveler_id FROM crm.form_submission f WHERE f.trip_id = p_subject
                    UNION ALL
                    SELECT q.traveler_id FROM crm.dispatch_queue q WHERE q.trip_id = p_subject) x
             WHERE x.traveler_id IS NOT NULL AND crm.hold_traveler(x.traveler_id));
    ELSIF p_scope = 'traveler' THEN
        -- dispatch_queue, traveler_health, document, note, trip_traveler, consent, form_submission and the traveller
        -- carry traveler_id = the traveller (4d through hold_traveler); trip_party / profile_history /
        -- traveler_profile are the traveller's own F2 rows (by token); these name a trip too; every relation from or
        -- to them (both rows); every client they referred (referrer_traveler_id := NULL rewrites that client's row).
        RETURN crm.hold_traveler(p_subject)
            OR EXISTS (
                SELECT 1
                  FROM (SELECT tt.trip_id FROM crm.trip_traveler tt WHERE tt.traveler_id = p_subject
                        UNION ALL
                        SELECT n.trip_id FROM crm.note n WHERE n.traveler_id = p_subject
                        UNION ALL
                        SELECT d.trip_id FROM crm.document d WHERE d.traveler_id = p_subject
                        UNION ALL
                        SELECT f.trip_id FROM crm.form_submission f WHERE f.traveler_id = p_subject
                        UNION ALL
                        SELECT q.trip_id FROM crm.dispatch_queue q WHERE q.traveler_id = p_subject
                        UNION ALL
                        SELECT p.trip_id FROM crm.trip_party p
                         WHERE p_token IS NOT NULL AND p.traveler_token = p_token) x
                 WHERE x.trip_id IS NOT NULL AND crm.hold_trip(x.trip_id))
            OR EXISTS (
                SELECT 1 FROM crm.traveler_relation rel
                 WHERE (rel.from_traveler_id = p_subject OR rel.to_traveler_id = p_subject)
                   AND (crm.hold_traveler(rel.from_traveler_id) OR crm.hold_traveler(rel.to_traveler_id)))
            OR EXISTS (
                SELECT 1 FROM crm.traveler t
                 WHERE t.referrer_traveler_id = p_subject AND crm.hold_traveler(t.traveler_id));
    ELSIF p_scope = 'task' THEN
        RETURN EXISTS (SELECT 1 FROM crm.task k WHERE k.task_id = p_subject AND crm.hold_trip(k.trip_id));
    ELSIF p_scope = 'note' THEN
        RETURN EXISTS (SELECT 1 FROM crm.note n WHERE n.note_id = p_subject AND crm.hold_row(n.trip_id, n.traveler_id));
    ELSIF p_scope = 'document' THEN
        RETURN EXISTS (SELECT 1 FROM crm.document d
                        WHERE d.document_id = p_subject AND crm.hold_row(d.trip_id, d.traveler_id));
    ELSIF p_scope = 'relation' THEN
        -- The row and its inverse (crm-006 mirrors the delete) have the same two ends.
        RETURN EXISTS (SELECT 1 FROM crm.traveler_relation rel
                        WHERE rel.relation_id = p_subject
                          AND (crm.hold_traveler(rel.from_traveler_id) OR crm.hold_traveler(rel.to_traveler_id)));
    END IF;
    RETURN crm.hold_row(NULL, NULL);  -- subject-less data (llm_call, placeholder_map): the agency hold only
END;
$$;

-- 4f: the pre-check every caller uses (trash, restore, redaction, offboarding) = "erase_subject would refuse".
CREATE OR REPLACE FUNCTION crm.legal_hold_blocks(p_scope text, p_subject uuid) RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT crm.erase_held(p_scope, p_subject, NULL);
$$;
DO $$
DECLARE
    f text;
BEGIN
    FOREACH f IN ARRAY ARRAY['crm.hold_trip(uuid)', 'crm.hold_traveler(uuid)', 'crm.hold_row(uuid,uuid)',
                             'crm.erase_held(text,uuid,uuid)', 'crm.legal_hold_blocks(text,uuid)'] LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO crm_app', f);
    END LOOP;
END $$;
COMMENT ON FUNCTION crm.hold_trip(uuid) IS 'AA-942 (crm-010, hold rule 4a/4c): the trip is held: an active hold names it, names a traveller on its party (trip_traveler), or is the agency hold. A NULL trip: the agency hold only. Invoker rights (RLS: one agency).';
COMMENT ON FUNCTION crm.hold_traveler(uuid) IS 'AA-942 (crm-010, hold rule 4b/4c): the traveller is held: an active hold names them, names a trip whose party they are on, or is the agency hold. One level, not transitive. A NULL traveller: the agency hold only. Invoker rights.';
COMMENT ON FUNCTION crm.hold_row(uuid, uuid) IS 'AA-942 (crm-010, hold rule 4d): a row is held when its trip is held or its traveller is held. Used by the daily redaction (form_submission) and the erase checks. Invoker rights.';
COMMENT ON FUNCTION crm.erase_held(text, uuid, uuid) IS 'AA-942 (crm-010, hold rule 4e): true when crm.erase_subject(scope, subject, token) would delete or update a held row (every step''s rows, both rows of a relation, the clients a traveller referred, the submissions a trip unlinks); scope tenant: any active hold of the agency. crm.erase_subject refuses with CRM10 on it, dry run too. Invoker rights.';
COMMENT ON FUNCTION crm.legal_hold_blocks(text, uuid) IS 'AA-942 (crm-010, hold rule 4f): crm.erase_held(scope, subject, NULL), i.e. crm.erase_subject would refuse with CRM10. The trash / restore pre-check, the offboarding checks (scope tenant: any active hold) and every other caller use it, so they agree with the purge. Subject-less data (llm_call): the agency hold only. Invoker rights (RLS: one agency).';

-- ── 7. crm.erasure_request ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.erasure_request (
    request_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                          REFERENCES crm.tenant (tenant_id),
    scope                 TEXT NOT NULL,
    subject_id            UUID NOT NULL,
    status                TEXT NOT NULL DEFAULT 'requested',
    requested_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    confirmed_by          TEXT,
    dry_run_counts        JSONB NOT NULL DEFAULT '{}',
    export_waived         BOOLEAN NOT NULL DEFAULT false,
    export_object_key     TEXT,
    export_sha256         TEXT,
    export_expires_at     TIMESTAMPTZ,
    export_downloaded_at  TIMESTAMPTZ,
    executed_at           TIMESTAMPTZ,
    keys_destroyed_at     TIMESTAMPTZ,
    backup_purge_by       DATE,
    receipt               JSONB NOT NULL DEFAULT '{}',
    failure_class         TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at            TIMESTAMPTZ,
    deleted_by            TEXT,
    purge_after           TIMESTAMPTZ,
    CONSTRAINT erasure_request_scope_chk CHECK (scope IN ('traveler', 'tenant') AND (scope <> 'tenant' OR subject_id = tenant_id)),
    CONSTRAINT erasure_request_status_chk CHECK (
        status IN ('requested', 'export_ready', 'erasing', 'erased', 'cancelled', 'failed')
    ),
    CONSTRAINT erasure_request_actor_chk CHECK (
        requested_by ~ '^[A-Za-z0-9:_-]{1,80}$' AND (confirmed_by IS NULL OR confirmed_by ~ '^[A-Za-z0-9:_-]{1,80}$')
    ),
    CONSTRAINT erasure_request_counts_chk CHECK (
        jsonb_typeof(dry_run_counts) = 'object' AND octet_length(dry_run_counts::text) <= 4096
        AND jsonb_typeof(receipt) = 'object' AND octet_length(receipt::text) <= 8192
    ),
    CONSTRAINT erasure_request_export_chk CHECK (
        (export_object_key IS NULL) = (export_sha256 IS NULL) AND (export_object_key IS NULL) = (export_expires_at IS NULL)
        AND (export_object_key IS NULL OR export_object_key ~ '^exports/tenants/[0-9a-f-]{36}/[0-9a-f-]{36}\.jsonl\.enc$')
        AND (export_sha256 IS NULL OR export_sha256 ~ '^[0-9a-f]{64}$')
        AND NOT (export_waived AND export_object_key IS NOT NULL)
    ),
    CONSTRAINT erasure_request_done_chk CHECK ((status = 'erased') = (executed_at IS NOT NULL)),
    CONSTRAINT erasure_request_failure_chk CHECK (failure_class IS NULL OR failure_class ~ '^[A-Za-z][A-Za-z0-9_]{0,63}$'),
    CONSTRAINT erasure_request_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS erasure_request_open_tenant_uq ON crm.erasure_request (tenant_id)
    WHERE scope = 'tenant' AND status IN ('requested', 'export_ready', 'erasing', 'failed');
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('erasure_request', 'requested', 'export_ready'),
    ('erasure_request', 'requested', 'erasing'),
    ('erasure_request', 'requested', 'cancelled'),
    ('erasure_request', 'export_ready', 'erasing'),
    ('erasure_request', 'export_ready', 'cancelled'),
    ('erasure_request', 'erasing', 'erased'),
    ('erasure_request', 'erasing', 'failed'),
    ('erasure_request', 'failed', 'erasing'),
    ('erasure_request', 'failed', 'cancelled')
ON CONFLICT DO NOTHING;
REVOKE DELETE, TRUNCATE ON crm.erasure_request FROM crm_app;
COMMENT ON TABLE crm.erasure_request IS 'AA-942 (crm-010, lane §2.11 / §5.8): a traveller erasure (erased at once, bypasses the trash) or an agency offboarding (requested -> export_ready -> erasing -> erased; cancelled before erasing). dry_run_counts and receipt hold table names, counts, codes and dates only. Kept after the agency erase (the receipt). crm_app never deletes one. CRM-35 (AA-967) adds the data-request log and the full export zip.';
COMMENT ON COLUMN crm.erasure_request.export_object_key IS 'the offboarding export in the documents bucket (exports/tenants/<tenant>/<request>.jsonl.enc, sealed with the agency export DEK; unreadable once the keys are destroyed, and the bucket expires it after 7 days)';
COMMENT ON COLUMN crm.erasure_request.backup_purge_by IS 'the date by which no backup or DEK copy holds the erased data (<= 30 days, V1)';

-- ── 8. crm.lifecycle_run (append-only) ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.lifecycle_run (
    run_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                REFERENCES crm.tenant (tenant_id),
    kind        TEXT NOT NULL,
    dry_run     BOOLEAN NOT NULL,
    counts      JSONB NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    CONSTRAINT lifecycle_run_kind_chk CHECK (kind ~ '^crm_[a-z0-9_]{1,40}$'),
    CONSTRAINT lifecycle_run_counts_chk CHECK (
        jsonb_typeof(counts) = 'object' AND octet_length(counts::text) <= 4096
        AND NOT jsonb_path_exists(counts, '$.* ? (@.type() != "number")')
    )
);
CREATE INDEX IF NOT EXISTS lifecycle_run_tenant_idx ON crm.lifecycle_run (tenant_id, created_at DESC);
CREATE OR REPLACE TRIGGER lifecycle_run_append_only
    BEFORE UPDATE OR DELETE ON crm.lifecycle_run
    FOR EACH ROW EXECUTE FUNCTION crm.reject_append_only_change();
CREATE OR REPLACE TRIGGER lifecycle_run_no_truncate
    BEFORE TRUNCATE ON crm.lifecycle_run
    FOR EACH STATEMENT EXECUTE FUNCTION crm.reject_append_only_change();
REVOKE UPDATE, DELETE, TRUNCATE ON crm.lifecycle_run FROM crm_app;
COMMENT ON TABLE crm.lifecycle_run IS 'AA-942 (crm-010): one row per agency per crm_lifecycle run (dry run or applied) with counts only (redacted submissions, purged LLM calls, purged trash per kind, auto-archived clients, skipped under a hold). Append-only; shown on Settings > Data and privacy. Kept after an offboarding.';

-- ── 9. The erasable append-only trigger ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.erasable_append_only() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    -- Only DELETE, only inside crm.erase_subject / crm.lifecycle_purge_expired (they run as crm_owner and set
    -- app.erasing for their own transaction). The runtime role can never be crm_owner.
    IF TG_OP = 'DELETE' AND current_user = 'crm_owner' AND current_setting('app.erasing', true) = 'on' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'crm: % is append-only (% refused)', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'insufficient_privilege';
END;
$$;
REVOKE ALL ON FUNCTION crm.erasable_append_only() FROM PUBLIC;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['consent', 'trip_stage_history', 'llm_call'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON crm.%I', t || '_append_only', t);
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON crm.%I', t || '_no_truncate', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON crm.%I '
                       'FOR EACH ROW EXECUTE FUNCTION crm.erasable_append_only()', t || '_append_only', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE TRUNCATE ON crm.%I '
                       'FOR EACH STATEMENT EXECUTE FUNCTION crm.erasable_append_only()', t || '_no_truncate', t);
    END LOOP;
END $$;

-- ── 10. crm.erase_subject ────────────────────────────────────────────────────────────────────────
-- One step: count (dry run), delete, or update the rows of one table that match a fixed predicate. Called only from
-- the two deletion functions (it is crm_owner's, nobody else may execute it); the table names and predicates are
-- literals of those functions, the subject and token are bound parameters ($1, $2).
CREATE OR REPLACE FUNCTION crm.erase_rows(p_table text, p_where text, p_subject uuid, p_token uuid,
                                          p_dry_run boolean, p_set text DEFAULT NULL) RETURNS bigint
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    n bigint;
BEGIN
    IF p_dry_run THEN
        EXECUTE format('SELECT count(*) FROM crm.%I WHERE %s', p_table, p_where) INTO n USING p_subject, p_token;
    ELSIF p_set IS NOT NULL THEN
        EXECUTE format('WITH d AS (UPDATE crm.%I SET %s WHERE %s RETURNING 1) SELECT count(*) FROM d',
                       p_table, p_set, p_where) INTO n USING p_subject, p_token;
    ELSE
        EXECUTE format('WITH d AS (DELETE FROM crm.%I WHERE %s RETURNING 1) SELECT count(*) FROM d',
                       p_table, p_where) INTO n USING p_subject, p_token;
    END IF;
    RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION crm.erase_rows(text, text, uuid, uuid, boolean, text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION crm.erase_subject(p_scope text, p_subject uuid, p_profile_token uuid DEFAULT NULL,
                                             p_dry_run boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_counts jsonb := '{}'::jsonb;
    v_blockers text[];
    v_status text;
    v_has_token boolean;
    v_step text[];
    v_left text[] := '{}';
    r record;
    -- Tables an agency erase keeps: the agency row (status offboarded), the destroyed key rows, the audit and its
    -- export registry and chain (crm-007: they leave with the partition drops / the archive), the erasure receipts,
    -- the lifecycle counts and the holds (ids and codes only).
    c_keep CONSTANT text[] := ARRAY['tenant', 'tenant_key', 'audit_event', 'audit_export_tenant',
                                    'audit_export_manifest', 'erasure_request', 'lifecycle_run', 'legal_hold'];
BEGIN
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'crm: erase_subject needs app.tenant_id' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_dry_run IS NULL OR p_subject IS NULL THEN
        RAISE EXCEPTION 'crm: erase_subject needs a subject and dry_run true or false'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_scope NOT IN ('trip', 'traveler', 'task', 'note', 'document', 'relation', 'tenant') THEN
        RAISE EXCEPTION 'crm: erase_subject scope % is unknown', p_scope USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Hold rule 4g: serialise with hold placement. SHARE conflicts with the ROW EXCLUSIVE of an INSERT / UPDATE on
    -- crm.legal_hold: a hold placed now waits until this transaction ends; a hold being placed makes this wait, then
    -- the check below (a new snapshot: this function is VOLATILE) sees it.
    LOCK TABLE crm.legal_hold IN SHARE MODE;

    -- The subject must exist in this agency (FORCE RLS: crm_owner sees app.tenant_id's rows only).
    IF p_scope = 'trip' THEN
        PERFORM 1 FROM crm.trip WHERE trip_id = p_subject;
    ELSIF p_scope = 'traveler' THEN
        SELECT profile_token_enc IS NOT NULL INTO v_has_token FROM crm.traveler WHERE traveler_id = p_subject;
    ELSIF p_scope = 'task' THEN
        PERFORM 1 FROM crm.task WHERE task_id = p_subject;
    ELSIF p_scope = 'note' THEN
        PERFORM 1 FROM crm.note WHERE note_id = p_subject;
    ELSIF p_scope = 'document' THEN
        PERFORM 1 FROM crm.document WHERE document_id = p_subject;
    ELSIF p_scope = 'relation' THEN
        PERFORM 1 FROM crm.traveler_relation WHERE relation_id = p_subject;
    ELSE
        IF p_subject <> v_tenant THEN
            RAISE EXCEPTION 'crm: subject_not_found (a tenant erase names the agency of app.tenant_id)'
                USING ERRCODE = 'CRM13';
        END IF;
        SELECT status INTO v_status FROM crm.tenant WHERE tenant_id = v_tenant;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (% %)', p_scope, p_subject USING ERRCODE = 'CRM13';
    END IF;

    -- Hold rule 4e: any held row among those this erase would delete or update refuses it, dry run included.
    IF crm.erase_held(p_scope, p_subject, p_profile_token) THEN
        RAISE EXCEPTION 'crm: legal_hold (an active legal hold reaches a row the erase of % % would change)',
            p_scope, p_subject USING ERRCODE = 'CRM10';
    END IF;

    IF p_scope = 'trip' THEN
        v_blockers := crm.trip_delete_blockers(p_subject);
        IF cardinality(v_blockers) > 0 THEN
            RAISE EXCEPTION 'crm: delete_blocked %', array_to_string(v_blockers, ',') USING ERRCODE = 'CRM11';
        END IF;
    ELSIF p_scope = 'traveler' THEN
        IF EXISTS (SELECT 1 FROM crm.trip_traveler tt JOIN crm.trip t ON t.trip_id = tt.trip_id
                    WHERE tt.traveler_id = p_subject AND t.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'crm: traveler_on_trip (delete or erase the client''s live trips first)'
                USING ERRCODE = 'CRM12';
        END IF;
        IF v_has_token AND p_profile_token IS NULL THEN
            RAISE EXCEPTION 'crm: profile_token_required' USING ERRCODE = 'CRM15';
        END IF;
        -- Consistency guard (the database cannot open the encrypted pointer; the caller decrypted it from this row,
        -- bound by its AAD): every party row of the token is the F2 twin of one of the traveller's own party rows
        -- (same trip, same role).
        IF p_profile_token IS NOT NULL AND EXISTS (
            SELECT 1 FROM crm.trip_party p
             WHERE p.traveler_token = p_profile_token
               AND NOT EXISTS (SELECT 1 FROM crm.trip_traveler tt
                                WHERE tt.trip_id = p.trip_id AND tt.traveler_id = p_subject AND tt.role = p.role)) THEN
            RAISE EXCEPTION 'crm: profile_token_mismatch' USING ERRCODE = 'CRM15';
        END IF;
    ELSIF p_scope = 'tenant' AND NOT p_dry_run AND v_status <> 'offboarding' THEN
        -- A dry run (the counts the owner sees before confirming) works on an active agency.
        RAISE EXCEPTION 'crm: tenant_not_offboarding (status %)', v_status USING ERRCODE = 'CRM14';
    END IF;

    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', 'on', true);
    END IF;

    IF p_scope = 'trip' THEN
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['dispatch_queue', 'trip_id = $1', ''],
            ['trip_commitment', 'trip_id = $1', ''],
            ['document', 'trip_id = $1', ''],
            ['note', 'trip_id = $1', ''],
            ['task', 'trip_id = $1', ''],
            ['trip_stage_history', 'trip_id = $1', ''],
            ['trip_party', 'trip_id = $1', ''],
            ['trip_traveler', 'trip_id = $1', ''],
            ['form_submission', 'trip_id = $1', 'trip_id = NULL'],
            ['trip', 'trip_id = $1', '']
        ] LOOP
            v_counts := v_counts || jsonb_build_object(
                v_step[1] || CASE WHEN v_step[3] <> '' THEN '_unlinked' ELSE '' END,
                crm.erase_rows(v_step[1], v_step[2], p_subject, NULL, p_dry_run, NULLIF(v_step[3], '')));
        END LOOP;
    ELSIF p_scope = 'traveler' THEN
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['dispatch_queue', 'traveler_id = $1', ''],
            ['traveler_health', 'traveler_id = $1', ''],
            ['document', 'traveler_id = $1', ''],
            ['note', 'traveler_id = $1', ''],
            ['traveler_relation', 'from_traveler_id = $1 OR to_traveler_id = $1', ''],
            ['trip_traveler', 'traveler_id = $1', ''],
            ['trip_party', 'traveler_token = $2', ''],
            ['profile_history', 'traveler_token = $2', ''],
            ['traveler_profile', 'traveler_token = $2', ''],
            ['consent', 'traveler_id = $1', ''],
            ['form_submission', 'traveler_id = $1', ''],
            ['traveler', 'referrer_traveler_id = $1', 'referrer_traveler_id = NULL'],
            ['traveler', 'traveler_id = $1', '']
        ] LOOP
            v_counts := v_counts || jsonb_build_object(
                v_step[1] || CASE WHEN v_step[3] <> '' THEN '_referrer_unlinked' ELSE '' END,
                crm.erase_rows(v_step[1], v_step[2], p_subject, p_profile_token, p_dry_run, NULLIF(v_step[3], '')));
        END LOOP;
    ELSIF p_scope IN ('task', 'note', 'document') THEN
        v_counts := jsonb_build_object(p_scope,
            crm.erase_rows(p_scope, p_scope || '_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'relation' THEN
        v_counts := jsonb_build_object('traveler_relation',
            crm.erase_rows('traveler_relation', 'relation_id = $1', p_subject, NULL, p_dry_run));
    ELSE
        -- The whole agency. Memberships are deleted as a platform action (crm-008 guard_member_write lets only an
        -- unscoped or platform context delete a member); the caller's actor is restored afterwards.
        PERFORM set_config('app.actor', 'platform:crm_offboarding', true);
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['dispatch_queue', ''], ['trip_commitment', ''], ['document', ''], ['traveler_health', ''],
            ['note', ''], ['task', ''], ['trip_stage_history', ''], ['trip_party', ''], ['trip_traveler', ''],
            ['traveler_relation', ''], ['consent', ''], ['form_submission', ''], ['profile_history', ''],
            ['traveler_profile', ''], ['placeholder_map', 'optional'], ['llm_call', ''], ['trip', ''],
            ['traveler', 'unlink'], ['traveler', ''], ['intake_form', ''], ['form_definition', ''],
            ['integration_credential', ''], ['tenant_settings', ''], ['member_invitation', 'optional'],
            ['owner_recovery_request', 'optional'], ['tenant_entitlement', 'optional'], ['member', '']
        ] LOOP
            CONTINUE WHEN v_step[2] = 'optional' AND to_regclass('crm.' || v_step[1]) IS NULL;
            IF v_step[2] = 'unlink' THEN
                v_counts := v_counts || jsonb_build_object('traveler_referrer_unlinked',
                    crm.erase_rows('traveler', 'referrer_traveler_id IS NOT NULL', p_subject, NULL, p_dry_run,
                                   'referrer_traveler_id = NULL'));
            ELSE
                v_counts := v_counts || jsonb_build_object(v_step[1],
                    crm.erase_rows(v_step[1], 'true', p_subject, NULL, p_dry_run));
            END IF;
        END LOOP;
        PERFORM set_config('app.actor', v_actor, true);
        -- Nothing of the agency may be left in a tenant table outside the keep list: a table added later that this
        -- function does not know fails the erase (rolled back) instead of keeping personal data silently.
        IF NOT p_dry_run THEN
            FOR r IN SELECT c.relname::text AS name
                       FROM pg_catalog.pg_class c
                       JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
                      WHERE c.relnamespace = 'crm'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
                        AND c.relname <> ALL (c_keep) AND c.relname NOT LIKE 'audit_event%'
                      ORDER BY 1 LOOP
                IF NOT (SELECT relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = ('crm.' || quote_ident(r.name))::regclass) THEN
                    v_left := v_left || r.name;  -- without FORCE RLS the owner would see every agency: refuse
                ELSE
                    EXECUTE format('SELECT EXISTS (SELECT 1 FROM crm.%I)', r.name) INTO v_has_token;
                    IF v_has_token THEN
                        v_left := v_left || r.name;
                    END IF;
                END IF;
            END LOOP;
            IF cardinality(v_left) > 0 THEN
                RAISE EXCEPTION 'crm: erase_incomplete (rows left in %)', array_to_string(v_left, ', ')
                    USING ERRCODE = 'CRM16';
            END IF;
        END IF;
    END IF;

    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', '', true);
    END IF;
    RETURN jsonb_build_object('scope', p_scope, 'dry_run', p_dry_run, 'counts', v_counts);
END;
$$;
REVOKE ALL ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) TO crm_eraser;
COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';

-- ── 11. crm.lifecycle_purge_expired ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.lifecycle_purge_expired(p_dry_run boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    n bigint;
    m bigint := 0;
BEGIN
    IF v_tenant IS NULL OR p_dry_run IS NULL THEN
        RAISE EXCEPTION 'crm: lifecycle_purge_expired needs app.tenant_id and dry_run'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    LOCK TABLE crm.legal_hold IN SHARE MODE;  -- hold rule 4g
    IF crm.hold_row(NULL, NULL) THEN  -- llm_call names no trip or traveller: the agency hold only (4c, 4f)
        RETURN jsonb_build_object('llm_call', 0, 'placeholder_map', 0, 'held', 1);
    END IF;
    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', 'on', true);
    END IF;
    -- crm-009 placeholder_map_call_fk: a map of a call this purge deletes goes first (a 24 h map the hourly
    -- crm_placeholder_purge has not removed yet). Skipped while crm-009 is not applied (crm-010 may land first).
    IF to_regclass('crm.placeholder_map') IS NOT NULL THEN
        m := crm.erase_rows('placeholder_map',
                            'llm_call_id IN (SELECT l.llm_call_id FROM crm.llm_call l '
                            'WHERE l.at < now() - interval ''180 days'')',
                            NULL, NULL, p_dry_run);
    END IF;
    n := crm.erase_rows('llm_call', 'at < now() - interval ''180 days''', NULL, NULL, p_dry_run);
    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', '', true);
    END IF;
    RETURN jsonb_build_object('llm_call', n, 'placeholder_map', m, 'held', 0);
END;
$$;
REVOKE ALL ON FUNCTION crm.lifecycle_purge_expired(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.lifecycle_purge_expired(boolean) TO crm_eraser;
COMMENT ON FUNCTION crm.lifecycle_purge_expired(boolean) IS 'AA-942 (crm-010, design §3.6): deletes the agency''s crm.llm_call rows older than 180 days (crm.llm_usage_daily keeps the rollup), and first the crm-009 placeholder maps of those calls; nothing under an agency legal hold. Dry run counts only. EXECUTE: crm_eraser only.';

-- ── RLS + triggers on the new tenant tables ──────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['legal_hold', 'trip_commitment', 'dispatch_queue', 'erasure_request', 'lifecycle_run'] LOOP
        EXECUTE format('ALTER TABLE crm.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE crm.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON crm.%I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON crm.%I '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)', t);
        IF t <> 'lifecycle_run' THEN
            EXECUTE format(
                'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON crm.%I FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at()',
                t || '_set_updated_at', t);
        END IF;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['legal_hold', 'dispatch_queue', 'erasure_request'] LOOP
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE OF status ON crm.%I '
            'FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition()', t || '_status_transition', t);
    END LOOP;
END $$;

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
BEGIN
    FOREACH t IN ARRAY ARRAY['crm.legal_hold', 'crm.trip_commitment', 'crm.dispatch_queue', 'crm.erasure_request',
                             'crm.lifecycle_run'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = t::regclass) THEN
            RAISE EXCEPTION 'crm-010: % must have ENABLE + FORCE row level security', t;
        END IF;
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, t, p) THEN
                    RAISE EXCEPTION 'crm-010: reader % may % on %', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['crm.legal_hold', 'crm.erasure_request', 'crm.lifecycle_run'] LOOP
        IF pg_catalog.has_table_privilege('crm_app', t, 'DELETE') OR pg_catalog.has_table_privilege('crm_app', t, 'TRUNCATE') THEN
            RAISE EXCEPTION 'crm-010: crm_app may delete from %', t;
        END IF;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['crm.consent', 'crm.trip_stage_history', 'crm.llm_call', 'crm.lifecycle_run'] LOOP
        IF pg_catalog.has_table_privilege('crm_app', t, 'UPDATE') OR pg_catalog.has_table_privilege('crm_app', t, 'DELETE') THEN
            RAISE EXCEPTION 'crm-010: % is append-only but crm_app may change it', t;
        END IF;
    END LOOP;
    -- The audit keeps its own unconditional trigger: no erasure path reaches it.
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_trigger g
                WHERE g.tgfoid = 'crm.erasable_append_only()'::regprocedure
                  AND g.tgrelid NOT IN ('crm.consent'::regclass, 'crm.trip_stage_history'::regclass,
                                        'crm.llm_call'::regclass)) THEN
        RAISE EXCEPTION 'crm-010: crm.erasable_append_only() may guard consent, trip_stage_history and llm_call only';
    END IF;
    IF (SELECT count(*) FROM pg_catalog.pg_trigger g
         WHERE g.tgrelid = 'crm.audit_event'::regclass AND NOT g.tgisinternal
           AND g.tgfoid = 'crm.reject_append_only_change()'::regprocedure) <> 2 THEN
        RAISE EXCEPTION 'crm-010: crm.audit_event lost its append-only triggers';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.erase_subject(text,uuid,uuid,boolean)', 'crm.lifecycle_purge_expired(boolean)'] LOOP
        IF pg_catalog.has_function_privilege('crm_app', t, 'EXECUTE')
           OR NOT pg_catalog.has_function_privilege('crm_eraser', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-010: % must be executable by crm_eraser only', t;
        END IF;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['crm.erase_rows(text,text,uuid,uuid,boolean,text)', 'crm.erasable_append_only()',
                             'crm.guard_legal_hold()', 'crm.legal_hold_blocks(text,uuid)', 'crm.hold_trip(uuid)',
                             'crm.hold_traveler(uuid)', 'crm.hold_row(uuid,uuid)', 'crm.erase_held(text,uuid,uuid)',
                             'crm.trip_delete_blockers(uuid)', 'crm.erase_subject(text,uuid,uuid,boolean)',
                             'crm.lifecycle_purge_expired(boolean)'] LOOP
        IF pg_catalog.has_function_privilege('public', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-010: % is executable by PUBLIC (SEC-4)', t;
        END IF;
    END LOOP;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_rows(text,text,uuid,uuid,boolean,text)', 'EXECUTE')
       OR pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_rows(text,text,uuid,uuid,boolean,text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-010: crm.erase_rows must be callable from the deletion functions only';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-010: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-010', now(), 'AA-942: data lifecycle (agency offboarding states, trash days, archive columns, legal_hold, trip_commitment, dispatch_queue, erasure_request, lifecycle_run, erase_subject, lifecycle_purge_expired)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
