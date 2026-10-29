"""Runner side of the expand auto-apply (AA-993 M3, root ADR 0017 decision 5, `.github/workflows/migration-apply.yml`).

The database part runs in the migrator task (`db/run_migration.py`, MIGRATION_MODE=apply-pending): only the task can
read `shared.schema_versions`, and only it applies. This tool prepares what the task gets and explains what it did. It
needs no AWS and no database, so every mode runs locally:

  python3 db/apply_pending.py plan --source cis=owners/AA-CIS-App/api/migrations … [--live schema.json | --registered keys.txt]
      [--classify classify.json] [--bundle bundle.json] [--plan-out plan.json] [--summary FILE] [--github-output FILE]
  python3 db/apply_pending.py report --log task.log [--summary FILE] [--github-output FILE]
  python3 db/apply_pending.py notes --manual "contract:cis/301_x.sql,…" --run-id N
  python3 db/apply_pending.py pick-pr --pulls pulls.json --path cis/301_x.sql (--merged | --open)
  python3 db/apply_pending.py explain 14

plan (also the dry run): for every copy in db/migrations/<cis|booking|tripplanner|crm>/ above the owner's legacy floor
(run_migration.AUTO_APPLY_FLOOR) the runner's verdict:
  * the bytes are re-checked against the owner repo's main (`--source OWNER=DIR`, a fresh clone of that main; never the
    copy PR's label or its merge, ADR 0017 d5) — missing on main or different = refused;
  * the file is re-classified: `--classify` is the JSON of `db/expand_check.py --classify` run in this workflow on a
    replay of Dev; only class `expand` passes. Without it the verdict is "no classify evidence", which the task treats
    as a stop, so nothing is applied on a header alone.
Plus the gap list (bundle field `not_copied`): every `NNN_name.sql` on an owner's main above the floor (and at or above
the owner's lowest copy here, as migration_sync.plan) whose number has no copy here yet, i.e. its copy PR has not
merged. plan_pending stops the owner at that number, so a later copy is never applied past it (critic 2); the task also
refuses any number that is not the owner's head + 1 on its own, so the gap list only names the reason.
The expected plan comes from run_migration.plan_pending (the same code the task runs) on the registered keys of the
latest DB Schema Dump artifact (`--live`) or a key list (`--registered`, one key per line). It is only a forecast: the
task re-reads the keys under the apply lock. Outputs (`--github-output`): `needs_classify` (an expected `apply` step
exists when classify evidence is assumed), `apply` (an expected `apply` step exists with the real verdicts), `pending`
(count of expected steps), `manual` (the expected stop of each owner as `kind:owner/file`, comma separated; every
stop kind needs a person, run_migration.STOP_KINDS; with `--classify-skipped` a `no-evidence` stop is left out, because
a scheduled list-only run skips the classify on purpose). `--bundle` writes the task's input: kind, format, files
(path, sha256, sql, verdict, verdict_kind), not_copied (paths).

report: reads the task log's `MIGRATE auto-result {json}` line, writes the run summary, and outputs `applied` (true
when a file was applied; `unknown` when the line is missing, so the workflow still runs the probe and the dump),
`manual` (every owner's stop as `kind:owner/file`; the migration-apply summary job comments on the copy PRs) and
`result` (found | missing). Exit 3 when the line is missing: the step must go red, never green on an unknown result.

notes: one JSON line per `kind:owner/file` item: the copy PR to comment on (`on_main`: the merged PR that added the
file, else the open copy PR of a file not copied yet), a marker unique to the kind and file, and the comment body.
pick-pr: the PR number to comment on from a GitHub pulls list (`--merged`: merged_at set, the bot branch preferred,
the latest merge; `--open`: the open PR on the bot branch); prints nothing when there is none.

explain: the one-line ::error:: text for a task exit code (the same codes as DB Migrate).
Standard library only (plus run_migration, which is standard library outside the task).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import run_migration as rm  # noqa: E402

DB_DIR = Path(__file__).resolve().parent
NO_EVIDENCE = "no classify evidence (no DB Schema Dump artifact, or classify did not run or did not reach the file)"
MANUAL_MARK = "aa993-manual-apply"

# What a person does for each stop kind (run_migration.STOP_KINDS): the summary line and the copy PR comment.
STOP_NOTES = {
    rm.STOP_CONTRACT: ("manual DB Migrate apply needed",
                       "it is a contract file (no `-- migrate: expand` header), so migration-apply never applies it. "
                       "Run DB Migrate `check` then `apply` with `migration={path}`."),
    rm.STOP_OUT_OF_ORDER: ("manual DB Migrate apply needed",
                           "its number is below the owner's highest registered key (out of order), so migration-apply "
                           "never applies it. Run DB Migrate `check` then `apply` with `migration={path}`."),
    rm.STOP_LINT: ("fix in the owner repo",
                   "it has the expand header but fails the runner's lint. Fix the file in the owner repo (the sync "
                   "updates the copy), or apply it by hand with DB Migrate as a contract file."),
    rm.STOP_REFUSED_CLASSIFY: ("manual DB Migrate apply needed",
                               "expand_check --classify on a replay of Dev found that it changes an existing object, so "
                               "it is treated as a contract file. Change it in the owner repo, or run DB Migrate "
                               "`check` then `apply` with `migration={path}`."),
    rm.STOP_REFUSED_BYTES: ("copy differs from the owner's main",
                            "the copy here is not byte-identical to the owner repo's main (or that main could not be "
                            "read). Fix the copy so it matches the owner's main; nothing of this owner is applied "
                            "until then."),
    rm.STOP_NO_EVIDENCE: ("no classify evidence",
                          "the run had no classify result for it (no DB Schema Dump artifact, or the classify step "
                          "failed). Check the run's classify step; dispatch DB Schema Dump if its artifact expired."),
    rm.STOP_NOT_COPIED: ("copy PR not merged yet",
                         "it is on the owner repo's main but this copy PR has not merged, and every later file of the "
                         "owner waits for it (never past a gap). Get this PR green and merged."),
    rm.STOP_GAP: ("gap before this file",
                  "the owner's next number before it is neither registered nor copied here, so nothing past the gap is "
                  "applied. Copy (or apply by hand) the missing number first."),
    rm.STOP_DUPLICATE: ("duplicate number",
                        "another copy has the same number. Fix the copies so each number is used once."),
    rm.STOP_REFUSED: ("refused on the runner",
                      "the runner refused it (see the run summary). Fix the cause, or apply it by hand with DB "
                      "Migrate."),
}

EXPLAIN = {
    2: "the bundle's sha256 does not match what the workflow uploaded: nothing ran",
    3: "a file ran but did not register its version in shared.schema_versions",
    4: "a file failed the runner's lint in the task (the plan step passed it: compare the runner versions)",
    6: "PostgreSQL error (see the MIGRATE ERROR line; a lock timeout was retried twice first)",
    7: "a hot-table expand file met an open rerun wave (deferred; the next run retries)",
    8: "role refused (see the MIGRATE ERROR: role line): the login must reach the live owner of the dir",
    9: "ownership post-check failed: rolled back (or, after COMMIT, committed: clean up by hand)",
    10: "the task refused the mode or the bundle (see the MIGRATE ERROR line): nothing ran",
    14: "expand post-check: a file changed an existing object (named in the MIGRATE ERROR line); rolled back, not "
        "registered. Change the file in the owner repo, or ship it as a contract file (manual DB Migrate apply)",
    15: "expand lock risk: a file would lock an existing table above 100k rows; nothing of it ran. Make it a contract "
        "file or use CREATE INDEX CONCURRENTLY in a no-transaction file",
    16: "expand CREATE INDEX CONCURRENTLY left a missing or INVALID index (named in the log): not registered. Drop the "
        "index (manual DB Migrate run-script or a contract file), then re-run",
    17: "the apply lock stayed held by another DB Migrate or auto-apply run for 25 min: nothing ran. Re-run later",
}


def parse_sources(values: list) -> dict:
    out = {}
    for v in values:
        owner, sep, path = v.partition("=")
        if not sep or owner not in rm.AUTO_OWNERS:
            raise SystemExit(f"--source must be OWNER=DIR with OWNER in {', '.join(rm.AUTO_OWNERS)}: {v!r}")
        out[owner] = Path(path)
    return out


def registered_from_live(live: dict) -> set:
    return {m["version"] for m in live.get("migrations") or [] if m.get("version")}


def classify_verdicts(classify: dict | None) -> dict:
    """{"owner/file": (verdict_kind, verdict)} from expand_check --classify JSON: ("ok", "ok") for class expand,
    else the refused-classify kind and why not."""
    out = {}
    for e in (classify or {}).get("files") or []:
        if e.get("class") == "expand":
            out[e["file"]] = ("ok", "ok")
        else:
            why = (e.get("findings") or []) + (e.get("lint_errors") or [])
            detail = "; ".join(why[:2]) or e.get("error") or (
                "no `-- migrate: expand` header" if e.get("header") != "expand" else "not expand")
            out[e["file"]] = (rm.STOP_REFUSED_CLASSIFY, f"classified contract on the replay: {detail}"[:400])
    return out


def copies(repo_root: Path) -> list:
    """Every owner-dir copy above its legacy floor: [{"owner", "name", "path", "number", "bytes"}], number order."""
    out = []
    for owner in rm.AUTO_OWNERS:
        d = repo_root / "db" / "migrations" / owner
        for p in sorted(d.glob("*.sql")) if d.is_dir() else []:
            m = rm.AUTO_FILE_RE.match(f"{owner}/{p.name}")
            if not m or int(m.group(2)) <= rm.AUTO_APPLY_FLOOR.get(owner, 0):
                continue
            out.append({"owner": owner, "name": p.name, "path": f"{owner}/{p.name}", "number": int(m.group(2)),
                        "bytes": p.read_bytes()})
    return out


def not_copied(repo_root: Path, sources: dict) -> list:
    """Owner-main files whose number has no copy here: ["owner/NNN_name.sql"], above AUTO_APPLY_FLOOR and at or above
    the owner's lowest copy (below it is the history from before the copy flow, as migration_sync.plan)."""
    out = []
    for owner in rm.AUTO_OWNERS:
        src = sources.get(owner)
        if src is None or not src.is_dir():
            continue
        d = repo_root / "db" / "migrations" / owner
        here = {int(m.group(2)) for p in (d.glob("*.sql") if d.is_dir() else [])
                if (m := rm.AUTO_FILE_RE.match(f"{owner}/{p.name}"))}
        lowest = min(here) if here else 0
        for p in sorted(src.glob("*.sql")):
            m = rm.AUTO_FILE_RE.match(f"{owner}/{p.name}")
            if not m:
                continue
            number = int(m.group(2))
            if number > rm.AUTO_APPLY_FLOOR.get(owner, 0) and number >= lowest and number not in here:
                out.append(f"{owner}/{p.name}")
    return out


