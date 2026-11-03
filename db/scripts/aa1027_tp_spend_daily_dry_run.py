"""AA-1027 E5 DRY RUN (read-only): tripplanner.llm_spend_daily before TripPlanner tp-025 drops it, and the tripplanner
grants on the two AI gateway config tables before CIS 351 revokes them. Skill aa-cis-schema
references/destructive-ops.md, step 1; also the independent verify after both applies.

Dispatch: DB Migrate, mode=run-script, script=db/scripts/aa1027_tp_spend_daily_dry_run.py (READ_ONLY: the session is
default_transaction_read_only, the idle check only reports). Dispatch it after the TripPlanner E5 build is live on
both Lambdas (no writer left), and again after a TripPlanner smoke (browse search + assembly narrate): the write
counters and last_write must not move.

Output (counts, sums, names of tables / roles, timestamps; no row values beyond the per-table aggregates):
  SCRIPT table name=tripplanner.llm_spend_daily exists=<t|f> rows=<n> days=<n> first_day=<d|-> last_day=<d|->
         last_write=<ts|-> cost_usd=<x> calls=<n> bytes=<n> seq_scan=<n> idx_scan=<n> ins=<n> upd=<n> del=<n>
  SCRIPT ledger days=<n> cost_usd=<x> calls=<n>       (shared.llm_call_log, app tripplanner, the online stages, same
                                                      UTC days: the billing truth the counter was a copy of)
  SCRIPT stats_reset database=<ts|->                  (pg_stat counters count from here)
  SCRIPT statements role=<r> calls=<n>                (pg_stat_statements naming the table, when installed)
  SCRIPT dependent object=<name> kind=<view|fk>       (what would block tp-025's DROP … RESTRICT)
  SCRIPT grant table=tripplanner.llm_spend_daily grantee=<role> privileges=<…>
  SCRIPT cis_grant object=<shared.t | shared.t (columns)> privilege=<p> grantor=<role> by_owner=<t|f>   (CIS 351)
  SCRIPT contract view=<catalog.v> tripplanner_select=<t|f> exists=<t|f>   (kept by 351)
  SCRIPT verdict drop_ready=<true|false> revoke_ready=<true|false> reasons=<…>
drop_ready: the table exists or is already gone, nothing depends on it, no row written in the last hour (tp-025's
guard). revoke_ready: every tripplanner grant on shared.llm_role_config / shared.llm_model_catalog was made by the
table's owner (cis_owner), so cis_owner's REVOKE in 351 removes it, and tripplanner can read both contract views.
After both applies the same run is the verify: exists=f, no cis_grant line ("cis_grant none=t"), both views t.
"""

READ_ONLY = True

TABLE = "tripplanner.llm_spend_daily"
ONLINE_STAGES = ["tp_compose", "tp_search_embed"]  # TripPlanner llm_gateway.ONLINE_STAGES
CIS_351_TABLES = ("shared.llm_role_config", "shared.llm_model_catalog")
CONTRACT_VIEWS = ("catalog.v_llm_gateway_config_v1", "catalog.v_llm_app_spend_today_v1")
WRITE_GUARD = "1 hour"  # tp-025: no row written within this interval

SUMMARY_SQL = """
SELECT count(*) AS rows, count(DISTINCT day) AS days, min(day) AS first_day, max(day) AS last_day,
       max(updated_at) AS last_write, coalesce(sum(cost_usd), 0) AS cost_usd, coalesce(sum(calls), 0) AS calls,
       coalesce(max(updated_at) > now() - interval '1 hour', false) AS recent
  FROM tripplanner.llm_spend_daily
"""

LEDGER_SQL = """
SELECT count(DISTINCT (created_at AT TIME ZONE 'UTC')::date) AS days, coalesce(sum(cost_usd), 0) AS cost_usd,
       count(*) AS calls
  FROM shared.llm_call_log
 WHERE app = 'tripplanner' AND stage = ANY($1::text[])
   AND created_at >= ($2::date)::timestamp AT TIME ZONE 'UTC'
   AND created_at < ($3::date + 1)::timestamp AT TIME ZONE 'UTC'
"""

STAT_SQL = """
SELECT s.seq_scan, coalesce(s.idx_scan, 0) AS idx_scan, s.n_tup_ins, s.n_tup_upd, s.n_tup_del,
       pg_total_relation_size(s.relid) AS bytes
  FROM pg_stat_user_tables s WHERE s.relid = $1::text::regclass
"""

DEPENDENTS_SQL = """
SELECT DISTINCT v.oid::regclass::text AS dep, 'view' AS kind
  FROM pg_depend d
  JOIN pg_rewrite r ON r.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
  JOIN pg_class v ON v.oid = r.ev_class
 WHERE d.refobjid = $1::text::regclass AND v.oid <> $1::text::regclass
UNION
SELECT c.conrelid::regclass::text || ' (' || c.conname || ')', 'fk'
  FROM pg_constraint c
 WHERE c.contype = 'f' AND c.confrelid = $1::text::regclass AND c.conrelid <> $1::text::regclass
 ORDER BY 1
"""

GRANTS_SQL = """
SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END AS grantee,
       string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type) AS privileges
  FROM pg_class c, aclexplode(c.relacl) a
 WHERE c.oid = $1::text::regclass AND a.grantee <> c.relowner
 GROUP BY 1 ORDER BY 1
"""

