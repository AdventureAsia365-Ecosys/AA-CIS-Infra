"""Read-only dump of the shared RDS catalog, run in a one-off ECS task (AA-807 N1).

Started by .github/workflows/db-schema-dump.yml exactly like DB Migrate starts run_migration.py:
the workflow uploads this file to S3, the task (migrator task definition since X1 S12: CIS api image,
the migrator task role, DATABASE_URL secret)
downloads it through a presigned URL and execs it. Uses only the image's Python + asyncpg + boto3.

Login (X1 S22): DATABASE_URL is db_migrator's DSN (the RDS master before S22). db_migrator is an INHERIT
member of every owner role (cis_owner, bk_owner, tp_owner, catalog_owner) and of pg_read_all_stats, so the
catalog reads, the soft-key counts and the state / query columns of pg_stat_activity (Connections table)
are what the master saw; pg_*_relation_size takes no privilege. The first line `DUMP login=<role>` says
which role ran the dump.

What it captures, for every non-system schema (extension-owned objects left out):
  schemas (owner, USAGE/CREATE grants) · tables/views/matviews (kind, owner, RLS enabled/forced,
  estimated rows, total/table/index size) · columns (format_type, NOT NULL, comment — raw; gen_schema_reference.py
  parses the data standards DM-6.1 `pii:<class>` / `conf:<class>` tag from it) · indexes (definition,
  valid, size, scans) · CHECK and FK constraints · RLS policies · table grants and column grants ·
  triggers · functions (owner, SECURITY DEFINER) · default privileges · roles (attributes, connection
  limit, timeout settings) and memberships · extensions · enums · pg_stat_user_tables activity ·
  sessions per application_name · shared.schema_versions · the orphan rate of cross-app soft keys
  (data standards DM-4.2: aggregate counts only, see SOFT_KEY_CHECKS).

Read-only by construction: the session sets default_transaction_read_only and every query runs in
one REPEATABLE READ READ ONLY transaction (one consistent snapshot), with statement_timeout 60s and
lock_timeout 10s (pg_total_relation_size takes an ACCESS SHARE lock; a migration holding an
exclusive lock makes the dump fail and retry the next night, never wait behind it).

Env: DATABASE_URL, DUMP_BUCKET, DUMP_KEY. Writes the JSON to s3://DUMP_BUCKET/DUMP_KEY and prints
`DUMP ok ...`. Exit 0 ok, 1 error (traceback in the task log). No row values are read (the soft-key
checks return counts only), and role passwords are never visible in pg_roles.
"""
import asyncio
import datetime
import json
import os
import sys

FORMAT = 2
SESSION_SETTINGS = {
    "application_name": "db-schema-dump",
    "default_transaction_read_only": "on",
    "statement_timeout": "60s",
    "lock_timeout": "10s",
    "search_path": "pg_catalog, public",      # stable format_type() output
}
# Role settings worth publishing (connection budget, backstop timeouts). Anything else in rolconfig
# is dropped, so an unexpected setting never leaks into the public root repo.
ROLE_CONFIG_KEYS = (
    "statement_timeout", "lock_timeout", "idle_in_transaction_session_timeout", "search_path",
    "application_name", "default_transaction_read_only", "work_mem",
)
NOT_EXTENSION = """NOT EXISTS (SELECT 1 FROM pg_depend dep WHERE dep.classid = '{catalog}'::regclass
                     AND dep.objid = {oid} AND dep.deptype = 'e')"""
GRANTEE = "CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END"

SCHEMAS_SQL = """
SELECT n.nspname AS schema, pg_get_userbyid(n.nspowner) AS owner
FROM pg_namespace n
WHERE n.nspname NOT IN ('information_schema', 'pg_catalog', 'pg_toast')
  AND n.nspname !~ '^pg_(temp|toast_temp)_'
ORDER BY 1"""

