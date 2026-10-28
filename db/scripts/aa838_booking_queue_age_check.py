"""AA-838 D8 (first C8 capacity review, S255/S256): explain the single Booking queue-age sample of 24/10/2026.
READ-ONLY.

What happened (CloudWatch + the Booking task log, read in S256): `AA/Jobs/Booking OldestQueuedAgeSeconds` was 0 in
every 5-minute sample except one, 38,746 s (~10.8 h), sent at 2026-10-24 03:14:47 UTC by the metrics sampler of a
NEW task 0.5 s after it started (a rolling deploy; the old task's sampler had sent 0 at 03:11:23 and the next sample
at 03:19:47 was 0 again). So a due queued row with run_after ~2026-10-23 16:29 UTC was visible for at most a few
minutes around the deploy and was claimed (or cancelled) right after. The log does not say which kind. This script
reads booking.job (master login, DB Migrate `mode=run-script`) to name it.

Output (`SCRIPT ` lines; kinds, statuses, timestamps, attempt counters and lengths only — no ids, payloads, result
values, error text or created_by values, so no customer or staff data reaches the public Actions log):
- `SCRIPT window ...`: the run_after window searched (the computed run_after +/- WINDOW_MIN minutes).
- `SCRIPT row ...`: one line per booking.job row whose run_after is in the window, and one per row that was due
  and still queued at the spike (run_after <= spike, started_at NULL or >= the old sampler's last zero), with an
  `explain=` label from `explain_row` (pure, unit-tested).
- `SCRIPT kinds ...`: per kind, rows created in the 24 h before the spike and their run_after spread.
- `SCRIPT verdict candidates=<n>`.

Always returns 0: it is evidence for a one-off sample, not a gate.
"""

import datetime as dt

READ_ONLY = True

UTC = dt.timezone.utc
# The ALARM sample: sampler line `ops_metrics_sampled ... oldest_queued_age_s=38746` at this instant.
SPIKE_AT = dt.datetime(2026, 10, 24, 3, 14, 47, tzinfo=UTC)
SPIKE_AGE_S = 38746
# The previous zero sample (old task) — a row seen at the spike but not then became due-and-queued in between.
PREV_ZERO_AT = dt.datetime(2026, 10, 24, 3, 11, 23, tzinfo=UTC)
WINDOW_MIN = 3

ROW_SQL = """
SELECT kind, status, attempt, max_attempts, cancel_requested,
       created_at, run_after, started_at, finished_at, updated_at,
       (created_by IS NULL) AS created_by_null, length(coalesce(error, '')) AS error_len,
       parent_job_id IS NOT NULL AS has_parent
  FROM booking.job
 WHERE run_after BETWEEN $1::timestamptz AND $2::timestamptz
    OR (run_after < $4::timestamptz - interval '15 minutes' AND created_at <= $3::timestamptz
        AND (started_at IS NULL OR started_at >= $4::timestamptz OR updated_at >= $4::timestamptz)
        AND updated_at <= $3::timestamptz + interval '10 minutes')
 ORDER BY run_after, created_at
 LIMIT 50
"""

KIND_SQL = """
SELECT kind, count(*) AS n, min(run_after) AS min_run_after, max(run_after) AS max_run_after,
       count(*) FILTER (WHERE run_after < created_at) AS run_after_before_created,
       count(*) FILTER (WHERE status = 'succeeded') AS ok,
       count(*) FILTER (WHERE status = 'failed') AS failed,
       count(*) FILTER (WHERE status = 'cancelled') AS cancelled
  FROM booking.job
 WHERE created_at BETWEEN $1::timestamptz - interval '24 hours' AND $1::timestamptz + interval '10 minutes'
 GROUP BY kind ORDER BY kind
"""


def explain_row(row: dict, spike_at: dt.datetime = SPIKE_AT, prev_zero_at: dt.datetime = PREV_ZERO_AT) -> str:
    """Label why a row could have been the 'due queued' row of the spike sample (pure)."""
    run_after, created_at, updated_at = row["run_after"], row["created_at"], row["updated_at"]
    started_at = row.get("started_at")
    if run_after is None or run_after > spike_at:
        return "not_due_at_spike"
    if created_at > spike_at:
        return "created_after_spike"
    if prev_zero_at < created_at <= spike_at:
        return "enqueued_during_deploy_with_old_run_after"
    if row.get("attempt", 0) > 0 and updated_at is not None and prev_zero_at < updated_at and (
            started_at is None or started_at > spike_at):
        return "requeued_during_deploy_keeping_run_after"
    if started_at is not None and started_at <= prev_zero_at:
        return "already_started_before_prev_zero"
    if row.get("cancel_requested"):
        return "cancel_requested"
    return "queued_and_due_unclaimed"


def _fmt(v) -> str:
    if isinstance(v, dt.datetime):
        return v.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    return str(v)


async def main(conn):
    centre = SPIKE_AT - dt.timedelta(seconds=SPIKE_AGE_S)
    lo, hi = centre - dt.timedelta(minutes=WINDOW_MIN), centre + dt.timedelta(minutes=WINDOW_MIN)
    print(f"SCRIPT window run_after={_fmt(centre)} +/-{WINDOW_MIN}min spike={_fmt(SPIKE_AT)} "
          f"prev_zero={_fmt(PREV_ZERO_AT)}")
    rows = [dict(r) for r in await conn.fetch(ROW_SQL, lo, hi, SPIKE_AT, PREV_ZERO_AT)]
    for r in rows:
        print("SCRIPT row " + " ".join(
            f"{k}={_fmt(r[k])}" for k in ("kind", "status", "attempt", "max_attempts", "cancel_requested",
                                          "created_at", "run_after", "started_at", "finished_at", "updated_at",
                                          "created_by_null", "error_len", "has_parent"))
              + f" explain={explain_row(r)}")
    for k in await conn.fetch(KIND_SQL, SPIKE_AT):
        print("SCRIPT kinds " + " ".join(f"{c}={_fmt(k[c])}" for c in k.keys()))
    print(f"SCRIPT verdict candidates={len(rows)}")
    return 0
