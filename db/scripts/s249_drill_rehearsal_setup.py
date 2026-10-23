"""AA-829 S249 single-schema restore rehearsal, step 0 (WRITE, synthetic data only).

Creates the throw-away schema drill_s249 with one table of 100 synthetic rows, commits, waits two minutes,
then deletes 40 of them (the simulated "damage"). Prints the UTC commit times T1 (rows complete) and T2
(damage) so the PITR copy can be restored to a point between them. Nothing of any app is touched; the schema
is dropped by s249_drill_cleanup.py in the same session. Rerun-safe: refuses if the schema already exists.
"""
import asyncio

SCHEMA = "drill_s249"
TABLE = "drill_s249.restore_rehearsal"


async def main(conn):
    if await conn.fetchval("SELECT count(*) FROM pg_namespace WHERE nspname = $1", SCHEMA):
        raise RuntimeError(f"{SCHEMA} already exists: run s249_drill_cleanup.py first")
    async with conn.transaction():
        await conn.execute(f"CREATE SCHEMA {SCHEMA}")
        await conn.execute(f"CREATE TABLE {TABLE} (id int PRIMARY KEY, label text NOT NULL, "
                           "created_at timestamptz NOT NULL DEFAULT now())")
        await conn.execute(f"INSERT INTO {TABLE} (id, label) SELECT g, 'synthetic-' || g FROM generate_series(1, 100) g")
    t1 = await conn.fetchval("SELECT now()")
    print(f"SCRIPT t1_rows_complete={t1.isoformat()} rows={await conn.fetchval(f'SELECT count(*) FROM {TABLE}')}", flush=True)
    await asyncio.sleep(120)
    async with conn.transaction():
        n = await conn.execute(f"DELETE FROM {TABLE} WHERE id % 5 IN (1, 3)")
    t2 = await conn.fetchval("SELECT now()")
    print(f"SCRIPT t2_damage={t2.isoformat()} {n} left={await conn.fetchval(f'SELECT count(*) FROM {TABLE}')}", flush=True)
