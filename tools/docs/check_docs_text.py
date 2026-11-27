#!/usr/bin/env python3
"""Line checks for docs and agent instructions (AA-888). Stdlib only.

aws-multiline   An `aws ...` command line that ends with a backslash continuation. Multi-line
                AWS CLI hangs in WSL2 (global rule); every AWS CLI command is one line.
                Scope: docs/**, skill/**, .kiro/steering/**, .kiro/specs/**, .claude/**, minus journals.
                Always an error.

resource-ids    Literal AWS resource IDs in prose: sg-/subnet-/vpc-/... IDs, standalone
                12-digit account IDs, ARNs with an account, Cognito user-pool IDs, API Gateway
                hostnames (docs/STYLE.md, "Resource IDs"). Scope: docs/** minus journals,
                templates excepted, the onboarding account map and generated pages.
                --mode error on the docs pages of every repo (all public, AA-1185); --mode warn
                for agent files (.claude, skills) that only their owner rewrites.
                --block KINDS keeps those kinds failing in warn mode.
                Kinds: vpc, elb (a load balancer or target group id, app/<name>/<16 hex>;
                AA-1118, S282 audit R26), arn, user-pool, apigw, account, mail (an e-mail address outside the
                company and test domains, AA-1185).

retired-phrases  A phrase that describes something retired as if it were live, or a fact that is no
                longer true (AA-1134, the S283 docs audit, AA-1118): "acc3 only" LLM serving, Bedrock
                or "the LLM account" on acc3 alone, acc1 "removed from the ecosystem" without its
                S278 Bedrock role, a `develop` branch, `:latest` image tags, Vercel previews, the
                `portal/` copy and aa-crm-dev-portal, the retired Booking kind bk_inquiry_pull, 7-day
                Dev RDS backups. For most phrases a line that says the thing is gone (retired,
                removed, no longer, was, ...) is history and passes; a phrase whose own words are
                history-like (acc1 removed) instead passes when the line or the next lines state
                today's fact (its `allow` words). Scope: docs/**, skill/**, .kiro/steering/**,
                .claude/**, minus journals, generated pages, ADRs, exported Linear issues and
                archived pages (records keep their words). --scope DIR narrows it (the docs lint runs
                --scope docs --mode error and the agent files with --mode warn).

--all scans every tracked .md file of the repo (minus journals) instead of the check's
default scope. --scope DIR (repeatable) scans the tracked .md files under DIR instead; the docs
lint runs `resource-ids --mode error --scope .kiro/specs`: specs ship in the public app repos
(AA-1137), so an ID there fails even in the root repo, where docs pages only warn. The app and Infra repos keep their pages at the repo root and in docs/, so
their docs-lint workflows pass --all; the root repo keeps the narrower default scope.

Add `docs-lint: ignore` (for example in an HTML comment) to a line to skip it.

Usage:
  python tools/docs/check_docs_text.py aws-multiline
  python tools/docs/check_docs_text.py aws-multiline --all
  python tools/docs/check_docs_text.py resource-ids --mode warn
  python tools/docs/check_docs_text.py resource-ids --all --mode warn --block vpc,apigw
  python tools/docs/check_docs_text.py resource-ids --mode error --scope .kiro/specs
  python tools/docs/check_docs_text.py resource-ids --mode error path/to/file.md ...
  python tools/docs/check_docs_text.py retired-phrases --mode warn
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import NamedTuple

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

AWS_SCOPE = ["docs", "skill", ".kiro/steering", ".kiro/specs", ".claude"]
ID_SCOPE = ["docs"]
RETIRED_SCOPE = AWS_SCOPE



class RetiredPhrase(NamedTuple):
    """A phrase that is wrong today. `truth` is what runs instead. With `history_ok` a line that says the thing is gone
    (RETIRED_HISTORY) passes; `allow` (checked on the line and the next ALLOW_WINDOW lines) passes a line whose
    paragraph states today's fact or negates the phrase ("no `develop` branch")."""

    pattern: re.Pattern[str]
    truth: str
    history_ok: bool = True
    allow: re.Pattern[str] | None = None


