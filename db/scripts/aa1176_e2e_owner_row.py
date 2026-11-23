"""AA-1176 (Dev only): the CIS directory row, Booking grant and owner marker of the A10h Dev-only E2E owner.

Root ADR 0006a A10h (tech lead S288: "an admin like me" for the orchestrating agent's live checks): the address
e2e-owner@e2e-mail.lumiguides.it.com holds exactly the WORKFORCE groups cis-admin + booking-admin (Cognito user:
tools/identity/crm_dev_identity.py e2e-owner). Its CIS directory row must be an ``admin`` with the owner marker
(``shared.admin_users.is_owner``), never the business owner, no custom role, no password, and its Booking grant ``admin``
(``shared.staff_app_grant``). No product route sets ``is_owner`` (only the bootstrap tool, which needs the master secret
the CIS task role is denied), so this reviewed master run-script writes it, like aa1155_custom_maker_grants.py (S287).
CIS migration 473 must be applied first (its admin_users_email_chk branch allows the row and the marker).

Rules:
- Only the A10h address (matched in WHERE on lower(email); the e-mail is never selected or printed).
- No row yet: the same insert as the Staff page's Add staff (username e2e-owner, role admin, active, no password, not an
  owner, display name "E2E owner (agent, Dev only)"), audited ``staff.created``. The Cognito identity is linked at the
  first CIS sign-in (CIS first: Booking reads the marker through shared.v_staff_booking_grant, linked rows only).
- Refuses (raises, nothing changes) when more than one row matches, when the row's role is not admin, when it has a
  custom role, a password or the business-owner marker, when it is inactive (a disabled E2E owner is re-enabled on the
  Staff page by a person, never by this script), or when it holds a CRM role.
- Booking grant ``admin`` (upsert), audited ``staff.roles_changed`` {booking_role: {before, after}}.
- Owner marker: ``UPDATE ... SET is_owner = true WHERE id = $1 AND role = 'admin' AND NOT is_business_owner AND
  custom_role IS NULL AND password_hash IS NULL`` (exactly one row), audited ``staff.owner_marker_set``
  {is_owner: {before, after}}.
- Every audit row: actor ``script:db-migrate-aa1176``, resource_type admin_user, details carry
  ``source: "db-script:aa1176"`` and ``e2e_owner: true``. Idempotent: a second apply writes nothing (no audit row).
- REMOVE = True (cleanup after the removal, root ADR 0006a A10h): owner marker off, Booking grant deleted, audited
  ``staff.owner_marker_cleared`` and ``staff.roles_changed``. It is never the removal itself: this script makes no
  Cognito call, and the Cognito user's token alone still opens Booking (admin from its groups) and the CRM (cis-admin
  reader). The only immediate removal is Platform › Staff › Disable (row inactive, AdminDisableUser, global sign-out),
  so REMOVE refuses while the row is still active, and every REMOVE run ends with a ``cognito`` line saying the
  Cognito user was NOT touched here. The Cognito user is deleted with tools/identity at the A10 family removal.

Modes (DB Migrate mode=run-script, runs as the RDS master; db/scripts/README.md):
- READ_ONLY = True (this file as merged): DRY RUN. Read-only session; prints the current state and the planned writes.
- Apply: a one-line follow-up PR sets READ_ONLY = False after the DRY RUN output was reviewed; dispatch again.
- Remove (after Staff › Disable): a one-line PR sets REMOVE = True (with READ_ONLY = True first for its own DRY RUN,
  then False).
- Local test: ``python3 db/scripts/aa1176_e2e_owner_row.py <DSN> [--apply] [--remove]`` (DRY RUN without --apply).

Prints counts, roles, booleans and a fingerprint (first 12 hex of sha256 of the row id); no e-mail, name, sub, id or DSN.
"""

import hashlib
import json

READ_ONLY = True
REMOVE = False

