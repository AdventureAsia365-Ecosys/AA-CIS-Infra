"""AA-682 S1 (S252), Dev only: the live check of supplier bookings (AA-Booking bk-026) on a synthetic trip case.

Why a script: the agent's only Dev staff session (the AA-910 E2E admin) and every preview session are read-only, so
the S1 writes cannot be made through the staff API by an agent (S252 design §2 note, critic B8). This script makes the
same writes the Booking service makes, in SQL, as `bk_owner`, so the bk-026 triggers (edges, fact guard, supply view,
outbox trigger of the B2B line) run for real on Dev. The API part is then checked read-only: `GET
/booking/trip-cases/{code}/supplier-bookings` (supply `booked`), `GET /booking/trip-cases/{code}` (`supply`), the
staff UI screenshots, and for the B2B part `GET /booking/b2b/v1/events` (CRM client).

What it does, in one transaction (MODE "dry_run" rolls it back at the end, "apply" commits):
- B2C: a synthetic supplier (`SYNTHETIC S252 AA-682 Supplier`) with a hotel room type and a service; a synthetic
  customer (no real person: `synthetic-aa682-s1@example.invalid`); a trip case at `confirmed`, start = today + 60 days,
  notes `SYNTHETIC S252 AA-682 S1`, with an approved V1 of two supply items and their USD cost rows; then two supplier
  bookings `pending` → `requested` (the case moves `confirmed → supplier_confirming`, a system move with an "Auto:"
  status note, as app/ops/supplier_bookings.advance_case does) → `confirmed` with a ref. Checks (each in a savepoint, so
  a refusal is the expected outcome): an illegal edge (`pending → confirmed`) and B2C `pre_departure` are refused by
  the database, a second live booking of one item hits the unique index, the supply view reads `booked`.
- B2B (optional): if the AA-973 seed partner (tenant `00000000-0000-4000-8000-00000000c972`) has a confirmed hold with
  a line still `on_request`, one supplier booking is linked to it, requested and confirmed, and the line is accepted
  with the same UPDATE as app/b2b/desk.answer_line, so the bk-022 trigger writes `line.confirmed` to `booking.outbox`
  (checked here; the agency feed shows it after the next stamp). Otherwise `SCRIPT skip what=b2b` (book a room on
  request through the CRM E2E first, then run again).

Idempotent per day: the synthetic case of today is reused (its bookings are not generated twice: the unique live index).
Audit rows name the actor `script:aa682_s1_live_check`. Nothing is deleted. Prints codes, ids, statuses and counts
only (no net amount, no personal data): the Actions log of this public repo is readable.

Modes (DB Migrate mode=run-script, as the RDS master; db/scripts/README.md): MODE = "dry_run" (this file as merged)
runs every write and check, prints the results and rolls everything back; a one-line follow-up PR sets MODE = "apply".
Needs bk-026 applied (refuses otherwise). Local test: `python3 db/scripts/aa682_s1_live_check.py <DSN> [--apply]`.
"""

import json

MODE = "dry_run"

SCRIPT_NAME = "aa682_s1_live_check"
ACTOR = f"script:{SCRIPT_NAME}"
TAG = "SYNTHETIC S252 AA-682"
CASE_NOTE = f"{TAG} S1"
SUPPLIER_NAME = f"{TAG} Supplier"
CUSTOMER_EMAIL = "synthetic-aa682-s1@example.invalid"
SEED_TENANT = "00000000-0000-4000-8000-00000000c972"
REQUIRED_VERSION = "bk-026"
WRITE_ROLE = "bk_owner"
LIVE = ("pending", "requested", "confirmed")


class Refused(Exception):
    pass


def out(kind: str, **values) -> None:
    parts = " ".join(f"{k}={v}" for k, v in values.items())
    print(f"SCRIPT {kind} {parts}".rstrip(), flush=True)


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


