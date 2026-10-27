"""AA-682 S4 (S254), Dev only: the live check of supplier bills and payouts (AA-Booking bk-030) on a synthetic supplier
and a synthetic sold trip case. Draft for AA-CIS-Infra db/scripts/aa682_s4_live_check.py (the orchestrator copies it
there; it is not part of the Booking repo).

Why a script: the agent's only Dev staff session (the AA-910 E2E admin) and every preview session are read-only, and
the AA-682 comment forbids payment actions in agent sessions (S252 design §2 note, critic B8). A run-script may not
import Booking code, so it makes the writes the service makes (app/ops/supplier_bills.py), in SQL, as `bk_owner`, with
three SYNTHETIC staff keys (enterer, checker, payer); the bk-030 triggers (bill guard, line guard, payout guard,
settle, maker-checker CHECK, ops_transitions edges) run for real. The API side is then checked read-only:
`GET /booking/supplier-bills?q=SYN-S4`, `GET /booking/supplier-bills/{code}`, `GET /booking/supplier-bills/summary`,
`GET /booking/trip-cases/{code}/supplier-costs`, the staff UI screenshots. The human walkthrough (enter by A, approve
by B, payout by an admin who is not A, void) stays an AA-855 UAT step.

What it does, in one transaction (MODE "dry_run" rolls it back at the end, "apply" commits):
- Three synthetic staff keys (`synthetic-aa682-s4-enterer` and `-checker` contracting, `-payer` admin, INACTIVE: no
  sign-in, they only fill created_by / approved_by / recorded_by).
- A synthetic supplier (`SYNTHETIC S254 AA-682 S4 supplier`, reused) and a synthetic B2C case inserted at `confirmed`
  (no version: the bookings are extra items), with two supplier bookings moved pending -> requested -> confirmed
  (net 300.00 and 80.00 USD); the case follows to `supplier_confirming` (app advance_case in SQL).
- A bill `SYN-S4-<ops date>` of 380.00 USD due ops today + 2, lines 300.00 + 80.00. Then, each step printed:
    * refused (savepoints): a line naming a pending booking; approve by the person who entered it (maker-checker);
      approve while the lines (380) differ from the amount (400); `UPDATE supplier_bills SET status = 'paid'`; a
      payout on a received bill;
    * approved by the checker -> `approved`;
    * refused: a payout by the bill's creator; a payout above the amount; a payout in another currency;
    * payout 200.00 by the payer -> `approved`, balance 180.00; the same Idempotency-Key again -> refused (unique);
      payout 180.00 -> `paid`; cancel with live payouts -> refused; the 180.00 voided -> `approved` (balance 180.00).
    * the view v_supplier_bill_balance (paid, balance, lines) and the cost vs billed numbers of the case.
- The reminder: MODE "dry_run" writes the `supplier_bill.due` staff row of the bill twice in SQL with ON CONFLICT DO
  NOTHING (key `supplier_bill.due:<bill>:<due>:soon`) -> one row. MODE "apply": commits, then queues two manual
  `bk_ops_reminders` jobs for the worker and waits up to POLL_SECONDS; the bill must have exactly one
  `supplier_bill.due` row.

Idempotent per day: when today's synthetic bill already exists (an earlier apply), nothing is written again and the
current state is printed. Audit rows name the actor `script:aa682_s4_live_check`. Nothing is deleted. No S3 object is
written (no document, no bank slip). Prints codes, statuses, amounts and counts only (no personal data): the Actions
log of the public Infra repo is readable.

Modes (DB Migrate mode=run-script, as the RDS master; db/scripts/README.md): MODE = "dry_run" (this file as merged)
runs every write and check, prints the results and rolls everything back; a one-line follow-up PR sets MODE = "apply"
(leaves the synthetic supplier, case, bookings, bill and payouts on Dev for the read-only API check and the
screenshots). Needs bk-030 applied (refuses otherwise). Local test:
`python3 aa682_s4_live_check.py <DSN> [--apply] [--no-wait]`.
"""

import asyncio
import json

MODE = "dry_run"

