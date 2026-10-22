#!/usr/bin/env python3
"""AA-879 (U-61): the shared RDS connection budget, checked from the code instead of by hand.

Data standards Part C (root docs/architecture/data-standards/03-scaling.md):
- C2.3c: for every role with a CONNECTION LIMIT, sum(pool max_size x max processes) over the role's pools
  must be <= that limit, and the C2.2 total must be <= 75 % of max_connections. "To build (N3): a CI script
  that parses the Terraform values and fails on an over-budget sum." This is that script.

Inputs (all from db/connection_budget.json, which says where each number lives):
- max processes per pool: parsed from the Terraform in THIS repo (ECS autoscaling max_capacity,
  worker_max_count, Lambda reserved concurrency, Booking deployment overlap), or a fixed count;
- CONNECTION LIMIT per role: the manifest value must equal the last `ALTER ROLE <role> ... CONNECTION LIMIT n`
  in db/migrations/roles/*.sql (X1 role bootstrap), else in db/migrations/cis/*.sql (N3 interim);
- max_connections: accounts/aa365/observability_ecosys.tf `local.rds_max_connections`, which must match the
  manifest's value for the RDS instance class read from Terraform;
- pool max_size: the manifest value; with --verify-sources it must also equal the value parsed from the owner
  app's `main` (public repos, GitHub contents API; GITHUB_TOKEN only lifts the rate limit).

An over-budget check passes only when an `accepted_overages` entry names it, the computed value is <=
`accept_up_to` (so any further growth fails) and `until` is today or later and at most 60 days ahead.
Standard library only. TODAY_OVERRIDE=YYYY-MM-DD for tests.

Usage: python3 db/check_connection_budget.py [--manifest db/connection_budget.json] [--repo-root .]
                                             [--verify-sources]
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import math
import os
import re
import sys
from pathlib import Path
from typing import Callable, Optional

MAX_ACCEPT_DAYS = 60
ALTER_LIMIT = re.compile(r"ALTER\s+ROLE\s+(\w+)\b[^;]*?\bCONNECTION\s+LIMIT\s+(-?\d+)", re.I)
TRANSFORMS: dict[str, Callable[[int], int]] = {
    # shared/jobs/worker.py: create_pool(..., max_size=max(5, max_parallel + 2))
    "worker_pool": lambda v: max(5, v + 2),
}


class BudgetError(Exception):
    pass


def _read(root: Path, rel: str) -> str:
    path = root / rel
    if not path.is_file():
        raise BudgetError(f"{rel}: file not found")
    return path.read_text(encoding="utf-8")


def _match(text: str, regex: str, where: str, flags: int = re.S) -> str:
    m = re.search(regex, text, flags)
    if not m:
        raise BudgetError(f"{where}: pattern not found ({regex})")
    return m.group(1)


def tf_value(root: Path, spec: dict) -> str:
    """The value of spec['tf_regex'] in spec['tf_file'], unless an override in spec['override_glob'] sets it."""
    if "override_glob" in spec:
        for path in sorted(glob.glob(str(root / spec["override_glob"]))):
            m = re.search(spec["override_regex"], Path(path).read_text(encoding="utf-8"), re.S)
            if m:
                return m.group(1)
    return _match(_read(root, spec["tf_file"]), spec["tf_regex"], spec["tf_file"])


def processes(root: Path, pool: dict) -> int:
    spec = pool["processes"]
    if "fixed" in spec:
        return int(spec["fixed"])
    raw = float(tf_value(root, spec)) * float(spec.get("scale", 1))
    return int(math.ceil(raw))


def live_role_limits(root: Path) -> dict[str, int]:
    """Last CONNECTION LIMIT per role: db/migrations/roles wins over db/migrations/cis (applied later, X1)."""
    limits: dict[str, int] = {}
    for sub in ("cis", "roles"):
        for path in sorted((root / "db" / "migrations" / sub).glob("*.sql")):
            text = path.read_text(encoding="utf-8")
            text = re.sub(r"--[^\n]*", "", text)  # comments may quote old values
            for role, n in ALTER_LIMIT.findall(text):
                limits[role.lower()] = int(n)
    return limits


def check(manifest: dict, root: Path, today: dt.date,
          fetch: Optional[Callable[[str, str], Optional[bytes]]] = None) -> tuple[list[str], list[str], list[str]]:
    """Returns (errors, warnings, report lines)."""
    errors: list[str] = []
    warnings: list[str] = []
    report: list[str] = []

    # max_connections and the ceiling
    mc = manifest["max_connections"]
    try:
        tf_max = int(_match(_read(root, mc["tf_file"]), mc["tf_regex"], mc["tf_file"]))
        cls = tf_value(root, mc["instance_class"])
    except BudgetError as e:
        errors.append(str(e))
        return errors, warnings, report
    expected = mc["by_class"].get(cls)
    if expected is None:
        errors.append(f"instance class {cls} has no max_connections in the manifest (by_class); measure it "
                      f"with SHOW max_connections after the resize and add it")
    elif expected != tf_max:
        errors.append(f"{mc['tf_file']} rds_max_connections = {tf_max}, but the manifest says {expected} for {cls}")
    ceiling = math.floor(tf_max * manifest["ceiling_pct"] / 100)
    report.append(f"instance {cls}: max_connections {tf_max}, ceiling {manifest['ceiling_pct']} % = {ceiling}")

    # role limits: manifest vs role files
    live = live_role_limits(root)
    for role, limit in manifest["role_limits"].items():
        if role not in live:
            errors.append(f"role {role}: no ALTER ROLE ... CONNECTION LIMIT in db/migrations/roles or cis")
        elif live[role] != limit:
            errors.append(f"role {role}: manifest limit {limit}, role files set {live[role]}")

    # pools
    per_role: dict[str, int] = {}
    total = 0
    for pool in manifest["pools"]:
        try:
            n = processes(root, pool)
        except BudgetError as e:
            errors.append(f"pool {pool['name']}: {e}")
            continue
        for rule in pool.get("tf_must_not_contain", []):
            for path in sorted(glob.glob(str(root / rule["glob"]))):
                if rule["text"] in Path(path).read_text(encoding="utf-8"):
                    rel = Path(path).relative_to(root).as_posix()
                    errors.append(f"pool {pool['name']}: {rel} mentions {rule['text']} — {rule['why']}")
        if fetch is not None and "source" in pool:
            src = pool["source"]
            try:
                body = fetch(src["repo"], src["path"])
            except BudgetError as e:
                errors.append(f"pool {pool['name']}: {e}")
                body = b""
            if body == b"":
                pass
            elif body is None:
                errors.append(f"pool {pool['name']}: {src['repo']}:{src['path']} not found on main")
            else:
                try:
                    v = int(_match(body.decode("utf-8"), src["regex"], f"{src['repo']}:{src['path']}",
                                   re.S | re.M))
                    v = TRANSFORMS[src["transform"]](v) if "transform" in src else v
                    if v != pool["max_size"]:
                        errors.append(f"pool {pool['name']}: manifest max_size {pool['max_size']}, "
                                      f"{src['repo']} main has {v} ({src['path']})")
                except BudgetError as e:
                    errors.append(f"pool {pool['name']}: {e}")
        worst = pool["max_size"] * n
        per_role[pool["role"]] = per_role.get(pool["role"], 0) + worst
        total += worst
        report.append(f"pool {pool['name']:<44} {pool['role']:<12} {pool['max_size']:>3} x {n:>3} = {worst:>4}")
    for r in manifest.get("reserves", []):
        total += r["connections"]
        report.append(f"reserve {r['name']:<41} {'':<12} {r['connections']:>15}")
    report.append(f"total {total} / ceiling {ceiling}")

    # over-budget checks, then accepted overages
    over: dict[str, tuple[int, int]] = {}
    for role, used in sorted(per_role.items()):
        limit = manifest["role_limits"].get(role)
        report.append(f"role {role:<12} {used:>4} / limit {limit}")
        if limit is not None and used > limit:
            over[f"role:{role}"] = (used, limit)
    if total > ceiling:
        over["total"] = (total, ceiling)

    accepted = {a["check"]: a for a in manifest.get("accepted_overages", [])}
    for key, a in accepted.items():
        try:
            until = dt.date.fromisoformat(a["until"])
        except (KeyError, ValueError):
            errors.append(f"accepted overage {key}: 'until' must be YYYY-MM-DD")
            continue
        if not a.get("reason"):
            errors.append(f"accepted overage {key}: needs a reason")
        if until < today:
            errors.append(f"accepted overage {key} expired on {until}: fix the budget or renew it with a new reason")
        elif (until - today).days > MAX_ACCEPT_DAYS:
            errors.append(f"accepted overage {key}: until {until} is more than {MAX_ACCEPT_DAYS} days ahead")
        if key not in over:
            warnings.append(f"accepted overage {key} is no longer needed (within budget): remove it")
    for key, (used, cap) in over.items():
        a = accepted.get(key)
        if a is None:
            errors.append(f"{key}: worst case {used} > {cap} (C2.3c). Shrink a pool or a process count, or raise "
                          f"the limit through a roles/ file, and update the C2.2 table")
        elif used > int(a.get("accept_up_to", 0)):
            errors.append(f"{key}: worst case {used} > {cap}, and above the accepted {a.get('accept_up_to')} "
                          f"— this change makes an accepted overage worse")
        else:
            warnings.append(f"{key}: worst case {used} > {cap}, accepted until {a['until']}: {a['reason']}")
    return errors, warnings, report


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="db/connection_budget.json")
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--verify-sources", action="store_true",
                    help="also compare each pool max_size with the owner app's main (network)")
    args = ap.parse_args(argv)
    root = Path(args.repo_root).resolve()
    manifest = json.loads((root / args.manifest).read_text(encoding="utf-8"))
    today = dt.date.fromisoformat(os.environ.get("TODAY_OVERRIDE") or dt.date.today().isoformat())

    fetch = None
    if args.verify_sources:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from check_migration_copies import FetchError, github_fetch  # noqa: E402

        def fetch(repo: str, path: str) -> Optional[bytes]:
            try:
                return github_fetch(repo, path)
            except FetchError as e:
                raise BudgetError(str(e)) from None

    try:
        errors, warnings, report = check(manifest, root, today, fetch)
    except BudgetError as e:
        errors, warnings, report = [str(e)], [], []
    for line in report:
        print(line)
    for w in warnings:
        print(f"::warning::{w}")
    for e in errors:
        print(f"::error::{e}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write("### Connection budget (C2.2)\n\n```\n" + "\n".join(report) + "\n```\n")
            for w in warnings:
                fh.write(f"- warning: {w}\n")
            for e in errors:
                fh.write(f"- **error**: {e}\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
