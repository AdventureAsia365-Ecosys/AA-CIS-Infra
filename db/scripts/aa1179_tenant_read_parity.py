"""AA-1179 (S293, C4.3 W48 findings 1 and 3), read-only: old and new statements return the same rows on live Dev.

1. shared/tour_liveness.py REQUEST_TOURS_SQL, the W48 statement vs today's (S291), for EVERY tenant and EVERY one of its
   angle-gate requests (CHUNK ids per call, as the master with app.tenant_id set): rows compared in the script, per
   request (request id -> tour id). Also, when the master may switch to aa_app_user (the tenant pool's role), today's
   statement as that role must return the master's rows (RLS changes nothing for the tenant's own requests).
   Context counts: requests whose representative tour's key is retired, and how many of those the Subject rule moved
   to a served member (the new tour differs from the representative).
2. shared/llm_client/anomaly_breaker.py BASELINE_SQL, W48 vs S291 vs S293, per app with AI, windows of 1, 7, 14, 28 and
   60 days ending today and 7 days ago: the three medians must be equal.

Output lines start with `SCRIPT `: counts only (no row values, no ids, no amounts). The last line is
`SCRIPT verdict ... ok=<bool>`; ok=True needs 0 differing rows and 0 differing medians. Time budget BUDGET_S. Always
returns 0.

Dispatch (after merge): DB Migrate, mode=run-script, script=db/scripts/aa1179_tenant_read_parity.py. Read the output:
`gh api repos/AdventureAsia365-Ecosys/AA-CIS-Infra/actions/jobs/<id>/logs | grep -o 'SCRIPT .*'`.
The SQL below is copied verbatim from AA-CIS-App (tests/integration/test_aa838_request_tours_sql.py,
tests/integration/test_aa1126_gateway_caps_sql.py, shared/tour_liveness.py, shared/llm_client/anomaly_breaker.py).
"""

import datetime
import time
import uuid

READ_ONLY = True

CHUNK = 200
BUDGET_S = 25 * 60
ROLE = "aa_app_user"

