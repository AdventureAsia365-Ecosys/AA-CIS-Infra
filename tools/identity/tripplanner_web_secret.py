#!/usr/bin/env python3
"""TripPlanner web secret tool (AA-1038 R5 hosting, root ADR 0019 d23). Run by an AWS admin with MFA from a workstation.
Not run by CI, not deployed. Standard library + boto3 only. DRY RUN by default: nothing is written without --apply.

Fills the secret shell of the TripPlanner frontend on ECS (modules/environment/tripplanner_web.tf), so no value passes
through a terminal, a file or a Terraform state read:

  tripplanner/<env>/web   {session_secret, catalog_revalidate_secret, sentry_dsn}

  session_secret             seals the traveller session cookies (TP_SESSION_SECRET). Kept when the secret already
                             holds one of at least 32 characters; otherwise a new random one (48 bytes, URL-safe).
                             The Vercel copy cannot be read back (a "sensitive" Vercel env), so the ECS host starts
                             with its own key: a traveller signed in on Vercel signs in again after the DNS switch.
  catalog_revalidate_secret  the HMAC key of the CIS catalog purge notice (CATALOG_REVALIDATE_SECRET), copied from
                             aa-cis/<env>/tripplanner-revalidate-hmac (a plain string; the CIS worker signs with it).
  sentry_dsn                 the browser/server DSN of the TripPlanner web Sentry project (SENTRY_DSN): --sentry-dsn
                             when given, else the value already stored, else "" (Sentry stays off; the app sends
                             nothing without a DSN).

Values are never printed: the output is one JSON line with the secret name, the keys that would change / changed and
the version id. Other keys already in the secret are kept. A re-run with nothing to change writes nothing.

Run it AFTER the Terraform apply that creates the shell and BEFORE the first task starts (a task whose secret lacks a
mapped key fails to start): apply -> this tool --apply -> the first deploy (AA-TripPlanner-Web Deploy Web Dev) ->
scale aa-tripplanner-<env>-web to 1. After a rotation of the revalidate key, run it again and force a new deployment.

Account guard: refuses to run unless the credentials are for --expect-account.
"""

from __future__ import annotations

import argparse
import json
import secrets
import sys
from typing import Any

DEFAULT_PROFILE = "aa365-admin"
DEFAULT_REGION = "us-west-1"
DEFAULT_ACCOUNT = "005097885195"
DEFAULT_ENV = "dev"

WEB_SECRET = "tripplanner/{env}/web"
REVALIDATE_SECRET = "aa-cis/{env}/tripplanner-revalidate-hmac"
MIN_SESSION_SECRET = 32
KEYS = ("session_secret", "catalog_revalidate_secret", "sentry_dsn")


class ToolError(Exception):
    """A refusal or an AWS failure, printed as one line (no traceback)."""


def out(line: dict[str, Any]) -> None:
    print(json.dumps(line, ensure_ascii=False), flush=True)


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


def revalidate_key(sm: Any, name: str) -> str:
    try:
        raw = sm.get_secret_value(SecretId=name)["SecretString"]
    except sm.exceptions.ResourceNotFoundException as exc:
        raise ToolError(f"{name} has no value: the CIS purge key must exist first (AA-987)") from exc
    value = (raw or "").strip()
    if not value:
        raise ToolError(f"{name} is empty")
    if value.startswith("{"):
        raise ToolError(f"{name} holds JSON, expected the plain key string the CIS worker signs with")
    return value


def wanted_values(current: dict[str, Any], revalidate: str, sentry_dsn: str | None) -> dict[str, str]:
    session = current.get("session_secret")
    if not isinstance(session, str) or len(session) < MIN_SESSION_SECRET:
        session = secrets.token_urlsafe(48)
    if sentry_dsn is not None:
        dsn = sentry_dsn.strip()
    else:
        dsn = current.get("sentry_dsn") if isinstance(current.get("sentry_dsn"), str) else ""
    if dsn and not dsn.startswith("https://"):
        raise ToolError("--sentry-dsn must be an https:// DSN (or empty to switch Sentry off)")
    return {"session_secret": session, "catalog_revalidate_secret": revalidate, "sentry_dsn": dsn}


def write_secret(sm: Any, env: str, sentry_dsn: str | None, *, apply: bool) -> dict[str, Any]:
    name = WEB_SECRET.format(env=env)
    if not _secret_exists(sm, name):
        raise ToolError(f"{name} does not exist: apply AA-CIS-Infra modules/environment/tripplanner_web.tf first (the shell)")
    current = _current_secret(sm, name)
    wanted = wanted_values(current, revalidate_key(sm, REVALIDATE_SECRET.format(env=env)), sentry_dsn)
    changed = sorted(k for k in KEYS if current.get(k) != wanted[k])
    result: dict[str, Any] = {"secret": name, "changed": changed, "sentry": "on" if wanted["sentry_dsn"] else "off"}
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
    p = argparse.ArgumentParser(description="AA-1038 TripPlanner web secret. DRY RUN unless --apply.")
    p.add_argument("--profile", default=DEFAULT_PROFILE, help="AWS profile ('' = default chain/env)")
    p.add_argument("--region", default=DEFAULT_REGION)
    p.add_argument("--expect-account", default=DEFAULT_ACCOUNT, help="refuse to run in any other account")
    p.add_argument("--env", default=DEFAULT_ENV)
    p.add_argument("--sentry-dsn", default=None, help="the TripPlanner web Sentry DSN; '' switches Sentry off; omit to keep")
    p.add_argument("--apply", action="store_true")
    return p


def main(argv: list[str] | None = None, clients: tuple[Any, Any] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if clients is None:
            import boto3  # noqa: PLC0415 — only when talking to AWS

            session = boto3.Session(profile_name=args.profile or None, region_name=args.region)
            sts, sm = session.client("sts"), session.client("secretsmanager")
        else:
            sts, sm = clients
        account = sts.get_caller_identity()["Account"]
        if args.expect_account and account != args.expect_account:
            raise ToolError(f"refused: credentials are for account {account}, expected {args.expect_account}")
        out(write_secret(sm, args.env, args.sentry_dsn, apply=args.apply))
        return 0
    except ToolError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 — one line, no traceback (a traceback could echo a request body)
        print(f"error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
