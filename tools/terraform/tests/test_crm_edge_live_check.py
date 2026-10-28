"""Tests of tools/terraform/crm_edge_live_check.py (AA-933, AA-935). Offline, stdlib + pytest.

Since AA-935 the partner host's default rule forwards to the CRM web target group; the first test keeps crm_edge.tf
and the live check in step.
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
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

    def fake(host, path, headers=None):
        calls.append(path)
        return 301, b"", "text/plain", f"https://portal.lumiguides.it.com{path}"

    monkeypatch.setattr(chk, "get", fake)
    assert chk.main(["--cf-domain", "x.cloudfront.net", "--only", "partner-root,partner-path"]) == 0
    assert calls == ["/", "/crmx?x=1"]
    assert "PASS  partner-root" in capsys.readouterr().out


def test_partner_host_moved_to_the_agency_host():
    ok = chk.moved_to("portal.example", "/crmx?x=1")
    assert ok(301, b"", "text/plain", "https://portal.example/crmx?x=1")[0]
    assert not ok(301, b"", "text/plain", "https://portal.example/crmx")[0]  # the query was dropped
    assert not ok(302, b"", "text/plain", "https://portal.example/crmx?x=1")[0]
    assert not ok(307, b"", "text/plain", "https://partner-dev.example/auth/refresh?next=%2F")[0]  # the web: no 301
    assert not ok(503, b"<html>503</html>", "text/html")[0]


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


def test_agency_cname_points_at_its_distribution_after_the_clean_up():
    """AA-979 §4.5: no cutover switch and no Vercel target left; TTL back to 300."""
    record = AGENCY_TF.split('resource "aws_route53_record" "crm_agency" {', 1)[1].split("\nresource ", 1)[0]
    assert 'type    = "CNAME"' in record
    assert "records = [aws_cloudfront_distribution.crm_agency[0].domain_name]" in record
    assert "ttl     = 300" in record
    for gone in ("crm_agency_live", "crm_agency_vercel_target", "crm_agency_dns_ttl", "vercel-dns"):
        assert gone not in AGENCY_TF, gone
    tfvars = (REPO / "accounts" / "aa365" / "terraform.tfvars").read_text(encoding="utf-8")
    assert not re.search(r"^crm_agency_live\s*=", tfvars, re.M)
    assert 'from = aws_route53_record.vercel_frontend["portal"]' in AGENCY_TF
    # The certificate is the wildcard (CAA of the Vercel CNAME target does not allow Amazon before the flip).
    assert "domain_name       = local.crm_agency_wildcard" in AGENCY_TF


def test_studio_page_pass_and_fail():
    assert chk.eval_studio_page(200, b"<html>Sign in</html>", "text/html; charset=utf-8")[0]
    assert chk.eval_studio_page(503, b"<html>503</html>", "text/html")[0]
    assert not chk.eval_studio_page(404, b"<html>not found</html>", "text/html")[0]
    assert not chk.eval_studio_page(307, b"", "text/plain", "/auth/refresh")[0]
    assert not chk.eval_studio_page(503, b'{"status":"not_ready"}', "application/json")[0]


def test_studio_sign_in_gone():
    ok = chk.studio_sign_in_gone("portal.example")
    assert ok(308, b"", "text/plain", "https://portal.example/auth/refresh?next=%2Fportal%2Fdashboard")[0]
    assert ok(503, b"<html>503</html>", "text/html")[0]
    assert not ok(200, b"<html>Sign in</html>", "text/html")[0]  # the API-key page is still served: flag still on
    assert not ok(307, b"", "text/plain", "https://portal.example/auth/refresh?next=%2Fportal%2Fdashboard")[0]
    assert not ok(308, b"", "text/plain", "https://portal.example/auth/refresh?next=%2Ftenant-login")[0]  # a loop


def test_agency_checks_only_with_the_flag():
    ns = chk.argparse.Namespace(host="h", client_host="c", cf_domain="cf", api_host="a", booking_host="b",
                                agency_host="portal.example", agency_cf_domain="", agency_direct=False)
    assert not any(k.startswith("agency-") for k in chk.build_checks(ns))
    ns.agency_cf_domain = "d111.cloudfront.net"
    assert {"agency-root", "agency-healthz", "agency-studio", "agency-legal", "agency-crm", "agency-raw-cf"} <= set(
        chk.build_checks(ns)
    )


# ── AA-979 clean-up: the partner host's CloudFront Function (301 to the agency host except /crm, /crm/*) ────────────

FUNCTION_JS = REPO / "accounts" / "aa365" / "cloudfront_functions" / "crm_partner_to_agency.js"


def test_partner_distribution_runs_the_function_on_viewer_request():
    fn = EDGE_TF.split('resource "aws_cloudfront_function" "crm_partner_to_agency"', 1)[1].split("\nresource ", 1)[0]
    assert 'runtime = "cloudfront-js-2.0"' in fn and "publish = true" in fn
    assert 'agency_origin = "https://${local.crm_agency_host}"' in fn
    dist = EDGE_TF.split('resource "aws_cloudfront_distribution" "crm_partner"', 1)[1].split("\nresource ", 1)[0]
    default = dist.split("default_cache_behavior {", 1)[1].split("\n  }\n", 1)[0]
    assert 'event_type   = "viewer-request"' in default
    assert "aws_cloudfront_function.crm_partner_to_agency[0].arn" in default
    # The template has exactly one placeholder (templatefile would read any other ${...} as Terraform).
    assert re.findall(r"\$\{[^}]*\}", FUNCTION_JS.read_text(encoding="utf-8")) == ["${agency_origin}"]


def _run_function(event: dict) -> dict:
    code = FUNCTION_JS.read_text(encoding="utf-8").replace("${agency_origin}", "https://portal.example")
    script = code + "\nprocess.stdout.write(JSON.stringify(handler(" + json.dumps(event) + ")));\n"
    out = subprocess.run(["node", "-e", script], capture_output=True, text=True, timeout=30, check=True)  # noqa: S603,S607
    return json.loads(out.stdout)


def _event(uri: str, qs: dict | None = None) -> dict:
    return {"request": {"method": "GET", "uri": uri, "querystring": qs or {}, "headers": {}, "cookies": {}}}


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
@pytest.mark.parametrize(
    "uri,qs,location",
    [
        ("/", {}, "https://portal.example/"),
        ("/pipeline", {}, "https://portal.example/pipeline"),
        ("/crmx", {"x": {"value": "1"}}, "https://portal.example/crmx?x=1"),
        ("/auth/refresh", {"next": {"value": "%2Fpipeline"}}, "https://portal.example/auth/refresh?next=%2Fpipeline"),
        (
            "/a",
            {"t": {"value": "1", "multiValue": [{"value": "1"}, {"value": "2"}]}, "flag": {"value": ""}},
            "https://portal.example/a?t=1&t=2&flag",
        ),
    ],
)
def test_function_moves_every_other_path_with_its_query(uri, qs, location):
    res = _run_function(_event(uri, qs))
    assert res["statusCode"] == 301
    assert res["headers"]["location"]["value"] == location


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
@pytest.mark.parametrize("uri", ["/crm", "/crm/", "/crm/health", "/crm/v1/agency/x"])
def test_function_leaves_the_crm_api_paths_alone(uri):
    res = _run_function(_event(uri, {"x": {"value": "1"}}))
    assert res.get("uri") == uri and "statusCode" not in res
