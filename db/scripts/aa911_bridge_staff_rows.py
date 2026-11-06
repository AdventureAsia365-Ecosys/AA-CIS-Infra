"""AA-911, one-time: link or deactivate the bridge-era Booking staff rows once the CIS to Booking bridge is gone.

After AA-911 Booking accepts only Cognito WORKFORCE tokens and finds a staff row by (cognito_iss, cognito_sub).
Rows created earlier by the CIS bridge token are keyed by the CIS shared.admin_users.id. A row that is still active
and has no Cognito identity can no longer be signed in to, so Done-when line 4 asks for "no active unlinked row".
This script decides per bridge-era row (key not `cog:`):

- `link`: the Booking row is active and unlinked, its CIS row is active and has cognito_sub, and no other Booking
  row holds that identity. Copies cognito_iss / cognito_sub (plus e-mail / name where Booking has none), exactly
  like db/scripts/aa680_link_staff_cognito.py.
- `deactivate` (active = false): every other active unlinked row, and always the E2E accounts (CIS username
  `e2e-*`), linked or not. An identity already held by another row (e.g. a `cog:` row) means deactivate, never
  merge. Rows are never deleted (FKs reference cis_user_id).
- no-op: rows already linked to their CIS identity (`already_linked`), linked to another identity
  (`linked_other`, reported), or already inactive (`already_inactive`). Idempotent: a second run writes nothing.

Guard: the run fails (return 1, nothing written) when an active unlinked bridge-era row belongs to a CIS username
outside EXPECTED_USERNAMES, including a NULL username (the CIS row is gone): an unknown person must be looked at
before anything is decided for them.

Modes (DB Migrate mode=run-script, runs as the RDS master; db/scripts/README.md):
- READ_ONLY = True (this file as merged): DRY RUN in a read-only session. Prints the planned action per row.
- Apply: a one-line follow-up PR sets READ_ONLY = False after the DRY RUN output was reviewed; dispatch again. One
  transaction, lock_timeout 5 s, rows locked FOR UPDATE OF s. Each write adds one booking.audit_logs row
  (`staff.identity_linked` / `staff.deactivated`, actor_ref `script:aa911_bridge_staff_rows`). The runner's idle
  check (every job table idle) applies to non-read-only runs.
- Local test: `python3 db/scripts/aa911_bridge_staff_rows.py <DSN> [--apply]` (DRY RUN without --apply).

Output: `SCRIPT row {...}` per bridge-era row (id, CIS username, sub8, action), `SCRIPT counts {...}` and
`SCRIPT verdict active_unlinked=<n>` (active rows with no Cognito identity, over ALL rows, after this run; a DRY RUN
reports the current state). Prints no e-mail, password, DSN or token; subs are cut to 8 characters.
"""

import json
import uuid

READ_ONLY = True

SCRIPT_NAME = "aa911_bridge_staff_rows"
COGNITO_KEY_PREFIX = "cog:"
E2E_PREFIX = "e2e-"
SUB_CHARS = 8
# The bridge-era rows known on 20/10/2026 (S245 run 39349316013). Anything else active and unlinked stops the run.
EXPECTED_USERNAMES = frozenset({"admin", "e2e-claude-code", "e2e-claude-code-2"})

PRECHECK_SQL = """
SELECT count(*) FROM information_schema.columns
 WHERE table_schema = 'booking' AND table_name = 'staff_users' AND column_name IN ('cognito_iss', 'cognito_sub')
"""

