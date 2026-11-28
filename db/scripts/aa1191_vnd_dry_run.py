"""AA-1191 DRY RUN (read-only): which rows still hold VND now that the platform shows and accepts USD only.

Skill aa-cis-schema references/destructive-ops.md step 1 (DRY RUN). Nothing is written: one READ ONLY transaction of
SELECT count(*) ... GROUP BY on enum-like codes (status, kind, currency, retired or live). The output is aggregate
counts only: no id, no name, no amount, no personal column. Any conversion of these rows to USD is a later, reviewed
step (AA-1191 "Done when": the counts are posted, then rows are converted after review), never this script.

Sections (each runs in its own savepoint; a section the login cannot read prints `skipped` with the SQLSTATE, so the
same file is run once per app):

  cis      shared.plan (VND list prices), shared.tenants (billing_currency VND, by kind and account status),
           shared.tenant_subscription (agreed_currency VND, by status)        -> role cis_app (CIS api container)
  booking  booking.agency_invoice (currency VND, by kind and status), booking.billing_terms (saas_currency VND,
           default row or agency override)                                     -> role booking (Booking api container)
  crm      crm.proposal (currency VND, by kind and status), crm.tenant_settings (base_currency VND); the crm tables
           are tenant-scoped (FORCE RLS), so the section switches to role crm_owner and counts agency by agency
           (app.tenant_id per CIS tenant id) -> only the master login (AA-CIS-Infra DB Migrate mode=run-script)

How to run it:
  * ecsx (S3-mediated ECS exec) in the aa-cis-dev-api container, then in the aa-booking-dev-api container:
    `python3 aa1191_vnd_dry_run.py` reads the container env DATABASE_URL (DB_SSL=disable only for a local database).
  * AA-CIS-Infra DB Migrate mode=run-script (master login) for the crm section (and all three at once): copy it to
    db/scripts/; the runner calls `main(conn)`.

Output: one `DRYRUN <section> <json>` line per section, then `DRYRUN_JSON {...}` with everything.
"""
# ruff: noqa: S608 — every SQL string is a constant of this file (no input reaches it)

from __future__ import annotations

import asyncio
import json
import os
from datetime import UTC, datetime
from typing import Any

READ_ONLY = True
CURRENCY = "VND"

CIS_QUERIES = {
    "plans_with_vnd_price": """
        SELECT (retired_at IS NULL) AS live, product, count(*) AS n
          FROM shared.plan
         WHERE price_vnd_monthly IS NOT NULL OR price_extra_seat_vnd IS NOT NULL
         GROUP BY 1, 2 ORDER BY 1 DESC, 2""",
    "tenants_billing_currency_vnd": """
        SELECT kind, account_status, count(*) AS n
          FROM shared.tenants
         WHERE billing_currency = $1
         GROUP BY 1, 2 ORDER BY 1, 2""",
    "subscriptions_agreed_currency_vnd": """
        SELECT product, status, count(*) AS n
          FROM shared.tenant_subscription
         WHERE agreed_currency = $1
         GROUP BY 1, 2 ORDER BY 1, 2""",
}
BOOKING_QUERIES = {
    "agency_invoices_vnd": """
        SELECT invoice_kind, status, count(*) AS n
          FROM booking.agency_invoice
         WHERE currency = $1
         GROUP BY 1, 2 ORDER BY 1, 2""",
    "billing_terms_saas_currency_vnd": """
        SELECT (party_tenant_id IS NULL) AS default_row, count(*) AS n
          FROM booking.billing_terms
         WHERE saas_currency = $1
         GROUP BY 1 ORDER BY 1 DESC""",
}
CRM_TENANTS_SQL = "SELECT tenant_id::text AS tenant_id FROM shared.tenants ORDER BY tenant_id"
CRM_QUERIES = {
    "proposals_vnd": """
        SELECT kind, status, count(*) AS n
          FROM crm.proposal
         WHERE currency = $1 AND deleted_at IS NULL
         GROUP BY 1, 2""",
    "tenant_settings_base_currency_vnd": """
        SELECT 'base_currency' AS field, count(*) AS n
          FROM crm.tenant_settings
         WHERE base_currency = $1
         GROUP BY 1""",
}


