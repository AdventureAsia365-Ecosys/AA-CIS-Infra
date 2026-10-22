"""Retention-row check for new-app tables (data standards DM-7.1, AA-929). No network, no DB.

DM-7.1: every table gets a row in the retention table of data standards Part B section 7 (AA-Ecosys
`docs/architecture/data-standards/02-data-management.md`, the registry) in the same change that creates it. This
check makes that a PR failure for the owner dirs in RETENTION_OWNERS: each table a migration copy of such a dir
creates, and no later copy of the same dir drops, must be named in the first column of a row of that section
(`schema.table` in backticks). The existing owners (cis, booking, tripplanner) are not listed: their tables are
grandfathered by DM-7.1 ("an existing table without a row keeps all its rows until its owner proposes a window").
A new app's dir joins RETENTION_OWNERS in the PR that registers it in owners.yaml (ADR 0008 playbook).

Scope of the SQL reading: `CREATE [UNLOGGED] TABLE [IF NOT EXISTS] name` (a `PARTITION OF` child is covered by its
parent's row; TEMP tables are skipped), `DROP TABLE` and `ALTER TABLE … RENAME TO`, in file order. Unqualified
names take the dir's schema. Views, materialized views and tables created through dynamic SQL are out of scope.

Usage:
  python3 db/check_retention_rows.py --registry <AA-Ecosys>/docs/architecture/data-standards/02-data-management.md
  python3 db/check_retention_rows.py --registry FILE --scoped      # print "yes" when a scoped dir has a copy

Exit: 0 every table has a row (or no scoped dir has a copy), 1 a table has no row, 2 the registry is unreadable or
has no section 7 table (fail closed).
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import run_migration  # noqa: E402

MIGRATIONS_DIR = "db/migrations"
# Migration dir -> the schema an unqualified table name lands in. Add a new app's dir here (DM-7.1).
RETENTION_OWNERS = {"crm": "crm"}

SECTION_RE = re.compile(r"^## 7\. Retention and archival\s*$")
NAME_IN_CELL_RE = re.compile(r"`([a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*)`")
IDENT = r'(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_$]*)'
QUALIFIED = rf"({IDENT}(?:\s*\.\s*{IDENT})?)"
CREATE_RE = re.compile(rf"^CREATE\s+((?:GLOBAL\s+|LOCAL\s+)?(?:TEMP|TEMPORARY)\s+|UNLOGGED\s+)?TABLE\s+"
                       rf"(?:IF\s+NOT\s+EXISTS\s+)?{QUALIFIED}(.*)$", re.IGNORECASE | re.DOTALL)
DROP_RE = re.compile(r"^DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?(.+?)(?:\s+(?:CASCADE|RESTRICT))?$",
                     re.IGNORECASE | re.DOTALL)
RENAME_RE = re.compile(rf"^ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?{QUALIFIED}\s+RENAME\s+TO\s+({IDENT})$",
                       re.IGNORECASE | re.DOTALL)
NUMBER_RE = re.compile(r"^([0-9]{3})_")


class RegistryError(Exception):
    pass


def registry_tables(markdown: str) -> set[str]:
    """`schema.table` names in the first column of every table row of section 7 (the DM-7 registry)."""
    names: set[str] = set()
    in_section, rows = False, 0
    for line in markdown.splitlines():
        if SECTION_RE.match(line):
            in_section = True
            continue
        if in_section and line.startswith("## "):
            break
        if not in_section or not line.startswith("|"):
            continue
        cells = line.split("|")
        if len(cells) < 3 or set(cells[1].strip()) <= set("-: "):
            continue                                       # separator row
        rows += 1
        names.update(NAME_IN_CELL_RE.findall(cells[1]))
    if not in_section:
        raise RegistryError("no '## 7. Retention and archival' section")
    if not rows or not names:
        raise RegistryError("section 7 has no table row naming a `schema.table`")
    return names


def _ident(raw: str) -> str:
    raw = raw.strip()
    return raw[1:-1].replace('""', '"') if raw.startswith('"') else raw.lower()


def qualify(raw: str, default_schema: str) -> str:
    parts = [_ident(p) for p in re.split(r'\s*\.\s*(?=(?:[^"]*"[^"]*")*[^"]*$)', raw.strip())]
    return ".".join(parts) if len(parts) == 2 else f"{default_schema}.{parts[-1]}"


def _code(st) -> str:
    """The statement without comments, whitespace collapsed, case kept (Statement.code is upper case)."""
    text, out, i, n = st.text, [], 0, len(st.text)
    while i < n:
        if text.startswith("--", i):
            j = text.find("\n", i)
            i = n if j == -1 else j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue
        out.append(text[i])
        i += 1
    return " ".join("".join(out).split()).rstrip(";").strip()


def created_tables(sql_files: list[tuple[str, str]], default_schema: str) -> dict[str, str]:
    """{table: 'file:line'} for the tables the files create and do not drop again, in file order."""
    live: dict[str, str] = {}
    for rel, sql in sql_files:
        for st in run_migration.split_statements(sql):
            code = _code(st)
            m = CREATE_RE.match(code)
            if m:
                temp = (m.group(1) or "").strip().upper().endswith(("TEMP", "TEMPORARY"))
                if temp or re.match(r"^\s*PARTITION\s+OF\b", m.group(3), re.IGNORECASE):
                    continue                           # session-only, or covered by the parent's row
                live.setdefault(qualify(m.group(2), default_schema), f"{rel}:{st.line}")
                continue
            m = DROP_RE.match(code)
            if m:
                for raw in m.group(1).split(","):
                    live.pop(qualify(raw, default_schema), None)
                continue
            m = RENAME_RE.match(code)
            if m:
                old = qualify(m.group(1), default_schema)
                if old in live:
                    where = live.pop(old)
                    live[f"{old.split('.')[0]}.{_ident(m.group(2))}"] = where
    return live


def scoped_files(repo_root: Path) -> dict[str, list[tuple[str, str]]]:
    """{dir: [(repo-relative path, sql)]} for the RETENTION_OWNERS dirs that have copies, in number order."""
    out = {}
    for d in sorted(RETENTION_OWNERS):
        base = repo_root / MIGRATIONS_DIR / d
        if not base.is_dir():
            continue
        files = sorted(p for p in base.glob("*.sql") if p.is_file() and NUMBER_RE.match(p.name))
        if files:
            out[d] = [(p.relative_to(repo_root).as_posix(), p.read_text(encoding="utf-8")) for p in files]
    return out


def check(registry: set[str], files: dict[str, list[tuple[str, str]]]) -> list[str]:
    errors = []
    for d, sql_files in files.items():
        for table, where in sorted(created_tables(sql_files, RETENTION_OWNERS[d]).items()):
            if table not in registry:
                errors.append(f"{where}: table {table} has no row in the data standards retention table (Part B "
                              "section 7, DM-7.1). Add the row in an AA-Ecosys root PR, merge it, then re-run.")
    return errors


def main(argv: Optional[list[str]] = None, out=sys.stdout) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--registry", help="path to AA-Ecosys docs/architecture/data-standards/02-data-management.md")
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument("--scoped", action="store_true",
                        help="print 'yes' when a RETENTION_OWNERS dir has a migration copy, else 'no'")
    args = parser.parse_args(argv)
    files = scoped_files(Path(args.repo_root))
    if args.scoped:
        print("yes" if files else "no", file=out)
        return 0
    if not files:
        print(f"no migration copy in {', '.join(sorted(RETENTION_OWNERS))}: nothing to check", file=out)
        return 0
    if not args.registry:
        print("FAIL  --registry is required when a scoped dir has migration copies", file=out)
        return 2
    try:
        registry = registry_tables(Path(args.registry).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, RegistryError) as e:
        print(f"FAIL  retention registry {args.registry}: {e}", file=out)
        return 2
    errors = check(registry, files)
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    for e in errors:
        print(f"FAIL  {e}", file=out)
        if annotate:
            print(f"::error file={e.split(':', 1)[0]}::{e}", file=out)
    n = sum(len(created_tables(f, RETENTION_OWNERS[d])) for d, f in files.items())
    print(f"{n} table(s) in {', '.join(files)}, {len(registry)} name(s) in the registry, {len(errors)} without a row",
          file=out)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
