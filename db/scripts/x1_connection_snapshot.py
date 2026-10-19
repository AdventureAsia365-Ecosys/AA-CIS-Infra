"""X1 S15 (AA-860, plan XD6): one snapshot of who holds connections on the shared RDS, for the cis_app
CONNECTION LIMIT decision before X1 S18. Read-only; one snapshot per dispatch (dispatch it 2–3 times, e.g.
while a job wave runs and while idle).

Dispatch: DB Migrate, mode=run-script, script=db/scripts/x1_connection_snapshot.py.

Prints aggregate lines only (no query text, no client address, no row values):
  SCRIPT settings max_connections=… superuser_reserved_connections=… at=<UTC>
  SCRIPT sessions usename=<role> application_name=<name|<empty>> state=<state|<none>> n=<count>
      (client backends of every database; application_name is what each pool sets: cis-api, cis-worker,
      cis-job, cis-tenant, booking-api, …; <empty> = the ad-hoc asyncpg.connect() calls)
  SCRIPT role usename=<role> sessions=<n> rolconnlimit=<limit|-1> pct=<n/limit %|->
  SCRIPT total client_sessions=<n>
"""

READ_ONLY = True

SETTINGS_SQL = ("SELECT current_setting('max_connections') AS max_connections, "
                "current_setting('superuser_reserved_connections') AS superuser_reserved_connections, "
                "to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS at")

SESSIONS_SQL = """
    SELECT coalesce(usename::text, '<none>') AS usename,
           coalesce(nullif(application_name, ''), '<empty>') AS application_name,
           coalesce(state, '<none>') AS state,
           count(*) AS n
      FROM pg_catalog.pg_stat_activity
     WHERE backend_type = 'client backend'
     GROUP BY 1, 2, 3
     ORDER BY 1, 2, 3
"""

ROLES_SQL = """
    SELECT r.rolname::text AS usename, count(a.pid) AS sessions, r.rolconnlimit
      FROM pg_catalog.pg_roles r
      LEFT JOIN pg_catalog.pg_stat_activity a ON a.usename = r.rolname AND a.backend_type = 'client backend'
     WHERE r.rolcanlogin AND r.rolname NOT LIKE 'rds%'
     GROUP BY r.rolname, r.rolconnlimit
     ORDER BY r.rolname
"""


async def main(conn):
    s = await conn.fetchrow(SETTINGS_SQL)
    print(f"SCRIPT settings max_connections={s['max_connections']} "
          f"superuser_reserved_connections={s['superuser_reserved_connections']} at={s['at']}", flush=True)
    total = 0
    for r in await conn.fetch(SESSIONS_SQL):
        total += r["n"]
        print(f"SCRIPT sessions usename={r['usename']} application_name={r['application_name']} "
              f"state={r['state']} n={r['n']}", flush=True)
    for r in await conn.fetch(ROLES_SQL):
        limit = r["rolconnlimit"]
        pct = f"{100 * r['sessions'] / limit:.0f}%" if limit and limit > 0 else "-"
        print(f"SCRIPT role usename={r['usename']} sessions={r['sessions']} rolconnlimit={limit} pct={pct}",
              flush=True)
    print(f"SCRIPT total client_sessions={total}", flush=True)
