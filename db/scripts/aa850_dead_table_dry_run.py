"""AA-850 DRY RUN (read-only): Dead Table Registry census + wave-1 quarantine readiness.

Skill aa-cis-schema references/destructive-ops.md step 1 (DRY RUN) and data standards DM-3.8 / DM-3.9.
Nothing is written: the session is read-only and the script only runs SELECTs on catalog views, pg_stat_* and
count(*) / max(<timestamp column>) on user tables. Output is counts, names, timestamps and roles only, never row
values or query text.

Two ways to run it (same file):
  * DB Migrate mode=run-script (preferred: master login, sees every schema incl. booking / tripplanner / crm):
    copy to AA-CIS-Infra db/scripts/aa850_dead_table_dry_run.py, merge, dispatch DB Migrate on main with
    mode=run-script script=db/scripts/aa850_dead_table_dry_run.py. READ_ONLY = True: the runner opens the session
    with default_transaction_read_only = on and only reports the idle check.
  * S3-mediated ECS exec in the CIS api container (cis_app, CIS schemas only; other owners' tables print
    access=none): `python3 /tmp/s.py` uses the container's DATABASE_URL with ssl="require".

Dispatch it twice: T0 now, and T1 >= 14 days later (DM-3.8 "14 days of pg_stat_user_tables") or right before the
quarantine apply. The counters of every wave-1 table must not move between T0 and T1 (stats_reset unchanged).

Output lines (prefix SCRIPT):
  SCRIPT stats_reset database=<ts|-> now=<ts> login=<role>
  SCRIPT census table=<schema.name> kind=<r|p|v> access=<ok|none> rows=<exact|-> bytes=<n> last_write=<ts|->
         write_cols=<n> seq=<n> idx=<n> ins=<n> upd=<n> del=<n> live=<n> last_vacuum=<ts|-> last_analyze=<ts|->
  SCRIPT wave1 object=<schema.name> exists=<t|f> where=<schema|-> rows=<n|-> tenant_rows=<n|-> tenants=<n|->
         non_platform_tenant_rows=<n|-> last_write=<ts|->
  SCRIPT wave1_dep object=<o> kind=<view|fk_in|fk_out|function|trigger|policy|sequence> name=<n>
  SCRIPT wave1_grant object=<o> grantee=<role> privileges=<p,...>
  SCRIPT wave1_statements object=<o> role=<r> calls=<n>          (pg_stat_statements, counts only)
  SCRIPT retired_schema exists=<t|f> owner=<role|->
  SCRIPT verdict quarantine_ready=<true|false> reasons=<...>
quarantine_ready: every wave-1 object exists in its source schema (or already sits in `retired`), no view or
function outside wave 1 depends on it, no inbound FK from outside wave 1, no app role statement in
pg_stat_statements, and no row of a non-platform tenant. Row counts and counters are reported for the registry and
for the guard values of the quarantine migration; they are not judged here (they count since stats_reset).
"""
from __future__ import annotations

import asyncio
import os
import re

READ_ONLY = True

PLATFORM_TENANT_ID = "00000000-0000-0000-0000-000000000001"   # AA internal (services/erasure/inventory.py)

# (source schema, name, relkind) of wave 1 — keep in step with the draft migration cis_NNN_aa850_quarantine_wave1.sql
WAVE1 = (
    ("acp_contract", "atom_decompose_jobs", "r"),
    ("acp_contract", "s1_from_atom_runs", "r"),
    ("acp_contract", "route_pick", "r"),
    ("acp_shared", "marketplace_portfolios", "r"),
    ("acp_shared", "tenant_atom_state", "r"),
    ("shared", "acp_runs", "r"),
    ("shared", "tenant_brand_rule_versions", "r"),
    ("shared", "tenant_brand_rules_deleted_aa404", "r"),
    ("shared", "v_batch_stats", "v"),
    ("shared", "v_pipeline_summary", "v"),
)
# Wave 2 is reported in the census and with the same detail block (not judged by the verdict).
WAVE2 = (
    ("shared", "tenant_export_config", "r"),
    ("gold_aa_internal", "content_exports", "r"),
    ("gold_aa_internal", "webhook_deliveries", "r"),
    ("public", "checkpoint_migrations", "r"),
    ("shared", "pipeline_jobs", "r"),
)
QUARANTINE_SCHEMA = "retired"
SKIP_SCHEMAS = ("pg_catalog", "information_schema", "pg_toast")
# Roles whose statements mean "an app still touches it" (DB Migrate, the schema dump and the probe are not apps).
APP_ROLES = ("cis_app", "aa_app_user", "booking", "tripplanner", "crm_app")

