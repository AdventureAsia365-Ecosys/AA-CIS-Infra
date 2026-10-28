"""AA-838 capacity probe (data standards C8b items 2-4 and 6, C4.3 weekly check). READ-ONLY.

Two ways to run it, same file:

1. S3-mediated ECS exec in the aa-cis-dev-api container (login `cis_app`, container DATABASE_URL):
       python3 capacity_probe.py            # all sections
       PROBE_TOP=50 python3 capacity_probe.py   # top-50 statements (C4.3a snapshot before any reset)
   `cis_app` is not a member of pg_read_all_stats: pg_stat_statements rows of OTHER roles keep their
   timings but show no query text and no queryid; pg_stat_activity shows their role and
   application_name but not their state. The probe says so in its header.

2. DB Migrate `mode=run-script` (master login, full text), after copying this file to AA-CIS-Infra
   `db/scripts/aa838_capacity_probe.py` through a reviewed PR. The runner awaits `main(conn)`;
   READ_ONLY = True makes the runner open the session read-only.

Never writes, never calls pg_stat_statements_reset() (C4.3a). Prints aggregates, object names and
normalised statement text only (constants are $n placeholders): no row values, no secrets, no DSN.
Every line starts with "PROBE " so the output is easy to grep from the exec or task log.
"""

import asyncio
import os

READ_ONLY = True

TOP = int(os.environ.get("PROBE_TOP", "20"))
QTEXT = int(os.environ.get("PROBE_QTEXT", "160"))

# Statement-text patterns for the C1.2 SLIs (matched with ILIKE on the normalised text).
SLI_PATTERNS = [
    ("cis_tenant_reads", "%acp_shared.%"),
    ("cis_tenant_versions", "%tenant_tour_versions%"),
    ("catalog_views", "%catalog.v_%"),
    ("cis_admin_usage", "%v_tenant_monthly_usage%"),
    ("cis_llm_cost_aggregates", "%llm_call_log%"),
    ("cis_job_claim", "%pg_advisory_xact_lock%"),
    ("booking_trip_cases", "%booking.trip_cases%"),
    ("booking_customers", "%booking.customers%"),
    ("tp_outbox", "%tripplanner.outbox%"),
]


def out(*parts):
    print("PROBE", *parts, flush=True)


def mb(n):
    return f"{(n or 0) / 1048576:.1f}MB"


def short(q):
    if q is None:
        return "<hidden: other role, needs pg_read_all_stats>"
    return " ".join(q.split())[:QTEXT]


async def section(conn, name, coro):
    try:
        await coro
    except Exception as exc:  # one failing section must not hide the others
        out(f"[{name}] ERROR {type(exc).__name__}: {str(exc)[:200]}")


async def header(conn):
    r = await conn.fetchrow(
        """
        SELECT current_user AS login,
               version() AS version,
               to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS at,
               pg_postmaster_start_time() AS started,
               pg_has_role(current_user, 'pg_read_all_stats', 'USAGE') AS read_all_stats,
               current_setting('transaction_isolation') AS iso
        """
    )
    out(f"[header] login={r['login']} at={r['at']} postmaster_start={r['started']} "
        f"read_all_stats={r['read_all_stats']}")
    out(f"[header] {r['version'].split(',')[0]}")
    names = ["max_connections", "superuser_reserved_connections", "shared_buffers", "effective_cache_size",
             "work_mem", "maintenance_work_mem", "autovacuum_vacuum_scale_factor",
             "autovacuum_analyze_scale_factor", "autovacuum_naptime", "log_min_duration_statement",
             "log_lock_waits", "track_io_timing", "idle_in_transaction_session_timeout",
             "statement_timeout", "pg_stat_statements.max", "pg_stat_statements.track",
             "shared_preload_libraries"]
    rows = await conn.fetch(
        "SELECT name, setting, unit FROM pg_catalog.pg_settings WHERE name = ANY($1::text[]) ORDER BY name",
        names)
    for x in rows:
        out(f"[setting] {x['name']}={x['setting']}{x['unit'] or ''}")