SCRIPT_NAME = "aa682_s4_live_check"
ACTOR = f"script:{SCRIPT_NAME}"
TAG = "SYNTHETIC S254 AA-682 S4"
NOTE = f"{TAG} case"
SUPPLIER_NAME = f"{TAG} supplier"
CUSTOMER_EMAIL = "synthetic-aa682-s4@example.invalid"
ENTERER = "synthetic-aa682-s4-enterer"
CHECKER = "synthetic-aa682-s4-checker"
PAYER = "synthetic-aa682-s4-payer"
REQUIRED_VERSION = "bk-030"
WRITE_ROLE = "bk_owner"
DEFAULT_TZ = "Asia/Ho_Chi_Minh"
REMINDERS_KIND = "bk_ops_reminders"
BILL_DUE_TYPE = "supplier_bill.due"
POLL_SECONDS = 90
SHA = "0" * 64  # request hash placeholder: the script's own keys are never replayed through the API


def out(tag: str, /, **values) -> None:
    parts = " ".join(f"{k}={v}" for k, v in values.items())
    print(f"SCRIPT {tag} {parts}".rstrip(), flush=True)


async def _expect_refusal(conn, what: str, sql: str, *args) -> bool:
    """Run one statement in a savepoint; True (and rolled back) when the database refuses it."""
    try:
        async with conn.transaction():
            await conn.execute(sql, *args)
    except Exception as exc:  # noqa: BLE001 — the refusal is the expected outcome
        out("check", what=what, refused=True, sqlstate=getattr(exc, "sqlstate", "?"))
        return True
    out("check", what=what, refused=False)
    return False


async def _audit(conn, action: str, entity_type: str, entity_id: str, label: str, after: dict, summary: str) -> None:
    await conn.execute(
        "INSERT INTO booking.audit_logs (actor_type, actor_ref, action, entity_type, entity_id, after, entity_label,"
        " summary) VALUES ('system', $1, $2, $3, $4::uuid, $5::jsonb, $6, $7)",
        ACTOR, action, entity_type, entity_id, json.dumps(after, default=str), label, summary,
    )


async def _ops_zone(conn) -> str:
    raw = await conn.fetchval("SELECT value #>> '{}' FROM booking.settings WHERE key = 'b2b_ops_timezone'")
    if raw and await conn.fetchval("SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1)", raw):
        return raw
    return DEFAULT_TZ


async def _staff(conn) -> None:
    for key, role in ((ENTERER, "contracting"), (CHECKER, "contracting"), (PAYER, "admin")):
        await conn.execute(
            "INSERT INTO booking.staff_users (cis_user_id, role, active, name) VALUES ($1, $2, false, $3)"
            " ON CONFLICT (cis_user_id) DO NOTHING",
            key, role, f"{TAG} {key.rsplit('-', 1)[-1]}",
        )


async def _supplier(conn) -> str:
    sid = await conn.fetchval("SELECT id::text FROM booking.suppliers WHERE company_name = $1", SUPPLIER_NAME)
    if sid is None:
        sid = await conn.fetchval(
            "INSERT INTO booking.suppliers (company_name, categories, country_code) VALUES ($1, ARRAY['hotel'], 'VN')"
            " RETURNING id::text",
            SUPPLIER_NAME,
        )
    return sid


async def _case(conn, today) -> dict:
    customer = await conn.fetchval("SELECT id::text FROM booking.customers WHERE email = $1", CUSTOMER_EMAIL)
    if customer is None:
        customer = await conn.fetchval(
            "INSERT INTO booking.customers (email, name) VALUES ($1, $2) RETURNING id::text",
            CUSTOMER_EMAIL, f"{TAG} traveller",
        )
    await conn.execute("SELECT set_config('booking.actor', '', true), set_config('booking.status_note', $1, true)",
                       f"{ACTOR}: synthetic sold case")
    case = await conn.fetchrow(
        "INSERT INTO booking.trip_cases (customer_id, status, start_date, end_date, pax, pax_adults, currency,"
        " source_system, notes) VALUES ($1::uuid, 'confirmed', $2::date + 40, $2::date + 44, 2, 2, 'USD', 'manual', $3)"
        " RETURNING id::text AS id, code",
        customer, today, NOTE,
    )
    await conn.execute("SELECT set_config('booking.status_note', '', true)")
    out("write", what="sold_case", code=case["code"], status="confirmed")
    return dict(case)


