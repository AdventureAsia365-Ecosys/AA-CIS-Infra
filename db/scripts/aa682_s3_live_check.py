"""AA-682 S3 (S253), Dev only: the live check of invoices, the payment schedule and manual payments (AA-Booking bk-028)
on synthetic trip cases. Draft for AA-CIS-Infra db/scripts/aa682_s3_live_check.py (the orchestrator copies it there;
it is not part of the Booking repo).

Why a script: the agent's only Dev staff session (the AA-910 E2E admin) and every preview session are read-only, and
the AA-682 comment forbids payment actions in agent sessions (S252 design §2 note, critic B8). A run-script may not
import Booking code, so it makes the writes the services make (app/ops/invoices.py, payments.py, track.py), in SQL, as
`bk_owner`, with two SYNTHETIC staff keys as maker and checker; the bk-028 triggers (money guard, settle, maker-checker
CHECK, schedule sums, case fact guard) run for real. The API side is then checked read-only: `GET
/booking/invoices?q=SYN`, `GET /booking/invoices/{number}`, `GET /booking/trip-cases/{code}/billing`, `GET
/booking/billing/summary`, the staff UI screenshots. The human walkthrough (Nghiệp + a second admin record / verify /
void through the UI) stays an AA-855 UAT step.

What it does, in one transaction (MODE "dry_run" rolls it back at the end, "apply" commits):
- Two synthetic staff keys (`synthetic-aa682-s3-maker`, `synthetic-aa682-s3-checker`, role admin, INACTIVE: no
  sign-in, they only fill recorded_by / verified_by).
- Case A (the Done-when flow): a synthetic customer (`synthetic-aa682-s3@example.invalid`) and a B2C case INSERTED at
  `confirmed` with an approved V1 of 2400 USD, start = ops today + 40. Invoice draft: the version total line + the 30 /
  70 schedule (720 due ops today + 3, 1680 due start - 30), sent (bill-to snapshot) -> case `invoice_sent` (the
  advance_case UPDATE). Then, each step printed with the invoice and case status:
    * refused (savepoints, the refusal is the expected outcome): `UPDATE invoices SET status = 'paid'` (money guard),
      the case to `paid` (fact guard), a bank transfer verified by its own recorder (maker-checker), verified without
      evidence (evidence rule), the same Idempotency-Key twice (unique per invoice -> one payment);
    * the deposit 720 (cash) recorded by the maker, verified by the checker -> invoice `partially_paid`, case
      `payment_pending`; the balance 1680 (cash) -> `paid` / `paid`; the balance voided by the checker -> back to
      `partially_paid` / `payment_pending`. The unverified bank transfer is voided (no evidence object exists on Dev:
      the script never writes S3).
    * the views: v_invoice_balance (net paid, balance), v_payment_schedule_status (states), v_trip_check_board
      (payment_verified).
- Case B (the reminder): a second synthetic B2C case with an invoice sent with ONE row of 2400 due ops today - 2
  (overdue). MODE "dry_run": the bk_ops_reminders insert of `invoice.overdue` (staff + customer rows, key
  `invoice.overdue:<row>:<due>:d1`) is made twice in SQL with ON CONFLICT DO NOTHING -> one row per recipient type.
  MODE "apply": commits, then queues two manual `bk_ops_reminders` jobs (two idempotency keys) for the worker and
  waits up to POLL_SECONDS; the count of `invoice.overdue` rows of invoice B must stay 2 (staff + customer).

Idempotent per day: when today's synthetic case A already exists (an earlier apply), nothing is written again and the
current state is printed. Audit rows name the actor `script:aa682_s3_live_check`. Nothing is deleted. Prints codes,
statuses, amounts and counts only (no personal data): the Actions log of the public Infra repo is readable.

Modes (DB Migrate mode=run-script, as the RDS master; db/scripts/README.md): MODE = "dry_run" (this file as merged)
runs every write and check, prints the results and rolls everything back; a one-line follow-up PR sets MODE = "apply"
(leaves the synthetic cases, invoices and payments on Dev for the read-only API check and the screenshots). Needs bk-028
applied (refuses otherwise). Local test: `python3 aa682_s3_live_check.py <DSN> [--apply] [--no-wait]`.
"""

import asyncio
import json

MODE = "apply"

