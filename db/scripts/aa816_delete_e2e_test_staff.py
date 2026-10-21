"""AA-816 (root ADR 0006a A10, removal step 4), one-time: delete the old E2E test staff row from shared.admin_users.

The temporary exception of CIS migration 250 let the SES test mailbox address be a staff address. The E2E user is now
the ordinary reviewer e2e-cognito@adventure.asia (forwarded to the mailbox), and the old row has been disabled on the
Staff page (H3) and its Cognito user deleted (H4). CIS migration 252 puts admin_users_email_chk back to the 247 rule
and RAISEs while that row exists, so this script runs first. Plan: AA-CIS-App
docs/implementation-notes/AA-816-a10-removal.md; Infra notes docs/implementation-notes/AA-816-a10-removal.md.

Rules (any failure: exit 13, nothing written):
- Exactly one row has lower(btrim(email)) = the old address, and it is inactive, CIS role reviewer, not an owner,
  has no password hash and no shared.staff_app_grant row.
- Every foreign key that references shared.admin_users (found in pg_constraint at run time, not a fixed list;
  21/10/2026: staff_app_grant, tenant_api_usage.admin_user_id, generated_content.reviewed_by,
  raw_tours.reviewed_by) has 0 rows for it. A key with ON DELETE CASCADE / SET NULL / SET DEFAULT on a table whose
  row security could hide rows from this session is refused too (the count could be wrong and the delete would then
  change rows nobody counted). A NO ACTION key on such a table is safe: the delete itself fails if a hidden row exists.
- acp_shared.audit_log rows about the row are counted and KEPT (no foreign key; the log is append-only).
- Apply is one transaction: lock the row (FOR UPDATE), re-check every guard, DELETE and require exactly one deleted
  row (otherwise roll back), re-count the address (0), then the `staff.deleted` audit row LAST (the audit chain
  trigger takes a lock), actor `script:<name>`, details = the restore record (username, role, created_at).
- No RDS snapshot (written decision, destructive-ops step 2): it is one test row, and the audit details are the
  restore record. Restore = re-insert from those details (only together with migration 250 and the old code).

Modes (DB Migrate mode=run-script, runs as the RDS master; db/scripts/README.md):
- READ_ONLY = True (this file as merged): DRY RUN, the same checks and report (`would_delete`), no lock, no write.
- READ_ONLY = False (a one-line follow-up PR): apply.
- Local test: `python3 db/scripts/aa816_delete_e2e_test_staff.py <DSN> [--apply]` (DRY RUN without --apply).

Prints counts, booleans and ids only: never an e-mail, a username, a hash or the DSN.
"""

import json

READ_ONLY = True

SCRIPT_NAME = "aa816_delete_e2e_test_staff"
ACTOR = f"script:{SCRIPT_NAME}"
AUDIT_ACTION = "staff.deleted"
RESOURCE_TYPE = "admin_user"
# The temporary E2E address of CIS migration 250 (AA-CIS-App api/migrations/250_admin_users_e2e_test_email.sql).
OLD_E2E_EMAIL = "e2e@e2e-mail.lumiguides.it.com"
EXPECTED_ROLE = "reviewer"
SAFE_ON_DELETE = ("a", "r")   # pg_constraint.confdeltype: NO ACTION, RESTRICT

CANDIDATES_SQL = """
SELECT a.id, a.is_active, a.role::text AS role, a.is_owner, a.password_hash IS NULL AS no_password,
       a.cognito_sub IS NOT NULL AS linked, a.username, a.created_at::text AS created_at,
       (SELECT count(*) FROM shared.staff_app_grant g WHERE g.admin_user_id = a.id) AS grants
  FROM shared.admin_users a
 WHERE lower(btrim(a.email)) = $1
 ORDER BY a.id
"""

