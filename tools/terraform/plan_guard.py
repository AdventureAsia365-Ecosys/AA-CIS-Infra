#!/usr/bin/env python3
"""Terraform plan guard for the CI apply (AA-846).

Reads the JSON of a saved plan (`terraform show -json tfplan`) and refuses the apply when the plan
touches a guarded resource type with any action other than no-op or read. Guarded by default:

  aws_secretsmanager_secret_version   a secret value (rotation, overwrite, forget, delete)
  random_password                     a generated credential (a replace changes the password)
  aws_db_instance                     the shared RDS instance (all three apps)

Object Lock (AA-932, the CRM audit buckets), guarded by rule rather than by type:

  aws_s3_bucket_object_lock_configuration   refused on any update, delete, replace, forget or import, and on a
                                            create whose default retention mode is COMPLIANCE (irreversible for
                                            every locked version; Dev is governance only, design v3 §3.6). A
                                            GOVERNANCE create passes.
  aws_s3_bucket                             refused when the plan deletes or replaces a bucket that has
                                            object_lock_enabled = true.

Organization, account, SCP, trail and Identity Center resources (AA-1004, the accounts/management root; the nonprod
account's own trail in accounts/aa365 too), guarded against removal only:

  aws_organizations_* (organization, OU, account, policy, policy attachment, delegated admin, resource policy),
  aws_iam_organizations_features, aws_cloudtrail, aws_ssoadmin_* (permission sets, their policies, assignments),
  aws_identitystore_* (users, groups, memberships)
                                            refused on delete, replace (delete+create either order) and forget.
                                            Create, update and import pass: adding a user, an SCP edit or importing
                                            an invited account is ordinary work; removing one is not.

Matching is on the resource type, so module addresses (module.rds.aws_db_instance.main) count too.
`forget` (a `removed` block) and imports of a guarded type are refused as well: they change what
Terraform owns, which deserves the same explicit opt-in.

The guard prints only addresses, types and actions, never attribute values: the plan JSON holds
sensitive values in clear text. The one exception is the Object Lock mode word (COMPLIANCE), which is not secret.

Exit codes:
  0  nothing guarded is touched, or it is but --allow-reason was given (each change is listed as a
     warning together with the reason)
  1  refused: a guarded resource would change
  2  bad input (missing file, not JSON, not a Terraform plan JSON); fail closed

Stdlib only. Usage:
  terraform show -json tfplan > plan.json
  python3 tools/terraform/plan_guard.py plan.json [--allow-reason "why"] [--summary $GITHUB_STEP_SUMMARY]
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from typing import Iterable, Optional

GUARDED_TYPES = frozenset(
    {
        "aws_secretsmanager_secret_version",
        "random_password",
        "aws_db_instance",
    }
)

# AA-1004: refused only when the plan removes them (delete, replace, forget); see the module docstring.
DESTROY_GUARDED_TYPES = frozenset(
    {
        "aws_organizations_organization",
        "aws_organizations_organizational_unit",
        "aws_organizations_account",
        "aws_organizations_policy",
        "aws_organizations_policy_attachment",
        "aws_organizations_delegated_administrator",
        "aws_organizations_resource_policy",
        "aws_iam_organizations_features",
        "aws_cloudtrail",
        "aws_ssoadmin_permission_set",
        "aws_ssoadmin_account_assignment",
        "aws_ssoadmin_managed_policy_attachment",
        "aws_ssoadmin_customer_managed_policy_attachment",
        "aws_ssoadmin_permission_set_inline_policy",
        "aws_ssoadmin_permissions_boundary_attachment",
        "aws_identitystore_user",
        "aws_identitystore_group",
        "aws_identitystore_group_membership",
    }
)
_REMOVING_ACTIONS = frozenset({"delete", "forget"})

OBJECT_LOCK_CONFIG_TYPE = "aws_s3_bucket_object_lock_configuration"
BUCKET_TYPE = "aws_s3_bucket"

# Actions that leave the real resource and its state untouched.
_SAFE_ACTIONS = (["no-op"], ["read"])


class InputError(Exception):
    """The plan JSON cannot be read or is not a Terraform plan."""


@dataclass(frozen=True)
class GuardedChange:
    address: str
    type: str
    action: str  # e.g. "update", "delete,create", "forget", "import"


def _action_label(actions: list[str], importing: bool) -> Optional[str]:
    """The action text for a guarded resource, or None when it is safe."""
    if actions in _SAFE_ACTIONS and not importing:
        return None
    label = ",".join(actions)
    if importing:
        label = "import" if actions == ["no-op"] else f"import+{label}"
    return label


def find_guarded_changes(
    plan: dict,
    guarded_types: Iterable[str] = GUARDED_TYPES,
    destroy_guarded_types: Iterable[str] = DESTROY_GUARDED_TYPES,
) -> list[GuardedChange]:
    """Every change on a guarded type whose action is not no-op/read, and every removal of a destroy-guarded type."""
    if not isinstance(plan, dict) or "format_version" not in plan:
        raise InputError("not a Terraform plan JSON (no format_version); use `terraform show -json <planfile>`")
    if "planned_values" not in plan and "resource_changes" not in plan:
        # `terraform show -json` on a state (not a plan) has values but no planned_values.
        raise InputError("JSON has no planned_values/resource_changes: is this a state, not a plan?")
    changes = plan.get("resource_changes")
    if changes is None:  # a plan with no changes may omit the key
        changes = []
    if not isinstance(changes, list):
        raise InputError("resource_changes is not a list")

    guarded = frozenset(guarded_types)
    destroy_guarded = frozenset(destroy_guarded_types)
    found: list[GuardedChange] = []
    for rc in changes:
        if not isinstance(rc, dict):
            raise InputError("resource_changes entry is not an object")
        rtype = rc.get("type")
        if rtype in (OBJECT_LOCK_CONFIG_TYPE, BUCKET_TYPE):
            lock = _object_lock_change(rc)
            if lock is not None:
                found.append(lock)
            continue
        if rtype in destroy_guarded and rtype not in guarded:
            removal = _removal_change(rc)
            if removal is not None:
                found.append(removal)
            continue
        if rtype not in guarded:
            continue
        change = rc.get("change")
        if not isinstance(change, dict) or not isinstance(change.get("actions"), list):
            raise InputError(f"{rc.get('address', '?')}: change.actions missing")
        label = _action_label(change["actions"], bool(change.get("importing")))
        if label is not None:
            found.append(GuardedChange(address=str(rc.get("address", "?")), type=rtype, action=label))
    return found


def _removal_change(rc: dict) -> Optional[GuardedChange]:
    """A destroy-guarded type (AA-1004): a GuardedChange when the plan deletes, replaces or forgets it, else None."""
    change = rc.get("change")
    if not isinstance(change, dict) or not isinstance(change.get("actions"), list):
        raise InputError(f"{rc.get('address', '?')}: change.actions missing")
    actions = change["actions"]
    if not _REMOVING_ACTIONS.intersection(actions):
        return None
    label = ",".join(actions)
    if "delete" in actions and "create" in actions:
        label += " (replace)"
    return GuardedChange(address=str(rc.get("address", "?")), type=str(rc["type"]), action=label)


def _compliance_mode(after: object) -> bool:
    """True when an object lock configuration's planned default retention is COMPLIANCE."""
    if not isinstance(after, dict):
        return False
    for rule in after.get("rule") or []:
        for ret in (rule or {}).get("default_retention") or []:
            if (ret or {}).get("mode") == "COMPLIANCE":
                return True
    return False


