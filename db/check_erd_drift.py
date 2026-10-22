"""Design ERD vs live drift check (AA-894 scope 3).

Usage:
  python3 db/check_erd_drift.py erd.json DESIGN [DESIGN ...] [--summary FILE]

DESIGN is a hand-written design page (AA-Ecosys docs/architecture/erd/design/<schema>.md) or a directory of them
(README.md is skipped). erd.json is the model db/gen_erd.py writes from the live catalog dump.

A design page carries one marker comment and one or more Mermaid `erDiagram` blocks:

  <!-- erd-design schema=crm enforce=false implied-fk=tenant_id:tenant -->

  * schema=<name>      the schema the page designs (required);
  * enforce=true|false drift fails the check only when true and the schema is live (default false);
  * implied-fk=<col>:<table>[,...]  every box with an FK attribute <col> and no drawn edge on it has an FK from
                       that column to <table> (the tenant edge, which would hide everything else if drawn).

Diagram conventions (same as the generated pages): the parent is on the left of a relationship line, the child on
the right, and the label is the child's FK column list ("trip_id" or "a_id, b_id"). A quoted "schema.table" is a
table of another schema. Each table has its attribute block once on the page; a bare name is a reference to it.

For every design page whose schema exists live (has relations in erd.json), the check reports tables missing from
live or extra in live, primary keys that differ (where the design gives one) and FK edges missing or extra (for
tables on both sides). A schema that is not live yet is reported as such and passes. Exit 1 only for drift (or a
design problem) on a live schema whose page says enforce=true; otherwise 0. Exit 2 on a usage error.
Standard library only (runs on the GitHub runner next to gen_erd.py).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from typing import Optional

MARKER_RE = re.compile(r"<!--\s*erd-design\s+(.*?)\s*-->")
BLOCK_RE = re.compile(r"```mermaid[ \t]*\n(.*?)```", re.S)
NAME = r'"[^"\n]+"|[A-Za-z_][A-Za-z0-9_\-]*'
ENTITY_OPEN_RE = re.compile(rf"^({NAME})\s*\{{$")
ENTITY_BARE_RE = re.compile(rf"^({NAME})$")
ATTR_RE = re.compile(r'^([A-Za-z*][A-Za-z0-9_\-()\[\]]*)\s+([A-Za-z_*][A-Za-z0-9_\-()\[\]]*)'
                     r'(?:\s+((?:PK|FK|UK)(?:\s*,\s*(?:PK|FK|UK))*))?(?:\s+"[^"]*")?$', re.I)
LEFT = r"\|\||\|o|\}o|\}\|"
RIGHT = r"\|\||o\||o\{|\|\{"
REL_RE = re.compile(rf'^({NAME})\s+(?:{LEFT})(?:--|\.\.)(?:{RIGHT})\s+({NAME})\s*:\s*("[^"]*"|\S+)$')
IGNORED_RE = re.compile(r"^(erDiagram|direction\s+\w+|title\s.*|%%.*)$", re.I)
KEY_SUFFIXED_RE = re.compile(r"^(pk|fk|uk)_(-.*)?$", re.I)     # gen_erd.mermaid_name writes `pk` as `pk_`


def _unquote(name: str) -> str:
    return name[1:-1] if name.startswith('"') and name.endswith('"') else name


def _column(name: str) -> str:
    m = KEY_SUFFIXED_RE.match(name)
    return name[:2] + (m.group(2) or "") if m else name


@dataclass
class DesignTable:
    pk: list = field(default_factory=list)
    fk_columns: list = field(default_factory=list)
    columns: list = field(default_factory=list)


@dataclass
class Design:
    path: str
    schema: Optional[str] = None
    enforce: bool = False
    implied: list = field(default_factory=list)         # [(column, parent table)]
    tables: dict = field(default_factory=dict)          # name -> DesignTable (boxes with an attribute block)
    references: set = field(default_factory=set)        # bare names of this schema
    edges: set = field(default_factory=set)             # {(child, (cols, ...), parent)}; parent may be "s.t"
    problems: list = field(default_factory=list)


def parse_marker(text: str, design: Design) -> None:
    markers = MARKER_RE.findall(text)
    if len(markers) != 1:
        design.problems.append(f"expected one `<!-- erd-design schema=... -->` marker, found {len(markers)}")
        if not markers:
            return
    for token in markers[0].split():
        key, _, value = token.partition("=")
        if key == "schema" and value:
            design.schema = value
        elif key == "enforce" and value in ("true", "false"):
            design.enforce = value == "true"
        elif key == "implied-fk" and value:
            for pair in value.split(","):
                col, _, parent = pair.partition(":")
                if col and parent:
                    design.implied.append((col, parent))
                else:
                    design.problems.append(f"marker: bad implied-fk entry {pair!r} (want <column>:<table>)")
        else:
            design.problems.append(f"marker: unknown or empty setting {token!r}")
    if not design.schema:
        design.problems.append("marker: schema=<name> is missing")


def _local(design: Design, raw: str) -> str:
    """Table name in the design's terms: bare for its own schema, 'schema.table' for another schema."""
    name = _unquote(raw)
    if "." in name:
        sch, table = name.split(".", 1)
        return table if sch == design.schema else name
    return name


