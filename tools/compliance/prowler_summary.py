#!/usr/bin/env python3
"""AA-1173 (S290, compliance readiness phase 2) — turn the weekly Prowler scan into the evidence bundle of Platform ›
Compliance (source prowler_weekly).

The workflow "Compliance AWS" (.github/workflows/compliance-aws.yml) runs Prowler (the open source scanner, tech lead
S287 Q11: no Security Hub, no AWS Config) from its container image pinned by digest, with the read-only role
aa-cis-<env>-compliance-evidence, and writes its findings as JSON-OCSF into the runner's temp directory. Every byte of
Prowler's own output goes to files, never to the log (the public repo prints counts only, advisory section 4 C.5). This
tool reads the findings and writes the bundle the CIS API ingests; the raw findings file is sealed next to it in the
Object Lock evidence bucket (tools/compliance/seal.py), private.

Rows:
  prowler_scan_recent    pass when the scan produced findings (the freshness is the validity window of the source,
                         cis.compliance.validity_hours.prowler_weekly); detail: totals, failing by severity, pass /
                         fail per compliance framework Prowler maps (ISO 27001, SOC 2, CIS, ...), the Prowler version
  prowler_critical_high  fact ``critical_high`` = failing findings of severity critical or high; CIS grades it against
                         cis.compliance.prowler_critical_high_max (a known finding belongs in an approved exception)
A scan with no findings file (Prowler crashed) gives two ``error`` rows naming the step, never a pass.

    python3 tools/compliance/prowler_summary.py --findings out/prowler.ocsf.json --out out/bundle.json \\
        [--prowler-version 5.48.0]

Stdlib only. Detail holds counts and framework names only (no account id, no ARN, no resource name).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

FORMAT = 1
SOURCE = "prowler_weekly"
LINK = "https://github.com/AdventureAsia365-Ecosys/AA-CIS-Infra/blob/main/.github/workflows/compliance-aws.yml"
SEVERITIES = ("critical", "high", "medium", "low", "informational")
MAX_FRAMEWORKS = 40   # bounds the detail (the CIS evidence detail is at most 8 KiB)
_FRAMEWORK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,60}$")


def _status(f: dict) -> str:
    s = str(f.get("status_code") or f.get("status") or "").upper()
    return s if s in ("PASS", "FAIL", "MANUAL") else "OTHER"


def _severity(f: dict) -> str:
    s = str(f.get("severity") or "").lower()
    return s if s in SEVERITIES else "informational"


def summarize(findings: list) -> dict:
    totals = {"PASS": 0, "FAIL": 0, "MANUAL": 0, "OTHER": 0}
    fail_by_sev = {s: 0 for s in SEVERITIES}
    frameworks: dict = {}
    for f in findings:
        if not isinstance(f, dict):
            continue
        st = _status(f)
        totals[st] += 1
        if st == "FAIL":
            fail_by_sev[_severity(f)] += 1
        comp = (f.get("unmapped") or {}).get("compliance") or {}
        if isinstance(comp, dict):
            for name in comp:
                if not isinstance(name, str) or not _FRAMEWORK.fullmatch(name):
                    continue
                row = frameworks.setdefault(name, {"pass": 0, "fail": 0})
                if st == "PASS":
                    row["pass"] += 1
                elif st == "FAIL":
                    row["fail"] += 1
    top = dict(sorted(frameworks.items(), key=lambda kv: -(kv[1]["pass"] + kv[1]["fail"]))[:MAX_FRAMEWORKS])
    return {"findings": sum(totals.values()), "pass": totals["PASS"], "fail": totals["FAIL"],
            "manual": totals["MANUAL"], "fail_by_severity": fail_by_sev, "frameworks": dict(sorted(top.items())),
            "critical_high": fail_by_sev["critical"] + fail_by_sev["high"]}


def rows(findings: Optional[list], version: Optional[str], problem: Optional[str] = None) -> list:
    if findings is None:
        why = problem or "the scan produced no findings file"
        return [{"check_id": cid, "status": "error", "summary": why[:300], "detail": {}, "link": LINK}
                for cid in ("prowler_scan_recent", "prowler_critical_high")]
    s = summarize(findings)
    detail = {k: s[k] for k in ("findings", "pass", "fail", "manual", "fail_by_severity", "frameworks")}
    detail["prowler_version"] = version
    return [
        {"check_id": "prowler_scan_recent", "status": "pass" if s["findings"] else "error",
         "summary": f"{s['findings']} findings: {s['pass']} pass, {s['fail']} fail, {s['manual']} manual"
         if s["findings"] else "the scan returned no finding (nothing was checked)", "detail": detail, "link": LINK},
        {"check_id": "prowler_critical_high", "status": "pass" if s["findings"] else "error",
         "summary": f"{s['critical_high']} failing critical or high finding(s)",
         "detail": {"critical_high": s["critical_high"], "fail_by_severity": s["fail_by_severity"]}, "link": LINK},
    ]


def load_findings(path: Path) -> tuple[Optional[list], Optional[str]]:
    if not path.is_file():
        return None, "the scan produced no findings file"
    try:
        data = json.loads(path.read_text(encoding="utf-8") or "[]")
    except json.JSONDecodeError:
        return None, "the findings file is not JSON"
    if not isinstance(data, list):
        return None, "the findings file is not a list"
    return data, None


def main(argv: Optional[list] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--findings", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--prowler-version", default=None)
    a = ap.parse_args(argv)
    findings, problem = load_findings(a.findings)
    sha = os.environ.get("GITHUB_SHA") or None
    run_ref = f"{os.environ.get('GITHUB_WORKFLOW', 'compliance-aws')} #{os.environ.get('GITHUB_RUN_NUMBER', '0')}"
    out = {"format": FORMAT, "source": SOURCE, "collector": "AA-CIS-Infra compliance-aws (Prowler)",
           "collector_version": sha if sha and re.fullmatch(r"[0-9a-f]{7,40}", sha) else None,
           "run_ref": run_ref[:120],
           "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
           "checks": rows(findings, a.prowler_version, problem)}
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(out, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"checks": len(out["checks"]), "statuses": sorted(c["status"] for c in out["checks"])}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