# Every FK onto shared.admin_users, with a ready count query (identifiers quoted by Postgres) and whether row
# security could hide rows of the referencing table from this session.
FKS_SQL = """
SELECT con.conname::text AS name, con.conrelid::regclass::text AS tbl, con.confdeltype::text AS on_delete,
       cardinality(con.conkey) AS ncols, ra.attname::text AS ref_col,
       format('SELECT count(*) FROM %s WHERE %I = $1', con.conrelid::regclass, a.attname) AS count_sql,
       (c.relrowsecurity
        AND NOT (SELECT r.rolsuper OR r.rolbypassrls FROM pg_catalog.pg_roles r WHERE r.rolname = current_user)
        AND (c.relforcerowsecurity OR NOT pg_catalog.pg_has_role(current_user, c.relowner, 'MEMBER')))
         AS rls_may_hide
  FROM pg_catalog.pg_constraint con
  JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
  JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
  JOIN pg_catalog.pg_attribute ra ON ra.attrelid = con.confrelid AND ra.attnum = con.confkey[1]
 WHERE con.contype = 'f' AND con.confrelid = 'shared.admin_users'::regclass
 ORDER BY 2, 1
"""

AUDIT_COUNT_SQL = """
SELECT count(*) FROM acp_shared.audit_log WHERE resource_type = 'admin_user' AND resource_id = $1
"""

DELETE_SQL = """
DELETE FROM shared.admin_users
 WHERE id = $1 AND lower(btrim(email)) = $2 AND NOT is_active AND NOT is_owner AND password_hash IS NULL
"""

REMAINING_SQL = "SELECT count(*) FROM shared.admin_users WHERE lower(btrim(email)) = $1"

AUDIT_SQL = """
INSERT INTO acp_shared.audit_log (tenant_id, actor, action, resource_type, resource_id, details)
VALUES (NULL, $1, $2, $3, $4, $5::jsonb)
RETURNING id
"""


class Refused(Exception):
    """The row or its references are not what this script may delete: nothing is written."""


def check_row(rows) -> None:
    """Raise Refused unless `rows` is exactly one inactive, password-less, grant-less, non-owner reviewer row."""
    if len(rows) != 1:
        raise Refused(f"expected exactly 1 row with the old E2E address, found {len(rows)}")
    row = rows[0]
    if row["is_active"]:
        raise Refused("the row is still active (disable it on the Staff page first)")
    if row["role"] != EXPECTED_ROLE:
        raise Refused("the row is not a reviewer")
    if row["is_owner"]:
        raise Refused("the row is an owner")
    if not row["no_password"]:
        raise Refused("the row has a password hash")
    if row["grants"]:
        raise Refused(f"the row has {row['grants']} app grant row(s)")


async def scan_references(conn, row_id) -> list:
    """Every FK onto shared.admin_users with its row count for `row_id`. Raises Refused on any reference, on a
    key this script cannot count reliably, or on an unexpected key shape."""
    found = []
    for fk in await conn.fetch(FKS_SQL):
        if fk["ncols"] != 1 or fk["ref_col"] != "id":
            raise Refused(f"foreign key {fk['name']} on {fk['tbl']} is not a single-column key onto id")
        if fk["rls_may_hide"] and fk["on_delete"] not in SAFE_ON_DELETE:
            raise Refused(f"foreign key {fk['name']} on {fk['tbl']} acts on delete and row security may hide "
                          "rows from this session")
        count = await conn.fetchval(fk["count_sql"], row_id)
        found.append({"fk": fk["name"], "table": fk["tbl"], "on_delete": fk["on_delete"], "rows": count,
                      "rls_may_hide": bool(fk["rls_may_hide"])})
    busy = [f for f in found if f["rows"]]
    if busy:
        raise Refused("rows still reference the old E2E row: "
                      + ", ".join(f"{f['table']}={f['rows']}" for f in busy))
    return found


