"""S283 Q4 access review (AA-1111, data standards DM-8.10), DB part — read-only catalog report.

Reproduces section 6 of the S245 access review (docs/audits/2026-10-20-S245-access-review/README.md) for the 2026-Q4
record docs/audits/2026-11-17-S283-access-review/README.md: who can log in to the shared RDS, which role is a member of
which, what each login role can reach per schema (direct grants and through membership), the default ACLs, where
PUBLIC still holds a privilege, and which login roles can read a credential column (comment tag `conf:credential`).
It also counts the staff sign-in rows that grant app access (shared.admin_users, shared.staff_app_grant,
shared.staff_crm_grant, booking.staff_users, open view-as sessions, active CRM support grants).

Catalog reads and aggregate counts only: no table row value, no username, e-mail, password hash, token or DSN is
printed. Every output line starts with `SCRIPT `.

Run: AA-CIS-Infra DB Migrate, mode=run-script (db/scripts/README.md contract: `READ_ONLY = True`, `async def main(conn)`).
Copy to AA-CIS-Infra `db/scripts/s283_access_review_db.py` before dispatch.
"""

import json

READ_ONLY = True

# Login roles the apps and tools use; the review checks what each can reach.
LOGIN_ROLES_SQL = """
SELECT r.rolname
  FROM pg_roles r
 WHERE r.rolcanlogin
   AND r.rolname NOT LIKE 'pg\\_%'
   AND r.rolname NOT LIKE 'rds%'
 ORDER BY r.rolname
"""

ROLES_SQL = """
SELECT r.rolname, r.rolcanlogin, r.rolsuper, r.rolbypassrls, r.rolcreaterole, r.rolcreatedb, r.rolinherit,
       r.rolreplication, r.rolconnlimit, r.rolvaliduntil IS NOT NULL AS has_valid_until,
       (SELECT count(*) FROM pg_stat_activity a WHERE a.usename = r.rolname) AS sessions_now
  FROM pg_roles r
 WHERE r.rolname NOT LIKE 'pg\\_%'
   AND r.rolname NOT IN ('rdsadmin', 'rdsrepladmin', 'rdstopmgr')
 ORDER BY r.rolname
"""

MEMBERSHIP_SQL = """
SELECT m.rolname AS member, g.rolname AS member_of, am.admin_option, am.inherit_option
  FROM pg_auth_members am
  JOIN pg_roles m ON m.oid = am.member
  JOIN pg_roles g ON g.oid = am.roleid
 WHERE m.rolname NOT LIKE 'pg\\_%'
   AND m.rolname NOT IN ('rdsadmin', 'rdsrepladmin', 'rdstopmgr')
 ORDER BY 1, 2
"""

# PG 15 has no inherit_option column (PG 16+); fall back to this shape.
MEMBERSHIP_SQL_PG15 = """
SELECT m.rolname AS member, g.rolname AS member_of, am.admin_option
  FROM pg_auth_members am
  JOIN pg_roles m ON m.oid = am.member
  JOIN pg_roles g ON g.oid = am.roleid
 WHERE m.rolname NOT LIKE 'pg\\_%'
   AND m.rolname NOT IN ('rdsadmin', 'rdsrepladmin', 'rdstopmgr')
 ORDER BY 1, 2
"""

DATABASE_ACL_SQL = """
SELECT d.datname, coalesce(g.rolname, 'PUBLIC') AS grantee, a.privilege_type
  FROM pg_database d
  CROSS JOIN LATERAL aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
  LEFT JOIN pg_roles g ON g.oid = a.grantee
 WHERE d.datname = current_database()
 ORDER BY 2, 3
"""

APP_SCHEMAS_SQL = """
SELECT n.nspname, o.rolname AS owner
  FROM pg_namespace n
  JOIN pg_roles o ON o.oid = n.nspowner
 WHERE n.nspname NOT LIKE 'pg\\_%'
   AND n.nspname NOT IN ('information_schema')
 ORDER BY n.nspname
"""

SCHEMA_ACL_SQL = """
SELECT n.nspname, coalesce(g.rolname, 'PUBLIC') AS grantee, a.privilege_type
  FROM pg_namespace n
  CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
  LEFT JOIN pg_roles g ON g.oid = a.grantee
 WHERE n.nspname NOT LIKE 'pg\\_%'
   AND n.nspname <> 'information_schema'
 ORDER BY 1, 2, 3
"""

