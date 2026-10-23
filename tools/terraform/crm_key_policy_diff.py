#!/usr/bin/env python3
"""Nightly CRM KMS key-policy diff (AA-932, design v3 §4.1 "a nightly GetKeyPolicy diff").

Compares the live key policy of each AA-Partner (CRM) KMS key (aws_kms_key.crm_data, crm_ingest, crm_seal in
accounts/aa365/crm_data.tf) with the policy Terraform last applied (the state of accounts/aa365). Both sides are
normalised first (statement order, list order, single value vs one-element list), so only a real change counts.

Why the state and not the code: a merged-but-not-applied PR is not drift; a PutKeyPolicy outside Terraform (Console,
CLI, a script) is. Every PutKeyPolicy also fires the aa-crm-<env>-kms-key-admin alarm at once; this check catches what
the alarm cannot: an alarm e-mail nobody read, or a rule that was itself changed.

Read-only: GetKeyPolicy through the AWS CLI (the runner's CLI v2; no boto3 next to the credentials), nothing is
written. Output names keys by their Terraform name (data, ingest, seal) and statements by Sid only, never ARNs or
account ids (public repo logs).

Exit codes:
  0  every key in the state matches its live policy (keys not in the state yet are reported and skipped)
  1  drift: at least one key's live policy differs (the differing Sids are listed)
  2  bad input or a failed read (state not JSON, GetKeyPolicy refused or missing key): fail closed

Usage:
  terraform -chdir=accounts/aa365 show -json > state.json
  python3 tools/terraform/crm_key_policy_diff.py --state state.json --region us-west-1 [--summary $GITHUB_STEP_SUMMARY]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from typing import Callable, Iterator, Optional

KEY_RESOURCES = {"crm_data": "data", "crm_ingest": "ingest", "crm_seal": "seal"}
_LIST_FIELDS = ("Action", "NotAction", "Resource", "NotResource")


class InputError(Exception):
    """The state cannot be read, or a live policy cannot be fetched."""


def _as_sorted_list(value: object) -> list:
    items = value if isinstance(value, list) else [value]
    return sorted(items, key=lambda v: json.dumps(v, sort_keys=True))


def _norm_statement(stmt: dict) -> dict:
    out = {}
    for k, v in stmt.items():
        if k in _LIST_FIELDS:
            out[k] = _as_sorted_list(v)
        elif k in ("Principal", "NotPrincipal"):
            out[k] = v if isinstance(v, str) else {t: _as_sorted_list(p) for t, p in sorted(v.items())}
        elif k == "Condition":
            out[k] = {op: {ck: _as_sorted_list(cv) for ck, cv in sorted(keys.items())}
                      for op, keys in sorted(v.items())}
        else:
            out[k] = v
    return out


def normalize(policy: str | dict) -> dict:
    """Canonical form of a key policy: {"Version": ..., "Statement": {sid: statement}}."""
    doc = json.loads(policy) if isinstance(policy, str) else policy
    if not isinstance(doc, dict):
        raise InputError("policy is not a JSON object")
    stmts = doc.get("Statement", [])
    if isinstance(stmts, dict):
        stmts = [stmts]
    by_sid: dict[str, dict] = {}
    for i, s in enumerate(stmts):
        n = _norm_statement(s)
        sid = str(s.get("Sid") or f"<no Sid #{i}>")
        if sid in by_sid:
            sid = f"{sid} #{i}"
        by_sid[sid] = n
    return {"Version": doc.get("Version"), "Statement": by_sid}


def diff(expected: str | dict, live: str | dict) -> list[str]:
    """Human lines naming what differs (Sids only, never statement content)."""
    a, b = normalize(expected), normalize(live)
    out = []
    if a["Version"] != b["Version"]:
        out.append("Version differs")
    for sid in sorted(set(a["Statement"]) - set(b["Statement"])):
        out.append(f"statement {sid}: in Terraform, missing live")
    for sid in sorted(set(b["Statement"]) - set(a["Statement"])):
        out.append(f"statement {sid}: live only (not in Terraform)")
    for sid in sorted(set(a["Statement"]) & set(b["Statement"])):
        if a["Statement"][sid] != b["Statement"][sid]:
            out.append(f"statement {sid}: content differs")
    return out


def _resources(module: dict) -> Iterator[dict]:
    yield from module.get("resources", []) or []
    for child in module.get("child_modules", []) or []:
        yield from _resources(child)


def state_policies(state: dict) -> dict[str, dict]:
    """{data|ingest|seal: {"key_id": ..., "policy": ...}} for the CRM keys in a `terraform show -json` state."""
    if not isinstance(state, dict) or "format_version" not in state:
        raise InputError("not a Terraform state JSON (no format_version); use `terraform show -json`")
    root = (state.get("values") or {}).get("root_module")
    if root is None:
        return {}  # empty state
    found = {}
    for r in _resources(root):
        if r.get("mode") == "managed" and r.get("type") == "aws_kms_key" and r.get("name") in KEY_RESOURCES \
                and r.get("address", "").startswith("aws_kms_key."):
            vals = r.get("values") or {}
            if not vals.get("key_id") or not vals.get("policy"):
                raise InputError(f"{r.get('address')}: key_id or policy missing in the state")
            found[KEY_RESOURCES[r["name"]]] = {"key_id": vals["key_id"], "policy": vals["policy"]}
    return found


def aws_cli_fetch(region: str) -> Callable[[str], str]:
    def fetch(key_id: str) -> str:
        cmd = ["aws", "kms", "get-key-policy", "--key-id", key_id, "--policy-name", "default",
               "--region", region, "--query", "Policy", "--output", "text"]
        res = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if res.returncode != 0:
            # The CLI error names the key ARN (account id): report only the error code.
            code = next((w.strip("()") for w in res.stderr.split() if w.startswith("(") and w.endswith(")")),
                        "unknown error")
            raise InputError(f"GetKeyPolicy failed: {code}")
        return res.stdout
    return fetch


def run(state: dict, fetch: Callable[[str], str]) -> tuple[str, int]:
    keys = state_policies(state)
    lines, drift = [], False
    for name in ("data", "ingest", "seal"):
        if name not in keys:
            lines.append(f"- `{name}`: not in the Terraform state (not applied yet), skipped")
            continue
        try:
            live = fetch(keys[name]["key_id"])
        except InputError as exc:
            raise InputError(f"{name}: {exc}") from exc
        problems = diff(keys[name]["policy"], live)
        if problems:
            drift = True
            lines.append(f"- `{name}`: **DRIFT**")
            lines.extend(f"  - {p}" for p in problems)
        else:
            lines.append(f"- `{name}`: live policy = Terraform state")
    if drift:
        head = ("CRM key-policy diff: DRIFT. A CRM key policy was changed outside Terraform. Treat it as an incident "
                "(root docs/ops/runbooks/crm-keys.md, 'Nightly key-policy diff is red').")
    else:
        head = "CRM key-policy diff: OK."
    return head + "\n" + "\n".join(lines), 1 if drift else 0


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--state", required=True, help="output of `terraform show -json` for accounts/aa365")
    ap.add_argument("--region", default="us-west-1")
    ap.add_argument("--summary", help="append the report to this file (e.g. $GITHUB_STEP_SUMMARY)")
    args = ap.parse_args(argv)
    try:
        with open(args.state, encoding="utf-8") as fh:
            state = json.load(fh)
        text, code = run(state, aws_cli_fetch(args.region))
    except (OSError, json.JSONDecodeError) as exc:
        text, code = f"CRM key-policy diff: ERROR, cannot read the state ({type(exc).__name__}). Fail closed.", 2
    except InputError as exc:
        text, code = f"CRM key-policy diff: ERROR, {exc}. Fail closed.", 2
    print(text, file=sys.stderr if code else sys.stdout)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write("### CRM key-policy diff\n\n" + text + "\n\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
