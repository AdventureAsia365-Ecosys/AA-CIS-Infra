"""Renders AA-Ecosys docs/architecture/db-schema-reference.md from a schema_dump.py JSON (AA-807 N1).

Usage:
  python3 db/gen_schema_reference.py dump.json --out db-schema-reference.md [--source "run URL"]
  python3 db/gen_schema_reference.py dump.json --fingerprint     # print the structural fingerprint

Standard library only (runs on the GitHub runner). Output is deterministic for a given dump.

The file carries `<!-- schema-fingerprint: … -->`: a sha256 of the dump WITHOUT the volatile parts
(row estimates, sizes, scan counters, sessions, timestamps). The workflow opens or updates the root
PR only when the fingerprint differs from the one on the root repo's master, so a night where only
statistics moved does not produce a PR.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import sys
from collections import defaultdict
from typing import Optional

FINGERPRINT_RE = re.compile(r"<!-- schema-fingerprint: ([0-9a-f]{64}) -->")
INDEX_RE = re.compile(r"^CREATE (UNIQUE )?INDEX \S+ ON (?:ONLY )?\S+ USING (.*)$")
TRIGGER_RE = re.compile(r"^CREATE (?:CONSTRAINT )?TRIGGER \S+ (.*)$")
KIND_LABEL = {"table": "table", "partitioned table": "partitioned table", "view": "VIEW",
              "materialized view": "MATERIALIZED VIEW", "foreign table": "foreign table"}
DEFAULT_ACL_OBJECT = {"r": "tables", "S": "sequences", "f": "functions", "T": "types", "n": "schemas"}
LATEST_MIGRATIONS = 20


def structural_view(dump: dict) -> dict:
    """The dump without the parts that change while the schema does not."""
    d = copy.deepcopy(dump)
    for key in ("generated_at", "connections"):
        d.pop(key, None)
    db = d.get("database") or {}
    for key in ("size_bytes", "stats_reset"):
        db.pop(key, None)
    for rels in d.get("relations", {}).values():
        for rel in rels.values():
            for key in ("est_rows", "size", "activity"):
                rel.pop(key, None)
            for idx in rel.get("indexes", []):
                idx.pop("bytes", None)
                idx.pop("scans", None)
    for key in d.get("soft_keys", []):
        for count in ("total", "without_key", "orphans", "orphan_rate"):
            key.pop(count, None)
    return d


def fingerprint(dump: dict) -> str:
    blob = json.dumps(structural_view(dump), sort_keys=True, default=str).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def human_bytes(n) -> str:
    if n is None:
        return ""
    size = float(n)
    for unit in ("B", "kB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{int(size)} {unit}" if unit == "B" else f"{size:.1f} {unit}".replace(".0 ", " ")
        size /= 1024
    return f"{size:.1f} TB"


def cell(value) -> str:
    text = "" if value is None else str(value)
    return text.replace("|", "\\|").replace("\n", " ")


def short_index(definition: str) -> str:
    m = INDEX_RE.match(definition)
    return f"{'UNIQUE ' if m.group(1) else ''}{m.group(2)}" if m else definition


def short_trigger(definition: str) -> str:
    m = TRIGGER_RE.match(definition)
    return m.group(1) if m else definition


def stamp(ts) -> str:
    return str(ts)[:16].replace("T", " ") if ts else ""


def render(d: dict, source: Optional[str] = None) -> str:
    L: list[str] = []
    w = L.append
    rels = d["relations"]
    latest = d.get("migrations_latest_per_owner", {})
    db = d.get("database") or {}
    n_rel = sum(len(v) for v in rels.values())
    empty = [s["schema"] for s in d["schemas"] if not rels.get(s["schema"])]
    fks = [(sch, name, c) for sch, rs in sorted(rels.items()) for name, r in sorted(rs.items())
           for c in r["constraints"] if c["type"] == "f"]

    w("# AA-Ecosys DB Schema Reference (live dump)")
    w("")
    w(f"<!-- schema-fingerprint: {fingerprint(d)} -->")
    w("")
    w(f"**Verified:** {stamp(d['generated_at'])} UTC — live catalog dump of the shared RDS (`aa-cis-dev-db`, "
      f"`aa-cis/dev/rds`, acc2 `005097885195`, us-west-1, PostgreSQL {db.get('server_version', '?')}). "
      f"Latest migration per owner: CIS **{latest.get('cis')}**, TripPlanner **{latest.get('tripplanner')}**, "
      f"Booking **{latest.get('booking')}** ({len(d.get('migrations', []))} versions registered).")
    w("")
    w("> **Generated file — do not edit by hand** (data standards DM-3.1). It is the single source of truth for "
      "table/column names, owners, grants and RLS across CIS, TripPlanner and Booking (one RDS, one schema per "
      "owner; ownership rules: `docs/database/schema-ownership.md`). Read it before introspecting columns. "
      "AA-CIS-Infra `.github/workflows/db-schema-dump.yml` regenerates it after every DB Migrate apply and every "
      "night (`db/schema_dump.py` in a one-off ECS task, then `db/gen_schema_reference.py`) and opens a PR here "
      "when the structure changed.")
    if source:
        w(f"> Source: {source}")
    w("")
    w(f"**Totals:** {len(d['schemas'])} schemas ({len(empty)} empty: {', '.join(empty) or 'none'}), "
      f"{n_rel} tables/views, {d['counts'].get('indexes', 0)} indexes, {len(fks)} FKs, "
      f"{d['counts'].get('policies', 0)} RLS policy(ies), {len(d.get('functions', []))} functions, "
      f"{len(d.get('enums', []))} enums. Database size {human_bytes(db.get('size_bytes'))}, "
      f"max_connections {db.get('max_connections', '?')}.")
    w("")
    w("## Conventions")
    w("- Column format: `name type` — `NN` suffix = NOT NULL. Types are `format_type()` output "
      "(`character varying(64)`, `text[]`, `vector(1024)`, enums schema-qualified).")
    w("- `~N rows` = `pg_class.reltuples` estimate, sizes = `pg_total_relation_size`, both as of the Verified line "
      "(a PR is opened only when the structure changes, so these lag between structural changes). "
      "Run exact counts before any drop decision.")
    w("- Under each object: owner and RLS state (`RLS on` = ENABLE, `+ FORCE` = FORCE ROW LEVEL SECURITY; the owner "
      "is exempt unless FORCE), indexes, CHECK constraints, grants to roles other than the owner (`*` = WITH GRANT "
      "OPTION), column-level grants, RLS policies and triggers. Usage counters are in *Table activity* at the end.")
    w("- `raw_tours` PK is `tour_id` (NOT `id`). `quality_scores` has `evaluated_at` (NOT `created_at`). "
      "`published_tours`/`seo_context` have NO `country` — always JOIN `raw_tours`.")
    w("")
    w("## Schemas")
    w("")
    w("| schema | owner | objects | size | grants (USAGE / CREATE) |")
    w("|---|---|---|---|---|")
    for s in d["schemas"]:
        rs = rels.get(s["schema"], {})
        size = sum((r.get("size") or {}).get("total") or 0 for r in rs.values())
        grants = "; ".join(f"{g['grantee']}: {g['privileges']}" for g in s.get("grants", []))
        w(f"| `{s['schema']}` | {cell(s['owner'])} | {len(rs)} | {human_bytes(size) if size else ''} | {cell(grants)} |")
    w("")

    for sch in sorted(rels):
        rs = rels[sch]
        if not rs:
            continue
        w(f"## `{sch}` ({len(rs)} objects)")
        w("")
        for name in sorted(rs):
            r = rs[name]
            bits = [KIND_LABEL.get(r["kind"], r["kind"])]
            if r.get("est_rows") is not None and r["est_rows"] >= 0:
                bits.append(f"~{r['est_rows']} rows")
            if r.get("size"):
                bits.append(human_bytes(r["size"].get("total")))
            w(f"### `{sch}.{name}` ({', '.join(bits)})")
            w("```")
            for c in r["columns"]:
                w(f"{c['name']} {c['type']}{' NN' if c['not_null'] else ''}")
            w("```")
            meta = [f"owner `{r['owner']}`"]
            if r.get("rls"):
                meta.append("RLS on + FORCE" if r.get("rls_forced") else "RLS on")
            if r.get("is_partition"):
                meta.append("partition")
            w(f"- {' · '.join(meta)}")
            for i in r["indexes"]:
                label = " PRIMARY KEY" if i.get("is_primary") else ""
                invalid = " **INVALID** (failed CONCURRENTLY build — drop and rebuild)" if not i.get("is_valid", True) else ""
                w(f"- index `{i['index']}`{label}: {short_index(i['definition'])}{invalid}")
            for c in r["constraints"]:
                if c["type"] == "c":
                    nv = " NOT VALID" if not c.get("validated", True) else ""
                    w(f"- check `{c['constraint']}`: {c['definition']}{nv}")
            for g in r["grants"]:
                w(f"- grant `{g['grantee']}`: {g['privileges'].replace(',', ', ')}")
            by_grant: dict = defaultdict(list)
            for g in r["column_grants"]:
                by_grant[(g["grantee"], g["privileges"])].append(g["column"])
            for (grantee, privs), columns in sorted(by_grant.items()):
                w(f"- column grant `{grantee}`: {privs.replace(',', ', ')} ({', '.join(sorted(columns))})")
            for p in r["policies"]:
                roles = ", ".join(p.get("roles") or []) or "public"
                body = []
                if p.get("qual"):
                    body.append(f"USING `{p['qual']}`")
                if p.get("with_check"):
                    body.append(f"WITH CHECK `{p['with_check']}`")
                w(f"- policy `{p['policy']}` ({p['permissive']} {p['cmd']} TO {roles}): {' '.join(body) or '(no expression)'}")
            for t in r["triggers"]:
                disabled = " (disabled)" if t.get("enabled") == "D" else ""
                w(f"- trigger `{t['trigger']}`: {short_trigger(t['definition'])}{disabled}")
            w("")

    w("## Roles")
    w("")
    w("Roles other than `pg_*` / `rds*`. Passwords are never part of the dump.")
    w("")
    member_of: dict = defaultdict(list)
    for m in d.get("role_members", []):
        member_of[m["member"]].append(m["role"] + (" (admin)" if m.get("admin_option") else ""))
    w("| role | login | superuser | bypassrls | connection limit | settings | member of |")
    w("|---|---|---|---|---|---|---|")
    for r in d.get("roles", []):
        limit = "none" if r.get("connection_limit", -1) == -1 else r["connection_limit"]
        settings = ", ".join(f"{k}={v}" for k, v in sorted((r.get("config") or {}).items()))
        w(f"| `{r['role']}` | {'yes' if r.get('login') else 'no'} | {'yes' if r.get('superuser') else 'no'} | "
          f"{'yes' if r.get('bypassrls') else 'no'} | {limit} | {cell(settings)} | "
          f"{cell(', '.join(sorted(member_of.get(r['role'], []))))} |")
    w("")
    w("## Default privileges")
    w("")
    w("Grants applied automatically to objects that `role` creates later (`ALTER DEFAULT PRIVILEGES`).")
    w("")
    w("| role | schema | objects | grantee | privileges |")
    w("|---|---|---|---|---|")
    for a in d.get("default_privileges", []):
        w(f"| `{a['role']}` | {cell(a.get('schema') or '(all)')} | "
          f"{DEFAULT_ACL_OBJECT.get(a['object_type'], a['object_type'])} | `{a['grantee']}` | {cell(a['privileges'])} |")
    w("")
    w("## Functions")
    w("")
    w("Extension-owned functions are left out. `SECURITY DEFINER` functions run with the owner's rights.")
    w("")
    w("| function | returns | language | owner | security definer |")
    w("|---|---|---|---|---|")
    for f in d.get("functions", []):
        kind = {"p": "procedure", "a": "aggregate", "w": "window"}.get(f.get("kind"), "")
        w(f"| `{f['schema']}.{f['name']}({cell(f['args'])})` | {cell(f.get('result') or kind)} | {f['language']} | "
          f"`{f['owner']}` | {'**yes**' if f.get('security_definer') else 'no'} |")
    w("")
    w("## Extensions")
    w("")
    for e in d.get("extensions", []):
        w(f"- `{e['name']}` {e['version']} (schema `{e['schema']}`)")
    w("")
    w("## Enums")
    w("")
    for e in d.get("enums", []):
        w(f"- `{e['schema']}.{e['name']}`: {', '.join(repr(str(label)) for label in e['labels'])}")
    w("")
    w("## Foreign keys")
    w("")
    w("Format: `child.col` -> `parent.col` (multi-column keys as `(a,b)`).")
    w("```")
    for sch, name, c in sorted(fks, key=lambda x: (x[0], x[1], x[2]["columns"] or "", x[2]["constraint"])):
        cols, ref_cols = c.get("columns") or "", c.get("ref_columns") or ""
        cols = f"({cols})" if "," in cols else cols
        ref_cols = f"({ref_cols})" if "," in ref_cols else ref_cols
        nv = "  NOT VALID" if not c.get("validated", True) else ""
        w(f"{sch}.{name}.{cols} -> {c['ref_schema']}.{c['ref_name']}.{ref_cols}{nv}")
    w("```")
    w("")
    w("## Table activity")
    w("")
    w(f"`pg_stat_user_tables` counters since the last stats reset ({stamp(db.get('stats_reset')) or 'never'}), "
      "as of the Verified line. Use them with the 14-day rule of the Dead Table Registry, not alone.")
    w("")
    w("| table | ~rows | size | seq scans | idx scans | ins / upd / del | dead tuples | last autovacuum |")
    w("|---|---|---|---|---|---|---|---|")
    for sch in sorted(rels):
        for name in sorted(rels[sch]):
            r = rels[sch][name]
            a = r.get("activity")
            if not a:
                continue
            w(f"| `{sch}.{name}` | {r.get('est_rows') if (r.get('est_rows') or 0) >= 0 else ''} | "
              f"{human_bytes((r.get('size') or {}).get('total'))} | {a.get('seq_scan') or 0} | {a.get('idx_scan') or 0} | "
              f"{a.get('n_tup_ins') or 0} / {a.get('n_tup_upd') or 0} / {a.get('n_tup_del') or 0} | "
              f"{a.get('n_dead_tup') or 0} | {stamp(a.get('last_autovacuum'))} |")
    w("")
    unused = [(sch, name, i) for sch in sorted(rels) for name in sorted(rels[sch])
              for i in rels[sch][name]["indexes"]
              if not i.get("is_primary") and not i.get("is_unique") and (i.get("scans") or 0) == 0]
    w("## Unused indexes")
    w("")
    w("Non-PK, non-unique indexes with 0 scans since the stats reset. A drop candidate only after 30 days at 0 "
      "(standards C5.2d), through expand/contract.")
    w("")
    for sch, name, i in unused:
        w(f"- `{sch}.{i['index']}` on `{name}` ({human_bytes(i.get('bytes'))})")
    if not unused:
        w("- none")
    w("")
    w("## Soft-key orphans (DM-4.2)")
    w("")
    w("Cross-app keys that have no FK (data standards DM-2.3) and how many rows point at nothing in the target, as of "
      "the Verified line (counts lag between structural changes, like `~rows`). `not_applicable` = the key columns or "
      "the target do not exist yet; `no_privilege` = the dump role cannot read one side. Orphan rate = orphans / rows "
      "with a key.")
    w("")
    w("| key | status | rows | without key | orphans | orphan rate |")
    w("|---|---|---|---|---|---|")
    for k in d.get("soft_keys", []):
        rate = "" if k.get("orphan_rate") is None else f"{k['orphan_rate']:.2%}"
        w(f"| {cell(k['name'])} | {cell(k['status'])} | {cell(k.get('total'))} | {cell(k.get('without_key'))} | "
          f"{cell(k.get('orphans'))} | {rate} |")
    if not d.get("soft_keys"):
        w("| none | | | | | |")
    w("")
    w("## Connections at dump time")
    w("")
    w("Client sessions per `application_name` (`(empty)` = a pool without `application_name`, standards C1.1a).")
    w("")
    w("| application_name | role | state | sessions |")
    w("|---|---|---|---|")
    for c in d.get("connections", []):
        w(f"| {cell(c['application_name'])} | {cell(c['role'])} | {cell(c['state'])} | {c['sessions']} |")
    w("")
    w("## Latest migrations")
    w("")
    w("| version | applied_at | description |")
    w("|---|---|---|")
    for m in d.get("migrations", [])[:LATEST_MIGRATIONS]:
        w(f"| {cell(m['version'])} | {cell(m['applied_at'])} | {cell(m['description'])} |")
    w("")
    return "\n".join(L)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("dump", help="JSON written by db/schema_dump.py")
    parser.add_argument("--out", help="Markdown file to write (default: stdout)")
    parser.add_argument("--source", help="provenance line, e.g. the workflow run URL")
    parser.add_argument("--fingerprint", action="store_true", help="print the structural fingerprint only")
    args = parser.parse_args(argv)
    with open(args.dump, encoding="utf-8") as f:
        dump = json.load(f)
    if dump.get("format") != 2:
        print(f"unsupported dump format {dump.get('format')!r} (expected 2)", file=sys.stderr)
        return 2
    if args.fingerprint:
        print(fingerprint(dump))
        return 0
    text = render(dump, args.source)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"written {args.out}: {len(text.splitlines())} lines, fingerprint {fingerprint(dump)[:12]}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
