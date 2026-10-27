"""AA-993 G5 live proof (S254), Dev only: seed one RUNNING row of a deploy-blocking kind in booking.job
(`bk_retention_job`) and one in crm.job (`crm_dispatch`), so the orchestrator can show that the new deploy gates of
AA-Booking (`/booking/ops/deploy-gate`) and AA-Partner (`/crm/ci/deploy-gate`) block on them: a `workflow_dispatch` of
each Deploy Dev must go red at `preflight` with "1 <kind> job(s) running (deploy-blocking kind)".

Each row is synthetic and inert:
- `status = 'running'`, `locked_by = 'aa993-g5-proof'` (no real worker holds it, no worker ever claims a running row,
  no handler runs, nothing is sent or deleted), `locked_until = now() + LEASE_MINUTES`;
- `cancel_requested = true` and `attempt = max_attempts = 1`, so when the lease expires the app's reaper ends the row
  `cancelled` (never re-queued); `started_at` and `progress.attempt_started_at` stay NULL, so the backlog metric never
  counts it as overdue (no `-jobs-overdue-running` alarm);
- payload `{"aa993_g5_proof": true}`, `created_by = script:aa993_g5_gate_proof_rows`.
While the rows exist (≤ LEASE_MINUTES), DB Migrate apply / run-script of every owner waits on them (idle check): run
the two dispatches, then let the lease expire. `aa993_g4_bk_noop_report.py` (READ_ONLY) shows them ending `cancelled`.

Preconditions (or the proof passes falsely): `aa-booking-dev-api` and `aa-crm-dev-api` each run ≥ 1 task. With 0
tasks running, pending or desired, both preflight scripts skip the gate ("no task running, pending or desired — gate
skipped") and the Deploy Dev goes green. Check `runningCount` before dispatching, and read the preflight log: it must
show the `GET .../deploy-gate -> 200` line and `blocked_by`, not the "gate skipped" notice.

Side effect: the seeded `bk_retention_job` row shows in the Booking retention status (`/booking/retention`, failed
bucket, status `cancelled`) as the newest run until the next real retention run replaces it. It is test data, marked
by its payload and `created_by`.

Modes: MODE = "dry_run" (this file as merged) inserts both rows, prints them and rolls back; "apply" (one-line
follow-up PR) commits. Refuses when a proof row of either kind is still running. Writes as each schema's owner role
(`bk_owner`, `crm_owner`), one transaction per schema. Prints ids and statuses only. Local test:
`python3 aa993_g5_gate_proof_rows.py <DSN> [--apply]`.
"""

import asyncio
import json

MODE = "dry_run"

SCRIPT_NAME = "aa993_g5_gate_proof_rows"
ACTOR = f"script:{SCRIPT_NAME}"
LOCKED_BY = "aa993-g5-proof"
LEASE_MINUTES = 10
# (table, owner role, deploy-blocking kind)
TARGETS = (
    ("booking.job", "bk_owner", "bk_retention_job"),
    ("crm.job", "crm_owner", "crm_dispatch"),
)


def out(tag: str, /, **values) -> None:
    parts = " ".join(f"{k}={v}" for k, v in values.items())
    print(f"SCRIPT {tag} {parts}".rstrip(), flush=True)


async def _seed(conn, table: str, role: str, kind: str, mode: str) -> bool:
    tx = conn.transaction()
    await tx.start()
    committed = False
    try:
        await conn.execute(f"SET LOCAL ROLE {role}")
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        open_rows = await conn.fetchval(
            f"SELECT count(*) FROM {table} WHERE created_by = $1 AND status = 'running'", ACTOR
        )
        if open_rows:
            out("refuse", table=table, why="a proof row is still running (wait for its lease to expire)")
            return False
        row = await conn.fetchrow(
            f"INSERT INTO {table} (kind, payload, status, attempt, max_attempts, locked_by, locked_until,"
            " cancel_requested, created_by)"
            " VALUES ($1, $2::jsonb, 'running', 1, 1, $3, now() + make_interval(mins => $4), true, $5)"
            " RETURNING id::text AS id, status,"
            " to_char(locked_until AT TIME ZONE 'UTC', 'HH24:MI:SS') AS lease_until",
            kind, json.dumps({"aa993_g5_proof": True}), LOCKED_BY, LEASE_MINUTES, ACTOR,
        )
        running = await conn.fetchval(
            f"SELECT count(*) FROM {table} WHERE kind = $1 AND status = 'running'", kind
        )
        out("seeded", table=table, kind=kind, id=row["id"], status=row["status"],
            lease_until_utc=row["lease_until"], running_of_kind=running)
        if mode == "apply":
            await tx.commit()
            committed = True
        else:
            out("rolled_back", table=table, reason="dry_run")
        return True
    finally:
        if not committed:
            await tx.rollback()


async def run(conn, mode: str) -> int:
    out(SCRIPT_NAME, mode=mode.upper(), lease_minutes=LEASE_MINUTES)
    ok = True
    for table, role, kind in TARGETS:
        ok = await _seed(conn, table, role, kind, mode) and ok
    if ok and mode == "apply":
        out("next", step=f"dispatch Booking and Partner Deploy Dev within {LEASE_MINUTES} min: preflight must be red")
    return 0 if ok else 1


async def main(conn):
    return await run(conn, MODE)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse

    import asyncpg

    parser = argparse.ArgumentParser(description="AA-993 G5: seed running deploy-blocking proof rows (DRY RUN)")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="commit the two rows")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, "apply" if args.apply else "dry_run")
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