async def _confirmed_booking(conn, case: dict, supplier: str, what: str, net: str) -> dict:
    row = await conn.fetchrow(
        "INSERT INTO booking.supplier_bookings (trip_case_id, supplier_id, item_description, net_amount, net_currency,"
        " created_by, updated_by) VALUES ($1::uuid, $2::uuid, $3, $4::numeric, 'USD', $5, $5)"
        " RETURNING id::text AS id, code",
        case["id"], supplier, f"{TAG} {what}", net, ENTERER,
    )
    await conn.execute(
        "UPDATE booking.supplier_bookings SET status = 'requested', requested_at = now(), requested_by = $2"
        " WHERE id = $1::uuid", row["id"], ENTERER,
    )
    await conn.execute(
        "UPDATE booking.supplier_bookings SET status = 'confirmed', confirmed_at = now(), confirmed_by = $2,"
        " confirmation_ref = $3 WHERE id = $1::uuid", row["id"], ENTERER, f"SYN-{row['code']}",
    )
    out("write", what="supplier_booking_confirmed", code=row["code"], net=f"{net} USD")
    return dict(row)


async def _advance(conn, case: dict) -> str:
    """app/ops/track.advance_case in SQL (supply track): confirmed -> supplier_confirming once a supplier was asked."""
    await conn.execute("SELECT set_config('booking.actor', '', true), set_config('booking.status_note', $1, true)",
                       f"Auto: supplier booked ({ACTOR})")
    await conn.execute(
        "UPDATE booking.trip_cases SET status = 'supplier_confirming' WHERE id = $1::uuid AND status = 'confirmed'",
        case["id"],
    )
    await conn.execute("SELECT set_config('booking.status_note', '', true)")
    return await conn.fetchval("SELECT status FROM booking.trip_cases WHERE id = $1::uuid", case["id"])


async def _bill(conn, supplier: str, case: dict, number: str, today) -> dict:
    row = await conn.fetchrow(
        "INSERT INTO booking.supplier_bills (supplier_id, trip_case_id, bill_number, currency, amount, issue_date,"
        " due_date, idempotency_key, request_sha256, created_by, updated_by)"
        " VALUES ($1::uuid, $2::uuid, $3, 'USD', 380, $4::date, $4::date + 2, $5, $6, $7, $7)"
        " RETURNING id::text AS id, code, due_date",
        supplier, case["id"], number, today, f"syn-s4-bill-{number}", SHA, ENTERER,
    )
    await _audit(conn, "supplier_bill.created", "supplier_bill", row["id"], row["code"],
                 {"amount": "380.00", "currency": "USD"}, f"Entered {row['code']} ({ACTOR})")
    return dict(row)


async def _line(conn, bill: dict, booking: dict, amount: str) -> None:
    await conn.execute(
        "INSERT INTO booking.supplier_bill_items (bill_id, supplier_booking_id, amount, created_by)"
        " VALUES ($1::uuid, $2::uuid, $3::numeric, $4)",
        bill["id"], booking["id"], amount, ENTERER,
    )


async def _payout(conn, bill: dict, amount: str, key: str, by: str = PAYER, currency: str = "USD") -> dict:
    row = await conn.fetchrow(
        "INSERT INTO booking.supplier_payouts (bill_id, amount, currency, method, paid_on, reference, idempotency_key,"
        " request_sha256, recorded_by, updated_by) VALUES ($1::uuid, $2::numeric, $3, 'bank_transfer', current_date,"
        " $4, $5, $6, $7, $7) RETURNING id::text AS id, code",
        bill["id"], amount, currency, f"SYN-{key}", key, SHA, by,
    )
    await _audit(conn, "supplier_payout.recorded", "supplier_payout", row["id"], f"{bill['code']} {row['code']}",
                 {"amount": amount, "currency": currency, "reference": "(set)"}, f"Paid {row['code']} ({ACTOR})")
    return dict(row)


