"""AA-961 live check (S261), Dev only: raise, then clear, one synthetic AA incident on one Booking departure, so the
CRM side (incident banner, `aa_incident` task, Travelling-now panel, cleared banner) can be seen end to end.

Why a script: the only Booking staff identity an agent can sign in with is read-only by design (AA-910, 403
`e2e_read_only` on `POST /booking/b2b-desk/departures/<id>/incidents`). The row is written the way the Booking API
writes it: as the app role `booking` (INSERT on the table, UPDATE on cleared_at / cleared_by only), so the
`departure_incidents_outbox` trigger fans the event out to the partners with seats on the departure exactly as in
production. No Booking audit row on this path.

Target: the synthetic departure of 13 Nov 2026 that the S261 evidence prepared (one synthetic CRM agency holds a
confirmed AA line on it; root docs/audits/2026-10-31-S261-evidence/AA-961/README.md).

MODE:
- "flag" (this file as merged): refuses if the departure already has an open incident; inserts one `other` incident,
  then prints the outbox rows the trigger wrote for it (partner ids, event type, sequenced or not).
- "clear" (one-line follow-up PR): refuses unless exactly one open incident exists on the departure; sets
  cleared_at / cleared_by, then prints the outbox rows again.

Prints ids, codes and counts only (no agency names). Local test: `python3 aa961_incident_seed.py <DSN> [flag|clear]`.
"""

import asyncio

MODE = "flag"

SCRIPT_NAME = "aa961_incident_seed"
ACTOR = "seed:S261-AA-961"
DEPARTURE_ID = "9f7d807d-1b10-4477-9136-02a7911f4875"
INCIDENT_CODE = "other"
WRITE_ROLE = "booking"


def out(tag: str, /, **values) -> None:
    parts = " ".join(f"{k}={v}" for k, v in values.items())
    print(f"SCRIPT {tag} {parts}".rstrip(), flush=True)


async def _outbox(conn) -> None:
    rows = await conn.fetch(
        "SELECT partner_id::text AS partner_id, event_type, incident_code, feed_seq IS NOT NULL AS sequenced"
        " FROM booking.outbox WHERE departure_id = $1::uuid AND event_type LIKE 'departure.incident%' ORDER BY id",
        DEPARTURE_ID,
    )
    out("outbox", rows=len(rows))
    for r in rows:
        out("outbox_row", partner_id=r["partner_id"], event_type=r["event_type"], code=r["incident_code"],
            sequenced=r["sequenced"])  # fmt: skip


async def run(conn, mode: str) -> int:
    out(SCRIPT_NAME, mode=mode.upper(), departure_id=DEPARTURE_ID)
    async with conn.transaction():
        await conn.execute(f"SET LOCAL ROLE {WRITE_ROLE}")
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        exists = await conn.fetchval("SELECT count(*) FROM booking.departures WHERE id = $1::uuid", DEPARTURE_ID)
        if exists != 1:
            out("refuse", why="departure not found")
            return 1
        open_ids = [
            r["id"]
            for r in await conn.fetch(
                "SELECT id::text AS id FROM booking.departure_incidents WHERE departure_id = $1::uuid"
                " AND cleared_at IS NULL",
                DEPARTURE_ID,
            )
        ]
        if mode == "flag":
            if open_ids:
                out("refuse", why="an incident is already open", incident_id=open_ids[0])
                return 1
            incident_id = await conn.fetchval(
                "INSERT INTO booking.departure_incidents (departure_id, incident_code, flagged_by)"
                " VALUES ($1::uuid, $2, $3) RETURNING id::text",
                DEPARTURE_ID, INCIDENT_CODE, ACTOR,
            )  # fmt: skip
            out("flagged", incident_id=incident_id, code=INCIDENT_CODE)
        elif mode == "clear":
            if len(open_ids) != 1:
                out("refuse", why="expected exactly one open incident", open=len(open_ids))
                return 1
            await conn.execute(
                "UPDATE booking.departure_incidents SET cleared_at = now(), cleared_by = $2 WHERE id = $1::uuid",
                open_ids[0], ACTOR,
            )  # fmt: skip
            out("cleared", incident_id=open_ids[0])
        else:
            out("refuse", why="unknown mode")
            return 1
    await _outbox(conn)
    return 0


async def main(conn):
    return await run(conn, MODE)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import sys

    import asyncpg

    async def _cli() -> int:
        conn = await asyncpg.connect(sys.argv[1])
        try:
            return await run(conn, sys.argv[2] if len(sys.argv) > 2 else "flag")
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