async def database(conn):
    rows = await conn.fetch(
        """
        SELECT d.datname,
               CASE WHEN has_database_privilege(d.oid, 'CONNECT') THEN pg_database_size(d.oid) END AS size, s.numbackends, s.xact_commit, s.xact_rollback,
               s.blks_hit, s.blks_read, s.temp_files, s.temp_bytes, s.deadlocks, s.conflicts,
               s.stats_reset, age(d.datfrozenxid) AS xid_age
          FROM pg_catalog.pg_database d
          JOIN pg_catalog.pg_stat_database s ON s.datid = d.oid
         WHERE d.datallowconn AND d.datname NOT IN ('template0', 'template1', 'rdsadmin')
         ORDER BY size DESC
        """
    )
    for x in rows:
        hit = x["blks_hit"] or 0
        rd = x["blks_read"] or 0
        ratio = 100.0 * hit / (hit + rd) if hit + rd else 0
        out(f"[database] {x['datname']} size={mb(x['size'])} backends={x['numbackends']} "
            f"commit={x['xact_commit']} rollback={x['xact_rollback']} cache_hit={ratio:.2f}% "
            f"temp_files={x['temp_files']} temp={mb(x['temp_bytes'])} deadlocks={x['deadlocks']} "
            f"conflicts={x['conflicts']} xid_age={x['xid_age']} stats_reset={x['stats_reset']}")


async def schemas(conn):
    rows = await conn.fetch(
        """
        SELECT n.nspname AS schema, count(*) AS tables,
               sum(pg_total_relation_size(c.oid)) AS total,
               sum(pg_relation_size(c.oid)) AS heap,
               sum(pg_indexes_size(c.oid)) AS idx
          FROM pg_catalog.pg_class c
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind IN ('r', 'm', 'p')
           AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
         GROUP BY 1 ORDER BY total DESC
        """
    )
    for x in rows:
        out(f"[schema] {x['schema']} tables={x['tables']} total={mb(x['total'])} heap={mb(x['heap'])} "
            f"indexes={mb(x['idx'])}")


TABLES_SQL = """
    SELECT s.schemaname || '.' || s.relname AS t,
           pg_total_relation_size(s.relid) AS total,
           pg_relation_size(s.relid) AS heap,
           pg_indexes_size(s.relid) AS idx,
           coalesce(pg_total_relation_size(c.reltoastrelid), 0) AS toast,
           s.n_live_tup, s.n_dead_tup, s.seq_scan, s.idx_scan, s.n_tup_ins, s.n_tup_upd, s.n_tup_del,
           s.n_mod_since_analyze, s.last_autovacuum, s.last_autoanalyze, s.autovacuum_count,
           io.heap_blks_hit, io.heap_blks_read
      FROM pg_catalog.pg_stat_user_tables s
      JOIN pg_catalog.pg_class c ON c.oid = s.relid
      LEFT JOIN pg_catalog.pg_statio_user_tables io ON io.relid = s.relid
"""


async def tables(conn):
    rows = await conn.fetch(TABLES_SQL + " ORDER BY total DESC LIMIT 30")
    for x in rows:
        live = x["n_live_tup"] or 0
        dead = x["n_dead_tup"] or 0
        ratio = 100.0 * dead / live if live else 0
        hit = x["heap_blks_hit"] or 0
        rd = x["heap_blks_read"] or 0
        cache = 100.0 * hit / (hit + rd) if hit + rd else 0
        out(f"[table_size] {x['t']} total={mb(x['total'])} heap={mb(x['heap'])} idx={mb(x['idx'])} "
            f"toast={mb(x['toast'])} live~{live} dead={dead} dead_pct={ratio:.1f} seq={x['seq_scan']} "
            f"idx_scan={x['idx_scan']} ins/upd/del={x['n_tup_ins']}/{x['n_tup_upd']}/{x['n_tup_del']} "
            f"heap_cache_hit={cache:.1f}% last_autovac={x['last_autovacuum']} autovac_n={x['autovacuum_count']}")
    rows = await conn.fetch(TABLES_SQL + " ORDER BY s.n_live_tup DESC NULLS LAST LIMIT 30")
    for x in rows:
        out(f"[table_rows] {x['t']} live~{x['n_live_tup']} dead={x['n_dead_tup']} total={mb(x['total'])}")
    # C5.2b: dead/live > 20 % (only tables with a meaningful number of dead rows)
    rows = await conn.fetch(TABLES_SQL + """
         WHERE s.n_dead_tup >= 1000 AND s.n_dead_tup > 0.2 * greatest(s.n_live_tup, 1)
         ORDER BY s.n_dead_tup DESC LIMIT 30""")
    out(f"[bloat] tables with dead/live > 20% and >= 1000 dead rows: {len(rows)}")
    for x in rows:
        out(f"[bloat] {x['t']} live~{x['n_live_tup']} dead={x['n_dead_tup']} last_autovac={x['last_autovacuum']}")