async def _state(conn, bill: dict, step: str) -> tuple[str, str]:
    row = await conn.fetchrow(
        "SELECT b.status, v.paid_amount::text AS paid, v.balance::text AS balance, v.line_count, v.live_payouts"
        " FROM booking.supplier_bills b JOIN booking.v_supplier_bill_balance v ON v.bill_id = b.id"
        " WHERE b.id = $1::uuid", bill["id"],
    )
    out("state", step=step, bill=bill["code"], status=row["status"], paid=row["paid"], balance=row["balance"],
        lines=row["line_count"], live_payouts=row["live_payouts"])
    return row["status"], row["balance"]


async def _flow(conn, today) -> tuple[bool, dict]:
    supplier = await _supplier(conn)
    case = await _case(conn, today)
    room = await _confirmed_booking(conn, case, supplier, "room", "300.00")
    kayak = await _confirmed_booking(conn, case, supplier, "kayak", "80.00")
    out("state", step="case_after_supply", case=case["code"], case_status=await _advance(conn, case))
    pending = await conn.fetchval(
        "INSERT INTO booking.supplier_bookings (trip_case_id, supplier_id, item_description, created_by)"
        " VALUES ($1::uuid, $2::uuid, $3, $4) RETURNING id::text",
        case["id"], supplier, f"{TAG} extra (pending)", ENTERER,
    )
    bill = await _bill(conn, supplier, case, f"SYN-S4-{today:%Y%m%d}", today)
    await _line(conn, bill, room, "300.00")
    await _line(conn, bill, kayak, "80.00")
    checks = [
        await _expect_refusal(conn, "line_on_pending_booking",
                              "INSERT INTO booking.supplier_bill_items (bill_id, supplier_booking_id, amount, created_by)"
                              " VALUES ($1::uuid, $2::uuid, 1, $3)", bill["id"], pending, ENTERER),
        await _expect_refusal(conn, "approve_by_enterer_maker_checker",
                              "UPDATE booking.supplier_bills SET status = 'approved', approved_by = $2, approved_at = now()"
                              " WHERE id = $1::uuid", bill["id"], ENTERER),
        await _expect_refusal(conn, "approve_lines_not_equal_amount",
                              "UPDATE booking.supplier_bills SET amount = 400, status = 'approved', approved_by = $2,"
                              " approved_at = now() WHERE id = $1::uuid", bill["id"], CHECKER),
        await _expect_refusal(conn, "direct_status_paid",
                              "UPDATE booking.supplier_bills SET status = 'paid', paid_at = now() WHERE id = $1::uuid",
                              bill["id"]),
        await _expect_refusal(conn, "payout_on_received_bill",
                              "INSERT INTO booking.supplier_payouts (bill_id, amount, currency, method, paid_on,"
                              " idempotency_key, request_sha256, recorded_by) VALUES ($1::uuid, 1, 'USD', 'cash',"
                              " current_date, 'syn-s4-refused-1', $2, $3)", bill["id"], SHA, PAYER),
    ]
    await conn.execute(
        "UPDATE booking.supplier_bills SET status = 'approved', approved_by = $2, approved_at = now(), updated_by = $2"
        " WHERE id = $1::uuid", bill["id"], CHECKER,
    )
    await _audit(conn, "supplier_bill.approved", "supplier_bill", bill["id"], bill["code"], {"status": "approved"},
                 f"Approved {bill['code']} ({ACTOR})")
    status, _ = await _state(conn, bill, "approved_by_checker")
    checks.append(status == "approved")
    pay_sql = ("INSERT INTO booking.supplier_payouts (bill_id, amount, currency, method, paid_on, idempotency_key,"
               " request_sha256, recorded_by) VALUES ($1::uuid, $2::numeric, $3, 'cash', current_date, $4, $5, $6)")
    checks += [
        await _expect_refusal(conn, "payout_by_bill_creator", pay_sql, bill["id"], "10", "USD", "syn-s4-r-2", SHA,
                              ENTERER),
        await _expect_refusal(conn, "payout_above_amount", pay_sql, bill["id"], "380.01", "USD", "syn-s4-r-3", SHA,
                              PAYER),
        await _expect_refusal(conn, "payout_other_currency", pay_sql, bill["id"], "10", "EUR", "syn-s4-r-4", SHA,
                              PAYER),
    ]
    await _payout(conn, bill, "200.00", "syn-s4-pay-1")
    status, balance = await _state(conn, bill, "payout_200")
    checks.append(status == "approved" and balance == "180.00")
    checks.append(await _expect_refusal(conn, "same_idempotency_key", pay_sql, bill["id"], "1", "USD", "syn-s4-pay-1",
                                        SHA, PAYER))
    second = await _payout(conn, bill, "180.00", "syn-s4-pay-2")
    status, balance = await _state(conn, bill, "payout_180")
    checks.append(status == "paid" and balance == "0.00")
    checks.append(await _expect_refusal(conn, "cancel_with_live_payouts",
                                        "UPDATE booking.supplier_bills SET status = 'cancelled', cancelled_at = now(),"
                                        " cancelled_by = $2, cancel_reason = 'x' WHERE id = $1::uuid",
                                        bill["id"], CHECKER))
    await conn.execute(
        "UPDATE booking.supplier_payouts SET voided_at = now(), voided_by = $2, void_reason = $3, updated_by = $2"
        " WHERE id = $1::uuid", second["id"], PAYER, f"{TAG}: void check",
    )
    await _audit(conn, "supplier_payout.voided", "supplier_payout", second["id"], second["code"], {"state": "voided"},
                 f"Voided {second['code']} ({ACTOR})")
    status, balance = await _state(conn, bill, "payout_180_voided")
    checks.append(status == "approved" and balance == "180.00")
    costs = await conn.fetch(
        "SELECT sb.code, sb.net_amount::text AS net, coalesce(sum(it.amount), 0)::text AS billed"
        " FROM booking.supplier_bookings sb LEFT JOIN booking.supplier_bill_items it ON it.supplier_booking_id = sb.id"
        " LEFT JOIN booking.supplier_bills b ON b.id = it.bill_id AND b.status <> 'cancelled'"
        " WHERE sb.trip_case_id = $1::uuid AND sb.status = 'confirmed' GROUP BY sb.code, sb.net_amount ORDER BY sb.code",
        case["id"],
    )
    for c in costs:
        out("cost_vs_billed", booking=c["code"], net=c["net"], billed=c["billed"])
    ok = all(checks)
    out("flow", case=case["code"], bill=bill["code"], checks=len(checks), ok=ok)
    return ok, bill


