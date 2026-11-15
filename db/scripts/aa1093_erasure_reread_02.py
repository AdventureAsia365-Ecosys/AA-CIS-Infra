"""AA-1093 (S281): independent re-read, as the master, of the SECOND real tenant erasure on Dev (synthetic tenant
aa1093-erase-02), this time with the CRM stage. The first run's script (aa1093_erasure_reread.py, aa1093-erase-01) stays
as the S280 record.

Pinned to the run's tenant below (set TENANT_ID after step A2 of the S281 runbook, before the PR). Run with DB Migrate
mode=run-script script=db/scripts/aa1093_erasure_reread_02.py environment=dev: once before anything is erased
(baseline A6), once after stage 1 (E3a, optional), once after the CRM round (E3). READ_ONLY: the runner opens the
session read-only.

Why the master: TripPlanner's tenant tables are owner-only for the runtime roles (FORCE RLS; cis_app reads only the
report view); the CRM's are FORCE RLS on app.tenant_id (the master is a member of crm_owner, so SET LOCAL app.tenant_id
shows exactly that agency's rows). Counts only: no row value leaves the database (db/scripts/README.md personal-data
guard: count(...), and personal-data columns only in WHERE / IS NOT NULL).

What it prints (lines start with SCRIPT):
  TripPlanner  rows of the tenant in sessions, trip_drafts, trip_events, outbox (0 after the apply; D4 delete), its
               ai_spend_month rows (scope tenant:<id>, 0: merged into the app scope), the customers its sessions link (0),
               the customers no session links any more (after: not higher than the baseline), the tenant_erasure_log
               rows (kept), and each table's visible total (sessions with 0 visible rows = INCONCLUSIVE).
  Booking      the free-text census of the agency's rows (D3 anonymise: rows stay, the cleared columns must be empty),
               the partner row's erased name and status, name hits of AGENCY_NAME (0), the tenant_erasure_log rows.
  CRM          inside the tenant's own context (SET LOCAL app.tenant_id; app.actor platform:aa1093-reread for the studio
               invitations' platform policy):
                 - visibility: the agency row of the tenant must be visible (the erase keeps it, status offboarded);
                   not visible = INCONCLUSIVE (a 0 elsewhere would prove nothing);
                 - rows per crm table with a tenant_id column; after the erase only the crm.erase_subject keep list may
                   hold rows (tenant, tenant_key, audit_event*, audit_export_tenant, audit_export_manifest,
                   erasure_request, lifecycle_run, legal_hold, export_job, data_request): any other table with rows
                   is LEFT (FAIL);
                 - the pii census, independent of the CRM code: for every crm table with a tenant_id column and pii:
                   tagged columns (DM-6.1 comments, read live), the tenant's rows holding a value in any of them (0);
                 - the agency row: status offboarded and name = 'Erased agency <first 8 of the id>', AGENCY_NAME hits 0;
                 - crm.tenant_key rows not destroyed (0: crypto-shred);
                 - crm.studio_invitation rows of the CIS tenant (cis_tenant_id; 0);
                 - the CRM's erasure record (crm.tenant_erasure_report per round / mode / outcome, kept).
  VERDICT      after-erase PASS / FAIL / INCONCLUSIVE for TripPlanner, Booking and CRM (a baseline run before the apply
               prints FAIL: expected).
"""
from __future__ import annotations

import re

READ_ONLY = True

# The synthetic tenant of the S281 run (set after step A2: the tenant_id cisapi.py provision-status printed) and its
# synthetic agency name ("" would skip the name search).
TENANT_ID = "ce1fb25b-8625-43c0-a4a6-404e6b576288"
AGENCY_NAME = "E2E Erasure Drill 02"

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


def _say(msg: str) -> None:
    print(f"SCRIPT {msg}", flush=True)


