"""AA-682 S2 (S253), Dev only: the live check of trip checks and the case lifecycle (AA-Booking bk-027) on synthetic
trip cases. Draft for AA-CIS-Infra db/scripts/aa682_s2_live_check.py (the orchestrator copies it there).

Why a script: the agent's only Dev staff session (the AA-910 E2E admin) and every preview session are read-only, so the
S2 writes cannot be made through the staff API by an agent (S252 design §2 note, critic B8). A run-script may not import
Booking code, so it makes the writes the service makes, in SQL, as `bk_owner`; the bk-027 triggers (seeding on
`confirmed`, the check guard) and the bk-026 fact guard run for real. The API part is then checked read-only:
`GET /booking/trip-cases/{code}/checks`, `GET /booking/trip-checks?q=SYN`, `GET /booking/case-lifecycle/runs`, the staff
UI screenshots.

What it does, in one transaction (MODE "dry_run" rolls it back at the end, "apply" commits):
- B2B: a synthetic B2B trip case (no customer, synthetic agency tenant `...0a6822`, notes `SYNTHETIC S253 AA-682 S2
  B2B`) INSERTED at `confirmed` the way the B2B confirm does, start = ops today - 3, end = ops today - 1, nothing to
  book (supply `none`). Shows the three seeded checks (emergency contact `not_applicable`) and checks, each in a
  savepoint (the refusal is the expected outcome): an emergency contact on the B2B case, reopening that row, a second
  standard row.
- B2C: a synthetic customer (`synthetic-aa682-s2@example.invalid`, no real person) and a case at `proposal_sent`,
  start = ops today + 30, moved to `confirmed` by an UPDATE (the version-approval path): three checks seeded, all open;
  the synthetic emergency contact is entered and the check marked done; a custom check is added.
- The board view rows of both cases (stored counts, derived `suppliers_confirmed`, `payment_verified` NULL).
- The lifecycle step:
  * MODE "dry_run": the moves `bk_case_lifecycle` makes, in SQL (same statements as app/ops/lifecycle._move: ops time
    zone for the transaction, empty actor, "Auto: travel dates" note, a system audit row), on the B2B case:
    confirmed -> pre_departure -> on_trip -> completed, each accepted by the bk-026 guard; B2C stays confirmed (its
    pre-departure date is 16 days away; and a B2C case needs `paid`, bk-028). Then everything is rolled back.
  * MODE "apply": commits the synthetic cases at `confirmed` and queues two real jobs for the worker: a manual LIVE run
    scoped to the synthetic B2B case (`case_ids`) and an unscoped manual DRY RUN over every case (what the daily run
    would do on Dev). It then waits up to POLL_SECONDS for both and prints their results (mode, moves, blocked, cleared
    counts; case codes only). The synthetic B2B case should end `completed`.
  * MODE "go_live" (a later one-line PR, after Nghiệp / the orchestrator read the unscoped DRY RUN result): queues one
    unscoped manual LIVE run; from then on the daily scheduled run is live (DM-7.2). Writes nothing else.

Idempotent per day: today's synthetic cases are reused (the seeding is ON CONFLICT DO NOTHING; the custom check is added
once). Audit rows name the actor `script:aa682_s2_live_check`. Nothing is deleted. Prints codes, ids, statuses and
counts only (no personal data): the Actions log of the public Infra repo is readable.

Modes (DB Migrate mode=run-script, as the RDS master; db/scripts/README.md): MODE = "dry_run" (this file as merged)
runs every write and check, prints the results and rolls everything back; a one-line follow-up PR sets MODE = "apply",
another one "go_live". Needs bk-027 applied (refuses otherwise). Local test:
`python3 aa682_s2_live_check.py <DSN> [--apply | --go-live] [--no-wait]`.
"""

import asyncio
import json

MODE = "apply"

SCRIPT_NAME = "aa682_s2_live_check"
ACTOR = f"script:{SCRIPT_NAME}"
TAG = "SYNTHETIC S253 AA-682 S2"
B2B_NOTE = f"{TAG} B2B"
B2C_NOTE = f"{TAG} B2C"
CUSTOMER_EMAIL = "synthetic-aa682-s2@example.invalid"
SYNTHETIC_TENANT = "00000000-0000-4000-8000-0000000a6822"
REQUIRED_VERSION = "bk-027"
WRITE_ROLE = "bk_owner"
DEFAULT_TZ = "Asia/Ho_Chi_Minh"
KIND = "bk_case_lifecycle"
POLL_SECONDS = 90
TRAVEL = ("pre_departure", "on_trip", "completed")


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


