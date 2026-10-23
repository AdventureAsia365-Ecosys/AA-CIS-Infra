"""AA-829 S249 restore drill: compare the PITR copy with live, schema by schema (read-only).

Same check as the S241 drill (docs/audits/2026-10-17-S241-restore-drill/drill_check.py), run through DB Migrate
run-script as the master: table count and row count per table on both instances, latest shared.schema_versions,
and the rehearsal table drill_s249.restore_rehearsal on both. Prints aggregates per schema and the names of the
tables whose counts differ (no row values).
"""
import json
import time

READ_ONLY = True

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

SQL = ("SELECT n.nspname s, c.relname t FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
       "WHERE c.relkind IN ('r', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') "
       "ORDER BY 1, 2")


async def _counts(c):
    t0 = time.time()
    out = {}
    for r in await c.fetch(SQL):
        out[f"{r['s']}.{r['t']}"] = await c.fetchval(f'SELECT count(*) FROM "{r["s"]}"."{r["t"]}"')
    heads = await c.fetch("SELECT version FROM shared.schema_versions ORDER BY applied_at DESC LIMIT 5")
    return out, [h["version"] for h in heads], round(time.time() - t0, 1)


async def main(conn):
    drill = await _connect_drill()
    try:
        print(f"SCRIPT drill_server_started={await drill.fetchval('SELECT pg_postmaster_start_time()')}", flush=True)
        src, src_heads, ts = await _counts(conn)
        async with drill.transaction(readonly=True):
            dr, dr_heads, td = await _counts(drill)
    finally:
        await drill.close()
    schemas = {}
    diff = []
    for k in sorted(set(src) | set(dr)):
        s = k.split(".")[0]
        d = schemas.setdefault(s, {"tables_live": 0, "tables_drill": 0, "rows_live": 0, "rows_drill": 0,
                                   "missing_in_drill": 0, "diff_tables": 0})
        if k in src:
            d["tables_live"] += 1
            d["rows_live"] += src[k]
        if k in dr:
            d["tables_drill"] += 1
            d["rows_drill"] += dr[k]
        if k not in dr:
            d["missing_in_drill"] += 1
        elif k in src and dr[k] != src[k]:
            d["diff_tables"] += 1
            diff.append(f"{k}:{src[k]-dr[k]:+d}")
    print("SCRIPT " + json.dumps({"tables_live": len(src), "tables_drill": len(dr), "heads_live": src_heads,
                                  "heads_drill": dr_heads, "secs_live": ts, "secs_drill": td}), flush=True)
    for s, d in schemas.items():
        print(f"SCRIPT schema {s} " + json.dumps(d), flush=True)
    print("SCRIPT diff_tables (live minus drill) " + " ".join(diff), flush=True)
    print(f"SCRIPT rehearsal live={src.get('drill_s249.restore_rehearsal')} drill={dr.get('drill_s249.restore_rehearsal')}", flush=True)
