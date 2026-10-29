#!/usr/bin/env python3
"""Lead time of an owner migration, from the app PR merge to the schema on Dev (AA-993, root ADR 0017 Consequences).

For the last N migration files copied into db/migrations/<owner>/ here, it reads from the GitHub API (read only,
through `gh api`):

  app merged   the owner repo's PR that added the file (the merge of the first commit on main that touches it)
  copy opened  the AA-CIS-Infra PR that added the copy (a bot/migration-copy/* PR of ci-bot, or a person's PR)
  copy merged  that PR's merge
  applied      auto: the Migration Apply run on the copy's merge commit with "Apply on Dev" success (+ the blocking
               Isolation Probe); manual: the first successful DB Migrate run after the copy merge (approximate: the
               run's inputs are not in the API) or, exact, the key's shared.schema_versions.applied_at from
               --applied-at (CSV "version,applied_at", e.g. from the S258 schema_versions read script)

and prints one row per file plus the median / max total and how many met the ADR 0017 target (default 25 min).

  python3 tools/github/migration_lead_time.py --last 10
  python3 tools/github/migration_lead_time.py --last 5 --owner booking --applied-at applied.csv --json out.json

Needs a `gh` login that can read the public repos (any account). Writes nothing on GitHub.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta

ORG = "AdventureAsia365-Ecosys"
INFRA = f"{ORG}/AA-CIS-Infra"
# db/owners.yaml owners: <owner dir> -> (repo, migrations path, schema_versions key prefix)
OWNERS = {
    "cis": ("AA-CIS-App", "api/migrations", ""),
    "booking": ("AA-Booking", "migrations", "bk-"),
    "tripplanner": ("AA-TripPlanner-Web", "migrations", "tp-"),
    "crm": ("AA-Partner", "api/migrations", "crm-"),
}
COPY_RE = re.compile(r"^db/migrations/(cis|booking|tripplanner|crm)/(\d{3})_[^/]+\.sql$")
APPLY_JOB = "Apply on Dev"
PROBE_JOB = "Isolation probe"
MANUAL_WINDOW = timedelta(hours=24)


@dataclass
class Row:
    owner: str
    file: str
    key: str
    app_pr: int | None = None
    app_merged: str | None = None
    copy_pr: int | None = None
    copy_author: str | None = None
    copy_opened: str | None = None
    copy_merged: str | None = None
    applied: str | None = None
    applied_how: str = "unknown"          # auto | auto+probe | listed-only | manual~ | schema_versions | unknown
    notes: list[str] = field(default_factory=list)

    def minutes(self) -> dict[str, float | None]:
        t0 = self.app_merged
        return {
            "to_copy_opened": minutes_between(t0, self.copy_opened),
            "to_copy_merged": minutes_between(t0, self.copy_merged),
            "to_applied": minutes_between(t0, self.applied),
        }


# ── pure helpers (tools/github/tests/test_migration_lead_time.py) ─────────────────────────────────────────────────

def parse_ts(s: str | None) -> datetime | None:
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def minutes_between(a: str | None, b: str | None) -> float | None:
    ta, tb = parse_ts(a), parse_ts(b)
    if ta is None or tb is None:
        return None
    return round((tb - ta).total_seconds() / 60, 1)


def copied_files(files: list[dict]) -> list[tuple[str, str, str]]:
    """(owner, file name, NNN) for every owner migration file a PR ADDED (a copy), from its /files listing."""
    out = []
    for f in files:
        m = COPY_RE.match(f.get("filename", ""))
        if m and f.get("status") == "added":
            out.append((m.group(1), f["filename"].rsplit("/", 1)[1], m.group(2)))
    return out


def version_key(owner: str, number: str) -> str:
    return OWNERS[owner][2] + number


def apply_from_jobs(jobs: list[dict]) -> tuple[str | None, str]:
    """(completed_at, how) of a Migration Apply run from its jobs: the apply job's end when it succeeded (with the
    probe's end when that succeeded too); "listed-only" when the apply job was skipped (DB_AUTO_APPLY off)."""
    apply = next((j for j in jobs if j.get("name", "").startswith(APPLY_JOB)), None)
    if apply is None:
        return None, "unknown"
    if apply.get("conclusion") == "skipped":
        return None, "listed-only"
    if apply.get("conclusion") != "success":
        return None, f"apply {apply.get('conclusion')}"
    probes = [j for j in jobs if j.get("name", "").startswith(PROBE_JOB)]
    if probes and all(p.get("conclusion") == "success" for p in probes):
        return max(p["completed_at"] for p in probes), "auto+probe"
    return apply.get("completed_at"), "auto"


def summarise(rows: list[Row], target: float) -> dict:
    totals = [r.minutes()["to_applied"] for r in rows]
    totals = [t for t in totals if t is not None]
    return {
        "files": len(rows),
        "measured": len(totals),
        "median_min": round(statistics.median(totals), 1) if totals else None,
        "max_min": max(totals) if totals else None,
        "within_target": sum(1 for t in totals if t <= target),
        "target_min": target,
        "no_hand_step": sum(1 for r in rows if r.applied_how.startswith("auto")
                            and (r.copy_author or "").startswith("aa-ecosys-ci-bot")),
    }


# ── GitHub reads ──────────────────────────────────────────────────────────────────────────────────────────────────

