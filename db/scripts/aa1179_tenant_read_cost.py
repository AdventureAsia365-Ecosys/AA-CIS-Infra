"""AA-1179 (S293, C4.3 W48 findings 1 and 3), read-only: the cost per call of the CIS tenant served-badge lookup and of
the anomaly-breaker baseline, old vs new, on live Dev.

1. shared/tour_liveness.py REQUEST_TOURS_SQL: the W48 statement (a LEFT JOIN of gold_aa_internal.v_tour_liveness on the
   key expression, before S291) and today's (S291: the representative tour once per row, a LATERAL one-key lookup of
   the view, CIS 480 index). Typical inputs, for the 3 tenants with the most angle-gate requests: their newest request
   (the 409 checks), their 8 and 50 newest (a /v1 list page), and up to 8 whose representative tour's key is retired
   (the Subject rule branch). As the master, and as aa_app_user (the tenant pool's role, app.tenant_id set) when the
   master may switch to it.
2. shared/llm_client/anomaly_breaker.py BASELINE_SQL: W48 (rolled test per ledger row), S291 (one grouped scan of the
   window) and S293 (one sum per UTC day on a created_at range); per app with AI, baselines of 7, 14 and 28 days.

Why no EXPLAIN: the run-script PII guard (AA-969) plans every statement with EXPLAIN (VERBOSE, FORMAT JSON) first and
refuses what it cannot plan, so an EXPLAIN statement is refused (S291). Instead, per statement and input:
  - REPEATS timed calls (client ms: p50, p95, max);
  - pg_stat_statements deltas of the statement (calls, execution ms, shared hit / read and temp blocks written per
    call); each statement is wrapped as SELECT /* aa1179_probe ... */ q.* FROM (<statement>) q, so its query id is
    this script's own and never shares counters with the app's calls. A comment does not change a query id, so one
    entry serves every input of a statement and keeps the text of its first call: the delta is taken over every entry
    whose text holds MARK (one measurement runs at a time, so only the running one moves);
  - pg_stat_xact_user_tables deltas inside the calls' transaction: per table, sequential and index scans per call
    (table names and counts).
Then a verdict line per check of the issue's Done-when: buffers per call old / new >= 5, new p95 < 150 ms, baseline
temp written 0. Output lines start with `SCRIPT `: counts, timings and relation / index names only (no row values, no
ids). Time budget BUDGET_S. Always returns 0.

Dispatch (after merge): DB Migrate, mode=run-script, script=db/scripts/aa1179_tenant_read_cost.py. Read the output:
`gh api repos/AdventureAsia365-Ecosys/AA-CIS-Infra/actions/jobs/<id>/logs | grep -o 'SCRIPT .*'`.
The SQL below is copied verbatim from AA-CIS-App (tests/integration/test_aa838_request_tours_sql.py,
tests/integration/test_aa1126_gateway_caps_sql.py, shared/tour_liveness.py, shared/llm_client/anomaly_breaker.py).
"""

import datetime
import math
import time
import uuid

READ_ONLY = True

REPEATS = 20
BUDGET_S = 20 * 60
TENANTS = 3
MARK = "aa1179_probe"
ROLE = "aa_app_user"
TARGET_BUFFER_RATIO = 5.0
TARGET_P95_MS = 150.0