TABLES_SQL = """
SELECT n.nspname AS schema, c.relname AS name, c.relkind::text AS kind, c.oid::bigint AS oid
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p', 'v', 'm') AND n.nspname <> ALL($1::text[]) AND n.nspname NOT LIKE 'pg_temp%'
 ORDER BY 1, 2
"""

STAT_SQL = """
SELECT s.seq_scan, coalesce(s.idx_scan, 0) AS idx_scan, s.n_tup_ins, s.n_tup_upd, s.n_tup_del, s.n_live_tup,
       greatest(s.last_vacuum, s.last_autovacuum) AS last_vacuum,
       greatest(s.last_analyze, s.last_autoanalyze) AS last_analyze,
       pg_total_relation_size(s.relid) AS bytes
  FROM pg_stat_user_tables s WHERE s.relid = $1::bigint::oid
"""

TS_COLS_SQL = """
SELECT a.attname FROM pg_attribute a
 WHERE a.attrelid = $1::bigint::oid AND a.attnum > 0 AND NOT a.attisdropped
   AND a.atttypid IN ('timestamptz'::regtype, 'timestamp'::regtype)
   AND a.attname NOT IN ('expires_at', 'valid_until', 'retain_until', 'starts_at', 'ends_at', 'due_at', 'scheduled_at')
 ORDER BY a.attnum
"""

TENANT_COL_SQL = """
SELECT a.attname FROM pg_attribute a
 WHERE a.attrelid = $1::bigint::oid AND a.attnum > 0 AND NOT a.attisdropped AND a.attname IN ('tenant_id', 'tenant')
 ORDER BY a.attname DESC LIMIT 1
"""

DEPS_SQL = """
WITH f AS (SELECT $1::bigint::oid AS oid, ARRAY(SELECT x::oid FROM unnest($2::bigint[]) x) AS wave)
SELECT 'view' AS kind, v.oid::regclass::text AS name
  FROM f JOIN pg_depend d ON d.refobjid = f.oid AND d.classid = 'pg_rewrite'::regclass
  JOIN pg_rewrite r ON r.oid = d.objid JOIN pg_class v ON v.oid = r.ev_class
 WHERE v.oid <> f.oid AND NOT v.oid = ANY(f.wave)
UNION
SELECT 'fk_in', c.conrelid::regclass::text || ' (' || c.conname || ')'
  FROM f JOIN pg_constraint c ON c.contype = 'f' AND c.confrelid = f.oid
 WHERE c.conrelid <> f.oid AND NOT c.conrelid = ANY(f.wave)
UNION
SELECT 'fk_out', c.confrelid::regclass::text || ' (' || c.conname || ')'
  FROM f JOIN pg_constraint c ON c.contype = 'f' AND c.conrelid = f.oid
UNION
SELECT 'trigger', t.tgname FROM f JOIN pg_trigger t ON t.tgrelid = f.oid AND NOT t.tgisinternal
UNION
SELECT 'policy', p.polname FROM f JOIN pg_policy p ON p.polrelid = f.oid
UNION
SELECT 'sequence', s.oid::regclass::text
  FROM f JOIN pg_depend d ON d.refobjid = f.oid AND d.classid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
  JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S'
 ORDER BY 1, 2
"""

# Functions whose body names the table (plpgsql resolves names at call time, so a moved table breaks them).
FUNCS_SQL = """
SELECT p.oid::regprocedure::text AS name
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname <> ALL($2::text[]) AND p.prosrc ~* $1
 ORDER BY 1
"""