ACC1_TRUTH = ("acc1 serves Bedrock first since S278 (AA-1095); acc3 is the fallback behind it (root ADR 0001a, "
              "Note S278).")
# Update this list when an ADR retires something that docs keep describing (docs/STYLE.md); derive each entry from
# CONTEXT.md / CLAUDE.md facts and fix the hits in the same PR.
RETIRED_PHRASES: list[RetiredPhrase] = [
    RetiredPhrase(re.compile(r"(?i)(?<!and )\bacc3[- ]only\b|\bonly (?:on )?acc3\b|\bacc3 is the only\b"), ACC1_TRUTH),
    # AA-1118: Bedrock / the LLM account named as acc3 alone. A paragraph that also names acc1 or the fallback passes.
    RetiredPhrase(
        re.compile(r"(?i)\b(?:Bedrock|LLMs?|model calls?|AI models?|chat models?)\b[^.|;]{0,25}\b(?:on|in) acc3\b|"
                   r"\bthe LLM account \(acc3\)|\bLLM account \(acc3\)"),
        ACC1_TRUTH, history_ok=False,
        allow=re.compile(r"(?i)S278|AA-1095|fallback|behind (?:it|acc1)|\bacc1 (?:first|serves|and acc3|then acc3)|"
                         r"\bacc1 *(?:\+|/|->|→) *acc3")),
    # AA-1118: "acc1 was removed from the ecosystem" without its S278 exception reads as "acc1 does nothing".
    RetiredPhrase(
        # the sentence may wrap: "... no longer part of" / "the ecosystem" on the next line
        re.compile(r"(?i)\bacc1\b[^.;|]{0,40}\b(?:(?:is no longer part of|was removed from|removed from|left) the "
                   r"ecosystem|(?:no longer part of|removed from)(?: the)?\s*$)"),
        "acc1 left the ecosystem with AA-998 but serves Bedrock first since S278 (AA-1095, root ADR 0001a Note "
        "S278): say both.", history_ok=False,
        allow=re.compile(r"(?i)S278|AA-1095|serves? (?:the )?(?:Amazon )?Bedrock|Bedrock (?:LLM )?serving|since "
                         r"2026-11-12|12/11/2026")),
    # AA-1118: trunk-based (ADR-2026-023): branches start from origin/main (root: master); there is no develop.
    RetiredPhrase(
        re.compile(r"(?i)`develop`|\bdevelop branch\b|\borigin/develop\b|\b(?:in)?to develop\b"),
        "There is no develop branch: trunk-based, branches from origin/main (root repo: master) (ADR-2026-023).",
        history_ok=False,
        allow=re.compile(r"(?i)\bno\b|\bnot\b|\bnever\b|\bwithout\b|không|trunk")),
    # AA-1118: ECR repositories are IMMUTABLE and deploys use dev-<git sha> / git SHA tags (AA-869).
    RetiredPhrase(
        re.compile(r"[\w./-]*:latest(?![\w-])"),
        "ECR tags are immutable git-SHA tags (dev-<sha> for CIS, the SHA for Booking; AA-869); never :latest.",
        history_ok=False,
        allow=re.compile(r"(?i)\bno\b|\bnot\b|\bnever\b|\bwithout\b|\bimmutable\b|instead of|\bavoid|không")),
    RetiredPhrase(re.compile(r"(?i)\bVercel preview"),
                  "There are no Vercel previews: the frontends run on ECS (AA-911, AA-1038, AA-979) and the UI smoke "
                  "runs after the ECS deploy."),
    RetiredPhrase(re.compile(r"(?:AA-Partner|AA-CIS-App)/portal/|`portal/`|\baa-crm-dev-portal\b"),
                  "The tenant portal lives in the CRM web since AA-1036 R3 (service aa-crm-dev-web, host portal.); "
                  "the CIS portal/ copy was deleted at P2b."),
    RetiredPhrase(re.compile(r"\bbk_inquiry_pull\b"),
                  "The Booking B2C inquiry kinds are retired (AA-1046, root ADR 0019 d8/d11)."),
    # RDS backups only: the tenant export prefixes really are kept 7 days (bucket rule exports-expire).
    RetiredPhrase(re.compile(r"(?i)\b(?:7|seven)[- ]days?\b[^.|;]{0,40}\b(?:PITR|(?:automated|RDS) backups?)\b|"
                             r"\b(?:PITR|(?:automated|RDS) backups?)\b[^.|;*]{0,40}\b(?:7|seven)[- ]days?\b"),
                  "Dev RDS backups are kept 14 days (root ADR 0019 d16)."),
]
# allow words count on the matched line and this many lines after it (a paragraph wraps at 120 characters).
ALLOW_WINDOW = 3
# Records, not living pages: an ADR keeps the words of its decision (amendments say what changed), exported Linear
# issues and archived pages are history.
RETIRED_SKIP_PREFIXES = ("docs/adr/", "docs/linear-export/", "docs/archive/", "docs/ops/postmortems/2",
                         "docs/architecture/ecosystem-review-2026-09.md", "docs/architecture/db-schema-reference.md")