async def _due_rows(conn, bill_id: str) -> int:
    return await conn.fetchval(
        "SELECT count(*)::int FROM booking.notifications WHERE type = $1 AND entity_id = $2::uuid", BILL_DUE_TYPE, bill_id,
    )


async def _reminder_in_sql(conn, bill: dict) -> int:
    key = f"{BILL_DUE_TYPE}:{bill['id']}:{bill['due_date'].isoformat()}:soon"
    for _ in range(2):
        await conn.execute(
            "INSERT INTO booking.notifications (recipient_type, recipient_id, recipient_ref, type, title, message,"
            " entity_type, entity_id, data) VALUES ('staff', NULL, NULL, $1, $2, 'Due soon (live check).',"
            " 'supplier_bill', $3::uuid, $4::jsonb) ON CONFLICT DO NOTHING",
            BILL_DUE_TYPE, f"{bill['code']}: pay ({TAG})", bill["id"], json.dumps({"reminder_key": key}),
        )
    rows = await _due_rows(conn, bill["id"])
    out("check", what="bill_due_reminder_once_per_key", rows=rows, expected=1)
    return rows


async def _queue(conn, key: str) -> str | None:
    return await conn.fetchval(
        "INSERT INTO booking.job (kind, payload, idempotency_key, max_attempts, created_by)"
        " VALUES ($1, '{\"trigger\": \"manual\"}'::jsonb, $2, 3, $3) ON CONFLICT DO NOTHING RETURNING id::text",
        REMINDERS_KIND, key, ACTOR,
    )


