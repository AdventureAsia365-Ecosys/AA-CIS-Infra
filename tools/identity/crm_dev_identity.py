#!/usr/bin/env python3
"""AA-Partner (CRM) Dev identity tool (AA-935, design v3 card CRM-07). Run by an AWS admin with MFA from a workstation.
Not run by CI, not deployed. Standard library + boto3 only. DRY RUN by default: nothing is written without --apply.

Subcommands
  e2e-users  [--apply] [--write-secrets]
      The e2e test users of the synthetic CRM agencies (tools/identity/crm_e2e_users.json), in the EXTERNAL pool
      (the CRM web signs in with the `cis-portal` client on Dev until AA-939). Each user is
      e2e-test-crm-<agency>-<role>@e2e-mail.<zone> (the pool's username is the e-mail; the SES receipt rule of
      e2e_mailbox.tf takes these addresses), created with AdminCreateUser MessageAction=SUPPRESS and
      email_verified=true, no password ever set: sign-in is the e-mail code, read from the e2e mailbox bucket.
      A re-run creates only the missing users. Prints one JSON line per user with its `sub` and the seeder
      argument `--member <agency>:<role>:<sub>`, then the full seeder command (AA-Partner `python -m app.seed`).
      --write-secrets stores {email, sub, agency, role, pool} (no password exists) in
      crm/<env>/e2e-test-crm/<agency>-<role>, so CI and agents look the subject up by name.
  web-secret [--apply] [--rotate-session]
      Writes the CRM web secret crm/<env>/web (crm_web.tf secret shell): {cognito_client_secret, session_secret}.
      The client secret is read from the `cis-portal` client (DescribeUserPoolClient) and kept in memory; the
      session secret is random (secrets.token_urlsafe) and kept on a re-run unless --rotate-session (which signs
      every CRM web user out). Values are never printed: the output is the secret name, the version id and which
      keys changed.

Account guard: refuses to run unless the credentials are for --expect-account. Pools and clients are found by NAME
(aa-external-<env>, aa-external-<env>-cis-portal), never by a pasted id.
"""

from __future__ import annotations

import argparse
import json
import secrets
import sys
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_PROFILE = "aa365-admin"
DEFAULT_REGION = "us-west-1"
DEFAULT_ACCOUNT = "005097885195"
DEFAULT_ENV = "dev"
DEFAULT_ZONE = "lumiguides.it.com"
USERS_FILE = Path(__file__).resolve().parent / "crm_e2e_users.json"
ROLES = frozenset({"owner", "agent", "assistant"})
SESSION_SECRET_BYTES = 48


class ToolError(Exception):
    """A refusal or an AWS failure, printed as one line (no traceback)."""


@dataclass(frozen=True)
class E2eUser:
    agency: str
    role: str

    def email(self, zone: str) -> str:
        return f"e2e-test-crm-{self.agency}-{self.role}@e2e-mail.{zone}"

    def secret_name(self, env: str) -> str:
        return f"crm/{env}/e2e-test-crm/{self.agency}-{self.role}"


def load_users(path: Path = USERS_FILE) -> list[E2eUser]:
    data = json.loads(path.read_text(encoding="utf-8"))
    users = [E2eUser(u["agency"], u["role"]) for u in data["users"]]
    for u in users:
        if u.role not in ROLES or not u.agency.replace("-", "").isalnum() or u.agency != u.agency.lower():
            raise ToolError(f"bad entry in {path.name}: {u}")
    if len(set(users)) != len(users):
        raise ToolError(f"duplicate entry in {path.name}")
    return users


def out(line: dict[str, Any]) -> None:
    print(json.dumps(line, ensure_ascii=False), flush=True)


# ── AWS lookups by name ──────────────────────────────────────────────────────
def find_pool_id(idp: Any, name: str) -> str:
    token = None
    while True:
        kwargs: dict[str, Any] = {"MaxResults": 60}
        if token:
            kwargs["NextToken"] = token
        page = idp.list_user_pools(**kwargs)
        for pool in page.get("UserPools", []):
            if pool.get("Name") == name:
                return pool["Id"]
        token = page.get("NextToken")
        if not token:
            raise ToolError(f"user pool {name} not found")


