"""AA-829 S249 single-schema restore rehearsal, option A of docs/ops/runbooks/restore-schema.md (WRITE).

Reads drill_s249.restore_rehearsal from the PITR copy, inserts the rows missing in live (by primary key) in one
transaction, recounts inside the transaction and raises (rolls back) if live is not exactly the copy afterwards.
DRY RUN numbers come from s249_drill_compare.py (live 60, copy 100, so 40 to insert); this script refuses any
other count. Touches only the throw-away rehearsal schema.
"""

DRILL_ID = "aa-cis-dev-db-drill-20261023"
SCHEMA = "drill_s249"
TABLE = "drill_s249.restore_rehearsal"


def _master_dsn():
    import boto3
    return boto3.client("secretsmanager", region_name="us-west-1").get_secret_value(
        SecretId="aa-cis/dev/rds")["SecretString"]


def _drill_host():
    """The drill copy's endpoint: the live instance's RDS name (found behind db.dev.internal) with the
    instance id swapped. No endpoint suffix is written in this public repo."""
    import socket
    name, aliases, _ = socket.gethostbyname_ex("db.dev.internal")
    for n in [name, *aliases]:
        if n.startswith("aa-cis-dev-db.") and n.endswith(".rds.amazonaws.com"):
            return DRILL_ID + n[len("aa-cis-dev-db"):]
    raise RuntimeError("db.dev.internal does not lead to aa-cis-dev-db (is the CNAME repointed?)")


async def _connect_drill():
    import asyncpg
    from urllib.parse import urlsplit
    u = urlsplit(_master_dsn())
    from urllib.parse import unquote
    return await asyncpg.connect(host=_drill_host(), port=u.port or 5432, user=unquote(u.username),
                                 password=unquote(u.password), database=u.path.lstrip("/"), ssl="require",
                                 timeout=30)

EXPECTED_INSERT = 40


async def main(conn):
    drill = await _connect_drill()
    try:
        async with drill.transaction(readonly=True):
            rows = await drill.fetch(f"SELECT id, label, created_at FROM {TABLE} ORDER BY id")
    finally:
        await drill.close()
    copy_ids = {r["id"] for r in rows}
    async with conn.transaction():
        live_ids = {r["id"] for r in await conn.fetch(f"SELECT id FROM {TABLE} FOR UPDATE")}
        missing = [r for r in rows if r["id"] not in live_ids]
        print(f"SCRIPT dry_run copy={len(rows)} live={len(live_ids)} to_insert={len(missing)}", flush=True)
        if len(missing) != EXPECTED_INSERT:
            raise RuntimeError(f"to_insert {len(missing)} != DRY RUN {EXPECTED_INSERT}: nothing written")
        await conn.executemany(f"INSERT INTO {TABLE} (id, label, created_at) VALUES ($1, $2, $3) "
                               "ON CONFLICT (id) DO NOTHING", [(r["id"], r["label"], r["created_at"]) for r in missing])
        after = {r["id"] for r in await conn.fetch(f"SELECT id FROM {TABLE}")}
        if after != copy_ids:
            raise RuntimeError(f"live {len(after)} rows differ from the copy {len(copy_ids)}: rolled back")
        print(f"SCRIPT restored inserted={len(missing)} live_now={len(after)} equals_copy=true", flush=True)
