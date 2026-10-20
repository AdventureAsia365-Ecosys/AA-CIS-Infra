"""Shared helpers for the docs lint tools (AA-888).

Stdlib only, so check_docs_text.py and check_adr_index.py run without installing anything.
Only check_frontmatter.py needs PyYAML and jsonschema (tools/docs/requirements.txt).
"""

from __future__ import annotations

import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Journals: dated records of what happened. They keep their history as written, so the
# catalog rules (front-matter, resource IDs, single-line CLI) do not apply to them.
# docs/backups is gitignored (real-data dumps, DM-6.10) and never reaches CI.
JOURNAL_PREFIXES = (
    "docs/sessions/",
    "docs/audits/",
    "docs/implementation-notes/",
    "docs/backlog/",
    "docs/research/",
    "docs/calib/",
    "docs/backups/",
)

# Pages the style guide exempts from the resource-ID rule (docs/STYLE.md, "Resource IDs").
# onboarding.md holds the single account-map table; db-schema-reference.md is generated.
RESOURCE_ID_EXEMPT_FILES = (
    "docs/onboarding.md",
    "docs/architecture/db-schema-reference.md",
)

# Templates carry placeholder IDs (OPS-00-replace-me) and are not real pages.
TEMPLATE_PREFIX = "docs/templates/"

# Put this marker on a line to skip the text checks for that line only.
IGNORE_MARKER = "docs-lint: ignore"


@dataclass
class Finding:
    path: str
    line: int
    title: str
    message: str
    kind: str = ""  # short key of the rule that matched (resource-ids: vpc, arn, ...); used by --block

    def annotate(self, level: str) -> str:
        """GitHub Actions workflow command; also readable in a local terminal."""
        msg = self.message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        return f"::{level} file={self.path},line={self.line},title={self.title}::{msg}"


def rel(path: Path, root: Path = REPO_ROOT) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def is_journal(relpath: str) -> bool:
    return relpath.startswith(JOURNAL_PREFIXES)


def is_template(relpath: str) -> bool:
    return relpath.startswith(TEMPLATE_PREFIX)


def list_markdown(roots: list[str], root: Path = REPO_ROOT) -> list[str]:
    """Tracked .md files under the given repo-relative roots (git ls-files).

    Falls back to a filesystem walk outside a git checkout (unit tests use temp dirs).
    """
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--", *roots],
            check=True,
            capture_output=True,
        ).stdout.decode("utf-8")
        files = [f for f in out.split("\0") if f.endswith(".md")]
        if files or (root / ".git").exists():
            return sorted(files)
    except (OSError, subprocess.CalledProcessError):
        pass
    found: list[str] = []
    for r in roots:
        base = root / r
        if base.is_file() and base.suffix == ".md":
            found.append(rel(base, root))
        elif base.is_dir():
            for dirpath, _dirs, names in os.walk(base):
                for n in names:
                    if n.endswith(".md"):
                        found.append(rel(Path(dirpath) / n, root))
    return sorted(found)


def split_front_matter(text: str) -> tuple[str | None, int]:
    """Return (yaml_text, body_start_line) when the file starts with a '---' block.

    yaml_text is None when there is no front-matter. body_start_line is 1-based.
    Raises ValueError when the block is opened but never closed.
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, 1
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[1:i]), i + 2
    raise ValueError("front-matter opened with '---' on line 1 but never closed")


def is_generated(text: str) -> bool:
    head = "\n".join(text.splitlines()[:30])
    return "generated: true" in head or "<!-- GENERATED" in head


def emit(findings: list[Finding], level: str) -> None:
    for f in findings:
        print(f.annotate(level))
    sys.stdout.flush()