# ── statements (verbatim) ──────────────────────────────────────────────────────────────────────────────────────────
W48_REQUEST_TOURS_SQL = "\n    SELECT r.request_id::text AS request_id,\n           (CASE WHEN tl_rq.state = 'retired'\n                 THEN COALESCE((SELECT ta_mt.tour_id FROM acp_shared.subject s_mt\n          JOIN acp_contract.atom_segment_member m_mt\n            ON m_mt.segment_id IN (s_mt.segment_id, (SELECT a_mt.segment_id_canonical\n                 FROM acp_contract.atom_segment_alias a_mt WHERE a_mt.segment_id_old = s_mt.segment_id))\n          JOIN acp_contract.tour_atoms ta_mt ON ta_mt.atom_id = m_mt.atom_id AND NOT ta_mt.deleted\n               AND NOT ta_mt.is_empty_marker\n          JOIN gold_aa_internal.published_tours pt_mt\n      ON pt_mt.tour_id = ta_mt.tour_id AND pt_mt.master_status = 'active' AND pt_mt.deleted_at IS NULL\n    JOIN silver_aa_internal.raw_tours rt_mt\n      ON rt_mt.tour_id = pt_mt.tour_id AND rt_mt.source_status = 'active' AND rt_mt.deleted_at IS NULL\n         WHERE s_mt.subject_id = r.subject_id AND s_mt.tenant_id = r.tenant_id\n           AND s_mt.segment_id IS NOT NULL\n         ORDER BY ta_mt.tour_id LIMIT 1), COALESCE(r.trip_id, ta.tour_id))\n                 ELSE COALESCE(r.trip_id, ta.tour_id) END)::text AS tour_id\n      FROM acp_shared.angle_gate_request r\n      LEFT JOIN acp_contract.tour_atoms ta ON ta.atom_id = r.atom_id\n      LEFT JOIN silver_aa_internal.raw_tours rt_rq ON rt_rq.tour_id = COALESCE(r.trip_id, ta.tour_id)\n      LEFT JOIN gold_aa_internal.v_tour_liveness tl_rq\n        ON tl_rq.source_id = (COALESCE(rt_rq.source_group_id, rt_rq.tour_id))::text\n     WHERE r.request_id = ANY($1::uuid[]) AND r.tenant_id = $2::uuid\n"
S291_REQUEST_TOURS_SQL = "\n    SELECT r.request_id::text AS request_id,\n           (CASE WHEN lv_rq.state = 'retired'\n                 THEN COALESCE((SELECT ta_mt.tour_id FROM acp_shared.subject s_mt\n          JOIN acp_contract.atom_segment_member m_mt\n            ON m_mt.segment_id IN (s_mt.segment_id, (SELECT a_mt.segment_id_canonical\n                 FROM acp_contract.atom_segment_alias a_mt WHERE a_mt.segment_id_old = s_mt.segment_id))\n          JOIN acp_contract.tour_atoms ta_mt ON ta_mt.atom_id = m_mt.atom_id AND NOT ta_mt.deleted\n               AND NOT ta_mt.is_empty_marker\n          JOIN gold_aa_internal.published_tours pt_mt\n      ON pt_mt.tour_id = ta_mt.tour_id AND pt_mt.master_status = 'active' AND pt_mt.deleted_at IS NULL\n    JOIN silver_aa_internal.raw_tours rt_mt\n      ON rt_mt.tour_id = pt_mt.tour_id AND rt_mt.source_status = 'active' AND rt_mt.deleted_at IS NULL\n         WHERE s_mt.subject_id = r.subject_id AND s_mt.tenant_id = r.tenant_id\n           AND s_mt.segment_id IS NOT NULL\n         ORDER BY ta_mt.tour_id LIMIT 1), rep.tour_id)\n                 ELSE rep.tour_id END)::text AS tour_id\n      FROM acp_shared.angle_gate_request r\n      LEFT JOIN acp_contract.tour_atoms ta ON ta.atom_id = r.atom_id\n     CROSS JOIN LATERAL (SELECT COALESCE(r.trip_id, ta.tour_id) AS tour_id) rep\n      LEFT JOIN silver_aa_internal.raw_tours rt_rq ON rt_rq.tour_id = rep.tour_id\n      LEFT JOIN LATERAL (\n            SELECT tl_rq.state\n              FROM gold_aa_internal.v_tour_liveness tl_rq\n             WHERE tl_rq.source_id = (COALESCE(rt_rq.source_group_id, rt_rq.tour_id))::text\n            OFFSET 0\n           ) lv_rq ON true\n     WHERE r.request_id = ANY($1::uuid[]) AND r.tenant_id = $2::uuid\n"
W48_BASELINE_SQL = "\n    WITH days AS (\n        SELECT generate_series($1::date, $2::date - 1, interval '1 day')::date AS day\n    ), rolled AS (\n        SELECT d.day, sum(d.cost_usd)::float AS usd\n          FROM shared.llm_call_daily d\n         WHERE d.day >= $1 AND d.day < $2 AND d.app = $3\n         GROUP BY 1\n    ), raw AS (\n        SELECT (l.created_at AT TIME ZONE 'UTC')::date AS day, coalesce(sum(l.cost_usd), 0)::float AS usd\n          FROM shared.llm_call_log l\n         WHERE l.created_at >= ($1::date::timestamp AT TIME ZONE 'UTC')\n           AND l.created_at < ($2::date::timestamp AT TIME ZONE 'UTC')\n           AND coalesce(l.app, l.quality_signal ->> 'app', 'cis') = $3\n           AND NOT EXISTS (SELECT 1 FROM shared.llm_call_daily d\n                            WHERE d.day = (l.created_at AT TIME ZONE 'UTC')::date)\n         GROUP BY 1\n    )\n    SELECT coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(r.usd, w.usd, 0)), 0)::float AS median\n      FROM days\n      LEFT JOIN rolled r USING (day)\n      LEFT JOIN raw w USING (day)\n"
S291_BASELINE_SQL = "\n    WITH days AS (\n        SELECT generate_series($1::date, $2::date - 1, interval '1 day')::date AS day\n    ), rolled AS (\n        SELECT d.day, sum(d.cost_usd)::float AS usd\n          FROM shared.llm_call_daily d\n         WHERE d.day >= $1 AND d.day < $2 AND d.app = $3\n         GROUP BY 1\n    ), raw_days AS (\n        SELECT (l.created_at AT TIME ZONE 'UTC')::date AS day, coalesce(sum(l.cost_usd), 0)::float AS usd\n          FROM shared.llm_call_log l\n         WHERE l.created_at >= ($1::date::timestamp AT TIME ZONE 'UTC')\n           AND l.created_at < ($2::date::timestamp AT TIME ZONE 'UTC')\n           AND coalesce(l.app, l.quality_signal ->> 'app', 'cis') = $3\n         GROUP BY 1\n    ), raw AS (\n        SELECT g.day, g.usd\n          FROM raw_days g\n         WHERE NOT EXISTS (SELECT 1 FROM shared.llm_call_daily d WHERE d.day = g.day)\n    )\n    SELECT coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(r.usd, w.usd, 0)), 0)::float AS median\n      FROM days\n      LEFT JOIN rolled r USING (day)\n      LEFT JOIN raw w USING (day)\n"
S293_BASELINE_SQL = "\n    WITH days AS (\n        SELECT generate_series($1::date, $2::date - 1, interval '1 day')::date AS day\n    ), rolled AS (\n        SELECT d.day, sum(d.cost_usd)::float AS usd\n          FROM shared.llm_call_daily d\n         WHERE d.day >= $1 AND d.day < $2 AND d.app = $3\n         GROUP BY 1\n    )\n    SELECT coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(r.usd, w.usd, 0)), 0)::float AS median\n      FROM days\n      LEFT JOIN rolled r USING (day)\n      LEFT JOIN LATERAL (\n            SELECT sum(l.cost_usd)::float AS usd\n              FROM shared.llm_call_log l\n             WHERE l.created_at >= (days.day::timestamp AT TIME ZONE 'UTC')\n               AND l.created_at < ((days.day + 1)::timestamp AT TIME ZONE 'UTC')\n               AND coalesce(l.app, l.quality_signal ->> 'app', 'cis') = $3\n               AND NOT EXISTS (SELECT 1 FROM shared.llm_call_daily d WHERE d.day = days.day)\n           ) w ON true\n"

