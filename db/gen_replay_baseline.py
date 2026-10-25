"""Writes db/replay_baseline/*.sql: history no migration holds, which the schema drift replay needs (AA-853, S251).

Why it exists. The `acp_*` schemas and their first tables (acp_shared.acp_runs, acp_hitl_requests, acp_output_rules,
acp_silver_s2.visibility_reports, acp_silver_s3.content_calendars, acp_silver_s4.blog_drafts, …) and
gold_aa_internal.tenant_tour_versions were created on Dev by the AA-ACP-App repo, which was deleted in S241
(AA-867); AA-ACP-Core (archived) holds no SQL, and AA-CIS-App's history has no DDL for them. From May 2026 on, CIS
migrations extend these objects (019 "Schema: acp_silver_s4 (existing)", 025 ALTER acp_shared.acp_runs, 107 ALTER
tenant_tour_versions, …). Without them the replay of db/replay_migrations.py fails CIS 019 … 078, then the whole
acp_contract / catalog / X1 chain behind them, and the drift report counts every object of that chain as
"unmanaged". The baseline puts back exactly the objects no surviving file creates, in the shape they must have had
when the first CIS file that needs them ran (decision D1).

Recorded hand DDL. Four more files replay DDL that ran on Dev outside any migration, each at the point the evidence
gives, because a later file needs or checks its effect: sprint S7's row level security on shared.pipeline_runs (008's
header; 239 checks it), raw_sources.file_hash (123's header; 123 indexes it), and the two archived one-off scripts
of the AA-Ecosys root repo docs/archive/2026/ (G3 DROP of acp_shared.unknown_ledger, 16/09/2026; AA-603 DROP of the
N7/N8 tables, 21/09/2026; 244 checks the RLS tables that are left). CIS migration 281 codifies the same end state
for a database built from the files alone (D2).

What it is NOT. Never a migration: it is not under db/migrations/, DB Migrate cannot select it (its path regex),
run_migration.lint refuses any file carrying BASELINE_MARKER, and every file begins with a guard that raises unless
the session carries the replay's setting (`aa_replay.baseline = on`, application_name db-replay), which only
db/replay_migrations.py sets, and only for baseline files. Applied to Dev it would do nothing but raise.

How the shape is chosen (per object, in SPEC; the reason is written into the file):
  * live objects (acp_output_rules, tenant_tour_versions): the live dump's columns, NOT NULL, constraints and
    indexes, MINUS what a later CIS file that still exists adds (that file then adds it in the replay), with the
    pre-change definition where a later file replaces one and its text says what it was (108: status CHECK
    without ai_generated);
  * tables Dev later dropped (121): only what later files need (a referenced key column; nothing else is known).
    A table no later file needs a column of is created with no column, honestly empty;
  * column defaults are not in the dump (and not compared): only defaults a later file relies on are written
    (an INSERT that omits the key column), each named in SPEC;
  * placement (db/schema_drift_decisions.json `baseline`): each file runs right before the FIRST replayed file that
    needs any of its objects. That is the latest point the evidence fixes; an earlier one would claim that older
    CIS files (grant loops, RLS loops, 003's schema rebuild) acted on objects nobody can show existed then.

Usage (regenerate after a SPEC change or to refresh from a newer live dump; the output is deterministic):
  python3 db/gen_replay_baseline.py schema.json                # writes db/replay_baseline/
  python3 db/gen_replay_baseline.py schema.json --check        # exit 1 when a committed file differs
Standard library only.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DB_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(DB_DIR))
import run_migration as rm  # noqa: E402

OUT_DIR = DB_DIR / "replay_baseline"
BASELINE_MARKER = rm.BASELINE_MARKER                 # run_migration.lint refuses a file that carries it
GUARD_SETTING = "aa_replay.baseline"                 # set by db/replay_migrations.py for baseline files only
GUARD_APPLICATION = "db-replay"                      # replay_migrations.APPLICATION_NAME

GUARD = f"""DO $guard$
BEGIN
    IF current_setting('{GUARD_SETTING}', true) IS DISTINCT FROM 'on'
       OR current_setting('application_name') IS DISTINCT FROM '{GUARD_APPLICATION}' THEN
        RAISE EXCEPTION '{BASELINE_MARKER}: this file only feeds the schema drift replay '
                        '(db/replay_migrations.py); it is never applied to a real database';
    END IF;