# Every query takes $1 = the schema list (text[]) unless it has no $1.
QUERIES = {
    "database": """
SELECT current_database() AS name, current_setting('server_version') AS server_version,
       pg_database_size(current_database()) AS size_bytes,
       current_setting('max_connections')::int AS max_connections,
       (SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()) AS stats_reset""",
    "schema_grants": f"""
SELECT n.nspname AS schema, {GRANTEE} AS grantee,
       string_agg(a.privilege_type, ',' ORDER BY a.privilege_type) AS privileges
FROM pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) a
WHERE n.nspname = ANY($1::text[]) AND a.grantee <> n.nspowner
GROUP BY 1, 2 ORDER BY 1, 2""",
    "relations": f"""
SELECT n.nspname AS schema, c.relname AS name, c.relkind::text AS kind,
       pg_get_userbyid(c.relowner) AS owner, c.reltuples::bigint AS est_rows,
       c.relrowsecurity AS rls, c.relforcerowsecurity AS rls_forced, c.relispartition AS is_partition,
       CASE WHEN c.relkind IN ('r', 'p', 'm') THEN pg_total_relation_size(c.oid) END AS total_bytes,
       CASE WHEN c.relkind IN ('r', 'p', 'm') THEN pg_relation_size(c.oid) END AS table_bytes,
       CASE WHEN c.relkind IN ('r', 'p', 'm') THEN pg_indexes_size(c.oid) END AS index_bytes
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = ANY($1::text[]) AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
  AND {NOT_EXTENSION.format(catalog='pg_class', oid='c.oid')}
ORDER BY 1, 2""",
    "columns": """
SELECT n.nspname AS schema, c.relname AS name, a.attname AS column,
       format_type(a.atttypid, a.atttypmod) AS type, a.attnotnull AS not_null,
       col_description(a.attrelid, a.attnum) AS comment
FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = ANY($1::text[]) AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
  AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY 1, 2, a.attnum""",
    "indexes": """
SELECT n.nspname AS schema, t.relname AS name, i.relname AS index, pg_get_indexdef(i.oid) AS definition,
       x.indisprimary AS is_primary, x.indisunique AS is_unique, x.indisvalid AS is_valid,
       pg_relation_size(i.oid) AS bytes, s.idx_scan AS scans
FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid JOIN pg_class t ON t.oid = x.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
LEFT JOIN pg_stat_all_indexes s ON s.indexrelid = x.indexrelid
WHERE n.nspname = ANY($1::text[])
ORDER BY 1, 2, 3""",
    "constraints": """
SELECT n.nspname AS schema, c.relname AS name, con.conname AS constraint, con.contype::text AS type,
       pg_get_constraintdef(con.oid) AS definition, con.convalidated AS validated,
       fn.nspname AS ref_schema, fc.relname AS ref_name,
       (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
          FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum) AS columns,
       (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
          FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum) AS ref_columns
FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_class fc ON fc.oid = con.confrelid LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
WHERE n.nspname = ANY($1::text[]) AND con.contype IN ('c', 'f')
ORDER BY 1, 2, 3""",
    "policies": """
SELECT schemaname AS schema, tablename AS name, policyname AS policy, permissive,
       roles::text[] AS roles, cmd, qual, with_check
FROM pg_policies WHERE schemaname = ANY($1::text[])
ORDER BY 1, 2, 3""",
    "table_grants": f"""
SELECT n.nspname AS schema, c.relname AS name, {GRANTEE} AS grantee,
       string_agg(a.privilege_type || CASE WHEN a.is_grantable THEN '*' ELSE '' END, ','
                  ORDER BY a.privilege_type) AS privileges
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN LATERAL aclexplode(c.relacl) a
WHERE n.nspname = ANY($1::text[]) AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.grantee <> c.relowner
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3""",
    "column_grants": f"""
SELECT n.nspname AS schema, c.relname AS name, att.attname AS column, {GRANTEE} AS grantee,
       string_agg(a.privilege_type, ',' ORDER BY a.privilege_type) AS privileges
FROM pg_attribute att JOIN pg_class c ON c.oid = att.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(att.attacl) a
WHERE n.nspname = ANY($1::text[]) AND att.attnum > 0 AND NOT att.attisdropped
GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 4, 3""",
    "triggers": """
SELECT n.nspname AS schema, c.relname AS name, t.tgname AS trigger,
       pg_get_triggerdef(t.oid) AS definition, t.tgenabled::text AS enabled
FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = ANY($1::text[]) AND NOT t.tgisinternal
ORDER BY 1, 2, 3""",
    "functions": f"""
SELECT n.nspname AS schema, p.proname AS name, pg_get_function_identity_arguments(p.oid) AS args,
       pg_get_function_result(p.oid) AS result, p.prokind::text AS kind, l.lanname AS language,
       pg_get_userbyid(p.proowner) AS owner, p.prosecdef AS security_definer
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
WHERE n.nspname = ANY($1::text[]) AND {NOT_EXTENSION.format(catalog='pg_proc', oid='p.oid')}
ORDER BY 1, 2, 3""",
    "default_privileges": f"""
SELECT pg_get_userbyid(d.defaclrole) AS role, n.nspname AS schema, d.defaclobjtype::text AS object_type,
       {GRANTEE} AS grantee, string_agg(a.privilege_type, ',' ORDER BY a.privilege_type) AS privileges
FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
CROSS JOIN LATERAL aclexplode(d.defaclacl) a
GROUP BY 1, 2, 3, 4 ORDER BY 1, 2 NULLS FIRST, 3, 4""",
    "roles": """
SELECT rolname AS role, rolcanlogin AS login, rolsuper AS superuser, rolinherit AS inherit,
       rolcreaterole AS createrole, rolcreatedb AS createdb, rolbypassrls AS bypassrls,
       rolconnlimit AS connection_limit, rolconfig AS config
FROM pg_roles WHERE rolname !~ '^(pg_|rds)'
ORDER BY 1""",
    "role_members": """
SELECT pg_get_userbyid(m.roleid) AS role, pg_get_userbyid(m.member) AS member, m.admin_option
FROM pg_auth_members m WHERE pg_get_userbyid(m.member) !~ '^(pg_|rds)'
ORDER BY 2, 1""",
    "extensions": """
SELECT e.extname AS name, e.extversion AS version, n.nspname AS schema
FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY 1""",
    "enums": """
SELECT n.nspname AS schema, t.typname AS name, array_agg(e.enumlabel ORDER BY e.enumsortorder) AS labels
FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = ANY($1::text[])
GROUP BY 1, 2 ORDER BY 1, 2""",
    "activity": """
SELECT schemaname AS schema, relname AS name, seq_scan, seq_tup_read, idx_scan, n_tup_ins, n_tup_upd,
       n_tup_del, n_live_tup, n_dead_tup, last_vacuum, last_autovacuum, last_analyze, last_autoanalyze
FROM pg_stat_user_tables WHERE schemaname = ANY($1::text[])
ORDER BY 1, 2""",
    "connections": """
SELECT coalesce(nullif(application_name, ''), '(empty)') AS application_name,
       coalesce(usename::text, '') AS role, coalesce(state, '') AS state, count(*)::int AS sessions
FROM pg_stat_activity
WHERE datname = current_database() AND backend_type = 'client backend' AND pid <> pg_backend_pid()
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3""",
    "migrations": """
SELECT version, applied_at, description FROM shared.schema_versions
ORDER BY applied_at DESC, version DESC""",
}