REQUEST_TOURS = (("w48", W48_REQUEST_TOURS_SQL), ("s291", S291_REQUEST_TOURS_SQL))
BASELINES = (("w48", W48_BASELINE_SQL), ("s291", S291_BASELINE_SQL), ("s293", S293_BASELINE_SQL))
APPS = ("cis", "tripplanner", "crm")
BASELINE_DAYS = (7, 14, 28)

# ── inputs (ids are read here and passed back as parameters, never printed) ─────────────────────────────────────────
TOP_TENANTS_SQL = """
    SELECT r.tenant_id::text AS tenant_id, count(*) AS n
      FROM acp_shared.angle_gate_request r
     GROUP BY r.tenant_id ORDER BY count(*) DESC, r.tenant_id LIMIT $1
"""
NEWEST_SQL = """
    SELECT r.request_id::text AS request_id FROM acp_shared.angle_gate_request r
     WHERE r.tenant_id = $1::uuid ORDER BY r.created_at DESC, r.request_id LIMIT $2
"""
RETIRED_SQL = """
    SELECT r.request_id::text AS request_id
      FROM acp_shared.angle_gate_request r
      LEFT JOIN acp_contract.tour_atoms ta ON ta.atom_id = r.atom_id
      JOIN silver_aa_internal.raw_tours rt ON rt.tour_id = COALESCE(r.trip_id, ta.tour_id)
      JOIN gold_aa_internal.v_tour_liveness tl ON tl.source_id = (COALESCE(rt.source_group_id, rt.tour_id))::text
     WHERE r.tenant_id = $1::uuid AND tl.state = 'retired'
     ORDER BY r.created_at DESC, r.request_id LIMIT $2
"""
INPUTS = (("one", NEWEST_SQL, 1), ("page8", NEWEST_SQL, 8), ("page50", NEWEST_SQL, 50), ("retired8", RETIRED_SQL, 8))

