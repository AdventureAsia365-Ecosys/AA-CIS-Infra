"""Plans and checks the migration-copy PRs that ci-bot opens and merges (AA-993 M3, root ADR 0017 d2, ADR 0011a).

`.github/workflows/migration-sync.yml` clones each public owner repo's main anonymously (no cross-repo token, no
payload from an app) and runs:

  python3 db/migration_sync.py plan --source cis=owners/AA-CIS-App/api/migrations … [--live schema.json] --out plan.json
  python3 db/migration_sync.py merge-check --pr pr.json --files files.json --checks checks.json \
      --head-file head.sql --source cis=… [--repo-root .] [--ruleset tools/github/infra-main-ruleset.json]

plan: the SET DIFFERENCE per owner (check_migration_copies.OWNERS, not roles/): every `NNN_name.sql` on the owner's
main that is missing from db/migrations/<owner>/, numbered at or above the owner's lowest copy here (below it is the
history from before the copy flow: CIS 001-214, TripPlanner 001-006). A lower-numbered file merged late is found too
(critic 2); it is labelled `out-of-order` when its number is below the owner's highest registered key (`--live`, the
latest DB Schema Dump) or, without a dump, below the owner's highest copy. One entry per file, one branch per file
`bot/migration-copy/<owner>-<NNN>`, with the class label from the header (`migration:expand` = expand header and a
clean lint; `migration:destructive`; else `migration:contract`), a commit message, a PR title and body. A number that
is already used here by another file name is a conflict (listed, never copied: the lint would refuse two files).

merge-check: exit 0 when ci-bot may squash-merge the PR (ADR 0011a decision 1), 2 when it should wait (a check still
running), 1 with the reason when it must not:
  * an open, non-draft PR from a branch of this repo named bot/migration-copy/<owner>-<NNN>, opened by a bot, on main;
  * exactly one changed file, status `added`, db/migrations/<owner>/<NNN>_name.sql of that owner and number;
  * the file at the PR head (`--head-file`) byte-identical to the owner repo's main (`--source`);
  * no gap below it (wait, critic 2): every lower-numbered file of that owner on the owner's main, at or above the
    owner's lowest copy, already has a copy on Infra main (`--repo-root`, the checkout of main; the workflow adds each
    file it merges in the pass). With the pass going per owner in ascending number order, a copy never reaches main
    before a lower one, so migration-apply never sees a later file first (it also stops at any gap on its own);
  * every required check of the ruleset on main (`--ruleset`) present on the head commit and successful (or skipped),
    and no check run failed. The ruleset enforces the checks again at merge time.
Standard library only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_migration_copies as cmc  # noqa: E402
import run_migration as rm  # noqa: E402

DB_DIR = Path(__file__).resolve().parent
REPO_ROOT = DB_DIR.parent
BRANCH_PREFIX = "bot/migration-copy/"
BRANCH_RE = re.compile(r"^bot/migration-copy/(cis|booking|tripplanner|crm)-([0-9]{3})$")
FILE_RE = re.compile(r"^([0-9]{3})_[a-z0-9_]+\.sql$")
LABELS = {"expand": "migration:expand", "contract": "migration:contract", "destructive": "migration:destructive",
          "out-of-order": "out-of-order"}
DEFAULT_RULESET = REPO_ROOT / "tools" / "github" / "infra-main-ruleset.json"
BAD_CONCLUSIONS = {"failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale"}
OK_CONCLUSIONS = {"success", "skipped", "neutral"}


def sync_owners() -> list:
    return [o for o, v in cmc.OWNERS.items() if not v.native]


def parse_sources(values: list) -> dict:
    out = {}
    for v in values:
        owner, sep, path = v.partition("=")
        if not sep or owner not in sync_owners():
            raise SystemExit(f"--source must be OWNER=DIR with OWNER in {', '.join(sync_owners())}: {v!r}")
        out[owner] = Path(path)
    return out


def sql_files(d: Path) -> dict:
    """{name: number} of the NNN_name.sql files in a folder."""
    out = {}
    for p in sorted(d.glob("*.sql")) if d.is_dir() else []:
        m = FILE_RE.match(p.name)
        if m:
            out[p.name] = int(m.group(1))
    return out


def file_class(sql: str, path: str) -> str:
    d = rm.parse_directives(sql)
    if d.destructive:
        return "destructive"
    if d.expand and not rm.lint(sql, d, path)[0]:
        return "expand"
    return "contract"


def highest_registered(registered: set, owner: str) -> int:
    prefix = cmc.OWNERS[owner].key_prefix
    nums = [int(k[len(prefix):]) for k in registered if re.fullmatch(rf"{re.escape(prefix)}[0-9]{{3}}", k)]
    return max(nums) if nums else 0


def plan(repo_root: Path, sources: dict, registered: set | None) -> dict:
    """{"copies": [...], "conflicts": [...], "basis": ...} (see the module docstring)."""
    copies, conflicts = [], []
    for owner in sync_owners():
        src = sources.get(owner)
        if src is None:
            continue
        here = sql_files(repo_root / "db" / "migrations" / owner)
        there = sql_files(src)
        used = {n: name for name, n in here.items()}
        floor = min(here.values()) if here else 0
        top_here = max(here.values()) if here else 0
        top_reg = highest_registered(registered, owner) if registered is not None else None
        for name, number in sorted(there.items(), key=lambda kv: (kv[1], kv[0])):
            if name in here or number < floor:
                continue
            if number in used:
                conflicts.append({"owner": owner, "file": name, "number": number,
                                  "reason": f"number {number:03d} is already used here by {used[number]}"})
                continue
            raw = (src / name).read_bytes()
            rel = f"db/migrations/{owner}/{name}"
            try:
                cls = file_class(raw.decode("utf-8"), rel)
            except UnicodeDecodeError:
                cls = "contract"
            limit = top_reg if top_reg is not None else top_here
            out_of_order = number < limit
            key = f"{cmc.OWNERS[owner].key_prefix}{number:03d}"
            labels = [LABELS[cls]] + ([LABELS["out-of-order"]] if out_of_order else [])
            repo = cmc.OWNERS[owner].repo
            src_path = f"{cmc.OWNERS[owner].source_dir}/{name}"
            note = {
                "expand": "Expand file: `migration-apply` applies it on Dev after this merge (strict number order, "
                          "post-check, isolation probe), when `DB_AUTO_APPLY` is on.",
                "contract": "Contract file: **manual DB Migrate apply needed** after this merge (MIG-4).",
                "destructive": "Destructive file: **manual DB Migrate apply needed** (RDS snapshot, DRY RUN, MIG-12).",
            }[cls]
            if out_of_order:
                basis = (f"the highest registered {owner} key on Dev" if top_reg is not None
                         else f"the highest {owner} copy here (no DB Schema Dump artifact)")
                note += (f" Out of order: its number is below {basis}, so it is never auto-applied; a person applies "
                         f"it with DB Migrate.")
            body = "\n".join([
                f"Byte copy of `{cmc.ORG}/{repo}@{cmc.BRANCH}:{src_path}` (sha256 "
                f"`{hashlib.sha256(raw).hexdigest()[:12]}`), registry key `{key}`.",
                "",
                f"Opened by `migration-sync.yml` (AA-993 M3, root ADR 0017 decision 2). {note}",
                "",
                "ci-bot squash-merges it when every required check is green and the diff is exactly this one file, "
                "byte-identical to the owner's main (ADR 0011a decision 1).",
                "",
                "Refs AA-993",
            ])
            copies.append({
                "owner": owner, "file": name, "number": number, "version": key, "path": rel,
                "source": str(src / name), "branch": f"{BRANCH_PREFIX}{owner}-{number:03d}",
                "class": cls, "out_of_order": out_of_order, "labels": labels,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "title": f"chore: copy {owner} migration {name[:-4]}",
                "commit": f"chore: copy {owner} migration {name[:-4]}\n\nByte copy of {repo} {src_path} "
                          f"(migration-sync).\n\nRefs AA-993",
                "body": body,
            })
    basis = "dump" if registered is not None else "copies"
    return {"copies": copies, "conflicts": conflicts, "out_of_order_basis": basis}


def required_contexts(ruleset: dict) -> list:
    for rule in ruleset.get("rules") or []:
        if rule.get("type") == "required_status_checks":
            return [c["context"] for c in rule["parameters"]["required_status_checks"]]
    return []


def lower_missing(repo_root: Path, src: Path, owner: str, number: int) -> list:
    """Owner-main files numbered below `number` (at or above the owner's lowest copy) whose number has no copy here."""
    here = sql_files(repo_root / "db" / "migrations" / owner)
    used = set(here.values())
    floor = min(used) if used else 0
    return [name for name, n in sorted(sql_files(src).items(), key=lambda kv: (kv[1], kv[0]))
            if floor <= n < number and n not in used]


def merge_check(pr: dict, files: list, checks: list, head_file: bytes | None, sources: dict,
                required: list, repo_root: Path = REPO_ROOT) -> tuple:
    """(code, reason): 0 merge, 2 wait, 1 refuse (see the module docstring)."""
    head = (pr.get("head") or {})
    m = BRANCH_RE.match(head.get("ref") or "")
    if not m:
        return 1, f"head branch {head.get('ref')!r} is not bot/migration-copy/<owner>-<NNN>"
    owner, number = m.group(1), m.group(2)
    if pr.get("state") != "open" or pr.get("draft"):
        return 1, "the PR is not open, or is a draft"
    if (pr.get("base") or {}).get("ref") != "main":
        return 1, "the PR does not target main"
    if (head.get("repo") or {}).get("full_name") != ((pr.get("base") or {}).get("repo") or {}).get("full_name"):
        return 1, "the head branch is not in this repository"
    if (pr.get("user") or {}).get("type") != "Bot":
        return 1, f"opened by {(pr.get('user') or {}).get('login')!r}, not a bot (ci-bot merges only its own PRs)"
    if len(files) != 1:
        return 1, f"{len(files)} changed files; a copy PR changes exactly one"
    f = files[0]
    fm = re.match(rf"^db/migrations/{owner}/({number}_[a-z0-9_]+\.sql)$", f.get("filename") or "")
    if not fm or f.get("status") != "added":
        return 1, f"the changed file {f.get('filename')!r} ({f.get('status')}) is not a new {owner}/{number}_*.sql copy"
    src = sources.get(owner)
    upstream = (src / fm.group(1)) if src else None
    if upstream is None or not upstream.is_file():
        return 1, f"{fm.group(1)} is not on the {owner} owner repo's main"
    if head_file is None or head_file != upstream.read_bytes():
        return 1, f"{fm.group(1)} at the PR head is not byte-identical to the owner repo's main"
    by_name: dict = {}
    for c in checks:
        by_name.setdefault(c.get("name"), []).append(c)
    bad = [c["name"] for c in checks if c.get("status") == "completed" and c.get("conclusion") in BAD_CONCLUSIONS]
    if bad:
        return 1, f"check(s) failed on the head commit: {', '.join(sorted(set(bad)))}"
    gap = lower_missing(repo_root, src, owner, int(number))
    if gap:
        return 2, (f"waiting for lower-numbered {owner} file(s) to reach main first: {', '.join(gap)} (their copy PRs "
                   f"merge before this one; never past a gap)")
    waiting = []
    for ctx in required:
        runs = by_name.get(ctx) or []
        if not runs or any(c.get("status") != "completed" for c in runs):
            waiting.append(ctx)
        elif not all(c.get("conclusion") in OK_CONCLUSIONS for c in runs):
            return 1, f"required check {ctx!r} did not succeed"
    if waiting:
        return 2, f"waiting for required check(s): {', '.join(waiting)}"
    running = [c["name"] for c in checks if c.get("status") != "completed"]
    if running:
        return 2, f"waiting for check(s) still running: {', '.join(sorted(set(running)))}"
    return 0, f"ok: {f['filename']} is byte-identical to the owner's main and every required check is green"


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--repo-root", default=str(REPO_ROOT))
    p.add_argument("--source", action="append", default=[], help="OWNER=DIR: the owner repo main's migrations folder")
    p.add_argument("--live", help="schema.json of the latest DB Schema Dump (registered keys, for out-of-order)")
    p.add_argument("--out", required=True)
    m = sub.add_parser("merge-check")
    m.add_argument("--pr", required=True, help="GET /repos/{o}/{r}/pulls/{n} JSON")
    m.add_argument("--files", required=True, help="GET …/pulls/{n}/files JSON")
    m.add_argument("--checks", required=True, help="GET …/commits/{head sha}/check-runs JSON")
    m.add_argument("--head-file", required=True, help="the file's bytes at the PR head (may be missing)")
    m.add_argument("--source", action="append", default=[])
    m.add_argument("--repo-root", default=str(REPO_ROOT), help="checkout of Infra main (the copies already there)")
    m.add_argument("--ruleset", default=str(DEFAULT_RULESET))
    args = parser.parse_args(argv)
    if args.cmd == "plan":
        live = json.loads(Path(args.live).read_text(encoding="utf-8")) if args.live else None
        registered = {x["version"] for x in live.get("migrations") or []} if live else None
        out = plan(Path(args.repo_root), parse_sources(args.source), registered)
        Path(args.out).write_text(json.dumps(out, indent=1, sort_keys=True), encoding="utf-8")
        for c in out["copies"]:
            print(f"SYNC copy {c['owner']}/{c['file']} -> {c['branch']} [{', '.join(c['labels'])}]")
        for c in out["conflicts"]:
            print(f"SYNC conflict {c['owner']}/{c['file']}: {c['reason']}")
        if not out["copies"] and not out["conflicts"]:
            print("SYNC nothing to copy: every owner file at or above the lowest copy is here")
        return 0
    checks = json.loads(Path(args.checks).read_text(encoding="utf-8"))
    head = Path(args.head_file)
    code, reason = merge_check(json.loads(Path(args.pr).read_text(encoding="utf-8")),
                               json.loads(Path(args.files).read_text(encoding="utf-8")),
                               checks.get("check_runs", checks) if isinstance(checks, dict) else checks,
                               head.read_bytes() if head.is_file() else None, parse_sources(args.source),
                               required_contexts(json.loads(Path(args.ruleset).read_text(encoding="utf-8"))),
                               Path(args.repo_root))
    print(f"MERGE-CHECK {['merge', 'refuse', 'wait'][code]}: {reason}")
    return code


if __name__ == "__main__":
    sys.exit(main())
