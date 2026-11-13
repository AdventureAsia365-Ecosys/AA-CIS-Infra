"""AA-1093 (S279): independent re-read, as the master, of the first real tenant erasure on Dev (synthetic tenant only).

Copy to AA-CIS-Infra db/scripts/aa1093_erasure_reread.py, set TENANT_ID (and AGENCY_NAME) below to the run's synthetic
tenant, review, merge, then run DB Migrate mode=run-script script=aa1093_erasure_reread.py environment=dev, once
before the apply (baseline) and once after it. READ_ONLY: the runner opens the session read-only.

Why the master: TripPlanner's tenant tables are owner-only for the runtime roles (FORCE RLS; cis_app reads only the
report view), the CRM's need an agency context. Counts only: no row value leaves the database (db/scripts/README.md
personal-data guard: count(...), and personal-data columns only in WHERE).

What it prints (lines start with SCRIPT):
  TripPlanner  rows of the tenant in sessions, trip_drafts, trip_events, outbox (must be 0 after the apply; D4 delete),
               its ai_spend_month rows (scope tenant:<id>, must be 0: merged into the app scope), the customers its
               sessions link (0), the tenant_erasure_log rows (kept: the erasure record), and each table's total rows
               as seen by this session (a visibility check: a 0 on a table this session cannot see is not a 0).
  Booking      the free-text census of the agency's rows (D3 anonymise: rows stay, the cleared columns must be empty),
               the partner row's erased name and status, and (with AGENCY_NAME) name hits in audit rows,
               notifications and partner rows (must be 0).
  CRM          rows of the tenant in every crm table with a tenant_id column, read inside the tenant's own context
               (SET LOCAL app.tenant_id). Not erased by this run (the CRM erasure stage is not built): information.
  VERDICT      after-erase PASS / FAIL for TripPlanner and Booking (a baseline run before the apply prints FAIL: expected).
"""
from __future__ import annotations

import re

READ_ONLY = True

# Set to the run's synthetic tenant before the PR (a uuid); AGENCY_NAME = its synthetic name ("" skips the name search).
TENANT_ID = "9310c702-eebd-44bd-9c52-133a7d2a4af9"
AGENCY_NAME = "E2E Erasure Drill 01"

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
R = "[redacted]"
RJ = '\'{"redacted": "tenant_erased"}\'::jsonb'

TP_TABLES = ("tripplanner.sessions", "tripplanner.trip_drafts", "tripplanner.trip_events", "tripplanner.outbox")
CASES = "SELECT id FROM booking.trip_cases WHERE channel = 'b2b' AND party_tenant_id = $1::uuid"
PARTNER = "SELECT id FROM booking.b2b_partners WHERE tenant_id = $1::uuid"
INVOICES = "SELECT id FROM booking.agency_invoice WHERE party_tenant_id = $1::uuid"
SCOPE = "SELECT id FROM booking.tenant_erase_scope($1::uuid) AS s(id)"
BK_CENSUS = {
    "booking.trip_cases": ("channel = 'b2b' AND party_tenant_id = $1::uuid",
                           "notes IS NOT NULL OR inquiry_snapshot IS NOT NULL"),
    "booking.trip_case_status_history": (f"trip_case_id IN ({CASES})", "note IS NOT NULL"),
    "booking.supplier_bookings": (f"trip_case_id IN ({CASES})",
                                  f"notes IS NOT NULL OR voucher_note IS NOT NULL OR cancel_reason <> '{R}'"),
    "booking.trip_case_checks": (f"trip_case_id IN ({CASES})",
                                 "note IS NOT NULL OR emergency_contact_name IS NOT NULL "
                                 f"OR emergency_contact_phone IS NOT NULL OR (code = 'custom' AND title <> '{R}')"),
    "booking.b2b_cancellations": (f"partner_id IN ({PARTNER})", f"waive_reason <> '{R}'"),
    "booking.agency_invoice": ("party_tenant_id = $1::uuid", f"staff_note IS NOT NULL OR void_reason <> '{R}'"),
    "booking.agency_payment": (f"invoice_id IN ({INVOICES})", f"note IS NOT NULL OR reject_reason <> '{R}'"),
    "booking.notifications": (f"entity_id IN ({SCOPE})",
                              f"title <> '{R}' OR message IS NOT NULL OR data - 'reminder_key' <> '{{}}'::jsonb"),
    "booking.audit_logs": (f"entity_id IN ({SCOPE})",
                           f"(before IS NOT NULL AND before <> {RJ}) OR (after IS NOT NULL AND after <> {RJ}) "
                           f"OR entity_label IS NOT NULL OR (summary IS NOT NULL AND summary <> '{R}')"),
}
NAME_HITS = {
    "booking.audit_logs": "SELECT count(*)::int FROM booking.audit_logs WHERE before::text ILIKE $1 "
                          "OR after::text ILIKE $1 OR entity_label ILIKE $1 OR summary ILIKE $1",
    "booking.notifications": "SELECT count(*)::int FROM booking.notifications WHERE title ILIKE $1 "
                             "OR message ILIKE $1 OR data::text ILIKE $1",
    "booking.b2b_partners": "SELECT count(*)::int FROM booking.b2b_partners WHERE agency_name ILIKE $1",
}
CRM_TABLES_SQL = """
SELECT c.table_schema || '.' || c.table_name AS t
  FROM information_schema.columns c
  JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
 WHERE c.table_schema = 'crm' AND c.column_name = 'tenant_id' AND t.table_type = 'BASE TABLE'
 ORDER BY 1
"""


