"""AA-682 S5 (S254), Dev only, READ ONLY: the scope of My Payments (AA-Booking /booking/customer/v1) on the S253
synthetic invoices. Draft for AA-CIS-Infra db/scripts/aa682_s5_live_check.py (the orchestrator copies it there; it is
not part of the Booking repo).

Why a script: no agent can sign in as a traveller whose Booking customer has an invoice (the S253 synthetic customer
`synthetic-aa682-s3@example.invalid` has no sign-in identity, and none is created here). So the check runs the SAME
scope SQL as `app/ops/my_payments.py` (copied below; a run-script may not import Booking code) for:

- the synthetic customer (owner of the S253 cases tagged `SYNTHETIC S253 AA-682 S3 A` / `... B`): every visible
  invoice must be one of its own, sent or later (never a draft), each with its schedule states and verified payments;
- a different live customer (any other one, else a random UUID): none of the synthetic numbers is visible, and the
  one-number query for each synthetic number returns nothing (the API answers 404 `invoice_not_found`);
- the counts of drafts / B2B / deleted invoices excluded by the scope (all invoices of the customer minus visible).

The API side is checked separately, read only: `curl` both routes on the Dev API with no token, with a staff token and
with a bad token -> 401 `{"detail":"sign_in_required"}`; TripPlanner `/api/me/payments` without a session -> 401.

Prints invoice numbers, statuses, amounts and counts only (no personal data: the Actions log is readable).
Local test: `python3 aa682_s5_live_check.py <DSN>`.
"""

import asyncio

READ_ONLY = True

TAG = "SYNTHETIC S253 AA-682 S3"
CUSTOMER_EMAIL = "synthetic-aa682-s3@example.invalid"
REQUIRED_VERSION = "bk-028"

# Same scope as AA-Booking app/ops/my_payments.py (OWN_INVOICES, INVOICE_COLUMNS, SCHEDULE_SQL, PAYMENTS_SQL).
OWN_INVOICES = """
  FROM booking.invoices i
  JOIN booking.trip_cases tc ON tc.id = i.trip_case_id
  JOIN booking.v_invoice_balance b ON b.invoice_id = i.id
 WHERE tc.customer_id = $1::uuid
   AND tc.channel = 'b2c'
   AND tc.deleted_at IS NULL
   AND i.bill_to_kind = 'customer'
   AND i.deleted_at IS NULL
   AND i.status <> 'draft'
"""
INVOICE_COLUMNS = """
SELECT i.id::text AS id, i.invoice_number, i.status, i.currency, i.total_amount::text AS total_amount,
       b.net_paid::text AS paid_amount, b.balance::text AS balance, b.next_due_date, b.overdue_amount::text AS overdue,
       tc.code AS trip_code
"""
LIST_SQL = INVOICE_COLUMNS + OWN_INVOICES + " ORDER BY i.issued_at DESC, i.invoice_number DESC LIMIT 50"
ONE_SQL = INVOICE_COLUMNS + OWN_INVOICES + " AND i.invoice_number = $2"
SCHEDULE_SQL = """
SELECT s.seq, s.kind, s.amount::text AS amount, s.state FROM booking.v_payment_schedule_status s
 WHERE s.invoice_id = $1::uuid ORDER BY s.due_date, s.seq
"""
PAYMENTS_SQL = """
SELECT count(*) FILTER (WHERE p.verified_at IS NOT NULL AND p.voided_at IS NULL) AS shown,
       count(*) FILTER (WHERE p.verified_at IS NULL AND p.voided_at IS NULL) AS waiting,
       count(*) FILTER (WHERE p.voided_at IS NOT NULL) AS voided
  FROM booking.payments p WHERE p.invoice_id = $1::uuid
"""


def out(msg: str) -> None:
    print(f"SCRIPT {msg}", flush=True)


async def main(conn) -> int:
    done = await conn.fetchval("SELECT 1 FROM shared.schema_versions WHERE version = $1", REQUIRED_VERSION)
    if not done:
        out(f"refused: {REQUIRED_VERSION} is not applied")
        return 1
    customer = await conn.fetchval(
        "SELECT id::text FROM booking.customers WHERE email = $1 AND deleted_at IS NULL", CUSTOMER_EMAIL
    )
    if customer is None:
        out("refused: the S253 synthetic customer does not exist (run aa682_s3_live_check apply first)")
        return 1
    identities = await conn.fetchval(
        "SELECT count(*) FROM booking.customer_identities WHERE customer_id = $1::uuid", customer
    )
    out(f"synthetic customer found; sign-in identities linked: {identities} (expected 0: no live traveller sees it)")

    total = await conn.fetchval(
        "SELECT count(*) FROM booking.invoices i JOIN booking.trip_cases tc ON tc.id = i.trip_case_id"
        " WHERE tc.customer_id = $1::uuid",
        customer,
    )
    visible = await conn.fetch(LIST_SQL, customer)
    out(f"invoices of the customer: {total}; visible on My Payments: {len(visible)}")
    problems = 0
    for row in visible:
        if row["status"] == "draft":
            problems += 1
        sched = await conn.fetch(SCHEDULE_SQL, row["id"])
        pays = await conn.fetchrow(PAYMENTS_SQL, row["id"])
        out(
            f"{row['invoice_number']} case {row['trip_code']} status {row['status']} {row['currency']}"
            f" total {row['total_amount']} paid {row['paid_amount']} balance {row['balance']}"
            f" next_due {row['next_due_date']} overdue {row['overdue']}"
            f" | schedule {[(s['seq'], s['kind'], s['amount'], s['state']) for s in sched]}"
            f" | payments shown {pays['shown']} (hidden: waiting {pays['waiting']}, voided {pays['voided']})"
        )
        same = await conn.fetchrow(ONE_SQL, customer, row["invoice_number"])
        if same is None:
            problems += 1
            out(f"PROBLEM {row['invoice_number']}: listed but not found by number")

    other = await conn.fetchval(
        "SELECT id::text FROM booking.customers WHERE id <> $1::uuid AND deleted_at IS NULL ORDER BY created_at LIMIT 1",
        customer,
    )
    other = other or "00000000-0000-4000-8000-000000000000"
    leaked = [r["invoice_number"] for r in visible if await conn.fetchrow(ONE_SQL, other, r["invoice_number"])]
    other_list = {r["invoice_number"] for r in await conn.fetch(LIST_SQL, other)}
    leaked += [r["invoice_number"] for r in visible if r["invoice_number"] in other_list]
    out(f"another customer: sees {len(other_list)} invoice(s); synthetic numbers visible to it: {sorted(set(leaked))}")
    problems += len(set(leaked))

    if problems:
        out(f"FAILED: {problems} problem(s)")
        return 1
    out(f"OK: {TAG} invoices are visible to their own customer only, never as a draft")
    return 0


if __name__ == "__main__":  # local test: python3 aa682_s5_live_check.py <DSN>
    import sys

    import asyncpg

    async def _local() -> int:
        conn = await asyncpg.connect(sys.argv[1])
        try:
            return await main(conn)
        finally:
            await conn.close()

    sys.exit(asyncio.run(_local()))