async def indexes(conn):
    rows = await conn.fetch(
        """
        SELECT s.schemaname || '.' || s.indexrelname AS i, s.relname AS t,
               pg_relation_size(s.indexrelid) AS size, s.idx_scan, x.indisunique, x.indisprimary
          FROM pg_catalog.pg_stat_user_indexes s
          JOIN pg_catalog.pg_index x ON x.indexrelid = s.indexrelid
         ORDER BY size DESC LIMIT $1
        """, TOP)
    for x in rows:
        out(f"[index_size] {x['i']} on {x['t']} size={mb(x['size'])} scans={x['idx_scan']} "
            f"unique={x['indisunique']} pk={x['indisprimary']}")
    rows = await conn.fetch(
        """
        SELECT s.schemaname || '.' || s.indexrelname AS i, s.relname AS t, pg_relation_size(s.indexrelid) AS size
          FROM pg_catalog.pg_stat_user_indexes s
          JOIN pg_catalog.pg_index x ON x.indexrelid = s.indexrelid
         WHERE s.idx_scan = 0 AND NOT x.indisunique AND NOT x.indisprimary
           AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k WHERE k.conindid = s.indexrelid)
         ORDER BY size DESC
        """
    )
    total = sum(x["size"] for x in rows)
    out(f"[unused_index] count={len(rows)} total={mb(total)} (C5.2d: drop candidate only after 30 days at 0)")
    for x in rows[:15]:
        out(f"[unused_index] {x['i']} on {x['t']} size={mb(x['size'])}")


async def ledgers(conn):
    # C5.4 / DM-7 windows: llm_call_log 180 d, tenant_api_usage 90 d, jobs succeeded 30 d / failed 90 d.
    checks = [
        ("shared.llm_call_log", "created_at", 180),
        ("shared.decision_log", "created_at", None),
        ("shared.tenant_api_usage", "called_at", 90),
        ("shared.job", "created_at", 30),  # 30 d is the succeeded window; failed keep 90 d
        ("booking.job", None, 30),
        ("crm.job", None, 30),
    ]
    for table, col, keep in checks:
        schema, rel = table.split(".")
        est = await conn.fetchval(
            "SELECT n_live_tup FROM pg_catalog.pg_stat_user_tables WHERE schemaname = $1 AND relname = $2",
            schema, rel)
        line = f"[ledger] {table} live~{est} retention_days={keep or 'none yet'}"
        if col:
            try:
                r = await conn.fetchrow(
                    f"SELECT min({col}) AS oldest, count(*) FILTER (WHERE {col} > now() - interval '30 days') "
                    f"AS last30, count(*) FILTER (WHERE {col} > now() - interval '7 days') AS last7 FROM {table}")
                line += f" oldest={r['oldest']} rows_30d={r['last30']} rows_7d={r['last7']}"
                if keep:
                    over = await conn.fetchval(
                        f"SELECT count(*) FROM {table} WHERE {col} < now() - make_interval(days => $1)", keep)
                    line += f" older_than_window={over}"
            except Exception as exc:
                line += f" (no SELECT: {type(exc).__name__})"
        out(line)


async def jobs(conn):
    rows = await conn.fetch(
        """
        SELECT status, count(*) AS n,
               round(extract(epoch FROM now() - min(run_after) FILTER (WHERE status = 'queued'
                     AND run_after <= now()))) AS oldest_due_s
          FROM shared.job GROUP BY status ORDER BY status
        """
    )
    for x in rows:
        out(f"[job_cis] status={x['status']} n={x['n']} oldest_due_queued_s={x['oldest_due_s']}")
    rows = await conn.fetch(
        """
        SELECT kind, count(*) AS n,
               round(percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM finished_at - started_at)::float8)::numeric, 1) AS p50_s,
               round(percentile_cont(0.95) WITHIN GROUP (ORDER BY extract(epoch FROM finished_at - started_at)::float8)::numeric, 1) AS p95_s,
               count(*) FILTER (WHERE status = 'failed') AS failed
          FROM shared.job
         WHERE created_at > now() - interval '30 days' AND started_at IS NOT NULL AND finished_at IS NOT NULL
         GROUP BY kind ORDER BY n DESC LIMIT 25
        """
    )
    for x in rows:
        out(f"[job_cis_kind_30d] {x['kind']} n={x['n']} p50={x['p50_s']}s p95={x['p95_s']}s failed={x['failed']}")


