#!/usr/bin/env python3
"""Staff web secrets tool (AA-911, root ADR 0019 d23). Run by an AWS admin with MFA from a workstation. Not run by CI,
not deployed. Standard library + boto3 only. DRY RUN by default: nothing is written without --apply.

Fills the two secret shells of the staff frontends on ECS (modules/environment/staff_web.tf) from the WORKFORCE app
clients, so the client secrets never pass through a terminal, a file or Terraform state reads:

  aa-cis/<env>/admin-web    {cis_admin_client_secret, breakglass_client_secret}
                            clients aa-workforce-<env>-cis-admin and aa-workforce-<env>-breakglass
  booking/<env>/admin-web   {booking_staff_client_secret}
                            client aa-workforce-<env>-booking-staff

Each client secret is read with DescribeUserPoolClient and kept in memory. Values are never printed: the output is one
JSON line per secret with its name, the keys that would change / changed and the version id. Other keys already in a
secret are kept. A re-run with nothing to change writes nothing.

Run it AFTER the Terraform apply that creates the shells and BEFORE the first task starts (a task whose secret lacks a
mapped key fails to start): apply -> this tool --apply -> the first deploy of each app -> scale the service to 1.
After a client secret rotation, run it again and force a new deployment of the staff web service.

Account guard: refuses to run unless the credentials are for --expect-account. The pool and clients are found by NAME
(aa-workforce-<env>, aa-workforce-<env>-<client>), never by a pasted id.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

DEFAULT_PROFILE = "aa365-admin"
DEFAULT_REGION = "us-west-1"
DEFAULT_ACCOUNT = "005097885195"
DEFAULT_ENV = "dev"

# secret name template -> {json key: WORKFORCE client key}
SECRETS: dict[str, dict[str, str]] = {
    "aa-cis/{env}/admin-web": {
        "cis_admin_client_secret": "cis-admin",
        "breakglass_client_secret": "breakglass",
    },
    "booking/{env}/admin-web": {
        "booking_staff_client_secret": "booking-staff",
    },
}


class ToolError(Exception):
    """A refusal or an AWS failure, printed as one line (no traceback)."""


def out(line: dict[str, Any]) -> None:
    print(json.dumps(line, ensure_ascii=False), flush=True)


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


def client_secret(idp: Any, pool_id: str, client_name: str) -> str:
    client_id = find_client_id(idp, pool_id, client_name)
    value = idp.describe_user_pool_client(UserPoolId=pool_id, ClientId=client_id)["UserPoolClient"].get("ClientSecret")
    if not value:
        raise ToolError(f"{client_name} has no client secret (it must be a confidential client)")
    return value


def _secret_exists(sm: Any, name: str) -> bool:
    try:
        sm.describe_secret(SecretId=name)
        return True
    except sm.exceptions.ResourceNotFoundException:
        return False


def _current_secret(sm: Any, name: str) -> dict[str, Any]:
    """The JSON object stored in the secret, {} when it has no value yet (a fresh shell) or is not a JSON object."""
    try:
        raw = sm.get_secret_value(SecretId=name)["SecretString"]
    except sm.exceptions.ResourceNotFoundException:
        return {}
    try:
        data = json.loads(raw)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def write_secret(
    idp: Any, sm: Any, pool_id: str, pool_name: str, name: str, keys: dict[str, str], *, apply: bool
) -> dict[str, Any]:
    if not _secret_exists(sm, name):
        raise ToolError(f"{name} does not exist: apply AA-CIS-Infra modules/environment/staff_web.tf first (the shell)")
    wanted = {key: client_secret(idp, pool_id, f"{pool_name}-{client}") for key, client in keys.items()}
    current = _current_secret(sm, name)
    changed = sorted(k for k, v in wanted.items() if current.get(k) != v)
    result: dict[str, Any] = {"secret": name, "clients": sorted(keys.values()), "changed": changed}
    if not changed:
        result["action"] = "unchanged"
        return result
    if not apply:
        result["action"] = "would_write"
        return result
    resp = sm.put_secret_value(SecretId=name, SecretString=json.dumps({**current, **wanted}))
    result["action"] = "written"
    result["version_id"] = resp.get("VersionId")
    return result


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="AA-911 staff web secrets (WORKFORCE client secrets). DRY RUN unless --apply.")
    p.add_argument("--profile", default=DEFAULT_PROFILE, help="AWS profile ('' = default chain/env)")
    p.add_argument("--region", default=DEFAULT_REGION)
    p.add_argument("--expect-account", default=DEFAULT_ACCOUNT, help="refuse to run in any other account")
    p.add_argument("--env", default=DEFAULT_ENV)
    p.add_argument("--only", choices=("cis", "booking"), help="write one app's secret only")
    p.add_argument("--apply", action="store_true")
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
        pool_name = f"aa-workforce-{args.env}"
        pool_id = find_pool_id(idp, pool_name)
        for template, keys in SECRETS.items():
            if args.only and not template.startswith("aa-cis/" if args.only == "cis" else "booking/"):
                continue
            out(write_secret(idp, sm, pool_id, pool_name, template.format(env=args.env), keys, apply=args.apply))
        return 0
    except ToolError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 — one line, no traceback (a traceback could echo a request body)
        print(f"error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
