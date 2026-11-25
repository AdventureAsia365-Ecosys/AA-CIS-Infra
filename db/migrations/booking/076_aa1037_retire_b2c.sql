-- Migration bk-076: AA-1037 — retire the B2C half of AA-Booking (root ADR 0019, B2B-only model): drop the customer
-- tables and the customer invoice / payment tables (their rows archived first under the accounting exception), drop
-- trip_cases.customer_id, and limit new trip cases to b2b. The b2c trip cases and every row about them stay.
-- migrate: destructive
--
-- AA-1046 R4b part 1 (S271; draft and DRY RUN of AA-1037 S270, root docs/audits/2026-11-05-S270-aa1037-b2c-drop-dryrun/).
-- AA-1061 (R4c, S294): rebuilt on main and renumbered to the next free key, bk-076 (the finance file took bk-045). The
-- files bk-045 to bk-075 leave every object this file checks, rewrites or drops as bk-030 / bk-028 / bk-025 / bk-020
-- left it (implementation notes AA-1061, "Changed"), so the body is the S271 one with the key changed.
-- Merged as a migration-only PR (MIG-4, lesson 164) only after, in this order:
--   1. the readers outside Booking are gone: TripPlanner My Payments, the CIS data coverage row bk.customers, the CIS
--      KPI rows on these tables, the CIS erasure checklist line, the AA-CIS-Infra isolation probe cells on
--      booking.customers and booking.v_ops_inquiry_inbox and its owner-only exemption for booking.retired_b2c_record
--      (else runtime_grants.booking goes red on this apply), the Infra DM-6.5 consent script, the root contract
--      booking.customer.v1, the root DSAR runbook, consent query page and UAT scenarios BK-08 / BK-10 (all AA-1046
--      S271);
--   2. the Booking build that no longer reads or writes them is deployed (AA-1046 S271 code PR: the B2C routers and
--      services, app/inquiry/intake.py and its bk_inquiry_pull job, the staff admin pages; no trip_cases.customer_id);
--   3. a fresh DRY RUN (root docs/audits/2026-11-05-S270-aa1037-b2c-drop-dryrun/scripts/aa1037_b2c_dry_run.py) at
--      least 30 days after the last B2C write printed DRYRUN_PINS: it is pasted into `pins` below (every null
--      replaced) IN THIS PR, BEFORE it merges (a merged file is copied to AA-CIS-Infra and never edited again), and
--      the tech lead approved the drop with those numbers (destructive-ops.md step 4). With the nulls left in, the
--      apply on a database that still holds a B2C row refuses ("has no DRY RUN pin"): fail closed.
-- The `destructive` header makes DB Migrate take a manual RDS snapshot first and refuse to apply without it (MIG-12);
-- Migration Apply never auto-applies it (ADR 0017a). The snapshot is the rollback copy (aa:retain-until = apply + 180
-- days, id recorded in the dead-table registry); it is NOT the retention copy of anything (see "Data rules").
--
-- Owner: AA-Booking (key bk-076). Runs as bk_owner (live owner of schema booking since bk-014).
--
-- Data rules (DM-7.1 retention table, DM-6.7, DM-7.3 of root docs/architecture/data-standards/02-data-management.md):
--   * Rows under the accounting exception (DM-7.1: invoices, invoice_items, payment_schedule, payments, supplier
--     bills / bill lines / payouts, ops_files of kinds payment_evidence / supplier_bill / payout_evidence and their S3
--     objects) are never deleted here. The four customer money tables are copied row for row (to_jsonb, every column)
--     into the new append-only table booking.retired_b2c_record, with retain_until = 31 December of (year of the
--     row's last write, Vietnam time) + 10, and the copy is checked equal before the tables drop. The supplier money
--     rows and every ops_files row stay where they are, untouched. booking.retired_b2c_record has its own DM-7.1 row
--     (root PR of AA-1037 S270); DM-7.3's S3 Parquet archive does not exist yet (N4), so the archive is in the
--     database, owner-only, and moves to S3 with the other accounting rows when N4 lands.
--   * booking.audit_logs ("kept (append-only)"), booking.trip_case_status_history ("kept (audit evidence)"),
--     booking.notifications and booking.inbox_events rows (proposed / payload-only windows: nothing deleted until
--     approved) are not touched: no b2c trip case, version, supplier booking, check or status row is deleted, so
--     nothing cascades. Their CHECKs keep the 'customer' / 'payment' values the kept rows use.
--   * Dropped without an archive: booking.customers, customer_identities (follows its customer), customer_otps and
--     customer_sessions (credentials; DM-7.1 already plans to drop both tables), media_files (customer profile
--     pictures; 0 inserts on Dev). These are the personal master and credentials of a retired channel with no
--     remaining purpose (ADR 0019); the accounting copy of the person (the invoice bill_to snapshot) is archived above.
--
-- What, in this order (one transaction):
--   0. Guards (RAISE, nothing changes): running as bk_owner; no inquiry intake job (bk_inquiry_pull /
--      bk_inquiry_process) queued or running; NO B2C ROW WRITTEN IN THE LAST 30 DAYS (the block between
--      "last-write:begin" and "last-write:end", byte-equal to the DRY RUN's LAST_WRITE_SQL: customers, identities,
--      OTPs (created / used), sessions, media, the four invoice tables, b2c trip cases and their versions, supplier
--      bookings / bills / bill lines / payouts of b2c cases, their operations files (created / updated / removed),
--      inquiry inbox rows); every dropped table still holds exactly the rows the DRY RUN pinned (row count AND an md5
--      over the non-personal columns of every row: key, write times, codes; an app UPDATE moves a write time and a
--      delete-plus-insert moves the id, so either after the DRY RUN also refuses; checked only when a
--      dropped table has a row: an empty schema, as in the Integration Tests' replay, loses nothing); no view or
--      foreign key outside this file depends on a dropped object.
--   1. Archive: booking.retired_b2c_record, then the four customer money tables copied into it and checked.
--   2. Views rewritten without B2C (same columns, grants kept): v_trip_check_board (payment_verified is NULL on every
--      case: no customer invoice any more), v_ops_data_totals (the 'customers' metric goes; CIS data coverage stops
--      reading it first).
--   3. Functions rewritten without B2C: trip_cases_post_sale_guard (every money status refused, as for b2b before),
--      ops_files_guard (no new customer payment evidence; the kept one can no longer change).
--   4. Drop the B2C views, then the invoice / payment tables (their triggers and guard functions go with them).
--   5. trip_cases: drop customer_id; trip_cases_channel_chk lets only b2b cases in from now on (the kept b2c cases,
--      created before the apply, still pass it).
--   6. Drop the customer tables, media_files and the B2C sequences.
--   7. Config: the invoice ops_transitions edges and the money edges of a trip case go (reference data, DM-7.1).
--   8. Register bk-076.
--
-- Kept on purpose: the b2c trip cases and everything about them (see "Data rules"); booking.inbox_events and
-- inbox_cursor (the CIS catalog lifecycle feed, source 'cis', uses them; the inquiry rows stay under DM-6.6),
-- invoice_sequence (AAS / AAT agency invoice numbers), the settings rows (payment_instructions is read by agency
-- billing; the B2C-only keys deposit_due_days, balance_due_days_before_start, payment_due_soon_days,
-- payment_overdue_reminder_days and invoice_issuer are left for a later cleanup with their code), the trip case
-- statuses invoice_sent / payment_pending / paid in trip_cases_status_chk (kept b2c cases may hold them; unreachable
-- once the edges are gone).
-- Outside this file: the S3 objects of media_files rows (if any; 0 on Dev) are purged after the apply. The ops-docs
-- objects of ops_files rows stay (their rows stay). TripPlanner's own customer tables are a TripPlanner migration.
--
-- Locks: SHARE ROW EXCLUSIVE on the nine dropped tables and trip_cases from the first statement (no write lands
-- between the guards and the drops), then ACCESS EXCLUSIVE on every dropped table and view and on trip_cases (DROP
-- COLUMN, constraint swap) for the length of the transaction. Apply while the job tables are idle (DB Migrate waits for that) and Booking traffic is
-- low; lock_timeout 5s, retry on a timeout.
-- Undo: none in SQL. Restore from the pre-apply snapshot (db-migrate-bk-076-<run>-<attempt>); the archived money
-- rows can also be read back from booking.retired_b2c_record.record.
-- Re-runnable: every step reads to_regclass / IF EXISTS; after a full apply the guards find nothing and the file
-- only re-registers (ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
-- The pin hashes read the text of timestamps and numbers: pin the settings that shape it (the DRY RUN sets the same).
SET LOCAL TimeZone = 'UTC';
SET LOCAL DateStyle = 'ISO, YMD';
SET LOCAL IntervalStyle = 'postgres';
SET LOCAL extra_float_digits = 1;
SET LOCAL bytea_output = 'hex';

-- Hold the checked tables still from the guards to the drops: SHARE ROW EXCLUSIVE lets other sessions read them but
-- makes every INSERT / UPDATE / DELETE wait until COMMIT (or this file fail on lock_timeout first), so the pins, the
-- 30-day guard and the archive check still describe the rows at DROP time and no row committed in between is dropped
-- unarchived. trip_cases is in the set because step 5 alters it anyway. Skipped on a re-run (the tables are gone)
-- and, like every guard, when not running as bk_owner (the guard block then refuses).
-- lock:begin
DO $$
BEGIN
    IF current_user = 'bk_owner' AND to_regclass('booking.customers') IS NOT NULL
       AND to_regclass('booking.invoices') IS NOT NULL THEN
        LOCK TABLE booking.customers, booking.customer_identities, booking.customer_otps, booking.customer_sessions,
                   booking.media_files, booking.invoices, booking.invoice_items, booking.payment_schedule,
                   booking.payments, booking.trip_cases
            IN SHARE ROW EXCLUSIVE MODE;
    END IF;
END $$;
-- lock:end

-- ── 0. Guards ────────────────────────────────────────────────────────────────

DO $$
DECLARE
    -- The DRY RUN's DRYRUN_PINS ({"n": rows, "md5": hash of the pinned columns} per dropped table); null = not
    -- filled in.
    pins jsonb := '{"customers": null, "customer_identities": null, "customer_otps": null, "customer_sessions": null,
                    "media_files": null, "invoices": null, "invoice_items": null, "payment_schedule": null,
                    "payments": null}';
    -- pin-tables:begin
    pin_tables text[] := ARRAY['customers', 'customer_identities', 'customer_otps', 'customer_sessions', 'media_files',
                               'invoices', 'invoice_items', 'payment_schedule', 'payments'];
    -- pin-tables:end
    -- The pinned columns of each table (key, write times, status-like codes; never a personal column), byte-equal to
    -- the DRY RUN's PIN_COLUMNS: the DRY RUN must pass the pilot PII guard (AA-969), which refuses whole-row reads.
    -- pin-columns:begin
    pin_columns jsonb := '{
        "customers": "t.id, t.code, t.source, t.verified, t.is_blocked, t.created_at, t.updated_at, t.deleted_at",
        "customer_identities": "t.customer_id, t.created_at",
        "customer_otps": "t.id, t.customer_id, t.channel, t.attempts, t.created_at, t.expires_at, t.used_at",
        "customer_sessions": "t.id, t.customer_id, t.created_at, t.expires_at, t.revoked_at",
        "media_files": "t.id, t.content_type, t.created_at, t.deleted_at",
        "invoices": "t.id, t.invoice_number, t.trip_case_id, t.version_id, t.document_type, t.status, t.currency, t.total_amount, t.issued_at, t.cancelled_at, t.created_at, t.updated_at, t.deleted_at",
        "invoice_items": "t.id, t.invoice_id, t.position, t.kind, t.amount, t.created_at, t.updated_at",
        "payment_schedule": "t.id, t.invoice_id, t.seq, t.kind, t.amount, t.due_date, t.created_at, t.updated_at",
        "payments": "t.id, t.ref, t.invoice_id, t.kind, t.amount, t.currency, t.method, t.recorded_at, t.verified_at, t.voided_at, t.created_at, t.updated_at"
    }';
    -- pin-columns:end
    k        text;
    n        bigint;
    h        text;
    total    bigint := 0;
    actual   jsonb := '{}';
    last_at  timestamptz;
    deps     text;
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-076: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.customers') IS NULL AND to_regclass('booking.invoices') IS NULL THEN
        RETURN;                                                     -- already applied (re-run)
    END IF;
    IF to_regclass('booking.customers') IS NULL OR to_regclass('booking.invoices') IS NULL THEN
        RAISE EXCEPTION 'bk-076: half-applied state (customers %, invoices %): restore from the snapshot',
            to_regclass('booking.customers'), to_regclass('booking.invoices');
    END IF;

    IF EXISTS (SELECT 1 FROM booking.job WHERE kind IN ('bk_inquiry_pull', 'bk_inquiry_process')
                AND status IN ('queued', 'running')) THEN
        RAISE EXCEPTION 'bk-076: the inquiry intake still runs (bk_inquiry_pull / bk_inquiry_process queued or running): '
            'deploy the Booking build without the intake first and cancel its queued jobs';
    END IF;

    -- last-write:begin
    SELECT max(t) INTO last_at FROM (
        SELECT greatest(max(created_at), max(updated_at)) AS t FROM booking.customers
        UNION ALL SELECT max(created_at) FROM booking.customer_identities
        UNION ALL SELECT greatest(max(created_at), max(used_at)) FROM booking.customer_otps
        UNION ALL SELECT greatest(max(created_at), max(revoked_at)) FROM booking.customer_sessions
        UNION ALL SELECT greatest(max(created_at), max(deleted_at)) FROM booking.media_files
        UNION ALL SELECT greatest(max(created_at), max(updated_at)) FROM booking.invoices
        UNION ALL SELECT greatest(max(created_at), max(updated_at)) FROM booking.invoice_items
        UNION ALL SELECT greatest(max(created_at), max(updated_at)) FROM booking.payment_schedule
        UNION ALL SELECT greatest(max(created_at), max(updated_at)) FROM booking.payments
        UNION ALL SELECT greatest(max(created_at), max(updated_at)) FROM booking.trip_cases WHERE channel = 'b2c'
        UNION ALL SELECT greatest(max(created_at), max(updated_at)) FROM booking.trip_case_versions
                   WHERE trip_case_id IN (SELECT id FROM booking.trip_cases WHERE channel = 'b2c')
        UNION ALL SELECT greatest(max(created_at), max(updated_at)) FROM booking.supplier_bookings
                   WHERE trip_case_id IN (SELECT id FROM booking.trip_cases WHERE channel = 'b2c')
        UNION ALL SELECT greatest(max(created_at), max(updated_at)) FROM booking.supplier_bills
                   WHERE trip_case_id IN (SELECT id FROM booking.trip_cases WHERE channel = 'b2c')
                      OR id IN (SELECT it.bill_id FROM booking.supplier_bill_items it
                                  JOIN booking.supplier_bookings sb ON sb.id = it.supplier_booking_id
                                  JOIN booking.trip_cases tc ON tc.id = sb.trip_case_id WHERE tc.channel = 'b2c')
        UNION ALL SELECT max(it.created_at) FROM booking.supplier_bill_items it
                   JOIN booking.supplier_bookings sb ON sb.id = it.supplier_booking_id
                   JOIN booking.trip_cases tc ON tc.id = sb.trip_case_id WHERE tc.channel = 'b2c'
        UNION ALL SELECT greatest(max(o.created_at), max(o.updated_at)) FROM booking.supplier_payouts o
                   WHERE o.bill_id IN (SELECT b.id FROM booking.supplier_bills b
                                         JOIN booking.trip_cases tc ON tc.id = b.trip_case_id WHERE tc.channel = 'b2c'
                                       UNION SELECT it.bill_id FROM booking.supplier_bill_items it
                                         JOIN booking.supplier_bookings sb ON sb.id = it.supplier_booking_id
                                         JOIN booking.trip_cases tc ON tc.id = sb.trip_case_id
                                        WHERE tc.channel = 'b2c')
        UNION ALL SELECT greatest(max(f.created_at), max(f.updated_at), max(f.removed_at)) FROM booking.ops_files f
                   WHERE f.entity_type = 'payment'
                      OR f.trip_case_id IN (SELECT id FROM booking.trip_cases WHERE channel = 'b2c')
                      OR (f.entity_type IN ('supplier_bill', 'supplier_payout') AND f.entity_id IN (
                            SELECT b.id FROM booking.supplier_bills b
                              JOIN booking.trip_cases tc ON tc.id = b.trip_case_id WHERE tc.channel = 'b2c'
                            UNION SELECT it.bill_id FROM booking.supplier_bill_items it
                              JOIN booking.supplier_bookings sb ON sb.id = it.supplier_booking_id
                              JOIN booking.trip_cases tc ON tc.id = sb.trip_case_id WHERE tc.channel = 'b2c'
                            UNION SELECT o.id FROM booking.supplier_payouts o WHERE o.bill_id IN (
                              SELECT b.id FROM booking.supplier_bills b
                                JOIN booking.trip_cases tc ON tc.id = b.trip_case_id WHERE tc.channel = 'b2c'
                              UNION SELECT it.bill_id FROM booking.supplier_bill_items it
                                JOIN booking.supplier_bookings sb ON sb.id = it.supplier_booking_id
                                JOIN booking.trip_cases tc ON tc.id = sb.trip_case_id WHERE tc.channel = 'b2c')))
        UNION ALL SELECT max(received_at) FROM booking.inbox_events WHERE contract = 'inquiry.submitted'
    ) w;
    -- last-write:end
    IF last_at > now() - interval '30 days' THEN
        RAISE EXCEPTION 'bk-076: a B2C row was written at % (less than 30 days ago): B2C is not frozen yet', last_at;
    END IF;

    -- Pins: what the DRY RUN saw in every dropped table is still exactly what is there. They bind only where a row
    -- would be lost: a database whose dropped tables are all empty (the Integration Tests replay every file on an
    -- empty schema; a Dev already emptied) loses nothing, whatever the pins say.
    FOREACH k IN ARRAY pin_tables LOOP
        EXECUTE format('SELECT count(*) AS n, md5(coalesce(string_agg(r, chr(10) ORDER BY r), %L)) AS h'
                       ' FROM (SELECT jsonb_build_array(%s)::text AS r FROM booking.%I t) s',
                       '', pin_columns->>k, k) INTO n, h;
        actual := actual || jsonb_build_object(k, jsonb_build_object('n', n, 'md5', h));
        total := total + n;
    END LOOP;
    IF total > 0 THEN
        FOREACH k IN ARRAY pin_tables LOOP
            IF jsonb_typeof(pins->k) IS DISTINCT FROM 'object' THEN
                RAISE EXCEPTION 'bk-076: % has no DRY RUN pin (paste DRYRUN_PINS into pins)', k;
            END IF;
            IF (actual->k->>'n')::bigint <> (pins->k->>'n')::bigint THEN
                RAISE EXCEPTION 'bk-076: % has % rows now, the DRY RUN counted %: run the DRY RUN again',
                    k, actual->k->>'n', pins->k->>'n';
            END IF;
            IF actual->k->>'md5' IS DISTINCT FROM pins->k->>'md5' THEN
                RAISE EXCEPTION 'bk-076: the rows of % changed since the DRY RUN (same count, other content): run the '
                    'DRY RUN again', k;
            END IF;
        END LOOP;
    END IF;

    -- Views and foreign keys outside this file that would break (or block the DROPs).
    SELECT string_agg(DISTINCT dep, ', ' ORDER BY dep) INTO deps FROM (
        SELECT v.oid::regclass::text || ' (view on ' || t.oid::regclass::text || ')' AS dep
          FROM unnest(ARRAY['booking.customers', 'booking.customer_identities', 'booking.customer_otps',
                            'booking.customer_sessions', 'booking.media_files', 'booking.invoices',
                            'booking.invoice_items', 'booking.payment_schedule', 'booking.payments',
                            'booking.v_invoice_balance', 'booking.v_payment_schedule_status',
                            'booking.v_customer_summary', 'booking.v_ops_inquiry_inbox']::regclass[]) AS t(oid)
          JOIN pg_depend d ON d.refobjid = t.oid AND d.classid = 'pg_rewrite'::regclass
          JOIN pg_rewrite r ON r.oid = d.objid JOIN pg_class v ON v.oid = r.ev_class
         WHERE v.oid <> t.oid
           AND v.oid::regclass::text NOT IN ('booking.v_invoice_balance', 'booking.v_payment_schedule_status',
                                             'booking.v_customer_summary', 'booking.v_trip_check_board',
                                             'booking.v_ops_data_totals')
        UNION
        SELECT c.conrelid::regclass::text || ' (FK ' || c.conname || ' to ' || c.confrelid::regclass::text || ')'
          FROM pg_constraint c
         WHERE c.contype = 'f'
           AND c.confrelid IN ('booking.customers'::regclass, 'booking.media_files'::regclass,
                               'booking.invoices'::regclass, 'booking.payments'::regclass,
                               'booking.payment_schedule'::regclass, 'booking.invoice_items'::regclass)
           AND c.conrelid::regclass::text NOT IN ('booking.customers', 'booking.customer_identities',
                                                  'booking.customer_otps', 'booking.customer_sessions',
                                                  'booking.invoices', 'booking.invoice_items',
                                                  'booking.payment_schedule', 'booking.payments',
                                                  'booking.trip_cases')
    ) x;
    IF deps IS NOT NULL THEN
        RAISE EXCEPTION 'bk-076: objects outside this file depend on the B2C tables: %', deps;
    END IF;
END $$;

-- ── 1. Archive the customer money rows (accounting exception, DM-7.1) ─────────

CREATE TABLE IF NOT EXISTS booking.retired_b2c_record (
    source_table  text        NOT NULL,
    source_id     uuid        NOT NULL,
    record        jsonb       NOT NULL,
    last_write_at timestamptz NOT NULL,
    retain_until  date        NOT NULL,
    archived_at   timestamptz NOT NULL DEFAULT now(),
    archived_by   text        NOT NULL,
    CONSTRAINT retired_b2c_record_pkey PRIMARY KEY (source_table, source_id),
    CONSTRAINT retired_b2c_record_source_chk
        CHECK (source_table = ANY (ARRAY['invoices'::text, 'invoice_items'::text, 'payment_schedule'::text,
                                         'payments'::text])),
    CONSTRAINT retired_b2c_record_retain_chk CHECK (retain_until > last_write_at::date)
);
COMMENT ON TABLE booking.retired_b2c_record IS
    'bk-076 (AA-1037, root ADR 0019): the rows of the retired customer money tables (invoices, invoice_items, '
    'payment_schedule, payments), copied whole before the tables dropped. Accounting exception (DM-7.1): kept until '
    'retain_until, also through an erasure request (free text in record is redacted then). Owner-only, append-only; '
    'moves to the DM-7.3 S3 archive when it exists.';
COMMENT ON COLUMN booking.retired_b2c_record.record IS
    'pii:free_text; to_jsonb of the source row: bill_to name, e-mail and address of the invoice, payment reference, '
    'notes and reasons';
COMMENT ON COLUMN booking.retired_b2c_record.retain_until IS
    '31 December of (year of the source row''s last write, Asia/Ho_Chi_Minh) + 10: the proposed statutory period '
    '(DM-7.1 accounting exception; the accountant confirms before prod)';
-- Owner-only: the schema's default privileges give role booking arwd on a new table; the app never reads it.
REVOKE ALL ON booking.retired_b2c_record FROM PUBLIC, booking;

DO $$
DECLARE
    k      text;
    n_src  bigint;
    n_arc  bigint;
BEGIN
    FOREACH k IN ARRAY ARRAY['invoices', 'invoice_items', 'payment_schedule', 'payments'] LOOP
        CONTINUE WHEN to_regclass('booking.' || k) IS NULL;           -- already dropped (re-run)
        EXECUTE format(
            'INSERT INTO booking.retired_b2c_record (source_table, source_id, record, last_write_at, retain_until,'
            ' archived_by)'
            ' SELECT %L, t.id, to_jsonb(t), greatest(t.created_at, t.updated_at),'
            '  make_date(extract(year FROM greatest(t.created_at, t.updated_at) AT TIME ZONE %L)::int + 10, 12, 31),'
            '  %L FROM booking.%I t'
            ' ON CONFLICT (source_table, source_id) DO NOTHING',
            k, 'Asia/Ho_Chi_Minh', 'bk-076', k);
        EXECUTE format('SELECT count(*) FROM booking.%I', k) INTO n_src;
        EXECUTE format('SELECT count(*) FROM booking.%I t JOIN booking.retired_b2c_record r'
                       ' ON r.source_table = %L AND r.source_id = t.id AND r.record = to_jsonb(t)', k, k) INTO n_arc;
        IF n_arc <> n_src THEN
            RAISE EXCEPTION 'bk-076: archived % of the % rows of booking.%: nothing is dropped', n_arc, n_src, k;
        END IF;
    END LOOP;
END $$;

-- ── 2. Views rewritten without B2C (same columns; CREATE OR REPLACE keeps the grants) ──

CREATE OR REPLACE VIEW booking.v_trip_check_board AS
 SELECT tc.id AS trip_case_id,
    tc.code AS trip_case_code,
    tc.channel,
    tc.status AS case_status,
    tc.start_date,
    tc.end_date,
    COALESCE(k.total, 0::bigint)::integer AS checks_total,
    COALESCE(k.open, 0::bigint)::integer AS checks_open,
    COALESCE(k.done, 0::bigint)::integer AS checks_done,
    COALESCE(k.not_applicable, 0::bigint)::integer AS checks_not_applicable,
    COALESCE(k.overdue, 0::bigint)::integer AS checks_overdue,
    k.next_due AS next_due_date,
    s.state AS supply_state,
    s.state = ANY (ARRAY['booked'::text, 'none'::text]) AS suppliers_confirmed,
    NULL::boolean AS payment_verified
   FROM booking.trip_cases tc
     JOIN booking.v_trip_case_supply_state s ON s.trip_case_id = tc.id
     LEFT JOIN LATERAL ( SELECT count(*) AS total,
            count(*) FILTER (WHERE c.status = 'open'::text) AS open,
            count(*) FILTER (WHERE c.status = 'done'::text) AS done,
            count(*) FILTER (WHERE c.status = 'not_applicable'::text) AS not_applicable,
            count(*) FILTER (WHERE c.status = 'open'::text AND c.due_date < CURRENT_DATE) AS overdue,
            min(c.due_date) FILTER (WHERE c.status = 'open'::text) AS next_due
           FROM booking.trip_case_checks c
          WHERE c.trip_case_id = tc.id) k ON true
  WHERE tc.deleted_at IS NULL
    AND tc.status = ANY (ARRAY['confirmed'::text, 'supplier_confirming'::text, 'invoice_sent'::text,
                               'payment_pending'::text, 'paid'::text, 'pre_departure'::text, 'on_trip'::text]);

CREATE OR REPLACE VIEW booking.v_ops_data_totals AS
 SELECT 'trip_plans'::text AS metric, count(*) AS n FROM booking.trip_plans
UNION ALL
 SELECT 'trip_plans_sellable'::text, count(*) FROM booking.trip_plans WHERE trip_plans.sellable
UNION ALL
 SELECT 'trip_plan_components'::text, count(*) FROM booking.trip_plan_components
UNION ALL
 SELECT 'departures_open'::text, count(*) FROM booking.departures
  WHERE departures.status = ANY (ARRAY['scheduled'::text, 'guaranteed'::text]) AND departures.start_date >= CURRENT_DATE
UNION ALL
 SELECT 'suppliers_active'::text, count(*) FROM booking.suppliers WHERE suppliers.status = 'active'::text
UNION ALL
 SELECT 'contracts_published'::text, count(*) FROM booking.supplier_contracts
  WHERE supplier_contracts.status = 'published'::text AND supplier_contracts.valid_from <= CURRENT_DATE
    AND (supplier_contracts.valid_to IS NULL OR supplier_contracts.valid_to >= CURRENT_DATE)
UNION ALL
 SELECT 'rates_current'::text, count(*) FROM booking.supplier_rates
  WHERE supplier_rates.valid_from <= CURRENT_DATE
    AND (supplier_rates.valid_to IS NULL OR supplier_rates.valid_to >= CURRENT_DATE)
UNION ALL
 SELECT 'media_active'::text, count(*) FROM booking.entity_media WHERE entity_media.status = 'active'::text
UNION ALL
 SELECT 'media_active_with_rights'::text, count(*) FROM booking.entity_media
  WHERE entity_media.status = 'active'::text AND entity_media.usage_rights
UNION ALL
 SELECT 'b2b_partners_active'::text, count(*) FROM booking.b2b_partners WHERE b2b_partners.status = 'active'::text
UNION ALL
 SELECT 'b2b_holds_active'::text, count(*) FROM booking.b2b_holds WHERE b2b_holds.status = 'active'::text;

-- The views stay read-only for the app role (the migration guard's view rule; CREATE OR REPLACE keeps the grants).
REVOKE INSERT, UPDATE, DELETE ON booking.v_trip_check_board FROM booking;
REVOKE INSERT, UPDATE, DELETE ON booking.v_ops_data_totals FROM booking;

-- ── 3. Functions rewritten without B2C (same triggers) ───────────────────────

CREATE OR REPLACE FUNCTION booking.trip_cases_post_sale_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
    v_live     INTEGER;
    v_state    TEXT;
BEGIN
    SELECT count(*) INTO v_live FROM booking.supplier_bookings
     WHERE trip_case_id = NEW.id AND status IN ('pending', 'requested', 'confirmed');

    IF NEW.status = 'supplier_confirming' AND v_live = 0 THEN
        RAISE EXCEPTION 'trip case %: supplier_confirming needs a live supplier booking', NEW.code
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'confirmed' AND OLD.status = 'supplier_confirming' AND v_live > 0 THEN
        RAISE EXCEPTION 'trip case %: back to confirmed only when no live supplier booking is left', NEW.code
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'pre_departure' THEN
        SELECT state INTO v_state FROM booking.v_trip_case_supply_state WHERE trip_case_id = NEW.id;
        IF v_state IS DISTINCT FROM 'booked' AND v_state IS DISTINCT FROM 'none' THEN
            RAISE EXCEPTION 'trip case %: pre_departure needs every supplier booking confirmed (supply is %)',
                NEW.code, v_state USING ERRCODE = 'check_violation';
        END IF;
    ELSIF NEW.status = 'on_trip' AND (NEW.start_date IS NULL OR NEW.start_date > current_date) THEN
        RAISE EXCEPTION 'trip case %: on_trip only from its start date', NEW.code USING ERRCODE = 'check_violation';
    ELSIF NEW.status = 'completed' AND (NEW.end_date IS NULL OR NEW.end_date >= current_date) THEN
        RAISE EXCEPTION 'trip case %: completed only after its end date', NEW.code USING ERRCODE = 'check_violation';
    ELSIF NEW.status IN ('invoice_sent', 'payment_pending', 'paid') THEN
        -- bk-076 (AA-1037): the customer invoice is retired; agency money lives in booking.agency_invoice.
        RAISE EXCEPTION 'trip case %: no money status since the B2C retirement (agency invoices are separate)', NEW.code
            USING ERRCODE = 'check_violation';
    ELSIF NEW.status = 'new_inquiry' AND OLD.status = 'cancelled' AND v_live > 0 THEN
        RAISE EXCEPTION 'trip case %: cancel its % live supplier booking(s) before reopening it', NEW.code, v_live
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION booking.ops_files_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
    v_case      UUID;
    v_channel   TEXT;
    v_voided    TIMESTAMPTZ;
    v_status    TEXT;
    v_b2b       BOOLEAN := false;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.status = 'removed' AND NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'file % is removed; upload it again instead', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        IF (NEW.kind, NEW.entity_type, NEW.entity_id, NEW.trip_case_id, NEW.s3_bucket, NEW.s3_key, NEW.content_type,
            NEW.bytes, NEW.sha256, NEW.file_name, NEW.uploaded_by, NEW.created_at)
           IS DISTINCT FROM
           (OLD.kind, OLD.entity_type, OLD.entity_id, OLD.trip_case_id, OLD.s3_bucket, OLD.s3_key, OLD.content_type,
            OLD.bytes, OLD.sha256, OLD.file_name, OLD.uploaded_by, OLD.created_at) THEN
            RAISE EXCEPTION 'file %: only its removal changes', OLD.id USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.entity_type = 'payment' THEN
            -- bk-076 (AA-1037): evidence of a retired customer payment (archived in booking.retired_b2c_record) is
            -- kept as it is under the accounting exception (DM-7.1).
            RAISE EXCEPTION 'file %: evidence of a retired customer payment; it stays as it is', OLD.id
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.status = 'removed' AND OLD.status = 'active' AND OLD.entity_type = 'supplier_bill' THEN
            IF EXISTS (SELECT 1 FROM booking.supplier_bills b
                        WHERE b.document_file_id = OLD.id AND b.status IN ('approved', 'paid')) THEN
                RAISE EXCEPTION 'file % is the document of an approved supplier bill; it stays', OLD.id
                    USING ERRCODE = 'check_violation';
            END IF;
            IF EXISTS (SELECT 1 FROM booking.supplier_bills b
                        WHERE b.document_file_id = OLD.id AND b.status = 'received') THEN
                RAISE EXCEPTION 'file % is the attached document of a supplier bill; detach it before removing it',
                    OLD.id USING ERRCODE = 'check_violation';
            END IF;
        END IF;
        IF NEW.status = 'removed' AND OLD.status = 'active' AND OLD.entity_type = 'supplier_payout' THEN
            IF EXISTS (SELECT 1 FROM booking.supplier_payouts o
                        WHERE o.evidence_file_id = OLD.id AND o.voided_at IS NULL) THEN
                RAISE EXCEPTION 'file % is the evidence of a live payout; it stays (upload a replacement first)', OLD.id
                    USING ERRCODE = 'check_violation';
            END IF;
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.status <> 'active' THEN
        RAISE EXCEPTION 'a file starts active' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.entity_type = 'supplier_booking' THEN
        SELECT sb.trip_case_id, tc.channel INTO v_case, v_channel
          FROM booking.supplier_bookings sb JOIN booking.trip_cases tc ON tc.id = sb.trip_case_id
         WHERE sb.id = NEW.entity_id;
        IF v_case IS NULL THEN
            RAISE EXCEPTION 'file %: supplier booking % does not exist', NEW.id, NEW.entity_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
        v_b2b := v_channel = 'b2b';
    ELSIF NEW.entity_type = 'supplier_bill' THEN
        SELECT b.trip_case_id, b.status INTO v_case, v_status FROM booking.supplier_bills b WHERE b.id = NEW.entity_id;
        IF v_status IS NULL THEN
            RAISE EXCEPTION 'file %: supplier bill % does not exist', NEW.id, NEW.entity_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
        IF v_status <> 'received' THEN
            RAISE EXCEPTION 'file %: supplier bill % is %; its document is fixed', NEW.id, NEW.entity_id, v_status
                USING ERRCODE = 'check_violation';
        END IF;
        -- A supplier's bill names the guests: never on a bill that touches a B2B case (DM-6.8).
        v_b2b := EXISTS (SELECT 1 FROM booking.trip_cases tc WHERE tc.id = v_case AND tc.channel = 'b2b')
              OR EXISTS (SELECT 1 FROM booking.supplier_bill_items it
                           JOIN booking.supplier_bookings sb ON sb.id = it.supplier_booking_id
                           JOIN booking.trip_cases tc ON tc.id = sb.trip_case_id
                          WHERE it.bill_id = NEW.entity_id AND tc.channel = 'b2b');
    ELSIF NEW.entity_type = 'supplier_payout' THEN
        SELECT b.trip_case_id, o.voided_at INTO v_case, v_voided
          FROM booking.supplier_payouts o JOIN booking.supplier_bills b ON b.id = o.bill_id
         WHERE o.id = NEW.entity_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'file %: payout % does not exist', NEW.id, NEW.entity_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
        IF v_voided IS NOT NULL THEN
            RAISE EXCEPTION 'file %: payout % is voided; its evidence is fixed', NEW.id, NEW.entity_id
                USING ERRCODE = 'check_violation';
        END IF;
        -- AA's own bank slip to a supplier names no traveller: allowed on every case.
    ELSE
        -- bk-076 (AA-1037): 'payment' (customer payment evidence) is retired with the customer payments table.
        RAISE EXCEPTION 'file %: unknown entity type %', NEW.id, NEW.entity_type USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.trip_case_id IS DISTINCT FROM v_case THEN
        RAISE EXCEPTION 'file %: trip_case_id must be the trip case of its % %', NEW.id, NEW.entity_type, NEW.entity_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_b2b THEN
        RAISE EXCEPTION 'no supplier document on a B2B trip case (DM-6.8: confirmation ref only)'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

-- ── 4. B2C views, then the invoice / payment tables and their functions ──────

DROP VIEW IF EXISTS booking.v_invoice_balance;
DROP VIEW IF EXISTS booking.v_payment_schedule_status;
DROP VIEW IF EXISTS booking.v_customer_summary;
DROP VIEW IF EXISTS booking.v_ops_inquiry_inbox;

DROP TABLE IF EXISTS booking.payments;
DROP TABLE IF EXISTS booking.payment_schedule;
DROP TABLE IF EXISTS booking.invoice_items;
DROP TABLE IF EXISTS booking.invoices;

DROP FUNCTION IF EXISTS booking.invoice_settle(uuid);
DROP FUNCTION IF EXISTS booking.invoice_money_state(uuid, numeric);
DROP FUNCTION IF EXISTS booking.invoice_net_paid(uuid);
DROP FUNCTION IF EXISTS booking.invoices_guard();
DROP FUNCTION IF EXISTS booking.invoice_items_guard();
DROP FUNCTION IF EXISTS booking.invoice_items_settle();
DROP FUNCTION IF EXISTS booking.payment_schedule_guard();
DROP FUNCTION IF EXISTS booking.payments_guard();
DROP FUNCTION IF EXISTS booking.payments_settle();

-- ── 5. trip_cases: new cases are b2b only ────────────────────────────────────
-- The kept b2c cases (created before this apply) still pass the CHECK, so they stay readable and redactable
-- (DM-6.7); a b2c case created after the apply is refused. The cut-off is the apply time, written as a literal.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'booking.trip_cases'::regclass
                    AND attname = 'customer_id' AND NOT attisdropped) THEN
        RETURN;                                                     -- already applied (re-run)
    END IF;
    ALTER TABLE booking.trip_cases DROP CONSTRAINT IF EXISTS trip_cases_channel_chk;
    ALTER TABLE booking.trip_cases DROP COLUMN customer_id;
    EXECUTE format(
        'ALTER TABLE booking.trip_cases ADD CONSTRAINT trip_cases_channel_chk CHECK ('
        '(channel = %L AND party_tenant_id IS NOT NULL)'
        ' OR (channel = %L AND party_tenant_id IS NULL AND created_at < %L::timestamptz))',
        'b2b', 'b2c', date_trunc('second', now()));
END $$;
COMMENT ON CONSTRAINT trip_cases_channel_chk ON booking.trip_cases IS
    'bk-076 (AA-1037, root ADR 0019): a new trip case is a B2B case of a partner agency (party_tenant_id); b2c cases '
    'created before the B2C retirement are kept as history (DM-7.1), with no customer link (booking.customers is gone).';

-- ── 6. Customer tables, profile media, B2C sequences ─────────────────────────

DROP TABLE IF EXISTS booking.customer_identities;
DROP TABLE IF EXISTS booking.customer_otps;
DROP TABLE IF EXISTS booking.customer_sessions;
DROP TABLE IF EXISTS booking.customers;
DROP TABLE IF EXISTS booking.media_files;
DROP SEQUENCE IF EXISTS booking.customer_code_seq;
DROP SEQUENCE IF EXISTS booking.invoice_number_seq;
DROP SEQUENCE IF EXISTS booking.payment_ref_seq;

-- ── 7. Config rows (reference data) ──────────────────────────────────────────

DELETE FROM booking.ops_transitions WHERE entity = 'invoice';
DELETE FROM booking.trip_case_status_transitions
 WHERE from_status IN ('invoice_sent', 'payment_pending', 'paid')
    OR to_status IN ('invoice_sent', 'payment_pending', 'paid');

-- ── 8. Register ──────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-076', now(), 'AA-1037: retire B2C (customer and customer money tables dropped, money rows archived to '
        'retired_b2c_record, b2c cases kept as history, new trip cases b2b only)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
