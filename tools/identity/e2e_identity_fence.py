#!/usr/bin/env python3
"""Pilot day: list, then disable, the Dev-only E2E staff identities of the WORKFORCE pool (AA-1054, root ADR 0006a).

Tech lead decision S295 (sec-Q11): the Dev-only E2E identities (A10, A10a ... A10h: the agent's test accounts, every
address of the E2E mailbox domain) are disabled on the day the pilot agency starts on Dev, not at go-live. The CIS and
Booking APIs already refuse them once the pilot fence setting is on (CIS ``cis.platform.pilot_e2e_fence``); this tool
then switches their Cognito users off, so no E2E sign-in is even issued a token. Order: root runbook
docs/ops/runbooks/pilot-agency-onboarding.md, section "Pilot day".

Run by the orchestrating agent on the pilot day only, or by the tech lead, with MFA (profile aa365-admin). Not run by
CI, not deployed. Standard library and boto3 only.

    PY=/home/nghiep/projects/AA-Ecosys/apps/AA-CIS-App/.venv/bin/python
    $PY tools/identity/e2e_identity_fence.py                 # DRY RUN (default): list codes + Cognito state
    $PY tools/identity/e2e_identity_fence.py --apply         # disable + global sign-out each enabled one, read back
    $PY tools/identity/e2e_identity_fence.py --json          # the same listing as one JSON document on stdout

What it lists. The known addresses come from the WORKFORCE pre token trigger (accounts/aa365/lambda_src/
identity_triggers/workforce.py, every ``E2E_*_EMAIL`` constant, read with ``ast``: nothing is imported or executed),
mapped to their ADR 0006a exception code by :data:`CODES`. The pool is read with ListUsers (filter ``email ^= "e2e"``,
the read the bootstrap tool uses; AdminGetUser would count a monthly active user each): every user whose e-mail is of
the E2E mailbox domain is listed, a known one under its code and any other under ``unmapped``. Each row shows the code,
a masked label, ``in_pool``, ``enabled`` and the Cognito status. E-mail addresses and Cognito usernames are never
printed (every one is registered with the output redactor, errors included).

``--apply`` disables every listed user that is enabled (AdminDisableUser) and signs it out everywhere
(AdminUserGlobalSignOut: its refresh tokens stop), then lists the pool again (the read-back). Exit 0 only when every
E2E user in the pool reads ``enabled: false``. It never deletes a user and never touches an address outside the E2E
mailbox domain. Undo (only if the pilot is called off): AdminEnableUser per user, by hand.

Exit codes: 0 done (DRY RUN listed, or every E2E user disabled), 1 apply incomplete or an AWS error, 2 a known E2E
constant of the trigger has no code here (update :data:`CODES` first).
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from workforce_bootstrap import (  # noqa: E402 - same directory; shares the Dev facts and the redactor
    DEFAULT_ACCOUNT,
    DEFAULT_POOL_ID,
    DEFAULT_PROFILE,
    DEFAULT_REGION,
    Output,
    ToolError,
)

REPO = Path(__file__).resolve().parents[2]
WORKFORCE_PY = REPO / "accounts" / "aa365" / "lambda_src" / "identity_triggers" / "workforce.py"
# The domain of every Dev-only E2E address (accounts/aa365/e2e_mailbox.tf).
E2E_MAIL_DOMAIN = "e2e-mail.lumiguides.it.com"
LIST_FILTER = 'email ^= "e2e"'
UNMAPPED = "unmapped"


class UnmappedConstant(ToolError):
    """A known E2E constant of the trigger has no exception code here: exit code 2."""

    exit_code = 2

# workforce.py constant -> root ADR 0006a exception code. A new E2E_*_EMAIL constant without a code stops the tool
# (exit 2) and fails tools/identity/tests/test_e2e_identity_fence.py.
CODES: dict[str, str] = {
    "E2E_TEST_STAFF_EMAIL": "A10",
    "E2E_BOOKING_TEST_STAFF_EMAIL": "A10a",
    "E2E_CIS_ADMIN_TEST_STAFF_EMAIL": "A10b",
    "E2E_CRM_STAFF_TEST_STAFF_EMAIL": "A10c",
    "E2E_CIS_CS_TEST_STAFF_EMAIL": "A10d",
    "E2E_BOOKING_STAFF_TEST_STAFF_EMAIL": "A10e",
    "E2E_BOOKING_MAKER_TEST_STAFF_EMAIL": "A10e",
    "E2E_BOOKING_CHECKER_TEST_STAFF_EMAIL": "A10e",
    "E2E_BOOKING_PRICING_CHECKER_TEST_STAFF_EMAIL": "A10e-2",
    "E2E_CIS_CONTENT_LEAD_TEST_STAFF_EMAIL": "A10f",
    "E2E_CUSTOM_ROLE_MAKER_TEST_STAFF_EMAIL": "A10g",
    "E2E_OWNER_TEST_STAFF_EMAIL": "A10h",
}


@dataclass
class Row:
    code: str
    label: str
    email: str
    username: str | None = None
    in_pool: bool = False
    enabled: bool | None = None
    status: str | None = None

    def public(self) -> dict[str, Any]:
        return {"code": self.code, "label": self.label, "in_pool": self.in_pool, "enabled": self.enabled,
                "status": self.status}


def known_addresses(path: Path = WORKFORCE_PY) -> dict[str, str]:
    """Every module-level ``E2E_*_EMAIL = "..."`` string constant of the trigger (name -> address), read with ast."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    found: dict[str, str] = {}
    for node in tree.body:
        if (isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)
                and node.targets[0].id.startswith("E2E_") and node.targets[0].id.endswith("_EMAIL")
                and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)):
            found[node.targets[0].id] = node.value.value.strip().lower()
    return found