async def _ops_zone(conn) -> str:
    raw = await conn.fetchval("SELECT value #>> '{}' FROM booking.settings WHERE key = 'b2b_ops_timezone'")
    if raw and await conn.fetchval("SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1)", raw):
        return raw
    return DEFAULT_TZ


async def _checks(conn, case_id: str, code: str) -> list:
    rows = await conn.fetch(
        "SELECT id::text AS id, code, status, due_date, (emergency_contact_name IS NOT NULL) AS has_contact"
        " FROM booking.trip_case_checks WHERE trip_case_id = $1::uuid ORDER BY (code = 'custom'), code, created_at",
        case_id,
    )
    for r in rows:
        out("seeded", case=code, check=r["code"], status=r["status"], due=r["due_date"], contact=r["has_contact"])
    return rows


async def _b2b(conn, today) -> dict:
    case = await conn.fetchrow(
        "SELECT id::text AS id, code, status FROM booking.trip_cases WHERE notes = $1 AND created_at::date = $2"
        " AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1",
        B2B_NOTE, today,
    )
    if case is None:
        await conn.execute("SELECT set_config('booking.actor', '', true), set_config('booking.status_note', $1, true)",
                           f"{ACTOR}: synthetic B2B case inserted at confirmed (as holds._open_case)")
        case = await conn.fetchrow(
            "INSERT INTO booking.trip_cases (channel, party_tenant_id, status, start_date, end_date, pax, pax_adults,"
            " currency, source_system, notes) VALUES ('b2b', $1::uuid, 'confirmed', $2::date - 3, $2::date - 1, 2, 2,"
            " 'USD', 'crm', $3) RETURNING id::text AS id, code, status",
            SYNTHETIC_TENANT, today, B2B_NOTE,
        )
        await conn.execute("SELECT set_config('booking.status_note', '', true)")
        out("write", what="b2b_trip_case", code=case["code"], status="confirmed")
    rows = await _checks(conn, case["id"], case["code"])
    contact = next((r for r in rows if r["code"] == "emergency_contact"), None)
    ok = len([r for r in rows if r["code"] != "custom"]) == 3 and contact is not None and contact["status"] == "not_applicable"
    out("verify", what="b2b_seeded", case=case["code"], standard_checks=len(rows), contact_not_applicable=ok)
    if contact is not None:
        await _expect_refusal(
            conn, "b2b_emergency_contact_write",
            "UPDATE booking.trip_case_checks SET emergency_contact_name = 'SYNTHETIC', emergency_contact_phone ="
            " '+84 00 000 0000' WHERE id = $1::uuid", contact["id"],
        )
        await _expect_refusal(conn, "b2b_emergency_contact_reopen",
                              "UPDATE booking.trip_case_checks SET status = 'open' WHERE id = $1::uuid", contact["id"])
    await _expect_refusal(
        conn, "second_standard_row",
        "INSERT INTO booking.trip_case_checks (trip_case_id, code, title) VALUES ($1::uuid, 'insurance', 'again')",
        case["id"],
    )
    return {"id": case["id"], "code": case["code"], "ok": ok}