async def _tripplanner(conn, tid: str) -> tuple[int, bool]:
    bad, blind = 0, False
    for t in TP_TABLES:
        n = await conn.fetchval(f"SELECT count(*)::int FROM {t} WHERE tenant_id = $1::uuid", tid)
        total = await conn.fetchval(f"SELECT count(*)::int FROM {t}")
        bad += bool(n)
        if t == "tripplanner.sessions" and total == 0:
            blind = True  # this session sees no session row at all: a 0 here proves nothing
        _say(f"TP {t} tenant_rows={n} visible_total={total}")
    n = await conn.fetchval("SELECT count(*)::int FROM tripplanner.ai_spend_month WHERE scope = 'tenant:' || $1", tid)
    bad += bool(n)
    _say(f"TP tripplanner.ai_spend_month scope_tenant_rows={n}")
    n = await conn.fetchval("SELECT count(DISTINCT customer_id)::int FROM tripplanner.sessions "
                            "WHERE tenant_id = $1::uuid AND customer_id IS NOT NULL", tid)
    bad += bool(n)
    _say(f"TP tripplanner.customers linked_by_tenant_sessions={n}")
    orphans = await conn.fetchval("SELECT count(*)::int FROM tripplanner.customers c WHERE NOT EXISTS "
                                  "(SELECT 1 FROM tripplanner.sessions s WHERE s.customer_id = c.id)")
    _say(f"TP tripplanner.customers unlinked_total={orphans} (after the apply: not higher than the baseline)")
    rows = await conn.fetch("SELECT mode, status, count(*)::int AS n FROM tripplanner.tenant_erasure_log "
                            "WHERE tenant_id = $1::uuid GROUP BY mode, status ORDER BY mode, status", tid)
    _say("TP tripplanner.tenant_erasure_log (kept, the record): "
         + (", ".join(f"{r['mode']}/{r['status']}={r['n']}" for r in rows) or "none"))
    return bad, blind


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
    rows = await conn.fetch("SELECT mode, status, count(*)::int AS n FROM booking.tenant_erasure_log "
                            "WHERE tenant_id = $1::uuid GROUP BY mode, status ORDER BY mode, status", tid)
    _say("BK booking.tenant_erasure_log (kept, the record): "
         + (", ".join(f"{r['mode']}/{r['status']}={r['n']}" for r in rows) or "none"))
    return bad


# crm.erase_subject keep list (AA-Partner crm-038, the function's last definition; audit_event partitions by prefix)
CRM_KEEP = {"tenant", "tenant_key", "audit_event", "audit_export_tenant", "audit_export_manifest", "erasure_request",
            "lifecycle_run", "legal_hold", "export_job", "data_request"}
CRM_TABLES_PG_SQL = """
SELECT c.relname::text AS name
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
 WHERE c.relnamespace = 'crm'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
 ORDER BY 1
"""
CRM_PII_SQL = """
SELECT c.relname::text AS name, array_agg(a.attname::text ORDER BY a.attname) AS cols
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
  JOIN pg_catalog.pg_description d ON d.objoid = c.oid AND d.classoid = 'pg_catalog.pg_class'::regclass
                                  AND d.objsubid = a.attnum
 WHERE c.relnamespace = 'crm'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
   AND d.description LIKE 'pii:%'
 GROUP BY c.relname
 ORDER BY 1
"""


