"""Static tests: the responses the edge answers itself carry the apps' security headers (AA-1111, S284 ZAP baseline).

What they hold:
  - every block action of the WAF web ACL (modules/waf) answers a custom response carrying
    local.security_response_headers (HSTS without preload, nosniff, X-Frame-Options, a deny-all CSP); no bare
    `block {}` is left (ZAP counted the WAF 403s of the staff hosts and the API stages as the apps' own pages);
  - both REST APIs (CIS modules/api_gateway, Booking modules/environment/booking.tf) set DEFAULT_4XX and DEFAULT_5XX
    gateway responses with HSTS + nosniff and the default JSON message, and both deployments hash them and depend on
    them (a stage serves a frozen snapshot: the AA-432 trap).

Offline: reads the .tf files; no Terraform, no AWS. Run from the repo root:
python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1111_security_headers.py
"""
from __future__ import annotations

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
WAF = os.path.join(REPO_ROOT, "modules", "waf", "main.tf")
CIS_API = os.path.join(REPO_ROOT, "modules", "api_gateway", "main.tf")
BOOKING = os.path.join(REPO_ROOT, "modules", "environment", "booking.tf")

HSTS = "max-age=63072000; includeSubDomains"


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def _code(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if not line.strip().startswith("#"))


def _block_after(text: str, start: int) -> str:
    """Text of the brace-balanced block whose opening brace is the first one at or after ``start``."""
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i : j + 1]
    raise AssertionError("unbalanced braces")


def test_waf_header_set():
    waf = _code(_read(WAF))
    headers = _block_after(waf, waf.index("security_response_headers = {"))
    assert f'"Strict-Transport-Security" = "{HSTS}"' in headers
    assert "preload" not in headers
    assert '"X-Content-Type-Options"    = "nosniff"' in headers
    assert '"X-Frame-Options"           = "DENY"' in headers
    assert "\"Content-Security-Policy\"   = \"frame-ancestors 'none'; default-src 'none'\"" in headers


def test_every_waf_block_answers_with_the_headers():
    waf = _code(_read(WAF))
    assert not re.search(r"block\s*\{\s*\}", waf), "a bare block {} answers without the security headers"
    blocks = [m.start() for m in re.finditer(r"\bblock\s*\{", waf)]
    assert len(blocks) >= 5, "TripPlanner x2, RateLimit1000, GeoBlockNonAllowed, StaffWebRateLimit"
    for start in blocks:
        body = _block_after(waf, start)
        assert "custom_response {" in body
        assert 'dynamic "response_header"' in body and "for_each = local.security_response_headers" in body


def _gateway_checks(text: str, resource: str, api_ref: str, locals_prefix: str) -> None:
    code = _code(text)
    res = _block_after(code, code.index(f'resource "aws_api_gateway_gateway_response" "{resource}"'))
    assert 'for_each = toset(["DEFAULT_4XX", "DEFAULT_5XX"])' in res
    assert f"rest_api_id         = {api_ref}" in res
    assert f"response_parameters = local.{locals_prefix}gateway_security_headers" in res
    assert f"response_templates  = local.{locals_prefix}gateway_default_message" in res
    params = _block_after(code, code.index(f"{locals_prefix}gateway_security_headers = {{"))
    assert f"\"gatewayresponse.header.Strict-Transport-Security\" = \"'{HSTS}'\"" in params
    assert "\"gatewayresponse.header.X-Content-Type-Options\"    = \"'nosniff'\"" in params
    assert '"{\\"message\\":$context.error.messageString}"' in code, "the default JSON message body"
    deployment = _block_after(code, code.index('resource "aws_api_gateway_deployment"'))
    assert f"aws_api_gateway_gateway_response.{resource}," in deployment, "depends_on"
    assert f"aws_api_gateway_gateway_response.{resource} : k => [r.response_parameters, r.response_templates]" in (
        deployment
    ), "the redeployment hash"


def test_cis_api_gateway_responses():
    _gateway_checks(_read(CIS_API), "security_headers", "aws_api_gateway_rest_api.this.id", "")


def test_booking_api_gateway_responses():
    _gateway_checks(_read(BOOKING), "booking_security_headers", "aws_api_gateway_rest_api.booking.id", "bk_")
