"""Renders AA-Ecosys docs/architecture/db-schema-reference.md from a schema_dump.py JSON (AA-807 N1).

Usage:
  python3 db/gen_schema_reference.py dump.json --out db-schema-reference.md [--source "run URL"]
  python3 db/gen_schema_reference.py dump.json --fingerprint     # print the structural fingerprint
  python3 db/gen_schema_reference.py dump.json --rls-guard       # X2 RLS catalogue guard summary + annotations

Standard library only (runs on the GitHub runner). Output is deterministic for a given dump.

The file carries `<!-- schema-fingerprint: … -->`: a sha256 of the dump WITHOUT the volatile parts
(row estimates, sizes, scan counters, sessions, timestamps). The workflow opens or updates the root
PR only when the fingerprint differs from the one on the root repo's master, so a night where only
statistics moved does not produce a PR. The fingerprint also covers the outcome of the X2 RLS catalogue guard
(db/rls_catalogue_rules.py, a byte copy of AA-CIS-App tests/integration/rls_catalogue_rules.py): a change to the
rules or the allowlist reaches the file on the next run, even when the catalog did not change.

Data standards DM-6.1 (AA-877): each column's `pii:<class>` / `conf:<class>` tag (parse_tag, read from the raw
comment the dump carries) is rendered after the column and collected in *Personal and confidential data tags (DM-6.1)*, with the untagged
candidates of the Booking and TripPlanner schemas (PII_CANDIDATE_*). The fingerprint covers the tags and the candidate
outcome, never the free text of a comment, so editing an untagged comment opens no PR.

Public repos (AA-981, S248 d15): the page names the account by its label only (acc2), and the rendered text goes
through AA-CIS-Infra tools/docs/aws_mask.py (account ids -> `{acc2}`-style labels, ARNs without partition and
account, EC2/VPC ids masked) with a no-leak assertion, so a catalog comment or policy that quotes an ARN or an
account id cannot publish it. UUIDs (the AA master tenant id) are not touched.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import sys
from collections import defaultdict
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # the rules module sits next to this file
import rls_catalogue_rules as rls  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools", "docs"))
import aws_mask  # noqa: E402   AA-981: tools/docs/aws_mask.py (stdlib only)

FINGERPRINT_RE = re.compile(r"<!-- schema-fingerprint: ([0-9a-f]{64}) -->")
INDEX_RE = re.compile(r"^CREATE (UNIQUE )?INDEX \S+ ON (?:ONLY )?\S+ USING (.*)$")
TRIGGER_RE = re.compile(r"^CREATE (?:CONSTRAINT )?TRIGGER \S+ (.*)$")
KIND_LABEL = {"table": "table", "partitioned table": "partitioned table", "view": "VIEW",
              "materialized view": "MATERIALIZED VIEW", "foreign table": "foreign table"}
DEFAULT_ACL_OBJECT = {"r": "tables", "S": "sequences", "f": "functions", "T": "types", "n": "schemas"}
LATEST_MIGRATIONS = 20

# Data standards DM-6.1 (AA-877): a column holding personal data carries COMMENT 'pii:<class>; <free text>',
# commercial secrets 'conf:commercial; …', credentials 'conf:credential; …'. The classes below are the standard's list;
# any other class is reported as a finding here and fails the migration lint (db/check_migration_files.py, which
# imports this table). The dump carries the raw comment; parsing happens here only. Standards v1.3 (AA-929, partner
# CRM): government_id (passport / ID document data), health (special category, stored only with consent) and
# emergency_contact (a third person's contact details).
TAG_CLASSES = {
    "pii": ("contact", "name", "address", "profile", "online_id", "free_text", "travel", "payment",
            "government_id", "health", "emergency_contact"),
    "conf": ("commercial", "credential"),
}
# The leading tag, ended by ';', ' —' / ' –' / ' -' (the tp-011 form 'conf:credential — …') or the end of the text.
LEADING_TAG_RE = re.compile(r"^\s*((?:pii|conf):[a-z_]+)(?=\s*;|\s+[\u2014\u2013-](?:\s|$)|\s*$)")
ANY_TAG_RE = re.compile(r"(?<![a-z_])((?:pii|conf):[a-z_]+)")

# DM-6.1 untagged-candidate check (AA-877; seed of the X2+ lint). A column of these schemas whose snake_case name
# contains one of the tokens (whole tokens: 'mission' is not 'iss', 'subject' is not 'sub') must carry a tag or an
# entry below with a one-line reason. Keep the reasons short; an entry that matches nothing is reported as stale.
PII_CANDIDATE_SCHEMAS = ("booking", "crm", "tripplanner")   # crm: the partner CRM from its first table (AA-929)
PII_CANDIDATE_TOKENS = frozenset({
    "email", "phone", "name", "address", "note", "notes", "message", "payload", "snapshot", "title", "summary",
    "label", "sub", "iss", "data", "itinerary",
})
PII_ALLOWLIST = {
    "booking.countries.name": "reference data: country name",
    "booking.hotels.name": "a hotel (business) name",
    "booking.hotels.address": "a hotel (business) address",
    "booking.hotel_room_types.name": "a room type name",
    "booking.services.title": "internal working title of a supplier service (bk-010), no customer data",
    "booking.supplier_contracts.title": "a contract title, no customer data",
    "booking.suppliers.company_name": "a supplier company name; the contact person is suppliers.contact_name",
    "booking.suppliers.address": "a supplier business address (AA-877 decision: a sole-trader guide's business "
                                 "address is covered by the supplier-contacts RoPA activity, not tagged)",
    "booking.trip_case_version_itinerary.title": "itinerary item title (tour, hotel or service name)",
    "booking.job.payload": "job payloads carry ids only (DM-6.3; the intake enqueues {inbox_event_id}, staff_email "
                           "the notification id)",
    "tripplanner.narration_cache.itinerary_hash": "hash of a catalog itinerary (cache key), no identity",
}


def parse_tag(comment) -> tuple:
    """(tag, also) of a column comment under DM-6.1: the leading 'pii:<class>' / 'conf:<class>' (None when the
    comment does not start with one) and every other tag named later in the text, in order, without repeats.
    'pii:contact; also pii:name and pii:free_text (…)' (bk-012) -> ('pii:contact', ['pii:name', 'pii:free_text']).
    A comment that names a tag but does not start with one gives (None, [the tags]): a misplaced tag (finding)."""
    if not comment:
        return None, []
    m = LEADING_TAG_RE.match(comment)
    tag = m.group(1) if m else None
    rest = comment[m.end():] if m else comment
    also = []
    for t in ANY_TAG_RE.findall(rest):
        if t != tag and t not in also:
            also.append(t)
    return tag, also


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
            for col in rel.get("columns", []):
                tag, also = parse_tag(col.pop("comment", None))   # free text: only the DM-6.1 tag is structure
                if tag:
                    col["tag"] = tag
                if also:
                    col["also"] = also
    for key in d.get("soft_keys", []):
        for count in ("total", "without_key", "orphans", "orphan_rate"):
            key.pop(count, None)
    return d


def rls_guard_state(dump: dict) -> dict:
    """The X2 guard outcome in a stable form (part of the fingerprint)."""
    result = rls.check(dump)
    return {"violations": [list(f[:3]) for f in result.violations],
            "allowlisted": [[f.rule, f.key, reason] for f, reason in result.allowlisted],
            "stale": [list(x) for x in result.stale]}


def _tokens(column: str) -> set:
    return set(column.lower().split("_"))


def pii_tags(dump: dict) -> dict:
    """DM-6.1 view of the dump: tagged columns, findings (unknown class, misplaced tag), untagged candidates of
    PII_CANDIDATE_SCHEMAS (not on PII_ALLOWLIST), the allowlist entries used and the stale ones."""
    tagged, findings, candidates, allowlisted = [], [], [], []
    for sch in sorted(dump.get("relations", {})):
        rels = dump["relations"][sch]
        for name in sorted(rels):
            for c in rels[name].get("columns", []):
                key = f"{sch}.{name}.{c['name']}"
                tag, also = parse_tag(c.get("comment"))
                if tag:
                    tagged.append({"schema": sch, "relation": name, "column": c["name"], "tag": tag, "also": also})
                for t in [tag] + also if tag else []:
                    kind, _, klass = t.partition(":")
                    if klass not in TAG_CLASSES.get(kind, ()):
                        findings.append({"key": key, "finding": f"unknown class {t}"})
                if not tag and also:
                    findings.append({"key": key, "finding": "names " + ", ".join(also)
                                     + " but does not start with a tag ('<kind>:<class>; ...')"})
                if sch in PII_CANDIDATE_SCHEMAS and not tag and _tokens(c["name"]) & PII_CANDIDATE_TOKENS:
                    if key in PII_ALLOWLIST:
                        allowlisted.append(key)
                    else:
                        candidates.append(key)
    stale = sorted(set(PII_ALLOWLIST) - set(allowlisted))
    return {"tagged": tagged, "findings": findings, "candidates": candidates, "allowlisted": allowlisted,
            "stale": stale}


def pii_state(dump: dict) -> dict:
    """The parts of pii_tags that depend on the allowlist (the tags themselves are in the structural view)."""
    p = pii_tags(dump)
    return {"candidates": p["candidates"], "allowlisted": [[k, PII_ALLOWLIST[k]] for k in p["allowlisted"]],
            "stale": p["stale"], "findings": p["findings"]}


def fingerprint(dump: dict) -> str:
    view = {"dump": structural_view(dump), "rls_guard": rls_guard_state(dump), "pii_tags": pii_state(dump)}
    blob = json.dumps(view, sort_keys=True, default=str).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def render_rls_guard(d: dict) -> list[str]:
    """The '## RLS catalogue guard (X2)' section: violations (expected none), then every allowlist entry used."""
    result = rls.check(d)
    L = ["## RLS catalogue guard (X2)", ""]
    L.append("Rules in AA-CIS-Infra `db/rls_catalogue_rules.py` (byte copy of AA-CIS-App "
             "`tests/integration/rls_catalogue_rules.py`, which CIS CI runs on the replayed migrations). "
             "A violation is a finding that is not on the allowlist; each allowlist entry carries a one-line reason. "
             "Fix the object or allowlist it in the CIS file, then copy it here.")
    L.append("")
    used: dict = defaultdict(int)
    for f, _ in result.allowlisted:
        used[f.rule] += 1
    viol: dict = defaultdict(int)
    for f in result.violations:
        viol[f.rule] += 1
    L.append(f"**{len(result.violations)} unallowlisted violation(s)**, {len(result.allowlisted)} allowlisted "
             f"finding(s), {len(result.stale)} stale allowlist entry(ies).")
    L.append("")
    L.append("| rule | meaning | violations | allowlisted |")
    L.append("|---|---|---|---|")
    for rule, meaning in rls.RULES.items():
        L.append(f"| {rule} | {cell(meaning)} | {viol[rule]} | {used[rule]} |")
    L.append("")
    L.append("### Violations")
    L.append("")
    for f in result.violations:
        L.append(f"- [{f.rule}] `{f.key}`: {cell(f.detail)}")
    if not result.violations:
        L.append("- none")
    L.append("")
    L.append("### Allowlist entries in use")
    L.append("")
    L.append("| rule | entry | findings | reason |")
    L.append("|---|---|---|---|")
    al = rls.ALLOWLIST
    counts: dict = defaultdict(int)
    for f, _ in result.allowlisted:
        counts[(f.rule, rls._match(al.get(f.rule, {}), f.key))] += 1
    for (rule, entry), n in sorted(counts.items()):
        L.append(f"| {rule} | `{cell(entry)}` | {n} | {cell(al[rule][entry])} |")
    if not counts:
        L.append("| none | | | |")
    L.append("")
    if result.stale:
        L.append("Stale entries (matched nothing on this database; remove them from the CIS file): "
                 + ", ".join(f"[{r}] `{k}`" for r, k in result.stale) + ".")
        L.append("")
    return L


def rls_guard_report(d: dict) -> str:
    """CI text for the workflow: one summary line, then a ::warning:: annotation per violation (never fatal)."""
    result = rls.check(d)
    lines = [f"- RLS catalogue guard (X2): {len(result.violations)} unallowlisted violation(s), "
             f"{len(result.allowlisted)} allowlisted, {len(result.stale)} stale allowlist entry(ies)"]
    for f in result.violations:
        lines.append(f"::warning::RLS catalogue guard [{f.rule}] {f.key}: {f.detail} ({rls.RULES[f.rule]})")
    return "\n".join(lines) + "\n"


def render_pii_tags(d: dict) -> list[str]:
    """The '## Personal and confidential data tags (DM-6.1)' section (AA-877)."""
    p = pii_tags(d)
    L = ["## Personal and confidential data tags (DM-6.1)", ""]
    L.append("Column comments that start with `pii:<class>` (personal data) or `conf:<class>` (`commercial`, "
             "`credential`), data standards DM-6.1; `also` = further tags named later in the same comment. Owners tag "
             "a column in the migration that creates it. Input of the RoPA (AA-Ecosys `docs/legal/register.md` section "
             "(a), `tools/data/gen_pii_inventory.py`) and the erasure runbook (DM-6.7).")
    L.append("")
    L.append(f"**{len(p['tagged'])} tagged column(s)**, {len(p['candidates'])} untagged candidate(s) in "
             f"{', '.join(PII_CANDIDATE_SCHEMAS)}, {len(p['findings'])} finding(s).")
    L.append("")
    counts: dict = defaultdict(lambda: defaultdict(int))
    also_counts: dict = defaultdict(lambda: defaultdict(int))
    for t in p["tagged"]:
        counts[t["schema"]][t["tag"]] += 1
        for a in t["also"]:
            also_counts[t["schema"]][a] += 1
    L.append("| schema | tag | columns | named as also |")
    L.append("|---|---|---|---|")
    for sch in sorted(set(counts) | set(also_counts)):
        for tag in sorted(set(counts[sch]) | set(also_counts[sch])):
            L.append(f"| `{sch}` | `{tag}` | {counts[sch][tag]} | {also_counts[sch][tag]} |")
    if not counts:
        L.append("| none | | | |")
    L.append("")
    L.append("### Tagged columns")
    L.append("")
    L.append("| schema | relation | column | tag | also |")
    L.append("|---|---|---|---|---|")
    for t in p["tagged"]:
        also = ", ".join(f"`{a}`" for a in t["also"])
        L.append(f"| `{t['schema']}` | `{t['relation']}` | `{t['column']}` | `{t['tag']}` | {also} |")
    if not p["tagged"]:
        L.append("| none | | | | |")
    L.append("")
    L.append("### Tag findings")
    L.append("")
    for f in p["findings"]:
        L.append(f"- `{f['key']}`: {cell(f['finding'])}")
    if not p["findings"]:
        L.append("- none")
    L.append("")
    L.append("### Untagged candidates")
    L.append("")
    L.append(f"Columns of {', '.join(f'`{s}`' for s in PII_CANDIDATE_SCHEMAS)} without a tag whose name contains one of "
             f"the tokens {', '.join(f'`{t}`' for t in sorted(PII_CANDIDATE_TOKENS))} (whole snake_case tokens) and "
             "that are not on the allowlist (AA-CIS-Infra `db/gen_schema_reference.py` `PII_ALLOWLIST`). Tag them in "
             "an owner migration or allowlist them with a reason.")
    L.append("")
    for k in p["candidates"]:
        L.append(f"- `{k}`")
    if not p["candidates"]:
        L.append("- none")
    L.append("")
    L.append("| allowlisted column | reason |")
    L.append("|---|---|")
    for k in p["allowlisted"]:
        L.append(f"| `{k}` | {cell(PII_ALLOWLIST[k])} |")
    if not p["allowlisted"]:
        L.append("| none | |")
    L.append("")
    if p["stale"]:
        L.append("Stale allowlist entries (matched no untagged column; remove them): "
                 + ", ".join(f"`{k}`" for k in p["stale"]) + ".")
        L.append("")
    return L


def column_line(c: dict) -> str:
    """`name type [NN] [· tag [(also …)]]` inside a relation's code block."""
    line = f"{c['name']} {c['type']}{' NN' if c['not_null'] else ''}"
    tag, also = parse_tag(c.get("comment"))
    if tag:
        line += f" · {tag}"
        if also:
            line += f" (also {', '.join(also)})"
    return line


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
    pii = pii_tags(d)
    fks = [(sch, name, c) for sch, rs in sorted(rels.items()) for name, r in sorted(rs.items())
           for c in r["constraints"] if c["type"] == "f"]

    w("# AA-Ecosys DB Schema Reference (live dump)")
    w("")
    w(f"<!-- schema-fingerprint: {fingerprint(d)} -->")
    w("")
    w(f"**Verified:** {stamp(d['generated_at'])} UTC — live catalog dump of the shared RDS (`aa-cis-dev-db`, "
      f"`aa-cis/dev/rds`, acc2, us-west-1, PostgreSQL {db.get('server_version', '?')}). "
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
    w("**ERD:** [one Mermaid diagram per schema](erd/README.md) (keys and foreign keys), generated from the same "
      "dump by AA-CIS-Infra `db/gen_erd.py` (AA-894).")
    w("")
    w(f"**Totals:** {len(d['schemas'])} schemas ({len(empty)} empty: {', '.join(empty) or 'none'}), "
      f"{n_rel} tables/views, {d['counts'].get('indexes', 0)} indexes, {len(fks)} FKs, "
      f"{d['counts'].get('policies', 0)} RLS policy(ies), {len(d.get('functions', []))} functions, "
      f"{len(d.get('enums', []))} enums. Database size {human_bytes(db.get('size_bytes'))}, "
      f"max_connections {db.get('max_connections', '?')}. RLS catalogue guard: "
      f"{len(rls.check(d).violations)} unallowlisted violation(s) (see *RLS catalogue guard (X2)*). DM-6.1 tags: "
      f"{len(pii.get('tagged', []))} tagged column(s), {len(pii.get('candidates', []))} untagged candidate(s).")
    w("")
    w("## Conventions")
    w("- Column format: `name type` — `NN` suffix = NOT NULL. Types are `format_type()` output "
      "(`character varying(64)`, `text[]`, `vector(1024)`, enums schema-qualified). A ` · pii:<class>` / "
      "` · conf:<class>` suffix is the column's data standards DM-6.1 tag (its comment starts with it), "
      "`(also …)` = further tags named in the same comment; see *Personal and confidential data tags (DM-6.1)*.")
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
                w(column_line(c))
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
    L.extend(render_pii_tags(d))
    L.extend(render_rls_guard(d))
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
    text = aws_mask.mask_text("\n".join(L))
    aws_mask.assert_clean(text, "db-schema-reference.md")
    return text


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("dump", help="JSON written by db/schema_dump.py")
    parser.add_argument("--out", help="Markdown file to write (default: stdout)")
    parser.add_argument("--source", help="provenance line, e.g. the workflow run URL")
    parser.add_argument("--fingerprint", action="store_true", help="print the structural fingerprint only")
    parser.add_argument("--rls-guard", action="store_true",
                        help="print the X2 RLS catalogue guard summary and ::warning:: annotations only")
    args = parser.parse_args(argv)
    with open(args.dump, encoding="utf-8") as f:
        dump = json.load(f)
    if dump.get("format") != 2:
        print(f"unsupported dump format {dump.get('format')!r} (expected 2)", file=sys.stderr)
        return 2
    if args.fingerprint:
        print(fingerprint(dump))
        return 0
    if args.rls_guard:
        sys.stdout.write(rls_guard_report(dump))
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
