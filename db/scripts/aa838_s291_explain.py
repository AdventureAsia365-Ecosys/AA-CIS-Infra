"""AA-838 / AA-1126 (S291, C4.3 W48 findings 1 and 3), read-only: old vs new plans of the CIS reads changed in S291.

1. shared/tour_liveness.py REQUEST_TOURS_SQL (the tenant served-badge lookup): the statement before S291 (a LEFT JOIN of
   gold_aa_internal.v_tour_liveness on the key expression) and the S291 one (a LATERAL one-key lookup with OFFSET 0),
   for the tenant with the most angle-gate requests: its 8 newest requests, and up to 8 whose representative tour's
   key is retired (the Subject rule branch). As the master, and as aa_app_user (the tenant pool's role, app.tenant_id
   set) when that works. Also: is raw_tours_key_expr_idx (CIS 480) present, and does the new plan use it.
2. shared/llm_client/anomaly_breaker.py TODAY_SQL / BASELINE_SQL (role cis_app on Dev): TODAY_SQL is unchanged after the
   review fix (old = new, a control pair); BASELINE_SQL moves the rolled-day test from every row to every grouped day; per app with AI, today since UTC midnight and baselines of 14 and 28 days.
3. api/routers/admin.py Tenant 360 cost sums: `tenant_id = $1 OR ($2 AND tenant_id IS NULL)` and the two-branch
   statements, for the internal tenant and the non-internal tenant with the most ledger rows, all time and 30 days.

Each statement: PREPARE, EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) EXECUTE once (execution ms, shared hit / read, temp
written, top plan nodes), then REPEATS timed EXECUTEs; parity = the old and new results are equal (compared in the
script, never printed). Output lines start with `SCRIPT `: counts, timings, plan node types and relation / index names
only (no row values, no ids). Time budget BUDGET_S. Always returns 0.

Dispatch (after the orchestrator copies it to AA-CIS-Infra db/scripts/aa838_s291_explain.py): DB Migrate,
mode=run-script, script=db/scripts/aa838_s291_explain.py. Read the output:
`gh api repos/AdventureAsia365-Ecosys/AA-CIS-Infra/actions/jobs/<id>/logs | grep -o 'SCRIPT .*'`.
Generated from the AA-CIS-App S291 code PR's statements (the SQL below is copied verbatim).
"""

import datetime
import json
import statistics
import time
import uuid

READ_ONLY = True

REPEATS = 3
BUDGET_S = 20 * 60
TOP_NODES = 6
SAMPLE = 8
AA_MASTER = "00000000-0000-0000-0000-000000000001"

