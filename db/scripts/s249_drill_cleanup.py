"""AA-829 S249 restore rehearsal cleanup (WRITE): drops the throw-away schema drill_s249 and prints what is left.

Only the rehearsal schema created by s249_drill_rehearsal_setup.py is touched; it refuses if the schema holds anything but
restore_rehearsal.
"""
SCHEMA = "drill_s249"


async def main(conn):
    objs = await conn.fetch("SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
                            "WHERE n.nspname = $1 AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')", SCHEMA)
    names = sorted(r["relname"] for r in objs)
    if not await conn.fetchval("SELECT count(*) FROM pg_namespace WHERE nspname = $1", SCHEMA):
        print(f"SCRIPT {SCHEMA} absent: nothing to do", flush=True)
        return
    if names not in ([], ["restore_rehearsal"]):
        raise RuntimeError(f"{SCHEMA} holds unexpected objects {names}: refusing")
    async with conn.transaction():
        await conn.execute(f"DROP SCHEMA {SCHEMA} CASCADE")
    print(f"SCRIPT dropped {SCHEMA} (had {names}); present_now="
          f"{await conn.fetchval('SELECT count(*) FROM pg_namespace WHERE nspname = $1', SCHEMA)}", flush=True)