SCRIPT_NAME = "aa682_s3_live_check"
ACTOR = f"script:{SCRIPT_NAME}"
TAG = "SYNTHETIC S253 AA-682 S3"
NOTE_A = f"{TAG} A"
NOTE_B = f"{TAG} B"
CUSTOMER_EMAIL = "synthetic-aa682-s3@example.invalid"
MAKER = "synthetic-aa682-s3-maker"
CHECKER = "synthetic-aa682-s3-checker"
REQUIRED_VERSION = "bk-028"
WRITE_ROLE = "bk_owner"
DEFAULT_TZ = "Asia/Ho_Chi_Minh"
REMINDERS_KIND = "bk_ops_reminders"
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
    for key in (MAKER, CHECKER):
        await conn.execute(
            "INSERT INTO booking.staff_users (cis_user_id, role, active, name) VALUES ($1, 'admin', false, $2)"
            " ON CONFLICT (cis_user_id) DO NOTHING",
            key, f"{TAG} {key.rsplit('-', 1)[-1]}",
        )


async def _sold_case(conn, note: str, today, start_days: int) -> dict:
    """A synthetic B2C case inserted at confirmed (the seeding trigger adds its checks) + an approved, priced V1."""
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
        " source_system, notes) VALUES ($1::uuid, 'confirmed', $2::date + $3::int, $2::date + $3::int + 4, 2, 2,"
        " 'USD', 'manual', $4) RETURNING id::text AS id, code, start_date",
        customer, today, start_days, note,
    )
    await conn.execute("SELECT set_config('booking.status_note', '', true)")
    version = await conn.fetchval(
        "INSERT INTO booking.trip_case_versions (trip_case_id, version_number, title, total_price, currency, channel,"
        " fx_rate_locked, fx_as_of, is_sent_to_customer, sent_at, is_approved, approved_at)"
        " VALUES ($1::uuid, 1, $2, 2400, 'USD', 'b2c_tailor_made', 1, $3::date, true, now(), true, now())"
        " RETURNING id::text",
        case["id"], f"{TAG} V1", today,
    )
    out("write", what="sold_case", code=case["code"], status="confirmed", version_total="2400.00 USD")
    return {"id": case["id"], "code": case["code"], "start": case["start_date"], "version": version,
            "customer": customer}


async def _sent_invoice(conn, case: dict, schedule: list[tuple[str, str, object]], key: str) -> dict:
    inv = await conn.fetchrow(
        "INSERT INTO booking.invoices (trip_case_id, version_id, customer_id, currency, idempotency_key, request_sha256,"
        " created_by, updated_by) VALUES ($1::uuid, $2::uuid, $3::uuid, 'USD', $4, $5, $6, $6)"
        " RETURNING id::text AS id, invoice_number",
        case["id"], case["version"], case["customer"], key, SHA, MAKER,
    )
    await conn.execute(
        "INSERT INTO booking.invoice_items (invoice_id, position, kind, description, quantity, unit_price, amount,"
        " created_by) VALUES ($1::uuid, 1, 'version_total', $2, 1, 2400, 2400, $3)",
        inv["id"], f"Trip price ({TAG} V1)", MAKER,
    )
    for seq, (kind, amount, due) in enumerate(schedule, start=1):
        await conn.execute(
            "INSERT INTO booking.payment_schedule (invoice_id, seq, kind, amount, due_date, created_by)"
            " VALUES ($1::uuid, $2, $3, $4::numeric, $5, $6)",
            inv["id"], seq, kind, amount, due, MAKER,
        )
    await conn.execute(
        "UPDATE booking.invoices SET status = 'sent', issued_at = now(), sent_by = $2, bill_to_name = $3,"
        " bill_to_email = $4, updated_by = $2 WHERE id = $1::uuid",
        inv["id"], MAKER, f"{TAG} traveller", CUSTOMER_EMAIL,
    )
    await _audit(conn, "invoice.sent", "invoice", inv["id"], f"{case['code']} {inv['invoice_number']}",
                 {"status": "sent", "schedule": len(schedule)}, f"Sent {inv['invoice_number']} ({ACTOR})")
    out("write", what="invoice_sent", case=case["code"], invoice=inv["invoice_number"], rows=len(schedule))
    return {"id": inv["id"], "number": inv["invoice_number"]}


