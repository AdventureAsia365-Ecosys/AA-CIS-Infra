#!/usr/bin/env python3
"""Delete GitHub Actions caches that no other run can read (S273, AA-1024): pull request and merge-queue refs.

A cache saved on refs/pull/<n>/merge is readable only by later runs of that pull request, and one saved on a merge-queue
ref (refs/heads/gh-readonly-queue/<base>/pr-<n>-<sha>) only by that queue group. Both stay until GitHub's 7-day idle
eviction or the 10 GB per-repo cap, and above the cap GitHub evicts least-recently-used entries first, which can be
the default-branch entries every run restores. On 08/11/2026 AA-CIS-App was at 10.7 GB (7.5 GB on pull request and
queue refs) and AA-Booking at 9.2 GB; a one-off script freed ~13.8 GB. This keeps it that way:

  pr     the caches of one pull request's refs (refs/pull/<n>/merge and /head): the Cache cleanup workflow runs it when
         the pull request closes (merged or not).
  queue  the caches of merge-queue refs not used for more than --max-age-hours (2): the Cache cleanup schedule.
  stale  both kinds for the whole repo (pull requests that are not open, queue refs older than the age): the root
         tools/github/ci_hygiene.py --clean, with the tech lead's gh login.

Default-branch and other branch caches are never touched. Dry run unless --apply; prints counts and bytes either way.
Reads and deletes go through the `gh` CLI (GH_TOKEN in a workflow: the job needs `actions: write`). Stdlib only. The
same file in the root repo, AA-CIS-App, AA-Booking, AA-Partner, AA-TripPlanner-Web and AA-CIS-Infra: change it in all
of them in the same wave (the root tools/github/ci_hygiene.py imports the root copy).
Run: python3 .github/scripts/cache_cleanup.py pr --repo OWNER/NAME --pr N [--apply]
     python3 .github/scripts/cache_cleanup.py queue --repo OWNER/NAME [--max-age-hours H] [--apply]
     python3 .github/scripts/cache_cleanup.py stale --repo OWNER/NAME [--max-age-hours H] [--apply]
Exit 0 = done (or nothing to do), 1 = a list or delete call failed.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

PR_REF = re.compile(r"^refs/pull/(\d+)/(?:merge|head)$")
QUEUE_REF = re.compile(r"^refs/heads/gh-readonly-queue/")
DEFAULT_MAX_AGE_HOURS = 2.0


class GhError(RuntimeError):
    """A gh call failed (login, permission, rate limit)."""


def gh(args: list[str], run=subprocess.run) -> str:
    proc = run(["gh", *args], capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise GhError(f"gh {' '.join(args[:3])}: {(proc.stderr or proc.stdout or '').strip()[:300]}")
    return proc.stdout


def list_caches(repo: str, run=subprocess.run) -> list[dict]:
    """Every cache entry of the repo (id, ref, key, size_in_bytes, last_accessed_at, ...)."""
    out = gh(["api", "--paginate", f"repos/{repo}/actions/caches?per_page=100", "--jq", ".actions_caches[]"], run)
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def open_pull_requests(repo: str, run=subprocess.run) -> set[int]:
    out = gh(["api", "--paginate", f"repos/{repo}/pulls?state=open&per_page=100", "--jq", ".[].number"], run)
    return {int(n) for n in out.split()}


def _when(cache: dict) -> datetime | None:
    raw = cache.get("last_accessed_at") or cache.get("created_at") or ""
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def pr_number(ref: str) -> int | None:
    m = PR_REF.match(ref or "")
    return int(m.group(1)) if m else None


def is_old_queue_cache(cache: dict, now: datetime, max_age: timedelta) -> bool:
    if not QUEUE_REF.match(cache.get("ref") or ""):
        return False
    when = _when(cache)
    return when is not None and now - when > max_age


def select(caches: list[dict], mode: str, *, pr: int | None = None, open_prs: set[int] | None = None,
           now: datetime | None = None, max_age_hours: float = DEFAULT_MAX_AGE_HOURS) -> list[dict]:
    """The caches `mode` deletes: 'pr' (that pull request's refs), 'queue' (old queue refs), 'stale' (both kinds)."""
    now = now or datetime.now(timezone.utc)
    max_age = timedelta(hours=max_age_hours)
    chosen = []
    for cache in caches:
        n = pr_number(cache.get("ref") or "")
        if mode == "pr":
            hit = n is not None and n == pr
        elif mode == "queue":
            hit = is_old_queue_cache(cache, now, max_age)
        elif mode == "stale":
            hit = (n is not None and n not in (open_prs or set())) or is_old_queue_cache(cache, now, max_age)
        else:
            raise ValueError(f"unknown mode {mode!r}")
        if hit:
            chosen.append(cache)
    return chosen


def total_bytes(caches: list[dict]) -> int:
    return sum(int(c.get("size_in_bytes") or 0) for c in caches)


def gb(n: int) -> str:
    return f"{n / 1e9:.2f} GB"


def delete(repo: str, caches: list[dict], run=subprocess.run, log=print) -> int:
    """Delete each cache by id; returns the number that failed (an entry already gone counts as deleted)."""
    failed = 0
    for cache in caches:
        proc = run(["gh", "api", "-X", "DELETE", f"repos/{repo}/actions/caches/{cache['id']}"], capture_output=True,
                   text=True, timeout=60)
        if proc.returncode != 0 and "404" not in (proc.stderr or ""):
            failed += 1
            log(f"::warning::delete cache {cache['id']} ({cache.get('ref')}): {(proc.stderr or '').strip()[:200]}")
    return failed


def run_mode(repo: str, mode: str, *, pr: int | None = None, apply: bool = False,
             max_age_hours: float = DEFAULT_MAX_AGE_HOURS, run=subprocess.run, now: datetime | None = None,
             log=print) -> dict:
    """List, select and (with apply) delete; returns the counts the caller prints or reports."""
    caches = list_caches(repo, run)
    open_prs = open_pull_requests(repo, run) if mode == "stale" else None
    drop = select(caches, mode, pr=pr, open_prs=open_prs, now=now, max_age_hours=max_age_hours)
    result = {"repo": repo, "mode": mode, "caches": len(caches), "bytes": total_bytes(caches), "drop": len(drop),
              "drop_bytes": total_bytes(drop), "deleted": 0, "failed": 0, "applied": apply}
    log(f"{repo}: {gb(result['bytes'])} in {len(caches)} caches; {mode}: {len(drop)} to delete "
        f"({gb(result['drop_bytes'])}) -> {gb(result['bytes'] - result['drop_bytes'])}"
        + ("" if apply else " (dry run: --apply deletes)"))
    if apply and drop:
        result["failed"] = delete(repo, drop, run, log)
        result["deleted"] = len(drop) - result["failed"]
        log(f"  deleted {result['deleted']}, failed {result['failed']}")
    return result


def main(argv: list[str] | None = None, run=subprocess.run) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    for name in ("pr", "queue", "stale"):
        p = sub.add_parser(name)
        p.add_argument("--repo", required=True, help="OWNER/NAME")
        p.add_argument("--apply", action="store_true")
        if name == "pr":
            p.add_argument("--pr", required=True, type=int)
        else:
            p.add_argument("--max-age-hours", type=float, default=DEFAULT_MAX_AGE_HOURS)
    a = ap.parse_args(argv)
    try:
        result = run_mode(a.repo, a.mode, pr=getattr(a, "pr", None), apply=a.apply,
                          max_age_hours=getattr(a, "max_age_hours", DEFAULT_MAX_AGE_HOURS), run=run)
    except (GhError, json.JSONDecodeError, subprocess.TimeoutExpired) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 1 if result["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