async def _advance(conn, case_id: str, code: str, cause: str) -> str | None:
    """app/ops/supplier_bookings.advance_case, in SQL."""
    row = await conn.fetchrow(
        "SELECT tc.status, count(sb.*) FILTER (WHERE sb.status IN ('pending', 'requested', 'confirmed')) AS live,"
        " count(sb.*) FILTER (WHERE sb.status IN ('requested', 'confirmed')) AS asked"
        " FROM booking.trip_cases tc LEFT JOIN booking.supplier_bookings sb ON sb.trip_case_id = tc.id"
        " WHERE tc.id = $1::uuid GROUP BY tc.status",
        case_id,
    )
    target = None
    if row["status"] == "confirmed" and row["asked"] > 0:
        target = "supplier_confirming"
    elif row["status"] == "supplier_confirming" and row["live"] == 0:
        target = "confirmed"
    if target is None:
        return None
    await conn.execute("SELECT set_config('booking.actor', '', true), set_config('booking.status_note', $1, true)",
                       f"Auto: {cause} ({ACTOR})")
    await conn.execute("UPDATE booking.trip_cases SET status = $2 WHERE id = $1::uuid", case_id, target)
    await conn.execute("SELECT set_config('booking.status_note', '', true)")
    await _audit(conn, "trip_case.status_changed", "trip_case", case_id, code,
                 {"status": target, "cause": cause}, f"{row['status']} -> {target} (automatic: {cause})")
    out("advance", case=code, status=target)
    return target