# ── statements (verbatim) ──────────────────────────────────────────────────────────────────────────────────────────
W48_REQUEST_TOURS_SQL = "\n    SELECT r.request_id::text AS request_id,\n           (CASE WHEN tl_rq.state = 'retired'\n                 THEN COALESCE((SELECT ta_mt.tour_id FROM acp_shared.subject s_mt\n          JOIN acp_contract.atom_segment_member m_mt\n            ON m_mt.segment_id IN (s_mt.segment_id, (SELECT a_mt.segment_id_canonical\n                 FROM acp_contract.atom_segment_alias a_mt WHERE a_mt.segment_id_old = s_mt.segment_id))\n          JOIN acp_contract.tour_atoms ta_mt ON ta_mt.atom_id = m_mt.atom_id AND NOT ta_mt.deleted\n               AND NOT ta_mt.is_empty_marker\n          JOIN gold_aa_internal.published_tours pt_mt\n      ON pt_mt.tour_id = ta_mt.tour_id AND pt_mt.master_status = 'active' AND pt_mt.deleted_at IS NULL\n    JOIN silver_aa_internal.raw_tours rt_mt\n      ON rt_mt.tour_id = pt_mt.tour_id AND rt_mt.source_status = 'active' AND rt_mt.deleted_at IS NULL\n         WHERE s_mt.subject_id = r.subject_id AND s_mt.tenant_id = r.tenant_id\n           AND s_mt.segment_id IS NOT NULL\n         ORDER BY ta_mt.tour_id LIMIT 1), COALESCE(r.trip_id, ta.tour_id))\n                 ELSE COALESCE(r.trip_id, ta.tour_id) END)::text AS tour_id\n      FROM acp_shared.angle_gate_request r\n      LEFT JOIN acp_contract.tour_atoms ta ON ta.atom_id = r.atom_id\n      LEFT JOIN silver_aa_internal.raw_tours rt_rq ON rt_rq.tour_id = COALESCE(r.trip_id, ta.tour_id)\n      LEFT JOIN gold_aa_internal.v_tour_liveness tl_rq\n        ON tl_rq.source_id = (COALESCE(rt_rq.source_group_id, rt_rq.tour_id))::text\n     WHERE r.request_id = ANY($1::uuid[]) AND r.tenant_id = $2::uuid\n"
S291_REQUEST_TOURS_SQL = "\n    SELECT r.request_id::text AS request_id,\n           (CASE WHEN lv_rq.state = 'retired'\n                 THEN COALESCE((SELECT ta_mt.tour_id FROM acp_shared.subject s_mt\n          JOIN acp_contract.atom_segment_member m_mt\n            ON m_mt.segment_id IN (s_mt.segment_id, (SELECT a_mt.segment_id_canonical\n                 FROM acp_contract.atom_segment_alias a_mt WHERE a_mt.segment_id_old = s_mt.segment_id))\n          JOIN acp_contract.tour_atoms ta_mt ON ta_mt.atom_id = m_mt.atom_id AND NOT ta_mt.deleted\n               AND NOT ta_mt.is_empty_marker\n          JOIN gold_aa_internal.published_tours pt_mt\n      ON pt_mt.tour_id = ta_mt.tour_id AND pt_mt.master_status = 'active' AND pt_mt.deleted_at IS NULL\n    JOIN silver_aa_internal.raw_tours rt_mt\n      ON rt_mt.tour_id = pt_mt.tour_id AND rt_mt.source_status = 'active' AND rt_mt.deleted_at IS NULL\n         WHERE s_mt.subject_id = r.subject_id AND s_mt.tenant_id = r.tenant_id\n           AND s_mt.segment_id IS NOT NULL\n         ORDER BY ta_mt.tour_id LIMIT 1), rep.tour_id)\n                 ELSE rep.tour_id END)::text AS tour_id\n      FROM acp_shared.angle_gate_request r\n      LEFT JOIN acp_contract.tour_atoms ta ON ta.atom_id = r.atom_id\n     CROSS JOIN LATERAL (SELECT COALESCE(r.trip_id, ta.tour_id) AS tour_id) rep\n      LEFT JOIN silver_aa_internal.raw_tours rt_rq ON rt_rq.tour_id = rep.tour_id\n      LEFT JOIN LATERAL (\n            SELECT tl_rq.state\n              FROM gold_aa_internal.v_tour_liveness tl_rq\n             WHERE tl_rq.source_id = (COALESCE(rt_rq.source_group_id, rt_rq.tour_id))::text\n            OFFSET 0\n           ) lv_rq ON true\n     WHERE r.request_id = ANY($1::uuid[]) AND r.tenant_id = $2::uuid\n"
W48_BASELINE_SQL = "\n    WITH days AS (\n        SELECT generate_series($1::date, $2::date - 1, interval '1 day')::date AS day\n    ), rolled AS (\n        SELECT d.day, sum(d.cost_usd)::float AS usd\n          FROM shared.llm_call_daily d\n         WHERE d.day >= $1 AND d.day < $2 AND d.app = $3\n         GROUP BY 1\n    ), raw AS (\n        SELECT (l.created_at AT TIME ZONE 'UTC')::date AS day, coalesce(sum(l.cost_usd), 0)::float AS usd\n          FROM shared.llm_call_log l\n         WHERE l.created_at >= ($1::date::timestamp AT TIME ZONE 'UTC')\n           AND l.created_at < ($2::date::timestamp AT TIME ZONE 'UTC')\n           AND coalesce(l.app, l.quality_signal ->> 'app', 'cis') = $3\n           AND NOT EXISTS (SELECT 1 FROM shared.llm_call_daily d\n                            WHERE d.day = (l.created_at AT TIME ZONE 'UTC')::date)\n         GROUP BY 1\n    )\n    SELECT coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(r.usd, w.usd, 0)), 0)::float AS median\n      FROM days\n      LEFT JOIN rolled r USING (day)\n      LEFT JOIN raw w USING (day)\n"
S291_BASELINE_SQL = "\n    WITH days AS (\n        SELECT generate_series($1::date, $2::date - 1, interval '1 day')::date AS day\n    ), rolled AS (\n        SELECT d.day, sum(d.cost_usd)::float AS usd\n          FROM shared.llm_call_daily d\n         WHERE d.day >= $1 AND d.day < $2 AND d.app = $3\n         GROUP BY 1\n    ), raw_days AS (\n        SELECT (l.created_at AT TIME ZONE 'UTC')::date AS day, coalesce(sum(l.cost_usd), 0)::float AS usd\n          FROM shared.llm_call_log l\n         WHERE l.created_at >= ($1::date::timestamp AT TIME ZONE 'UTC')\n           AND l.created_at < ($2::date::timestamp AT TIME ZONE 'UTC')\n           AND coalesce(l.app, l.quality_signal ->> 'app', 'cis') = $3\n         GROUP BY 1\n    ), raw AS (\n        SELECT g.day, g.usd\n          FROM raw_days g\n         WHERE NOT EXISTS (SELECT 1 FROM shared.llm_call_daily d WHERE d.day = g.day)\n    )\n    SELECT coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(r.usd, w.usd, 0)), 0)::float AS median\n      FROM days\n      LEFT JOIN rolled r USING (day)\n      LEFT JOIN raw w USING (day)\n"
S293_BASELINE_SQL = "\n    WITH days AS (\n        SELECT generate_series($1::date, $2::date - 1, interval '1 day')::date AS day\n    ), rolled AS (\n        SELECT d.day, sum(d.cost_usd)::float AS usd\n          FROM shared.llm_call_daily d\n         WHERE d.day >= $1 AND d.day < $2 AND d.app = $3\n         GROUP BY 1\n    )\n    SELECT coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(r.usd, w.usd, 0)), 0)::float AS median\n      FROM days\n      LEFT JOIN rolled r USING (day)\n      LEFT JOIN LATERAL (\n            SELECT sum(l.cost_usd)::float AS usd\n              FROM shared.llm_call_log l\n             WHERE l.created_at >= (days.day::timestamp AT TIME ZONE 'UTC')\n               AND l.created_at < ((days.day + 1)::timestamp AT TIME ZONE 'UTC')\n               AND coalesce(l.app, l.quality_signal ->> 'app', 'cis') = $3\n               AND NOT EXISTS (SELECT 1 FROM shared.llm_call_daily d WHERE d.day = days.day)\n           ) w ON true\n"