def byte_verdict(c: dict, sources: dict) -> str:
    """"ok", or why the copy is refused (verdict kind run_migration.STOP_REFUSED_BYTES)."""
    src = sources.get(c["owner"])
    if src is None:
        return f"no clone of the {c['owner']} owner repo's main to compare with"
    upstream = src / c["name"]
    if not upstream.is_file():
        return "not on the owner repo's main (a copy must be byte-identical to the owner's main)"
    got = upstream.read_bytes()
    if got != c["bytes"]:
        return (f"differs from the owner repo's main (copy sha256 {hashlib.sha256(c['bytes']).hexdigest()[:12]}, "
                f"owner {hashlib.sha256(got).hexdigest()[:12]})")
    return "ok"


def build(repo_root: Path, sources: dict, classify: dict | None, assume_classified: bool = False) -> list:
    """The bundle files with the runner's verdicts. assume_classified: a missing classify verdict counts as ok (only to
    decide whether classify is worth running)."""
    verdicts = classify_verdicts(classify)
    files = []
    for c in copies(repo_root):
        try:
            sql = c["bytes"].decode("utf-8")
        except UnicodeDecodeError:
            continue                # the Copy Guard refuses it; never pending-applicable
        v = byte_verdict(c, sources)
        vk = "ok" if v == "ok" else rm.STOP_REFUSED_BYTES
        if v == "ok":
            vk, v = verdicts.get(c["path"], ("ok", "ok") if assume_classified else (rm.STOP_NO_EVIDENCE, NO_EVIDENCE))
        files.append({"path": c["path"], "sha256": hashlib.sha256(c["bytes"]).hexdigest(), "sql": sql, "verdict": v,
                      "verdict_kind": vk})
    return files


