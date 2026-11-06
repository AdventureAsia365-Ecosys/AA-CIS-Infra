"""AA-680 staff half, evidence (read-only): Booking holds no staff row for the refused E2E WORKFORCE user, and the
current booking.staff_users rows with their Cognito link state.

Why: the CIS Cognito E2E (AA-CIS-App .github/workflows/e2e-cognito.yml) signs the "E2E Cognito" WORKFORCE user
(CIS reviewer, no booking-* group) in to the Booking staff admin and expects /login?reason=no_booking_role. The
Booking API refuses that identity before any write (current_staff raises 403 no_booking_role before it creates or
links a staff row), so after the run Booking must still hold NO row for it. This script shows that from the database
side, and lists every Booking staff row (bridge-era rows keyed by a CIS id vs `cog:` rows, linked or not) so the
readiness of "every Booking staff signs in through Cognito" is visible.

Output (DB Migrate mode=run-script; db/scripts/README.md):
- `SCRIPT e2e {...}`: whether the E2E user exists in CIS, its CIS role / active flag, whether it is linked to a
  Cognito identity, and `booking_rows` = Booking rows that match it by CIS id, by Cognito identity, by its
  `cog:<sub>` key or by e-mail (expected 0).
- `SCRIPT row {...}`: one line per booking.staff_users row: key kind (`cis` / `cog`), id (a CIS uuid, or `cog:` and
  the first 8 characters of the sub), Booking role, active, linked (cognito_sub set), CIS username and active flag
  for `cis` rows, last_seen_at date.
- `SCRIPT counts {...}`, `SCRIPT verdict e2e_has_no_booking_row=<true|false>` and (AA-911 Done-when line 4)
  `SCRIPT verdict active_unlinked=<n>`: active rows with no Cognito identity (expected 0 once the bridge is retired
  and db/scripts/aa911_bridge_staff_rows.py has been applied). It is reported, never a failure.

Returns 1 (run fails, exit 13) only when a Booking row matches the E2E identity: then the refusal evidence is
contradicted and must be looked at. A missing E2E user (e.g. disabled and removed later, AA-816 A10) is reported,
not failed. Prints no e-mail, password, DSN or token; subs are cut to 8 characters.

Local test: `python3 db/scripts/aa680_staff_users_readonly_check.py <DSN>`.
"""

import json

READ_ONLY = True

# The SES test mailbox that is the E2E staff user's address (CIS migration 250, a temporary exception).
E2E_EMAIL = "e2e@e2e-mail.lumiguides.it.com"
COGNITO_KEY_PREFIX = "cog:"
SUB_CHARS = 8

E2E_SQL = """
SELECT a.id::text AS id, a.role::text AS cis_role, a.is_active, a.cognito_sub IS NOT NULL AS cognito_linked,
       (SELECT count(*) FROM booking.staff_users s
         WHERE s.cis_user_id = a.id::text
            OR (a.cognito_sub IS NOT NULL AND s.cognito_iss = a.cognito_iss AND s.cognito_sub = a.cognito_sub)
            OR (a.cognito_sub IS NOT NULL AND s.cis_user_id = 'cog:' || a.cognito_sub)
            OR lower(s.email) = $1) AS booking_rows
  FROM shared.admin_users a
 WHERE lower(a.email) = $1
"""

# Booking rows matching the address when the CIS row is gone (no CIS id or identity to compare).
E2E_EMAIL_ONLY_SQL = "SELECT count(*) FROM booking.staff_users WHERE lower(email) = $1"

ROWS_SQL = """
SELECT s.cis_user_id, s.role, s.active, s.cognito_sub IS NOT NULL AS linked, s.cognito_sub,
       s.last_seen_at::date::text AS last_seen,
       a.id IS NOT NULL AS in_cis, a.username AS cis_username, a.is_active AS cis_active
  FROM booking.staff_users s
  LEFT JOIN shared.admin_users a ON left(s.cis_user_id, 4) <> 'cog:' AND a.id::text = s.cis_user_id
 ORDER BY s.created_at, s.cis_user_id
"""


def row_line(row) -> dict:
    """One printable line per Booking staff row (no e-mail; a `cog:` key and the sub cut to 8 characters)."""
    key = row["cis_user_id"]
    cog = key.startswith(COGNITO_KEY_PREFIX)
    line = {
        "kind": "cog" if cog else "cis",
        "id": key[: len(COGNITO_KEY_PREFIX) + SUB_CHARS] if cog else key,
        "role": row["role"],
        "active": row["active"],
        "linked": row["linked"],
        "sub8": (row["cognito_sub"] or "")[:SUB_CHARS] or None,
        "last_seen": row["last_seen"],
    }
    if not cog:
        line.update(in_cis=row["in_cis"], cis_username=row["cis_username"], cis_active=row["cis_active"])
    return line


def counts(rows) -> dict:
    lines = [row_line(r) for r in rows]
    return {
        "total": len(lines),
        "cog_rows": sum(1 for x in lines if x["kind"] == "cog"),
        "cis_rows": sum(1 for x in lines if x["kind"] == "cis"),
        "linked": sum(1 for x in lines if x["linked"]),
        "unlinked": sum(1 for x in lines if not x["linked"]),
        "unlinked_active": sum(1 for x in lines if not x["linked"] and x["active"]),
    }


async def run(conn) -> int:
    e2e = await conn.fetchrow(E2E_SQL, E2E_EMAIL)
    if e2e is None:
        booking_rows = await conn.fetchval(E2E_EMAIL_ONLY_SQL, E2E_EMAIL)
        info = {"in_cis": False, "booking_rows": booking_rows}
    else:
        booking_rows = e2e["booking_rows"]
        info = {
            "in_cis": True,
            "cis_id": e2e["id"],
            "cis_role": e2e["cis_role"],
            "cis_active": e2e["is_active"],
            "cognito_linked": e2e["cognito_linked"],
            "booking_rows": booking_rows,
        }
    print(f"SCRIPT e2e {json.dumps(info, sort_keys=True)}", flush=True)

    rows = await conn.fetch(ROWS_SQL)
    for r in rows:
        print(f"SCRIPT row {json.dumps(row_line(r), sort_keys=True)}", flush=True)
    print(f"SCRIPT counts {json.dumps(counts(rows), sort_keys=True)}", flush=True)

    ok = booking_rows == 0
    print(f"SCRIPT verdict e2e_has_no_booking_row={'true' if ok else 'false'}", flush=True)
    print(f"SCRIPT verdict active_unlinked={counts(rows)['unlinked_active']}", flush=True)
    return 0 if ok else 1


async def main(conn):
    return await run(conn)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse
    import asyncio

    import asyncpg

    parser = argparse.ArgumentParser(description="AA-680 read-only Booking staff_users check")
    parser.add_argument("dsn")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
