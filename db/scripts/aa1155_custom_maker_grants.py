"""AA-1155 (one-time, Dev): give the A10g E2E custom-role maker its two custom roles.

Root ADR 0006a A10g: the Dev-only address e2e-custom-maker@e2e-mail.lumiguides.it.com holds exactly the WORKFORCE
groups cis-custom + booking-custom. Its CIS directory row needs the CIS custom role ``custom_content`` ("Content",
CIS 462 seed, based_on content_lead) and its Booking grant the Booking custom role ``custom_product_ops_accounting``
("Product, ops & accounting", bk-062 seed). Without them CIS answers 403 custom_role_unavailable and Booking 403
no_booking_role, which is the correct fail-closed result, but the AA-1155 live proof (R4.1, R4.3, R5.1) needs them.
The normal path is the CIS Staff page as an is_owner user; this script is the master-login path for the same two
writes (shared.admin_users.custom_role and one shared.staff_app_grant row), with the same audit action.

Rules:
- Only the A10g address (matched in WHERE on lower(email); the e-mail is never selected or printed).
- Creates the directory row when none exists yet (S287: the maker had never been added on the Staff page, and CIS
  refuses a WORKFORCE sign-in with no row): the same insert as the Staff page's Add staff (role content_lead, active,
  no password, not an owner), audited as ``staff.created``. The Cognito identity is linked at the maker's next sign-in.
- Refuses (raises, nothing changes) when more than one row matches, when the row's CIS role is not
  content_lead (the A10g CHECK branch of admin_users_email_chk needs it), when the row is an owner or the business
  owner, or when either custom role is missing, archived, or does not hold its seed capability count (18 / 24).
- Reports, does not refuse: is_active and whether a Cognito identity is linked (shared.v_staff_booking_grant shows
  only active rows with a Cognito identity, so Booking would still answer no_booking_role without them).
- Idempotent: a second apply finds both values in place and writes nothing (no audit row).
- One acp_shared.audit_log row ``staff.roles_changed`` (resource_type admin_user, the directory's own action) with
  {role: {before, after}, booking_role: {before, after}, source: "db-script:aa1155"} per apply that changes something.

Modes (DB Migrate mode=run-script, runs as the RDS master; db/scripts/README.md):
- READ_ONLY = True (this file as merged): DRY RUN. Read-only session; prints the current state, the planned change
  and the counts. Writes nothing.
- Apply: a one-line follow-up PR sets READ_ONLY = False after the DRY RUN output was reviewed; dispatch again.
- Local test: ``python3 db/scripts/aa1155_custom_maker_grants.py <DSN> [--apply]`` (DRY RUN without --apply).

Prints counts, role codes, booleans and a fingerprint (first 12 hex of sha256 of the row id); no e-mail, name, sub,
id or DSN.
"""

import hashlib
import json

READ_ONLY = False

SCRIPT_NAME = "aa1155_custom_maker_grants"
MAKER_EMAIL = "e2e-custom-maker@e2e-mail.lumiguides.it.com"
CIS_BASE_ROLE = "content_lead"
CIS_CUSTOM = "custom_content"
CIS_CUSTOM_CAPS = 18
BOOKING_APP = "booking"
BOOKING_CUSTOM = "custom_product_ops_accounting"
BOOKING_CUSTOM_CAPS = 24
AUDIT_ACTION = "staff.roles_changed"
AUDIT_ACTOR = "script:db-migrate-aa1155"
MAKER_USERNAME = "e2e-custom-maker"
MAKER_DISPLAY = "E2E custom role maker"