async def connections(conn):
    r = await conn.fetchrow(
        "SELECT current_setting('max_connections')::int AS mx, "
        "current_setting('superuser_reserved_connections')::int AS su")
    out(f"[conn] max_connections={r['mx']} superuser_reserved={r['su']} ceiling75={int(r['mx'] * 0.75)}")
    rows = await conn.fetch(
        """
        SELECT coalesce(usename::text, '<none>') AS role,
               coalesce(nullif(application_name, ''), '<empty>') AS app,
               coalesce(state, '<not visible>') AS state, count(*) AS n
          FROM pg_catalog.pg_stat_activity
         WHERE usename IS NOT NULL AND pid <> pg_backend_pid()
         GROUP BY 1, 2, 3 ORDER BY 1, 2, 3
        """
    )
    total = 0
    for x in rows:
        total += x["n"]
        out(f"[conn_app] role={x['role']} app={x['app']} state={x['state']} n={x['n']}")
    out(f"[conn] client_sessions={total} (excluding this probe)")
    rows = await conn.fetch(
        """
        SELECT r.rolname AS role, r.rolconnlimit AS lim, count(a.pid) AS n
          FROM pg_catalog.pg_roles r
          LEFT JOIN pg_catalog.pg_stat_activity a ON a.usename = r.rolname
         WHERE r.rolcanlogin AND r.rolname NOT LIKE 'rds%'
         GROUP BY 1, 2 ORDER BY 1
        """
    )
    for x in rows:
        pct = f"{100.0 * x['n'] / x['lim']:.0f}%" if x["lim"] and x["lim"] > 0 else "-"
        out(f"[conn_role] {x['role']} sessions={x['n']} rolconnlimit={x['lim']} pct={pct}")
    rows = await conn.fetch(
        """
        SELECT usename AS role, coalesce(nullif(application_name, ''), '<empty>') AS app, state,
               round(extract(epoch FROM now() - xact_start)) AS xact_s,
               round(extract(epoch FROM now() - state_change)) AS state_s
          FROM pg_catalog.pg_stat_activity
         WHERE pid <> pg_backend_pid() AND xact_start IS NOT NULL
           AND (now() - xact_start > interval '60 seconds')
         ORDER BY xact_s DESC LIMIT 10
        """
    )
    out(f"[long_xact] visible transactions open > 60 s: {len(rows)} (only sessions this login may see)")
    for x in rows:
        out(f"[long_xact] role={x['role']} app={x['app']} state={x['state']} xact_s={x['xact_s']} state_s={x['state_s']}")


async def locks(conn):
    r = await conn.fetchrow(
        """
        SELECT count(*) FILTER (WHERE NOT granted) AS waiting,
               count(*) AS total,
               (SELECT count(*) FROM pg_catalog.pg_stat_activity
                 WHERE cardinality(pg_blocking_pids(pid)) > 0) AS blocked_sessions
          FROM pg_catalog.pg_locks
        """
    )
    out(f"[locks] held+waiting={r['total']} waiting={r['waiting']} blocked_sessions={r['blocked_sessions']}")