OLD_REQUEST_TOURS_SQL = "\n    SELECT r.request_id::text AS request_id,\n           (CASE WHEN tl_rq.state = 'retired'\n                 THEN COALESCE((SELECT ta_mt.tour_id FROM acp_shared.subject s_mt\n          JOIN acp_contract.atom_segment_member m_mt\n            ON m_mt.segment_id IN (s_mt.segment_id, (SELECT a_mt.segment_id_canonical\n                 FROM acp_contract.atom_segment_alias a_mt WHERE a_mt.segment_id_old = s_mt.segment_id))\n          JOIN acp_contract.tour_atoms ta_mt ON ta_mt.atom_id = m_mt.atom_id AND NOT ta_mt.deleted\n               AND NOT ta_mt.is_empty_marker\n          JOIN gold_aa_internal.published_tours pt_mt\n      ON pt_mt.tour_id = ta_mt.tour_id AND pt_mt.master_status = 'active' AND pt_mt.deleted_at IS NULL\n    JOIN silver_aa_internal.raw_tours rt_mt\n      ON rt_mt.tour_id = pt_mt.tour_id AND rt_mt.source_status = 'active' AND rt_mt.deleted_at IS NULL\n         WHERE s_mt.subject_id = r.subject_id AND s_mt.tenant_id = r.tenant_id\n           AND s_mt.segment_id IS NOT NULL\n         ORDER BY ta_mt.tour_id LIMIT 1), COALESCE(r.trip_id, ta.tour_id))\n                 ELSE COALESCE(r.trip_id, ta.tour_id) END)::text AS tour_id\n      FROM acp_shared.angle_gate_request r\n      LEFT JOIN acp_contract.tour_atoms ta ON ta.atom_id = r.atom_id\n      LEFT JOIN silver_aa_internal.raw_tours rt_rq ON rt_rq.tour_id = COALESCE(r.trip_id, ta.tour_id)\n      LEFT JOIN gold_aa_internal.v_tour_liveness tl_rq\n        ON tl_rq.source_id = (COALESCE(rt_rq.source_group_id, rt_rq.tour_id))::text\n     WHERE r.request_id = ANY($1::uuid[]) AND r.tenant_id = $2::uuid\n"
NEW_REQUEST_TOURS_SQL = "\n    SELECT r.request_id::text AS request_id,\n           (CASE WHEN lv_rq.state = 'retired'\n                 THEN COALESCE((SELECT ta_mt.tour_id FROM acp_shared.subject s_mt\n          JOIN acp_contract.atom_segment_member m_mt\n            ON m_mt.segment_id IN (s_mt.segment_id, (SELECT a_mt.segment_id_canonical\n                 FROM acp_contract.atom_segment_alias a_mt WHERE a_mt.segment_id_old = s_mt.segment_id))\n          JOIN acp_contract.tour_atoms ta_mt ON ta_mt.atom_id = m_mt.atom_id AND NOT ta_mt.deleted\n               AND NOT ta_mt.is_empty_marker\n          JOIN gold_aa_internal.published_tours pt_mt\n      ON pt_mt.tour_id = ta_mt.tour_id AND pt_mt.master_status = 'active' AND pt_mt.deleted_at IS NULL\n    JOIN silver_aa_internal.raw_tours rt_mt\n      ON rt_mt.tour_id = pt_mt.tour_id AND rt_mt.source_status = 'active' AND rt_mt.deleted_at IS NULL\n         WHERE s_mt.subject_id = r.subject_id AND s_mt.tenant_id = r.tenant_id\n           AND s_mt.segment_id IS NOT NULL\n         ORDER BY ta_mt.tour_id LIMIT 1), rep.tour_id)\n                 ELSE rep.tour_id END)::text AS tour_id\n      FROM acp_shared.angle_gate_request r\n      LEFT JOIN acp_contract.tour_atoms ta ON ta.atom_id = r.atom_id\n     CROSS JOIN LATERAL (SELECT COALESCE(r.trip_id, ta.tour_id) AS tour_id) rep\n      LEFT JOIN silver_aa_internal.raw_tours rt_rq ON rt_rq.tour_id = rep.tour_id\n      LEFT JOIN LATERAL (\n            SELECT tl_rq.state\n              FROM gold_aa_internal.v_tour_liveness tl_rq\n             WHERE tl_rq.source_id = (COALESCE(rt_rq.source_group_id, rt_rq.tour_id))::text\n            OFFSET 0\n           ) lv_rq ON true\n     WHERE r.request_id = ANY($1::uuid[]) AND r.tenant_id = $2::uuid\n"
OLD_TODAY_SQL = "\n    SELECT coalesce(sum(l.cost_usd), 0)::float AS usd\n      FROM shared.llm_call_log l\n     WHERE l.created_at >= $1 AND coalesce(l.app, l.quality_signal ->> 'app', 'cis') = $2\n"
NEW_TODAY_SQL = "\n    SELECT coalesce(sum(l.cost_usd), 0)::float AS usd\n      FROM shared.llm_call_log l\n     WHERE l.created_at >= $1 AND coalesce(l.app, l.quality_signal ->> 'app', 'cis') = $2\n"
OLD_BASELINE_SQL = "\n    WITH days AS (\n        SELECT generate_series($1::date, $2::date - 1, interval '1 day')::date AS day\n    ), rolled AS (\n        SELECT d.day, sum(d.cost_usd)::float AS usd\n          FROM shared.llm_call_daily d\n         WHERE d.day >= $1 AND d.day < $2 AND d.app = $3\n         GROUP BY 1\n    ), raw AS (\n        SELECT (l.created_at AT TIME ZONE 'UTC')::date AS day, coalesce(sum(l.cost_usd), 0)::float AS usd\n          FROM shared.llm_call_log l\n         WHERE l.created_at >= ($1::date::timestamp AT TIME ZONE 'UTC')\n           AND l.created_at < ($2::date::timestamp AT TIME ZONE 'UTC')\n           AND coalesce(l.app, l.quality_signal ->> 'app', 'cis') = $3\n           AND NOT EXISTS (SELECT 1 FROM shared.llm_call_daily d\n                            WHERE d.day = (l.created_at AT TIME ZONE 'UTC')::date)\n         GROUP BY 1\n    )\n    SELECT coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(r.usd, w.usd, 0)), 0)::float AS median\n      FROM days\n      LEFT JOIN rolled r USING (day)\n      LEFT JOIN raw w USING (day)\n"
NEW_BASELINE_SQL = "\n    WITH days AS (\n        SELECT generate_series($1::date, $2::date - 1, interval '1 day')::date AS day\n    ), rolled AS (\n        SELECT d.day, sum(d.cost_usd)::float AS usd\n          FROM shared.llm_call_daily d\n         WHERE d.day >= $1 AND d.day < $2 AND d.app = $3\n         GROUP BY 1\n    ), raw_days AS (\n        SELECT (l.created_at AT TIME ZONE 'UTC')::date AS day, coalesce(sum(l.cost_usd), 0)::float AS usd\n          FROM shared.llm_call_log l\n         WHERE l.created_at >= ($1::date::timestamp AT TIME ZONE 'UTC')\n           AND l.created_at < ($2::date::timestamp AT TIME ZONE 'UTC')\n           AND coalesce(l.app, l.quality_signal ->> 'app', 'cis') = $3\n         GROUP BY 1\n    ), raw AS (\n        SELECT g.day, g.usd\n          FROM raw_days g\n         WHERE NOT EXISTS (SELECT 1 FROM shared.llm_call_daily d WHERE d.day = g.day)\n    )\n    SELECT coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(r.usd, w.usd, 0)), 0)::float AS median\n      FROM days\n      LEFT JOIN rolled r USING (day)\n      LEFT JOIN raw w USING (day)\n"
OLD_TENANT_TOTAL_SQL = '\n    SELECT COALESCE(SUM(cost_usd), 0) FROM shared.llm_call_log WHERE tenant_id = $1 OR ($2 AND tenant_id IS NULL)\n'
NEW_TENANT_TOTAL_SQL = '\n    SELECT COALESCE(SUM(c.usd), 0) FROM (\n        SELECT SUM(cost_usd) AS usd FROM shared.llm_call_log WHERE tenant_id = $1\n        UNION ALL\n        SELECT SUM(cost_usd) FROM shared.llm_call_log WHERE $2 AND tenant_id IS NULL\n    ) c\n'
OLD_TENANT_WINDOW_SQL = '\n    SELECT COALESCE(SUM(cost_usd), 0) FROM shared.llm_call_log\n     WHERE (tenant_id = $1 OR ($2 AND tenant_id IS NULL)) AND created_at >= $3 AND created_at < $4\n'
NEW_TENANT_WINDOW_SQL = '\n    SELECT COALESCE(SUM(c.usd), 0) FROM (\n        SELECT SUM(cost_usd) AS usd FROM shared.llm_call_log\n         WHERE tenant_id = $1 AND created_at >= $3 AND created_at < $4\n        UNION ALL\n        SELECT SUM(cost_usd) FROM shared.llm_call_log\n         WHERE $2 AND tenant_id IS NULL AND created_at >= $3 AND created_at < $4\n    ) c\n'