# Copied from aa680_link_staff_cognito.py (scripts are uploaded as one file, no imports), plus the Booking name.
ROWS_SQL = """
SELECT s.cis_user_id, s.role, s.active, s.email IS NOT NULL AS has_email, s.name IS NOT NULL AS has_name,
       s.name AS booking_name, s.cognito_iss AS linked_iss, s.cognito_sub AS linked_sub,
       a.id IS NOT NULL AS in_cis, a.username AS cis_username, a.is_active AS cis_active,
       a.cognito_iss, a.cognito_sub, a.email AS cis_email, a.display_name AS cis_display_name,
       h.cis_user_id AS holder
  FROM booking.staff_users s
  LEFT JOIN shared.admin_users a ON a.id::text = s.cis_user_id
  LEFT JOIN booking.staff_users h
         ON h.cognito_iss = a.cognito_iss AND h.cognito_sub = a.cognito_sub AND h.cis_user_id <> s.cis_user_id
 WHERE left(s.cis_user_id, 4) <> 'cog:'
 ORDER BY s.created_at, s.cis_user_id
"""

# Over every row (`cog:` rows always hold an identity: staff_users_cognito_key_chk).
ACTIVE_UNLINKED_SQL = "SELECT count(*) FROM booking.staff_users WHERE active AND cognito_sub IS NULL"

LINK_SQL = """
UPDATE booking.staff_users
   SET cognito_iss = $2, cognito_sub = $3, email = coalesce(email, $4), name = coalesce(name, $5)
 WHERE cis_user_id = $1 AND cognito_iss IS NULL AND cognito_sub IS NULL AND active
"""

DEACTIVATE_SQL = "UPDATE booking.staff_users SET active = false WHERE cis_user_id = $1 AND active"

AUDIT_SQL = """
INSERT INTO booking.audit_logs (actor_type, actor_ref, action, entity_type, entity_id, before, after, entity_label,
                                summary)
VALUES ('system', $1, $2, 'staff_user', $3::uuid, $4::jsonb, $5::jsonb, $6, $7)
"""

DONE = {"link": "linked", "deactivate": "deactivated"}


def _is_e2e(row) -> bool:
    return (row["cis_username"] or "").startswith(E2E_PREFIX)


def classify(row) -> tuple:
    """(action, reason) for one bridge-era row. action is `link`, `deactivate` or a no-op label."""
    unlinked = row["linked_sub"] is None
    if not row["active"]:
        return "already_inactive", None
    if _is_e2e(row):
        return "deactivate", "e2e_account"
    if not unlinked:
        if (row["linked_iss"], row["linked_sub"]) == (row["cognito_iss"], row["cognito_sub"]):
            return "already_linked", None
        return "linked_other", None
    if not row["in_cis"]:
        return "deactivate", "no_cis_user"
    if not row["cis_active"]:
        return "deactivate", "cis_inactive"
    if row["cognito_sub"] is None:
        return "deactivate", "cis_not_linked"
    if row["holder"] is not None:
        held = "cog_row_exists" if row["holder"].startswith(COGNITO_KEY_PREFIX) else "identity_taken"
        return "deactivate", held
    return "link", None


def guard_violations(rows) -> list:
    """Active unlinked bridge-era rows whose CIS username is unknown (NULL included)."""
    return [r["cis_user_id"] for r in rows
            if r["active"] and r["linked_sub"] is None and r["cis_username"] not in EXPECTED_USERNAMES]


def row_line(row, action: str, reason) -> dict:
    sub = row["cognito_sub"]
    return {
        "cis_user_id": row["cis_user_id"],
        "cis_username": row["cis_username"],
        "action": action,
        "reason": reason,
        "booking_role": row["role"],
        "booking_active": row["active"],
        "booking_linked": row["linked_sub"] is not None,
        "cis_active": row["cis_active"],
        "sub8": sub[:SUB_CHARS] if sub else None,
        "holder": (row["holder"][: len(COGNITO_KEY_PREFIX) + SUB_CHARS] if row["holder"] else None),
    }


def _uuid_or_none(value: str):
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


def _label(row) -> str:
    return row["booking_name"] or row["cis_display_name"] or row["cis_username"] or row["cis_user_id"]