def is_e2e_address(email: Any) -> bool:
    if not isinstance(email, str):
        return False
    local, sep, domain = email.strip().lower().rpartition("@")
    return bool(sep) and bool(local) and domain == E2E_MAIL_DOMAIN


def mask(email: str) -> str:
    """A label that names no address: the first four and the last two letters of the local part, the rest starred;
    the domain left out."""
    local = email.split("@", 1)[0]
    if len(local) <= 6:
        return local[:2] + "*" * max(len(local) - 2, 1)
    return local[:4] + "*" * (len(local) - 6) + local[-2:]


def expected_rows(addresses: dict[str, str]) -> list[Row]:
    missing = sorted(set(addresses) - set(CODES))
    if missing:
        raise UnmappedConstant(f"refused: E2E constants without an exception code in CODES: {missing}")
    rows = [Row(code=CODES[name], label=mask(email), email=email) for name, email in addresses.items()]
    rows.sort(key=lambda r: (r.code, r.label))
    seen: dict[str, int] = {}
    for r in rows:   # A10e has three addresses: number them so each row reads apart
        if sum(1 for o in rows if o.code == r.code) > 1:
            seen[r.code] = seen.get(r.code, 0) + 1
            r.label = f"{r.label} #{seen[r.code]}"
    return rows


def _email_of(user: dict[str, Any]) -> str:
    for attr in user.get("Attributes", []):
        if attr.get("Name") == "email":
            return str(attr.get("Value", "")).strip().lower()
    return ""


def list_e2e_users(idp: Any, pool_id: str) -> list[dict[str, Any]]:
    """Every pool user whose e-mail is of the E2E mailbox domain (ListUsers, paginated)."""
    users: list[dict[str, Any]] = []
    token: str | None = None
    while True:
        kwargs: dict[str, Any] = {"UserPoolId": pool_id, "Filter": LIST_FILTER, "AttributesToGet": ["email"]}
        if token:
            kwargs["PaginationToken"] = token
        page = idp.list_users(**kwargs)
        users.extend(u for u in page.get("Users", []) if is_e2e_address(_email_of(u)))
        token = page.get("PaginationToken")
        if not token:
            return users


def inventory(idp: Any, pool_id: str, out: Output, addresses: dict[str, str]) -> list[Row]:
    rows = expected_rows(addresses)
    for r in rows:
        out.register(r.email)
    by_email = {r.email: r for r in rows}
    for user in list_e2e_users(idp, pool_id):
        email = _email_of(user)
        out.register(email, user.get("Username"))
        row = by_email.get(email)
        if row is None:
            row = Row(code=UNMAPPED, label=mask(email), email=email)
            rows.append(row)
            by_email[email] = row
        row.username = user.get("Username")
        row.in_pool = True
        row.enabled = bool(user.get("Enabled"))
        row.status = user.get("UserStatus")
    return rows