# The tripplanner grants CIS 351 revokes: table and column level, with grantor and whether it is the owner.
CIS_GRANTS_SQL = """
WITH f AS (SELECT array_agg(x::regclass) AS oids FROM unnest($1::text[]) x)
SELECT c.oid::regclass::text AS object, a.privilege_type AS privilege, pg_get_userbyid(a.grantor) AS grantor,
       a.grantor = c.relowner AS by_owner
  FROM f, pg_class c, aclexplode(c.relacl) a
 WHERE c.oid = ANY(f.oids) AND a.grantee = 'tripplanner'::regrole
UNION
SELECT DISTINCT c.oid::regclass::text || ' (columns)', a.privilege_type, pg_get_userbyid(a.grantor),
       a.grantor = c.relowner
  FROM f
  JOIN pg_class c ON c.oid = ANY(f.oids)
  JOIN pg_attribute att ON att.attrelid = c.oid AND att.attnum > 0 AND NOT att.attisdropped
 CROSS JOIN LATERAL aclexplode(att.attacl) a
 WHERE a.grantee = 'tripplanner'::regrole
 ORDER BY 1, 2
"""

STATEMENTS_SQL = """
SELECT pg_get_userbyid(s.userid) AS role, coalesce(sum(s.calls), 0) AS calls
  FROM pg_stat_statements s
 WHERE s.query ~* '\\mtripplanner\\.llm_spend_daily\\M'
 GROUP BY 1 ORDER BY 1
"""


def _ts(v) -> str:
    return v.isoformat() if v is not None else "-"


def _usd(v) -> str:
    return f"{float(v):.6f}"


async def _exists(conn, rel: str) -> bool:
    return await conn.fetchval("SELECT to_regclass($1) IS NOT NULL", rel)


async def main(conn):
    reasons = []
    if await _exists(conn, TABLE):
        s = await conn.fetchrow(SUMMARY_SQL)
        st = await conn.fetchrow(STAT_SQL, TABLE)
        print(f"SCRIPT table name={TABLE} exists=t rows={s['rows']} days={s['days']} "
              f"first_day={s['first_day'] or '-'} last_day={s['last_day'] or '-'} last_write={_ts(s['last_write'])} "
              f"cost_usd={_usd(s['cost_usd'])} calls={s['calls']} bytes={st['bytes']} seq_scan={st['seq_scan']} "
              f"idx_scan={st['idx_scan']} ins={st['n_tup_ins']} upd={st['n_tup_upd']} del={st['n_tup_del']}")
        if s["recent"]:
            reasons.append(f"written_within:{WRITE_GUARD.replace(' ', '_')}")
        if s["first_day"] is not None:
            led = await conn.fetchrow(LEDGER_SQL, ONLINE_STAGES, s["first_day"], s["last_day"])
            print(f"SCRIPT ledger days={led['days']} cost_usd={_usd(led['cost_usd'])} calls={led['calls']}")
        for d in await conn.fetch(DEPENDENTS_SQL, TABLE):
            print(f"SCRIPT dependent object={d['dep']} kind={d['kind']}")
            reasons.append(f"dependent:{d['dep']}")
        for g in await conn.fetch(GRANTS_SQL, TABLE):
            print(f"SCRIPT grant table={TABLE} grantee={g['grantee']} privileges={g['privileges']}")
    else:
        print(f"SCRIPT table name={TABLE} exists=f")

    reset = await conn.fetchval("SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()")
    print(f"SCRIPT stats_reset database={_ts(reset)}")
    if await conn.fetchval("SELECT to_regclass('public.pg_stat_statements') IS NOT NULL"):
        try:
            rows = await conn.fetch(STATEMENTS_SQL)
        except Exception as e:  # noqa: BLE001 - e.g. no permission on another role's statements
            print(f"SCRIPT statements error={type(e).__name__}")
            rows = None
        if rows is not None:
            for r in rows:
                print(f"SCRIPT statements role={r['role']} calls={r['calls']}")
            if not rows:
                print("SCRIPT statements none=t")
    else:
        print("SCRIPT statements unavailable=pg_stat_statements")

    revoke_ready = True
    if await conn.fetchval("SELECT to_regrole('tripplanner') IS NOT NULL"):
        rels = [r for r in CIS_351_TABLES if await _exists(conn, r)]
        grants = list(await conn.fetch(CIS_GRANTS_SQL, rels)) if rels else []
        for g in grants:
            print(f"SCRIPT cis_grant object={g['object']} privilege={g['privilege']} grantor={g['grantor']} "
                  f"by_owner={'t' if g['by_owner'] else 'f'}")
            if not g["by_owner"]:
                revoke_ready = False
        if not grants:
            print("SCRIPT cis_grant none=t")
        for v in CONTRACT_VIEWS:
            exists = await _exists(conn, v)
            ok = bool(exists) and await conn.fetchval("SELECT has_table_privilege('tripplanner', $1, 'SELECT')", v)
            print(f"SCRIPT contract view={v} tripplanner_select={'t' if ok else 'f'} exists={'t' if exists else 'f'}")
            if not ok:
                revoke_ready = False
    drop_ready = not reasons
    print(f"SCRIPT verdict drop_ready={'true' if drop_ready else 'false'} "
          f"revoke_ready={'true' if revoke_ready else 'false'} reasons={','.join(reasons) or '-'}")
    return 0