SCRIPT_NAME = "aa1176_e2e_owner_row"
OWNER_EMAIL = "e2e-owner@e2e-mail.lumiguides.it.com"
OWNER_USERNAME = "e2e-owner"
OWNER_DISPLAY = "E2E owner (agent, Dev only)"
CIS_ROLE = "admin"
BOOKING_APP = "booking"
BOOKING_ROLE = "admin"
AUDIT_ACTOR = "script:db-migrate-aa1176"
SOURCE = "db-script:aa1176"

ROW_SQL = (
    "SELECT u.id, u.role::text AS role, u.custom_role, u.is_active, u.is_owner, u.is_business_owner, "
    "(u.password_hash IS NULL) AS no_password, (u.cognito_sub IS NOT NULL) AS has_identity, "
    "(SELECT g.role FROM shared.staff_app_grant g WHERE g.admin_user_id = u.id AND g.app = $2) AS booking_role "
    "FROM shared.admin_users u WHERE lower(u.email) = $1 ORDER BY u.id"
)
ROW_LOCK_SQL = "SELECT u.id FROM shared.admin_users u WHERE lower(u.email) = $1 ORDER BY u.id FOR UPDATE"
CRM_TABLE_SQL = "SELECT to_regclass('shared.staff_crm_grant') IS NOT NULL"
CRM_COUNT_SQL = "SELECT count(*) FROM shared.staff_crm_grant WHERE admin_user_id = $1::uuid"
CHECK_SQL = (
    "SELECT pg_catalog.pg_get_constraintdef(oid) FROM pg_catalog.pg_constraint "
    "WHERE conrelid = 'shared.admin_users'::regclass AND conname = 'admin_users_email_chk'"
)
USERNAME_TAKEN_SQL = "SELECT count(*) FROM shared.admin_users WHERE username = $1"
INSERT_ROW_SQL = (
    "INSERT INTO shared.admin_users (username, password_hash, role, is_active, email, display_name, is_owner) "
    "VALUES ($1, NULL, 'admin'::shared.admin_role, true, $2, $3, false) RETURNING id"
)
UPSERT_GRANT_SQL = (
    "INSERT INTO shared.staff_app_grant (admin_user_id, app, role) VALUES ($1::uuid, $2, $3) "
    "ON CONFLICT (admin_user_id, app) DO UPDATE SET role = EXCLUDED.role, updated_at = now()"
)
SET_OWNER_SQL = (
    "UPDATE shared.admin_users SET is_owner = true, updated_at = now() "
    "WHERE id = $1::uuid AND role = 'admin'::shared.admin_role AND NOT is_business_owner AND custom_role IS NULL "
    "AND password_hash IS NULL AND is_active"
)
REMOVE_SQL = (
    "UPDATE shared.admin_users SET is_owner = false, updated_at = now() WHERE id = $1::uuid AND NOT is_active"
)
STILL_ACTIVE = ("the A10h row is still active: disable it on Platform › Staff first (row inactive, Cognito disable, "
                "global sign-out); REMOVE is the cleanup after that, never instead of it; refusing")
COGNITO_NOTE = {"cognito_user": "NOT touched by this script",
                "check": "Platform › Staff › Disable ran both steps (disable_user, global_sign_out) without an error"}
DELETE_GRANT_SQL = "DELETE FROM shared.staff_app_grant WHERE admin_user_id = $1::uuid AND app = $2"
AUDIT_SQL = (
    "INSERT INTO acp_shared.audit_log (actor, action, resource_type, resource_id, details) "
    "VALUES ($1, $2, 'admin_user', $3, $4::jsonb)"
)
GRANT_VIEW_SQL = (
    "SELECT count(*) FILTER (WHERE v.is_owner AND v.booking_role_code = $2) "
    "FROM shared.v_staff_booking_grant v JOIN shared.admin_users u ON u.cognito_sub = v.cognito_sub "
    "WHERE lower(u.email) = $1"
)


def out(label, payload):
    print(f"SCRIPT {label} {json.dumps(payload, sort_keys=True, default=str)}", flush=True)


def fingerprint(row_id) -> str:
    return hashlib.sha256(str(row_id).encode()).hexdigest()[:12]