PGSS_EXT_SQL = """
    SELECT n.nspname AS schema FROM pg_catalog.pg_extension e JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
     WHERE e.extname = 'pg_stat_statements'
"""
INDEX_SQL = "SELECT to_regclass('silver_aa_internal.raw_tours_key_expr_idx') IS NOT NULL AS present"
MEMBER_SQL = "SELECT pg_has_role(current_user, $1, 'MEMBER') AS ok"
SETTING_SQL = "SELECT current_setting($1, true) AS value"
TENANT_SQL = "SELECT set_config('app.tenant_id', $1, true) AS ok"
# Per-backend counters of the open transaction (no privilege needed): sequential and index scans per table. There is
# no transaction-level view per index, so the index names are not shown; an idx count on raw_tours with no seq count is
# the CIS 480 key index (or the primary key) at work.
XACT_TABLES_SQL = """
    SELECT schemaname || '.' || relname AS rel, coalesce(seq_scan, 0) AS seq, coalesce(idx_scan, 0) AS idx
      FROM pg_catalog.pg_stat_xact_user_tables
"""


def pgss_sql(schema: str) -> str:
    """Sum of the pg_stat_statements rows whose text holds MARK (any role, any statement of this script); the PII
    guard's EXPLAIN utility rows are left out."""
    assert schema.replace("_", "").isalnum()
    return f"""
        SELECT coalesce(sum(s.calls), 0)::bigint AS calls, coalesce(sum(s.total_exec_time), 0)::float AS ms,
               coalesce(sum(s.shared_blks_hit), 0)::bigint AS hit, coalesce(sum(s.shared_blks_read), 0)::bigint AS rd,
               coalesce(sum(s.temp_blks_written), 0)::bigint AS temp_w, coalesce(sum(s.rows), 0)::bigint AS nrows
          FROM {schema}.pg_stat_statements s
         WHERE s.toplevel AND s.query LIKE $1 AND s.query NOT LIKE '%EXPLAIN%'
    """


def marker(check: str, label: str, variant: str, role: str) -> str:
    out = f"{MARK} {check} {label} {variant} {role}"
    assert all(c.isalnum() or c in " _" for c in out), out
    return out


def wrapped(sql: str, mark: str) -> str:
    """The statement as a subquery under the marker comment: its own query id, the same plan below the wrapper."""
    return f"SELECT /* {mark} */ q.* FROM ({sql}) q"