async def _b2c(conn, today) -> dict:
    supplier = await conn.fetchval("SELECT id::text FROM booking.suppliers WHERE company_name = $1", SUPPLIER_NAME)
    if supplier is None:
        supplier = await conn.fetchval(
            "INSERT INTO booking.suppliers (company_name, categories, country_code) VALUES ($1, ARRAY['hotel', 'activity'],"
            " 'VN') RETURNING id::text",
            SUPPLIER_NAME,
        )
        hotel = await conn.fetchval(
            "INSERT INTO booking.hotels (supplier_id, name) VALUES ($1::uuid, $2) RETURNING id::text",
            supplier, f"{TAG} Hotel",
        )
        await conn.execute(
            "INSERT INTO booking.hotel_room_types (hotel_id, name) VALUES ($1::uuid, 'Synthetic double')", hotel
        )
        await conn.execute(
            "INSERT INTO booking.services (supplier_id, service_type, title) VALUES ($1::uuid, 'activity', $2)",
            supplier, f"{TAG} kayak",
        )
        out("write", what="supplier", id=supplier)
    room = await conn.fetchval(
        "SELECT rt.id::text FROM booking.hotel_room_types rt JOIN booking.hotels h ON h.id = rt.hotel_id"
        " WHERE h.supplier_id = $1::uuid LIMIT 1", supplier,
    )
    service = await conn.fetchval("SELECT id::text FROM booking.services WHERE supplier_id = $1::uuid LIMIT 1", supplier)

    case = await conn.fetchrow(
        "SELECT id::text AS id, code, status FROM booking.trip_cases WHERE notes = $1 AND created_at::date = $2"
        " AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1",
        CASE_NOTE, today,
    )
    if case is None:
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
            " source_system, notes) VALUES ($1::uuid, 'confirmed', $2::date + 60, $2::date + 64, 2, 2, 'USD', 'manual', $3)"
            " RETURNING id::text AS id, code, status",
            customer, today, CASE_NOTE,
        )
        version = await conn.fetchval(
            "INSERT INTO booking.trip_case_versions (trip_case_id, version_number, title, total_price, currency)"
            " VALUES ($1::uuid, 1, $2, 2400, 'USD') RETURNING id::text",
            case["id"], f"{TAG} V1",
        )
        for position, (title, day_from, day_to, col, ref, net) in enumerate(
            (("Two nights", 1, 3, "hotel_room_type_id", room, "400.00"), ("Kayak", 3, 3, "service_id", service, "80.00")),
            start=1,
        ):
            item = await conn.fetchval(
                "INSERT INTO booking.trip_case_version_itinerary (trip_case_version_id, position, title, day_from, day_to,"  # noqa: S608
                f" {col}) VALUES ($1::uuid, $2, $3, $4, $5, $6::uuid) RETURNING id::text",
                version, position, title, day_from, day_to, ref,
            )
            await conn.execute(
                "INSERT INTO booking.version_item_costs (version_item_id, net_amount, net_currency, supplier_note)"
                " VALUES ($1::uuid, $2::numeric, 'USD', $3)",
                item, net, TAG,
            )
        await conn.execute(
            "UPDATE booking.trip_case_versions SET is_approved = true, approved_at = now(), approval_note = $2"
            " WHERE id = $1::uuid",
            version, f"{TAG}: approved for the live check",
        )
        out("write", what="trip_case", code=case["code"], status="confirmed")

    # Generate (as app/ops/supplier_bookings.generate): one pending booking per supply item without a live one.
    # Room nights follow app/ops/supplier_bookings._nights: B2B day_to - day_from + 1 (holds._open_case), B2C the
    # pricing rule supply_rates.quantity('room_night') = max(day_to - day_from, 1). The B2C room item spans days 1-3
    # (check in day 1, out day 3): 2 nights, the nights its 400.00 net was costed for.
    created = await conn.fetch(
        "INSERT INTO booking.supplier_bookings (trip_case_id, version_item_id, supplier_id, hotel_room_type_id,"
        " service_id, item_description, service_date, nights, pax, net_amount, net_currency)"
        " SELECT tc.id, i.id, coalesce(h.supplier_id, sv.supplier_id), i.hotel_room_type_id, i.service_id, i.title,"
        "        tc.start_date + (i.day_from - 1), CASE WHEN i.hotel_room_type_id IS NULL THEN NULL"
        "        WHEN tc.channel = 'b2b' THEN i.day_to - i.day_from + 1"
        "        ELSE greatest(i.day_to - i.day_from, 1) END, tc.pax,"
        "        (SELECT sum(c.net_amount) FROM booking.version_item_costs c WHERE c.version_item_id = i.id), 'USD'"
        " FROM booking.trip_cases tc"
        " JOIN booking.trip_case_versions v ON v.trip_case_id = tc.id AND v.is_approved AND v.deleted_at IS NULL"
        " JOIN booking.trip_case_version_itinerary i ON i.trip_case_version_id = v.id"
        " LEFT JOIN booking.hotel_room_types rt ON rt.id = i.hotel_room_type_id"
        " LEFT JOIN booking.hotels h ON h.id = rt.hotel_id"
        " LEFT JOIN booking.services sv ON sv.id = i.service_id"
        " WHERE tc.id = $1::uuid AND (i.hotel_room_type_id IS NOT NULL OR i.service_id IS NOT NULL)"
        " ON CONFLICT (version_item_id) WHERE status IN ('pending', 'requested', 'confirmed')"
        " AND version_item_id IS NOT NULL DO NOTHING RETURNING id::text, code",
        case["id"],
    )
    out("write", what="supplier_bookings_generated", case=case["code"], created=len(created))
    room_nights = await conn.fetchval(
        "SELECT nights FROM booking.supplier_bookings WHERE trip_case_id = $1::uuid AND hotel_room_type_id IS NOT NULL"
        " AND status IN ('pending', 'requested', 'confirmed') LIMIT 1", case["id"],
    )
    out("verify", what="b2c_room_nights", case=case["code"], nights=room_nights, expected=2)
    rows = await conn.fetch(
        "SELECT id::text AS id, code, status, version_item_id::text AS item FROM booking.supplier_bookings"
        " WHERE trip_case_id = $1::uuid AND status IN ('pending', 'requested', 'confirmed') ORDER BY code",
        case["id"],
    )
    first = rows[0]
    if first["status"] == "pending":
        await _expect_refusal(
            conn, "illegal_edge_pending_to_confirmed",
            "UPDATE booking.supplier_bookings SET status = 'confirmed', confirmation_ref = 'X', confirmed_at = now()"
            " WHERE id = $1::uuid", first["id"],
        )
    await _expect_refusal(
        conn, "second_live_booking_of_one_item",
        "INSERT INTO booking.supplier_bookings (trip_case_id, version_item_id, supplier_id, item_description)"
        " VALUES ($1::uuid, $2::uuid, $3::uuid, 'duplicate')", case["id"], first["item"], supplier,
    )
    for r in rows:
        if r["status"] == "pending":
            await conn.execute(
                "UPDATE booking.supplier_bookings SET status = 'requested', requested_at = now() WHERE id = $1::uuid",
                r["id"],
            )
            await _audit(conn, "supplier_booking.requested", "supplier_booking", r["id"], f"{case['code']} {r['code']}",
                         {"status": "requested"}, f"Requested {r['code']} ({ACTOR})")
            await _advance(conn, case["id"], case["code"], f"supplier booking {r['code']} requested")
    for r in rows:
        if r["status"] != "confirmed":
            await conn.execute(
                "UPDATE booking.supplier_bookings SET status = 'confirmed', confirmation_ref = $2, confirmed_at = now()"
                " WHERE id = $1::uuid", r["id"], f"SYN-{r['code']}",
            )
            await _audit(conn, "supplier_booking.confirmed", "supplier_booking", r["id"], f"{case['code']} {r['code']}",
                         {"status": "confirmed"}, f"Confirmed {r['code']} ({ACTOR})")
    await _expect_refusal(conn, "b2c_pre_departure_before_bk028",
                          "UPDATE booking.trip_cases SET status = 'pre_departure' WHERE id = $1::uuid", case["id"])
    await _expect_refusal(conn, "money_status_without_edge",
                          "UPDATE booking.trip_cases SET status = 'invoice_sent' WHERE id = $1::uuid", case["id"])
    state = await conn.fetchrow(
        "SELECT state, items_to_book, items_booked, live, confirmed FROM booking.v_trip_case_supply_state"
        " WHERE trip_case_id = $1::uuid", case["id"],
    )
    status = await conn.fetchval("SELECT status FROM booking.trip_cases WHERE id = $1::uuid", case["id"])
    out("verify", what="b2c", case=case["code"], case_status=status, supply=state["state"],
        items_booked=f"{state['items_booked']}/{state['items_to_book']}", live=state["live"], confirmed=state["confirmed"])
    return {"case": case["code"], "case_status": status, "supply": state["state"]}