APPS = ("cis", "tripplanner", "crm")
WINDOW_DAYS = (1, 7, 14, 28, 60)
END_OFFSETS = (0, 7)

TENANTS_SQL = """
    SELECT r.tenant_id::text AS tenant_id, count(*) AS n
      FROM acp_shared.angle_gate_request r
     GROUP BY r.tenant_id ORDER BY r.tenant_id
"""
REQUESTS_SQL = """
    SELECT r.request_id::text AS request_id FROM acp_shared.angle_gate_request r
     WHERE r.tenant_id = $1::uuid ORDER BY r.request_id
"""
# The representative tour of each request and whether its key is retired (context counts only).
REP_SQL = """
    SELECT r.request_id::text AS request_id, COALESCE(r.trip_id, ta.tour_id)::text AS rep,
           (tl.state = 'retired') AS retired
      FROM acp_shared.angle_gate_request r
      LEFT JOIN acp_contract.tour_atoms ta ON ta.atom_id = r.atom_id
      LEFT JOIN silver_aa_internal.raw_tours rt ON rt.tour_id = COALESCE(r.trip_id, ta.tour_id)
      LEFT JOIN gold_aa_internal.v_tour_liveness tl ON tl.source_id = (COALESCE(rt.source_group_id, rt.tour_id))::text
     WHERE r.tenant_id = $1::uuid
"""
MEMBER_SQL = "SELECT pg_has_role(current_user, $1, 'MEMBER') AS ok"
TENANT_SQL = "SELECT set_config('app.tenant_id', $1, true) AS ok"


def chunks(ids, n):
    """Consecutive slices of at most n. Pure."""
    return [ids[i:i + n] for i in range(0, len(ids), n)]


def compare(old: dict, new: dict) -> int:
    """Requests whose row differs: in one result only, or another tour. Pure."""
    return sum(1 for k in set(old) | set(new) if k not in old or k not in new or old[k] != new[k])


class Budget:
    def __init__(self, seconds):
        self.seconds, self.t0 = seconds, time.monotonic()

    def left(self):
        return self.seconds - (time.monotonic() - self.t0)


async def _rows(conn, sql, ids, tenant, role=None) -> dict:
    async with conn.transaction():
        if role:
            await conn.execute(f"SET LOCAL ROLE {role}")
        await conn.fetchval(TENANT_SQL, str(uuid.UUID(tenant)))
        rows = await conn.fetch(sql, ids, tenant)
        if role:
            await conn.execute("RESET ROLE")
    return {r["request_id"]: r["tour_id"] for r in rows}