def parse_design(text: str, path: str = "<design>") -> Design:
    design = Design(path=path)
    parse_marker(text, design)
    blocks = [b for b in BLOCK_RE.findall(text) if b.strip().splitlines()[:1] == ["erDiagram"]]
    if not blocks:
        design.problems.append("no ```mermaid erDiagram block")
    raw_edges = []
    for b_no, block in enumerate(blocks, 1):
        current: Optional[str] = None
        for raw_line in block.splitlines():
            line = raw_line.strip()
            if not line or IGNORED_RE.match(line):
                continue
            where = f"block {b_no}: {line!r}"
            if current is not None:
                if line == "}":
                    current = None
                    continue
                m = ATTR_RE.match(line)
                if not m:
                    design.problems.append(f"attribute does not parse, {where}")
                    continue
                col = _column(m.group(2))
                keys = {k.strip().upper() for k in (m.group(3) or "").split(",") if k.strip()}
                t = design.tables[current]
                t.columns.append(col)
                if "PK" in keys:
                    t.pk.append(col)
                if "FK" in keys:
                    t.fk_columns.append(col)
                continue
            m = ENTITY_OPEN_RE.match(line)
            if m:
                name = _local(design, m.group(1))
                if "." in name:
                    design.problems.append(f"attribute block for another schema's table {name}, {where}")
                if name in design.tables:
                    design.problems.append(f"{name}: second attribute block (one box per table), {where}")
                design.tables[name] = DesignTable()
                current = name
                continue
            m = REL_RE.match(line)
            if m:
                parent, child = _local(design, m.group(1)), _local(design, m.group(2))
                cols = tuple(sorted(_column(c.strip()) for c in _unquote(m.group(3)).split(",") if c.strip()))
                raw_edges.append((child, cols, parent, where))
                for name in (parent, child):
                    if "." not in name:
                        design.references.add(name)
                continue
            m = ENTITY_BARE_RE.match(line)
            if m:
                name = _local(design, m.group(1))
                if "." not in name:
                    design.references.add(name)
                continue
            design.problems.append(f"line does not parse, {where}")
        if current is not None:
            design.problems.append(f"block {b_no}: attribute block of {current} is not closed")
    for child, cols, parent, where in raw_edges:
        if "." in child:
            design.problems.append(f"edge child {child} is not in schema {design.schema}, {where}")
            continue
        box = design.tables.get(child)
        if box is not None:
            not_fk = [c for c in cols if c not in box.fk_columns]
            if not cols or not_fk:
                design.problems.append(f"edge label of {child} names {', '.join(not_fk) or 'no column'} "
                                       f"that is not an FK attribute of {child}, {where}")
        design.edges.add((child, cols, parent))
    for name in sorted(design.references - set(design.tables)):
        design.problems.append(f"{name} is referenced but has no attribute block")
    drawn = {(child, cols) for child, cols, _ in design.edges}
    for name, box in sorted(design.tables.items()):
        for col in box.fk_columns:
            if (name, (col,)) in drawn or any(name == c and col in cs for c, cs in drawn):
                continue
            implied = [parent for icol, parent in design.implied if icol == col]
            if implied:
                design.edges.add((name, (col,), implied[0]))
            else:
                design.problems.append(f"{name}.{col} is marked FK but no edge or implied-fk covers it")
    return design


# ── live side ──────────────────────────────────────────────────────────────────────────────────────────────────


def live_schema(model: dict, schema: str) -> Optional[dict]:
    """{'tables': {name: pk list}, 'edges': {(child, cols, parent)}} or None when the schema has no relations."""
    entry = next((s for s in model.get("schemas", []) if s.get("schema") == schema), None)
    tables = [t for t in (entry or {}).get("tables", []) if not t.get("is_partition")]
    if not tables:
        return None
    edges = set()
    for t in tables:
        for fk in t.get("foreign_keys", []):
            parent = fk["ref_table"] if fk.get("ref_schema") == schema else f"{fk.get('ref_schema')}.{fk['ref_table']}"
            edges.add((t["name"], tuple(sorted(fk.get("columns", []))), parent))
    return {"tables": {t["name"]: list(t.get("primary_key", [])) for t in tables}, "edges": edges}


def _edge(e: tuple) -> str:
    child, cols, parent = e
    return f"`{child}` ({', '.join(cols)}) -> `{parent}`"