def _rows(records: list[Any]) -> list[dict[str, Any]]:
    """Plain JSON rows (codes and counts only)."""
    return [{k: (int(v) if k == "n" else v) for k, v in dict(r).items()} for r in records]


async def _section(conn: Any, name: str, queries: dict[str, str]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    try:
        async with conn.transaction():  # a savepoint: a refused read never aborts the other sections
            for key, sql in queries.items():
                out[key] = _rows(await conn.fetch(sql, *((CURRENCY,) if "$1" in sql else ())))
    except Exception as exc:  # noqa: BLE001 — a login without access to this app's schema: report, go on
        return {"skipped": f"{type(exc).__name__} {getattr(exc, 'sqlstate', '')}".strip()}
    return out


def _add(total: dict[tuple, int], rows: list[dict[str, Any]]) -> None:
    for r in rows:
        key = tuple((k, v) for k, v in r.items() if k != "n")
        total[key] = total.get(key, 0) + int(r["n"])


async def _crm(conn: Any) -> dict[str, Any]:
    """Agency by agency as crm_owner (FORCE RLS: a policy shows one app.tenant_id at a time). Master login only."""
    try:
        async with conn.transaction():
            tenants = [r["tenant_id"] for r in await conn.fetch(CRM_TENANTS_SQL)]
            await conn.execute("SET LOCAL ROLE crm_owner")
            totals: dict[str, dict[tuple, int]] = {k: {} for k in CRM_QUERIES}
            agencies_with_vnd = 0
            for tid in tenants:
                await conn.execute("SELECT set_config('app.tenant_id', $1, true)", tid)
                found = False
                for key, sql in CRM_QUERIES.items():
                    rows = _rows(await conn.fetch(sql, CURRENCY))
                    found = found or bool(rows)
                    _add(totals[key], rows)
                agencies_with_vnd += int(found)
            await conn.execute("SELECT set_config('app.tenant_id', '', true)")
    except Exception as exc:  # noqa: BLE001 — not the master login (no crm_owner, no shared): report, go on
        return {"skipped": f"{type(exc).__name__} {getattr(exc, 'sqlstate', '')}".strip()}
    out: dict[str, Any] = {
        k: [{**dict(key), "n": n} for key, n in sorted(v.items(), key=str)] for k, v in totals.items()
    }
    out["agencies_scanned"] = len(tenants)
    out["agencies_with_vnd"] = agencies_with_vnd
    return out


async def main(conn: Any) -> dict[str, Any]:
    """The DB Migrate run-script entry point (and the ecsx one, below): every section, one READ ONLY transaction."""
    report: dict[str, Any] = {"issue": "AA-1191", "currency": CURRENCY,
                              "at": datetime.now(UTC).isoformat(timespec="seconds")}  # fmt: skip
    async with conn.transaction(readonly=True):
        report["cis"] = await _section(conn, "cis", CIS_QUERIES)
        report["booking"] = await _section(conn, "booking", BOOKING_QUERIES)
        report["crm"] = await _crm(conn)
    for name in ("cis", "booking", "crm"):
        print(f"DRYRUN {name} {json.dumps(report[name], sort_keys=True, default=str)}")
    print(f"DRYRUN_JSON {json.dumps(report, sort_keys=True, default=str)}")
    return report


async def _run() -> None:
    import asyncpg  # the app images have it; imported here so the module loads without it (tests, DB Migrate)

    ssl: Any = False if os.environ.get("DB_SSL") == "disable" else "require"
    conn = await asyncpg.connect(os.environ["DATABASE_URL"], ssl=ssl)
    try:
        await main(conn)
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(_run())