# Data standards DM-4.2 (AA-830): cross-app soft keys (no FK across owners, DM-2.3) and how many rows point at
# nothing. Each check runs only when its key columns and its target exist and are readable by this role, so a
# check never aborts the one read-only transaction: before the owner's migration is applied it reports
# "not_applicable"; without SELECT it reports "no_privilege". Each SQL returns exactly one row of counts
# (total, without_key, orphans) and never row values. Add a check when a new soft key ships.
SOFT_KEY_CHECKS = (
    {
        "name": "booking.trip_case_legs.(source_system, source_id) -> catalog.v_tour",
        "table": "booking.trip_case_legs",
        "columns": ("source_system", "source_id"),
        "target": "catalog.v_tour",
        "target_columns": ("source_system", "source_id"),
        "sql": """
SELECT count(*)::int AS total,
       count(*) FILTER (WHERE l.source_id IS NULL)::int AS without_key,
       count(*) FILTER (WHERE l.source_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM catalog.v_tour t
           WHERE t.source_system = l.source_system AND t.source_id = l.source_id))::int AS orphans
FROM booking.trip_case_legs l""",
    },
)
SOFT_KEY_READY_SQL = """
SELECT to_regclass($1) IS NOT NULL AND to_regclass($3) IS NOT NULL AS present,
       (SELECT count(*) FROM pg_attribute a
         WHERE a.attrelid = to_regclass($1) AND a.attname = ANY($2::text[]) AND NOT a.attisdropped)
       = cardinality($2::text[])
   AND (SELECT count(*) FROM pg_attribute a
         WHERE a.attrelid = to_regclass($3) AND a.attname = ANY($4::text[]) AND NOT a.attisdropped)
       = cardinality($4::text[]) AS columns,
       CASE WHEN to_regclass($1) IS NOT NULL AND to_regclass($3) IS NOT NULL
            THEN has_table_privilege(to_regclass($1), 'SELECT') AND has_table_privilege(to_regclass($3), 'SELECT')
       END AS readable"""