# Direct table/view grants, summarised per grantee, schema and privilege (count of relations).
TABLE_GRANTS_SQL = """
SELECT coalesce(g.rolname, 'PUBLIC') AS grantee, n.nspname, a.privilege_type, count(DISTINCT c.oid) AS relations
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN LATERAL aclexplode(c.relacl) a
  LEFT JOIN pg_roles g ON g.oid = a.grantee
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND c.relacl IS NOT NULL
   AND n.nspname NOT LIKE 'pg\\_%'
   AND n.nspname <> 'information_schema'
   AND a.grantee <> c.relowner
 GROUP BY 1, 2, 3
 ORDER BY 1, 2, 3
"""

COLUMN_GRANTS_SQL = """
SELECT coalesce(g.rolname, 'PUBLIC') AS grantee, n.nspname, a.privilege_type, count(*) AS columns,
       count(DISTINCT c.oid) AS relations
  FROM pg_attribute att
  JOIN pg_class c ON c.oid = att.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN LATERAL aclexplode(att.attacl) a
  LEFT JOIN pg_roles g ON g.oid = a.grantee
 WHERE att.attacl IS NOT NULL
   AND NOT att.attisdropped
   AND n.nspname NOT LIKE 'pg\\_%'
   AND n.nspname <> 'information_schema'
 GROUP BY 1, 2, 3
 ORDER BY 1, 2, 3
"""

# Effective reach (direct + through membership) of one login role: relations per schema it can SELECT / write.
EFFECTIVE_REACH_SQL = """
SELECT n.nspname,
       count(*) AS relations,
       count(*) FILTER (WHERE has_table_privilege($1, c.oid, 'SELECT')) AS can_select,
       count(*) FILTER (WHERE has_table_privilege($1, c.oid, 'INSERT,UPDATE,DELETE')) AS can_write,
       count(*) FILTER (WHERE has_table_privilege($1, c.oid, 'TRUNCATE')) AS can_truncate,
       count(*) FILTER (WHERE pg_has_role($1, c.relowner, 'USAGE')) AS owns,
       bool_or(has_schema_privilege($1, n.oid, 'USAGE')) AS schema_usage,
       bool_or(has_schema_privilege($1, n.oid, 'CREATE')) AS schema_create
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND n.nspname NOT LIKE 'pg\\_%'
   AND n.nspname NOT IN ('information_schema')
 GROUP BY n.nspname
HAVING count(*) FILTER (WHERE has_table_privilege($1, c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')) > 0
 ORDER BY n.nspname
"""

DEFAULT_ACL_SQL = """
SELECT o.rolname AS role, coalesce(n.nspname, '(all)') AS schema,
       CASE d.defaclobjtype WHEN 'r' THEN 'tables' WHEN 'S' THEN 'sequences' WHEN 'f' THEN 'functions'
            WHEN 'T' THEN 'types' WHEN 'n' THEN 'schemas' ELSE d.defaclobjtype::text END AS objects,
       coalesce(g.rolname, 'PUBLIC') AS grantee, string_agg(a.privilege_type, ',' ORDER BY a.privilege_type) AS privileges
  FROM pg_default_acl d
  JOIN pg_roles o ON o.oid = d.defaclrole
  LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
  CROSS JOIN LATERAL aclexplode(d.defaclacl) a
  LEFT JOIN pg_roles g ON g.oid = a.grantee
 GROUP BY 1, 2, 3, 4
 ORDER BY 1, 2, 3, 4
"""

# Functions in app schemas that PUBLIC may execute (the PG default unless revoked), split by SECURITY DEFINER.
PUBLIC_EXECUTE_SQL = """
SELECT n.nspname, p.prosecdef AS security_definer, count(*) AS functions
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  LEFT JOIN pg_depend dep ON dep.objid = p.oid AND dep.deptype = 'e'
 WHERE n.nspname NOT LIKE 'pg\\_%'
   AND n.nspname NOT IN ('information_schema')
   AND dep.objid IS NULL
   AND EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
 GROUP BY 1, 2
 ORDER BY 1, 2
"""

SECDEF_OWNERS_SQL = """
SELECT n.nspname, o.rolname AS owner, count(*) AS functions
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_roles o ON o.oid = p.proowner
  LEFT JOIN pg_depend dep ON dep.objid = p.oid AND dep.deptype = 'e'
 WHERE p.prosecdef
   AND dep.objid IS NULL
   AND n.nspname NOT LIKE 'pg\\_%'
 GROUP BY 1, 2
 ORDER BY 1, 2
"""

RLS_SQL = """
SELECT n.nspname,
       count(*) AS tables,
       count(*) FILTER (WHERE c.relrowsecurity) AS rls_on,
       count(*) FILTER (WHERE c.relforcerowsecurity) AS rls_forced
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p')
   AND n.nspname NOT LIKE 'pg\\_%'
   AND n.nspname <> 'information_schema'
 GROUP BY 1
 ORDER BY 1
"""