def _say(msg: str) -> None:
    print(f"SCRIPT {msg}", flush=True)


def _ident(t: str) -> str:
    s, n = t.split(".", 1)
    return f'"{s}"."{n}"'


async def _tripplanner(conn, tid: str) -> int:
    bad = 0
    for t in TP_TABLES:
        n = await conn.fetchval(f"SELECT count(*)::int FROM {t} WHERE tenant_id = $1::uuid", tid)
        total = await conn.fetchval(f"SELECT count(*)::int FROM {t}")
        bad += bool(n)
        _say(f"TP {t} tenant_rows={n} visible_total={total}")
    n = await conn.fetchval("SELECT count(*)::int FROM tripplanner.ai_spend_month WHERE scope = 'tenant:' || $1", tid)
    bad += bool(n)
    _say(f"TP tripplanner.ai_spend_month scope_tenant_rows={n}")
    n = await conn.fetchval("SELECT count(DISTINCT customer_id)::int FROM tripplanner.sessions "
                            "WHERE tenant_id = $1::uuid AND customer_id IS NOT NULL", tid)
    bad += bool(n)
    _say(f"TP tripplanner.customers linked_by_tenant_sessions={n}")
    rows = await conn.fetch("SELECT mode, status, count(*)::int AS n FROM tripplanner.tenant_erasure_log "
                            "WHERE tenant_id = $1::uuid GROUP BY mode, status ORDER BY mode, status", tid)
    _say("TP tripplanner.tenant_erasure_log (kept, the record): "
         + (", ".join(f"{r['mode']}/{r['status']}={r['n']}" for r in rows) or "none"))
    return bad


async def _booking(conn, tid: str) -> int:
    bad = 0
    for table, (rows_where, left_cond) in BK_CENSUS.items():
        total = await conn.fetchval(f"SELECT count(*)::int FROM {table} WHERE {rows_where}", tid)
        left = await conn.fetchval(f"SELECT count(*)::int FROM {table} WHERE ({rows_where}) AND ({left_cond})", tid)
        bad += bool(left)
        _say(f"BK {table} agency_rows={total} free_text_left={left}")
    p = await conn.fetchrow("SELECT count(*)::int AS n, count(*) FILTER (WHERE agency_name = 'Erased agency ' || "
                            "left($1::text, 8))::int AS erased, count(*) FILTER (WHERE status = 'suspended')::int AS "
                            "suspended FROM booking.b2b_partners WHERE tenant_id = $1::uuid", tid)
    bad += not (p["n"] >= 1 and p["erased"] == p["n"] and p["suspended"] == p["n"])
    _say(f"BK booking.b2b_partners rows={p['n']} erased_name={p['erased']} suspended={p['suspended']}")
    if AGENCY_NAME.strip():
        like = "%" + AGENCY_NAME.strip().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        for table, sql in NAME_HITS.items():
            hits = await conn.fetchval(sql, like)
            bad += bool(hits)
            _say(f"BK name_hits {table}={hits}")
    return bad


async def _crm(conn, tid: str) -> None:
    tables = [r["t"] for r in await conn.fetch(CRM_TABLES_SQL)]
    found = []
    async with conn.transaction():
        await conn.execute(f"SET LOCAL app.tenant_id = '{tid}'")
        for t in tables:
            n = await conn.fetchval(f"SELECT count(*)::int FROM {_ident(t)} WHERE tenant_id = $1::uuid", tid)
            if n:
                found.append(f"{t}={n}")
    _say(f"CRM tables_checked={len(tables)} with_rows={len(found)} " + (" ".join(found) or "(none)"))


async def main(conn):
    tid = TENANT_ID.strip().lower()
    if not UUID_RE.match(tid):
        _say("FAIL TENANT_ID is not set to the run's tenant uuid")
        return 1
    _say(f"tenant {tid[:8]}")
    tp_bad = await _tripplanner(conn, tid)
    bk_bad = await _booking(conn, tid)
    await _crm(conn, tid)
    _say(f"VERDICT tripplanner after-erase {'PASS' if tp_bad == 0 else 'FAIL'} (non-zero checks: {tp_bad})")
    _say(f"VERDICT booking after-erase {'PASS' if bk_bad == 0 else 'FAIL'} (non-zero checks: {bk_bad})")
    return 0