def plan_json(plan: dict) -> dict:
    return {o: {"head": p["head"], "legacy": p["legacy"],
                "steps": [{"file": s.path, "version": s.version, "action": s.action, "reason": s.reason,
                           "kind": s.kind} for s in p["steps"]]} for o, p in plan.items()}


def plan_lines(plan: dict, title: str) -> list:
    lines = [title, "", "| Owner | Head | Expected step | File | Note |", "|---|---|---|---|---|"]
    for owner, p in plan.items():
        if not p["steps"]:
            lines.append(f"| {owner} | {p['head'] or '-'} | nothing pending | | |")
        for s in p["steps"]:
            note = s.reason.replace("|", "/")[:250]
            lines.append(f"| {owner} | {p['head'] or '-'} | {s.action} | `{s.path}` | {note} |")
    return lines


def stop_kind(kind: str | None) -> str:
    """The stop kind of a step or task row; anything unknown (or missing) is a plain runner refusal. Every stop kind
    needs a person: it is on the manual list and gets a note on the copy PR."""
    return kind if kind in rm.STOP_KINDS else rm.STOP_REFUSED


def manual_item(kind: str | None, path: str) -> str:
    return f"{stop_kind(kind)}:{path}"


def parse_manual(value: str) -> list:
    """[(kind, path)] from the `manual` output ("kind:owner/file,…"); an item without a known kind is refused."""
    out = []
    for item in (value or "").split(","):
        item = item.strip()
        if not item:
            continue
        kind, sep, path = item.partition(":")
        if not sep or kind not in rm.STOP_KINDS or not rm.AUTO_FILE_RE.match(path):
            raise SystemExit(f"manual item {item!r} is not kind:owner/NNN_name.sql")
        out.append((kind, path))
    return out


