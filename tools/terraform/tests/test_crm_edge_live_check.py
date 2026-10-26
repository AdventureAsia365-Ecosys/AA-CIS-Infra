"""Tests of tools/terraform/crm_edge_live_check.py (AA-933, AA-935). Offline, stdlib + pytest.

Since AA-935 the partner host's default rule forwards to the CRM web target group; the first test keeps crm_edge.tf
and the live check in step.
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


def test_terraform_default_rule_forwards_to_the_web():
    rule = _default_rule()
    assert re.search(r'type\s*=\s*"forward"', rule)
    assert re.search(r"target_group_arn\s*=\s*aws_lb_target_group\.crm_web\.arn", rule)
    assert "fixed-response" not in rule


def test_no_spike_left_in_edge():
    assert "crm_spike" not in EDGE_TF.replace("aws_lb_listener_rule.crm_spike_partner", "")
    assert not (REPO / "accounts" / "aa365" / "assets" / "crm_spike").exists()


def test_web_default_pass_and_fail():
    refresh = "https://partner-dev.lumiguides.it.com/auth/refresh?next=%2F"
    assert chk.eval_web_default(307, b"", "text/plain", refresh)[0]
    assert chk.eval_web_default(503, b"<html>503 Service Temporarily Unavailable</html>", "text/html")[0]
    assert not chk.eval_web_default(404, BODY, "application/json")[0]  # the old fixed default came back
    assert not chk.eval_web_default(503, b'{"status":"not_ready"}', "application/json")[0]  # the API, not the web
    assert not chk.eval_web_default(307, b"", "text/plain", "https://evil.example/")[0]
    assert not chk.eval_web_default(403, b"Forbidden\n", "text/plain")[0]
    assert not chk.eval_web_default(200, b"<html>", "text/html")[0]


def test_web_healthz():
    assert chk.eval_web_healthz(200, b'{"service":"aa-crm-web","git_sha":"abc"}', "application/json")[0]
    assert chk.eval_web_healthz(503, b"<html>503</html>", "text/html")[0]
    assert not chk.eval_web_healthz(200, b'{"service":"aa-crm-api"}', "application/json")[0]
    assert not chk.eval_web_healthz(404, BODY, "application/json")[0]


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
    redirect = (307, b"", "text/plain", "https://partner-dev.lumiguides.it.com/auth/refresh?next=%2F")
    monkeypatch.setattr(chk, "get", lambda host, path, headers=None: (calls.append(path), redirect)[1])
    assert chk.main(["--cf-domain", "x.cloudfront.net", "--only", "partner-root,partner-path"]) == 0
    assert calls == ["/", "/crmx"]
    assert "PASS  partner-root" in capsys.readouterr().out


def test_client_host_checks():
    html = b"<!doctype html><title>404</title>"
    assert chk.eval_client_web_404(404, html, "text/html")[0]
    assert chk.eval_client_web_404(503, b"<html>503</html>", "text/html")[0]
    assert not chk.eval_client_web_404(200, b'{"status": "ok"}', "application/json")[0]  # the API on /crm/health: fail
    assert not chk.eval_client_web_404(404, BODY, "application/json")[0]
    detail = json.dumps({"detail": [{"loc": ["path", "public_key"]}]}).encode()
    assert chk.eval_client_public(422, detail, "application/json")[0]
    assert chk.eval_client_public(503, b"<html>503</html>", "text/html")[0]
    assert not chk.eval_client_public(404, html, "text/html")[0]  # the web answered: the /crm/public/* rule is lost


def test_client_checks_hit_the_client_host(monkeypatch, capsys):
    seen = []
    monkeypatch.setattr(
        chk, "get", lambda host, path, headers=None: (seen.append((host, path)), (404, b"<html/>", "text/html", ""))[1]
    )
    assert chk.main(["--cf-domain", "x.cloudfront.net", "--only", "client-root,client-no-api"]) == 0
    assert seen == [("go-dev.lumiguides.it.com", "/"), ("go-dev.lumiguides.it.com", "/crm/health")]


# ── AA-979: the agency host (portal.) on its own distribution ────────────────────────────────────────────────────────

AGENCY_TF = (REPO / "accounts" / "aa365" / "crm_agency_edge.tf").read_text(encoding="utf-8")


def _agency_rule(name: str) -> str:
    return AGENCY_TF.split(f'resource "aws_lb_listener_rule" "{name}"', 1)[1].split("\nresource ", 1)[0]


def test_agency_rules_forward_to_the_expected_target_groups():
    assert "aws_lb_target_group.crm_api.arn" in _agency_rule("crm_agency_api")
    assert "aws_lb_target_group.crm_portal.arn" in _agency_rule("crm_agency_studio")
    assert "aws_lb_target_group.crm_portal.arn" in _agency_rule("crm_agency_studio_x")
    assert "aws_lb_target_group.crm_web.arn" in _agency_rule("crm_agency_default")
    assert '"/portal*"' in _agency_rule("crm_agency_studio")  # also the /portal-assets/ prefix


def test_agency_cutover_switch_changes_the_dns_target_only():
    record = AGENCY_TF.split('resource "aws_route53_record" "crm_agency" {', 1)[1].split("\nresource ", 1)[0]
    assert 'type    = "CNAME"' in record
    assert "var.crm_agency_live ?" in record
    assert 'from = aws_route53_record.vercel_frontend["portal"]' in AGENCY_TF
    # The certificate is the wildcard (CAA of the Vercel CNAME target does not allow Amazon before the flip).
    assert "domain_name       = local.crm_agency_wildcard" in AGENCY_TF


def test_studio_page_pass_and_fail():
    assert chk.eval_studio_page(200, b"<html>Sign in</html>", "text/html; charset=utf-8")[0]
    assert chk.eval_studio_page(503, b"<html>503</html>", "text/html")[0]
    assert not chk.eval_studio_page(404, b"<html>not found</html>", "text/html")[0]
    assert not chk.eval_studio_page(307, b"", "text/plain", "/auth/refresh")[0]
    assert not chk.eval_studio_page(503, b'{"status":"not_ready"}', "application/json")[0]


def test_agency_checks_only_with_the_flag():
    ns = chk.argparse.Namespace(host="h", client_host="c", cf_domain="cf", api_host="a", booking_host="b",
                                agency_host="portal.example", agency_cf_domain="", agency_direct=False)
    assert not any(k.startswith("agency-") for k in chk.build_checks(ns))
    ns.agency_cf_domain = "d111.cloudfront.net"
    assert {"agency-root", "agency-studio", "agency-legal", "agency-crm", "agency-raw-cf"} <= set(chk.build_checks(ns))
