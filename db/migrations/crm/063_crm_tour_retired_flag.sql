-- migrate: expand
-- Migration crm-063: AA-1093 part 1 (S278 system audit gap M29) — the CRM learns that Adventure Asia stopped serving
-- an AA tour (a CIS 410 the hourly crm_catalog_sync stores as crm.aa_catalog_tour.served_state = 'retired') and flags
-- every agency trip that still uses it.
--
-- Owner: AA-Partner (api/migrations/063_crm_tour_retired_flag.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy DB Migrate applies (Migration Copy Guard). Key crm-063 = crm main max + 1; if main moves, renumber: file name,
-- this header, the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS and the tests that name it (git grep '063_'
-- and 'crm-063').
--
-- What (DM-7.1: root data standards Part B §7, the trip-scoped row, added with this key):
--   1. crm.tour_retired_flag (base template): one item of one agency trip that uses a retired AA tour, written by the
--      job crm_tour_retired_fanout (job:crm_tour_retired_fanout) once per transition of the tour:
--        kind open_option    an AA option on the tour in a live builder version (draft, published, sent);
--             held_line      an AA booking line on hold (or a hold request in flight);
--             quoted_line    an AA booking line quoted, not held;
--             confirmed_line a booked AA line: information only (the CRM never changes a booking line, an option or
--                            a proposal because of a retirement; Booking never cancels either).
--      state open -> cleared (CIS serves the tour again: cleared_at, cleared_key). The column is ``state``, not
--      ``status``: a status column needs crm.status_transition rows (crm-002 base template), an INSERT into an
--      existing table that would make this file contract; the job only moves a flag forward (one UPDATE ... WHERE
--      state = 'open') and a new retirement raises new rows.
--      raised_key = the transition (the tour's crm.aa_catalog_tour.state_changed_at), so the same transition run twice
--      raises one flag set (unique per agency, tour, transition and item), and one item has at most one open flag.
--      option_id / booking_line_id are snapshot references without a foreign key (the option or line follows its
--      own lifecycle; the trip page reads only the open flags of live items). The trip page badge, the builder
--      option badge and the pipeline filter "AA tour discontinued" read it. Ids, codes and times only: no personal
--      data, no money, no title.
--   2. Erasure without a replaced crm.erase_subject: the only foreign key to a subject cascades from crm.trip, a row
--      the trip and agency erases already delete (tests/integration/test_crm010_schema.py CASCADE_ERASED lists it).
--      Hold rule 4h: crm-054's crm.guard_held_travel_doc() (a direct delete, trash or move of a held trip's row is
--      refused, CRM10); clearing a flag stays allowed.
--   3. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles); crm_app keeps the default DML of crm-001; no reader
--      grant (AI context, insights and support never read it).
--
-- Class: expand (root ADR 0017 d3): one new table with its constraints, indexes, triggers, policy and comments; the
-- foreign keys are from the new table only; no change to an existing object, no DO block, no CREATE OR REPLACE. Not
-- re-runnable by itself (plain CREATE POLICY / TRIGGER); DB Migrate never applies a registered key again and the test
-- conftest skips it. Ships as a migration-only PR, applied before the code PR (MIG-4).
--
-- Rollback (a forward crm- file, after the code that writes it is reverted): DROP TABLE crm.tour_retired_flag.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