def percentile(values, p: float) -> float:
    """Nearest-rank percentile (p in 0..100) of a non-empty list. Pure."""
    s = sorted(values)
    k = max(0, min(len(s) - 1, math.ceil(p / 100.0 * len(s)) - 1))
    return s[k]


def deltas(before: dict, after: dict) -> dict:
    """Positive per-key differences of two counter maps (names that did not move are left out). Pure."""
    return {k: after.get(k, 0) - before.get(k, 0) for k in after if after.get(k, 0) - before.get(k, 0) > 0}


def fmt_counts(d: dict, calls: int) -> str:
    if not d:
        return "-"
    return ",".join(f"{k}:{v / calls:g}" for k, v in sorted(d.items(), key=lambda kv: (-kv[1], kv[0])))


class Budget:
    def __init__(self, seconds):
        self.seconds, self.t0 = seconds, time.monotonic()

    def left(self):
        return self.seconds - (time.monotonic() - self.t0)


async def _xact(conn) -> tuple:
    seq, idx = {}, {}
    for r in await conn.fetch(XACT_TABLES_SQL):
        seq[r["rel"]] = r["seq"]
        idx[r["rel"]] = r["idx"]
    return seq, idx


async def _pgss(conn, schema, mark) -> dict:
    if not schema:
        return {}
    r = await conn.fetchrow(pgss_sql(schema), f"%{mark}%")
    return dict(r) if r else {}


async def measure(conn, schema, *, check, label, variant, sql, args, role=None, tenant=None):
    """REPEATS calls of one statement; prints one `SCRIPT cost` line; returns the summary dict or None on an error."""
    who = role or "master"
    mark = marker(check, label, variant, who)
    stmt = wrapped(sql, mark)
    try:
        before = await _pgss(conn, schema, MARK)
        times, nrows = [], 0
        async with conn.transaction():
            if role:
                await conn.execute(f"SET LOCAL ROLE {role}")
            if tenant:
                await conn.fetchval(TENANT_SQL, str(uuid.UUID(tenant)))
            seq0, idx0 = await _xact(conn)
            for _ in range(REPEATS):
                t0 = time.perf_counter()
                rows = await conn.fetch(stmt, *args)
                times.append((time.perf_counter() - t0) * 1000.0)
                nrows = len(rows)
            seq1, idx1 = await _xact(conn)
            if role:
                await conn.execute("RESET ROLE")
        after = await _pgss(conn, schema, MARK)
    except Exception as e:  # noqa: BLE001 — the class only, never the message (it can quote a value)
        print(f"SCRIPT error check={check} label={label} variant={variant} role={who} error={type(e).__name__}",
              flush=True)
        return None
    d = {k: after.get(k, 0) - before.get(k, 0) for k in ("calls", "ms", "hit", "rd", "temp_w")} if after else {}
    calls = d.get("calls") or 0
    per = (lambda k: round(d[k] / calls, 1)) if calls else (lambda k: None)
    seq, idx = deltas(seq0, seq1), deltas(idx0, idx1)
    out = {"p50": percentile(times, 50), "p95": percentile(times, 95), "max": max(times), "rows": nrows,
           "pgss_calls": calls, "mean_ms": per("ms"), "hit": per("hit"), "read": per("rd"),
           "temp_w": d.get("temp_w"), "seq": seq, "idx": idx}
    print(f"SCRIPT cost check={check} label={label} variant={variant} role={who} rows={nrows} calls={REPEATS} "
          f"p50_ms={out['p50']:.1f} p95_ms={out['p95']:.1f} max_ms={out['max']:.1f} pgss_calls={calls} "
          f"pgss_mean_ms={out['mean_ms']} hit_per_call={out['hit']} read_per_call={out['read']} "
          f"temp_w_total={out['temp_w']} seq_scans={fmt_counts(seq, REPEATS)} idx_scans={fmt_counts(idx, REPEATS)}",
          flush=True)
    return out