# A line that says the thing is gone is history, not a stale claim.
RETIRED_HISTORY = re.compile(
    r"(?i)\b(?:retired?|retiring|removed|no longer|was|were|gone|dropped|deleted|replaced|formerly|former|"
    r"used to|until|before|instead of|not any more|anymore)\b")

# `aws <service> ...` at a command position (line start, after $( | ; & = or a list marker),
# with the line ending in a backslash continuation.
AWS_MULTILINE = re.compile(r"(?:^|[\s(|;&=`])aws\s+[a-z][a-z0-9-]*\b.*\\\s*$")

_HEX_ID = r"[0-9a-f]{8}(?:[0-9a-f]{9})?"
# (label, pattern); KIND_KEYS gives each label the short key that --block takes.
RESOURCE_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("VPC resource ID",
     re.compile(rf"(?<![\w-])(?:sg|subnet|vpc|vpce|rtb|igw|nat|eni|acl|eipalloc|tgw)-{_HEX_ID}(?![\w-])")),
    # The name stays readable, the 16-hex id is the identifier (Infra tools/docs/aws_mask.py masks it as {masked}).
    ("Load balancer or target group ID",
     re.compile(r"(?<![\w-])(?:app|net|gwy|targetgroup)/[A-Za-z0-9-]{1,32}/[0-9a-f]{16}(?![\w-])")),
    ("ARN with account ID", re.compile(r"arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:\d{12}:")),
    ("Cognito user-pool ID", re.compile(r"(?<![\w-])[a-z]{2}-[a-z]+-\d_[A-Za-z0-9]{9}(?![\w-])")),
    ("API Gateway host", re.compile(r"(?<![\w-])[a-z0-9]{10}\.execute-api\.")),
    # Standalone only: a bucket name that embeds the account ID by convention
    # (aa-cis-bronze-<account>) is allowed by the style guide, so a leading '-' or word char skips it.
    ("12-digit account ID", re.compile(r"(?<![\w./:-])\d{12}(?![\w-])")),
    # AA-1185 (S295 audit SA-40): an e-mail address outside the company and test domains (a personal mailbox such as
    # an AWS root address, or a vendor's staff address). Only common real TLDs, so code like `@router.get` passes.
    ("Outside e-mail address", re.compile(
        r"(?<![\w.%+-])[A-Za-z0-9._%+-]+@(?!(?:[A-Za-z0-9-]+\.)*(?:adventure\.asia|lumiguides\.it\.com|"
        r"example\.(?:com|org|net)|anthropic\.com|users\.noreply\.github\.com)(?![\w.-]))"
        r"(?:[A-Za-z0-9-]+\.)+(?:com|net|org|asia|io|vn|sg|co|uk|me|ai)(?![\w-])", re.I)),
]
KIND_KEYS = {
    "VPC resource ID": "vpc",
    "Load balancer or target group ID": "elb",
    "ARN with account ID": "arn",
    "Cognito user-pool ID": "user-pool",
    "API Gateway host": "apigw",
    "12-digit account ID": "account",
    "Outside e-mail address": "mail",
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
                    hint = ("write the role instead (the reseller's account manager, the acc2 root mailbox)"
                            if KIND_KEYS[label] == "mail" else
                            "use the resource name, a Terraform output or a link to the account map in docs/onboarding.md")
                    findings.append(Finding(
                        relpath, n, "Literal resource ID",
                        f"{label} '{m.group(0)}' in prose; {hint}.",
                        kind=KIND_KEYS[label],
                    ))
                    break
    return findings


def _retired_hit(lines: list[str], n: int) -> tuple[str, RetiredPhrase] | None:
    """The first retired phrase line n (1-based) states as live, with the text it matched, or None."""
    line = lines[n - 1]
    history = bool(RETIRED_HISTORY.search(line)) or "~~" in line  # struck-through items are closed
    for phrase in RETIRED_PHRASES:
        if history and phrase.history_ok:
            continue
        m = phrase.pattern.search(line)
        if m and not (phrase.allow and phrase.allow.search(" ".join(lines[n - 1:n + ALLOW_WINDOW]))):
            return m.group(0), phrase
    return None


def check_retired_phrases(root: Path, files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for relpath in files:
        if relpath.startswith(RETIRED_SKIP_PREFIXES):
            continue
        text, lines = _lines(root, relpath)
        if is_generated(text):
            continue
        fenced = False
        for n, line in enumerate(lines, 1):
            if line.lstrip().startswith("```"):
                fenced = not fenced
                continue
            hit = None if fenced or IGNORE_MARKER in line else _retired_hit(lines, n)
            if hit:
                findings.append(Finding(relpath, n, "Retired phrase",
                                        f"'{hit[0]}' describes a retired thing as live. {hit[1].truth}",
                                        kind="retired"))
    return findings


def _select(root: Path, scope: list[str], explicit: list[str]) -> list[str]:
    files = explicit or list_markdown(scope, root)
    return [f for f in files if f.endswith(".md") and not is_journal(f)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("check", choices=["aws-multiline", "resource-ids", "retired-phrases"])
    parser.add_argument("files", nargs="*", help="repo-relative files (default: the check's scope)")
    parser.add_argument("--mode", choices=["warn", "error"], default="error")
    parser.add_argument("--block", type=_kinds, default=set(),
                        help="resource-ids: comma-separated kinds that fail even with --mode warn ("
                        + ", ".join(KIND_KEYS.values()) + ")")
    parser.add_argument("--all", action="store_true", help="scan every tracked .md file (minus journals)")
    parser.add_argument("--scope", action="append", default=[],
                        help="repo-relative folder to scan instead of the default scope (repeatable)")
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    args = parser.parse_intermixed_args(argv)
    root = args.root.resolve()

    if args.check == "aws-multiline":
        files = _select(root, ["."] if args.all else args.scope or AWS_SCOPE, args.files)
        findings = check_aws_multiline(root, files)
        errors, warnings = findings, []
    elif args.check == "retired-phrases":
        files = _select(root, ["."] if args.all else args.scope or RETIRED_SCOPE, args.files)
        findings = check_retired_phrases(root, files)
        errors, warnings = (findings, []) if args.mode == "error" else ([], findings)
    else:
        files = _select(root, ["."] if args.all else args.scope or ID_SCOPE, args.files)
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
