#!/usr/bin/env python3
"""AA-Partner (CRM) Dev identity tool (AA-935, design v3 card CRM-07; AA-939 partner pool). Run by an AWS admin with MFA
from a workstation. Not run by CI, not deployed. Standard library + boto3 only. DRY RUN by default: nothing is written
without --apply.

--pool external (default, the AA-935 behaviour) or --pool partner (AA-939, root ADR 0006b: the partner pool with MFA
required). On the partner pool an e2e user cannot sign in by e-mail code, so e2e-users enrols each new user the way a
person would: AdminCreateUser (SUPPRESS) with a random temporary password, then the first sign-in through the
partner-web client (USER_AUTH + PASSWORD, NEW_PASSWORD_REQUIRED with a random permanent password, MFA_SETUP with
AssociateSoftwareToken / VerifySoftwareToken), and stores {email, sub, agency, role, pool, password, totp_secret} in
the user's secret (required: --write-secrets; the values exist nowhere else). These admin calls raise the partner
pool's "admin bypass" alert (identity_partner.tf) by design: expect one mail per run.

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

  invitee-reset [--apply]   (AA-939, --pool partner)
      Deletes the partner-pool account of each "invitee" entry of crm_e2e_users.json (AdminDeleteUser), so the
      one-off timed E2E "invite -> active" (AA-Partner e2e/tests/invite.spec.ts) starts from no account.

Account guard: refuses to run unless the credentials are for --expect-account. Pools and clients are found by NAME
(aa-<pool>-<env>; clients aa-external-<env>-cis-portal / aa-partner-<env>-partner-web), never by a pasted id.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import secrets
import string
import struct
import sys
import time
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
POOLS = ("external", "partner")
WEB_CLIENT = {"external": "cis-portal", "partner": "partner-web"}
PASSWORD_SYMBOLS = "!#$%&*+-=?@^_"


class ToolError(Exception):
    """A refusal or an AWS failure, printed as one line (no traceback)."""


@dataclass(frozen=True)
class E2eUser:
    agency: str
    role: str
    # AA-939: an address only the timed invitation E2E uses (a mailbox recipient, never created by e2e-users).
    invitee: bool = False

    def email(self, zone: str) -> str:
        return f"e2e-test-crm-{self.agency}-{self.role}@e2e-mail.{zone}"

    def secret_name(self, env: str) -> str:
        return f"crm/{env}/e2e-test-crm/{self.agency}-{self.role}"


def load_users(path: Path = USERS_FILE) -> list[E2eUser]:
    data = json.loads(path.read_text(encoding="utf-8"))
    users = [E2eUser(u["agency"], u["role"], bool(u.get("invitee", False))) for u in data["users"]]
    for u in users:
        if u.role not in ROLES or not u.agency.replace("-", "").isalnum() or u.agency != u.agency.lower():
            raise ToolError(f"bad entry in {path.name}: {u}")
    if len({(u.agency, u.role) for u in users}) != len(users):
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


# ── partner pool enrolment (AA-939) ──────────────────────────────────────────
def random_password() -> str:
    """>= 14 characters with all four classes (the partner pool's policy); 28 here."""
    classes = (string.ascii_lowercase, string.ascii_uppercase, string.digits, PASSWORD_SYMBOLS)
    alphabet = "".join(classes)
    while True:
        value = "".join(secrets.choice(alphabet) for _ in range(28))
        if all(any(c in cls for c in value) for cls in classes):
            return value


def totp(secret_b32: str, at: float | None = None, step: int = 30) -> str:
    """RFC 6238 (SHA-1, 6 digits) for the authenticator enrolment."""
    key = base64.b32decode(secret_b32.upper() + "=" * (-len(secret_b32) % 8))
    counter = struct.pack(">Q", int((time.time() if at is None else at) // step))
    mac = hmac.new(key, counter, hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    return f"{(struct.unpack('>I', mac[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000:06d}"


def secret_hash(username: str, client_id: str, client_secret: str) -> str:
    digest = hmac.new(client_secret.encode(), (username + client_id).encode(), hashlib.sha256).digest()
    return base64.b64encode(digest).decode()


@dataclass(frozen=True)
class WebClient:
    client_id: str
    client_secret: str


def web_client(idp: Any, pool_id: str, client_name: str) -> WebClient:
    client_id = find_client_id(idp, pool_id, client_name)
    client_secret = idp.describe_user_pool_client(UserPoolId=pool_id, ClientId=client_id)["UserPoolClient"].get(
        "ClientSecret"
    )
    if not client_secret:
        raise ToolError(f"{client_name} has no client secret (it must be a confidential client)")
    return WebClient(client_id, client_secret)


def enrol_partner_user(idp: Any, client: WebClient, email: str, temporary: str) -> tuple[str, str]:
    """First sign-in of a new partner-pool user: own password, then the authenticator. Returns (password, totp secret)."""
    sh = secret_hash(email, client.client_id, client.client_secret)
    resp = idp.initiate_auth(
        ClientId=client.client_id,
        AuthFlow="USER_AUTH",
        AuthParameters={"USERNAME": email, "PREFERRED_CHALLENGE": "PASSWORD", "PASSWORD": temporary, "SECRET_HASH": sh},
    )
    if resp.get("ChallengeName") == "SELECT_CHALLENGE":
        resp = idp.respond_to_auth_challenge(
            ClientId=client.client_id, ChallengeName="SELECT_CHALLENGE", Session=resp["Session"],
            ChallengeResponses={"USERNAME": email, "ANSWER": "PASSWORD", "PASSWORD": temporary, "SECRET_HASH": sh},
        )
    if resp.get("ChallengeName") != "NEW_PASSWORD_REQUIRED":
        raise ToolError(f"{email}: expected NEW_PASSWORD_REQUIRED, got {resp.get('ChallengeName')}")
    password = random_password()
    resp = idp.respond_to_auth_challenge(
        ClientId=client.client_id, ChallengeName="NEW_PASSWORD_REQUIRED", Session=resp["Session"],
        ChallengeResponses={"USERNAME": email, "NEW_PASSWORD": password, "SECRET_HASH": sh},
    )
    if resp.get("ChallengeName") != "MFA_SETUP":
        raise ToolError(f"{email}: expected MFA_SETUP (the partner pool requires MFA), got {resp.get('ChallengeName')}")
    assoc = idp.associate_software_token(Session=resp["Session"])
    totp_secret = assoc["SecretCode"]
    verified = idp.verify_software_token(Session=assoc["Session"], UserCode=totp(totp_secret), FriendlyDeviceName="e2e")
    if verified.get("Status") != "SUCCESS":
        raise ToolError(f"{email}: the authenticator code was not accepted")
    done = idp.respond_to_auth_challenge(
        ClientId=client.client_id, ChallengeName="MFA_SETUP", Session=verified["Session"],
        ChallengeResponses={"USERNAME": email, "SECRET_HASH": sh},
    )
    if "AuthenticationResult" not in done:
        raise ToolError(f"{email}: enrolment did not finish ({done.get('ChallengeName')})")
    return password, totp_secret


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
    pool: str = "external",
    client: WebClient | None = None,
) -> list[dict[str, Any]]:
    if pool == "partner" and apply and not write_secrets:
        raise ToolError("--pool partner --apply needs --write-secrets: the password and authenticator secret exist nowhere else")
    rows: list[dict[str, Any]] = []
    for u in users:
        if u.invitee:
            continue  # the timed invitation E2E creates it through the CRM (invitee-reset deletes it)
        email = u.email(zone)
        found = find_user(idp, pool_id, email)
        action = "exists"
        credentials: dict[str, str] = {}
        if found is None:
            if not apply:
                rows.append({"agency": u.agency, "role": u.role, "email": email, "action": "would_create", "sub": None})
                continue
            kwargs: dict[str, Any] = {}
            temporary = random_password() if pool == "partner" else None
            if temporary:
                kwargs["TemporaryPassword"] = temporary  # never mailed (SUPPRESS); used once just below
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
                **kwargs,
            )
            found = created["User"]
            action = "created"
            if temporary:
                if client is None:
                    raise ToolError("the partner-web client is needed to enrol a partner-pool user")
                password, totp_secret = enrol_partner_user(idp, client, email, temporary)
                credentials = {"password": password, "totp_secret": totp_secret}
                action = "created_enrolled"
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
            if apply and pool == "partner" and not credentials:
                # An existing partner-pool user: its stored credentials stay as they are.
                row["secret"] = {"name": u.secret_name(env), "action": "kept"}
            elif apply:
                description = (
                    f"AA-939: e2e test user of the synthetic CRM agency {u.agency} ({u.role}) on the partner pool: "
                    "password + authenticator secret (MFA required)."
                    if pool == "partner"
                    else f"AA-935: e2e test user of the synthetic CRM agency {u.agency} ({u.role}). No password: e-mail code sign-in."
                )
                row["secret"] = put_json_secret(
                    sm,
                    u.secret_name(env),
                    {"email": email, "sub": sub, "agency": u.agency, "role": u.role, "pool": pool, **credentials},
                    description=description,
                )
            else:
                row["secret"] = {"name": u.secret_name(env), "action": "would_write"}
        rows.append(row)
    return rows


def invitee_reset(idp: Any, pool_id: str, users: Iterable[E2eUser], *, zone: str, apply: bool) -> list[dict[str, Any]]:
    rows = []
    for u in users:
        if not u.invitee:
            continue
        email = u.email(zone)
        found = find_user(idp, pool_id, email)
        if found is None:
            rows.append({"email": email, "action": "absent"})
        elif not apply:
            rows.append({"email": email, "action": "would_delete"})
        else:
            idp.admin_delete_user(UserPoolId=pool_id, Username=_attr(found, "sub") or email)
            rows.append({"email": email, "action": "deleted"})
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
    p.add_argument("--pool", choices=POOLS, default="external", help="AA-939: partner = the partner pool (MFA required)")
    sub = p.add_subparsers(dest="command", required=True)
    e = sub.add_parser("e2e-users", help="create the e2e users of the synthetic CRM agencies")
    e.add_argument("--apply", action="store_true")
    e.add_argument("--write-secrets", action="store_true")
    w = sub.add_parser("web-secret", help="write crm/<env>/web for the CRM web task")
    w.add_argument("--apply", action="store_true")
    w.add_argument("--rotate-session", action="store_true")
    r = sub.add_parser("invitee-reset", help="delete the invitee account(s) before the timed invitation E2E (--pool partner)")
    r.add_argument("--apply", action="store_true")
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
        pool_name = f"aa-{args.pool}-{args.env}"
        pool_id = find_pool_id(idp, pool_name)
        client_name = f"{pool_name}-{WEB_CLIENT[args.pool]}"
        if args.command == "invitee-reset":
            if args.pool != "partner":
                raise ToolError("invitee-reset works on the partner pool only (--pool partner)")
            for row in invitee_reset(idp, pool_id, load_users(), zone=args.zone, apply=args.apply):
                out(row)
            return 0
        if args.command == "e2e-users":
            client = web_client(idp, pool_id, client_name) if args.pool == "partner" and args.apply else None
            rows = e2e_users(
                idp,
                sm,
                pool_id,
                load_users(),
                env=args.env,
                zone=args.zone,
                apply=args.apply,
                write_secrets=args.write_secrets,
                pool=args.pool,
                client=client,
            )
            for row in rows:
                out(row)
            out({"summary": "apply" if args.apply else "dry_run", "pool": pool_name, "users": len(rows),
                 "created": sum(r["action"] in ("created", "created_enrolled") for r in rows),
                 "seeder": seeder_command(rows)})
        else:
            out(web_secret(idp, sm, pool_id, client_name, env=args.env, apply=args.apply,
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