async def _audit(conn, row, action: str, before: dict, after: dict, summary: str) -> None:
    await conn.execute(AUDIT_SQL, f"script:{SCRIPT_NAME}", action, _uuid_or_none(row["cis_user_id"]),
                       json.dumps(before), json.dumps(after), _label(row), summary)


async def _link(conn, row) -> bool:
    status = await conn.execute(LINK_SQL, row["cis_user_id"], row["cognito_iss"], row["cognito_sub"],
                                row["cis_email"], row["cis_display_name"])
    if status != "UPDATE 1":
        return False
    await _audit(conn, row, "staff.identity_linked",
                 {"cis_user_id": row["cis_user_id"], "cognito_sub": None},
                 {"cis_user_id": row["cis_user_id"], "cognito_iss": row["cognito_iss"],
                  "cognito_sub": row["cognito_sub"]},
                 "Linked to the company sign-in (Cognito WORKFORCE) when the CIS bridge was retired (AA-911)")
    return True


async def _deactivate(conn, row, reason: str) -> bool:
    status = await conn.execute(DEACTIVATE_SQL, row["cis_user_id"])
    if status != "UPDATE 1":
        return False
    await _audit(conn, row, "staff.deactivated",
                 {"cis_user_id": row["cis_user_id"], "active": True},
                 {"cis_user_id": row["cis_user_id"], "active": False, "reason": reason},
                 f"Deactivated: bridge-era row with no company sign-in ({reason}), CIS bridge retired (AA-911)")
    return True


def _print_rows(plan) -> dict:
    counts: dict = {}
    for row, action, reason in plan:
        counts[action] = counts.get(action, 0) + 1
        print("SCRIPT row " + json.dumps(row_line(row, action, reason), sort_keys=True), flush=True)
    print("SCRIPT counts " + json.dumps(counts, sort_keys=True), flush=True)
    return counts


def _guard_failed(rows) -> bool:
    bad = guard_violations(rows)
    if bad:
        print("SCRIPT ERROR active unlinked bridge-era rows of unexpected CIS users (or none), look at them first: "
              + json.dumps(bad), flush=True)
    return bool(bad)


async def run(conn, apply: bool) -> int:
    print(f"SCRIPT {SCRIPT_NAME} mode={'APPLY' if apply else 'DRY_RUN'}", flush=True)
    if await conn.fetchval(PRECHECK_SQL) != 2:
        print("SCRIPT ERROR booking.staff_users has no cognito_iss / cognito_sub: apply AA-Booking bk-016 first",
              flush=True)
        return 1
    if not apply:
        rows = await conn.fetch(ROWS_SQL)
        _print_rows([(r, *classify(r)) for r in rows])
        failed = _guard_failed(rows)
        print(f"SCRIPT verdict active_unlinked={await conn.fetchval(ACTIVE_UNLINKED_SQL)}", flush=True)
        return 1 if failed else 0
    async with conn.transaction():
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        rows = await conn.fetch(ROWS_SQL.rstrip() + " FOR UPDATE OF s")
        if _guard_failed(rows):
            _print_rows([(r, *classify(r)) for r in rows])
            return 1
        plan = []
        for row in rows:
            action, reason = classify(row)
            if action == "link":
                action = DONE[action] if await _link(conn, row) else "changed_concurrently"
            elif action == "deactivate":
                action = DONE[action] if await _deactivate(conn, row, reason) else "changed_concurrently"
            plan.append((row, action, reason))
        _print_rows(plan)
        remaining = await conn.fetchval(ACTIVE_UNLINKED_SQL)
    print(f"SCRIPT verdict active_unlinked={remaining}", flush=True)
    return 0


async def main(conn):
    return await run(conn, apply=not READ_ONLY)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse
    import asyncio

    import asyncpg

    parser = argparse.ArgumentParser(description="Link or deactivate bridge-era Booking staff rows (DRY RUN default)")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="write the changes (default: DRY RUN)")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, apply=args.apply)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