ROW_SQL = (
    "SELECT u.id, u.role::text AS role, u.custom_role, u.is_active, u.is_owner, u.is_business_owner, "
    "(u.cognito_sub IS NOT NULL) AS has_identity, "
    "(SELECT g.role FROM shared.staff_app_grant g WHERE g.admin_user_id = u.id AND g.app = $2) AS booking_role "
    "FROM shared.admin_users u WHERE lower(u.email) = $1 ORDER BY u.id"
)
ROW_LOCK_SQL = "SELECT u.id FROM shared.admin_users u WHERE lower(u.email) = $1 ORDER BY u.id FOR UPDATE"
CIS_ROLE_SQL = (
    "SELECT r.archived, r.based_on::text AS based_on, "
    "(SELECT count(*) FROM shared.staff_role_capability c WHERE c.role_code = r.code) AS caps "
    "FROM shared.staff_role r WHERE r.code = $1"
)
BOOKING_ROLE_SQL = (
    "SELECT r.archived, r.based_on, "
    "(SELECT count(*) FROM booking.staff_role_capability c WHERE c.role_code = r.code) AS caps "
    "FROM booking.staff_role r WHERE r.code = $1"
)
SET_CUSTOM_SQL = (
    "UPDATE shared.admin_users SET custom_role = $2, updated_at = now() "
    "WHERE id = $1::uuid AND role = 'content_lead'::shared.admin_role"
)
UPSERT_GRANT_SQL = (
    "INSERT INTO shared.staff_app_grant (admin_user_id, app, role) VALUES ($1::uuid, $2, $3) "
    "ON CONFLICT (admin_user_id, app) DO UPDATE SET role = EXCLUDED.role, updated_at = now()"
)
AUDIT_SQL = (
    "INSERT INTO acp_shared.audit_log (actor, action, resource_type, resource_id, details) "
    "VALUES ($1, $2, 'admin_user', $3, $4::jsonb)"
)
USERNAME_TAKEN_SQL = "SELECT count(*) FROM shared.admin_users WHERE username = $1"
INSERT_ROW_SQL = (
    "INSERT INTO shared.admin_users (username, password_hash, role, is_active, email, display_name, is_owner) "
    "VALUES ($1, NULL, 'content_lead'::shared.admin_role, true, $2, $3, false) RETURNING id"
)
GRANT_VIEW_COUNT_SQL = (
    "SELECT count(*) FROM shared.v_staff_booking_grant v JOIN shared.admin_users u ON u.cognito_sub = v.cognito_sub "
    "WHERE lower(u.email) = $1 AND v.booking_role_code = $2"
)


def out(label, payload):
    print(f"SCRIPT {label} {json.dumps(payload, sort_keys=True, default=str)}", flush=True)


def fingerprint(row_id) -> str:
    return hashlib.sha256(str(row_id).encode()).hexdigest()[:12]


async def check_roles(conn) -> None:
    cis = await conn.fetchrow(CIS_ROLE_SQL, CIS_CUSTOM)
    bk = await conn.fetchrow(BOOKING_ROLE_SQL, BOOKING_CUSTOM)
    out("roles", {
        "cis": None if cis is None else {"code": CIS_CUSTOM, "archived": cis["archived"], "based_on": cis["based_on"],
                                         "caps": cis["caps"]},
        "booking": None if bk is None else {"code": BOOKING_CUSTOM, "archived": bk["archived"],
                                            "based_on": bk["based_on"], "caps": bk["caps"]},
    })
    if cis is None or cis["archived"] or cis["based_on"] != CIS_BASE_ROLE or cis["caps"] != CIS_CUSTOM_CAPS:
        raise RuntimeError(f"CIS custom role {CIS_CUSTOM} missing, archived or not the 462 seed: refusing")
    if bk is None or bk["archived"] or bk["caps"] != BOOKING_CUSTOM_CAPS:
        raise RuntimeError(f"Booking custom role {BOOKING_CUSTOM} missing, archived or not the bk-062 seed: refusing")


async def read_target(conn, label="before"):
    rows = await conn.fetch(ROW_SQL, MAKER_EMAIL, BOOKING_APP)
    out("match", {"rows": len(rows)})
    if len(rows) != 1:
        raise RuntimeError(f"expected exactly one directory row for the A10g address, found {len(rows)}: refusing")
    r = rows[0]
    state = {
        "fingerprint": fingerprint(r["id"]), "role": r["role"], "custom_role": r["custom_role"],
        "booking_role": r["booking_role"], "is_active": r["is_active"], "has_cognito_identity": r["has_identity"],
        "is_owner": r["is_owner"], "is_business_owner": r["is_business_owner"],
    }
    out(label, state)
    if r["role"] != CIS_BASE_ROLE:
        raise RuntimeError(f"row role is {r['role']}, A10g needs {CIS_BASE_ROLE}: refusing")
    if r["is_owner"] or r["is_business_owner"]:
        raise RuntimeError("the A10g row must never be an owner or the business owner: refusing")
    if not r["is_active"] or not r["has_identity"]:
        out("warning", {"note": "row inactive or no Cognito identity linked: the Booking grant view will not list it "
                                "until the Staff page links it (Sync)"})
    return r