async def _b2c(conn, today) -> dict:
    case = await conn.fetchrow(
        "SELECT id::text AS id, code, status FROM booking.trip_cases WHERE notes = $1 AND created_at::date = $2"
        " AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1",
        B2C_NOTE, today,
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
            " source_system, notes) VALUES ($1::uuid, 'proposal_sent', $2::date + 30, $2::date + 34, 2, 2, 'USD',"
            " 'manual', $3) RETURNING id::text AS id, code, status",
            customer, today, B2C_NOTE,
        )
        # The version-approval path: an UPDATE into confirmed seeds the checks.
        await conn.execute("UPDATE booking.trip_cases SET status = 'confirmed' WHERE id = $1::uuid", case["id"])
        await conn.execute("SELECT set_config('booking.status_note', '', true)")
        out("write", what="b2c_trip_case", code=case["code"], status="confirmed")
    rows = await _checks(conn, case["id"], case["code"])
    contact = next((r for r in rows if r["code"] == "emergency_contact"), None)
    if contact is not None and contact["status"] == "open":
        await conn.execute(
            "UPDATE booking.trip_case_checks SET emergency_contact_name = $2, emergency_contact_phone = '+84 00 000 0000',"
            " status = 'done', done_at = now() WHERE id = $1::uuid",
            contact["id"], f"{TAG} contact",
        )
        await _audit(conn, "trip_check.updated", "trip_case_check", contact["id"], f"{case['code']} Emergency contact",
                     {"status": "done", "emergency_contact_name": "(set)", "emergency_contact_phone": "(set)"},
                     f"Done: Emergency contact ({case['code']}) ({ACTOR})")
        out("write", what="b2c_emergency_contact_done", case=case["code"])
    if not any(r["code"] == "custom" for r in rows):
        custom = await conn.fetchval(
            "INSERT INTO booking.trip_case_checks (trip_case_id, code, title, due_date) VALUES ($1::uuid, 'custom', $2,"
            " $3::date + 20) RETURNING id::text",
            case["id"], f"{TAG} custom check", today,
        )
        await _audit(conn, "trip_check.created", "trip_case_check", custom, f"{case['code']} custom",
                     {"code": "custom"}, f"Added a custom check to {case['code']} ({ACTOR})")
        out("write", what="b2c_custom_check", case=case["code"])
    standard = [r for r in await conn.fetch(
        "SELECT code, status FROM booking.trip_case_checks WHERE trip_case_id = $1::uuid AND code <> 'custom'",
        case["id"],
    )]
    ok = len(standard) == 3
    out("verify", what="b2c_seeded", case=case["code"], standard_checks=len(standard),
        contact_done=any(r["code"] == "emergency_contact" and r["status"] == "done" for r in standard))
    return {"id": case["id"], "code": case["code"], "ok": ok}


async def _board(conn, cases: list[dict]) -> None:
    for c in cases:
        row = await conn.fetchrow(
            "SELECT case_status, checks_total, checks_open, checks_done, checks_not_applicable, checks_overdue,"
            " supply_state, suppliers_confirmed, payment_verified FROM booking.v_trip_check_board"
            " WHERE trip_case_id = $1::uuid", c["id"],
        )
        if row is None:
            out("board", case=c["code"], on_board=False)
            continue
        out("board", case=c["code"], **{k: row[k] for k in row.keys()})


async def _lifecycle_in_sql(conn, b2b: dict, today, zone: str) -> str:
    """app/ops/lifecycle._move, in SQL: B2B, supply none, start passed, end passed -> catch-up to completed."""
    await conn.execute("SELECT set_config('TimeZone', $1, true)", zone)
    status = await conn.fetchval("SELECT status FROM booking.trip_cases WHERE id = $1::uuid", b2b["id"])
    for target in TRAVEL:
        before = status
        if TRAVEL.index(target) <= (TRAVEL.index(status) if status in TRAVEL else -1):
            continue
        await conn.execute("SELECT set_config('booking.actor', '', true), set_config('booking.status_note', $1, true)",
                           f"Auto: travel dates ({KIND}, {today.isoformat()}, {ACTOR})")
        try:
            async with conn.transaction():
                await conn.execute("UPDATE booking.trip_cases SET status = $2 WHERE id = $1::uuid AND status = $3",
                                   b2b["id"], target, before)
        except Exception as exc:  # noqa: BLE001
            out("lifecycle", case=b2b["code"], move=f"{before}->{target}", accepted=False,
                sqlstate=getattr(exc, "sqlstate", "?"))
            break
        await conn.execute("SELECT set_config('booking.status_note', '', true)")
        await _audit(conn, "trip_case.status_changed", "trip_case", b2b["id"], b2b["code"],
                     {"status": target, "cause": "travel dates"}, f"{before} -> {target} (automatic: travel dates, {ACTOR})")
        out("lifecycle", case=b2b["code"], move=f"{before}->{target}", accepted=True)
        status = target
    return status


async def _queue(conn, payload: dict, key: str) -> str | None:
    return await conn.fetchval(
        "INSERT INTO booking.job (kind, payload, idempotency_key, max_attempts, created_by)"
        " VALUES ($1, $2::jsonb, $3, 3, $4) ON CONFLICT DO NOTHING RETURNING id::text",
        KIND, json.dumps(payload), key, ACTOR,
    )