def _object_lock_change(rc: dict) -> Optional[GuardedChange]:
    """The Object Lock rule (module docstring): a GuardedChange, or None when the change is allowed."""
    change = rc.get("change")
    if not isinstance(change, dict) or not isinstance(change.get("actions"), list):
        raise InputError(f"{rc.get('address', '?')}: change.actions missing")
    actions = change["actions"]
    importing = bool(change.get("importing"))
    address, rtype = str(rc.get("address", "?")), rc["type"]
    if rtype == BUCKET_TYPE:
        before = change.get("before") if isinstance(change.get("before"), dict) else {}
        if "delete" in actions and before.get("object_lock_enabled") is True:
            return GuardedChange(address=address, type=rtype, action=",".join(actions) + " (Object Lock bucket)")
        return None
    if actions == ["create"] and not importing:
        if _compliance_mode(change.get("after")):
            return GuardedChange(address=address, type=rtype, action="create (COMPLIANCE)")
        return None
    label = _action_label(actions, importing)
    if label is None:
        return None
    if "create" in actions and _compliance_mode(change.get("after")):
        label += " (COMPLIANCE)"
    return GuardedChange(address=address, type=rtype, action=label)


def render(changes: list[GuardedChange], allow_reason: Optional[str]) -> tuple[str, int]:
    """Report text (Markdown-friendly) and the exit code."""
    types = ", ".join(sorted(GUARDED_TYPES) + ["Object Lock rule", "removal of organization/trail/Identity Center types"])
    if not changes:
        return f"Plan guard: OK, no change on a guarded type ({types}).", 0
    lines = [f"- `{c.address}` ({c.type}): {c.action}" for c in changes]
    if allow_reason:
        head = (
            f"Plan guard: ALLOWED by dispatch input (allow_guarded) with reason: {allow_reason}\n"
            f"{len(changes)} guarded change(s) will be applied:"
        )
        return head + "\n" + "\n".join(lines), 0
    head = (
        f"Plan guard: REFUSED. The plan changes {len(changes)} guarded resource(s) ({types}):"
    )
    tail = (
        "Nothing was applied. If the change is intended, re-run Terraform Apply Prod with "
        "allow_guarded=true and allow_reason set (it is echoed to the job summary)."
    )
    return head + "\n" + "\n".join(lines) + "\n" + tail, 1


def _load(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError as exc:
        raise InputError(f"plan JSON not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise InputError(f"plan JSON is not valid JSON ({exc.msg} at line {exc.lineno})") from exc


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("plan_json", help="output of `terraform show -json <planfile>`")
    ap.add_argument(
        "--allow-reason",
        default="",
        help="let guarded changes through (exit 0) and record this reason; empty = refuse",
    )
    ap.add_argument("--summary", help="append the report to this file (e.g. $GITHUB_STEP_SUMMARY)")
    args = ap.parse_args(argv)

    allow_reason = args.allow_reason.strip() or None
    try:
        changes = find_guarded_changes(_load(args.plan_json))
    except InputError as exc:
        text, code = f"Plan guard: ERROR, {exc}. Refusing to apply (fail closed).", 2
    else:
        text, code = render(changes, allow_reason)

    print(text, file=sys.stderr if code else sys.stdout)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write("### Terraform plan guard\n\n" + text + "\n\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