def compare(design: Design, live: dict) -> dict:
    d_tables, l_tables = set(design.tables), set(live["tables"])
    both = d_tables & l_tables
    pk = []
    for name in sorted(both):
        want, have = design.tables[name].pk, live["tables"][name]
        if want and sorted(want) != sorted(have):
            pk.append(f"`{name}`: design ({', '.join(want)}), live ({', '.join(have) or 'none'})")
    d_edges = {e for e in design.edges if e[0] in both}
    l_edges = {e for e in live["edges"] if e[0] in both}
    return {"missing_tables": sorted(d_tables - l_tables), "extra_tables": sorted(l_tables - d_tables),
            "pk": pk, "missing_edges": sorted(d_edges - l_edges), "extra_edges": sorted(l_edges - d_edges)}


@dataclass
class Result:
    design: Design
    status: str                    # not_live | in_sync | drift | invalid
    findings: dict = field(default_factory=dict)

    @property
    def count(self) -> int:
        return sum(len(v) for v in self.findings.values())

    @property
    def fails(self) -> bool:
        return self.design.enforce and self.status in ("drift", "invalid")


def check(design: Design, model: dict) -> Result:
    if not design.schema:
        return Result(design, "invalid")
    live = live_schema(model, design.schema)
    if live is None:
        return Result(design, "not_live")
    findings = compare(design, live)
    if any(findings.values()):
        return Result(design, "drift", findings)
    return Result(design, "invalid" if design.problems else "in_sync", findings)


LABELS = (("missing_tables", "Tables in the design, not live"), ("extra_tables", "Tables live, not in the design"),
          ("pk", "Primary keys that differ"), ("missing_edges", "FK edges in the design, not live"),
          ("extra_edges", "FK edges live, not in the design"))


def report(results: list[Result], model: dict) -> list[str]:
    L = ["### Design ERD drift (AA-894)", "",
         f"Live model `{str(model.get('fingerprint') or 'unknown')[:12]}`; {len(results)} design page(s).", "",
         "| schema | design page | enforce | result |", "|---|---|---|---|"]
    for r in results:
        d = r.design
        text = {"not_live": "not live yet (no relations in the dump): passes",
                "in_sync": f"in sync ({len(d.tables)} tables, {len(d.edges)} FK edges)",
                "drift": f"**drift: {r.count} finding(s)**" + (" (fails)" if r.fails else " (report only)"),
                "invalid": "**design page problems**" + (" (fails)" if r.fails else " (report only)")}[r.status]
        L.append(f"| `{d.schema or '?'}` | `{os.path.basename(d.path)}` | {'yes' if d.enforce else 'no'} | {text} |")
    L.append("")
    for r in results:
        d = r.design
        if r.status == "drift":
            L += [f"#### `{d.schema}` drift", ""]
            for key, label in LABELS:
                items = r.findings.get(key) or []
                if items:
                    shown = [_edge(i) if isinstance(i, tuple) else (i if i.startswith("`") else f"`{i}`")
                             for i in items]
                    L.append(f"- {label} ({len(items)}): " + "; ".join(shown))
            L.append("")
        if d.problems:
            L += [f"#### `{d.schema or d.path}` design page problems", ""]
            L += [f"- {p}" for p in d.problems] + [""]
    return L


def annotations(results: list[Result]) -> list[str]:
    out = []
    for r in results:
        d = r.design
        name = os.path.basename(d.path)
        if r.status == "not_live":
            out.append(f"::notice title=ERD drift::{d.schema}: not live yet, {name} not compared")
        elif r.status in ("drift", "invalid"):
            level = "error" if r.fails else "warning"
            what = f"{r.count} drift finding(s)" if r.status == "drift" else "design page problems"
            out.append(f"::{level} title=ERD drift::{d.schema or name}: {what} (see the step summary)")
        if d.problems and r.status != "invalid":
            out.append(f"::warning title=ERD design::{name}: {len(d.problems)} design page problem(s)")
    return out


def design_files(paths: list[str]) -> list[str]:
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += sorted(os.path.join(p, n) for n in os.listdir(p) if n.endswith(".md") and n != "README.md")
        else:
            files.append(p)
    return files


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("erd_json", help="erd.json written by db/gen_erd.py")
    parser.add_argument("design", nargs="+", help="design page(s) or directory of design pages")
    parser.add_argument("--summary", help="append the Markdown report to this file (e.g. $GITHUB_STEP_SUMMARY)")
    args = parser.parse_args(argv)
    try:
        with open(args.erd_json, encoding="utf-8") as f:
            model = json.load(f)
        files = design_files(args.design)
        texts = []
        for path in files:
            with open(path, encoding="utf-8") as f:
                texts.append((path, f.read()))
    except (OSError, ValueError) as exc:
        print(f"check_erd_drift: {exc}", file=sys.stderr)
        return 2
    results = []
    for path, text in texts:
        design = parse_design(text, path)
        stem = os.path.splitext(os.path.basename(path))[0]
        if design.schema and stem != design.schema:
            design.problems.append(f"file name {stem}.md does not match schema={design.schema}")
        results.append(check(design, model))
    lines = report(results, model)
    print("\n".join(lines))
    for a in annotations(results):
        print(a)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    return 1 if any(r.fails for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