GRANTS_SQL = """
SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END AS grantee,
       string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type) AS privileges
  FROM pg_class c, aclexplode(c.relacl) a
 WHERE c.oid = $1::bigint::oid AND a.grantee <> c.relowner
 GROUP BY 1 ORDER BY 1
"""

STATEMENTS_SQL = """
SELECT pg_get_userbyid(s.userid) AS role, sum(s.calls)::bigint AS calls
  FROM pg_stat_statements s
 WHERE s.query ~* $1
 GROUP BY 1 ORDER BY 1
"""


def q(ident: str) -> str:
    return '"' + ident.replace('"', '""') + '"'


def ts(v) -> str:
    return v.isoformat(timespec="seconds") if v is not None else "-"


async def _locate(conn, schema: str, name: str):
    """(schema it lives in now, oid, relkind) — the source schema, else the quarantine schema, else None."""
    for s in (schema, QUARANTINE_SCHEMA):
        row = await conn.fetchrow(
            "SELECT c.oid::bigint AS oid, c.relkind::text AS relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
            "WHERE n.nspname = $1 AND c.relname = $2", s, name)
        if row:
            return s, row["oid"], row["relkind"]
    return None, None, None


async def _can_read(conn, oid: int) -> bool:
    return bool(await conn.fetchval(
        "SELECT has_schema_privilege(c.relnamespace, 'USAGE') AND has_table_privilege(c.oid, 'SELECT') "
        "FROM pg_class c WHERE c.oid = $1::bigint::oid", oid))


async def _last_write(conn, schema: str, name: str, oid: int):
    cols = [r["attname"] for r in await conn.fetch(TS_COLS_SQL, oid)]
    if not cols:
        return None, 0
    expr = ", ".join(f"max({q(c)})" for c in cols)
    sql = f"SELECT greatest({expr}) FROM {q(schema)}.{q(name)}" if len(cols) > 1 else \
        f"SELECT max({q(cols[0])}) FROM {q(schema)}.{q(name)}"
    return await conn.fetchval(sql), len(cols)


async def census(conn) -> None:
    rows = await conn.fetch(TABLES_SQL, list(SKIP_SCHEMAS))
    for r in rows:
        fq = f"{r['schema']}.{r['name']}"
        access = await _can_read(conn, r["oid"])
        count = last = "-"
        ncols = 0
        if access and r["kind"] in ("r", "p"):
            try:
                count = await conn.fetchval(f"SELECT count(*) FROM {q(r['schema'])}.{q(r['name'])}")
                lw, ncols = await _last_write(conn, r["schema"], r["name"], r["oid"])
                last = ts(lw)
            except Exception as exc:                                  # timeout / RLS: report, keep going
                count = f"error:{type(exc).__name__}"
        st = await conn.fetchrow(STAT_SQL, r["oid"]) if r["kind"] in ("r", "p", "m") else None
        if st:
            print(f"SCRIPT census table={fq} kind={r['kind']} access={'ok' if access else 'none'} rows={count} "
                  f"bytes={st['bytes']} last_write={last} write_cols={ncols} seq={st['seq_scan']} idx={st['idx_scan']} "
                  f"ins={st['n_tup_ins']} upd={st['n_tup_upd']} del={st['n_tup_del']} live={st['n_live_tup']} "
                  f"last_vacuum={ts(st['last_vacuum'])} last_analyze={ts(st['last_analyze'])}")
        else:
            print(f"SCRIPT census table={fq} kind={r['kind']} access={'ok' if access else 'none'}")


