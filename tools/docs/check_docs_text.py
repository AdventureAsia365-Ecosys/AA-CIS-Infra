#!/usr/bin/env python3
"""Line checks for docs and agent instructions (AA-888). Stdlib only.

aws-multiline   An `aws ...` command line that ends with a backslash continuation. Multi-line
                AWS CLI hangs in WSL2 (global rule); every AWS CLI command is one line.
                Scope: docs/**, skill/**, .kiro/steering/**, .claude/**, minus journals.
                Always an error.

resource-ids    Literal AWS resource IDs in prose: sg-/subnet-/vpc-/... IDs, standalone
                12-digit account IDs, ARNs with an account, Cognito user-pool IDs, API Gateway
                hostnames (docs/STYLE.md, "Resource IDs"). Scope: docs/** minus journals,
                templates excepted, the onboarding account map and generated pages.
                --mode warn (root and Infra, private) or --mode error (public repos).
                --block vpc,apigw keeps those kinds failing in warn mode (Infra: no VPC
                resource ID or API Gateway host in any page; ARNs and account IDs warn).
                Kinds: vpc, arn, user-pool, apigw, account.

--all scans every tracked .md file of the repo (minus journals) instead of the check's
default scope. The app and Infra repos keep their pages at the repo root and in docs/, so
their docs-lint workflows pass --all; the root repo keeps the narrower default scope.

Add `docs-lint: ignore` (for example in an HTML comment) to a line to skip it.

Usage:
  python tools/docs/check_docs_text.py aws-multiline
  python tools/docs/check_docs_text.py aws-multiline --all
  python tools/docs/check_docs_text.py resource-ids --mode warn
  python tools/docs/check_docs_text.py resource-ids --all --mode warn --block vpc,apigw
  python tools/docs/check_docs_text.py resource-ids --mode error path/to/file.md ...
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from docslib import (
    IGNORE_MARKER,
    REPO_ROOT,
    RESOURCE_ID_EXEMPT_FILES,
    Finding,
    emit,
    is_generated,
    is_journal,
    list_markdown,
)

AWS_SCOPE = ["docs", "skill", ".kiro/steering", ".claude"]
ID_SCOPE = ["docs"]

# `aws <service> ...` at a command position (line start, after $( | ; & = or a list marker),
# with the line ending in a backslash continuation.
AWS_MULTILINE = re.compile(r"(?:^|[\s(|;&=`])aws\s+[a-z][a-z0-9-]*\b.*\\\s*$")

_HEX_ID = r"[0-9a-f]{8}(?:[0-9a-f]{9})?"
# (label, pattern); KIND_KEYS gives each label the short key that --block takes.
RESOURCE_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("VPC resource ID",
     re.compile(rf"(?<![\w-])(?:sg|subnet|vpc|vpce|rtb|igw|nat|eni|acl|eipalloc|tgw)-{_HEX_ID}(?![\w-])")),
    ("ARN with account ID", re.compile(r"arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:\d{12}:")),
    ("Cognito user-pool ID", re.compile(r"(?<![\w-])[a-z]{2}-[a-z]+-\d_[A-Za-z0-9]{9}(?![\w-])")),
    ("API Gateway host", re.compile(r"(?<![\w-])[a-z0-9]{10}\.execute-api\.")),
    # Standalone only: a bucket name that embeds the account ID by convention
    # (aa-cis-bronze-<account>) is allowed by the style guide, so a leading '-' or word char skips it.
    ("12-digit account ID", re.compile(r"(?<![\w./:-])\d{12}(?![\w-])")),
]
KIND_KEYS = {
    "VPC resource ID": "vpc",
    "ARN with account ID": "arn",
    "Cognito user-pool ID": "user-pool",
    "API Gateway host": "apigw",
    "12-digit account ID": "account",
}


def _lines(root: Path, relpath: str):
    text = (root / relpath).read_text(encoding="utf-8")
    return text, text.splitlines()


def check_aws_multiline(root: Path, files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for relpath in files:
        _, lines = _lines(root, relpath)
        for n, line in enumerate(lines, 1):
            if IGNORE_MARKER in line:
                continue
            if AWS_MULTILINE.search(line):
                findings.append(Finding(
                    relpath, n, "Multi-line AWS CLI",
                    "AWS CLI command continues with a backslash; write it on one line with "
                    "--profile and --region (multi-line commands hang WSL2).",
                ))
    return findings


def check_resource_ids(root: Path, files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for relpath in files:
        if relpath in RESOURCE_ID_EXEMPT_FILES:
            continue
        text, lines = _lines(root, relpath)
        if is_generated(text):
            continue
        for n, line in enumerate(lines, 1):
            if IGNORE_MARKER in line:
                continue
            for label, pattern in RESOURCE_PATTERNS:
                m = pattern.search(line)
                if m:
                    findings.append(Finding(
                        relpath, n, "Literal resource ID",
                        f"{label} '{m.group(0)}' in prose; use the resource name, a Terraform output "
                        "or a link to the account map in docs/onboarding.md.",
                        kind=KIND_KEYS[label],
                    ))
                    break
    return findings


def _select(root: Path, scope: list[str], explicit: list[str]) -> list[str]:
    files = explicit or list_markdown(scope, root)
    return [f for f in files if f.endswith(".md") and not is_journal(f)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("check", choices=["aws-multiline", "resource-ids"])
    parser.add_argument("files", nargs="*", help="repo-relative files (default: the check's scope)")
    parser.add_argument("--mode", choices=["warn", "error"], default="error")
    parser.add_argument("--block", type=_kinds, default=set(),
                        help="resource-ids: comma-separated kinds that fail even with --mode warn ("
                        + ", ".join(KIND_KEYS.values()) + ")")
    parser.add_argument("--all", action="store_true", help="scan every tracked .md file (minus journals)")
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    args = parser.parse_intermixed_args(argv)
    root = args.root.resolve()

    if args.check == "aws-multiline":
        files = _select(root, ["."] if args.all else AWS_SCOPE, args.files)
        findings = check_aws_multiline(root, files)
        errors, warnings = findings, []
    else:
        files = _select(root, ["."] if args.all else ID_SCOPE, args.files)
        findings = check_resource_ids(root, files)
        if args.mode == "error":
            errors, warnings = findings, []
        else:
            errors = [f for f in findings if f.kind in args.block]
            warnings = [f for f in findings if f.kind not in args.block]

    emit(errors, "error")
    emit(warnings, "warning")
    print(f"{args.check}: {len(files)} files checked, {len(errors)} errors, {len(warnings)} warnings")
    return 1 if errors else 0


def _kinds(value: str) -> set[str]:
    kinds = {k.strip() for k in value.split(",") if k.strip()}
    unknown = kinds - set(KIND_KEYS.values())
    if unknown:
        raise argparse.ArgumentTypeError(
            f"unknown kind(s) {', '.join(sorted(unknown))}; use {', '.join(KIND_KEYS.values())}")
    return kinds


if __name__ == "__main__":
    sys.exit(main())
