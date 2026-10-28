#!/usr/bin/env python3
"""Merge conditions of the DB Schema Dump root PR (AA-993 Phase E slice M1, root ADR 0017 decision 9).

The publish job of .github/workflows/db-schema-dump.yml opens or updates the root PR bot/db-schema-reference. After an
apply it may merge that PR itself (as aa-ecosys-ci-bot) when every condition below holds; otherwise the PR stays open
for a person. The decision is pure logic here so it can be unit tested (db/tests/test_schema_dump_automerge.py).

  decide   --after-apply true --drift-changed false --erd-drift success --design-ref "" --publish false
           --pr-existed false                       prints merge=yes|no and reason=<why>
  files    --ref-path P --erd-dir D  < names        exit 0 when every changed file is P or a generated page in D
                                                    (never D/design/), 1 otherwise
  checks   --required "Docs lint,gitleaks" < check-runs JSON (GET /repos/{o}/{r}/commits/{sha}/check-runs)
           exit 0 = all complete, required present and green, none red; 1 = red or a required check missing
           once all are complete; 2 = still running (poll again). Last line = the verdict.
"""
from __future__ import annotations

import argparse
import json
import sys

GREEN = {"success", "skipped", "neutral"}


def decide(after_apply: str, drift_changed: str, erd_drift: str, design_ref: str, publish: str,
           pr_existed: str) -> tuple[bool, str]:
    if after_apply != "true":
        return False, "not dispatched after an apply (nightly, manual or run-script): a person merges"
    if design_ref:
        return False, "design_ref is set (a test run of the design ERD check)"
    if publish == "true":
        return False, "publish=true (a forced manual run)"
    if pr_existed != "false":
        return False, "the PR was already open before this run (it may carry a change no apply explains)"
    if drift_changed != "false":
        return False, "the schema drift fingerprint changed (or was not computed): review the drift section"
    if erd_drift != "success":
        return False, f"the design ERD drift check is {erd_drift or 'not run'}"
    return True, "after apply, opened by this run, no drift change, design ERD green"


def files_ok(names: list[str], ref_path: str, erd_dir: str) -> tuple[bool, list[str]]:
    erd_dir = erd_dir.rstrip("/") + "/"
    bad = []
    for n in names:
        if n == ref_path:
            continue
        if n.startswith(erd_dir) and "/" not in n[len(erd_dir):] and n.endswith(".md"):
            continue
        bad.append(n)
    return (not bad and bool(names)), bad


def checks_verdict(runs: list[dict], required: list[str]) -> tuple[int, str]:
    pending = [r["name"] for r in runs if r.get("status") != "completed"]
    if pending:
        return 2, f"pending: {', '.join(sorted(pending))}"
    red = sorted(r["name"] for r in runs if (r.get("conclusion") or "") not in GREEN)
    if red:
        return 1, f"red check(s): {', '.join(red)}"
    names = {r["name"] for r in runs}
    missing = [n for n in required if n not in names]
    if missing:
        # Workflows can take a few seconds to register their check runs on a new head: treat as pending at first;
        # the caller's poll limit turns a lasting gap into "stays open".
        return 2, f"required check(s) not reported yet: {', '.join(missing)}"
    green = [r["name"] for r in runs if r["name"] in required]
    return 0, f"green: {', '.join(sorted(green))}"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decide")
    for flag in ("--after-apply", "--drift-changed", "--erd-drift", "--design-ref", "--publish", "--pr-existed"):
        d.add_argument(flag, default="")
    f = sub.add_parser("files")
    f.add_argument("--ref-path", required=True)
    f.add_argument("--erd-dir", required=True)
    c = sub.add_parser("checks")
    c.add_argument("--required", default="")
    a = ap.parse_args(argv)

    if a.cmd == "decide":
        ok, why = decide(a.after_apply, a.drift_changed, a.erd_drift, a.design_ref, a.publish, a.pr_existed)
        print(f"merge={'yes' if ok else 'no'}")
        print(f"reason={why}")
        return 0
    if a.cmd == "files":
        names = [line.strip() for line in sys.stdin if line.strip()]
        ok, bad = files_ok(names, a.ref_path, a.erd_dir)
        print("files: only generated files" if ok else f"files: not only generated files: {', '.join(bad) or '(none)'}")
        return 0 if ok else 1
    runs = json.load(sys.stdin).get("check_runs", [])
    required = [n.strip() for n in a.required.split(",") if n.strip()]
    rc, verdict = checks_verdict(runs, required)
    print(verdict)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