async def _wait(conn, job_ids: list[str], seconds: int) -> None:
    pending = [j for j in job_ids if j]
    rows = []
    for _ in range(max(seconds // 3, 1)):
        rows = await conn.fetch(
            "SELECT id::text AS id, status, result::text AS result, left(error, 200) AS error FROM booking.job"
            " WHERE id = ANY($1::uuid[])", pending,
        )
        if rows and all(r["status"] in ("succeeded", "failed", "cancelled") for r in rows):
            break
        await asyncio.sleep(3)
    for r in rows:
        res = json.loads(r["result"]) if r["result"] else {}
        out("job", id=r["id"], status=r["status"], bills_due=res.get("bills_due"),
            bills_notified=res.get("bills_notified"), error=r["error"])


async def run(conn, mode: str, wait: bool = True) -> int:
    out(SCRIPT_NAME, mode=mode.upper())
    if not await conn.fetchval("SELECT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = $1)",
                               REQUIRED_VERSION):
        out("refuse", why=f"{REQUIRED_VERSION} is not applied")
        return 1
    tx = conn.transaction()
    await tx.start()
    try:
        await conn.execute(f"SET LOCAL ROLE {WRITE_ROLE}")
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext($1))", SCRIPT_NAME)
        zone = await _ops_zone(conn)
        await conn.execute("SELECT set_config('TimeZone', $1, true)", zone)
        today = await conn.fetchval("SELECT current_date")
        out("context", ops_zone=zone, ops_today=today)
        existing = await conn.fetchrow(
            "SELECT b.code, b.status, v.balance::text AS balance FROM booking.supplier_bills b"
            " JOIN booking.suppliers s ON s.id = b.supplier_id"
            " JOIN booking.v_supplier_bill_balance v ON v.bill_id = b.id"
            " WHERE s.company_name = $1 AND b.bill_number = $2",
            SUPPLIER_NAME, f"SYN-S4-{today:%Y%m%d}",
        )
        if existing is not None:
            out("reused", bill=existing["code"], status=existing["status"], balance=existing["balance"])
            await tx.rollback()
            return 0
        await _staff(conn)
        ok, bill = await _flow(conn, today)
        if mode != "apply":
            ok = ok and await _reminder_in_sql(conn, bill) == 1
        counts = await conn.fetchrow(
            "SELECT count(*)::int AS bills, count(*) FILTER (WHERE status IN ('received', 'approved'))::int AS open,"
            " (SELECT count(*)::int FROM booking.supplier_payouts) AS payouts FROM booking.supplier_bills"
        )
        out("counts", bills=counts["bills"], open_bills=counts["open"], payouts=counts["payouts"])
        out("verdict", ok=ok, mode=mode)
    except BaseException:
        await tx.rollback()
        raise
    if mode == "apply" and ok:
        await tx.commit()
        jobs = [await _queue(conn, f"{REMINDERS_KIND}:{SCRIPT_NAME}:{n}:{today}") for n in (1, 2)]
        out("write", what="queued_reminder_jobs", jobs=",".join(j or "-" for j in jobs))
        if wait:
            await _wait(conn, jobs[:1], POLL_SECONDS)
            await _wait(conn, jobs[1:], POLL_SECONDS)
            out("verify", what="bill_due_reminder_once", bill=bill["code"], rows=await _due_rows(conn, bill["id"]),
                expected=1)
    else:
        await tx.rollback()
        out("rolled_back", reason="dry_run" if mode != "apply" else "verdict not ok")
    return 0 if ok else 1


async def main(conn):
    return await run(conn, MODE)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse

    import asyncpg

    parser = argparse.ArgumentParser(description="AA-682 S4 live check on synthetic data (DRY RUN by default)")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="commit and queue the reminder jobs")
    parser.add_argument("--no-wait", action="store_true", help="do not wait for the worker")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, "apply" if args.apply else "dry_run", wait=not args.no_wait)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