def gh(path: str):
    """One page of a GitHub API read (gh >= 2.45; no --slurp there, and one page of 100 is enough here)."""
    out = subprocess.run(["gh", "api", "-H", "Accept: application/vnd.github+json", path],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def infra_copies(scan: int) -> list[tuple[dict, str, str, str]]:
    """(pr, owner, file, NNN) for the copies added by the last `scan` merged Infra PRs, newest first."""
    prs = gh(f"repos/{INFRA}/pulls?state=closed&base=main&sort=updated&direction=desc&per_page=100")
    prs = sorted((p for p in prs if p.get("merged_at")), key=lambda p: p["merged_at"], reverse=True)[:scan]
    out = []
    for p in prs:
        for owner, name, num in copied_files(gh(f"repos/{INFRA}/pulls/{p['number']}/files?per_page=100")):
            out.append((p, owner, name, num))
    return out


def app_merge(owner: str, name: str) -> tuple[int | None, str | None, str]:
    repo, path, _ = OWNERS[owner]
    commits = gh(f"repos/{ORG}/{repo}/commits?sha=main&path={path}/{name}&per_page=100")
    if not commits:
        return None, None, "file not on the owner's main"
    first = commits[-1]                                     # oldest commit that touches the file = the one adding it
    pulls = [p for p in gh(f"repos/{ORG}/{repo}/commits/{first['sha']}/pulls") if p.get("merged_at")]
    if pulls:
        return pulls[0]["number"], pulls[0]["merged_at"], ""
    return None, first["commit"]["committer"]["date"], "no PR for the adding commit (commit date used)"


def applied_time(row: Row, merge_sha: str, applied_at: dict[str, str]) -> None:
    runs = gh(f"repos/{INFRA}/actions/workflows/migration-apply.yml/runs?head_sha={merge_sha}&per_page=20")["workflow_runs"]
    for run in sorted(runs, key=lambda r: r["created_at"]):
        when, how = apply_from_jobs(gh(f"repos/{INFRA}/actions/runs/{run['id']}/jobs?per_page=50")["jobs"])
        if when:
            row.applied, row.applied_how = when, how
            return
        if how != "unknown":
            row.applied_how = how
            row.notes.append(f"Migration Apply run {run['id']}: {how}")
    if row.key in applied_at:
        row.applied, row.applied_how = applied_at[row.key], "schema_versions"
        return
    since = row.copy_merged
    runs = gh(f"repos/{INFRA}/actions/workflows/db-migrate.yml/runs?status=success&created=%3E%3D{since}&per_page=100")["workflow_runs"]
    limit = parse_ts(since) + MANUAL_WINDOW
    runs = [r for r in runs if parse_ts(r["created_at"]) <= limit]
    if runs:
        first = min(runs, key=lambda r: r["created_at"])
        row.applied, row.applied_how = first["updated_at"], "manual~"
        row.notes.append(f"DB Migrate run {first['id']} (first success after the copy; file not checked)")


def read_applied_at(path: str | None) -> dict[str, str]:
    if not path:
        return {}
    with open(path, newline="") as fh:
        return {r["version"]: r["applied_at"] for r in csv.DictReader(fh)}


def render(rows: list[Row], summary: dict) -> str:
    head = f"{'file':<46} {'app PR':>7} {'copy PR':>8} {'opened':>7} {'merged':>7} {'applied':>8}  how"
    lines = [head, "-" * len(head)]
    for r in rows:
        m = r.minutes()
        cell = lambda v: "-" if v is None else f"{v:g}"  # noqa: E731
        lines.append(f"{r.owner + '/' + r.file:<46.46} {('#' + str(r.app_pr)) if r.app_pr else '-':>7} "
                     f"{('#' + str(r.copy_pr)) if r.copy_pr else '-':>8} {cell(m['to_copy_opened']):>7} "
                     f"{cell(m['to_copy_merged']):>7} {cell(m['to_applied']):>8}  {r.applied_how}"
                     + (f"  ({'; '.join(r.notes)})" if r.notes else ""))
    lines.append("")
    lines.append("minutes from the app PR merge. " + ", ".join(f"{k}={v}" for k, v in summary.items()))
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--last", type=int, default=10, help="migration files to measure (newest copies first)")
    ap.add_argument("--scan", type=int, default=60, choices=range(1, 101), metavar="1-100",
                    help="merged Infra PRs to scan for copies (one API page)")
    ap.add_argument("--owner", choices=sorted(OWNERS), action="append", help="only these owners (repeatable)")
    ap.add_argument("--applied-at", help="CSV version,applied_at from shared.schema_versions (exact manual applies)")
    ap.add_argument("--target", type=float, default=25.0, help="ADR 0017 target, minutes (default 25)")
    ap.add_argument("--json", help="also write the rows and the summary here")
    args = ap.parse_args(argv)

    applied_at = read_applied_at(args.applied_at)
    rows: list[Row] = []
    for pr, owner, name, num in infra_copies(args.scan):
        if args.owner and owner not in args.owner:
            continue
        row = Row(owner=owner, file=name, key=version_key(owner, num), copy_pr=pr["number"],
                  copy_author=pr["user"]["login"], copy_opened=pr["created_at"], copy_merged=pr["merged_at"])
        row.app_pr, row.app_merged, note = app_merge(owner, name)
        if note:
            row.notes.append(note)
        applied_time(row, pr["merge_commit_sha"], applied_at)
        rows.append(row)
        if len(rows) >= args.last:
            break
    summary = summarise(rows, args.target)
    print(render(rows, summary))
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"rows": [asdict(r) | {"minutes": r.minutes()} for r in rows], "summary": summary}, fh, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
