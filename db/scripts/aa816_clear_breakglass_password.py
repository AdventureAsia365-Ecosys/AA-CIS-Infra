"""AA-816 checklist B6 (decision N-B), one-time: clear the legacy password hash of the CIS break-glass staff row.

Root ADR 0006a A4: the break-glass account signs in through Cognito WORKFORCE (password + TOTP) and needs an active
shared.admin_users row with `password_hash` NULL. The row still holds a legacy hash, so `admin` + that old password
still opens the legacy login (Preview, API). This script sets it to NULL and writes one acp_shared.audit_log row in
the same transaction. Plan: root docs/audits/2026-10-19-S244-aa816-cutover/cutover-prep.md (B6).

Rules:
- The break-glass row is found the way the CIS staff directory finds it (AA-CIS-App staff_directory.is_breakglass):
  username `admin` or a break-glass e-mail. The script refuses (exit 13, nothing written) unless exactly one row
  matches AND that row has both the username `admin` and a break-glass e-mail.
- Only `password_hash` (and `updated_at`) change. Role, active, owner and the Cognito link are reported, not touched.
- Idempotent: a row whose hash is already NULL reports `already_null` and writes nothing.

Modes (DB Migrate mode=run-script, runs as the RDS master; db/scripts/README.md):
- READ_ONLY = False (this file as merged): apply, in one transaction.
- READ_ONLY = True: DRY RUN, the same checks and report (`would_clear`), no lock, no write.
- Local test: `python3 db/scripts/aa816_clear_breakglass_password.py <DSN> [--apply]` (DRY RUN without --apply).

Prints counts and booleans only (and the audit row id): never the hash, an e-mail or the DSN.
"""

import json

READ_ONLY = False

SCRIPT_NAME = "aa816_clear_breakglass_password"
ACTOR = f"script:{SCRIPT_NAME}"
AUDIT_ACTION = "staff.legacy_password_cleared"
RESOURCE_TYPE = "admin_user"
# Copied from AA-CIS-App api/services/staff_directory.py (a db/scripts file may not import app code).
BREAKGLASS_USERNAME = "admin"
BREAKGLASS_EMAILS = ("admin@adventure.asia", "breakglass@adventure.asia")

CANDIDATES_SQL = """
SELECT id, lower(btrim(username)) AS username_norm, lower(btrim(email)) AS email_norm,
       password_hash IS NOT NULL AS has_hash, is_active, role::text = 'admin' AS role_is_admin, is_owner,
       cognito_sub IS NOT NULL AS linked
  FROM shared.admin_users
 WHERE lower(btrim(username)) = $1 OR lower(btrim(email)) = ANY($2::text[])
 ORDER BY id
"""

CLEAR_SQL = """
UPDATE shared.admin_users SET password_hash = NULL, updated_at = now()
 WHERE id = $1 AND password_hash IS NOT NULL
"""

HAS_HASH_SQL = "SELECT password_hash IS NOT NULL FROM shared.admin_users WHERE id = $1"

AUDIT_SQL = """
INSERT INTO acp_shared.audit_log (tenant_id, actor, action, resource_type, resource_id, details)
VALUES (NULL, $1, $2, $3, $4, $5::jsonb)
RETURNING id
"""


class Refused(Exception):
    """The candidate rows are not exactly the break-glass row: nothing is written."""


def check_candidates(rows) -> None:
    """Raise Refused unless `rows` is exactly one row that is the break-glass row by username AND e-mail."""
    if len(rows) != 1:
        raise Refused(f"expected exactly 1 break-glass candidate row, found {len(rows)}")
    row = rows[0]
    if row["username_norm"] != BREAKGLASS_USERNAME:
        raise Refused("the only candidate row does not have the break-glass username")
    if row["email_norm"] not in BREAKGLASS_EMAILS:
        raise Refused("the only candidate row does not have a break-glass e-mail")


def report(rows, outcome: str, had_hash, has_hash_after, audit_row_id) -> dict:
    row = rows[0] if len(rows) == 1 else None
    return {
        "candidates": len(rows),
        "row_found": row is not None,
        "outcome": outcome,
        "had_hash_before": had_hash,
        "has_hash_after": has_hash_after,
        "is_active": row["is_active"] if row else None,
        "role_is_admin": row["role_is_admin"] if row else None,
        "is_owner": row["is_owner"] if row else None,
        "linked": row["linked"] if row else None,
        "audit_row_id": str(audit_row_id) if audit_row_id is not None else None,
    }


def _print_report(data: dict) -> None:
    print("SCRIPT report " + json.dumps(data, sort_keys=True), flush=True)


async def _apply(conn):
    """One transaction: lock, check, clear, re-read, audit (last: the audit chain trigger locks). Returns the
    report dict; Refused or any error rolls everything back."""
    async with conn.transaction():
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        rows = await conn.fetch(CANDIDATES_SQL.rstrip() + " FOR UPDATE", BREAKGLASS_USERNAME,
                                list(BREAKGLASS_EMAILS))
        try:
            check_candidates(rows)
        except Refused:
            _print_report(report(rows, "refused", None, None, None))
            raise
        row = rows[0]
        if not row["has_hash"]:
            return report(rows, "already_null", False, False, None)
        status = await conn.execute(CLEAR_SQL, row["id"])
        if status != "UPDATE 1":
            raise RuntimeError(f"expected UPDATE 1 on the locked break-glass row, got {status!r}")
        has_hash_after = await conn.fetchval(HAS_HASH_SQL, row["id"])
        if has_hash_after is not False:
            raise RuntimeError("password_hash is still set after the UPDATE")
        details = {
            "has_password": {"before": True, "after": False},
            "username": BREAKGLASS_USERNAME,
            "via": "db-migrate run-script",
            "issue": "AA-816",
            "step": "B6 / N-B",
        }
        audit_row_id = await conn.fetchval(AUDIT_SQL, ACTOR, AUDIT_ACTION, RESOURCE_TYPE, str(row["id"]),
                                           json.dumps(details, sort_keys=True))
        if audit_row_id is None:
            raise RuntimeError("the audit row was not written")
        return report(rows, "cleared", True, False, audit_row_id)


async def run(conn, apply: bool) -> int:
    print(f"SCRIPT {SCRIPT_NAME} mode={'APPLY' if apply else 'DRY_RUN'}", flush=True)
    if apply:
        try:
            data = await _apply(conn)
        except Refused as exc:
            print(f"SCRIPT REFUSED {exc}; nothing written", flush=True)
            return 1
        _print_report(data)
        print(f"SCRIPT committed outcome={data['outcome']}", flush=True)
        return 0
    rows = await conn.fetch(CANDIDATES_SQL, BREAKGLASS_USERNAME, list(BREAKGLASS_EMAILS))
    try:
        check_candidates(rows)
    except Refused as exc:
        _print_report(report(rows, "refused", None, None, None))
        print(f"SCRIPT REFUSED {exc}; nothing written", flush=True)
        return 1
    had = rows[0]["has_hash"]
    _print_report(report(rows, "would_clear" if had else "already_null", had, had, None))
    return 0


async def main(conn):
    return await run(conn, apply=not READ_ONLY)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse
    import asyncio

    import asyncpg

    parser = argparse.ArgumentParser(
        description="Clear the break-glass row's legacy password hash (DRY RUN by default)")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="clear the hash (default: DRY RUN)")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, apply=args.apply)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
