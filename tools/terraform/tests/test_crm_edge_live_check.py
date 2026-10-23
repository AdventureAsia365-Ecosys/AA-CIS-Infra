"""Tests of tools/terraform/crm_edge_live_check.py (AA-933). Offline, stdlib + pytest.

The partner host's default 404 body lives in two places (crm_edge.tf message_body and the live check); the first test
keeps them in step.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import crm_edge_live_check as chk  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
EDGE_TF = (REPO / "accounts" / "aa365" / "crm_edge.tf").read_text(encoding="utf-8")
BODY = json.dumps(chk.PARTNER_404).encode()


def _default_rule() -> str:
    return EDGE_TF.split('resource "aws_lb_listener_rule" "crm_partner_default"', 1)[1].split("\nresource ", 1)[0]


def test_terraform_default_rule_matches_live_check():
    rule = _default_rule()
    assert re.search(r'type\s*=\s*"fixed-response"', rule)
    assert re.search(r'status_code\s*=\s*"404"', rule)
    assert re.search(r'content_type\s*=\s*"application/json"', rule)
    body = re.search(r"message_body\s*=\s*jsonencode\((\{.*?\})\)", rule).group(1)
    pairs = dict(re.findall(r'(\w+)\s*=\s*"([^"]*)"', body))
    assert pairs == chk.PARTNER_404


def test_no_spike_left_in_edge():
    assert "crm_spike" not in EDGE_TF.replace("aws_lb_listener_rule.crm_spike_partner", "")
    assert not (REPO / "accounts" / "aa365" / "assets" / "crm_spike").exists()


def test_partner_default_pass_and_fail():
    assert chk.eval_partner_default(404, BODY, "application/json")[0]
    assert chk.eval_partner_default(404, BODY, "application/json; charset=utf-8")[0]
    assert not chk.eval_partner_default(403, b"Forbidden\n", "text/plain")[0]
    assert not chk.eval_partner_default(404, b'{"detail":"Not Found"}', "text/plain")[0]
    assert not chk.eval_partner_default(200, b"<html>", "text/html")[0]


@pytest.mark.parametrize(
    "status,body,ok",
    [(200, b'{"status":"ok"}', True), (503, b"<html>503</html>", True), (404, BODY, False), (403, b"Forbidden", False)],
)
def test_crm_health(status, body, ok):
    ctype = "application/json" if body.startswith(b"{") else "text/html"
    assert chk.eval_crm_health(status, body, ctype)[0] is ok


def test_raw_cf_needs_the_deny_403():
    assert chk.eval_raw_cf(403, b"Forbidden\n", "text/plain")[0]
    assert not chk.eval_raw_cf(404, BODY, "application/json")[0]
    assert not chk.eval_raw_cf(200, b"{}", "application/json")[0]


def test_api_header_never_the_partner_404():
    assert chk.eval_api_header(403, b"Forbidden\n", "text/plain")[0]
    assert chk.eval_api_header(200, b'{"status":"ok"}', "application/json")[0]
    assert not chk.eval_api_header(404, BODY, "application/json")[0]


def test_only_filter_runs_selected(monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(chk, "get", lambda host, path, headers=None: (calls.append(path), (404, BODY, "application/json"))[1])
    assert chk.main(["--cf-domain", "x.cloudfront.net", "--only", "partner-root,partner-path"]) == 0
    assert calls == ["/", "/crmx"]
    assert "PASS  partner-root" in capsys.readouterr().out