def buffers(m) -> float:
    return (m["hit"] or 0) + (m["read"] or 0) if m else 0.0


async def main(conn):
    budget = Budget(BUDGET_S)
    schema = await conn.fetchval(PGSS_EXT_SQL)
    can_role = bool(await conn.fetchval(MEMBER_SQL, ROLE))
    print(f"SCRIPT setup pgss_schema={'yes' if schema else 'missing'} key_expr_idx="
          f"{await conn.fetchval(INDEX_SQL)} master_may_set_role_{ROLE}={can_role} "
          f"jit={await conn.fetchval(SETTING_SQL, 'jit')} work_mem={await conn.fetchval(SETTING_SQL, 'work_mem')} "
          f"repeats={REPEATS}", flush=True)
    roles = (None, ROLE) if can_role else (None,)

    # 1. REQUEST_TOURS_SQL
    rt = {}
    tenants = await conn.fetch(TOP_TENANTS_SQL, TENANTS)
    for ti, t in enumerate(tenants):
        tenant = t["tenant_id"]
        for name, sql, n in INPUTS:
            if budget.left() < 60:
                print(f"SCRIPT truncated section=request_tours tenant_rank={ti + 1} input={name}", flush=True)
                break
            ids = [r["request_id"] for r in await conn.fetch(sql, tenant, n)]
            print(f"SCRIPT input check=request_tours tenant_rank={ti + 1} tenant_requests={t['n']} input={name} "
                  f"ids={len(ids)}", flush=True)
            if not ids:
                continue
            for role in roles:
                for variant, stmt in REQUEST_TOURS:
                    rt[(ti, name, role, variant)] = await measure(
                        conn, schema, check="request_tours", label=f"t{ti + 1}_{name}", variant=variant, sql=stmt,
                        args=(ids, tenant), role=role, tenant=tenant)

    # 2. BASELINE_SQL
    bl = {}
    today = datetime.datetime.now(datetime.timezone.utc).date()
    for app in APPS:
        for days in BASELINE_DAYS:
            if budget.left() < 60:
                print(f"SCRIPT truncated section=baseline app={app} days={days}", flush=True)
                break
            start = today - datetime.timedelta(days=days)
            for variant, stmt in BASELINES:
                bl[(app, days, variant)] = await measure(
                    conn, schema, check="baseline", label=f"{app}_{days}d", variant=variant, sql=stmt,
                    args=(start, today, app))

    # 3. verdicts (the issue's Done-when)
    ratios, p95s = [], []
    for (ti, name, role, variant), m in rt.items():
        if variant != "s291" or not m:
            continue
        old = rt.get((ti, name, role, "w48"))
        if old and buffers(m):
            ratios.append(buffers(old) / buffers(m))
        p95s.append(m["p95"])
    temps = [m["temp_w"] or 0 for (_, _, v), m in bl.items() if v == "s293" and m]
    if ratios:
        print(f"SCRIPT verdict request_tours buffers_ratio_min={min(ratios):.1f} buffers_ratio_median="
              f"{sorted(ratios)[len(ratios) // 2]:.1f} target>={TARGET_BUFFER_RATIO} "
              f"ok={min(ratios) >= TARGET_BUFFER_RATIO}", flush=True)
    if p95s:
        print(f"SCRIPT verdict request_tours new_p95_max_ms={max(p95s):.1f} target<{TARGET_P95_MS} "
              f"ok={max(p95s) < TARGET_P95_MS}", flush=True)
    if temps:
        print(f"SCRIPT verdict baseline new_temp_written_max={max(temps)} target=0 ok={max(temps) == 0}", flush=True)
    print(f"SCRIPT done seconds={time.monotonic() - budget.t0:.0f}", flush=True)
    return 0


if __name__ == "__main__":  # local: python3 aa1179_tenant_read_cost.py <DSN> (a throwaway database)
    import asyncio
    import sys

    import asyncpg

    async def _local():
        c = await asyncpg.connect(sys.argv[1])
        try:
            await main(c)
        finally:
            await c.close()
    asyncio.run(_local())
