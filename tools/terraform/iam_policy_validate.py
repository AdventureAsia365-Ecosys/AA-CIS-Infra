#!/usr/bin/env python3
"""IAM Access Analyzer policy validation of a Terraform plan (AA-1185, S295 Well-Architected review; free).

Reads the JSON of a saved plan (`terraform show -json tfplan`), takes every IAM policy document that a resource the
plan creates or updates will carry, and sends each to IAM Access Analyzer `ValidatePolicy` (free; it checks grammar,
AWS best practice and security: wildcard PassRole, a Deny that never matches, an unknown action or condition key ...).

  Documents checked (create / update / replace only; unchanged policies are not re-checked):
    aws_iam_policy.policy, aws_iam_role_policy.policy, aws_iam_user_policy.policy, aws_iam_group_policy.policy
        -> IDENTITY_POLICY
    aws_iam_role.assume_role_policy  -> RESOURCE_POLICY, resource type AWS::IAM::AssumeRolePolicyDocument
    aws_s3_bucket_policy.policy      -> RESOURCE_POLICY, resource type AWS::S3::Bucket
    aws_sns_topic_policy, aws_sqs_queue_policy, aws_kms_key, aws_secretsmanager_secret_policy,
    aws_ecr_repository_policy, aws_cloudwatch_log_resource_policy (.policy / .policy_document)
        -> RESOURCE_POLICY
  A document still unknown at plan time (it names a resource the same apply creates) cannot be checked here; it is
  listed as "not checked (known after apply)" and the next plan that touches it checks it.

  Result per finding type: ERROR and SECURITY_WARNING fail the run (exit 1) unless the allow file lists the exact
  (address, issueCode) with a reason; WARNING and SUGGESTION are listed only.

Output: resource addresses (identity-store keys redacted, as plan_guard.py does), finding types, issue codes and the
finding text masked by tools/docs/aws_mask.py (no account id or ARN in a public log). Never the policy text.

The AWS call goes through the `aws` CLI (`accessanalyzer validate-policy`, read only and free; the plan role's AWS managed
ReadOnlyAccess includes access-analyzer:ValidatePolicy, checked 27/11/2026, so no grant is added). Exit codes: 0 clean, 1 blocking findings, 2 bad input or AWS error (fail closed).

Usage:
  terraform show -json tfplan > plan.json
  python3 tools/terraform/iam_policy_validate.py plan.json [--allow tools/terraform/iam_policy_validate_allow.json]
                                                          [--summary $GITHUB_STEP_SUMMARY]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Optional

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(os.path.dirname(_HERE), "docs"))
from plan_guard import redact_address  # noqa: E402
from aws_mask import mask_text  # noqa: E402

DEFAULT_ALLOW = os.path.join(_HERE, "iam_policy_validate_allow.json")
AWS_PROVIDER = "registry.terraform.io/hashicorp/aws"
BLOCKING = ("ERROR", "SECURITY_WARNING")
_CHECKED_ACTIONS = frozenset({"create", "update"})

# type -> list of (attribute, policy type, validatePolicyResourceType or None)
DOCUMENTS: dict[str, list[tuple[str, str, Optional[str]]]] = {
    "aws_iam_policy": [("policy", "IDENTITY_POLICY", None)],
    "aws_iam_role_policy": [("policy", "IDENTITY_POLICY", None)],
    "aws_iam_user_policy": [("policy", "IDENTITY_POLICY", None)],
    "aws_iam_group_policy": [("policy", "IDENTITY_POLICY", None)],
    "aws_iam_role": [("assume_role_policy", "RESOURCE_POLICY", "AWS::IAM::AssumeRolePolicyDocument")],
    "aws_s3_bucket_policy": [("policy", "RESOURCE_POLICY", "AWS::S3::Bucket")],
    "aws_sns_topic_policy": [("policy", "RESOURCE_POLICY", None)],
    "aws_sqs_queue_policy": [("policy", "RESOURCE_POLICY", None)],
    "aws_kms_key": [("policy", "RESOURCE_POLICY", None)],
    "aws_secretsmanager_secret_policy": [("policy", "RESOURCE_POLICY", None)],
    "aws_ecr_repository_policy": [("policy", "RESOURCE_POLICY", None)],
    "aws_cloudwatch_log_resource_policy": [("policy_document", "RESOURCE_POLICY", None)],
}

Runner = Callable[[list[str]], str]


class InputError(Exception):
    """The plan, the allow file or the AWS call failed."""


@dataclass(frozen=True)
class Document:
    address: str
    attribute: str
    policy_type: str
    resource_type: Optional[str]
    text: Optional[str]  # None = known after apply


@dataclass
class Result:
    doc: Document
    findings: list[dict] = field(default_factory=list)


def aws_cli(args: list[str]) -> str:
    try:
        out = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True, check=True, timeout=120)
    except FileNotFoundError as e:
        raise InputError("aws CLI not found") from e
    except subprocess.CalledProcessError as e:
        # The message is masked: an AccessDenied names the role ARN.
        raise InputError(f"aws {' '.join(args[:2])} failed: {mask_text((e.stderr or '').strip()[:300])}") from e
    except subprocess.TimeoutExpired as e:
        raise InputError(f"aws {' '.join(args[:2])} timed out") from e
    return out.stdout


def _walk_modules(module: dict) -> Iterable[dict]:
    yield module
    for child in module.get("child_modules", []) or []:
        yield from _walk_modules(child)


def documents(plan: dict) -> list[Document]:
    """Every policy document of a created / updated resource, in plan order."""
    if not isinstance(plan, dict) or "resource_changes" not in plan:
        raise InputError("not a Terraform plan JSON (no resource_changes)")
    out: list[Document] = []
    for rc in plan.get("resource_changes") or []:
        if rc.get("mode") != "managed" or rc.get("provider_name") != AWS_PROVIDER:
            continue
        specs = DOCUMENTS.get(rc.get("type", ""))
        change = rc.get("change") or {}
        if not specs or not _CHECKED_ACTIONS.intersection(change.get("actions") or []):
            continue
        after = change.get("after") or {}
        unknown = change.get("after_unknown") or {}
        before = change.get("before") or {}
        for attr, ptype, rtype in specs:
            if unknown.get(attr) is True:
                out.append(Document(rc["address"], attr, ptype, rtype, None))
                continue
            text = after.get(attr)
            if not isinstance(text, str) or not text.strip():
                continue
            # An update that leaves this document as it was (tags only, for example) is not re-checked.
            if "update" in (change.get("actions") or []) and _same_json(before.get(attr), text):
                continue
            out.append(Document(rc["address"], attr, ptype, rtype, text))
    return out


def _same_json(a: Any, b: str) -> bool:
    if not isinstance(a, str):
        return False
    try:
        return json.loads(a) == json.loads(b)
    except ValueError:
        return a == b


def validate(doc: Document, run: Runner = aws_cli) -> list[dict]:
    """ValidatePolicy findings of one document (all pages)."""
    assert doc.text is not None
    args = ["accessanalyzer", "validate-policy", "--policy-type", doc.policy_type, "--policy-document", doc.text]
    if doc.resource_type:
        args += ["--validate-policy-resource-type", doc.resource_type]
    try:
        reply = json.loads(run(args) or "{}")
    except ValueError as e:
        raise InputError(f"{redact_address(doc.address)}: ValidatePolicy answer is not JSON") from e
    findings = reply.get("findings")
    if not isinstance(findings, list):
        raise InputError(f"{redact_address(doc.address)}: ValidatePolicy answer has no findings list")
    return findings


def load_allow(path: str) -> dict[tuple[str, str], str]:
    """(address, issueCode) -> reason. A row without a reason is refused."""
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise InputError(f"{path}: {e}") from e
    allow: dict[tuple[str, str], str] = {}
    for row in data.get("allow", []):
        addr, code, reason = row.get("address"), row.get("issueCode"), (row.get("reason") or "").strip()
        if not addr or not code or len(reason) < 20:
            raise InputError(f"{path}: every allow row needs address, issueCode and a reason of 20+ characters")
        allow[(addr, code)] = reason
    return allow


def blocking(results: list[Result], allow: dict[tuple[str, str], str]) -> list[tuple[Document, dict]]:
    out = []
    for r in results:
        for f in r.findings:
            if f.get("findingType") in BLOCKING and (r.doc.address, f.get("issueCode", "")) not in allow:
                out.append((r.doc, f))
    return out


def _finding_line(doc: Document, f: dict) -> str:
    detail = mask_text(str(f.get("findingDetails", "")).replace("\n", " ").replace("|", "/"))[:300]
    return f"| `{redact_address(doc.address)}` | {doc.attribute} | {f.get('findingType', '')} | {f.get('issueCode', '')} | {detail} |"


def render(results: list[Result], skipped: list[Document], blocked: list[tuple[Document, dict]],
           allow: dict[tuple[str, str], str]) -> str:
    lines = ["## IAM Access Analyzer policy validation", ""]
    lines.append(f"{len(results)} policy documents checked, {len(skipped)} known only after apply, "
                 f"{len(blocked)} blocking findings.")
    rows = [(r.doc, f) for r in results for f in r.findings]
    if rows:
        lines += ["", "| Resource | Attribute | Type | Issue | Detail |", "|---|---|---|---|---|"]
        for doc, f in rows:
            line = _finding_line(doc, f)
            if (doc.address, f.get("issueCode", "")) in allow:
                line = line[:-2] + " (allowed: " + mask_text(allow[(doc.address, f.get("issueCode", ""))])[:120] + ") |"
            lines.append(line)
    if skipped:
        lines += ["", "Not checked (known after apply):"]
        lines += [f"- `{redact_address(d.address)}` {d.attribute}" for d in skipped]
    return "\n".join(lines) + "\n"


def main(argv: Optional[list[str]] = None, *, run: Runner = aws_cli) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("plan")
    p.add_argument("--allow", default=DEFAULT_ALLOW)
    p.add_argument("--summary")
    args = p.parse_args(argv)
    try:
        with open(args.plan, encoding="utf-8") as f:
            plan = json.load(f)
        allow = load_allow(args.allow)
        docs = documents(plan)
        skipped = [d for d in docs if d.text is None]
        results = [Result(d, validate(d, run)) for d in docs if d.text is not None]
    except (OSError, ValueError, InputError) as e:
        print(f"iam_policy_validate: {e}", file=sys.stderr)
        return 2
    blocked = blocking(results, allow)
    text = render(results, skipped, blocked, allow)
    print(text)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as f:
            f.write(text)
    for doc, f in blocked:
        print(f"::error title=IAM policy {f.get('findingType')}::{redact_address(doc.address)} {doc.attribute}: "
              f"{f.get('issueCode')} (allow file: {os.path.relpath(args.allow)})", file=sys.stderr)
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
