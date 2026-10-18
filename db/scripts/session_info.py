"""Read-only smoke test for DB Migrate mode=run-script (X1 S12): prints who the script runs as and where.

Dispatch: DB Migrate, mode=run-script, script=db/scripts/session_info.py. Expected log lines:
session_user=aa_cis_admin (the master until X1 S22), the database name, the server version and the
application_name the runner sets (db-migrate). Changes nothing; prints no row values.
"""

SQL = ("SELECT session_user::text AS session_user, current_database()::text AS database, "
       "current_setting('server_version') AS server_version, "
       "current_setting('application_name') AS application_name, "
       "current_setting('lock_timeout') AS lock_timeout, "
       "current_setting('statement_timeout') AS statement_timeout")


async def main(conn):
    row = await conn.fetchrow(SQL)
    for key in ("session_user", "database", "server_version", "application_name", "lock_timeout",
                "statement_timeout"):
        print(f"SCRIPT {key}={row[key]}", flush=True)