async def soft_keys(conn) -> list:
    """Run every SOFT_KEY_CHECKS entry that can run; one result row per check."""
    out = []
    for check in SOFT_KEY_CHECKS:
        ready = await conn.fetchrow(SOFT_KEY_READY_SQL, check["table"], list(check["columns"]),
                                    check["target"], list(check["target_columns"]))
        if not (ready["present"] and ready["columns"]):
            out.append(soft_key_result(check, "not_applicable"))
        elif not ready["readable"]:
            out.append(soft_key_result(check, "no_privilege"))
        else:
            out.append(soft_key_result(check, "ok", dict(await conn.fetchrow(check["sql"]))))
    return out


def soft_key_result(check: dict, status: str, counts: dict | None = None) -> dict:
    """One check's result: name, table, target, status and (when it ran) counts + orphan rate over keyed rows."""
    row = {"name": check["name"], "table": check["table"], "target": check["target"], "status": status,
           "total": None, "without_key": None, "orphans": None, "orphan_rate": None}
    if counts is not None:
        keyed = counts["total"] - counts["without_key"]
        row.update(total=counts["total"], without_key=counts["without_key"], orphans=counts["orphans"],
                   orphan_rate=round(counts["orphans"] / keyed, 4) if keyed else 0.0)
    return row


KIND = {"r": "table", "p": "partitioned table", "v": "view", "m": "materialized view", "f": "foreign table"}


def _per_relation(rows, key="name"):
    out: dict = {}
    for r in rows:
        out.setdefault((r["schema"], r[key]), []).append(r)
    return out


def _strip(row: dict, *drop: str) -> dict:
    return {k: v for k, v in row.items() if k not in drop}


def role_config(config) -> dict:
    """Allowed rolconfig entries ('key=value' strings) as a dict; everything else is dropped."""
    out = {}
    for item in config or []:
        key, _, value = str(item).partition("=")
        if key in ROLE_CONFIG_KEYS:
            out[key] = value
    return out


def column_entry(c: dict) -> dict:
    """One column of a relation: name, type, NOT NULL and the raw comment (None when the column has none). No parsing
    here: the DM-6.1 tag is read from the comment by gen_schema_reference.py (AA-877), so the dump stays raw."""
    return {"name": c["column"], "type": c["type"], "not_null": bool(c["not_null"]), "comment": c.get("comment")}