async def _advance(conn, case: dict, cause: str) -> str:
    """app/ops/track.advance_case in SQL: the case follows its sent invoice (B2C)."""
    status = await conn.fetchval("SELECT status FROM booking.trip_cases WHERE id = $1::uuid", case["id"])
    invoice = await conn.fetchval(
        "SELECT status FROM booking.invoices WHERE trip_case_id = $1::uuid AND deleted_at IS NULL"
        " AND status IN ('sent', 'partially_paid', 'paid')", case["id"],
    )
    target = {"sent": "invoice_sent", "partially_paid": "payment_pending", "paid": "paid"}.get(invoice or "")
    if target is None or target == status:
        return status
    await conn.execute("SELECT set_config('booking.actor', '', true), set_config('booking.status_note', $1, true)",
                       f"Auto: {cause} ({ACTOR})")
    await conn.execute("UPDATE booking.trip_cases SET status = $2 WHERE id = $1::uuid", case["id"], target)
    await conn.execute("SELECT set_config('booking.status_note', '', true)")
    await _audit(conn, "trip_case.status_changed", "trip_case", case["id"], case["code"],
                 {"status": target, "cause": cause}, f"{status} -> {target} (automatic: {cause}, {ACTOR})")
    return target


async def _record(conn, invoice: dict, amount: str, method: str, key: str) -> dict:
    row = await conn.fetchrow(
        "INSERT INTO booking.payments (invoice_id, kind, amount, currency, method, received_on, reference,"
        " idempotency_key, request_sha256, recorded_by, updated_by)"
        " VALUES ($1::uuid, 'receipt', $2::numeric, 'USD', $3, current_date, $4, $5, $6, $7, $7)"
        " RETURNING id::text AS id, ref",
        invoice["id"], amount, method, f"SYN-{key}", key, SHA, MAKER,
    )
    await _audit(conn, "payment.recorded", "payment", row["id"], f"{invoice['number']} {row['ref']}",
                 {"kind": "receipt", "amount": amount, "method": method, "reference": "(set)"},
                 f"Recorded {row['ref']} ({ACTOR})")
    return {"id": row["id"], "ref": row["ref"]}


async def _verify(conn, payment: dict, by: str) -> None:
    await conn.execute(
        "UPDATE booking.payments SET verified_by = $2, verified_at = now(), updated_by = $2 WHERE id = $1::uuid",
        payment["id"], by,
    )
    await _audit(conn, "payment.verified", "payment", payment["id"], payment["ref"], {"state": "verified"},
                 f"Verified {payment['ref']} ({ACTOR})")


async def _void(conn, payment: dict, reason: str) -> None:
    await conn.execute(
        "UPDATE booking.payments SET voided_at = now(), voided_by = $2, void_reason = $3, updated_by = $2"
        " WHERE id = $1::uuid",
        payment["id"], CHECKER, reason,
    )
    await _audit(conn, "payment.voided", "payment", payment["id"], payment["ref"], {"state": "voided"},
                 f"Voided {payment['ref']} ({ACTOR})")


async def _state(conn, case: dict, invoice: dict, step: str) -> tuple[str, str]:
    row = await conn.fetchrow(
        "SELECT i.status AS invoice, tc.status AS trip_case, b.net_paid::text AS net_paid, b.balance::text AS balance"
        " FROM booking.invoices i JOIN booking.trip_cases tc ON tc.id = i.trip_case_id"
        " JOIN booking.v_invoice_balance b ON b.invoice_id = i.id WHERE i.id = $1::uuid", invoice["id"],
    )
    out("state", step=step, invoice=invoice["number"], invoice_status=row["invoice"], case=case["code"],
        case_status=row["trip_case"], net_paid=row["net_paid"], balance=row["balance"])
    return row["invoice"], row["trip_case"]


