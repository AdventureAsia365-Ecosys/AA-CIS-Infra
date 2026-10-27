"""AA-993 G4/G5 live proof (S254), Dev only, READ ONLY: report the drain-proof rows of booking.job and crm.job.

Read after `aa993_g4_bk_noop_enqueue.py` (MODE apply) and a Booking Deploy Dev, and after
`aa993_g5_gate_proof_rows.py`. READ_ONLY = True, so the runner skips the idle wait (a running `bk_noop_sleep` would
otherwise hold the run back) and the session refuses any write.

Prints, per row (newest first, at most 5 per kind): id, status, attempt / max_attempts, `progress.releases`,
`progress.released`, `progress.slept_seconds`, `result.resumed_at_seconds`, started / finished times, a short error.
G4 passes when the newest `bk_noop_sleep` row is `succeeded` with `releases` = 1 and `resumed_at_seconds` > 0 (it
was released by the old task and finished on the new one). The task stop time (< 30 s) comes from the ECS service
events, not from here. The G5 proof rows (`created_by` = script:aa993_g5_gate_proof_rows) end `cancelled` once their
lease expires (the reaper).
"""

import asyncio

READ_ONLY = True

SCRIPT_NAME = "aa993_g4_bk_noop_report"
PROOF_ACTORS = ["script:aa993_g4_bk_noop_enqueue", "script:aa993_g5_gate_proof_rows"]
TABLES = ("booking.job", "crm.job")
LIMIT = 5


def out(tag: str, /, **values) -> None:
    parts = " ".join(f"{k}={v}" for k, v in values.items())
    print(f"SCRIPT {tag} {parts}".rstrip(), flush=True)


def _sql(table: str) -> str:
    return (
        "SELECT id::text AS id, kind, status, attempt, max_attempts, cancel_requested,"
        " progress->>'releases' AS releases, progress->>'released' AS released,"
        " progress->>'slept_seconds' AS slept, result->>'resumed_at_seconds' AS resumed_at,"
        " to_char(started_at AT TIME ZONE 'UTC', 'HH24:MI:SS') AS started,"
        " to_char(finished_at AT TIME ZONE 'UTC', 'HH24:MI:SS') AS finished,"
        " to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS created, left(error, 120) AS error,"
        " row_number() OVER (PARTITION BY kind ORDER BY created_at DESC) AS n"
        f" FROM {table} WHERE created_by = ANY($1::text[])"
    )


async def run(conn) -> int:
    out(SCRIPT_NAME, mode="READ_ONLY")
    for table in TABLES:
        rows = await conn.fetch(f"SELECT * FROM ({_sql(table)}) r WHERE n <= $2 ORDER BY kind, created DESC",
                                PROOF_ACTORS, LIMIT)
        out("table", name=table, rows=len(rows))
        for r in rows:
            out("row", table=table, kind=r["kind"], id=r["id"], status=r["status"],
                attempt=f"{r['attempt']}/{r['max_attempts']}", cancel_requested=r["cancel_requested"],
                releases=r["releases"], released=r["released"], slept_seconds=r["slept"],
                resumed_at_seconds=r["resumed_at"], created=f"'{r['created']}'", started=r["started"],
                finished=r["finished"], error=repr(r["error"]) if r["error"] else None)
    newest = await conn.fetchrow(
        "SELECT status, progress->>'releases' AS releases, result->>'resumed_at_seconds' AS resumed_at"
        " FROM booking.job WHERE kind = 'bk_noop_sleep' AND created_by = $1 ORDER BY created_at DESC LIMIT 1",
        PROOF_ACTORS[0],
    )
    if newest is not None:
        ok = (newest["status"] == "succeeded" and (newest["releases"] or "0") != "0"
              and float(newest["resumed_at"] or 0) > 0)
        out("g4_verdict", ok=ok, status=newest["status"], releases=newest["releases"],
            resumed_at_seconds=newest["resumed_at"])
    return 0


async def main(conn):
    return await run(conn)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import sys

    import asyncpg

    async def _cli() -> int:
        conn = await asyncpg.connect(sys.argv[1])
        try:
            return await run(conn)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