def _q(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


async def _crm(conn, tid: str) -> tuple[int, bool]:
    """(non-zero checks, blind). Counts only, inside the tenant's own RLS context, all in one read-only transaction."""
    bad, blind = 0, False
    tables = [r["name"] for r in await conn.fetch(CRM_TABLES_PG_SQL)]
    pii = {r["name"]: list(r["cols"]) for r in await conn.fetch(CRM_PII_SQL)}
    async with conn.transaction():
        await conn.execute(f"SET LOCAL app.tenant_id = '{tid}'")
        await conn.execute("SET LOCAL app.actor = 'platform:aa1093-reread'")
        agency = await conn.fetchrow(
            "SELECT count(*)::int AS n, count(*) FILTER (WHERE status = 'offboarded')::int AS offboarded, "
            "count(*) FILTER (WHERE display_name = 'Erased agency ' || left($1::text, 8))::int AS erased "
            "FROM crm.tenant WHERE tenant_id = $1::uuid", tid)
        blind = agency["n"] == 0
        _say(f"CRM crm.tenant visible={agency['n']} offboarded={agency['offboarded']} erased_name={agency['erased']}")
        bad += not (agency["n"] == 1 and agency["offboarded"] == 1 and agency["erased"] == 1)
        left, keep, unreadable = [], [], []
        for t in tables:
            try:
                async with conn.transaction():
                    n = await conn.fetchval(f"SELECT count(*)::int FROM crm.{_q(t)} WHERE tenant_id = $1::uuid", tid)
            except Exception as exc:  # noqa: BLE001 — never counted as 0
                unreadable.append(f"{t}({type(exc).__name__})")
                continue
            if n:
                (keep if (t in CRM_KEEP or t.startswith("audit_event")) else left).append(f"{t}={n}")
        bad += len(left) + len(unreadable) + (len(tables) == 0)  # no table read is never a pass
        _say(f"CRM tables_checked={len(tables)} left={len(left)} " + (" ".join(left) or "(none)"))
        _say("CRM kept (erase_subject keep list): " + (" ".join(keep) or "(none)"))
        if unreadable:
            _say("CRM UNREADABLE " + " ".join(unreadable))
        checked = found = 0
        hits = []
        for t, cols in sorted(pii.items()):
            if t not in tables:
                continue  # no tenant_id column (e.g. crm.studio_invitation: counted below by cis_tenant_id)
            where = " OR ".join(f"{_q(c)} IS NOT NULL" for c in cols)
            try:
                async with conn.transaction():
                    n = await conn.fetchval(
                        f"SELECT count(*)::int FROM crm.{_q(t)} WHERE tenant_id = $1::uuid AND ({where})", tid)
            except Exception as exc:  # noqa: BLE001
                hits.append(f"{t}=UNREADABLE({type(exc).__name__})")
                bad += 1
                continue
            checked += len(cols)
            found += n
            if n:
                hits.append(f"{t}={n}")
        bad += bool(found) + (checked == 0)  # no pii column read is never a pass
        _say(f"CRM pii_columns_checked={checked} pii_rows_found={found} " + (" ".join(hits) or "(none)"))
        keys = await conn.fetchval("SELECT count(*)::int FROM crm.tenant_key WHERE tenant_id = $1::uuid "
                                   "AND destroyed_at IS NULL", tid)
        bad += bool(keys)
        _say(f"CRM crm.tenant_key live={keys}")
        inv = await conn.fetchval("SELECT count(*)::int FROM crm.studio_invitation WHERE cis_tenant_id = $1::uuid", tid)
        bad += bool(inv)
        _say(f"CRM crm.studio_invitation rows={inv}")
        if AGENCY_NAME.strip():
            n = await conn.fetchval("SELECT count(*)::int FROM crm.tenant WHERE display_name = $1", AGENCY_NAME.strip())
            bad += bool(n)
            _say(f"CRM name_hits crm.tenant={n}")
    try:  # the record only (crm-066): never turns the verdict above inconclusive
        rows = await conn.fetch(
            "SELECT r.round, r.mode, r.outcome, count(*)::int AS n FROM crm.tenant_erasure_report r "
            "JOIN crm.tenant_erasure_saga s ON s.request_id = r.request_id WHERE s.subject_tenant_id = $1::uuid "
            "GROUP BY r.round, r.mode, r.outcome ORDER BY r.round, r.mode", tid)
        _say("CRM crm.tenant_erasure_report (kept, the record): "
             + (", ".join(f"r{r['round']} {r['mode']}/{r['outcome']}={r['n']}" for r in rows) or "none"))
    except Exception as exc:  # noqa: BLE001
        _say(f"CRM crm.tenant_erasure_report unreadable ({type(exc).__name__})")
    return bad, blind


async def _synthetic(conn, tid: str) -> bool:
    """The run tenant is a synthetic CRM agency (crm.tenant.is_synthetic, kept by the erase)."""
    async with conn.transaction():
        await conn.execute(f"SET LOCAL app.tenant_id = '{tid}'")
        await conn.execute("SET LOCAL app.actor = 'platform:aa1093-reread'")
        n = await conn.fetchval("SELECT count(*) FILTER (WHERE is_synthetic)::int FROM crm.tenant "
                                "WHERE tenant_id = $1::uuid", tid)
    return n == 1


async def main(conn):
    tid = TENANT_ID.strip().lower()
    if not UUID_RE.match(tid):
        _say("FAIL TENANT_ID is not set to the run's tenant uuid")
        return 1
    _say(f"tenant {tid[:8]}")
    try:
        synthetic = await _synthetic(conn, tid)
    except Exception as exc:  # noqa: BLE001
        _say(f"FAIL the synthetic check could not run ({type(exc).__name__})")
        return 1
    if not synthetic:
        _say("FAIL tenant not synthetic (no crm.tenant row with is_synthetic for this id): refusing to report")
        return 1
    tp_bad, tp_blind = await _tripplanner(conn, tid)
    bk_bad = await _booking(conn, tid)
    tp_v = ("INCONCLUSIVE (no visible session row)" if tp_blind
            else ("PASS (no tenant rows at baseline: not evidence)" if tp_bad == 0 else "FAIL"))
    _say(f"VERDICT tripplanner after-erase {tp_v} (non-zero checks: {tp_bad})")
    _say(f"VERDICT booking after-erase {'PASS' if bk_bad == 0 else 'FAIL'} (non-zero checks: {bk_bad})")
    try:
        crm_bad, crm_blind = await _crm(conn, tid)
        crm_v = "INCONCLUSIVE (the agency row is not visible)" if crm_blind else ("PASS" if crm_bad == 0 else "FAIL")
        _say(f"VERDICT crm after-erase {crm_v} (non-zero checks: {crm_bad})")
    except Exception as exc:  # never hide the verdicts above
        _say(f"VERDICT crm after-erase INCONCLUSIVE (the CRM read failed: {type(exc).__name__})")
    return 0
