#!/usr/bin/env python3
"""Mask AWS account ids, ARNs and EC2 resource ids in generated docs (AA-981, S248 decision d15).

The root repo (AA-Ecosys) and this repo are public for now, and the generated pages they publish
(root docs/generated/*.md from tools/docs/gen_docs.py + gen_env_config.py, root
docs/architecture/db-schema-reference.md from db/gen_schema_reference.py) used to print account ids
and full ARNs. Every generator now passes its output through `mask_text`, and its tests assert
`find_leaks(page) == []`.

What is masked:
  * a 12-digit AWS account id -> `{acc2}` (the label from the alias table) or `{aws-account}` when the
    id is not in the table. The label is written in braces, not angle brackets: `<acc2>` in a Markdown
    table cell outside a code span is raw HTML and GitHub drops it.
  * an ARN -> `arn:{partition}:<service>:<region>:<account label>:<resource>`: the service, region and
    resource (type and name) stay readable, the partition and the account do not. A Secrets Manager
    ARN also loses its random 6-character suffix (`secret:booking/dev/database-url-AbC123` ->
    `secret:booking/dev/database-url`). `arn:aws:iam::aws:policy/...` (AWS managed) keeps `aws`
    as its account field.
  * an EC2 / VPC resource id (vpc-, subnet-, sg-, rtb-, igw-, eni-, i-, nat-, eipalloc-, vpce-, acl-,
    pl-) -> `<prefix>-{masked}`. Pages keep the Name column next to it.
UUIDs are left alone (their last group can be 12 digits, e.g. the AA master tenant id).

Alias table: env AWS_ACCOUNT_ALIASES = "acc1=<id>,acc2=<id>,acc3=<id>" (comma, space or newline
separated). The ids are never written in this repo: the docs-gen workflow builds the value from the
optional repo secret AWS_ACCOUNT_ALIASES plus acc2 read from `sts get-caller-identity` at run time
(masked in the log). Without it every id renders as `{aws-account}`: still masked, just less precise.

Masking does not rewrite git history: values committed before AA-981 stay in the history of both
repos. Account ids are not secrets (AWS); the point is less reconnaissance help in a public repo.

CLI (stdlib only):
  python3 tools/docs/aws_mask.py check FILE...      exit 1 and list every leak (12-digit id, arn:aws:)
  python3 tools/docs/aws_mask.py rewrite FILE...    mask the files in place; a page that carries a
                                                    `docs-fingerprint` comment (gen_docs.py pages) gets
                                                    the fingerprint of its masked body
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
from pathlib import Path
from typing import Mapping, Optional

ENV_VAR = "AWS_ACCOUNT_ALIASES"
UNKNOWN_LABEL = "aws-account"
LABEL_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
ACCOUNT_ID_RE = re.compile(r"^\d{12}$")

UUID = r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
# An ARN runs until whitespace, a quote, a backtick, a Markdown table pipe, a comma or a closing bracket.
ARN = r"arn:(?P<partition>aws(?:-[a-z]+)*):(?P<service>[A-Za-z0-9-]+):(?P<region>[A-Za-z0-9-]*):(?P<account>[A-Za-z0-9-]*):(?P<resource>[^\s\"'`|,)\]}<>]+)"
ACCOUNT = r"(?<![0-9A-Za-z])(?P<id>\d{12})(?![0-9A-Za-z])"
TOKEN_RE = re.compile(f"(?P<uuid>{UUID})|(?P<arn>{ARN})|{ACCOUNT}")
SECRET_SUFFIX_RE = re.compile(r"-[A-Za-z0-9]{6}$")
EC2_ID_RE = re.compile(r"\b(?P<prefix>vpc|subnet|sg|rtb|igw|eni|i|nat|eipalloc|vpce|acl|pl)-(?:[0-9a-f]{17}|[0-9a-f]{8})\b")

LEAK_ID_RE = re.compile(r"\b\d{12}\b")
UUID_RE = re.compile(UUID)
LEAK_ARN = "arn:aws:"
FINGERPRINT_RE = re.compile(r"<!-- docs-fingerprint: ([0-9a-f]{64}) -->\n")


class AliasError(ValueError):
    """AWS_ACCOUNT_ALIASES is malformed (fail closed: never guess a mapping)."""


def parse_aliases(spec: Optional[str]) -> dict[str, str]:
    """'acc1=<id>,acc2=<id>' -> {id: label}."""
    out: dict[str, str] = {}
    for item in re.split(r"[,\s]+", (spec or "").strip()):
        if not item:
            continue
        label, sep, acct = item.partition("=")
        label, acct = label.strip(), acct.strip()
        if not sep or not LABEL_RE.match(label) or not ACCOUNT_ID_RE.match(acct):
            # Never echo the item: it may hold an id.
            raise AliasError(f"{ENV_VAR}: every entry must be <label>=<12-digit id> (label: lower case, digits, '-')")
        out[acct] = label
    return out


def load_aliases(env: Optional[Mapping[str, str]] = None) -> dict[str, str]:
    return parse_aliases((os.environ if env is None else env).get(ENV_VAR))


def _label(acct: str, aliases: Mapping[str, str]) -> str:
    return "{" + aliases.get(acct, UNKNOWN_LABEL) + "}"


def _mask_arn(m: re.Match, aliases: Mapping[str, str]) -> str:
    service, region, account, resource = m.group("service"), m.group("region"), m.group("account"), m.group("resource")
    if ACCOUNT_ID_RE.match(account):
        account = _label(account, aliases)
    elif account and account != "aws":
        account = "{" + UNKNOWN_LABEL + "}"
    if service == "secretsmanager" and resource.startswith("secret:"):
        resource = SECRET_SUFFIX_RE.sub("", resource)
    # The resource part may embed another id (an ECR host, an S3 bucket name with the account suffix).
    resource = TOKEN_RE.sub(lambda x: _replace(x, aliases), resource)
    return f"arn:{{partition}}:{service}:{region}:{account}:{resource}"


def _replace(m: re.Match, aliases: Mapping[str, str]) -> str:
    if m.group("uuid"):
        return m.group(0)
    if m.group("arn"):
        return _mask_arn(m, aliases)
    return _label(m.group("id"), aliases)


def mask_text(text: str, aliases: Optional[Mapping[str, str]] = None) -> str:
    """Mask account ids, ARNs and EC2 resource ids. Idempotent."""
    if aliases is None:
        aliases = load_aliases()
    text = TOKEN_RE.sub(lambda m: _replace(m, aliases), text)
    return EC2_ID_RE.sub(lambda m: f"{m.group('prefix')}-{{masked}}", text)


def find_leaks(text: str) -> list[str]:
    """Distinct leak kinds left in a text: a 12-digit number outside a UUID, `arn:aws:`, an EC2 id.

    The guard every generator test and the generators themselves run on their output. It never returns
    the matched value (a CI log of a public repo must not print the id it is guarding)."""
    leaks = []
    scrubbed = UUID_RE.sub("", text)
    n = len(LEAK_ID_RE.findall(scrubbed))
    if n:
        leaks.append(f"{n} 12-digit number(s) (AWS account id?)")
    n = scrubbed.count(LEAK_ARN)
    if n:
        leaks.append(f"{n} '{LEAK_ARN}' ARN(s)")
    n = len(EC2_ID_RE.findall(scrubbed))
    if n:
        leaks.append(f"{n} EC2/VPC resource id(s)")
    return leaks


def assert_clean(text: str, what: str) -> None:
    leaks = find_leaks(text)
    if leaks:
        raise AssertionError(f"{what}: unmasked AWS identifiers: " + "; ".join(leaks))


def rewrite_page(text: str, aliases: Optional[Mapping[str, str]] = None) -> str:
    """Mask a whole page; a gen_docs.py page gets the fingerprint of its masked body back.

    The body of a gen_docs.page() is everything after the first blank line that follows the
    blurb (the `>` lines under the fingerprint comment)."""
    masked = mask_text(text, aliases)
    m = FINGERPRINT_RE.search(masked)
    if not m:
        return masked
    rest = masked[m.end():]
    # rest = "\n" + blurb lines ("> ...\n") + "\n" + body
    lines = rest.split("\n")
    i = 0
    while i < len(lines) and lines[i] == "":
        i += 1
    while i < len(lines) and lines[i].startswith(">"):
        i += 1
    if i >= len(lines) or lines[i] != "":
        return masked  # not the gen_docs layout: leave the fingerprint as it is
    body = "\n".join(lines[i + 1:])
    fp = hashlib.sha256(body.encode("utf-8")).hexdigest()
    return masked[: m.start()] + f"<!-- docs-fingerprint: {fp} -->\n" + rest


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("cmd", choices=("check", "rewrite"))
    ap.add_argument("files", nargs="+", type=Path)
    args = ap.parse_args(argv)
    try:
        aliases = load_aliases()
    except AliasError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 2
    bad = 0
    for path in args.files:
        text = path.read_text(encoding="utf-8")
        if args.cmd == "rewrite":
            new = rewrite_page(text, aliases)
            if new != text:
                path.write_text(new, encoding="utf-8")
                print(f"masked {path}")
            text = new
        leaks = find_leaks(text)
        if leaks:
            bad += 1
            print(f"::error file={path}::unmasked AWS identifiers: " + "; ".join(leaks))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