async def run(conn, *, apply: bool) -> int:
    out("mode", {"script": SCRIPT_NAME, "apply": apply})
    if not apply:
        await check_roles(conn)
        n = len(await conn.fetch(ROW_SQL, MAKER_EMAIL, BOOKING_APP))
        if n == 0:
            taken = await conn.fetchval(USERNAME_TAKEN_SQL, MAKER_USERNAME)
            out("match", {"rows": 0})
            if taken:
                raise RuntimeError("no row for the A10g address but its username is taken: refusing")
            out("plan", {"insert_row": True, "role": {"before": None, "after": CIS_CUSTOM},
                         "booking_role": {"before": None, "after": BOOKING_CUSTOM}})
            out("summary", {"rows_matched": 0, "writes_planned": 3, "dry_run": True})
            return 0
        r = await read_target(conn)
        plan = {
            "set_custom_role": r["custom_role"] != CIS_CUSTOM,
            "set_booking_grant": r["booking_role"] != BOOKING_CUSTOM,
        }
        out("plan", {"role": {"before": r["custom_role"], "after": CIS_CUSTOM},
                     "booking_role": {"before": r["booking_role"], "after": BOOKING_CUSTOM}, **plan})
        out("summary", {"rows_matched": 1, "writes_planned": sum(plan.values()), "dry_run": True})
        return 0

    async with conn.transaction():
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        locked = await conn.fetch(ROW_LOCK_SQL, MAKER_EMAIL)
        await check_roles(conn)
        if not locked:
            if await conn.fetchval(USERNAME_TAKEN_SQL, MAKER_USERNAME):
                raise RuntimeError("no row for the A10g address but its username is taken: refusing")
            new_id = await conn.fetchval(INSERT_ROW_SQL, MAKER_USERNAME, MAKER_EMAIL, MAKER_DISPLAY)
            await conn.execute(AUDIT_SQL, AUDIT_ACTOR, "staff.created", str(new_id),
                               json.dumps({"role": CIS_BASE_ROLE, "source": "db-script:aa1155"}))
            out("created", {"fingerprint": fingerprint(new_id), "role": CIS_BASE_ROLE})
            locked = await conn.fetch(ROW_LOCK_SQL, MAKER_EMAIL)
        if len(locked) != 1:
            raise RuntimeError(f"expected exactly one directory row for the A10g address, found {len(locked)}: refusing")
        r = await read_target(conn)
        row_id = str(r["id"])
        writes = 0
        changes = {}
        if r["custom_role"] != CIS_CUSTOM:
            status = await conn.execute(SET_CUSTOM_SQL, row_id, CIS_CUSTOM)
            if status != "UPDATE 1":
                raise RuntimeError(f"unexpected update status {status}: rolling back")
            writes += 1
            changes["role"] = {"before": r["custom_role"] or r["role"], "after": CIS_CUSTOM}
        if r["booking_role"] != BOOKING_CUSTOM:
            status = await conn.execute(UPSERT_GRANT_SQL, row_id, BOOKING_APP, BOOKING_CUSTOM)
            if status != "INSERT 0 1":
                raise RuntimeError(f"unexpected grant status {status}: rolling back")
            writes += 1
            changes["booking_role"] = {"before": r["booking_role"], "after": BOOKING_CUSTOM}
        if changes:
            changes["source"] = "db-script:aa1155"
            await conn.execute(AUDIT_SQL, AUDIT_ACTOR, AUDIT_ACTION, row_id, json.dumps(changes))
        after = await read_target(conn, "after")
        if after["custom_role"] != CIS_CUSTOM or after["booking_role"] != BOOKING_CUSTOM:
            raise RuntimeError("post-check failed: rolling back")
        in_view = await conn.fetchval(GRANT_VIEW_COUNT_SQL, MAKER_EMAIL, BOOKING_CUSTOM)
        out("summary", {"rows_matched": 1, "writes": writes, "audit_rows": 1 if changes else 0,
                        "booking_grant_view_rows": in_view, "dry_run": False})
    return 0


async def main(conn):
    return await run(conn, apply=not READ_ONLY)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse
    import asyncio

    import asyncpg

    parser = argparse.ArgumentParser(description="Give the A10g maker its custom roles (DRY RUN by default)")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="write the two values (default: DRY RUN)")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, apply=args.apply)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