# Credential columns (DM-6.1 comment tag conf:credential): which login roles can SELECT each one.
CREDENTIAL_COLUMNS_SQL = """
SELECT c.oid AS relid, n.nspname, c.relname, att.attname
  FROM pg_attribute att
  JOIN pg_class c ON c.oid = att.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p', 'v', 'm')
   AND att.attnum > 0
   AND NOT att.attisdropped
   AND col_description(c.oid, att.attnum) LIKE '%conf:credential%'
   AND NOT c.relispartition
 ORDER BY 2, 3, 4
"""

COLUMN_SELECT_SQL = "SELECT has_column_privilege($1, $2::oid, $3::text, 'SELECT')"

# Staff app access, aggregate only (no username, e-mail or identity value leaves the database).
ADMIN_USERS_SQL = """
SELECT role::text AS role, is_active, is_owner,
       count(*) AS users,
       count(*) FILTER (WHERE password_hash IS NOT NULL) AS with_password,
       count(*) FILTER (WHERE cognito_sub IS NOT NULL) AS cognito_linked,
       count(*) FILTER (WHERE username LIKE 'e2e%') AS e2e_accounts,
       count(*) FILTER (WHERE last_login_at IS NULL) AS never_logged_in,
       count(*) FILTER (WHERE last_login_at < now() - interval '90 days') AS idle_90d,
       count(*) FILTER (WHERE last_login_at >= now() - interval '30 days') AS active_30d
  FROM shared.admin_users
 GROUP BY 1, 2, 3
 ORDER BY 1, 2, 3
"""

STAFF_APP_GRANT_SQL = """
SELECT g.app, g.role, a.is_active, count(*) AS grants
  FROM shared.staff_app_grant g
  JOIN shared.admin_users a ON a.id = g.admin_user_id
 GROUP BY 1, 2, 3
 ORDER BY 1, 2, 3
"""

STAFF_CRM_GRANT_SQL = """
SELECT g.role, a.is_active, count(*) AS grants
  FROM shared.staff_crm_grant g
  JOIN shared.admin_users a ON a.id = g.admin_user_id
 GROUP BY 1, 2
 ORDER BY 1, 2
"""

STAFF_TENANT_ASSIGNMENT_SQL = """
SELECT kind, count(*) AS assignments, count(DISTINCT admin_user_id) AS staff, count(DISTINCT tenant_id) AS tenants
  FROM shared.staff_tenant_assignment
 GROUP BY 1
 ORDER BY 1
"""

VIEW_AS_SQL = """
SELECT count(*) AS sessions,
       count(*) FILTER (WHERE ended_at IS NULL AND expires_at > now()) AS open_now,
       count(*) FILTER (WHERE started_at >= now() - interval '90 days') AS last_90d
  FROM shared.staff_view_as_session
"""

BOOKING_STAFF_SQL = """
SELECT role, active,
       count(*) AS users,
       count(*) FILTER (WHERE cognito_sub IS NOT NULL) AS cognito_linked,
       count(*) FILTER (WHERE left(cis_user_id, 4) = 'cog:') AS cognito_keyed,
       count(*) FILTER (WHERE last_seen_at IS NULL) AS never_seen,
       count(*) FILTER (WHERE last_seen_at < now() - interval '90 days') AS idle_90d
  FROM booking.staff_users
 GROUP BY 1, 2
 ORDER BY 1, 2
"""

# crm.support_grant has RLS on + FORCE and the master is not its owner nor BYPASSRLS: the counts are what the policies
# let the master see (possibly 0). Read them as a lower bound; the CRM admin page is the full view.
CRM_SUPPORT_GRANT_SQL = """
SELECT status, count(*) AS grants,
       count(*) FILTER (WHERE status = 'active' AND expires_at < now()) AS active_but_past_expiry,
       count(*) FILTER (WHERE show_identity) AS show_identity
  FROM crm.support_grant
 GROUP BY 1
 ORDER BY 1
"""

# Runtime role -> schemas it is meant to reach (data standards DM-8, schema-ownership.md). Anything else is flagged.
EXPECTED_SCHEMAS = {
    "cis_app": None,  # CIS schemas: everything except the other apps' schemas below
    "aa_app_user": None,
    "booking": {"booking"},
    "tripplanner": {"tripplanner"},
    "crm_app": {"crm"},
}
OTHER_APP_SCHEMAS = {"booking", "tripplanner", "crm"}
OWN_APP_SCHEMA = {"booking": "booking", "tripplanner": "tripplanner", "crm_app": "crm"}