async def detail(conn, objs, label: str, wave_oids: list[int], reasons: list[str] | None) -> None:
    for schema, name, kind in objs:
        fq = f"{schema}.{name}"
        where, oid, relkind = await _locate(conn, schema, name)
        if oid is None:
            print(f"SCRIPT {label} object={fq} exists=f where=-")
            if reasons is not None:
                reasons.append(f"{fq}:missing")
            continue
        rows = tenant_rows = tenants = foreign = last = "-"
        if relkind in ("r", "p") and await _can_read(conn, oid):
            rows = await conn.fetchval(f"SELECT count(*) FROM {q(where)}.{q(name)}")
            lw, _ = await _last_write(conn, where, name, oid)
            last = ts(lw)
            tcol = await conn.fetchval(TENANT_COL_SQL, oid)
            if tcol:
                t = await conn.fetchrow(
                    f"SELECT count({q(tcol)}) AS n, count(DISTINCT {q(tcol)}) AS d, "
                    f"count(*) FILTER (WHERE {q(tcol)} IS NOT NULL AND {q(tcol)}::text <> $1) AS f "
                    f"FROM {q(where)}.{q(name)}", PLATFORM_TENANT_ID)
                tenant_rows, tenants, foreign = t["n"], t["d"], t["f"]
                if reasons is not None and t["f"]:
                    reasons.append(f"{fq}:non_platform_tenant_rows={t['f']}")
        print(f"SCRIPT {label} object={fq} exists=t where={where} rows={rows} tenant_rows={tenant_rows} "
              f"tenants={tenants} non_platform_tenant_rows={foreign} last_write={last}")
        for d in await conn.fetch(DEPS_SQL, oid, wave_oids):
            print(f"SCRIPT {label}_dep object={fq} kind={d['kind']} name={d['name']}")
            if reasons is not None and d["kind"] in ("view", "fk_in"):
                reasons.append(f"{fq}:{d['kind']}={d['name']}")
        pattern = r"\m" + re.escape(name) + r"\M"
        for f in await conn.fetch(FUNCS_SQL, pattern, list(SKIP_SCHEMAS)):
            print(f"SCRIPT {label}_dep object={fq} kind=function name={f['name']}")
            if reasons is not None:
                reasons.append(f"{fq}:function={f['name']}")
        for g in await conn.fetch(GRANTS_SQL, oid):
            print(f"SCRIPT {label}_grant object={fq} grantee={g['grantee']} privileges={g['privileges']}")
        try:
            for s in await conn.fetch(STATEMENTS_SQL, pattern):
                print(f"SCRIPT {label}_statements object={fq} role={s['role']} calls={s['calls']}")
                if reasons is not None and s["role"] in APP_ROLES:
                    reasons.append(f"{fq}:statements_by={s['role']}")
        except Exception as exc:                                       # extension missing or not readable
            print(f"SCRIPT {label}_statements object={fq} unavailable={type(exc).__name__}")


async def main(conn) -> None:
    await conn.execute("SET statement_timeout = '120s'")
    login = await conn.fetchval("SELECT current_user")
    reset = await conn.fetchval("SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()")
    now = await conn.fetchval("SELECT now()")
    print(f"SCRIPT stats_reset database={ts(reset)} now={ts(now)} login={login}")
    rs = await conn.fetchrow("SELECT pg_get_userbyid(nspowner) AS owner FROM pg_namespace WHERE nspname = $1",
                             QUARANTINE_SCHEMA)
    print(f"SCRIPT retired_schema exists={'t' if rs else 'f'} owner={rs['owner'] if rs else '-'}")
    await census(conn)
    wave_oids = []
    for schema, name, _ in WAVE1:
        _, oid, _ = await _locate(conn, schema, name)
        if oid is not None:
            wave_oids.append(oid)
    reasons: list[str] = []
    await detail(conn, WAVE1, "wave1", wave_oids, reasons)
    await detail(conn, WAVE2, "wave2", [], None)
    print(f"SCRIPT verdict quarantine_ready={'false' if reasons else 'true'} reasons={','.join(reasons) or '-'}")


if __name__ == "__main__":                                              # ECS exec path (cis_app)
    import asyncpg

    async def _run() -> None:
        conn = await asyncpg.connect(os.environ["DATABASE_URL"], ssl="require")
        try:
            # Session-level read-only (like run-script): a failed statement does not abort the rest of the run.
            # Same effect as the run-script session setting, written the way the runner's shape check accepts.
            await conn.execute("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY")
            await main(conn)
        finally:
            await conn.close()

    asyncio.run(_run())
