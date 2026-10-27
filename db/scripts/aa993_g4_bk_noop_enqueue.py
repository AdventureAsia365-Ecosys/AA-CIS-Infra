"""AA-993 G4 live proof (S254), Dev only: queue ONE `bk_noop_sleep` job (300 s) in booking.job, so the orchestrator can
redeploy AA-Booking while it runs and prove the graceful drain: the old task releases the row (back to `queued`,
`attempt` back to 0, `progress.releases` = 1), the new task re-claims it, and it ends `succeeded` with
`result.resumed_at_seconds` > 0; the task stop time (ECS events) stays under 30 s.

Preconditions (the script cannot see them, it only reads booking.job):
- AA-Booking with the test kind (`backend/app/jobs/noop_sleep.py`, AA-993 G5 PR) is deployed, and the Booking Dev
  task has `JOB_TEST_KINDS=1` (`accounts/aa365/booking.tf`, this branch; Terraform apply, then a Booking deploy carries
  the new task definition revision). Without them no worker claims the row: it stays `queued` (harmless; the next
  dry_run run reports it, and `UPDATE booking.job SET cancel_requested = true` in a follow-up script ends it).
- The Booking service runs one task (desired 1).

What it does, in one transaction:
- refuses when a `bk_noop_sleep` row is already `queued` or `running` (one proof at a time);
- MODE "dry_run" (this file as merged): inserts the row as `bk_owner`, prints it, rolls back;
- MODE "apply" (one-line follow-up PR): commits, then polls up to POLL_SECONDS for the worker to claim it and prints
  `status`, `attempt`, `progress.slept_seconds`. Start the Booking Deploy Dev right after this run reports `running`
  (the job sleeps 300 s; the deploy rolls the task within ~2-4 min). Read the outcome with the READ_ONLY
  `aa993_g4_bk_noop_report.py` (this run's idle check would wait while the job runs).

Payload `{"seconds": 300}`, `max_attempts` 1 (as the CIS proof: a test kind does not retry, so only a release can bring
it back), `created_by` = the script. Prints ids, statuses and numbers only. Local test:
`python3 aa993_g4_bk_noop_enqueue.py <DSN> [--apply]`.
"""

import asyncio
import json

MODE = "dry_run"

SCRIPT_NAME = "aa993_g4_bk_noop_enqueue"
ACTOR = f"script:{SCRIPT_NAME}"
KIND = "bk_noop_sleep"
SECONDS = 300
WRITE_ROLE = "bk_owner"
POLL_SECONDS = 90


def out(tag: str, /, **values) -> None:
    parts = " ".join(f"{k}={v}" for k, v in values.items())
    print(f"SCRIPT {tag} {parts}".rstrip(), flush=True)


async def _state(conn, job_id: str):
    return await conn.fetchrow(
        "SELECT status, attempt, max_attempts, (progress->>'slept_seconds') AS slept, locked_by IS NOT NULL AS locked"
        " FROM booking.job WHERE id = $1::uuid",
        job_id,
    )


async def run(conn, mode: str, wait: bool = True) -> int:
    out(SCRIPT_NAME, mode=mode.upper())
    tx = conn.transaction()
    await tx.start()
    committed = False
    try:
        await conn.execute(f"SET LOCAL ROLE {WRITE_ROLE}")
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext($1))", SCRIPT_NAME)
        active = await conn.fetch(
            "SELECT id::text AS id, status FROM booking.job WHERE kind = $1 AND status IN ('queued', 'running')", KIND
        )
        if active:
            for r in active:
                out("refuse", why="a bk_noop_sleep job is already active", id=r["id"], status=r["status"])
            return 1
        job_id = await conn.fetchval(
            "INSERT INTO booking.job (kind, payload, max_attempts, created_by) VALUES ($1, $2::jsonb, 1, $3)"
            " RETURNING id::text",
            KIND, json.dumps({"seconds": SECONDS}), ACTOR,
        )
        row = await _state(conn, job_id)
        out("queued", id=job_id, kind=KIND, seconds=SECONDS, status=row["status"], max_attempts=row["max_attempts"])
        if mode == "apply":
            await tx.commit()
            committed = True
        else:
            out("rolled_back", reason="dry_run")
    finally:
        if not committed:
            await tx.rollback()
    if mode != "apply" or not wait:
        return 0
    for _ in range(POLL_SECONDS // 3):
        row = await _state(conn, job_id)
        if row is None or row["status"] != "queued":
            break
        await asyncio.sleep(3)
    if row is None:
        out("gone", id=job_id)
        return 1
    out("state", id=job_id, status=row["status"], attempt=row["attempt"], slept_seconds=row["slept"])
    if row["status"] == "queued":
        out("hint", why="not claimed: is JOB_TEST_KINDS=1 on the Booking task and the G5 image deployed?")
        return 1
    out("next", step="start Booking Deploy Dev now; read the outcome with aa993_g4_bk_noop_report.py")
    return 0


async def main(conn):
    return await run(conn, MODE)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse

    import asyncpg

    parser = argparse.ArgumentParser(description="AA-993 G4: queue one bk_noop_sleep(300) (DRY RUN by default)")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="commit and wait for the claim")
    parser.add_argument("--no-wait", action="store_true", help="do not wait for the claim")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, "apply" if args.apply else "dry_run", wait=not args.no_wait)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
