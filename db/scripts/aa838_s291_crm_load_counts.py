"""AA-838 S291 lane f-crm-perf: CRM job-worker statement rates on the shared RDS. READ-ONLY, counts only.

Run like db/scripts/aa838_capacity_probe.py: AA-CIS-Infra DB Migrate `mode=run-script` (master login, so the
`crm_app` statement texts are visible; READ_ONLY = True makes the runner open the session read-only; the runner awaits
`main(conn)`). Takes two pg_stat_statements snapshots WINDOW_S apart and prints, per statement group, the calls per
minute in the window and the mean shared buffers per call. Never writes, never resets pg_stat_statements, never reads a
table row: only pg_stat_statements / pg_stat_statements_info counters and pg_roles.

Expected after the S291 CRM change is live (about 60 agencies on Dev, before -> after):
  due_proposals      ~60/min  -> ~12/min  (each agency every 300 s unless nudged)
  tenant_status      ~380/min -> ~60/min  (one read per agency and minute run; member requests unchanged)
  job_prune_delete   ~8/min   -> <= 3/min per worker process (3 recurring kinds once a minute)
  crm_app savepoint entries: the old `__asyncpg_savepoint_*` texts stop growing; `crm_sp_<n>` texts are a handful
  dealloc (evictions) per minute: falls toward 0 once the old entries are evicted
Every line starts with "COUNTS ".
"""

import asyncio

READ_ONLY = True
WINDOW_S = 120

GROUPS = {
    "due_proposals": "%p.accepted_hold_id IS NOT NULL AND p.deleted_at IS NULL%NOT EXISTS (SELECT 1 FROM crm.booking_line%",
    "tenant_status": "SELECT status FROM crm.tenant WHERE tenant_id = $1 AND deleted_at IS NULL",
    "job_prune_delete": "%DELETE FROM crm.job%WHERE kind = $1 AND status IN%",
}

SNAP_SQL = """
SELECT coalesce(sum(s.calls), 0)::bigint AS calls, coalesce(sum(s.shared_blks_hit + s.shared_blks_read), 0)::bigint AS blks
  FROM pg_stat_statements s JOIN pg_roles r ON r.oid = s.userid
 WHERE r.rolname = 'crm_app' AND s.query LIKE $1
"""
ROLE_SQL = """
SELECT count(*)::int AS entries,
       count(*) FILTER (WHERE s.query LIKE '%__asyncpg_savepoint_%')::int AS asyncpg_savepoints,
       count(*) FILTER (WHERE s.query LIKE '%crm_sp_%')::int AS depth_savepoints
  FROM pg_stat_statements s JOIN pg_roles r ON r.oid = s.userid
 WHERE r.rolname = 'crm_app'
"""
TOTAL_SQL = "SELECT count(*)::int AS n FROM pg_stat_statements"
DEALLOC_SQL = "SELECT dealloc::bigint AS d FROM pg_stat_statements_info"


def out(*parts):
    print("COUNTS", *parts, flush=True)


async def snapshot(conn):
    snap = {}
    for name, pattern in GROUPS.items():
        row = await conn.fetchrow(SNAP_SQL, pattern)
        snap[name] = (row["calls"], row["blks"])
    snap["_dealloc"] = await conn.fetchval(DEALLOC_SQL)
    return snap


async def main(conn):
    first = await snapshot(conn)
    await asyncio.sleep(WINDOW_S)
    second = await snapshot(conn)
    minutes = WINDOW_S / 60
    for name in GROUPS:
        calls = second[name][0] - first[name][0]
        blks = second[name][1] - first[name][1]
        per_call = f"{blks / calls:.0f}" if calls > 0 else "n/a"
        out(f"[rate] {name} calls_per_min={calls / minutes:.1f} window_calls={calls} buffers_per_call={per_call}")
    out(f"[evictions] dealloc_per_min={(second['_dealloc'] - first['_dealloc']) / minutes:.2f}")
    role = await conn.fetchrow(ROLE_SQL)
    out(f"[entries] crm_app={role['entries']} asyncpg_savepoint_texts={role['asyncpg_savepoints']} "
        f"crm_sp_texts={role['depth_savepoints']} all_roles={await conn.fetchval(TOTAL_SQL)}")
    out(f"[window] seconds={WINDOW_S}")