async def request_tours(conn, budget, can_role) -> tuple:
    """(requests, differing, role_differing, errors) over every tenant; prints the counts."""
    tenants = await conn.fetch(TENANTS_SQL)
    n_req = n_old = n_new = diff = role_diff = role_checked = retired = moved = no_tour = errors = done = 0
    for t in tenants:
        if budget.left() < 120:
            print(f"SCRIPT truncated section=request_tours tenants_done={done} tenants={len(tenants)}", flush=True)
            break
        tenant = t["tenant_id"]
        ids = [r["request_id"] for r in await conn.fetch(REQUESTS_SQL, tenant)]
        reps = {r["request_id"]: (r["rep"], r["retired"]) for r in await conn.fetch(REP_SQL, tenant)}
        for part in chunks(ids, CHUNK):
            try:
                old = await _rows(conn, W48_REQUEST_TOURS_SQL, part, tenant)
                new = await _rows(conn, S291_REQUEST_TOURS_SQL, part, tenant)
                if can_role:
                    as_role = await _rows(conn, S291_REQUEST_TOURS_SQL, part, tenant, role=ROLE)
                    role_diff += compare(new, as_role)
                    role_checked += len(part)
            except Exception as e:  # noqa: BLE001 — the class only, never the message
                errors += 1
                print(f"SCRIPT error section=request_tours error={type(e).__name__}", flush=True)
                continue
            n_req += len(part)
            n_old += len(old)
            n_new += len(new)
            diff += compare(old, new)
            for rid, tour in new.items():
                rep, is_retired = reps.get(rid, (None, None))
                retired += 1 if is_retired else 0
                moved += 1 if (is_retired and tour != rep) else 0
                no_tour += 1 if tour is None else 0
        done += 1
    print(f"SCRIPT parity check=request_tours tenants={done} requests={n_req} rows_old={n_old} rows_new={n_new} "
          f"differing={diff} retired_rep={retired} moved_by_subject_rule={moved} no_tour={no_tour} errors={errors}",
          flush=True)
    if can_role:
        print(f"SCRIPT parity check=request_tours_role role={ROLE} requests={role_checked} differing={role_diff}",
              flush=True)
    else:
        print(f"SCRIPT parity check=request_tours_role role={ROLE} skipped=master_not_member", flush=True)
    return n_req, diff, role_diff, errors


async def baselines(conn, budget) -> tuple:
    """(cases, differing, errors) over every app and window; prints the counts."""
    today = datetime.datetime.now(datetime.timezone.utc).date()
    cases = diff = errors = nonzero = 0
    for app in APPS:
        for off in END_OFFSETS:
            for days in WINDOW_DAYS:
                if budget.left() < 30:
                    print(f"SCRIPT truncated section=baseline app={app}", flush=True)
                    break
                end = today - datetime.timedelta(days=off)
                start = end - datetime.timedelta(days=days)
                try:
                    vals = [await conn.fetchval(sql, start, end, app)
                            for sql in (W48_BASELINE_SQL, S291_BASELINE_SQL, S293_BASELINE_SQL)]
                except Exception as e:  # noqa: BLE001
                    errors += 1
                    print(f"SCRIPT error section=baseline app={app} error={type(e).__name__}", flush=True)
                    continue
                cases += 1
                diff += 0 if vals[0] == vals[1] == vals[2] else 1
                nonzero += 1 if vals[2] else 0
    print(f"SCRIPT parity check=baseline cases={cases} differing={diff} nonzero_medians={nonzero} errors={errors}",
          flush=True)
    return cases, diff, errors


async def main(conn):
    budget = Budget(BUDGET_S)
    can_role = bool(await conn.fetchval(MEMBER_SQL, ROLE))
    n_req, rt_diff, role_diff, rt_err = await request_tours(conn, budget, can_role)
    cases, bl_diff, bl_err = await baselines(conn, budget)
    ok = n_req > 0 and cases > 0 and rt_diff == 0 and role_diff == 0 and bl_diff == 0 and rt_err == 0 and bl_err == 0
    print(f"SCRIPT verdict request_differing={rt_diff} role_differing={role_diff} baseline_differing={bl_diff} "
          f"errors={rt_err + bl_err} ok={ok} seconds={time.monotonic() - budget.t0:.0f}", flush=True)
    return 0


if __name__ == "__main__":  # local: python3 aa1179_tenant_read_parity.py <DSN> (a throwaway database)
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