def find_client_id(idp: Any, pool_id: str, name: str) -> str:
    token = None
    while True:
        kwargs: dict[str, Any] = {"UserPoolId": pool_id, "MaxResults": 60}
        if token:
            kwargs["NextToken"] = token
        page = idp.list_user_pool_clients(**kwargs)
        for client in page.get("UserPoolClients", []):
            if client.get("ClientName") == name:
                return client["ClientId"]
        token = page.get("NextToken")
        if not token:
            raise ToolError(f"app client {name} not found")


def _attr(user: dict[str, Any], name: str) -> str | None:
    for a in user.get("Attributes") or user.get("UserAttributes") or []:
        if a.get("Name") == name:
            return a.get("Value")
    return None


def find_user(idp: Any, pool_id: str, email: str) -> dict[str, Any] | None:
    page = idp.list_users(UserPoolId=pool_id, Filter=f'email = "{email}"', Limit=2)
    users = page.get("Users", [])
    if len(users) > 1:
        raise ToolError(f"{email}: more than one user has this e-mail")
    return users[0] if users else None


# ── e2e-users ────────────────────────────────────────────────────────────────
def e2e_users(
    idp: Any,
    sm: Any,
    pool_id: str,
    users: Iterable[E2eUser],
    *,
    env: str,
    zone: str,
    apply: bool,
    write_secrets: bool,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for u in users:
        email = u.email(zone)
        found = find_user(idp, pool_id, email)
        action = "exists"
        if found is None:
            if not apply:
                rows.append({"agency": u.agency, "role": u.role, "email": email, "action": "would_create", "sub": None})
                continue
            created = idp.admin_create_user(
                UserPoolId=pool_id,
                Username=email,
                UserAttributes=[
                    {"Name": "email", "Value": email},
                    {"Name": "email_verified", "Value": "true"},
                    {"Name": "name", "Value": f"E2E CRM {u.agency} {u.role}"},
                ],
                # Never mail a temporary password (identity.tf: every AdminCreateUser passes SUPPRESS).
                MessageAction="SUPPRESS",
            )
            found = created["User"]
            action = "created"
        sub = _attr(found, "sub")
        if not sub:
            raise ToolError(f"{email}: no sub attribute")
        row = {
            "agency": u.agency,
            "role": u.role,
            "email": email,
            "action": action,
            "sub": sub,
            "member": f"{u.agency}:{u.role}:{sub}",
        }
        if write_secrets:
            if apply:
                row["secret"] = put_json_secret(
                    sm,
                    u.secret_name(env),
                    {"email": email, "sub": sub, "agency": u.agency, "role": u.role, "pool": "external"},
                    description=f"AA-935: e2e test user of the synthetic CRM agency {u.agency} ({u.role}). No password: e-mail code sign-in.",
                )
            else:
                row["secret"] = {"name": u.secret_name(env), "action": "would_write"}
        rows.append(row)
    return rows


def seeder_command(rows: list[dict[str, Any]]) -> str:
    members = " ".join(f"--member {r['member']}" for r in rows if r.get("member"))
    return f"python -m app.seed --apply {members}".strip()


# ── secrets ──────────────────────────────────────────────────────────────────
def _secret_exists(sm: Any, name: str) -> bool:
    try:
        sm.describe_secret(SecretId=name)
        return True
    except sm.exceptions.ResourceNotFoundException:
        return False


def put_json_secret(sm: Any, name: str, value: dict[str, Any], *, description: str) -> dict[str, Any]:
    body = json.dumps(value, separators=(",", ":"))
    if _secret_exists(sm, name):
        resp = sm.put_secret_value(SecretId=name, SecretString=body)
        return {"name": name, "action": "updated", "version_id": resp.get("VersionId")}
    resp = sm.create_secret(Name=name, Description=description, SecretString=body, Tags=[{"Key": "App", "Value": "crm"}])
    return {"name": name, "action": "created", "version_id": resp.get("VersionId")}


def _current_secret(sm: Any, name: str) -> dict[str, Any] | None:
    try:
        raw = sm.get_secret_value(SecretId=name)["SecretString"]
    except sm.exceptions.ResourceNotFoundException:
        return None
    try:
        data = json.loads(raw)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def web_secret(
    idp: Any, sm: Any, pool_id: str, client_name: str, *, env: str, apply: bool, rotate_session: bool
) -> dict[str, Any]:
    name = f"crm/{env}/web"
    if not _secret_exists(sm, name):
        raise ToolError(f"{name} does not exist: apply AA-CIS-Infra crm_web.tf first (the secret shell)")
    client_id = find_client_id(idp, pool_id, client_name)
    client_secret = idp.describe_user_pool_client(UserPoolId=pool_id, ClientId=client_id)["UserPoolClient"].get(
        "ClientSecret"
    )
    if not client_secret:
        raise ToolError(f"{client_name} has no client secret (it must be a confidential client)")
    current = _current_secret(sm, name) or {}
    session = current.get("session_secret")
    changed = []
    if rotate_session or not isinstance(session, str) or len(session) < 32:
        session = secrets.token_urlsafe(SESSION_SECRET_BYTES)
        changed.append("session_secret")
    if current.get("cognito_client_secret") != client_secret:
        changed.append("cognito_client_secret")
    result: dict[str, Any] = {"secret": name, "client": client_name, "changed": changed}
    if not changed:
        result["action"] = "unchanged"
        return result
    if not apply:
        result["action"] = "would_write"
        return result
    resp = sm.put_secret_value(
        SecretId=name, SecretString=json.dumps({"cognito_client_secret": client_secret, "session_secret": session})
    )
    result["action"] = "written"
    result["version_id"] = resp.get("VersionId")
    return result


# ── CLI ──────────────────────────────────────────────────────────────────────
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="AA-Partner Dev identity tool (AA-935). DRY RUN unless --apply.")
    p.add_argument("--profile", default=DEFAULT_PROFILE, help="AWS profile ('' = default chain/env)")
    p.add_argument("--region", default=DEFAULT_REGION)
    p.add_argument("--expect-account", default=DEFAULT_ACCOUNT, help="refuse to run in any other account")
    p.add_argument("--env", default=DEFAULT_ENV)
    p.add_argument("--zone", default=DEFAULT_ZONE)
    sub = p.add_subparsers(dest="command", required=True)
    e = sub.add_parser("e2e-users", help="create the e2e users of the synthetic CRM agencies")
    e.add_argument("--apply", action="store_true")
    e.add_argument("--write-secrets", action="store_true")
    w = sub.add_parser("web-secret", help="write crm/<env>/web for the CRM web task")
    w.add_argument("--apply", action="store_true")
    w.add_argument("--rotate-session", action="store_true")
    return p