def copy_branch(path: str) -> str:
    m = rm.AUTO_FILE_RE.match(path)
    return f"bot/migration-copy/{m.group(1)}-{m.group(2)}"


def note(kind: str, path: str, run_id: str) -> dict:
    """The copy PR note of one stop: where to find the PR, a marker unique to kind + file, the comment body."""
    head, what = STOP_NOTES[stop_kind(kind)]
    marker = f"<!-- {MANUAL_MARK}:{kind}:{path} -->"
    body = (f"{marker}\n**{head[0].upper() + head[1:]}** for `{path}`: {what.format(path=path)} Every later file of "
            f"this owner waits behind it (strict number order, root ADR 0017 d5). (migration-apply run {run_id})")
    return {"path": path, "kind": kind, "branch": copy_branch(path), "on_main": kind != rm.STOP_NOT_COPIED,
            "marker": marker, "head": head, "body": body}


def pick_copy_pr(pulls: list, path: str, merged: bool) -> int | None:
    """The PR to comment on for a stop at `path`. merged: the MERGED PR that added the file (merged_at set; the bot
    copy branch preferred; the latest merge), never just the newest PR on the branch. not merged: the open PR on
    the bot copy branch (a file not copied yet)."""
    branch = copy_branch(path)
    on_branch = [p for p in pulls or [] if ((p.get("head") or {}).get("ref")) == branch]
    if merged:
        done = [p for p in pulls or [] if p.get("merged_at")]
        pool = [p for p in done if p in on_branch] or done
        return max(pool, key=lambda p: p["merged_at"])["number"] if pool else None
    live = [p for p in on_branch if p.get("state") == "open"]
    return max(p["number"] for p in live) if live else None


def _write_outputs(path: str | None, values: dict) -> None:
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            for k, v in values.items():
                fh.write(f"{k}={v}\n")


