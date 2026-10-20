#!/usr/bin/env python3
"""ADR status and index lint (AA-888). Stdlib only.

For every ADR file docs/adr/NNNN[a-z]-<slug>.md:
  * a status is stated: front-matter `status:`, a `- **Status:** X` / `Status: X` line,
    or a `## Status` heading followed by the value;
  * the first word of that status is one of Proposed, Accepted, Deprecated, Superseded, Rejected;
  * docs/adr/README.md links to the file.

Usage:
  python tools/docs/check_adr_index.py               # docs/adr of this repo
  python tools/docs/check_adr_index.py path/to/adr   # another ADR folder
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from docslib import REPO_ROOT, Finding, emit, split_front_matter

ADR_FILE = re.compile(r"^\d{4}[a-z]?-[a-z0-9-]+\.md$")
VALID = {"proposed", "accepted", "deprecated", "superseded", "rejected"}
STATUS_LINE = re.compile(r"^\s*(?:[-*]\s*)?\**status:?\**\s*:?\s*\**\s*(.+)$", re.IGNORECASE)
STATUS_HEADING = re.compile(r"^#{2,3}\s+status\s*$", re.IGNORECASE)


def first_word(value: str) -> str:
    m = re.search(r"[A-Za-z]+", value)
    return m.group(0).lower() if m else ""


def find_status(text: str) -> tuple[str | None, int]:
    """Return (status text, line number) or (None, 1)."""
    try:
        raw, _ = split_front_matter(text)
    except ValueError:
        raw = None
    if raw:
        for n, line in enumerate(raw.splitlines(), 2):
            if line.lower().startswith("status:"):
                return line.split(":", 1)[1].strip(), n
    lines = text.splitlines()
    for n, line in enumerate(lines, 1):
        if STATUS_HEADING.match(line):
            for m, nxt in enumerate(lines[n:], n + 1):
                if nxt.strip():
                    return nxt.strip(), m
            return None, n
        if line.lstrip().startswith(("#", "|")):
            continue
        sm = STATUS_LINE.match(line)
        if sm:
            return sm.group(1).strip(), n
    return None, 1


def check(adr_dir: Path, root: Path) -> list[Finding]:
    findings: list[Finding] = []
    index = adr_dir / "README.md"
    index_rel = index.resolve().relative_to(root).as_posix() if index.exists() else None
    index_text = index.read_text(encoding="utf-8") if index.exists() else ""
    adrs = sorted(p for p in adr_dir.glob("*.md") if ADR_FILE.match(p.name))
    if adrs and not index.exists():
        findings.append(Finding(adr_dir.resolve().relative_to(root).as_posix(), 1, "ADR index",
                                "docs/adr/README.md is missing; add an index that links every ADR."))
    for path in adrs:
        relpath = path.resolve().relative_to(root).as_posix()
        status, line = find_status(path.read_text(encoding="utf-8"))
        if status is None:
            findings.append(Finding(relpath, line, "ADR status",
                                    "no Status found; add '- **Status:** Accepted (dd/mm/yyyy, S<nnn>)'."))
        elif first_word(status) not in VALID:
            findings.append(Finding(relpath, line, "ADR status",
                                    f"status '{status[:60]}' must start with one of: "
                                    + ", ".join(sorted(VALID))))
        if index_rel and f"({path.name})" not in index_text and f"/{path.name})" not in index_text:
            findings.append(Finding(index_rel, 1, "ADR index", f"{path.name} is not linked from the index"))
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("adr_dir", nargs="?", default="docs/adr")
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    adr_dir = (root / args.adr_dir).resolve()
    findings = check(adr_dir, root)
    emit(findings, "error")
    count = len([p for p in adr_dir.glob("*.md") if ADR_FILE.match(p.name)])
    print(f"adr-index: {count} ADRs checked, {len(findings)} errors")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