TOP_TENANT_SQL = """
    SELECT r.tenant_id::text AS tenant_id, count(*) AS n
      FROM acp_shared.angle_gate_request r
     GROUP BY r.tenant_id ORDER BY count(*) DESC, r.tenant_id LIMIT 1
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
INDEX_SQL = "SELECT to_regclass('silver_aa_internal.raw_tours_key_expr_idx') IS NOT NULL AS present"
INTERNAL_SQL = "SELECT tenant_id::text AS tenant_id FROM shared.tenants WHERE plan_tier::text = 'internal' LIMIT 1"
TOP_LEDGER_TENANT_SQL = """
    SELECT l.tenant_id::text AS tenant_id FROM shared.llm_call_log l
      JOIN shared.tenants t ON t.tenant_id = l.tenant_id
     WHERE t.plan_tier::text <> 'internal'
     GROUP BY l.tenant_id ORDER BY count(*) DESC LIMIT 1
"""


class Budget:
    def __init__(self, seconds):
        self.seconds, self.t0 = seconds, time.monotonic()

    def left(self):
        return self.seconds - (time.monotonic() - self.t0)


def _uuid_lit(v):
    return f"'{uuid.UUID(str(v))}'::uuid"


def _uuid_array_lit(ids):
    return "'{" + ",".join(str(uuid.UUID(str(i))) for i in ids) + "}'::uuid[]"


def _ts_lit(ts):
    return f"'{ts.isoformat()}'::timestamptz"


def _date_lit(d):
    return f"'{d.isoformat()}'::date"


def _text_lit(s):
    assert s.replace("_", "").isalnum()
    return f"'{s}'::text"


def _plan_nodes(node, out):
    loops = node.get("Actual Loops", 1) or 1
    total = (node.get("Actual Total Time") or 0.0) * loops
    child_total = sum((c.get("Actual Total Time") or 0.0) * (c.get("Actual Loops", 1) or 1)
                      for c in node.get("Plans", []))
    rel = node.get("Index Name") or node.get("Relation Name") or node.get("CTE Name") or node.get("Alias") or "-"
    out.append((total - child_total, node.get("Node Type"), rel, loops, node.get("Actual Rows")))
    for c in node.get("Plans", []):
        _plan_nodes(c, out)


def _summary(doc):
    top = doc[0]
    plan = top["Plan"]
    nodes = []
    _plan_nodes(plan, nodes)
    names = {n[2] for n in nodes}
    nodes.sort(key=lambda n: -n[0])
    return {"exec_ms": round(top.get("Execution Time", 0.0), 1), "plan_ms": round(top.get("Planning Time", 0.0), 1),
            "hit": plan.get("Shared Hit Blocks"), "read": plan.get("Shared Read Blocks"),
            "temp_w": plan.get("Temp Written Blocks"), "names": names,
            "top": [(round(s, 1), t, r, lo, rw) for s, t, r, lo, rw in nodes[:TOP_NODES]]}


async def _measure(conn, label, variant, sql, types, args, role=None, tenant=None):
    """PREPARE + EXPLAIN ANALYZE once + REPEATS timed EXECUTEs. Returns (sorted result rows, summary) or None."""
    stmt = f"s291_{label}_{variant}"[:63]
    try:
        async with conn.transaction():
            if role:
                await conn.execute(f"SET LOCAL ROLE {role}")
            if tenant:
                await conn.fetchval("SELECT set_config('app.tenant_id', $1, true) AS ok", str(uuid.UUID(tenant)))
            await conn.execute(f"PREPARE {stmt}({', '.join(types)}) AS {sql}")
            try:
                raw = await conn.fetchval(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) EXECUTE {stmt}({args})")
                ex = _summary(json.loads(raw) if isinstance(raw, str) else raw)
                times, rows = [], None
                for _ in range(REPEATS):
                    t0 = time.perf_counter()
                    got = await conn.fetch(f"EXECUTE {stmt}({args})")
                    times.append((time.perf_counter() - t0) * 1000)
                    rows = rows if rows is not None else sorted(tuple(str(v) for v in r.values()) for r in got)
            finally:
                await conn.execute(f"DEALLOCATE {stmt}")
    except Exception as e:  # noqa: BLE001
        print(f"SCRIPT error label={label} variant={variant} role={role or 'master'} error={type(e).__name__}",
              flush=True)
        return None
    print(f"SCRIPT timing label={label} variant={variant} role={role or 'master'} rows={len(rows)} "
          f"median_ms={statistics.median(times):.1f} runs={'/'.join(f'{t:.0f}' for t in times)} "
          f"explain_exec_ms={ex['exec_ms']} plan_ms={ex['plan_ms']} hit={ex['hit']} read={ex['read']} "
          f"temp_w={ex['temp_w']} uses_key_expr_idx={'raw_tours_key_expr_idx' in ex['names']}", flush=True)
    for self_ms, typ, rel, loops, rw in ex["top"]:
        print(f"SCRIPT plan label={label} variant={variant} role={role or 'master'} node={typ}:{rel} "
              f"self_ms={self_ms} loops={loops} rows={rw}", flush=True)
    return rows, ex


async def _pair(conn, label, old_sql, new_sql, types, args, **kw):
    old = await _measure(conn, label, "old", old_sql, types, args, **kw)
    new = await _measure(conn, label, "new", new_sql, types, args, **kw)
    if old and new:
        print(f"SCRIPT parity label={label} role={kw.get('role') or 'master'} equal={old[0] == new[0]} "
              f"old_rows={len(old[0])} new_rows={len(new[0])}", flush=True)


async def main(conn):
    budget = Budget(BUDGET_S)
    print(f"SCRIPT index raw_tours_key_expr_idx present={await conn.fetchval(INDEX_SQL)}", flush=True)

    # 1. REQUEST_TOURS_SQL
    top = await conn.fetchrow(TOP_TENANT_SQL)
    if top:
        tenant = top["tenant_id"]
        sets = {"newest": [r["request_id"] for r in await conn.fetch(NEWEST_SQL, tenant, SAMPLE)],
                "retired": [r["request_id"] for r in await conn.fetch(RETIRED_SQL, tenant, SAMPLE)]}
        print(f"SCRIPT requests tenant_requests={top['n']} " + " ".join(f"{k}={len(v)}" for k, v in sets.items()),
              flush=True)
        for name, ids in sets.items():
            if not ids or budget.left() < 60:
                continue
            args = f"{_uuid_array_lit(ids)}, {_uuid_lit(tenant)}"
            await _pair(conn, f"request_tours_{name}", OLD_REQUEST_TOURS_SQL, NEW_REQUEST_TOURS_SQL,
                        ("uuid[]", "uuid"), args)
            await _pair(conn, f"request_tours_{name}", OLD_REQUEST_TOURS_SQL, NEW_REQUEST_TOURS_SQL,
                        ("uuid[]", "uuid"), args, role="aa_app_user", tenant=tenant)
    else:
        print("SCRIPT requests none", flush=True)

    # 2. anomaly breaker reads
    now = datetime.datetime.now(datetime.timezone.utc)
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    for app in ("cis", "tripplanner", "crm"):
        if budget.left() < 60:
            print(f"SCRIPT truncated section=anomaly app={app}", flush=True)
            break
        await _pair(conn, f"today_{app}", OLD_TODAY_SQL, NEW_TODAY_SQL, ("timestamptz", "text"),
                    f"{_ts_lit(midnight)}, {_text_lit(app)}")
        for days in (14, 28):
            start = (midnight - datetime.timedelta(days=days)).date()
            await _pair(conn, f"baseline_{app}_{days}d", OLD_BASELINE_SQL, NEW_BASELINE_SQL, ("date", "date", "text"),
                        f"{_date_lit(start)}, {_date_lit(midnight.date())}, {_text_lit(app)}")

    # 3. Tenant 360 cost sums
    internal = await conn.fetchval(INTERNAL_SQL) or AA_MASTER
    other = await conn.fetchval(TOP_LEDGER_TENANT_SQL)
    since = now - datetime.timedelta(days=30)
    for name, tid, is_internal in (("internal", internal, True), ("tenant", other, False)):
        if not tid or budget.left() < 60:
            continue
        flag = "true" if is_internal else "false"
        await _pair(conn, f"tenant_total_{name}", OLD_TENANT_TOTAL_SQL, NEW_TENANT_TOTAL_SQL, ("uuid", "boolean"),
                    f"{_uuid_lit(tid)}, {flag}")
        await _pair(conn, f"tenant_window_{name}", OLD_TENANT_WINDOW_SQL, NEW_TENANT_WINDOW_SQL,
                    ("uuid", "boolean", "timestamptz", "timestamptz"),
                    f"{_uuid_lit(tid)}, {flag}, {_ts_lit(since)}, {_ts_lit(now)}")
    print(f"SCRIPT done seconds={time.monotonic() - budget.t0:.0f}", flush=True)
    return 0


if __name__ == "__main__":  # local: python3 aa838_s291_explain.py <DSN> (a superuser on a throwaway database)
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