def details(**fields):
    return json.dumps({**fields, "source": SOURCE, "e2e_owner": True})


async def check_migration(conn) -> None:
    """CIS 473 must be applied: its CHECK names the address (else every write below is refused by the database)."""
    definition = await conn.fetchval(CHECK_SQL)
    applied = bool(definition) and f"'{OWNER_EMAIL}'" in definition
    out("migration_473", {"applied": applied})
    if not applied:
        raise RuntimeError("CIS migration 473 is not applied (admin_users_email_chk does not name the A10h address)")


async def read_target(conn, label="before"):
    rows = await conn.fetch(ROW_SQL, OWNER_EMAIL, BOOKING_APP)
    out("match", {"rows": len(rows)})
    if len(rows) > 1:
        raise RuntimeError(f"expected at most one directory row for the A10h address, found {len(rows)}: refusing")
    if not rows:
        return None
    r = rows[0]
    crm = await conn.fetchval(CRM_COUNT_SQL, str(r["id"])) if await conn.fetchval(CRM_TABLE_SQL) else 0
    out(label, {
        "fingerprint": fingerprint(r["id"]), "role": r["role"], "custom_role": r["custom_role"],
        "booking_role": r["booking_role"], "is_active": r["is_active"], "is_owner": r["is_owner"],
        "is_business_owner": r["is_business_owner"], "no_password": r["no_password"],
        "has_cognito_identity": r["has_identity"], "crm_roles": crm,
    })
    if r["is_business_owner"]:
        raise RuntimeError("the A10h row must never be the business owner: refusing")
    if REMOVE:
        if r["is_active"]:
            raise RuntimeError(STILL_ACTIVE)
        return r
    if r["role"] != CIS_ROLE or r["custom_role"] is not None:
        raise RuntimeError(f"row role is {r['role']} / custom {r['custom_role']}, A10h needs admin, no custom role")
    if not r["no_password"]:
        raise RuntimeError("the A10h row must not have a password: refusing")
    if not r["is_active"]:
        raise RuntimeError("the A10h row is disabled: a person re-enables it on the Staff page first; refusing")
    if crm:
        raise RuntimeError("the A10h row holds a CRM role: remove it on the Staff page first; refusing")
    if not r["has_identity"]:
        out("warning", {"note": "no Cognito identity linked yet: sign in to CIS first, then Booking sees the owner"})
    return r


async def plan(conn) -> int:
    r = await read_target(conn)
    if REMOVE:
        writes = 0 if r is None else int(r["is_owner"]) + int(r["booking_role"] is not None)
        out("plan", {"remove": True, "row": r is not None, "writes_planned": writes})
        out("summary", {"rows_matched": 0 if r is None else 1, "writes_planned": writes, "dry_run": True})
        out("cognito", COGNITO_NOTE)
        return 0
    if r is None:
        if await conn.fetchval(USERNAME_TAKEN_SQL, OWNER_USERNAME):
            raise RuntimeError("no row for the A10h address but its username is taken: refusing")
        out("plan", {"insert_row": True, "booking_role": {"before": None, "after": BOOKING_ROLE},
                     "is_owner": {"before": None, "after": True}})
        out("summary", {"rows_matched": 0, "writes_planned": 3, "dry_run": True})
        return 0
    todo = {"set_booking_grant": r["booking_role"] != BOOKING_ROLE, "set_owner_marker": not r["is_owner"]}
    out("plan", {"booking_role": {"before": r["booking_role"], "after": BOOKING_ROLE},
                 "is_owner": {"before": r["is_owner"], "after": True}, **todo})
    out("summary", {"rows_matched": 1, "writes_planned": sum(todo.values()), "dry_run": True})
    return 0