CREATE TABLE IF NOT EXISTS crm.tour_retired_flag (
    tour_retired_flag_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                         REFERENCES crm.tenant (tenant_id),
    trip_id              UUID NOT NULL,
    source_id            TEXT NOT NULL,
    kind                 TEXT NOT NULL,
    option_id            UUID,
    booking_line_id      UUID,
    state                TEXT NOT NULL DEFAULT 'open',
    raised_key           TEXT NOT NULL,
    raised_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    cleared_at           TIMESTAMPTZ,
    cleared_key          TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at           TIMESTAMPTZ,
    deleted_by           TEXT,
    purge_after          TIMESTAMPTZ,
    CONSTRAINT tour_retired_flag_tenant_id_uq UNIQUE (tenant_id, tour_retired_flag_id),
    CONSTRAINT tour_retired_flag_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT tour_retired_flag_kind_chk CHECK (
        kind IN ('open_option', 'held_line', 'quoted_line', 'confirmed_line')
    ),
    CONSTRAINT tour_retired_flag_item_chk CHECK (
        ((kind = 'open_option') = (option_id IS NOT NULL))
        AND ((kind <> 'open_option') = (booking_line_id IS NOT NULL))
    ),
    CONSTRAINT tour_retired_flag_values_chk CHECK (
        char_length(source_id) BETWEEN 1 AND 128 AND source_id !~ '[[:cntrl:]]'
        AND raised_key ~ '^[A-Za-z0-9:_.-]{1,64}$'
        AND (cleared_key IS NULL OR cleared_key ~ '^[A-Za-z0-9:_.-]{1,64}$')
    ),
    CONSTRAINT tour_retired_flag_state_chk CHECK (state IN ('open', 'cleared')),
    CONSTRAINT tour_retired_flag_cleared_chk CHECK (
        ((state = 'cleared') = (cleared_at IS NOT NULL))
        AND ((cleared_key IS NULL) OR (cleared_at IS NOT NULL))
        AND ((cleared_at IS NULL) OR (cleared_at >= raised_at - interval '1 day'))
    ),
    CONSTRAINT tour_retired_flag_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
-- One flag set per transition (the job run twice raises nothing new), one open flag per item.
CREATE UNIQUE INDEX IF NOT EXISTS tour_retired_flag_raised_uq
    ON crm.tour_retired_flag (tenant_id, source_id, raised_key, (COALESCE(option_id, booking_line_id)));
CREATE UNIQUE INDEX IF NOT EXISTS tour_retired_flag_open_uq
    ON crm.tour_retired_flag (tenant_id, (COALESCE(option_id, booking_line_id)))
    WHERE state = 'open' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS tour_retired_flag_trip_idx ON crm.tour_retired_flag (tenant_id, trip_id)
    WHERE state = 'open' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS tour_retired_flag_source_idx ON crm.tour_retired_flag (tenant_id, source_id)
    WHERE state = 'open' AND deleted_at IS NULL;
ALTER TABLE crm.tour_retired_flag ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.tour_retired_flag FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.tour_retired_flag
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER tour_retired_flag_set_updated_at
    BEFORE UPDATE ON crm.tour_retired_flag
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE TRIGGER tour_retired_flag_hold_guard
    BEFORE DELETE OR UPDATE ON crm.tour_retired_flag
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_travel_doc();
COMMENT ON TABLE crm.tour_retired_flag IS 'AA-1093 part 1 (crm-063, gap M29): one item of one agency trip that uses an AA tour Adventure Asia no longer serves (crm.aa_catalog_tour served_state retired, CIS 410). Raised by job:crm_tour_retired_fanout once per transition (raised_key; unique per tour, transition and item); kind open_option | held_line | quoted_line | confirmed_line (information only: the CRM never changes a line, option or proposal for it); state open -> cleared when CIS serves the tour again. The trip badge, the builder option badge and the pipeline filter read it. Ids, codes and times only. Cascades from the trip. No reader grant.';
COMMENT ON COLUMN crm.tour_retired_flag.source_id IS 'the AA tour (catalog.http.v1 source_id, crm.aa_catalog_tour.source_id with source_system cis)';
COMMENT ON COLUMN crm.tour_retired_flag.kind IS 'open_option (an AA option in a live builder version) | held_line | quoted_line | confirmed_line (an AA booking line by its state when the flag was raised)';
COMMENT ON COLUMN crm.tour_retired_flag.option_id IS 'the crm.option of an open_option flag (snapshot reference, no foreign key)';
COMMENT ON COLUMN crm.tour_retired_flag.booking_line_id IS 'the crm.booking_line of a line flag (snapshot reference, no foreign key)';
COMMENT ON COLUMN crm.tour_retired_flag.raised_key IS 'the retirement that raised the flag: retired:<state_changed_at in epoch microseconds>';
COMMENT ON COLUMN crm.tour_retired_flag.cleared_key IS 'the reinstatement that cleared it: reinstated:<state_changed_at in epoch microseconds>';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-063', now(), 'AA-1093 part 1: crm.tour_retired_flag (an agency trip item on a retired AA tour: open_option | held_line | quoted_line | confirmed_line, state open -> cleared); hold guard crm.guard_held_travel_doc (CRM10); cascades from crm.trip, no erase_subject change')
ON CONFLICT (version) DO NOTHING;

COMMIT;