async def statements(conn):
    ext = await conn.fetchval(
        "SELECT n.nspname FROM pg_catalog.pg_extension e JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace "
        "WHERE e.extname = 'pg_stat_statements'")
    if not ext:
        out("[pgss] extension pg_stat_statements not installed")
        return
    pgss = f"{ext}.pg_stat_statements"
    info = await conn.fetchrow(f"SELECT dealloc, stats_reset FROM {ext}.pg_stat_statements_info")
    n = await conn.fetchval(f"SELECT count(*) FROM {pgss}")
    out(f"[pgss] schema={ext} statements={n} dealloc={info['dealloc']} stats_reset={info['stats_reset']}")
    base = f"""
        SELECT r.rolname AS role, s.calls, s.total_exec_time AS total_ms, s.mean_exec_time AS mean_ms,
               s.stddev_exec_time AS sd_ms, s.max_exec_time AS max_ms, s.rows,
               s.shared_blks_hit, s.shared_blks_read, s.temp_blks_written, s.queryid, s.query
          FROM {pgss} s
          LEFT JOIN pg_catalog.pg_roles r ON r.oid = s.userid
         WHERE s.toplevel
    """
    rows = await conn.fetch(
        f"""
        SELECT coalesce(r.rolname, s.userid::text) AS role, count(*) AS stmts, sum(s.calls) AS calls,
               sum(s.total_exec_time) AS total_ms,
               sum(s.total_exec_time) / nullif(sum(s.calls), 0) AS mean_ms,
               sum(s.shared_blks_read) AS blks_read, sum(s.temp_blks_written) AS temp_written
          FROM {pgss} s LEFT JOIN pg_catalog.pg_roles r ON r.oid = s.userid
         WHERE s.toplevel
         GROUP BY 1 ORDER BY total_ms DESC
        """
    )
    grand = sum(float(x["total_ms"] or 0) for x in rows) or 1.0
    for x in rows:
        out(f"[pgss_role] {x['role']} stmts={x['stmts']} calls={x['calls']} total={float(x['total_ms']) / 1000:.1f}s "
            f"share={100 * float(x['total_ms']) / grand:.1f}% mean={float(x['mean_ms'] or 0):.2f}ms "
            f"blks_read={x['blks_read']} temp_written={x['temp_written']}")

    def line(tag, x):
        p95 = float(x["mean_ms"]) + 2 * float(x["sd_ms"] or 0)
        return (f"[{tag}] role={x['role']} calls={x['calls']} total={float(x['total_ms']) / 1000:.1f}s "
                f"mean={float(x['mean_ms']):.1f}ms p95~{p95:.1f}ms max={float(x['max_ms']):.0f}ms rows={x['rows']} "
                f"hit/read={x['shared_blks_hit']}/{x['shared_blks_read']} temp={x['temp_blks_written']} "
                f"qid={x['queryid']} q={short(x['query'])}")

    for x in await conn.fetch(base + " ORDER BY s.total_exec_time DESC LIMIT $1", TOP):
        out(line("pgss_total", x))
    for x in await conn.fetch(base + " AND s.calls >= 5 ORDER BY s.mean_exec_time DESC LIMIT $1", TOP):
        out(line("pgss_mean", x))
    # per role: top 5 by total and by mean (C4.3 "per role")
    for role in [x["role"] for x in rows]:
        for x in await conn.fetch(
                base + " AND coalesce(r.rolname, s.userid::text) = $1 ORDER BY s.total_exec_time DESC LIMIT 5", role):
            out(line("pgss_role_total", x))
        for x in await conn.fetch(
                base + " AND coalesce(r.rolname, s.userid::text) = $1 AND s.calls >= 5 "
                       "ORDER BY s.mean_exec_time DESC LIMIT 5", role):
            out(line("pgss_role_mean", x))
    # C3: primary-path statements with mean > 200 ms (trigger t4g.medium -> m7g counts > 5)
    slow = await conn.fetchval(f"SELECT count(*) FROM {pgss} s WHERE s.toplevel AND s.calls >= 20 AND s.mean_exec_time > 200")
    out(f"[pgss] statements with calls>=20 and mean>200ms: {slow}")
    # C1.2 SLIs, approximated per C1.1b (only statements whose text this login can see)
    for name, pattern in SLI_PATTERNS:
        r = await conn.fetchrow(
            f"""
            SELECT count(*) AS stmts, sum(calls) AS calls,
                   max(mean_exec_time + 2 * stddev_exec_time) AS worst_p95,
                   sum(total_exec_time) / nullif(sum(calls), 0) AS mean_ms
              FROM {pgss} s WHERE s.toplevel AND s.query ILIKE $1
            """, pattern)
        out(f"[sli] {name} stmts={r['stmts']} calls={r['calls']} mean={float(r['mean_ms'] or 0):.1f}ms "
            f"worst_stmt_p95~{float(r['worst_p95'] or 0):.1f}ms")


async def main(conn):
    for name, fn in [("header", header), ("database", database), ("schemas", schemas), ("tables", tables),
                     ("indexes", indexes), ("ledgers", ledgers), ("jobs", jobs), ("connections", connections),
                     ("locks", locks), ("statements", statements)]:
        await section(conn, name, fn(conn))
    out("[done]")
    return 0


async def _standalone():
    import asyncpg  # available in the CIS api image

    conn = await asyncpg.connect(
        os.environ["DATABASE_URL"], ssl="require",
        server_settings={"application_name": "aa838-capacity-probe", "statement_timeout": "60s",
                         "lock_timeout": "2s"})
    try:
        await conn.execute("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY")
        await main(conn)
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(_standalone())