def _out(kind, payload):
    print("SCRIPT " + kind + " " + json.dumps(payload, default=str, sort_keys=True))


async def _section(conn, kind, sql, *args):
    rows = await conn.fetch(sql, *args)
    for r in rows:
        _out(kind, dict(r))
    _out(kind + "_count", {"rows": len(rows)})
    return rows


async def _staff_section(conn, kind, sql):
    # A missing table (renamed by a later migration) is reported, not fatal: the catalog part matters most.
    exists = await conn.fetchval("SELECT to_regclass($1) IS NOT NULL", kind.split(":", 1)[1])
    if not exists:
        _out("staff_missing", {"table": kind.split(":", 1)[1]})
        return
    await _section(conn, "staff " + kind.split(":", 1)[1], sql)


async def main(conn):
    version = await conn.fetchval("SHOW server_version")
    who = await conn.fetchval("SELECT current_user")
    _out("meta", {"server_version": version, "current_user": who, "at": str(await conn.fetchval("SELECT now()"))})

    await _section(conn, "role", ROLES_SQL)
    major = int(str(version).split(".")[0])
    await _section(conn, "member", MEMBERSHIP_SQL if major >= 16 else MEMBERSHIP_SQL_PG15)
    await _section(conn, "db_acl", DATABASE_ACL_SQL)
    await _section(conn, "schema_owner", APP_SCHEMAS_SQL)
    await _section(conn, "schema_acl", SCHEMA_ACL_SQL)
    await _section(conn, "table_grant", TABLE_GRANTS_SQL)
    await _section(conn, "column_grant", COLUMN_GRANTS_SQL)
    await _section(conn, "default_acl", DEFAULT_ACL_SQL)
    await _section(conn, "public_execute", PUBLIC_EXECUTE_SQL)
    await _section(conn, "secdef_owner", SECDEF_OWNERS_SQL)
    await _section(conn, "rls", RLS_SQL)

    # Effective reach per login role, with a cross-app flag.
    logins = [r["rolname"] for r in await conn.fetch(LOGIN_ROLES_SQL)]
    cross_app = []
    for role in logins:
        rows = await conn.fetch(EFFECTIVE_REACH_SQL, role)
        for r in rows:
            d = dict(r)
            d["role"] = role
            _out("reach", d)
            schema = d["nspname"]
            if role in OWN_APP_SCHEMA and schema != OWN_APP_SCHEMA[role] and schema not in ("public",):
                cross_app.append({"role": role, "schema": schema, "can_select": d["can_select"], "can_write": d["can_write"]})
            elif role in ("cis_app", "aa_app_user") and schema in OTHER_APP_SCHEMAS:
                cross_app.append({"role": role, "schema": schema, "can_select": d["can_select"], "can_write": d["can_write"]})
    for c in cross_app:
        _out("cross_app", c)
    _out("cross_app_count", {"rows": len(cross_app), "login_roles": logins})

    # Credential columns: which login roles can read each.
    cred_cols = await conn.fetch(CREDENTIAL_COLUMNS_SQL)
    for col in cred_cols:
        readers = []
        for role in logins:
            if await conn.fetchval(COLUMN_SELECT_SQL, role, col["relid"], col["attname"]):
                readers.append(role)
        _out("credential_column", {"schema": col["nspname"], "table": col["relname"], "column": col["attname"],
                                   "login_roles_can_select": readers})
    _out("credential_column_count", {"rows": len(cred_cols)})

    # Staff sign-in rows that grant app access (aggregate counts only).
    await _staff_section(conn, "admin_users:shared.admin_users", ADMIN_USERS_SQL)
    await _staff_section(conn, "staff_app_grant:shared.staff_app_grant", STAFF_APP_GRANT_SQL)
    await _staff_section(conn, "staff_crm_grant:shared.staff_crm_grant", STAFF_CRM_GRANT_SQL)
    await _staff_section(conn, "staff_tenant_assignment:shared.staff_tenant_assignment", STAFF_TENANT_ASSIGNMENT_SQL)
    await _staff_section(conn, "staff_view_as_session:shared.staff_view_as_session", VIEW_AS_SQL)
    await _staff_section(conn, "booking_staff:booking.staff_users", BOOKING_STAFF_SQL)
    await _staff_section(conn, "support_grant:crm.support_grant", CRM_SUPPORT_GRANT_SQL)

    _out("done", {"login_roles": len(logins), "credential_columns": len(cred_cols), "cross_app": len(cross_app)})
    return 0

