"""Generated ERD of the shared RDS from a schema_dump.py JSON (AA-894 part 1).

Usage:
  python3 db/gen_erd.py dump.json --out-dir erd/ --json erd.json [--source "run URL"]
  python3 db/gen_erd.py dump.json --fingerprint        # print the ERD model fingerprint

Writes, from the same catalog dump as db/gen_schema_reference.py:
  * <out-dir>/<schema>.md  one Mermaid `erDiagram` per schema that has relations (AA-Ecosys
                           docs/architecture/erd/<schema>.md): base tables with their PK / FK / UK columns, every
                           FK as an edge, the other side of a cross-schema FK as a quoted "schema.table" entity;
  * <out-dir>/README.md    the index of those pages (owner, counts, cross-schema FKs, empty schemas);
  * --json erd.json        the model: schemas, tables, columns + full types, PK, unique keys, FKs, DM-6.1 tags,
                           owner app and owner role, a flat edge list. No row data, no comment text, no grants.

Standard library only (runs on the GitHub runner). Output is deterministic for a given dump, and the Markdown pages
carry nothing volatile (no row counts, sizes or dump time), so they change only when the structure does and the
nightly root PR shows a relationship change as a diff. The pages pass the root docs lint: catalog front matter
(docs/templates/frontmatter.schema.json, `generated: true`) and markdownlint (.markdownlint-cli2.jsonc).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # sibling modules
import gen_schema_reference as ref  # noqa: E402
import rls_catalogue_rules as rls  # noqa: E402

FORMAT = 1
GENERATOR = "infra/AA-CIS-Infra/.github/workflows/db-schema-dump.yml"
REFERENCE_LINK = "../db-schema-reference.md"
BASE_KINDS = ("table", "partitioned table")
# A schema with more tables or columns than this shows only its key columns (PK, FK, UK) in the diagram.
MAX_FULL_TABLES = 20
MAX_FULL_COLUMNS = 150
# Front-matter applies_to per owner app (docs/templates/frontmatter.schema.json slugs already in use).
APPLIES_TO = {"cis": "aa-cis-api", "booking": "aa-booking-api", "tripplanner": "tripplanner-lambda",
              "platform": "ecosystem"}
OWNER_LABEL = {"cis": "CIS", "booking": "Booking", "tripplanner": "TripPlanner", "platform": "platform"}

# Mermaid erDiagram words: an attribute type starts with a letter and holds letters, digits, '-', '_', '()' and
# '[]'; an unquoted entity or attribute name holds letters, digits, '-' and '_'.
TYPE_ABBREV = (
    ("timestamp with time zone", "timestamptz"), ("timestamp without time zone", "timestamp"),
    ("time with time zone", "timetz"), ("time without time zone", "time"),
    ("character varying", "varchar"), ("bit varying", "varbit"), ("double precision", "float8"),
    ("character", "char"),
)
TYPE_BAD_RE = re.compile(r"[^A-Za-z0-9_\-()\[\]]")
NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
NAME_BAD_RE = re.compile(r"[^A-Za-z0-9_\-]")
# Words the Mermaid ER lexer (case-insensitive) reads as keywords before it tries a name. An unquoted entity named
# one of these fails to parse (mermaid 11.4.1 erDiagram.jison: `one`, `many`, `to`, `u`, `erDiagram`); the
# multi-word cardinalities start with `one` / `zero` / `only` / `optionally`, and later Mermaid versions add
# `direction`, `style`, `classDef`, `class`, `title`, `accTitle`, `accDescr`. Such a table is always quoted.
ENTITY_KEYWORDS = frozenset(("erdiagram", "one", "many", "to", "u", "zero", "only", "optionally", "direction",
                             "style", "classdef", "class", "title", "acctitle", "accdescr"))
# Inside an attribute block `PK`, `FK` and `UK` are key markers (any case, whole word): a column with that name
# (or starting with it before a '-') is written with a '_' suffix, e.g. `pk` -> `pk_`. erd.json keeps the real name.
ATTRIBUTE_KEY_RE = re.compile(r"^(pk|fk|uk)(-|$)", re.I)
INDEX_HEAD_RE = re.compile(r"^CREATE (UNIQUE )?INDEX \S+ ON (?:ONLY )?\S+ USING \w+ \(")


# ── model ──────────────────────────────────────────────────────────────────────────────────────────────────────


def _split_top_level(text: str) -> list[str]:
    parts, depth, cur, quoted = [], 0, [], False
    for ch in text:
        if ch == '"':
            quoted = not quoted
        elif not quoted and ch == "(":
            depth += 1
        elif not quoted and ch == ")":
            depth -= 1
        if ch == "," and depth == 0 and not quoted:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur).strip())
    return parts


def index_columns(definition: str) -> tuple[Optional[list[str]], bool]:
    """(key columns, partial) of a `pg_get_indexdef` text. None when a key part is an expression.
    'CREATE UNIQUE INDEX x ON s.t USING btree (a, "b" DESC) WHERE (c IS NULL)' -> (['a', 'b'], True)."""
    m = INDEX_HEAD_RE.match(definition or "")
    if not m:
        return None, False
    depth, quoted, end = 1, False, None
    rest = definition[m.end():]
    for i, ch in enumerate(rest):
        if ch == '"':
            quoted = not quoted
        elif not quoted and ch == "(":
            depth += 1
        elif not quoted and ch == ")":
            depth -= 1
            if depth == 0:
                end = i
                break
    if end is None:
        return None, False
    cols = []
    for part in _split_top_level(rest[:end]):
        if not part or part.startswith("("):
            return None, False
        if part.startswith('"'):
            close = part.find('"', 1)
            name = part[1:close]
        else:
            name = part.split()[0]
            if "(" in name:
                return None, False
        cols.append(name)
    return cols, " WHERE " in rest[end:]


def _csv(value) -> list[str]:
    return [c for c in (value or "").split(",") if c]


def owner_app(schema: str) -> str:
    return rls.SCHEMA_OWNERS.get(schema, "unknown")


def build_model(dump: dict, source: Optional[str] = None) -> dict:
    """The erd.json document (FORMAT 1). Sorted: schemas, tables, edges by name; columns in table order."""
    rels = dump.get("relations", {})
    schema_owner = {s["schema"]: s.get("owner") for s in dump.get("schemas", [])}
    schemas, edges = [], []
    for sch in sorted(set(schema_owner) | set(rels)):
        tables = []
        for name in sorted(rels.get(sch, {})):
            r = rels[sch][name]
            col_names = [c["name"] for c in r.get("columns", [])]
            pk: list[str] = []
            uniques: list[list[str]] = []
            for i in sorted(r.get("indexes", []), key=lambda x: x.get("index") or ""):
                cols, partial = index_columns(i.get("definition", ""))
                if not cols or not set(cols) <= set(col_names) or not i.get("is_valid", True):
                    continue
                if i.get("is_primary"):
                    pk = cols
                elif i.get("is_unique") and not partial and cols not in uniques:
                    uniques.append(cols)
            fks = []
            for c in sorted((c for c in r.get("constraints", []) if c.get("type") == "f"),
                            key=lambda c: c.get("constraint") or ""):
                fk = {"name": c["constraint"], "columns": _csv(c.get("columns")), "ref_schema": c.get("ref_schema"),
                      "ref_table": c.get("ref_name"), "ref_columns": _csv(c.get("ref_columns")),
                      "validated": bool(c.get("validated", True))}
                fks.append(fk)
                edges.append({"name": fk["name"], "from": f"{sch}.{name}", "from_columns": fk["columns"],
                              "to": f"{fk['ref_schema']}.{fk['ref_table']}", "to_columns": fk["ref_columns"],
                              "validated": fk["validated"], "cross_schema": fk["ref_schema"] != sch,
                              "cross_owner": owner_app(fk["ref_schema"]) != owner_app(sch)})
            fk_cols = {col for fk in fks for col in fk["columns"]}
            uk_cols = {u[0] for u in uniques if len(u) == 1}
            columns = []
            for c in r.get("columns", []):
                tag, also = ref.parse_tag(c.get("comment"))
                col = {"name": c["name"], "type": c["type"], "not_null": bool(c.get("not_null")),
                       "pk": c["name"] in pk, "fk": c["name"] in fk_cols, "uk": c["name"] in uk_cols}
                if tag:
                    col["tag"] = tag
                if also:
                    col["also"] = also
                columns.append(col)
            tables.append({"name": name, "kind": r.get("kind"), "owner_role": r.get("owner"),
                           "rls": bool(r.get("rls")), "rls_forced": bool(r.get("rls_forced")),
                           "is_partition": bool(r.get("is_partition")), "primary_key": pk,
                           "unique_keys": uniques, "columns": columns, "foreign_keys": fks})
        schemas.append({"schema": sch, "owner_app": owner_app(sch), "owner_role": schema_owner.get(sch),
                        "tables": tables})
    edges.sort(key=lambda e: (e["from"], e["name"]))
    model = {"format": FORMAT, "migrations_latest_per_owner": dump.get("migrations_latest_per_owner", {}),
             "owner_migration_dates": owner_migration_dates(dump), "schemas": schemas, "edges": edges}
    model["fingerprint"] = model_fingerprint(model)
    model["generated_at"] = dump.get("generated_at")
    if source:
        model["source"] = source
    return model


def model_fingerprint(model: dict) -> str:
    view = {k: v for k, v in model.items() if k not in ("fingerprint", "generated_at", "source")}
    return hashlib.sha256(json.dumps(view, sort_keys=True).encode("utf-8")).hexdigest()


def owner_migration_dates(dump: dict) -> dict:
    """Applied date (YYYY-MM-DD) of each owner's newest migration (migrations_latest_per_owner) and of the newest
    migration overall ('platform'). Stable between migrations, so it can date a generated page."""
    applied = {m.get("version"): str(m.get("applied_at") or "")[:10] for m in dump.get("migrations", [])}
    out = {}
    for owner, version in sorted((dump.get("migrations_latest_per_owner") or {}).items()):
        if version and applied.get(version):
            out[owner] = applied[version]
    dates = sorted(d for d in applied.values() if d)
    if dates:
        out["platform"] = dates[-1]
    return out


def json_text(model: dict) -> str:
    return json.dumps(model, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


# ── Mermaid ────────────────────────────────────────────────────────────────────────────────────────────────────


def mermaid_type(pg_type: str) -> str:
    t = pg_type.replace('"', "")
    for long, short in TYPE_ABBREV:
        if t == long or t.startswith(long + "(") or t.startswith(long + "["):
            t = short + t[len(long):]
            break
    if "." in t and not t.startswith("("):           # schema-qualified enum or domain: keep the type name
        t = t.split(".", 1)[1]
    t = TYPE_BAD_RE.sub("_", t.replace(",", "_").replace(" ", "_"))
    t = t if t[:1].isalpha() else f"t_{t}"
    return t + "_" if t.lower() in ("pk", "fk", "uk") else t


def mermaid_name(name: str) -> str:
    n = NAME_BAD_RE.sub("_", name)
    n = n if n[:1].isalpha() or n[:1] == "_" else f"c_{n}"
    if ATTRIBUTE_KEY_RE.match(n):
        n = n[:2] + "_" + n[2:]
    return n


def entity(schema: str, table_schema: str, table: str) -> str:
    """Entity name in the diagram of `schema`: bare for its own tables, quoted "schema.table" for others."""
    if table_schema == schema and NAME_RE.match(table) and table.lower() not in ENTITY_KEYWORDS:
        return table
    label = table if table_schema == schema else f"{table_schema}.{table}"
    return '"' + label.replace('"', "'") + '"'


def full_columns(schema: dict) -> bool:
    tables = diagram_tables(schema)
    return len(tables) <= MAX_FULL_TABLES and sum(len(t["columns"]) for t in tables) <= MAX_FULL_COLUMNS


def diagram_tables(schema: dict) -> list[dict]:
    """Base tables that are not partitions; a schema without base tables shows its views instead."""
    base = [t for t in schema["tables"] if t["kind"] in BASE_KINDS and not t["is_partition"]]
    return base or [t for t in schema["tables"] if t["kind"] not in BASE_KINDS]


def attribute_line(c: dict) -> str:
    keys = [k for k, on in (("PK", c["pk"]), ("FK", c["fk"]), ("UK", c["uk"])) if on]
    line = f"        {mermaid_type(c['type'])} {mermaid_name(c['name'])}"
    if keys:
        line += " " + ", ".join(keys)
    if c.get("tag"):
        line += f' "{c["tag"]}"'
    return line


def relationship(fk_edge: dict, schema: str, tables: dict) -> str:
    child_schema, child = fk_edge["from"].split(".", 1)
    parent_schema, parent = fk_edge["to"].split(".", 1)
    child_t = tables.get(fk_edge["from"])
    cols = {c["name"]: c for c in (child_t or {}).get("columns", [])}
    mandatory = bool(fk_edge["from_columns"]) and all(cols.get(c, {}).get("not_null") for c in fk_edge["from_columns"])
    keyset = sorted(fk_edge["from_columns"])
    one_to_one = bool(child_t) and (keyset == sorted(child_t["primary_key"])
                                    or any(keyset == sorted(u) for u in child_t["unique_keys"]))
    left = "||" if mandatory else "|o"
    right = "o|" if one_to_one else "o{"
    line = "--" if fk_edge["validated"] else ".."
    # The child's FK column list ("trip_id", "a_id, b_id"): the convention the hand-written design pages use and
    # check_erd_drift.py reads (AA-894). The constraint name stays in the FK table below the diagram.
    label = ", ".join(fk_edge["from_columns"]).replace('"', "'") or fk_edge["name"].replace('"', "'")
    return (f"    {entity(schema, parent_schema, parent)} {left}{line}{right} "
            f'{entity(schema, child_schema, child)} : "{label}"')


def front_matter(page_id: str, title: str, description: str, applies_to: list[str], last_reviewed: str,
                 related: list[str]) -> list[str]:
    return ["---", f"id: {page_id}", f'title: "{title}"', f'description: "{description}"', "type: reference",
            "status: active", "owner: nghiep", "audience: [engineer, agent]",
            f"applies_to: [{', '.join(applies_to)}]", f"last_reviewed: {last_reviewed}", "review_every_days: 90",
            "generated: true", f"generator: {GENERATOR}", f"related: [{', '.join(related)}]", "---", ""]


def page_id(schema: str) -> str:
    return "APP-04-erd-" + re.sub(r"[^a-z0-9]+", "-", schema.lower()).strip("-")


def _date(model: dict, owner: str) -> str:
    dates = model.get("owner_migration_dates", {})
    return dates.get(owner) or dates.get("platform") or str(model.get("generated_at") or "1970-01-01")[:10]


def _as_of(model: dict, owner: str) -> str:
    version = (model.get("migrations_latest_per_owner") or {}).get(owner)
    if version:
        return (f"Live catalog as of the newest {OWNER_LABEL.get(owner, owner)} migration **{version}** "
                f"(applied {_date(model, owner)}).")
    return f"Live catalog as of the newest migration (applied {_date(model, owner)})."


def cell(value) -> str:
    return ref.cell(value)


def fk_table(edges: list[dict]) -> list[str]:
    if not edges:
        return ["None.", ""]
    L = ["| constraint | from | to | valid |", "|---|---|---|---|"]
    for e in edges:
        L.append(f"| `{e['name']}` | `{e['from']}` ({', '.join(e['from_columns'])}) | `{e['to']}` "
                 f"({', '.join(e['to_columns'])}) | {'yes' if e['validated'] else 'NOT VALID'} |")
    return L + [""]


def render_schema(model: dict, schema: dict) -> str:
    sch, owner = schema["schema"], schema["owner_app"]
    by_name = {f"{s['schema']}.{t['name']}": t for s in model["schemas"] for t in s["tables"]}
    shown = diagram_tables(schema)
    shown_names = {t["name"] for t in shown}
    full = full_columns(schema)
    own = [e for e in model["edges"] if e["from"].split(".", 1)[0] == sch]           # drawn: FKs of this schema
    incoming = [e for e in model["edges"] if e["to"].split(".", 1)[0] == sch and e not in own]   # listed only
    base = [t for t in schema["tables"] if t["kind"] in BASE_KINDS]
    views = [t for t in schema["tables"] if t["kind"] not in BASE_KINDS]
    title = f"ERD: {sch} schema"
    L = front_matter(page_id(sch), title,
                     f"Generated Mermaid ERD of the {sch} schema ({OWNER_LABEL.get(owner, owner)}): tables, keys and "
                     f"foreign keys from the live catalog dump.",
                     ["aa-cis-dev-db", APPLIES_TO.get(owner, "ecosystem")], _date(model, owner),
                     ["APP-04", "APP-04-erd", "AA-894"])
    w = L.append
    w(f"# {title}")
    w("")
    w(f"<!-- GENERATED by AA-CIS-Infra db/gen_erd.py ({GENERATOR}) - do not edit -->")
    w("")
    w(f"{_as_of(model, owner)} Owner: {OWNER_LABEL.get(owner, owner)} (schema owner role "
      f"`{schema['owner_role']}`). {len(base)} table(s), {len(views)} view(s), "
      f"{len(own)} foreign key(s), {len(incoming)} foreign key(s) in from other schemas.")
    w("")
    if full:
        w("The diagram shows every column. ")
    else:
        w(f"The diagram shows key columns only (PK, FK, UK): the schema has more than {MAX_FULL_TABLES} tables or "
          f"{MAX_FULL_COLUMNS} columns. ")
    L[-1] += (f"Full columns, indexes, grants and RLS: [DB schema reference]({REFERENCE_LINK}) (search for "
              f"`{sch}.<table>`). Generated file: change the schema through a migration, not this page.")
    w("")
    if not base and views:
        w("This schema has no tables: the diagram shows its views (no keys, no foreign keys).")
        w("")
    w("```mermaid")
    w("erDiagram")
    externals = set()
    for e in own:
        for side in (e["from"], e["to"]):
            s, t = side.split(".", 1)
            if s != sch:
                externals.add(side)
            elif t not in shown_names and t in {x["name"] for x in schema["tables"]}:
                shown_names.add(t)
                shown.append(by_name[side])
    for t in sorted(shown, key=lambda x: x["name"]):
        cols = t["columns"] if full else [c for c in t["columns"] if c["pk"] or c["fk"] or c["uk"]]
        if cols:
            w(f"    {entity(sch, sch, t['name'])} {{")
            for c in cols:
                w(attribute_line(c))
            w("    }")
        else:
            w(f"    {entity(sch, sch, t['name'])}")
    for side in sorted(externals):
        s, t = side.split(".", 1)
        w(f"    {entity(sch, s, t)}")
    for e in own:
        w(relationship(e, sch, by_name))
    w("```")
    w("")
    w("Notation: `||` exactly one, `|o` zero or one (nullable FK), `o{` zero or more, `o|` zero or one "
      "(the FK is the child's PK or a unique key); a dashed line is a `NOT VALID` FK. "
      "Attribute comments are DM-6.1 tags (`pii:<class>`, `conf:<class>`). "
      'A quoted `"schema.table"` box is the parent table in another schema; foreign keys of other schemas '
      "that point here are listed below, and drawn on their own schema's page.")
    w("")
    w("## Tables")
    w("")
    w("| table | kind | columns | primary key | FKs out | FKs in | DM-6.1 tagged columns |")
    w("|---|---|---|---|---|---|---|")
    for t in schema["tables"]:
        full_name = f"{sch}.{t['name']}"
        out_n = sum(1 for e in model["edges"] if e["from"] == full_name)
        in_n = sum(1 for e in model["edges"] if e["to"] == full_name)
        tagged = ", ".join(f"`{c['name']}` {c['tag']}" for c in t["columns"] if c.get("tag"))
        kind = t["kind"] + (" (partition)" if t["is_partition"] else "")
        pk = ", ".join(f"`{c}`" for c in t["primary_key"])
        w(f"| `{t['name']}` | {kind} | {len(t['columns'])} | {pk} | {out_n} | {in_n} | {cell(tagged)} |")
    w("")
    w("## Foreign keys")
    w("")
    L.extend(fk_table(own))
    w("## Foreign keys in from other schemas")
    w("")
    L.extend(fk_table(incoming))
    return "\n".join(L)


def render_index(model: dict) -> str:
    title = "Entity relationship diagrams (live)"
    L = front_matter("APP-04-erd", title,
                     "Index of the generated Mermaid ERD pages, one per schema of the shared RDS (CIS, Booking, "
                     "TripPlanner), with owners, counts and the cross-schema foreign keys.",
                     ["aa-cis-dev-db", "ecosystem"], _date(model, "platform"), ["APP-04", "AA-894"])
    w = L.append
    w(f"# {title}")
    w("")
    w(f"<!-- GENERATED by AA-CIS-Infra db/gen_erd.py ({GENERATOR}) - do not edit -->")
    w("")
    latest = model.get("migrations_latest_per_owner") or {}
    w("One generated Mermaid `erDiagram` per schema of the shared RDS, from the same live catalog dump as the "
      f"[DB schema reference]({REFERENCE_LINK}). Newest migration per owner: "
      + ", ".join(f"{OWNER_LABEL.get(o, o)} **{v}**" for o, v in sorted(latest.items()) if v) + ". "
      "The DB Schema Dump workflow regenerates these pages after every DB Migrate apply and every night and opens "
      "a root PR when the structure changed, so a new or dropped foreign key shows up as a diff here. "
      "Hand-written design diagrams (AA-894 scope 3) go to `design/` next to these pages, never into them.")
    w("")
    w("| schema | owner | tables | views | FKs out | page |")
    w("|---|---|---|---|---|---|")
    empty = []
    for s in model["schemas"]:
        if not s["tables"]:
            empty.append(s["schema"])
            continue
        base = sum(1 for t in s["tables"] if t["kind"] in BASE_KINDS)
        out_n = sum(1 for e in model["edges"] if e["from"].split(".", 1)[0] == s["schema"])
        w(f"| `{s['schema']}` | {OWNER_LABEL.get(s['owner_app'], s['owner_app'])} | {base} | "
          f"{len(s['tables']) - base} | {out_n} | [{s['schema']}.md]({s['schema']}.md) |")
    w("")
    w(f"Empty schemas (no page): {', '.join(f'`{s}`' for s in empty) or 'none'}.")
    w("")
    w("## Cross-schema foreign keys")
    w("")
    cross = [e for e in model["edges"] if e["cross_schema"]]
    pairs: dict = {}
    for e in cross:
        key = (e["from"].split(".", 1)[0], e["to"].split(".", 1)[0])
        pairs[key] = pairs.get(key, 0) + 1
    if pairs:
        w("| from schema | to schema | owners | FKs |")
        w("|---|---|---|---|")
        for (a, b), n in sorted(pairs.items()):
            owners = OWNER_LABEL.get(owner_app(a), owner_app(a))
            if owner_app(a) != owner_app(b):
                owners += " -> " + OWNER_LABEL.get(owner_app(b), owner_app(b))
            w(f"| `{a}` | `{b}` | {owners} | {n} |")
    else:
        w("None.")
    w("")
    w("### Between two owners")
    w("")
    w("A foreign key from one owner's schema to another's is a finding of the RLS catalogue guard (rule e) "
      "unless it is on the guard's allowlist (see the DB schema reference).")
    w("")
    L.extend(fk_table([e for e in cross if e["cross_owner"]]))
    w("## Machine-readable model")
    w("")
    w("The DB Schema Dump run also writes `erd.json` (schemas, tables, columns with full types, PK, unique keys, "
      "FKs, DM-6.1 tags, owner; no row data) as a run artifact, the input of the CIS admin data-model view "
      "(AA-894 scope 2).")
    w("")
    return "\n".join(L)


def write_pages(model: dict, out_dir: str) -> list[str]:
    """Writes README.md + one page per non-empty schema; returns the file names written (sorted)."""
    os.makedirs(out_dir, exist_ok=True)
    files = {"README.md": render_index(model)}
    for s in model["schemas"]:
        if s["tables"]:
            files[f"{s['schema']}.md"] = render_schema(model, s)
    for name, text in files.items():
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as f:
            f.write(text)
    return sorted(files)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("dump", help="JSON written by db/schema_dump.py")
    parser.add_argument("--out-dir", help="directory for README.md + <schema>.md")
    parser.add_argument("--json", help="erd.json path")
    parser.add_argument("--source", help="provenance written into erd.json, e.g. the workflow run URL")
    parser.add_argument("--fingerprint", action="store_true", help="print the ERD model fingerprint only")
    args = parser.parse_args(argv)
    with open(args.dump, encoding="utf-8") as f:
        dump = json.load(f)
    if dump.get("format") != 2:
        print(f"unsupported dump format {dump.get('format')!r} (expected 2)", file=sys.stderr)
        return 2
    model = build_model(dump, args.source)
    if args.fingerprint:
        print(model["fingerprint"])
        return 0
    if not args.out_dir and not args.json:
        parser.error("give --out-dir and/or --json")
    if args.out_dir:
        names = write_pages(model, args.out_dir)
        print(f"written {args.out_dir}: {len(names)} page(s), model fingerprint {model['fingerprint'][:12]}")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            f.write(json_text(model))
        print(f"written {args.json}: {len(model['schemas'])} schemas, {len(model['edges'])} FK edges")
    return 0


if __name__ == "__main__":
    sys.exit(main())