async def _b2b(conn) -> dict | None:
    line = await conn.fetchrow(
        "SELECT l.hold_id::text AS hold_id, l.line_ref, l.line_no, h.trip_case_id::text AS case_id, c.code,"
        "       c.status AS case_status"
        " FROM booking.b2b_hold_lines l"
        " JOIN booking.b2b_holds h ON h.id = l.hold_id AND h.status = 'confirmed'"
        " JOIN booking.b2b_partners p ON p.id = h.partner_id AND p.tenant_id = $1::uuid"
        " JOIN booking.trip_cases c ON c.id = h.trip_case_id"
        " WHERE l.held_as = 'on_request' AND l.status = 'on_request'"
        "   AND c.status IN ('confirmed', 'supplier_confirming')"
        " ORDER BY h.confirmed_at DESC LIMIT 1",
        SEED_TENANT,
    )
    if line is None:
        out("skip", what="b2b", why="no confirmed seed-partner hold with a line still on_request; book a room on request"
            " through the CRM E2E, then run again")
        return None
    item = await conn.fetchrow(
        "SELECT i.id::text AS id, i.title, i.hotel_room_type_id::text AS room, i.service_id::text AS service,"
        "       coalesce(h.supplier_id, sv.supplier_id)::text AS supplier"
        " FROM booking.trip_case_versions v JOIN booking.trip_case_version_itinerary i ON i.trip_case_version_id = v.id"
        " LEFT JOIN booking.hotel_room_types rt ON rt.id = i.hotel_room_type_id"
        " LEFT JOIN booking.hotels h ON h.id = rt.hotel_id LEFT JOIN booking.services sv ON sv.id = i.service_id"
        " WHERE v.trip_case_id = $1::uuid AND v.is_approved AND i.position = $2",
        line["case_id"], line["line_no"],
    )
    if item is None or item["supplier"] is None:
        out("skip", what="b2b", why="the on-request line's item books no supplier")
        return None
    booking = await conn.fetchrow(
        "INSERT INTO booking.supplier_bookings (trip_case_id, version_item_id, supplier_id, hotel_room_type_id,"
        " service_id, item_description, b2b_hold_id, b2b_line_ref) VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid,"
        " $5::uuid, $6, $7::uuid, $8) RETURNING id::text, code",
        line["case_id"], item["id"], item["supplier"], item["room"], item["service"], item["title"][:500],
        line["hold_id"], line["line_ref"],
    )
    await conn.execute(
        "UPDATE booking.supplier_bookings SET status = 'requested', requested_at = now() WHERE id = $1::uuid",
        booking["id"],
    )
    await _advance(conn, line["case_id"], line["code"], f"supplier booking {booking['code']} requested")
    await conn.execute("SELECT 1 FROM booking.b2b_holds WHERE id = $1::uuid FOR UPDATE", line["hold_id"])
    await conn.execute(
        "UPDATE booking.supplier_bookings SET status = 'confirmed', confirmation_ref = $2, confirmed_at = now()"
        " WHERE id = $1::uuid", booking["id"], f"SYN-{booking['code']}",
    )
    # app/b2b/desk.answer_line (accept): the bk-022 trigger writes line.confirmed to booking.outbox.
    await conn.execute(
        "UPDATE booking.b2b_hold_lines SET status = 'confirmed', decline_code = NULL, answered_at = now(),"
        " answered_by = NULL WHERE hold_id = $1::uuid AND line_ref = $2",
        line["hold_id"], line["line_ref"],
    )
    await _audit(conn, "supplier_booking.confirmed", "supplier_booking", booking["id"],
                 f"{line['code']} {booking['code']}", {"status": "confirmed", "b2b_line": line["line_ref"]},
                 f"Confirmed {booking['code']}; B2B line {line['line_ref']} accepted ({ACTOR})")
    events = await conn.fetchval(
        "SELECT count(*) FROM booking.outbox WHERE stream = 'b2b' AND event_type = 'line.confirmed'"
        " AND hold_id = $1::uuid AND line_ref = $2",
        line["hold_id"], line["line_ref"],
    )
    supply = await conn.fetchval(
        "SELECT state FROM booking.v_trip_case_supply_state WHERE trip_case_id = $1::uuid", line["case_id"]
    )
    out("verify", what="b2b", case=line["code"], supplier_booking=booking["code"], line=line["line_ref"],
        outbox_line_confirmed=events, supply=supply)
    return {"case": line["code"], "events": events}


