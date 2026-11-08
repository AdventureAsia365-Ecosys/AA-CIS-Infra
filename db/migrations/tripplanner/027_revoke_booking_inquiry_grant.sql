-- Migration tp-027: AA-1046 / AA-1038 — role booking loses its access to schema tripplanner: SELECT on
-- tripplanner.v_inquiry_outbox and USAGE on the schema, both granted by tp-009 for the retired inquiry.submitted
-- contract.
--
-- Class: contract (root ADR 0017 / 0017a). The file has no directive line on purpose: it revokes cross-owner grants on
-- existing objects and changes an existing view's comment, which the expand classifier refuses. Merge order MIG-4: this
-- migration-only PR first, no code PR follows (nothing in TripPlanner reads or writes through role booking). On Dev,
-- AA-CIS-Infra Migration Apply runs it in contract mode once every job table is idle (byte-identical copy
-- db/migrations/tripplanner/027_revoke_booking_inquiry_grant.sql), as tp_owner, the live owner of schema tripplanner and
-- of the view since tp-013 (XD8; tp-013 rewrote the grantor of the tp-009 grants to tp_owner, so tp_owner's REVOKE
-- removes them). Never run it from a laptop.
--
-- Why. The inquiry.submitted contract is retired (AA-1046, root docs/contracts/README.md): AA-Booking dropped its B2C
-- intake (bk_inquiry_pull and bk_inquiry_process have no handler) and TripPlanner's send-to-advisor answers 410 and
-- writes no inquiry row. The tp-009 grants stayed live. The view's payload is tagged pii:contact, pii:name,
-- pii:free_text and pii:travel (tp-016), and the view is owned by tp_owner, which bypasses the tp-025 shadow row-level
-- security (ENABLE, not FORCE), so role booking could read every tenant's traveller data. A grant with no consumer is
-- removed (data standards DM-8: least privilege).
--
-- What booking held in schema tripplanner before this file (AA-Ecosys docs/architecture/db-schema-reference.md, dump of
-- 2026-11-07, and AA-CIS-Infra db/owners.yaml tripplanner.consumer_grants): USAGE on the schema and SELECT on
-- v_inquiry_outbox, nothing else. lead.submitted.v1 goes to the tenant's CRM over HTTP, a webhook or an e-mail (no
-- grant, ADR 0008a); price.from.v1 is the opposite direction (role tripplanner reads booking.v_from_prices, bk-039). So
-- the schema USAGE goes too.
--
-- What:
--   1. REVOKE ALL on tripplanner.v_inquiry_outbox FROM booking (SELECT is the only privilege it held; ALL also clears
--      anything granted by hand);
--   2. REVOKE USAGE ON SCHEMA tripplanner FROM booking;
--   3. the view's comment says it has no consumer;
--   4. guards (RAISE, the transaction rolls back; each privilege function sits in a CASE on relkind, so the planner never
--      calls it on a row of another kind, e.g. a pg_toast relation): booking holds no privilege on the schema, on any relation or
--      sequence of it, and no default privilege FOR ROLE tp_owner IN SCHEMA tripplanner names it; the other readers
--      keep theirs (cis_app: USAGE + SELECT on v_ops_traffic_daily; tripplanner: SELECT on v_inquiry_outbox);
--   5. register tp-027.
--
-- Kept on purpose: the view tripplanner.v_inquiry_outbox itself and its rows. Dropping it is destructive (DRY RUN
-- first, `-- migrate: destructive`) and belongs with the removal of TripPlanner's leftover hand-off code; after this
-- file only the owner and the runtime role tripplanner can read it.
--
-- Locks: ACCESS EXCLUSIVE on the view (catalog only, no table lock on tripplanner.outbox) for a few milliseconds.
-- Re-runnable (test_replay_twice_pg.py): REVOKE of a privilege not held is a no-op, the same comment,
-- ON CONFLICT DO NOTHING. A full replay re-runs tp-009 (GRANT) before this file, which revokes again.
-- Undo: a later tp- file (contract) with the two GRANTs of tp-009 and the owners.yaml consumer grant back, only for a
-- new reviewed contract.

BEGIN;

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-027: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
    IF to_regrole('booking') IS NULL THEN
        RAISE EXCEPTION 'tp-027: role booking is missing (AA-Booking bk-001)';
    END IF;
END $$;

-- 1. and 2. the revokes

REVOKE ALL ON tripplanner.v_inquiry_outbox FROM booking;
REVOKE USAGE ON SCHEMA tripplanner FROM booking;

-- 3. comment

COMMENT ON VIEW tripplanner.v_inquiry_outbox IS
    'tp-008 (AA-676): the inquiry.submitted outbox rows. The contract is retired (AA-1046) and tp-027 revoked the '
    'AA-Booking read: no consumer. Kept until a destructive drop with the leftover hand-off code.';

-- 4. guards

DO $$
DECLARE
    bad text;
BEGIN
    IF pg_catalog.has_schema_privilege('booking', 'tripplanner', 'USAGE')
       OR pg_catalog.has_schema_privilege('booking', 'tripplanner', 'CREATE') THEN
        RAISE EXCEPTION 'tp-027: role booking still holds a privilege on schema tripplanner';
    END IF;
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'tripplanner'
       AND CASE WHEN c.relkind IN ('r', 'p', 'v', 'm', 'f')
                THEN pg_catalog.has_table_privilege('booking', c.oid,
                                                    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
                ELSE false END;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'tp-027: role booking still holds a privilege on tripplanner relation(s): %', bad;
    END IF;
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'tripplanner'
       AND CASE WHEN c.relkind = 'S'
                THEN pg_catalog.has_sequence_privilege('booking', c.oid, 'USAGE, SELECT, UPDATE')
                ELSE false END;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'tp-027: role booking still holds a privilege on tripplanner sequence(s): %', bad;
    END IF;
    IF EXISTS (SELECT 1
                 FROM pg_default_acl d
                 JOIN pg_namespace n ON n.oid = d.defaclnamespace
                CROSS JOIN LATERAL aclexplode(d.defaclacl) a
                WHERE n.nspname = 'tripplanner'
                  AND a.grantee = 'booking'::regrole) THEN
        RAISE EXCEPTION 'tp-027: a default privilege in schema tripplanner still names role booking';
    END IF;
    -- The other readers are untouched.
    IF to_regrole('cis_app') IS NOT NULL
       AND to_regclass('tripplanner.v_ops_traffic_daily') IS NOT NULL
       AND NOT (pg_catalog.has_schema_privilege('cis_app', 'tripplanner', 'USAGE')
                AND pg_catalog.has_table_privilege('cis_app', 'tripplanner.v_ops_traffic_daily', 'SELECT')) THEN
        RAISE EXCEPTION 'tp-027: role cis_app lost its read of tripplanner.v_ops_traffic_daily (tp-015)';
    END IF;
    IF NOT pg_catalog.has_table_privilege('tripplanner', 'tripplanner.v_inquiry_outbox', 'SELECT') THEN
        RAISE EXCEPTION 'tp-027: role tripplanner lost SELECT on tripplanner.v_inquiry_outbox';
    END IF;
END $$;

-- 5. registration

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-027', now(), 'AA-1046: revoke role booking SELECT on tripplanner.v_inquiry_outbox and USAGE on schema '
                         'tripplanner (tp-009 grants of the retired inquiry.submitted contract)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
