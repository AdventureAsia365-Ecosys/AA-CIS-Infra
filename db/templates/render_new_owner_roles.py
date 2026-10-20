"""Render the role bootstrap of a new owner (ADR 0008 playbook step 3, AA-826) into db/migrations/roles/.

The output is a reviewed roles/ file like rl-001 / rl-002: the owner role (NOLOGIN), the runtime role (LOGIN, no
password, CONNECTION LIMIT) and the empty anchor schema owned by the owner role, with guard blocks. The values must
match the owner's db/owners.yaml entry (owner_role, runtime_roles, anchor_schema, key_prefix) and the owner role must
be added to migrator_member_of in the same PR; db/tests/test_owners_registry.py and db/tests/test_roles_files.py
check that.

Usage:
  python3 db/templates/render_new_owner_roles.py --number 003 --owner crm --owner-role crm_owner --runtime-role crm_app --schema crm --key-prefix cr- --conn-limit 15 --issue AA-123 > db/migrations/roles/003_crm_roles.sql
Standard library only.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Optional

TEMPLATE = Path(__file__).resolve().parent / "new_owner_roles.sql.tmpl"
NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")
RESERVED = {"aa_cis_admin", "db_migrator", "aa_app_user", "catalog_owner", "cis_owner", "cis_app", "bk_owner",
            "tp_owner", "booking", "tripplanner", "public", "postgres", "rds_superuser"}
# Schemas of the existing owners and the platform (db/owners.yaml); a new owner gets a schema of its own.
RESERVED_SCHEMAS = {"public", "shared", "catalog", "geo", "booking", "tripplanner", "information_schema"}


def render(number: str, owner: str, owner_role: str, runtime_role: str, schema: str, key_prefix: str,
           conn_limit: int, issue: str) -> str:
    if not re.fullmatch(r"[0-9]{3}", number):
        raise ValueError("number must be three digits (rl-NNN)")
    for label, v in (("owner", owner), ("owner role", owner_role), ("runtime role", runtime_role),
                     ("schema", schema)):
        if not NAME_RE.match(v) or len(v) > 63:
            raise ValueError(f"{label} {v!r} must be a lower-case identifier")
    if {owner_role, runtime_role} & RESERVED or owner_role == runtime_role:
        raise ValueError("owner role and runtime role must be new, distinct roles")
    if schema in RESERVED_SCHEMAS or schema.startswith(("acp_", "pg_")) or schema.endswith("_aa_internal"):
        raise ValueError(f"schema {schema!r} belongs to an existing owner or the platform")
    if not re.fullmatch(r"[a-z]+-", key_prefix):
        raise ValueError("key prefix must look like xx- (owners.yaml key_prefix)")
    if not 1 <= conn_limit <= 100:
        raise ValueError("connection limit must be 1..100 (data standards C2.3a budget)")
    if not re.fullmatch(r"AA-[0-9]+", issue):
        raise ValueError("issue must look like AA-123")
    sql = TEMPLATE.read_text(encoding="utf-8")
    for key, value in {"NNN": number, "OWNER_ROLE": owner_role, "RUNTIME_ROLE": runtime_role, "OWNER": owner,
                       "SCHEMA": schema, "KEY_PREFIX": key_prefix, "CONN_LIMIT": str(conn_limit),
                       "ISSUE": issue}.items():
        sql = sql.replace("{{" + key + "}}", value)
    left = re.findall(r"\{\{[A-Z_]+\}\}", sql)
    if left:
        raise ValueError(f"unrendered placeholders: {sorted(set(left))}")
    return sql


def main(argv: Optional[list] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--number", required=True)
    p.add_argument("--owner", required=True, help="owners.yaml owner name (= migration dir)")
    p.add_argument("--owner-role", required=True)
    p.add_argument("--runtime-role", required=True)
    p.add_argument("--schema", required=True, help="owners.yaml anchor_schema")
    p.add_argument("--key-prefix", required=True)
    p.add_argument("--conn-limit", required=True, type=int)
    p.add_argument("--issue", required=True)
    a = p.parse_args(argv)
    try:
        sys.stdout.write(render(a.number, a.owner, a.owner_role, a.runtime_role, a.schema, a.key_prefix,
                                a.conn_limit, a.issue))
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