def render(rows: list[Row], out: Output, title: str) -> None:
    out.info(title)
    out.info(f"  {'code':<8} {'label':<34} {'in_pool':<8} {'enabled':<8} status")
    for r in rows:
        enabled = "-" if r.enabled is None else str(r.enabled).lower()
        out.info(f"  {r.code:<8} {r.label:<34} {str(r.in_pool).lower():<8} {enabled:<8} {r.status or '-'}")
    in_pool = [r for r in rows if r.in_pool]
    out.info(f"  {len(rows)} E2E identities known or found, {len(in_pool)} in the pool, "
             f"{sum(1 for r in in_pool if r.enabled)} enabled")


def disable(idp: Any, pool_id: str, rows: list[Row], out: Output) -> list[str]:
    """Disable + global sign-out every enabled E2E user; the labels of the ones that failed."""
    failed: list[str] = []
    for r in rows:
        if not (r.in_pool and r.enabled and r.username):
            continue
        try:
            idp.admin_disable_user(UserPoolId=pool_id, Username=r.username)
            idp.admin_user_global_sign_out(UserPoolId=pool_id, Username=r.username)
            out.info(f"  disabled + signed out: {r.code} {r.label}")
        except Exception as exc:  # noqa: BLE001 - keep going: every other user must still be disabled
            out.warn(f"  FAILED {r.code} {r.label}: {type(exc).__name__}")
            failed.append(f"{r.code} {r.label}")
    return failed


def run(idp: Any, pool_id: str, out: Output, *, apply: bool, as_json: bool,
        addresses: dict[str, str] | None = None) -> int:
    addresses = known_addresses() if addresses is None else addresses
    rows = inventory(idp, pool_id, out, addresses)
    if not apply:
        if as_json:
            out.info(json.dumps({"mode": "dry_run", "rows": [r.public() for r in rows]}, indent=2))
        else:
            render(rows, out, "DRY RUN (nothing changed; --apply disables the enabled ones):")
        return 0
    if not as_json:
        render(rows, out, "before:")
    failed = disable(idp, pool_id, rows, out)
    after = inventory(idp, pool_id, out, addresses)
    still = [r for r in after if r.in_pool and r.enabled]
    if as_json:
        out.info(json.dumps({"mode": "apply", "failed": failed, "rows": [r.public() for r in after]}, indent=2))
    else:
        render(after, out, "read-back:")
    if failed or still:
        out.warn(f"INCOMPLETE: {len(still)} E2E user(s) still enabled; run the tool again or "
                 "admin-disable-user by hand")
        return 1
    out.info("done: every E2E user in the pool is disabled")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="e2e_identity_fence.py", description=__doc__.split("\n")[0])
    p.add_argument("--profile", default=DEFAULT_PROFILE, help="AWS profile ('' = default chain/env)")
    p.add_argument("--region", default=DEFAULT_REGION)
    p.add_argument("--expect-account", default=DEFAULT_ACCOUNT, help="refuse to run in any other account")
    p.add_argument("--pool-id", default=DEFAULT_POOL_ID)
    p.add_argument("--apply", action="store_true", help="disable + sign out the enabled E2E users (pilot day only)")
    p.add_argument("--json", action="store_true", help="one JSON document on stdout")
    return p


def _idp(args: argparse.Namespace, out: Output) -> Any:
    import boto3  # imported here so the pure helpers and tests need no AWS setup

    session = boto3.Session(profile_name=args.profile or None, region_name=args.region)
    try:  # reuse the AWS CLI's assume-role cache (one MFA prompt, shared with aws cli)
        from botocore.credentials import JSONFileCache

        provider = session._session.get_component("credential_provider").get_provider("assume-role")
        provider.cache = JSONFileCache(os.path.expanduser(os.path.join("~", ".aws", "cli", "cache")))
    except Exception:  # noqa: BLE001
        pass
    account = session.client("sts").get_caller_identity()["Account"]
    if args.expect_account and account != args.expect_account:
        raise ToolError(f"refused: credentials are for account {account}, expected {args.expect_account}")
    out.warn(f"aws: region {args.region}, mode {'APPLY' if args.apply else 'DRY RUN'}")
    return session.client("cognito-idp")


def main(argv: list[str] | None = None, out: Output | None = None, idp: Any = None) -> int:
    out = out or Output()
    args = build_parser().parse_args(argv)
    try:
        client = idp if idp is not None else _idp(args, out)
        return run(client, args.pool_id, out, apply=args.apply, as_json=args.json)
    except ToolError as exc:
        out.warn(f"ERROR {exc}")
        return exc.exit_code
    except Exception as exc:  # noqa: BLE001 - no traceback: locals could carry addresses
        out.warn(f"ERROR {type(exc).__name__}: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
