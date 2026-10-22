"""Local checks on the DB Migrate copies in db/migrations/<owner>/ (AA-807 N5). No network, no DB.

  * unique number per owner: two files with the same NNN in one owner dir fail (MIG-3), because
    DB Migrate keys a run by the number and the second file would be "already applied";
  * the run_migration.py lint on every file: `-- migrate:` directives parse, CONCURRENTLY only in a
    `-- migrate: no-transaction` file, DROP TABLE/SCHEMA/COLUMN and TRUNCATE only with
    `-- migrate: destructive` (MIG-9, MIG-10, MIG-12), and the X1 role lint for owner-dir files
    above today's heads (no RESET ROLE, SET LOCAL ROLE only to the dir's allowlist, EXTENSION and
    ROLE statements only in roles/; one BEGIN … COMMIT block or a no-transaction file, the shape
    the role switch needs). Same code DB Migrate runs before apply.
  * roles/ (Infra-native, key rl-NNN) is numbered and linted like every owner dir.
  * data standards DM-6.1 tag lint (AA-929): a `COMMENT ON COLUMN … IS '<text>'` whose `pii:<class>` /
    `conf:<class>` tag names a class outside gen_schema_reference.TAG_CLASSES fails; a comment that names a
    tag without starting with it ('Home address, pii:address') is a warning, as in the schema reference.
    Comments written through dynamic SQL (EXECUTE format(…)) are out of reach; the schema reference's tag
    findings are the backstop.

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

import gen_schema_reference as gen  # noqa: E402  (TAG_CLASSES, parse_tag: one home for the DM-6.1 classes)
import run_migration  # noqa: E402

MIGRATIONS_DIR = "db/migrations"
NUMBER_RE = re.compile(r"^([0-9]{3})_")
# COMMENT ON COLUMN <target> IS '<literal>' (E'' strings too). Matched on one statement of split_statements, so a
# ';' inside the literal does not cut it; the target is reported as written.
COMMENT_COLUMN_RE = re.compile(r"\bCOMMENT\s+ON\s+COLUMN\s+(.+?)\s+IS\s+([eE]?)'((?:[^']|'')*)'", re.IGNORECASE | re.DOTALL)


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


def tag_lint(sql: str) -> tuple[list[str], list[str]]:
    """DM-6.1 (AA-929): (errors, warnings) for the pii:/conf: tags of the file's COMMENT ON COLUMN statements."""
    errors, warnings = [], []
    known = ", ".join(f"{kind}:{c}" for kind, classes in gen.TAG_CLASSES.items() for c in classes)
    for st in run_migration.split_statements(sql):
        if not st.code.startswith("COMMENT ON COLUMN"):
            continue
        m = COMMENT_COLUMN_RE.search(st.text)
        if not m:
            continue                                   # IS NULL, or a literal built some other way
        target, text = " ".join(m.group(1).split()), m.group(3).replace("''", "'")
        tag, also = gen.parse_tag(text)
        for t in ([tag] if tag else []) + also:
            kind, _, klass = t.partition(":")
            if klass not in gen.TAG_CLASSES.get(kind, ()):
                errors.append(f"line {st.line}: COMMENT ON COLUMN {target}: unknown class {t} "
                              f"(data standards DM-6.1 classes: {known})")
        if not tag and also:
            warnings.append(f"line {st.line}: COMMENT ON COLUMN {target} names {', '.join(also)} but does not "
                            "start with a tag ('<kind>:<class>; ...', DM-6.1)")
    return errors, warnings


def lint_file(path: Path, rel: str = "") -> tuple[list[str], list[str]]:
    try:
        sql = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return ["is not valid UTF-8"], []
    errors, warnings = run_migration.lint(sql, run_migration.parse_directives(sql), rel or path.as_posix())
    tag_errors, tag_warnings = tag_lint(sql)
    return list(errors) + tag_errors, list(warnings) + tag_warnings


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
        errors, warnings = lint_file(repo_root / rel, rel)
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