async def _flow_a(conn, today) -> bool:
    case = await _sold_case(conn, NOTE_A, today, 40)
    invoice = await _sent_invoice(
        conn, case,
        [("deposit", "720", today.fromordinal(today.toordinal() + 3)),
         ("final", "1680", case["start"].fromordinal(case["start"].toordinal() - 30))],
        f"{SCRIPT_NAME}:A:{today}",
    )
    expected = []
    await _advance(conn, case, f"invoice {invoice['number']} sent")
    expected.append(await _state(conn, case, invoice, "sent") == ("sent", "invoice_sent"))
    refusals = [
        await _expect_refusal(conn, "invoice_status_paid_by_hand",
                              "UPDATE booking.invoices SET status = 'paid' WHERE id = $1::uuid", invoice["id"]),
        await _expect_refusal(conn, "case_status_paid_without_money",
                              "UPDATE booking.trip_cases SET status = 'paid' WHERE id = $1::uuid", case["id"]),
    ]
    transfer = await _record(conn, invoice, "720", "bank_transfer", "A-transfer")
    refusals.append(await _expect_refusal(
        conn, "verify_by_recorder_maker_checker",
        "UPDATE booking.payments SET verified_by = $2, verified_at = now() WHERE id = $1::uuid", transfer["id"], MAKER,
    ))
    refusals.append(await _expect_refusal(
        conn, "verify_without_evidence",
        "UPDATE booking.payments SET verified_by = $2, verified_at = now() WHERE id = $1::uuid", transfer["id"], CHECKER,
    ))
    refusals.append(await _expect_refusal(
        conn, "same_idempotency_key_twice",
        "INSERT INTO booking.payments (invoice_id, kind, amount, currency, method, received_on, idempotency_key,"
        " request_sha256, recorded_by) VALUES ($1::uuid, 'receipt', 720, 'USD', 'cash', current_date, 'A-transfer',"
        " $2, $3)", invoice["id"], SHA, MAKER,
    ))
    same_key = await conn.fetchval(
        "SELECT count(*)::int FROM booking.payments WHERE invoice_id = $1::uuid AND idempotency_key = 'A-transfer'",
        invoice["id"],
    )
    out("verify", what="one_payment_per_key", payments=same_key)
    await _void(conn, transfer, "synthetic: no evidence object on Dev, the cash path is used")
    deposit = await _record(conn, invoice, "720", "cash", "A-deposit")
    await _verify(conn, deposit, CHECKER)
    await _advance(conn, case, f"payment {deposit['ref']} verified")
    expected.append(await _state(conn, case, invoice, "deposit_verified") == ("partially_paid", "payment_pending"))
    balance = await _record(conn, invoice, "1680", "cash", "A-balance")
    await _verify(conn, balance, CHECKER)
    await _advance(conn, case, f"payment {balance['ref']} verified")
    expected.append(await _state(conn, case, invoice, "balance_verified") == ("paid", "paid"))
    board = await conn.fetchval(
        "SELECT payment_verified FROM booking.v_trip_check_board WHERE trip_case_id = $1::uuid", case["id"]
    )
    out("verify", what="check_board_payment_verified", case=case["code"], payment_verified=board)
    await _void(conn, balance, "synthetic: void path of the Done-when")
    await _advance(conn, case, f"payment {balance['ref']} voided")
    expected.append(await _state(conn, case, invoice, "balance_voided") == ("partially_paid", "payment_pending"))
    for r in await conn.fetch(
        "SELECT seq, kind, amount::text AS amount, covered_amount::text AS covered, state"
        " FROM booking.v_payment_schedule_status WHERE invoice_id = $1::uuid ORDER BY seq", invoice["id"],
    ):
        out("schedule", invoice=invoice["number"], seq=r["seq"], kind=r["kind"], amount=r["amount"],
            covered=r["covered"], state=r["state"])
    ok = all(expected) and all(refusals) and same_key == 1
    out("verify", what="flow_a", case=case["code"], invoice=invoice["number"], steps_ok=all(expected),
        refusals_ok=all(refusals))
    return ok


async def _overdue_rows(conn, invoice_id: str) -> int:
    return await conn.fetchval(
        "SELECT count(*)::int FROM booking.notifications WHERE type = 'invoice.overdue' AND entity_id = $1::uuid",
        invoice_id,
    )