async def apply(conn) -> int:
    async with conn.transaction():
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        locked = await conn.fetch(ROW_LOCK_SQL, OWNER_EMAIL)
        audits = 0
        if not locked:
            if await conn.fetchval(USERNAME_TAKEN_SQL, OWNER_USERNAME):
                raise RuntimeError("no row for the A10h address but its username is taken: refusing")
            new_id = await conn.fetchval(INSERT_ROW_SQL, OWNER_USERNAME, OWNER_EMAIL, OWNER_DISPLAY)
            await conn.execute(AUDIT_SQL, AUDIT_ACTOR, "staff.created", str(new_id), details(role=CIS_ROLE))
            audits += 1
            out("created", {"fingerprint": fingerprint(new_id), "role": CIS_ROLE})
        r = await read_target(conn)
        if r is None:
            raise RuntimeError("the A10h row vanished: rolling back")
        row_id = str(r["id"])
        if r["booking_role"] != BOOKING_ROLE:
            status = await conn.execute(UPSERT_GRANT_SQL, row_id, BOOKING_APP, BOOKING_ROLE)
            if status != "INSERT 0 1":
                raise RuntimeError(f"unexpected grant status {status}: rolling back")
            await conn.execute(AUDIT_SQL, AUDIT_ACTOR, "staff.roles_changed", row_id,
                               details(booking_role={"before": r["booking_role"], "after": BOOKING_ROLE}))
            audits += 1
        if not r["is_owner"]:
            status = await conn.execute(SET_OWNER_SQL, row_id)
            if status != "UPDATE 1":
                raise RuntimeError(f"unexpected owner-marker status {status}: rolling back")
            await conn.execute(AUDIT_SQL, AUDIT_ACTOR, "staff.owner_marker_set", row_id,
                               details(is_owner={"before": False, "after": True}))
            audits += 1
        after = await read_target(conn, "after")
        if not after["is_owner"] or after["booking_role"] != BOOKING_ROLE or after["is_business_owner"]:
            raise RuntimeError("post-check failed: rolling back")
        in_view = await conn.fetchval(GRANT_VIEW_SQL, OWNER_EMAIL, BOOKING_ROLE)
        out("summary", {"rows_matched": 1, "audit_rows": audits, "booking_owner_view_rows": in_view,
                        "dry_run": False})
    return 0


async def remove(conn) -> int:
    async with conn.transaction():
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        await conn.fetch(ROW_LOCK_SQL, OWNER_EMAIL)
        r = await read_target(conn)
        if r is None:
            out("summary", {"rows_matched": 0, "audit_rows": 0, "dry_run": False})
            out("cognito", COGNITO_NOTE)
            return 0
        row_id, audits = str(r["id"]), 0
        if r["is_owner"]:
            status = await conn.execute(REMOVE_SQL, row_id)
            if status != "UPDATE 1":
                raise RuntimeError(f"unexpected remove status {status}: rolling back")
            await conn.execute(AUDIT_SQL, AUDIT_ACTOR, "staff.owner_marker_cleared", row_id,
                               details(is_owner={"before": True, "after": False}))
            audits += 1
        if r["booking_role"] is not None:
            await conn.execute(DELETE_GRANT_SQL, row_id, BOOKING_APP)
            await conn.execute(AUDIT_SQL, AUDIT_ACTOR, "staff.roles_changed", row_id,
                               details(booking_role={"before": r["booking_role"], "after": None}))
            audits += 1
        await read_target(conn, "after")
        out("summary", {"rows_matched": 1, "audit_rows": audits, "dry_run": False})
        out("cognito", COGNITO_NOTE)
    return 0


async def run(conn, *, apply_changes: bool) -> int:
    out("mode", {"script": SCRIPT_NAME, "apply": apply_changes, "remove": REMOVE})
    await check_migration(conn)
    if not apply_changes:
        return await plan(conn)
    return await (remove(conn) if REMOVE else apply(conn))


async def main(conn):
    return await run(conn, apply_changes=not READ_ONLY)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse
    import asyncio

    import asyncpg

    parser = argparse.ArgumentParser(description="The A10h E2E owner's directory row (DRY RUN by default)")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="write (default: DRY RUN)")
    parser.add_argument("--remove", action="store_true", help="the removal mode")
    args = parser.parse_args()
    REMOVE = args.remove

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, apply_changes=args.apply)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