async def run(conn, apply: bool) -> int:
    out(SCRIPT_NAME, mode="APPLY" if apply else "DRY_RUN")
    if not await conn.fetchval("SELECT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = $1)",
                               REQUIRED_VERSION):
        out("refuse", why=f"{REQUIRED_VERSION} is not applied")
        return 1
    today = await conn.fetchval("SELECT (now() AT TIME ZONE 'UTC')::date")
    tx = conn.transaction()
    await tx.start()
    try:
        await conn.execute(f"SET LOCAL ROLE {WRITE_ROLE}")
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext($1))", SCRIPT_NAME)
        b2c = await _b2c(conn, today)
        b2b = await _b2b(conn)
        ok = b2c["case_status"] == "supplier_confirming" and b2c["supply"] == "booked" and (b2b is None or b2b["events"] >= 1)
        out("verdict", ok=ok, applied=apply, b2b_checked=b2b is not None)
    except BaseException:
        await tx.rollback()
        raise
    if apply and ok:
        await tx.commit()
    else:
        await tx.rollback()
        out("rolled_back", reason="dry_run" if not apply else "verdict not ok")
    return 0 if ok else 1


async def main(conn):
    return await run(conn, apply=MODE == "apply")


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse
    import asyncio

    import asyncpg

    parser = argparse.ArgumentParser(description="AA-682 S1 live check on a synthetic case (DRY RUN by default)")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="commit (default: run and roll back)")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, apply=args.apply)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