async def _wait(conn, job_ids: list[str], seconds: int) -> None:
    pending = [j for j in job_ids if j]
    for _ in range(max(seconds // 3, 1)):
        rows = await conn.fetch(
            "SELECT id::text AS id, status, result::text AS result, left(error, 200) AS error FROM booking.job"
            " WHERE id = ANY($1::uuid[])", pending,
        )
        if rows and all(r["status"] in ("succeeded", "failed", "cancelled") for r in rows):
            break
        await asyncio.sleep(3)
    for r in rows if pending else []:
        res = json.loads(r["result"]) if r["result"] else {}
        out("job", id=r["id"], status=r["status"], mode=res.get("mode"), scoped=res.get("scoped"),
            today=res.get("today"), moves=json.dumps(res.get("moves")), moved=json.dumps(res.get("moved_cases")),
            blocked=res.get("blocked"), refused=res.get("refused"), cleared_checks=res.get("cleared_checks"),
            error=r["error"])


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
        today = await conn.fetchval("SELECT (now() AT TIME ZONE $1)::date", zone)
        out("context", ops_zone=zone, ops_today=today)
        if mode == "go_live":
            job = await _queue(conn, {"trigger": "manual", "dry_run": False}, f"{KIND}:{SCRIPT_NAME}:go_live:{today}")
            out("write", what="queued_unscoped_live_run", job=job)
            await tx.commit()
            if wait and job:
                await _wait(conn, [job], POLL_SECONDS)
            return 0
        b2b = await _b2b(conn, today)
        b2c = await _b2c(conn, today)
        await _board(conn, [b2b, b2c])
        totals = await conn.fetchrow(
            "SELECT count(*)::int AS checks, count(DISTINCT trip_case_id)::int AS cases,"
            " count(*) FILTER (WHERE status = 'open')::int AS open FROM booking.trip_case_checks"
        )
        sold = await conn.fetchval(
            "SELECT count(*)::int FROM booking.trip_cases WHERE deleted_at IS NULL AND status IN ('confirmed',"
            " 'supplier_confirming', 'invoice_sent', 'payment_pending', 'paid', 'pre_departure', 'on_trip')"
        )
        on_board = await conn.fetchval("SELECT count(*)::int FROM booking.v_trip_check_board")
        # Backfill + trigger: every open sold case has its three standard checks.
        missing = await conn.fetchval(
            "SELECT count(*)::int FROM booking.v_trip_check_board b WHERE (SELECT count(*) FROM booking.trip_case_checks k"
            " WHERE k.trip_case_id = b.trip_case_id AND k.code <> 'custom') <> 3"
        )
        out("counts", trip_case_checks=totals["checks"], cases_with_checks=totals["cases"], open_checks=totals["open"],
            open_sold_cases=sold, cases_on_board=on_board, sold_cases_missing_standard_checks=missing)
        ok = b2b["ok"] and b2c["ok"] and on_board == sold and missing == 0
        jobs: list[str] = []
        if mode == "apply":
            jobs.append(await _queue(conn, {"trigger": "manual", "dry_run": False, "case_ids": [b2b["id"]]},
                                     f"{KIND}:{SCRIPT_NAME}:scoped:{today}"))
            jobs.append(await _queue(conn, {"trigger": "manual", "dry_run": True}, f"{KIND}:{SCRIPT_NAME}:dry:{today}"))
            out("write", what="queued_jobs", scoped_live=jobs[0], unscoped_dry_run=jobs[1])
        else:
            final = await _lifecycle_in_sql(conn, b2b, today, zone)
            ok = ok and final == "completed"
            out("verify", what="b2b_lifecycle_in_sql", case=b2b["code"], final_status=final)
        out("verdict", ok=ok, mode=mode)
    except BaseException:
        await tx.rollback()
        raise
    if mode == "apply" and ok:
        await tx.commit()
        if wait:
            await _wait(conn, jobs, POLL_SECONDS)
            status = await conn.fetchval("SELECT status FROM booking.trip_cases WHERE id = $1::uuid", b2b["id"])
            out("verify", what="b2b_after_job", case=b2b["code"], status=status, expected="completed")
    else:
        await tx.rollback()
        out("rolled_back", reason="dry_run" if mode != "apply" else "verdict not ok")
    return 0 if ok else 1


async def main(conn):
    return await run(conn, MODE)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse

    import asyncpg

    parser = argparse.ArgumentParser(description="AA-682 S2 live check on synthetic cases (DRY RUN by default)")
    parser.add_argument("dsn")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--apply", action="store_true", help="commit and queue the jobs (default: run and roll back)")
    group.add_argument("--go-live", action="store_true", help="queue one unscoped live lifecycle run")
    parser.add_argument("--no-wait", action="store_true", help="do not wait for the worker")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            chosen = "apply" if args.apply else "go_live" if args.go_live else "dry_run"
            return await run(conn, chosen, wait=not args.no_wait)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