def cmd_plan(args) -> int:
    root = Path(args.repo_root)
    sources = parse_sources(args.source)
    classify = json.loads(Path(args.classify).read_text(encoding="utf-8")) if args.classify else None
    if args.registered:
        registered = {ln.strip() for ln in Path(args.registered).read_text(encoding="utf-8").splitlines() if ln.strip()}
        basis = f"key list {args.registered}"
    elif args.live:
        live = json.loads(Path(args.live).read_text(encoding="utf-8"))
        registered, basis = registered_from_live(live), f"DB Schema Dump of {live.get('generated_at', '?')}"
    else:
        registered, basis = None, ""
    files = build(root, sources, classify)
    missing = not_copied(root, sources)
    for path in missing:
        print(f"PLAN gap: {path} is on the owner's main but has no copy here yet (its copy PR has not merged)")
    if args.bundle:
        Path(args.bundle).write_text(json.dumps({"kind": rm.BUNDLE_KIND, "format": 1, "files": files,
                                                 "not_copied": missing}, sort_keys=True), encoding="utf-8")
    if registered is None:
        print("PLAN no registered keys (no --live dump artifact, no --registered list): no forecast; the task decides "
              "from the database, and without classify evidence it applies nothing")
        _write_outputs(args.github_output, {"needs_classify": "false", "apply": "false", "pending": 0, "manual": ""})
        if args.summary:
            with open(args.summary, "a", encoding="utf-8") as fh:
                fh.write("### Expected plan\n\nNo DB Schema Dump artifact: no forecast, nothing to classify.\n")
        return 0
    gaps = [rm.not_copied_entry(path) for path in missing]
    plan = rm.plan_pending(files + gaps, registered)
    provisional = rm.plan_pending(build(root, sources, classify, assume_classified=True) + gaps, registered)
    has_apply = any(s.action == "apply" for p in plan.values() for s in p["steps"])
    needs_classify = any(s.action == "apply" for p in provisional.values() for s in p["steps"])
    pending = sum(len(p["steps"]) for p in plan.values())
    for owner, p in plan.items():
        for s in p["steps"]:
            print(f"PLAN {owner} {s.action:5} {s.path} ({s.version}){': ' + s.reason if s.reason else ''}")
        if not p["steps"]:
            print(f"PLAN {owner} nothing pending (head {p['head']})")
    if args.plan_out:
        Path(args.plan_out).write_text(json.dumps({"basis": basis, "owners": plan_json(plan)}, indent=1,
                                                  sort_keys=True), encoding="utf-8")
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write("\n".join(plan_lines(plan, f"### Expected plan ({basis}; the task re-reads the keys)")) + "\n")
    manual = [manual_item(s.kind, s.path) for p in plan.values() for s in p["steps"] if s.action == "stop"
              and not (args.classify_skipped and s.kind == rm.STOP_NO_EVIDENCE)]
    _write_outputs(args.github_output, {"needs_classify": str(needs_classify).lower(),
                                        "apply": str(has_apply).lower(), "pending": pending,
                                        "manual": ",".join(manual)})
    return 0


def parse_result(log_text: str) -> dict | None:
    """The last `MIGRATE auto-result {json}` line of the task log, or None."""
    found = None
    for line in log_text.splitlines():
        if line.startswith("MIGRATE auto-result "):
            try:
                found = json.loads(line[len("MIGRATE auto-result "):])
            except json.JSONDecodeError:
                continue
    return found


def report_lines(result: dict | None) -> list:
    if result is None:
        return ["### Auto-apply result", "", "**Result unknown:** no `auto-result` line in the task log (the task did "
                "not finish, or its log is incomplete). The run is red; the isolation probe and DB Schema Dump run "
                "anyway. A person checks the task log and `shared.schema_versions`."]
    lines = ["### Auto-apply result", "", f"Task exit {result.get('exit')} (bundle {result.get('bundle')}).", "",
             "| Owner | Head before | File | Status | Note |", "|---|---|---|---|---|"]
    for owner, o in sorted((result.get("owners") or {}).items()):
        rows = o.get("files") or []
        if not rows:
            lines.append(f"| {owner} | {o.get('head_before') or '-'} | | nothing pending | |")
        for r in rows:
            note = r.get("reason") or (EXPLAIN.get(r.get("exit"), f"exit {r.get('exit')}") if r.get("exit") else "")
            if r.get("status") == "manual":
                note = f"{STOP_NOTES[stop_kind(r.get('kind'))][0]}: {note}"
            lines.append(f"| {owner} | {o.get('head_before') or '-'} | `{r['file']}` | {r['status']} | "
                         f"{note.replace('|', '/')[:250]} |")
    return lines