async def _reminder_in_sql(conn, invoice: dict, customer: str) -> None:
    """The bk_ops_reminders overdue insert (app/ops/lifecycle._payment_reminders), staff + customer, ON CONFLICT."""
    row = await conn.fetchrow(
        "SELECT schedule_id::text AS id, due_date, days_overdue FROM booking.v_payment_schedule_status"
        " WHERE invoice_id = $1::uuid AND state = 'overdue' ORDER BY due_date LIMIT 1", invoice["id"],
    )
    if row is None:
        out("verify", what="overdue_row", found=False)
        return
    key = f"invoice.overdue:{row['id']}:{row['due_date'].isoformat()}:d1"
    data = json.dumps({"invoice_number": invoice["number"], "reminder_key": key})
    await conn.execute(
        "INSERT INTO booking.notifications (recipient_type, type, title, message, entity_type, entity_id, data)"
        " VALUES ('staff', 'invoice.overdue', $1, 'synthetic', 'invoice', $2::uuid, $3::jsonb) ON CONFLICT DO NOTHING",
        f"{invoice['number']} overdue ({TAG})", invoice["id"], data,
    )
    await conn.execute(
        "INSERT INTO booking.notifications (recipient_type, recipient_id, type, title, message, entity_type, entity_id,"
        " data) VALUES ('customer', $1::uuid, 'invoice.overdue', 'Payment overdue', 'synthetic', 'invoice', $2::uuid,"
        " $3::jsonb) ON CONFLICT DO NOTHING",
        customer, invoice["id"], data,
    )


async def _flow_b(conn, today, mode: str) -> tuple[bool, dict]:
    case = await _sold_case(conn, NOTE_B, today, 60)
    invoice = await _sent_invoice(conn, case, [("final", "2400", today.fromordinal(today.toordinal() - 2))],
                                  f"{SCRIPT_NAME}:B:{today}")
    await _advance(conn, case, f"invoice {invoice['number']} sent")
    state = await conn.fetchval(
        "SELECT state FROM booking.v_payment_schedule_status WHERE invoice_id = $1::uuid", invoice["id"]
    )
    out("verify", what="overdue_schedule_row", invoice=invoice["number"], state=state)
    if mode == "apply":
        return state == "overdue", invoice
    await _reminder_in_sql(conn, invoice, case["customer"])
    await _reminder_in_sql(conn, invoice, case["customer"])
    rows = await _overdue_rows(conn, invoice["id"])
    out("verify", what="overdue_reminder_once_per_key", invoice=invoice["number"], rows=rows, expected=2)
    return state == "overdue" and rows == 2, invoice


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
        out("job", id=r["id"], status=r["status"], payments_overdue=res.get("payments_overdue"),
            payments_notified=res.get("payments_notified"), customer_rows=res.get("customer_rows"), error=r["error"])


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
            "SELECT tc.code, tc.status, i.invoice_number, i.status AS invoice_status FROM booking.trip_cases tc"
            " LEFT JOIN booking.invoices i ON i.trip_case_id = tc.id AND i.deleted_at IS NULL"
            " WHERE tc.notes = $1 AND tc.created_at::date = $2 AND tc.deleted_at IS NULL"
            " ORDER BY tc.created_at DESC LIMIT 1",
            NOTE_A, today,
        )
        if existing is not None:
            out("reused", case=existing["code"], case_status=existing["status"], invoice=existing["invoice_number"],
                invoice_status=existing["invoice_status"])
            await tx.rollback()
            return 0
        await _staff(conn)
        ok_a = await _flow_a(conn, today)
        ok_b, invoice_b = await _flow_b(conn, today, mode)
        counts = await conn.fetchrow(
            "SELECT count(*)::int AS invoices, count(*) FILTER (WHERE status IN ('sent', 'partially_paid'))::int AS open,"
            " (SELECT count(*)::int FROM booking.payments) AS payments FROM booking.invoices WHERE deleted_at IS NULL"
        )
        out("counts", invoices=counts["invoices"], open_invoices=counts["open"], payments=counts["payments"])
        ok = ok_a and ok_b
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
            rows = await _overdue_rows(conn, invoice_b["id"])
            out("verify", what="overdue_reminder_once_per_key", invoice=invoice_b["number"], rows=rows, expected=2)
    else:
        await tx.rollback()
        out("rolled_back", reason="dry_run" if mode != "apply" else "verdict not ok")
    return 0 if ok else 1


async def main(conn):
    return await run(conn, MODE)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse

    import asyncpg

    parser = argparse.ArgumentParser(description="AA-682 S3 live check on synthetic cases (DRY RUN by default)")
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
