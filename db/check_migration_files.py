"""Local checks on the DB Migrate copies in db/migrations/<owner>/ (AA-807 N5). No network, no DB.

  * unique number per owner: two files with the same NNN in one owner dir fail (MIG-3), because
    DB Migrate keys a run by the number and the second file would be "already applied";
  * the run_migration.py lint on every file: `-- migrate:` directives parse, CONCURRENTLY only in a
    `-- migrate: no-transaction` file, DROP TABLE/SCHEMA/COLUMN and TRUNCATE only with
    `-- migrate: destructive` (MIG-9, MIG-10, MIG-12). Same code DB Migrate runs before apply.

Usage:
  python3 db/check_migration_files.py            # every copy (CI, PR and nightly)
  python3 db/check_migration_files.py FILE ...   # lint the given files, still number-check all

Byte equality with the owner repo is the other guard, check_migration_copies.py.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import run_migration  # noqa: E402

MIGRATIONS_DIR = "db/migrations"
NUMBER_RE = re.compile(r"^([0-9]{3})_")


def duplicate_numbers(repo_root: Path) -> list[str]:
    """One error per owner number used by more than one file."""
    errors = []
    base = repo_root / MIGRATIONS_DIR
    for owner_dir in sorted(p for p in base.iterdir() if p.is_dir()):
        by_number: dict[str, list[str]] = defaultdict(list)
        for f in sorted(owner_dir.glob("*.sql")):
            m = NUMBER_RE.match(f.name)
            if m:
                by_number[m.group(1)].append(f.name)
        for number, names in sorted(by_number.items()):
            if len(names) > 1:
                errors.append(f"{MIGRATIONS_DIR}/{owner_dir.name}: number {number} is used by "
                              f"{len(names)} files ({', '.join(names)}) — numbers are unique per owner (MIG-3)")
    return errors


def lint_file(path: Path) -> tuple[list[str], list[str]]:
    try:
        sql = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return ["is not valid UTF-8"], []
    return run_migration.lint(sql, run_migration.parse_directives(sql))


def all_copies(repo_root: Path) -> list[str]:
    base = repo_root / MIGRATIONS_DIR
    return sorted(p.relative_to(repo_root).as_posix() for p in base.rglob("*.sql") if p.is_file())


def run(paths: list[str], repo_root: Path, out=sys.stdout) -> int:
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    failed = 0
    for err in duplicate_numbers(repo_root):
        failed += 1
        print(f"FAIL  {err}", file=out)
        if annotate:
            print(f"::error::{err}", file=out)
    checked = 0
    for rel in paths:
        rel = rel.strip()
        if not rel or not (repo_root / rel).is_file():
            continue
        checked += 1
        errors, warnings = lint_file(repo_root / rel)
        for w in warnings:
            print(f"warn  {rel}: {w}", file=out)
            if annotate:
                print(f"::warning file={rel}::{w}", file=out)
        for e in errors:
            print(f"FAIL  {rel}: {e}", file=out)
            if annotate:
                print(f"::error file={rel}::{e}", file=out)
        if errors:
            failed += 1
        elif not warnings:
            print(f"ok    {rel}", file=out)
    print(f"{checked} file(s) linted, unique numbers checked, {failed} problem(s)", file=out)
    return 1 if failed else 0


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("paths", nargs="*", help="repo-relative files to lint (default: every copy)")
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parent.parent))
    args = parser.parse_args(argv)
    root = Path(args.repo_root)
    return run(args.paths or all_copies(root), root)


if __name__ == "__main__":
    sys.exit(main())
