#!/usr/bin/env python3
"""gitleaks baseline guard: a pinned fingerprint in .gitleaksignore is never dropped silently.

The full-history secret scan (.github/workflows/secret-scan-history.yml) reads every commit of every branch and tag
AND the head of every pull request (`refs/pull/*/head`). GitHub keeps those PR heads for ever, closed PRs included,
and a history rewrite (git filter-repo + force push) does not touch them: the old, pre-rewrite commits stay
reachable through them. So when a rewrite gives the branch commits new SHAs, the fingerprints pinned on the OLD SHAs
are still needed next to the new ones. S287 (21/11/2026) remapped them instead (old pin replaced by the new one, root
#922 / AA-CIS-Infra #953) and the nightly scan went red from the next night on (S290): 33 findings in the root, 6 in
AA-CIS-Infra, every one the same line, at the same place, as a pin the remap had just removed.

Rule this guard enforces, on a change from a base to a head: every commit-pinned fingerprint
(`<40-hex sha>:<file>:<rule>:<line>`) in the base copy of .gitleaksignore is still in the head copy, or the head
copy retires it explicitly with a reason:

    # retired <fingerprint> <reason>

Retire a pin only when its commit is gone from GitHub for good (no branch, no tag, no `refs/pull/*/head` reaches
it, e.g. after GitHub Support purged the PR refs), and say so in the reason. A remap after a history rewrite ADDS the
new pins and keeps the old ones.

Usage:
  python3 tools/repo/gitleaksignore_guard.py --base origin/master [--head HEAD]
  python3 tools/repo/gitleaksignore_guard.py --base <sha> --head <sha> --github   (CI: ::error annotations)
  --allow-missing-base   exit 0 with a note when the base ref is not there (pre-push without a fetch; CI never)

Exit codes: 0 clean, 1 at least one pin dropped, 2 usage or git error.
Stdlib only, Python 3.9+. Byte-identical in AA-Ecosys and AA-CIS-Infra (tools/repo/README.md).
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass, field

IGNORE_FILE = ".gitleaksignore"
PIN_RE = re.compile(r"^[0-9a-f]{40}:\S+:[A-Za-z0-9_.-]+:\d+$")
RETIRED_RE = re.compile(r"^#\s*retired\s+(\S+)\s+(\S.*)$")
MIN_REASON_CHARS = 20
HINT = (
    "GitHub keeps every pull request head (refs/pull/*/head) for ever and the nightly full-history scan reads them, "
    "so a commit that left the branches (history rewrite, deleted branch) is still scanned. After a history rewrite, "
    "ADD the pins of the new SHAs and keep the old ones. Retire a pin only when no ref on GitHub reaches its commit "
    "any more: '# retired <fingerprint> <reason>' in .gitleaksignore."
)


@dataclass
class Baseline:
    pins: set[str] = field(default_factory=set)
    retired: dict[str, str] = field(default_factory=dict)
    bad_retired: list[str] = field(default_factory=list)


def parse(text: str) -> Baseline:
    """Commit-pinned fingerprints and `# retired` lines of a .gitleaksignore text."""
    out = Baseline()
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            m = RETIRED_RE.match(line)
            if m:
                fp, reason = m.group(1), m.group(2).strip()
                if PIN_RE.match(fp) and len(reason) >= MIN_REASON_CHARS:
                    out.retired[fp] = reason
                else:
                    out.bad_retired.append(line)
            continue
        if PIN_RE.match(line):
            out.pins.add(line)
    return out


def dropped(base: Baseline, head: Baseline) -> list[str]:
    """Pins of the base that the head neither keeps nor retires with a reason, sorted."""
    return sorted(fp for fp in base.pins if fp not in head.pins and fp not in head.retired)


def git(repo: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=False)


def ref_exists(repo: str, ref: str) -> bool:
    return git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").returncode == 0


def read_at(repo: str, ref: str, path: str) -> str:
    """The file at a ref, or '' when the ref has no such file. Raises RuntimeError on any other git failure."""
    if git(repo, "cat-file", "-e", f"{ref}:{path}").returncode != 0:
        return ""
    res = git(repo, "show", f"{ref}:{path}")
    if res.returncode != 0:
        raise RuntimeError(f"git show {ref}:{path} failed: {res.stderr.strip()}")
    return res.stdout


def render(drops: list[str], bad: list[str], path: str, github: bool) -> list[str]:
    lines: list[str] = []
    for fp in drops:
        text = f"pinned fingerprint removed: {fp}"
        lines.append(f"refused: {text}")
        if github:
            lines.append(f"::error file={path},title=gitleaks baseline guard::{text}. {HINT}")
    for line in bad:
        text = f"malformed retired line (needs a pinned fingerprint and a reason of {MIN_REASON_CHARS}+ chars): {line}"
        lines.append(f"refused: {text}")
        if github:
            lines.append(f"::error file={path},title=gitleaks baseline guard::{text}")
    if drops or bad:
        lines.append(HINT)
    return lines


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--base", required=True, help="base ref (the PR base, origin/master, origin/main)")
    ap.add_argument("--head", default="HEAD", help="head ref (default HEAD)")
    ap.add_argument("--repo", default=".", help="repository path (default: current directory)")
    ap.add_argument("--file", default=IGNORE_FILE, help=f"baseline path in the repo (default {IGNORE_FILE})")
    ap.add_argument("--github", action="store_true", help="also print GitHub ::error annotations")
    ap.add_argument("--allow-missing-base", action="store_true", help="exit 0 when the base ref is missing")
    args = ap.parse_args(argv)

    if not ref_exists(args.repo, args.base):
        if args.allow_missing_base:
            print(f"gitleaks baseline guard: base {args.base} not found, skipped (fetch it to check)")
            return 0
        print(f"gitleaks baseline guard: base ref {args.base} not found", file=sys.stderr)
        return 2
    if not ref_exists(args.repo, args.head):
        print(f"gitleaks baseline guard: head ref {args.head} not found", file=sys.stderr)
        return 2
    try:
        base = parse(read_at(args.repo, args.base, args.file))
        head = parse(read_at(args.repo, args.head, args.file))
    except RuntimeError as exc:
        print(f"gitleaks baseline guard: {exc}", file=sys.stderr)
        return 2

    drops = dropped(base, head)
    new_bad = [line for line in head.bad_retired if line not in base.bad_retired]
    for line in render(drops, new_bad, args.file, args.github):
        print(line)
    if drops or new_bad:
        return 1
    print(
        f"gitleaks baseline guard: OK ({len(base.pins)} pin(s) in base, {len(head.pins)} in head, "
        f"{len(head.retired)} retired)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