def main(argv: list[str] | None = None, clients: tuple[Any, Any, Any] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if clients is None:
            import boto3  # noqa: PLC0415 — only when talking to AWS

            session = boto3.Session(profile_name=args.profile or None, region_name=args.region)
            sts, idp, sm = session.client("sts"), session.client("cognito-idp"), session.client("secretsmanager")
        else:
            sts, idp, sm = clients
        account = sts.get_caller_identity()["Account"]
        if args.expect_account and account != args.expect_account:
            raise ToolError(f"refused: credentials are for account {account}, expected {args.expect_account}")
        pool_name = f"aa-external-{args.env}"
        pool_id = find_pool_id(idp, pool_name)
        if args.command == "e2e-users":
            rows = e2e_users(
                idp,
                sm,
                pool_id,
                load_users(),
                env=args.env,
                zone=args.zone,
                apply=args.apply,
                write_secrets=args.write_secrets,
            )
            for row in rows:
                out(row)
            out({"summary": "apply" if args.apply else "dry_run", "pool": pool_name, "users": len(rows),
                 "created": sum(r["action"] == "created" for r in rows),
                 "seeder": seeder_command(rows)})
        else:
            out(web_secret(idp, sm, pool_id, f"{pool_name}-cis-portal", env=args.env, apply=args.apply,
                           rotate_session=args.rotate_session))
        return 0
    except ToolError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 — one line, no traceback (a traceback could echo a request body)
        print(f"error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