def cmd_report(args) -> int:
    text = Path(args.log).read_text(encoding="utf-8", errors="replace") if Path(args.log).is_file() else ""
    result = parse_result(text)
    rows = [r for o in ((result or {}).get("owners") or {}).values() for r in o.get("files") or []]
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write("\n".join(report_lines(result)) + "\n")
    applied = "unknown" if result is None else str(any(r.get("status") == "applied" for r in rows)).lower()
    _write_outputs(args.github_output, {
        "applied": applied,
        "manual": ",".join(manual_item(r.get("kind"), r["file"]) for r in rows if r.get("status") == "manual"),
        "result": "found" if result is not None else "missing"})
    return 0 if result is not None else 3


def cmd_notes(args) -> int:
    for kind, path in parse_manual(args.manual):
        print(json.dumps(note(kind, path, args.run_id), sort_keys=True))
    return 0


def cmd_pick_pr(args) -> int:
    pulls = json.loads(Path(args.pulls).read_text(encoding="utf-8")) if Path(args.pulls).is_file() else []
    n = pick_copy_pr(pulls if isinstance(pulls, list) else [], args.path, merged=args.merged)
    if n is not None:
        print(n)
    return 0


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan", help="verdicts, expected plan, bundle (dry run when no --bundle)")
    p.add_argument("--repo-root", default=str(DB_DIR.parent))
    p.add_argument("--source", action="append", default=[], help="OWNER=DIR: the owner repo main's migrations folder")
    p.add_argument("--live", help="schema.json of the latest DB Schema Dump (its registered keys)")
    p.add_argument("--registered", help="file with one registered key per line (instead of --live)")
    p.add_argument("--classify", help="db/expand_check.py --classify JSON")
    p.add_argument("--bundle", help="write the task's bundle JSON here")
    p.add_argument("--plan-out", help="write the expected plan JSON here")
    p.add_argument("--summary", help="append Markdown (GITHUB_STEP_SUMMARY)")
    p.add_argument("--github-output", help="append key=value outputs (GITHUB_OUTPUT)")
    p.add_argument("--classify-skipped", action="store_true",
                   help="the classify was skipped on purpose (scheduled list-only run): no-evidence stops are not manual")
    r = sub.add_parser("report", help="run summary from the task log")
    r.add_argument("--log", required=True)
    r.add_argument("--summary")
    r.add_argument("--github-output")
    n = sub.add_parser("notes", help="one JSON line per manual item: copy PR lookup, marker, comment body")
    n.add_argument("--manual", required=True, help="the `manual` output: kind:owner/file,…")
    n.add_argument("--run-id", required=True)
    k = sub.add_parser("pick-pr", help="the PR number to comment on, from a GitHub pulls list")
    k.add_argument("--pulls", required=True)
    k.add_argument("--path", required=True, help="owner/NNN_name.sql")
    g = k.add_mutually_exclusive_group(required=True)
    g.add_argument("--merged", action="store_true", help="the merged PR that added the file")
    g.add_argument("--open", dest="merged", action="store_false", help="the open copy PR (a file not copied yet)")
    e = sub.add_parser("explain", help="the error text of a task exit code")
    e.add_argument("code", type=int)
    args = parser.parse_args(argv)
    if args.cmd == "plan":
        return cmd_plan(args)
    if args.cmd == "report":
        return cmd_report(args)
    if args.cmd == "notes":
        return cmd_notes(args)
    if args.cmd == "pick-pr":
        return cmd_pick_pr(args)
    print(EXPLAIN.get(args.code, f"migration task exited with {args.code}"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
