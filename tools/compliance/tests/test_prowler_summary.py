"""Tests of tools/compliance/prowler_summary.py (AA-1173): counts by status and severity, framework totals, errors.

Invented findings only. Run: python3 -m pytest -p no:cacheprovider -q tools/compliance/tests
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("prowler_summary", HERE.parent / "prowler_summary.py")
ps = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ps)


def _finding(status: str, severity: str, frameworks=("Framework-A",)) -> dict:
    return {"status_code": status, "severity": severity,
            "unmapped": {"compliance": {f: ["1.1"] for f in frameworks}}}


FINDINGS = [
    _finding("PASS", "low"),
    _finding("FAIL", "Critical"),
    _finding("FAIL", "high", ("Framework-A", "Framework-B")),
    _finding("FAIL", "medium"),
    _finding("MANUAL", "low"),
    _finding("FAIL", "unknown-level"),
    "not a finding",
]


def test_summarize_counts_status_severity_and_frameworks():
    s = ps.summarize(FINDINGS)
    assert (s["findings"], s["pass"], s["fail"], s["manual"]) == (6, 1, 4, 1)
    assert s["critical_high"] == 2
    assert s["fail_by_severity"]["informational"] == 1
    assert s["frameworks"] == {"Framework-A": {"pass": 1, "fail": 4}, "Framework-B": {"pass": 0, "fail": 1}}


def test_framework_names_with_odd_characters_are_dropped():
    s = ps.summarize([_finding("PASS", "low", ("ok-name", "bad<script>"))])
    assert list(s["frameworks"]) == ["ok-name"]


def test_rows_carry_the_critical_high_fact():
    rows = ps.rows(FINDINGS, "9.9.9")
    by_id = {r["check_id"]: r for r in rows}
    assert by_id["prowler_scan_recent"]["status"] == "pass"
    assert by_id["prowler_scan_recent"]["detail"]["prowler_version"] == "9.9.9"
    assert by_id["prowler_critical_high"]["detail"]["critical_high"] == 2


def test_no_findings_file_gives_two_error_rows(tmp_path):
    findings, problem = ps.load_findings(tmp_path / "missing.json")
    rows = ps.rows(findings, None, problem)
    assert [r["status"] for r in rows] == ["error", "error"]
    assert rows[0]["summary"] == "the scan produced no findings file"


def test_empty_scan_is_an_error_not_a_pass():
    assert {r["status"] for r in ps.rows([], None)} == {"error"}


def test_main_writes_a_format_1_bundle(tmp_path, capsys):
    f = tmp_path / "prowler.ocsf.json"
    f.write_text(json.dumps(FINDINGS), encoding="utf-8")
    out = tmp_path / "bundle.json"
    assert ps.main(["--findings", str(f), "--out", str(out), "--prowler-version", "9.9.9"]) == 0
    b = json.loads(out.read_text(encoding="utf-8"))
    assert (b["format"], b["source"]) == (1, "prowler_weekly")
    assert [c["check_id"] for c in b["checks"]] == ["prowler_scan_recent", "prowler_critical_high"]
    assert json.loads(capsys.readouterr().out) == {"checks": 2, "statuses": ["pass", "pass"]}


def test_not_json_is_an_error(tmp_path):
    f = tmp_path / "prowler.ocsf.json"
    f.write_text("{oops", encoding="utf-8")
    assert ps.load_findings(f) == (None, "the findings file is not JSON")