def report(rows, outcome: str, refs, audit_rows, deleted, remaining, audit_row_id) -> dict:
    row = rows[0] if len(rows) == 1 else None
    return {
        "candidates": len(rows),
        "row_id": str(row["id"]) if row else None,
        "outcome": outcome,
        "is_active": row["is_active"] if row else None,
        "role_is_reviewer": (row["role"] == EXPECTED_ROLE) if row else None,
        "is_owner": row["is_owner"] if row else None,
        "no_password": row["no_password"] if row else None,
        "linked": row["linked"] if row else None,
        "grants": row["grants"] if row else None,
        "references": refs,
        "audit_rows_kept": audit_rows,
        "deleted": deleted,
        "remaining_rows": remaining,
        "audit_row_id": str(audit_row_id) if audit_row_id is not None else None,
    }


def _print_report(data: dict) -> None:
    print("SCRIPT report " + json.dumps(data, sort_keys=True), flush=True)


async def _checks(conn, rows):
    """check_row + the reference scan + the audit count. Returns (refs, audit_rows)."""
    check_row(rows)
    refs = await scan_references(conn, rows[0]["id"])
    audit_rows = await conn.fetchval(AUDIT_COUNT_SQL, str(rows[0]["id"]))
    return refs, audit_rows


async def _apply(conn):
    """One transaction: lock, check, delete exactly one row, re-count, audit (last). Returns the report dict;
    Refused or any error rolls everything back."""
    async with conn.transaction():
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        rows = await conn.fetch(CANDIDATES_SQL.rstrip() + " FOR UPDATE OF a", OLD_E2E_EMAIL)
        try:
            refs, audit_rows = await _checks(conn, rows)
        except Refused:
            _print_report(report(rows, "refused", None, None, 0, None, None))
            raise
        row = rows[0]
        status = await conn.execute(DELETE_SQL, row["id"], OLD_E2E_EMAIL)
        if status != "DELETE 1":
            raise RuntimeError(f"expected DELETE 1 on the locked row, got {status!r}")
        remaining = await conn.fetchval(REMAINING_SQL, OLD_E2E_EMAIL)
        if remaining != 0:
            raise RuntimeError(f"{remaining} row(s) still hold the old E2E address after the DELETE")
        details = {
            "restore": {"username": row["username"], "role": row["role"], "created_at": row["created_at"],
                        "is_owner": False, "password_hash": None, "email": "the CIS migration 250 test address"},
            "audit_rows_kept": audit_rows,
            "via": "db-migrate run-script",
            "issue": "AA-816",
            "step": "ADR 0006a A10",
        }
        audit_row_id = await conn.fetchval(AUDIT_SQL, ACTOR, AUDIT_ACTION, RESOURCE_TYPE, str(row["id"]),
                                           json.dumps(details, sort_keys=True))
        if audit_row_id is None:
            raise RuntimeError("the audit row was not written")
        return report(rows, "deleted", refs, audit_rows, 1, remaining, audit_row_id)


async def run(conn, apply: bool) -> int:
    print(f"SCRIPT {SCRIPT_NAME} mode={'APPLY' if apply else 'DRY_RUN'}", flush=True)
    if apply:
        try:
            data = await _apply(conn)
        except Refused as exc:
            print(f"SCRIPT REFUSED {exc}; nothing written", flush=True)
            return 1
        _print_report(data)
        print(f"SCRIPT committed outcome={data['outcome']} deleted={data['deleted']}", flush=True)
        return 0
    rows = await conn.fetch(CANDIDATES_SQL, OLD_E2E_EMAIL)
    try:
        refs, audit_rows = await _checks(conn, rows)
    except Refused as exc:
        _print_report(report(rows, "refused", None, None, 0, None, None))
        print(f"SCRIPT REFUSED {exc}; nothing written", flush=True)
        return 1
    _print_report(report(rows, "would_delete", refs, audit_rows, 0, len(rows), None))
    return 0


async def main(conn):
    return await run(conn, apply=not READ_ONLY)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse
    import asyncio

    import asyncpg

    parser = argparse.ArgumentParser(description="Delete the old E2E test staff row (DRY RUN by default)")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="delete the row (default: DRY RUN)")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, apply=args.apply)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
