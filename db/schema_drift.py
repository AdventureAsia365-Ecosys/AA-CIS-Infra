"""Schema drift: the live catalog against a replay of every migration (AA-853, data standards MIG-5).

Input: two db/schema_dump.py JSON files, the live dump and the dump of the scratch database db/replay_migrations.py
built from all owner migrations, plus that replay's results and db/schema_drift_decisions.json. Standard library
only; runs on the GitHub runner in the DB Schema Dump workflow, and gen_schema_reference.py renders its result as a
section of the root db-schema-reference.md (render_markdown).

Objects compared (structure, never row data): schemas; tables / views / materialized views (kind); columns (type,
NOT NULL); indexes (definition); CHECK and FK constraints (definition); RLS policies (permissive, roles, command,
USING, WITH CHECK); triggers (definition, enabled); functions by signature (result, kind, language, SECURITY
DEFINER); enums (labels). Privileges are compared as a separate, informational class: owners of schemas,
relations and functions; schema, table and column grants; default privileges.

Classes:
  unmanaged   on Dev, not produced by any migration: DDL outside DB Migrate, or a migration that is not in any
              repo. The headline number ("0 unmanaged objects" is the target of AA-853).
  missing     produced by the migrations, absent on Dev: dropped by hand, or a migration whose apply differed.
  changed     on both, with a different definition (type, index definition, policy text, …).
  privileges  owner / grant / default-privilege differences (the replay runs as DB Migrate did, so these are
              real too, but they also move with the role bootstrap of the replay: reported, not counted as drift).
A child of an unmanaged or missing relation (its columns, indexes, …) is folded into the relation, and a relation
of an unmanaged or missing schema into the schema, so one lost CREATE TABLE is one finding.

Every unmanaged / missing / changed finding carries:
  owner        the owner of its schema (run_migration.OWNER_DIRS, mirror of db/owners.yaml), or '-' (public, …)
  explained_by the replay files that FAILED (or ran partly) and name the object, i.e. the likely cause is a
               replay gap, not drift on Dev; fix the replay (a baseline file) or the migration history
  decision     the matching entry of db/schema_drift_decisions.json (owner decision: keep as is, drop, write the
               missing migration, …). `open` counts findings with no decision.

Fingerprint (the workflow opens the root PR when it moves): the findings that NO replay gap explains, with their
diff and decision. Findings with explained_by are replay noise until the AA-ACP-Core baseline lands (an owner
editing an old file that then fails differently would otherwise open a PR); they stay in the section and the counts.
The report is informational: nothing fails on a finding (MIG-5 fail-on-unmanaged waits for the baseline and the
owner decisions).

Usage:
  python3 db/schema_drift.py live.json replay.json --replay-results results.json \
      [--decisions db/schema_drift_decisions.json] [--out drift.json] [--summary FILE]
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import run_migration  # noqa: E402  (OWNER_DIRS: owner of each schema)

FORMAT = 1
CLASSES = ("unmanaged", "missing", "changed")
SECTION_LIMIT = 100          # rows listed per table in the rendered section (every finding is in drift.json)


def schema_owner(schema: str) -> str:
    for owner, d in run_migration.OWNER_DIRS.items():
        if schema in d.schemas:
            return owner
    return "-"


def _norm(text) -> str:
    return " ".join(str(text or "").split())


def objects(dump: dict) -> dict:
    """{id: (kind, schema, parent_id, attrs)} for the structural objects of a dump. Ids are 'kind schema.name…'."""
    out: dict = {}

    def add(kind: str, schema: str, name: str, parent: str | None, attrs: dict) -> str:
        oid = f"{kind} {name}"
        out[oid] = (kind, schema, parent, attrs)
        return oid

    for s in dump.get("schemas", []):
        add("schema", s["schema"], s["schema"], None, {})
    for schema, rels in (dump.get("relations") or {}).items():
        sid = f"schema {schema}"
        for name, r in rels.items():
            q = f"{schema}.{name}"
            rid = add("relation", schema, q, sid, {"kind": r.get("kind")})
            for c in r.get("columns", []):
                add("column", schema, f"{q}.{c['name']}", rid, {"type": c.get("type"), "not_null": c.get("not_null")})
            for i in r.get("indexes", []):
                add("index", schema, f"{q} {i['index']}", rid, {"definition": _norm(i.get("definition"))})
            for c in r.get("constraints", []):
                add("constraint", schema, f"{q} {c['constraint']}", rid,
                    {"type": c.get("type"), "definition": _norm(c.get("definition"))})
            for p in r.get("policies", []):
                add("policy", schema, f"{q} {p['policy']}", rid,
                    {"permissive": p.get("permissive"), "roles": sorted(p.get("roles") or []), "cmd": p.get("cmd"),
                     "qual": _norm(p.get("qual")), "with_check": _norm(p.get("with_check"))})
            for t in r.get("triggers", []):
                add("trigger", schema, f"{q} {t['trigger']}", rid,
                    {"definition": _norm(t.get("definition")), "enabled": t.get("enabled")})
    for f in dump.get("functions", []):
        add("function", f["schema"], f"{f['schema']}.{f['name']}({f.get('args') or ''})", f"schema {f['schema']}",
            {"result": f.get("result"), "kind": f.get("kind"), "language": f.get("language"),
             "security_definer": f.get("security_definer")})
    for e in dump.get("enums", []):
        add("enum", e["schema"], f"{e['schema']}.{e['name']}", f"schema {e['schema']}", {"labels": list(e["labels"])})
    return out


def privileges(dump: dict) -> dict:
    """{id: value} of owners and grants."""
    out: dict = {}
    for s in dump.get("schemas", []):
        out[f"owner schema {s['schema']}"] = s.get("owner")
        for g in s.get("grants", []):
            out[f"grant schema {s['schema']} to {g['grantee']}"] = g.get("privileges")
    for schema, rels in (dump.get("relations") or {}).items():
        for name, r in rels.items():
            q = f"{schema}.{name}"
            out[f"owner relation {q}"] = r.get("owner")
            for g in r.get("grants", []):
                out[f"grant {q} to {g['grantee']}"] = g.get("privileges")
            for g in r.get("column_grants", []):
                out[f"grant {q}.{g['column']} to {g['grantee']}"] = g.get("privileges")
    for f in dump.get("functions", []):
        out[f"owner function {f['schema']}.{f['name']}({f.get('args') or ''})"] = f.get("owner")
    for d in dump.get("default_privileges", []):
        out[f"default privileges for {d['role']} in {d.get('schema') or '(all)'} on {d['object_type']} to "
            f"{d['grantee']}"] = d.get("privileges")
    return out


def load_decisions(path: str | None) -> list:
    if not path or not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return list(data.get("decisions", []))


def find_decision(decisions: list, cls: str, oid: str) -> dict | None:
    for d in decisions:
        if d.get("class", cls) != cls:
            continue
        pattern = d.get("id", "")
        if pattern == oid or ("*" in pattern and fnmatch.fnmatchcase(oid, pattern)):
            return d
    return None


def _explained_by(oid: str, schema: str, gaps: list) -> list:
    """Replay files that failed or ran partly and name this object (or its relation)."""
    name = oid.split(" ", 1)[1].split(" ", 1)[0]          # schema.table[.column] or schema.fn(args)
    parts = name.split("(", 1)[0].split(".")
    rel = ".".join(parts[:2]).lower() if len(parts) >= 2 else ""
    hits = []
    for g in gaps:
        names = g.get("names") or []
        if (rel and rel in names) or (not rel and schema in g.get("schemas", [])):
            hits.append(g["rel"])
    return hits[:5]


def diff(live: dict, replay: dict, results: dict | None = None, decisions: list | None = None) -> dict:
    decisions = decisions or []
    results = results or {}
    gaps = [i for i in results.get("items", []) if i.get("status") in ("failed", "partial")]
    lo, ro = objects(live), objects(replay)
    found = {c: [] for c in CLASSES}
    folded = {"unmanaged": set(), "missing": set()}
    # Parents first (schema, relation, then children), so children of a missing / unmanaged parent fold into it.
    order = {"schema": 0, "relation": 1, "function": 1, "enum": 1}
    for cls, src, other in (("unmanaged", lo, ro), ("missing", ro, lo)):
        for oid in sorted(src, key=lambda k: (order.get(src[k][0], 2), k)):
            kind, schema, parent, attrs = src[oid]
            if oid in other:
                continue
            if parent in folded[cls]:
                folded[cls].add(oid)
                continue
            folded[cls].add(oid)
            children = 0
            found[cls].append({"id": oid, "kind": kind, "schema": schema, "owner": schema_owner(schema),
                               "attrs": attrs, "children": children})
        # count folded children per finding
        index = {f["id"]: f for f in found[cls]}
        for oid in folded[cls]:
            p = src[oid][2]
            while p and p not in index and p in src:
                p = src[p][2]
            if p in index and oid not in index:
                index[p]["children"] += 1
    for oid in sorted(set(lo) & set(ro)):
        kind, schema, _parent, la = lo[oid]
        ra = ro[oid][3]
        if la != ra:
            delta = {k: {"live": la.get(k), "replay": ra.get(k)} for k in sorted(set(la) | set(ra))
                     if la.get(k) != ra.get(k)}
            found["changed"].append({"id": oid, "kind": kind, "schema": schema, "owner": schema_owner(schema),
                                     "diff": delta, "children": 0})
    lp, rp = privileges(live), privileges(replay)
    priv = []
    for k in sorted(set(lp) | set(rp)):
        if lp.get(k) != rp.get(k):
            priv.append({"id": k, "live": lp.get(k), "replay": rp.get(k)})
    for cls in CLASSES:
        for f in found[cls]:
            f["explained_by"] = _explained_by(f["id"], f["schema"], gaps)
            d = find_decision(decisions, cls, f["id"])
            f["decision"] = ({k: d.get(k) for k in ("decision", "owner", "ref", "note") if d.get(k)} if d else None)
    counts = {cls: len(found[cls]) for cls in CLASSES}
    counts["unmanaged_objects"] = counts["unmanaged"] + sum(f["children"] for f in found["unmanaged"])
    counts["open"] = sum(1 for cls in CLASSES for f in found[cls] if not f["decision"])
    counts["open_unmanaged"] = sum(1 for f in found["unmanaged"] if not f["decision"])
    counts["explained_by_replay_gap"] = sum(1 for cls in CLASSES for f in found[cls] if f["explained_by"])
    counts["privileges"] = len(priv)
    rc = results.get("counts") or {}
    fp_src = json.dumps({cls: [(f["id"], f.get("diff"), f["decision"]) for f in found[cls] if not f["explained_by"]]
                         for cls in CLASSES}, sort_keys=True, default=str)
    return {
        "format": FORMAT,
        "live_generated_at": live.get("generated_at"),
        "replay_generated_at": results.get("generated_at") or replay.get("generated_at"),
        "fingerprint": hashlib.sha256(fp_src.encode("utf-8")).hexdigest(),
        "counts": counts,
        "replay": {"counts": rc, "server_version": (replay.get("database") or {}).get("server_version"),
                   "gaps": [{"rel": g["rel"], "status": g["status"], "key": g.get("key"), "error": g.get("error")}
                            for g in gaps],
                   "pending": results.get("pending", []), "no_file": results.get("no_file", []),
                   "legacy": results.get("legacy", []), "notes": results.get("notes", [])},
        **found,
        "privileges": priv,
    }


def _cell(text, limit: int = 120) -> str:
    s = str(text if text is not None else "").replace("|", "\\|").replace("\n", " ")
    return s if len(s) <= limit else s[:limit - 1] + "…"


def render_markdown(d: dict, heading: str = "##") -> list:
    """The drift section of db-schema-reference.md (lines)."""
    c, r = d["counts"], d["replay"]
    rc = r.get("counts") or {}
    L = [f"{heading} Schema drift against a replay of all migrations (AA-853)", ""]
    L.append(f"<!-- drift-fingerprint: {d['fingerprint']} -->")
    L.append("")
    L.append(f"AA-CIS-Infra `db/replay_migrations.py` replayed every applied migration (live `shared.schema_versions` "
             f"order) into a scratch PostgreSQL {r.get('server_version') or '?'} and `db/schema_drift.py` compared its "
             f"catalog with the live dump above. Replay: {rc.get('files', '?')} files, {rc.get('ok', '?')} ok, "
             f"{rc.get('partial', 0)} partly (legacy files, psql semantics), {rc.get('failed', '?')} failed; "
             f"{rc.get('legacy', 0)} legacy files without a registry row replayed in number order, "
             f"{len(r.get('no_file', []))} registered versions without a file.")
    L.append("")
    L.append(f"**Unmanaged** (on Dev, no migration creates it): **{c['unmanaged']}** finding(s), "
             f"{c['unmanaged_objects']} object(s) with their children; **{c['open_unmanaged']} without an owner "
             f"decision**. **Missing** (a migration creates it, not on Dev): {c['missing']}. **Changed**: "
             f"{c['changed']}. Findings explained by a failed replay file: {c['explained_by_replay_gap']}. "
             f"Privilege differences (informational): {c['privileges']}. Owner decisions live in AA-CIS-Infra "
             f"`db/schema_drift_decisions.json`; `drift.json` in the workflow artifact has every finding. Report "
             f"only: a finding fails nothing, and findings a replay gap explains do not move the drift fingerprint.")
    L.append("")
    if r.get("gaps"):
        L.append(f"Replay gaps ({len(r['gaps'])}: files that failed or ran partly; their objects show up as unmanaged "
                 f"until the history is fixed or a baseline file covers them):")
        L.append("")
        L.append("| file | key | status | first error |")
        L.append("|---|---|---|---|")
        for g in r["gaps"][:SECTION_LIMIT]:
            L.append(f"| `{g['rel']}` | {_cell(g.get('key') or '-')} | {g['status']} | {_cell(g.get('error'), 140)} |")
        if len(r["gaps"]) > SECTION_LIMIT:
            L.append(f"| … | | | {len(r['gaps']) - SECTION_LIMIT} more in drift.json |")
        L.append("")
    for cls, title in (("unmanaged", "Unmanaged"), ("missing", "Missing"), ("changed", "Changed")):
        items = d.get(cls) or []
        if not items:
            continue
        L.append(f"{heading}# {title} ({len(items)})")
        L.append("")
        L.append("| object | owner | detail | replay gap | decision |")
        L.append("|---|---|---|---|---|")
        for f in items[:SECTION_LIMIT]:
            if cls == "changed":
                detail = "; ".join(f"{k}: live `{_cell(v['live'], 50)}` / replay `{_cell(v['replay'], 50)}`"
                                   for k, v in f["diff"].items())
            else:
                detail = (f"+{f['children']} child object(s)" if f["children"] else "") + \
                    (f" {f['attrs'].get('kind')}" if f["kind"] == "relation" else "")
            dec = f["decision"]
            dec_txt = f"{dec.get('decision', '')} ({dec.get('ref', '')})".strip() if dec else "**open**"
            gap = ", ".join(f"`{x}`" for x in f["explained_by"]) or "-"
            L.append(f"| `{_cell(f['id'], 90)}` | {f['owner']} | {_cell(detail.strip(), 160)} | {gap} | "
                     f"{_cell(dec_txt, 80)} |")
        if len(items) > SECTION_LIMIT:
            L.append(f"| … {len(items) - SECTION_LIMIT} more in drift.json | | | | |")
        L.append("")
    return L


def summary_lines(d: dict) -> list:
    c, rc = d["counts"], d["replay"].get("counts") or {}
    return [
        "### Schema drift (AA-853)",
        f"- replay: {rc.get('files', '?')} files, {rc.get('ok', '?')} ok, {rc.get('partial', 0)} partly, "
        f"{rc.get('failed', '?')} failed",
        f"- unmanaged: {c['unmanaged']} finding(s) ({c['unmanaged_objects']} objects), {c['open_unmanaged']} open",
        f"- missing: {c['missing']}, changed: {c['changed']}, "
        f"explained by a replay gap: {c['explained_by_replay_gap']}",
        f"- privilege differences (informational): {c['privileges']}",
        f"- fingerprint `{d['fingerprint'][:12]}`",
    ]


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("live", help="live dump JSON (db/schema_dump.py)")
    parser.add_argument("replay", help="dump JSON of the replayed database (db/replay_migrations.py --dump)")
    parser.add_argument("--replay-results", help="results JSON of db/replay_migrations.py (--out)")
    parser.add_argument("--decisions", default=str(Path(__file__).resolve().parent / "schema_drift_decisions.json"))
    parser.add_argument("--out", help="drift JSON to write")
    parser.add_argument("--summary", help="append a short Markdown summary here (GITHUB_STEP_SUMMARY)")
    parser.add_argument("--markdown", help="write the rendered section here")
    args = parser.parse_args(argv)
    live = json.loads(Path(args.live).read_text(encoding="utf-8"))
    replay = json.loads(Path(args.replay).read_text(encoding="utf-8"))
    results = json.loads(Path(args.replay_results).read_text(encoding="utf-8")) if args.replay_results else {}
    d = diff(live, replay, results, load_decisions(args.decisions))
    if args.out:
        Path(args.out).write_text(json.dumps(d, indent=1, sort_keys=True, default=str), encoding="utf-8")
    if args.markdown:
        Path(args.markdown).write_text("\n".join(render_markdown(d)) + "\n", encoding="utf-8")
    lines = summary_lines(d)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