END
$guard$;"""

LOST = ("Created on Dev by the deleted AA-ACP-App repo (S241, AA-867); no surviving repo holds its DDL.")

# One entry per baseline file. Objects run in list order. Keys:
#   schema: name                                   CREATE SCHEMA
#   table: schema.name, live: True                 shape from the live dump, minus the `later` items
#     later_columns {col: file}, later_indexes {name: file}, later_constraints {name: file}
#     constraints_before {name: (definition, file)}  pre-change definition a later file replaced
#     extra_constraints [(name, definition, evidence)]  dropped later by a file that names them
#   table: schema.name, columns [(name, type, evidence)]   a table Dev later dropped
#   defaults {col: (expr, evidence)}, rls (evidence), policies [(name, sql_tail, evidence)], why: text
#   sql: [statements], why: text                   recorded hand DDL, written as the archived script ran it
LEAD_LOST = ("Lost lineage: these objects were created on Dev by the AA-ACP-App repo, deleted in S241 (AA-867); "
             "no surviving repo holds their DDL.")
LEAD_HAND = ("Hand DDL on Dev that no migration holds; the script that ran it is kept in the AA-Ecosys root repo "
             "(docs/archive/2026/), and the replay needs its effect at the date it ran (a later file's guard checks "
             "that state). CIS migration 281 codifies the same end state for a database built from the files alone.")

SPEC = [
    {
        "file": "replay_baseline/001_s7_pipeline_runs_rls.sql",
        "before": "cis/008_rls_gold_silver.sql",
        "lead": ("Hand DDL on Dev that no migration holds: sprint S7 (April 2026) applied row level security on "
                 "shared.pipeline_runs by hand. The repo's 004 cannot have run as written (its policies compare the "
                 "uuid tenant_id with text), and 008 (21/04/2026) says 'S7 applied RLS only on "
                 "shared.pipeline_runs'. Unlike the other hand-DDL files, no CIS migration codifies this and none "
                 "can: 239 needs the state before 239 runs, so a later file (281) is too late. A database built from "
                 "the migration files alone still lacks it and stops at 239; this replay stand-in exists only so 239 "
                 "and 244 can run in the replay."),
        "title": "row level security on shared.pipeline_runs as sprint S7 applied it by hand (April 2026)",
        "objects": [
            {"sql": ["ALTER TABLE shared.pipeline_runs ENABLE ROW LEVEL SECURITY;",
                     "ALTER TABLE shared.pipeline_runs FORCE ROW LEVEL SECURITY;",
                     "CREATE POLICY tenant_isolation ON shared.pipeline_runs\n"
                     "    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);"],
             "why": "008's header ('S7 applied RLS only on shared.pipeline_runs'); 239's guard 1 expects "
                    "shared.pipeline_runs with RLS on and tenant_isolation PERMISSIVE ALL TO public in the "
                    "004/006/008 form `(tenant_id = (current_setting('app.tenant_id', true))::uuid)`, and the live "
                    "table is FORCEd. The 008 form of the policy is used (the one 239 names)."},
        ],
    },
    {
        "file": "replay_baseline/002_acp_lineage.sql",
        "before": "cis/020_acp_output_rules_seed.sql",
        "lead": LEAD_LOST,
        "title": "AA-ACP-App lineage of the acp_* schemas, as CIS 019-068 found it (May 2026)",
        "objects": [
            {"schema": "acp_shared",
             "why": LOST + " 021, 025, 028, 030 use it from May 2026; 095 and 096 call it existing "
                           "('schema already exists (acp_runs/unknown_ledger live there)')."},
            {"schema": "acp_silver_s2",
             "why": LOST + " Holds visibility_reports (below) before 027 creates competitor_inputs with CREATE SCHEMA "
                           "IF NOT EXISTS."},
            {"schema": "acp_silver_s3", "why": LOST + " 031 extends acp_silver_s3.content_calendars."},
            {"schema": "acp_silver_s4", "why": LOST + " 019 'Schema: acp_silver_s4 (existing)'."},
            {"schema": "acp_gold_output",
             "why": LOST + " Live, empty since 121 dropped its only table (published_content, DROP TABLE IF EXISTS: "
                           "no file needs its shape)."},
            {"table": "acp_shared.acp_runs",
             "why": LOST + " Dropped by 121. 019, 026, 028, 031, 055, 065, 094 reference acp_runs(run_id); 025, 055, "
                           "064 add their columns.",
             "columns": [("run_id", "uuid NOT NULL", "the key every FK names (019, 026, 028, 031, 055, 065, 094)")],
             "primary_key": ("acp_runs_pkey", "run_id"),
             "defaults": {"run_id": ("gen_random_uuid()", "assumed like every uuid key of the lineage")}},
            {"table": "acp_shared.acp_hitl_requests",
             "why": LOST + " Dropped by 121. 032 and 036 add columns; 121 names acp_output_rules.source_hitl_id -> "
                           "acp_hitl_requests(hitl_id).",
             "columns": [("hitl_id", "uuid NOT NULL", "121: acp_output_rules_source_hitl_id_fkey references it")],
             "primary_key": ("acp_hitl_requests_pkey", "hitl_id")},
            {"table": "acp_shared.acp_output_rules", "live": True,
             "why": LOST + " Still live. 020 seeds it, 037 adds confidence_score, 121 drops the source_hitl_id FK.",
             "later_columns": {"confidence_score": "037"},
             "extra_constraints": [("acp_output_rules_source_hitl_id_fkey",
                                    "FOREIGN KEY (source_hitl_id) REFERENCES acp_shared.acp_hitl_requests(hitl_id)",
                                    "121 drops it by this name (its header: the FK to acp_hitl_requests(hitl_id))")],
             "defaults": {"rule_id": ("gen_random_uuid()", "020 inserts rows without rule_id")},
             "rls": "229's header: a live-only policy output_rules_rls existed (RLS on); 239 checks relrowsecurity",
             "policies": [("output_rules_rls",
                           "USING (tenant_id = current_setting('app.current_tenant', true))",
                           "229's header: live-only, 'on the other GUC name app.current_tenant'; 229 drops it. "
                           "The exact expression is an assumption (229 replaces it)")]},
            {"table": "acp_silver_s2.visibility_reports",
             "why": LOST + " Dropped by 121. 029 adds fetched_at, expires_at, confidence_score, primary_keywords and "
                           "an index; no file needs another column.",
             "columns": []},
            {"table": "acp_silver_s3.content_calendars",
             "why": LOST + " Dropped by 121. 031 adds its v2 columns; no file needs another column.",
             "columns": []},
            {"table": "acp_silver_s4.blog_drafts",
             "why": LOST + " Dropped by 121. 032, 033, 038, 040, 041, 062, 063 add every column they use; no file "
                           "needs another one (its key and its FK to acp_hitl_requests, which 121 mentions, are not "
                           "named anywhere).",
             "columns": []},
        ],
    },
    {
        "file": "replay_baseline/003_tenant_tour_versions.sql",
        "before": "107",
        "lead": LEAD_LOST,
        "title": "gold_aa_internal.tenant_tour_versions as CIS 107 found it (August 2026)",
        "objects": [
            {"table": "gold_aa_internal.tenant_tour_versions", "live": True,
             "why": LOST + " Still live (P3-S9 tenant rewrite versions). 107 adds the qa columns, 108 and 175 "
                           "replace the status CHECK, 109 adds qa_auto_passed, 175 job_id; 229 and 244 its policies.",
             "later_columns": {"qa_status": "107", "qa_repair_count": "107", "qa_checked_at": "107",
                               "qa_auto_passed": "109", "job_id": "175"},
             "later_indexes": {"tenant_tour_versions_job_idx": "175"},
             "later_constraints": {"tenant_tour_versions_qa_status_check": "107",
                                   "tenant_tour_versions_job_id_fkey": "175"},
             "constraints_before": {"tenant_tour_versions_status_check": (
                 "CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text, "
                 "'needs_review'::text])))",
                 "108 adds ai_generated ('pre-existing P3-S9 gap'); 175 adds failed")},
             "rls": "229's header: 'already has RLS ENABLED with a live-only policy tenant_tour_versions_isolation'",
             "policies": [("tenant_tour_versions_isolation",
                           "USING ((tenant_id)::text = current_setting('app.tenant_id', true))",
                           "229's header: live-only, TO public, text compare; 229 drops it. The exact expression "
                           "is an assumption (229 replaces it)")]},
        ],
    },
    {
        "file": "replay_baseline/004_raw_sources_file_hash.sql",
        "before": "123",
        "lead": ("Hand DDL on Dev that no migration holds: silver_aa_internal.raw_sources.file_hash was added by hand; "
                 "123 (2026-08-28) registers only its unique index, 'already live via manual DDL', and fails without "
                 "the column. CIS migration 281 codifies the column for a database built from the files alone."),
        "title": "silver_aa_internal.raw_sources.file_hash, added by hand before CIS 123 (August 2026)",
        "objects": [
            {"sql": ["ALTER TABLE silver_aa_internal.raw_sources ADD COLUMN file_hash character varying(64);"],
             "why": "123's header ('already live via manual DDL'); the live type is character varying(64), nullable "
                    "(the live dump). Placed before 123, the first file that needs it."},
        ],
    },
    {
        "file": "replay_baseline/005_g3_drop_unknown_ledger.sql",
        "before": "153",
        "lead": LEAD_HAND,
        "title": "AA-598 G3 data reset, its one DDL: DROP TABLE acp_shared.unknown_ledger (16/09/2026, S183)",
        "objects": [
            {"sql": ["DROP TABLE acp_shared.unknown_ledger;"],
             "why": "docs/archive/2026/audit-cis-g3-execute.sql ('executed 16/09/2026 (S183)'), the one DDL "
                    "statement of that script (its DELETEs and UPDATE change rows only). No registry row on "
                    "16-17/09: placed before 153, the first one after."},
        ],
    },
    {
        "file": "replay_baseline/006_aa603_drop_n7n8_tables.sql",
        "before": "160",
        "lead": LEAD_HAND,
        "title": "AA-603 DROP of the dead N7/N8 tables (21/09/2026, S191)",
        "objects": [
            {"sql": ["DROP TABLE IF EXISTS acp_shared.content_metric_snapshot CASCADE;",
                     "DROP TABLE IF EXISTS acp_deliver.pieces CASCADE;",
                     "DROP TABLE IF EXISTS acp_deliver.packets CASCADE;",
                     "DROP TABLE IF EXISTS acp_shared.acp_v2_slots CASCADE;",
                     "DROP TABLE IF EXISTS acp_shared.acp_v2_runs CASCADE;"],
             "why": "docs/archive/2026/aa603-drop-n7n8-tables.sql ('executed 21/09/2026 (S191)'), its DROP "
                    "statements as written. Placed before 160, the first registry row of 21/09 (a lower bound; "
                    "244, 2026-10, checks the ENABLE-only RLS tables and these are not among them)."},
        ],
    },
]


def _q(name: str) -> str:
    return ".".join(f'"{p}"' if not p.replace("_", "a").isalnum() or p != p.lower() else p for p in name.split("."))


def _live_relation(live: dict, qual: str) -> dict:
    schema, name = qual.split(".", 1)
    rel = ((live.get("relations") or {}).get(schema) or {}).get(name)
    if not rel:
        raise SystemExit(f"{qual}: not in the live dump (a `live` object must exist on Dev)")
    return rel


def _comment(text: str, indent: str = "-- ") -> list:
    out, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > 112:
            out.append(indent + line)
            line = word
        else:
            line = f"{line} {word}" if line else word
    if line:
        out.append(indent + line)
    return out


def table_sql(obj: dict, live: dict) -> list:
    """Statements for one `table` object (pure apart from the live dump)."""
    qual = obj["table"]
    out = _comment(obj["why"])
    if obj.get("live"):
        rel = _live_relation(live, qual)
        later_cols = obj.get("later_columns", {})
        missing = [c for c in later_cols if c not in {x["name"] for x in rel["columns"]}]
        if missing:
            raise SystemExit(f"{qual}: later_columns {missing} are not live columns")
        cols = [(c["name"], c["type"] + (" NOT NULL" if c["not_null"] else ""), "live")
                for c in rel["columns"] if c["name"] not in later_cols]
        for c, f in sorted(later_cols.items()):
            out.append(f"-- column {c}: left out, {f} adds it")
        cons = []
        later_cons = obj.get("later_constraints", {})
        before = obj.get("constraints_before", {})
        for c in sorted(rel["constraints"], key=lambda x: x["constraint"]):
            if c["constraint"] in later_cons:
                out.append(f"-- constraint {c['constraint']}: left out, {later_cons[c['constraint']]} adds it")
                continue
            if c["constraint"] in before:
                definition, why = before[c["constraint"]]
                out.append(f"-- constraint {c['constraint']}: the definition before {why}")
                cons.append((c["constraint"], definition))
                continue
            cons.append((c["constraint"], c["definition"]))
        later_idx = obj.get("later_indexes", {})
        idx, pk = [], None
        for i in sorted(rel["indexes"], key=lambda x: x["index"]):
            if i["index"] in later_idx:
                out.append(f"-- index {i['index']}: left out, {later_idx[i['index']]} adds it")
                continue
            idx.append(i["definition"])
            if i.get("is_primary"):
                pk = i["index"]     # the dump keeps CHECK / FK constraints; the key is its primary index
    else:
        cols = list(obj["columns"])
        cons, idx, pk = [], [], None
        if obj.get("primary_key"):
            pk, col = obj["primary_key"]
            idx.append(f"CREATE UNIQUE INDEX {pk} ON {qual} USING btree ({col})")
        if not cols:
            out.append("-- no column: no later file needs one (each adds its own)")
    for name, _type, ev in cols:
        if ev != "live":
            out.append(f"-- column {name}: {ev}")
    defaults = obj.get("defaults", {})
    for c, (expr, ev) in sorted(defaults.items()):
        out.append(f"-- default of {c} ({expr}): {ev}")
    body = ",\n".join(f"    {_q(n)} {t}" + (f" DEFAULT {defaults[n][0]}" if n in defaults else "")
                      for n, t, _ in cols)
    out.append(f"CREATE TABLE {qual} (\n{body}\n);" if body else f"CREATE TABLE {qual} ();")
    extra = [(n, d) for n, d, _ in obj.get("extra_constraints", [])]
    for n, _d, ev in obj.get("extra_constraints", []):
        out.append(f"-- constraint {n}: {ev}")
    # indexes, then the key on its index, then CHECKs, FOREIGN KEYs last (a self reference finds its key)
    out += [f"{d};" for d in idx]
    if pk:
        out.append(f"ALTER TABLE {qual} ADD CONSTRAINT {_q(pk)} PRIMARY KEY USING INDEX {_q(pk)};")
    ordered = sorted(cons + extra, key=lambda x: (x[1].startswith("FOREIGN KEY"), x[0]))
    for n, d in ordered:
        out.append(f"ALTER TABLE {qual} ADD CONSTRAINT {_q(n)} {d};")
    if obj.get("rls"):
        out.append(f"-- row level security: {obj['rls']}")
        out.append(f"ALTER TABLE {qual} ENABLE ROW LEVEL SECURITY;")
    for n, tail, ev in obj.get("policies", []):
        out += _comment(f"policy {n}: {ev}")
        out.append(f"CREATE POLICY {_q(n)} ON {qual} {tail};")
    return out


def render(entry: dict, live: dict) -> str:
    lines = [f"-- {BASELINE_MARKER}: {entry['title']}",
             "--",
             *_comment(f"REPLAY BASELINE, NOT A MIGRATION. {entry['lead']} Only the "
                       "schema drift replay (db/replay_migrations.py, DB Schema Dump) reads this file, right before "
                       f"{entry['before']} (db/schema_drift_decisions.json `baseline`). It is never applied to a "
                       "real database: DB Migrate cannot select it, and the guard below (the first statement of the "
                       "transaction, so psql -f without ON_ERROR_STOP rolls the whole file back) raises outside the "
                       "replay."),
             "--",
             *_comment(f"Generated by db/gen_replay_baseline.py from the live dump of {live.get('generated_at')} "
                       "(AA-853). Do not edit by hand: change SPEC there and regenerate."),
             "",
             "BEGIN;",
             "",
             GUARD,
             ""]
    for obj in entry["objects"]:
        if "schema" in obj:
            lines += _comment(obj["why"])
            lines.append(f"CREATE SCHEMA {_q(obj['schema'])};")
        elif "sql" in obj:
            lines += _comment(obj["why"])
            lines += obj["sql"]
        else:
            lines += table_sql(obj, live)
        lines.append("")
    lines.append("COMMIT;")
    return "\n".join(lines) + "\n"


def decisions_entries() -> list:
    """The `baseline` list db/schema_drift_decisions.json must carry for SPEC (checked by the unit tests)."""
    return [{"file": e["file"], "before": e["before"]} for e in SPEC]


def main(argv: list | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("live", help="live dump JSON (db/schema_dump.py, the DB Schema Dump artifact)")
    p.add_argument("--check", action="store_true", help="compare with the committed files instead of writing")
    args = p.parse_args(argv)
    live = json.loads(Path(args.live).read_text(encoding="utf-8"))
    bad = 0
    for entry in SPEC:
        text = render(entry, live)
        path = DB_DIR / entry["file"]
        if args.check:
            if not path.is_file() or path.read_text(encoding="utf-8") != text:
                print(f"{entry['file']}: differs from a fresh render", file=sys.stderr)
                bad = 1
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        print(f"wrote {entry['file']}")
    return bad


if __name__ == "__main__":
    sys.exit(main())
