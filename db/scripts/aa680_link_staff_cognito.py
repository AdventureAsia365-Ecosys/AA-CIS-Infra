"""AA-680 Phase 2, one-time: link bridge-era Booking staff rows to their Cognito WORKFORCE identity.

Booking now signs staff in with the Cognito WORKFORCE pool and finds a staff row by (cognito_iss, cognito_sub)
(AA-Booking bk-016). Rows created before that by the CIS bridge token are keyed by CIS shared.admin_users.id and hold
no identity yet; without a link their owner would get a second, empty `cog:<sub>` row on the first Cognito sign-in.
This script copies shared.admin_users.cognito_iss / cognito_sub (CIS 247, set by the staff directory) onto the
booking.staff_users row with the same id, plus the CIS e-mail and display name where the Booking row has none.

Rules:
- Only rows keyed by a CIS id (not `cog:`), whose CIS row has cognito_sub set, and whose Booking row is not linked.
- Never rebinds: a row already linked to another identity, or an identity already held by another Booking row
  (e.g. a `cog:` row from a sign-in before this script ran), is reported and skipped. Rows are never merged.
- Role and active are not touched (Booking sets the role from the booking-* group on the next Cognito sign-in).
- Idempotent: a second run finds every linked row `already_linked` and writes nothing.

Modes (DB Migrate mode=run-script, runs as the RDS master; db/scripts/README.md):
- READ_ONLY = True (this file as merged): DRY RUN. The session is read-only; prints one `SCRIPT row {...}` JSON line
  per bridge-era row (the mapping) and `SCRIPT counts {...}`. Writes nothing.
- Apply: a one-line follow-up PR sets READ_ONLY = False after the DRY RUN output was reviewed; dispatch again. Each
  linked row also gets one booking.audit_logs row (`staff.identity_linked`). The runner's idle check applies.
- Local test: `python3 db/scripts/aa680_link_staff_cognito.py <DSN> [--apply]` (DRY RUN without --apply).

Prints ids, roles, statuses, CIS usernames and the first 8 characters of each sub; no e-mail, password or DSN.
"""

import json
import uuid

READ_ONLY = True

SCRIPT_NAME = "aa680_link_staff_cognito"
COGNITO_KEY_PREFIX = "cog:"
LINKED = ("link", "linked")  # to link (DRY RUN) / linked now (apply)

PRECHECK_SQL = """
SELECT count(*) FROM information_schema.columns
 WHERE table_schema = 'booking' AND table_name = 'staff_users' AND column_name IN ('cognito_iss', 'cognito_sub')
"""

# Every Booking row keyed by a CIS id, its CIS row (if any) and the Booking row (if any) already holding that CIS
# row's identity. FOR UPDATE OF s only when applying (a read-only session cannot take row locks).
ROWS_SQL = """
SELECT s.cis_user_id, s.role, s.active, s.email IS NOT NULL AS has_email, s.name IS NOT NULL AS has_name,
       s.cognito_iss AS linked_iss, s.cognito_sub AS linked_sub,
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

LINK_SQL = """
UPDATE booking.staff_users
   SET cognito_iss = $2, cognito_sub = $3, email = coalesce(email, $4), name = coalesce(name, $5)
 WHERE cis_user_id = $1 AND cognito_iss IS NULL AND cognito_sub IS NULL
"""

AUDIT_SQL = """
INSERT INTO booking.audit_logs (actor_type, actor_ref, action, entity_type, entity_id, before, after, entity_label,
                                summary)
VALUES ('system', $1, 'staff.identity_linked', 'staff_user', $2::uuid, $3::jsonb, $4::jsonb, $5, $6)
"""


def classify(row) -> str:
    """The outcome for one Booking row: `link` or why it is skipped."""
    if row["linked_sub"] is not None:
        if (row["linked_iss"], row["linked_sub"]) == (row["cognito_iss"], row["cognito_sub"]):
            return "already_linked"
        return "conflict_linked_other"
    if not row["in_cis"]:
        return "no_cis_user"
    if row["cognito_sub"] is None:
        return "cis_not_linked"
    if row["holder"] is not None:
        return "conflict_cog_row_exists" if row["holder"].startswith(COGNITO_KEY_PREFIX) else "conflict_identity_taken"
    return "link"


def summary_line(row, outcome: str) -> dict:
    sub = row["cognito_sub"]
    return {
        "cis_user_id": row["cis_user_id"],
        "cis_username": row["cis_username"],
        "outcome": outcome,
        "booking_role": row["role"],
        "booking_active": row["active"],
        "cis_active": row["cis_active"],
        "sub8": sub[:8] if sub else None,
        "holder": row["holder"],
        "fills_email": outcome in LINKED and not row["has_email"] and row["cis_email"] is not None,
        "fills_name": outcome in LINKED and not row["has_name"] and row["cis_display_name"] is not None,
    }


def _uuid_or_none(value: str):
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


async def _link(conn, row) -> bool:
    status = await conn.execute(LINK_SQL, row["cis_user_id"], row["cognito_iss"], row["cognito_sub"],
                                row["cis_email"], row["cis_display_name"])
    if status != "UPDATE 1":
        return False
    await conn.execute(
        AUDIT_SQL,
        f"script:{SCRIPT_NAME}",
        _uuid_or_none(row["cis_user_id"]),
        json.dumps({"cis_user_id": row["cis_user_id"], "cognito_sub": None}),
        json.dumps({"cis_user_id": row["cis_user_id"], "cognito_iss": row["cognito_iss"],
                    "cognito_sub": row["cognito_sub"]}),
        row["cis_display_name"] or row["cis_username"] or row["cis_user_id"],
        "Linked to the company sign-in (Cognito WORKFORCE) from CIS staff directory (AA-680 backfill)",
    )
    return True


async def run(conn, apply: bool) -> int:
    print(f"SCRIPT {SCRIPT_NAME} mode={'APPLY' if apply else 'DRY_RUN'}", flush=True)
    if await conn.fetchval(PRECHECK_SQL) != 2:
        print("SCRIPT ERROR booking.staff_users has no cognito_iss / cognito_sub: apply AA-Booking bk-016 first",
              flush=True)
        return 1
    counts: dict = {}
    if apply:
        async with conn.transaction():
            await conn.execute("SET LOCAL lock_timeout = '5s'")
            rows = await conn.fetch(ROWS_SQL.rstrip() + " FOR UPDATE OF s")
            for row in rows:
                outcome = classify(row)
                if outcome == "link" and not await _link(conn, row):
                    outcome = "changed_concurrently"
                elif outcome == "link":
                    outcome = "linked"
                counts[outcome] = counts.get(outcome, 0) + 1
                print("SCRIPT row " + json.dumps(summary_line(row, outcome), sort_keys=True), flush=True)
    else:
        for row in await conn.fetch(ROWS_SQL):
            outcome = classify(row)
            counts[outcome] = counts.get(outcome, 0) + 1
            print("SCRIPT row " + json.dumps(summary_line(row, outcome), sort_keys=True), flush=True)
    print("SCRIPT counts " + json.dumps(counts, sort_keys=True), flush=True)
    return 0


async def main(conn):
    return await run(conn, apply=not READ_ONLY)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse
    import asyncio

    import asyncpg

    parser = argparse.ArgumentParser(description="Link bridge-era Booking staff rows to Cognito (DRY RUN by default)")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="write the links (default: DRY RUN)")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, apply=args.apply)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
