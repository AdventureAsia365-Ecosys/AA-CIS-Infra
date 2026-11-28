#!/usr/bin/env python3
"""Cognito app client secret rotation (AA-1182, key ceremony group 4). Run by an AWS admin with MFA from a
workstation. Not run by CI, not deployed. Standard library + boto3 only. DRY RUN by default: nothing is written
without --apply.

Why this tool exists (lesson S296): Cognito returns a new client secret value ONCE, in the AddUserPoolClientSecret
response (ClientSecretDescriptor.ClientSecretValue). Once a client has rotated secrets, DescribeUserPoolClient no
longer returns ClientSecret (the AWS CLI prints "None" with --output text), so "add, then read it back with
Describe" loses the value and a hash compare against "None" passes by mistake. Here the add response goes straight
into the client's Secrets Manager key in the same step, in memory only, and the stored value is checked by hash.

Subcommands (each takes --client <name>, see CLIENTS; status also works without --client)
  status                      Per client: its secrets in Cognito (id + creation time, never a value), the Secrets
                              Manager secret and key that hold the value, whether the key is set, and when the
                              secret last changed. Read only.
  add    --client C [--apply] Two-secret overlap, step 1. Refused when the client already has 2 secrets (the
                              Cognito limit: retire one first). Adds a secret, merges the value into its key of the
                              Secrets Manager secret (every other key kept), reads it back and compares SHA-256
                              hashes. If the write or the check fails twice, the Secrets Manager secret is moved
                              back to the version that was current before (AWSCURRENT), and only then is the secret
                              just added deleted again (the apps keep the old one); the command exits 1. If that
                              restore cannot be done safely (no earlier version, another writer changed the secret,
                              or the stage move fails) the new Cognito secret is KEPT and the manual steps are
                              printed, so the stored value never points at a deleted secret. Prints the new secret id
                              and the restart command(s) of the services that read the key.
  retire --client C --keep ID [--apply]
                              Two-secret overlap, step 2, after the restart and a sign-in / M2M check. Deletes
                              every secret of the client except ID. Refused unless ID is the client's newest secret
                              and the Secrets Manager secret changed at or after ID was created (proof that the add
                              step stored it).

Values are never printed: output is one JSON line per client with names, ids, dates, counts and hash verdicts. Errors
print the exception class and AWS error code only.

Account guard: refuses to run unless the credentials are for --expect-account. Pools and clients are found by NAME,
never by a pasted id. --profile '' uses the default credential chain (for example credentials exported from the CLI
MFA cache, so boto3 does not ask for a second MFA code).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import Any

DEFAULT_PROFILE = "aa365-admin"
DEFAULT_REGION = "us-west-1"
DEFAULT_ACCOUNT = "005097885195"
DEFAULT_ENV = "dev"
CLUSTER = "aa-cis-{env}-cluster"
# Cognito keeps at most two secrets per app client (the overlap window of a rotation).
MAX_SECRETS_PER_CLIENT = 2
WRITE_ATTEMPTS = 2


@dataclass(frozen=True)
class Client:
    """One confidential app client, the Secrets Manager key its value lives in, and the ECS services reading it."""

    pool: str           # user pool name template
    client: str         # app client name template
    secret: str         # Secrets Manager secret name template
    key: str            # JSON key inside that secret
    services: tuple     # ECS services (templates) that read the key at task start

    def names(self, env: str) -> dict[str, Any]:
        return {"pool": self.pool.format(env=env), "client": self.client.format(env=env),
                "secret": self.secret.format(env=env), "key": self.key,
                "services": [s.format(env=env) for s in self.services]}


# The seven confidential clients rotated in S296 (P6). Terraform: accounts/aa365/identity.tf (WORKFORCE clients),
# identity_partner.tf (partner-web), identity_m2m.tf (CRM M2M); the secret shells: modules/environment/staff_web.tf,
# crm_web.tf and identity_m2m.tf. Keys: the same names staff_web_secret.py and crm_dev_identity.py write.
CLIENTS: dict[str, Client] = {
    "crm-m2m": Client("aa-m2m-{env}", "aa-m2m-{env}-crm", "aa-crm/{env}/m2m-booking-client", "client_secret",
                      ("aa-crm-{env}-api",)),
    "partner-web": Client("aa-partner-{env}", "aa-partner-{env}-partner-web", "crm/{env}/web",
                          "cognito_client_secret", ("aa-crm-{env}-web",)),
    "cis-admin": Client("aa-workforce-{env}", "aa-workforce-{env}-cis-admin", "aa-cis/{env}/admin-web",
                        "cis_admin_client_secret", ("aa-cis-{env}-admin",)),
    "breakglass": Client("aa-workforce-{env}", "aa-workforce-{env}-breakglass", "aa-cis/{env}/admin-web",
                         "breakglass_client_secret", ("aa-cis-{env}-admin",)),
    "booking-staff": Client("aa-workforce-{env}", "aa-workforce-{env}-booking-staff", "booking/{env}/admin-web",
                            "booking_staff_client_secret", ("aa-booking-{env}-admin",)),
    "crm-staff": Client("aa-workforce-{env}", "aa-workforce-{env}-crm-staff", "crm/{env}/web",
                        "staff_cognito_client_secret", ("aa-crm-{env}-web",)),
    "academy-web": Client("aa-workforce-{env}", "aa-workforce-{env}-academy-web", "crm/{env}/web",
                          "academy_cognito_client_secret", ("aa-crm-{env}-web",)),
}


class ToolError(Exception):
    """A refusal or an AWS failure, printed as one line (no traceback)."""


def out(line: dict[str, Any]) -> None:
    print(json.dumps(line, ensure_ascii=False, default=str), flush=True)


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def _aws_err(exc: Exception) -> str:
    code = (getattr(exc, "response", None) or {}).get("Error", {}).get("Code")
    return f"{type(exc).__name__}{f' {code}' if code else ''}"


def stored_location(client_name: str, env: str) -> tuple[str, str] | None:
    """(secret name, key) holding the value of the app client named client_name, None for a client not listed."""
    for c in CLIENTS.values():
        if c.client.format(env=env) == client_name:
            return c.secret.format(env=env), c.key
    return None


# ── Cognito ──────────────────────────────────────────────────────────────────
def find_pool_id(idp: Any, name: str) -> str:
    kwargs: dict[str, Any] = {"MaxResults": 60}
    while True:
        page = idp.list_user_pools(**kwargs)
        for pool in page.get("UserPools", []):
            if pool.get("Name") == name:
                return pool["Id"]
        if not page.get("NextToken"):
            raise ToolError(f"user pool {name} not found")
        kwargs["NextToken"] = page["NextToken"]


def find_client_id(idp: Any, pool_id: str, name: str) -> str:
    kwargs: dict[str, Any] = {"UserPoolId": pool_id, "MaxResults": 60}
    while True:
        page = idp.list_user_pool_clients(**kwargs)
        for client in page.get("UserPoolClients", []):
            if client.get("ClientName") == name:
                return client["ClientId"]
        if not page.get("NextToken"):
            raise ToolError(f"app client {name} not found")
        kwargs["NextToken"] = page["NextToken"]


def list_client_secrets(idp: Any, pool_id: str, client_id: str) -> list[dict[str, Any]]:
    """Every secret of the client, oldest first: [{"id", "created"}]. The value is never part of a listing."""
    kwargs: dict[str, Any] = {"UserPoolId": pool_id, "ClientId": client_id}
    found: list[dict[str, Any]] = []
    while True:
        page = idp.list_user_pool_client_secrets(**kwargs)
        for d in page.get("ClientSecrets", []):
            found.append({"id": d["ClientSecretId"], "created": d.get("ClientSecretCreateDate")})
        if not page.get("NextToken"):
            break
        kwargs["NextToken"] = page["NextToken"]
    return sorted(found, key=lambda s: (s["created"] is None, s["created"] or datetime.min))


# ── Secrets Manager ──────────────────────────────────────────────────────────
def _secret_exists(sm: Any, name: str) -> bool:
    try:
        sm.describe_secret(SecretId=name)
        return True
    except sm.exceptions.ResourceNotFoundException:
        return False


def _current_secret(sm: Any, name: str) -> dict[str, Any]:
    """The JSON object stored in the secret; {} for a shell without a value. A non-object value is refused: merging
    a key into it would destroy what is there."""
    try:
        raw = sm.get_secret_value(SecretId=name)["SecretString"]
    except sm.exceptions.ResourceNotFoundException:
        return {}
    try:
        data = json.loads(raw)
    except ValueError:
        raise ToolError(f"{name} does not hold a JSON object: fix it by hand first") from None
    if not isinstance(data, dict):
        raise ToolError(f"{name} does not hold a JSON object: fix it by hand first")
    return data


def _last_changed(sm: Any, name: str) -> Any:
    return sm.describe_secret(SecretId=name).get("LastChangedDate")


def current_version_id(sm: Any, name: str) -> str | None:
    """The version id that holds the AWSCURRENT stage, None for a shell that never had a value."""
    stages = sm.describe_secret(SecretId=name).get("VersionIdsToStages") or {}
    for version_id, labels in stages.items():
        if "AWSCURRENT" in (labels or []):
            return version_id
    return None


def store_value(sm: Any, name: str, key: str, value: str, written: list[str] | None = None) -> str:
    """Merge key=value into the secret and check the stored copy by hash. Returns the new version id. The id of a put
    that succeeded is appended to written before the check, so a caller can undo it when the check fails."""
    current = _current_secret(sm, name)
    resp = sm.put_secret_value(SecretId=name, SecretString=json.dumps({**current, key: value}))
    if written is not None:
        written.append(resp.get("VersionId", ""))
    stored = _current_secret(sm, name).get(key)
    if not isinstance(stored, str) or _sha256(stored) != _sha256(value):
        raise ToolError(f"{name}: the stored {key} does not match the new value (hash check)")
    return resp.get("VersionId", "")


def restore_previous_version(sm: Any, name: str, previous: str | None, written: list[str]) -> str:
    """Undo the puts of an abandoned add. Returns "unchanged" (no put of ours is current: nothing to undo) or
    "restored" (AWSCURRENT moved back to previous). Raises ToolError when the undo is not safe: no earlier version
    to go back to, AWSCURRENT is a version this run did not write (a put that succeeded after a client-side error,
    or another writer of the shared secret), or the stage move fails."""
    now = current_version_id(sm, name)
    if now == previous:
        return "unchanged"
    if previous is None:
        raise ToolError("the secret had no earlier version to move back to")
    if now not in [v for v in written if v]:
        raise ToolError(f"AWSCURRENT is version {now}, not one this run wrote (another writer, or a put that "
                        "succeeded after a client-side error)")
    try:
        sm.update_secret_version_stage(SecretId=name, VersionStage="AWSCURRENT", MoveToVersionId=previous,
                                       RemoveFromVersionId=now)
    except Exception as exc:  # noqa: BLE001
        raise ToolError(f"moving AWSCURRENT back failed ({_aws_err(exc)})") from None
    if current_version_id(sm, name) != previous:
        raise ToolError("AWSCURRENT did not move back")
    return "restored"


# ── commands ─────────────────────────────────────────────────────────────────
def _resolve(idp: Any, name: str, env: str) -> tuple[dict[str, Any], str, str]:
    if name not in CLIENTS:
        raise ToolError(f"refused: unknown client {name!r} (one of {', '.join(CLIENTS)})")
    names = CLIENTS[name].names(env)
    pool_id = find_pool_id(idp, names["pool"])
    return names, pool_id, find_client_id(idp, pool_id, names["client"])


def _restart_commands(names: dict[str, Any], env: str, profile: str, region: str) -> list[str]:
    prof = f" --profile {profile}" if profile else ""
    return [f"aws ecs update-service --cluster {CLUSTER.format(env=env)} --service {s} --force-new-deployment"
            f"{prof} --region {region} --query service.deployments[0].id --output text" for s in names["services"]]


def status(idp: Any, sm: Any, name: str, env: str) -> dict[str, Any]:
    names, pool_id, client_id = _resolve(idp, name, env)
    row: dict[str, Any] = {"client": name, "app_client": names["client"], "secret": names["secret"],
                           "key": names["key"]}
    row["cognito_secrets"] = list_client_secrets(idp, pool_id, client_id)
    if _secret_exists(sm, names["secret"]):
        row["key_set"] = bool(_current_secret(sm, names["secret"]).get(names["key"]))
        row["secret_last_changed"] = _last_changed(sm, names["secret"])
    else:
        row["key_set"] = False
        row["secret_last_changed"] = None
        row["note"] = "secret shell missing: apply its Terraform first"
    return row


def _abandon_add(idp: Any, sm: Any, names: dict[str, Any], pool_id: str, client_id: str, new_id: str,
                 previous: str | None, written: list[str], name: str) -> str:
    """Undo an add whose stored copy could not be verified. The Cognito secret is deleted only once Secrets Manager
    no longer serves its value (AWSCURRENT unchanged or moved back); otherwise it is kept, because the next task
    start of a reading service would load a value Cognito no longer accepts."""
    try:
        state = restore_previous_version(sm, names["secret"], previous, written)
    except ToolError as exc:
        return (f"the new Cognito secret {new_id} was KEPT because the stored value could not be put back ({exc}); "
                f"run status --client {name}: if the key holds the new value, restart and retire as usual; "
                f"otherwise move AWSCURRENT back by hand (aws secretsmanager update-secret-version-stage "
                f"--secret-id {names['secret']} --version-stage AWSCURRENT --move-to-version-id {previous} "
                f"--remove-from-version-id <current>) and then delete {new_id} "
                f"(aws cognito-idp delete-user-pool-client-secret)")
    done = "AWSCURRENT moved back to the earlier version, " if state == "restored" else ""
    try:
        idp.delete_user_pool_client_secret(UserPoolId=pool_id, ClientId=client_id, ClientSecretId=new_id)
        return f"{done}the secret just added was deleted again; the apps keep the old one"
    except Exception as exc:  # noqa: BLE001
        return (f"{done}deleting the secret just added failed too ({_aws_err(exc)}): delete {new_id} by hand "
                f"(aws cognito-idp delete-user-pool-client-secret), the apps still use the old one")


def add(idp: Any, sm: Any, name: str, env: str, *, apply: bool, profile: str, region: str) -> dict[str, Any]:
    names, pool_id, client_id = _resolve(idp, name, env)
    if not _secret_exists(sm, names["secret"]):
        raise ToolError(f"{names['secret']} does not exist: apply its Terraform secret shell first")
    _current_secret(sm, names["secret"])        # refuse a non-JSON value before Cognito changes anything
    before = list_client_secrets(idp, pool_id, client_id)
    row: dict[str, Any] = {"client": name, "app_client": names["client"], "secret": names["secret"],
                           "key": names["key"], "secrets_before": len(before)}
    if len(before) >= MAX_SECRETS_PER_CLIENT:
        raise ToolError(f"{names['client']} already has {len(before)} secrets: retire the old one first "
                        f"(retire --client {name} --keep <newest id>)")
    if not apply:
        row["action"] = "would_add"
        return row
    # The version the apps read today: an abandoned add moves AWSCURRENT back here before deleting the new secret.
    previous = current_version_id(sm, names["secret"])
    resp = idp.add_user_pool_client_secret(UserPoolId=pool_id, ClientId=client_id)
    desc = resp.get("ClientSecretDescriptor") or {}
    new_id, value = desc.get("ClientSecretId"), desc.get("ClientSecretValue")
    if not new_id or not value:
        raise ToolError(f"{names['client']}: the add response carried no secret id or value; check "
                        f"status --client {name} (a secret may have been added without a stored value)")
    version_id, failure, written = "", "", []
    for _ in range(WRITE_ATTEMPTS):
        try:
            version_id = store_value(sm, names["secret"], names["key"], value, written)
            failure = ""
            break
        except Exception as exc:  # noqa: BLE001 — class + code only, a message could echo a request body
            failure = str(exc) if isinstance(exc, ToolError) else _aws_err(exc)
    del value
    if failure:
        undo = _abandon_add(idp, sm, names, pool_id, client_id, new_id, previous, written, name)
        raise ToolError(f"{names['secret']}: storing the new value failed ({failure}); {undo}")
    row.update(action="added", new_secret_id=new_id, version_id=version_id, stored="hash-verified",
               secrets_after=len(before) + 1,
               next=_restart_commands(names, env, profile, region)
               + [f"then check sign-in / M2M, then: retire --client {name} --keep {new_id} --apply"])
    return row


def retire(idp: Any, sm: Any, name: str, env: str, keep: str, *, apply: bool) -> dict[str, Any]:
    names, pool_id, client_id = _resolve(idp, name, env)
    secrets = list_client_secrets(idp, pool_id, client_id)
    ids = [s["id"] for s in secrets]
    if keep not in ids:
        raise ToolError(f"{names['client']} has no secret {keep}")
    if len(secrets) < 2:
        raise ToolError(f"{names['client']} has only {keep}: nothing to retire")
    newest = secrets[-1]
    if newest["id"] != keep:
        raise ToolError(f"refused: {keep} is not the newest secret of {names['client']} (newest: {newest['id']})")
    changed = _last_changed(sm, names["secret"])
    if changed is None or newest["created"] is None or changed < newest["created"]:
        raise ToolError(f"refused: {names['secret']} has not changed since {keep} was created; run add first "
                        "(or rewrite the key from the add response) before retiring the old secret")
    old = [i for i in ids if i != keep]
    row: dict[str, Any] = {"client": name, "app_client": names["client"], "keep": keep, "retire": old}
    if not apply:
        row["action"] = "would_delete"
        return row
    for secret_id in old:
        idp.delete_user_pool_client_secret(UserPoolId=pool_id, ClientId=client_id, ClientSecretId=secret_id)
    row["action"] = "deleted"
    row["secrets_after"] = len(list_client_secrets(idp, pool_id, client_id))
    return row


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="AA-1182 Cognito client secret rotation. DRY RUN unless --apply.")
    p.add_argument("--profile", default=DEFAULT_PROFILE, help="AWS profile ('' = default chain/env)")
    p.add_argument("--region", default=DEFAULT_REGION)
    p.add_argument("--expect-account", default=DEFAULT_ACCOUNT, help="refuse to run in any other account")
    p.add_argument("--env", default=DEFAULT_ENV)
    sub = p.add_subparsers(dest="cmd", required=True)
    st = sub.add_parser("status")
    st.add_argument("--client", choices=list(CLIENTS))
    ad = sub.add_parser("add")
    ad.add_argument("--client", required=True, choices=list(CLIENTS))
    ad.add_argument("--apply", action="store_true")
    rt = sub.add_parser("retire")
    rt.add_argument("--client", required=True, choices=list(CLIENTS))
    rt.add_argument("--keep", required=True, help="the secret id to keep (the add step prints it)")
    rt.add_argument("--apply", action="store_true")
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
        if args.cmd == "status":
            for name in [args.client] if args.client else list(CLIENTS):
                out(status(idp, sm, name, args.env))
        elif args.cmd == "add":
            out(add(idp, sm, args.client, args.env, apply=args.apply, profile=args.profile, region=args.region))
        else:
            out(retire(idp, sm, args.client, args.env, args.keep, apply=args.apply))
        return 0
    except ToolError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 — one line, no traceback (a traceback could echo a request body)
        print(f"error: {_aws_err(exc)}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