def build_dump(schemas: list, rows: dict, generated_at: str, soft_key_rows: list | None = None) -> dict:
    """Assembles the JSON document from the query results (plain dicts). Pure, unit-tested."""
    names = [s["schema"] for s in schemas]
    cols = _per_relation(rows["columns"])
    idx = _per_relation(rows["indexes"])
    cons = _per_relation(rows["constraints"])
    pols = _per_relation(rows["policies"])
    grants = _per_relation(rows["table_grants"])
    cgrants = _per_relation(rows["column_grants"])
    trigs = _per_relation(rows["triggers"])
    act = {(r["schema"], r["name"]): _strip(r, "schema", "name") for r in rows["activity"]}

    relations: dict = {s: {} for s in names}
    for r in rows["relations"]:
        key = (r["schema"], r["name"])
        relations[r["schema"]][r["name"]] = {
            "kind": KIND.get(r["kind"], r["kind"]),
            "owner": r["owner"],
            "est_rows": r["est_rows"] if r["kind"] in ("r", "p", "m") else None,
            "rls": bool(r["rls"]), "rls_forced": bool(r["rls_forced"]),
            "is_partition": bool(r["is_partition"]),
            "size": {k: r[f"{k}_bytes"] for k in ("total", "table", "index")} if r["kind"] in ("r", "p", "m") else None,
            "columns": [column_entry(c) for c in cols.get(key, [])],
            "indexes": [_strip(i, "schema", "name") for i in idx.get(key, [])],
            "constraints": [_strip(c, "schema", "name") for c in cons.get(key, [])],
            "policies": [_strip(p, "schema", "name") for p in pols.get(key, [])],
            "grants": [_strip(g, "schema", "name") for g in grants.get(key, [])],
            "column_grants": [_strip(g, "schema", "name") for g in cgrants.get(key, [])],
            "triggers": [_strip(t, "schema", "name") for t in trigs.get(key, [])],
            "activity": act.get(key),
        }

    schema_grants: dict = {}
    for g in rows["schema_grants"]:
        schema_grants.setdefault(g["schema"], []).append(_strip(g, "schema"))
    roles = []
    for r in rows["roles"]:
        roles.append({**_strip(r, "config"), "config": role_config(r.get("config"))})

    migrations = rows["migrations"]
    latest_per_owner = {}
    for label, test in (("cis", lambda v: v.isdigit() and len(v) == 3),
                        ("tripplanner", lambda v: v.startswith("tp-")),
                        ("booking", lambda v: v.startswith("bk-"))):
        versions = sorted(m["version"] for m in migrations if test(m["version"]))
        latest_per_owner[label] = versions[-1] if versions else None

    return {
        "format": FORMAT,
        "generated_at": generated_at,
        "database": (rows["database"] or [{}])[0],
        "schemas": [{"schema": s["schema"], "owner": s["owner"],
                     "grants": schema_grants.get(s["schema"], [])}
                    for s in schemas],
        "relations": relations,
        "functions": rows["functions"],
        "default_privileges": rows["default_privileges"],
        "roles": roles,
        "role_members": rows["role_members"],
        "extensions": rows["extensions"],
        "enums": rows["enums"],
        "connections": rows["connections"],
        "migrations": migrations,
        "migrations_latest_per_owner": latest_per_owner,
        "soft_keys": list(soft_key_rows or []),
        "counts": {
            "schemas": len(names),
            "relations": sum(len(v) for v in relations.values()),
            "indexes": len(rows["indexes"]),
            "policies": len(rows["policies"]),
            "functions": len(rows["functions"]),
            "migrations": len(migrations),
        },
    }


async def collect(conn) -> dict:
    schemas = [dict(r) for r in await conn.fetch(SCHEMAS_SQL)]
    names = [s["schema"] for s in schemas]
    rows = {}
    for key, sql in QUERIES.items():
        args = (names,) if "$1" in sql else ()
        rows[key] = [dict(r) for r in await conn.fetch(sql, *args)]
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
    return build_dump(schemas, rows, now, await soft_keys(conn))


async def main() -> int:
    import asyncpg   # only inside the task
    import boto3
    conn = await asyncpg.connect(os.environ["DATABASE_URL"], timeout=30, server_settings=SESSION_SETTINGS)
    try:
        print(f"DUMP login={await conn.fetchval('SELECT session_user::text')}", flush=True)   # X1 S22: db_migrator
        async with conn.transaction(isolation="repeatable_read", readonly=True):
            dump = await collect(conn)
    finally:
        await conn.close()
    body = json.dumps(dump, default=str, indent=1, sort_keys=True).encode("utf-8")
    s3 = boto3.client("s3", region_name=os.environ.get("AWS_REGION") or "us-west-1")
    s3.put_object(Bucket=os.environ["DUMP_BUCKET"], Key=os.environ["DUMP_KEY"], Body=body,
                  ContentType="application/json")
    c = dump["counts"]
    print(f"DUMP ok schemas={c['schemas']} relations={c['relations']} indexes={c['indexes']} "
          f"policies={c['policies']} functions={c['functions']} migrations={c['migrations']} "
          f"latest={dump['migrations_latest_per_owner']} bytes={len(body)}", flush=True)
    for k in dump["soft_keys"]:
        print(f"DUMP soft-key {k['name']}: {k['status']} total={k['total']} without_key={k['without_key']} "
              f"orphans={k['orphans']}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
