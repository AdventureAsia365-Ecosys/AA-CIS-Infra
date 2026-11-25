"""Static tests: the responses the edge answers itself carry the apps' security headers (AA-1111, S284 ZAP baseline).

What they hold:
  - every block action of the WAF web ACL (modules/waf) answers a custom response carrying
    local.security_response_headers (HSTS without preload, nosniff, a deny-all CSP with frame-ancestors, the apps'
    Permissions-Policy); no bare `block {}` is left (ZAP counted the WAF 403s of the staff hosts and the API stages as
    the apps' own pages);
  - S294: the managed AWSManagedRulesCommonRuleSet blocks too (NoUserAgent_HEADER answered ZAP's first requests with
    the ALB's bare 403): every documented sub-rule has a rule_action_override, COUNT for
    var.managed_rule_count_overrides as before, else BLOCK with the 403, the "blocked" text body and the headers; the
    custom response headers of the whole ACL stay within the AWS quota (precondition + the Dev count here);
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


# The apps' Permissions-Policy (AA-CIS-App frontend/lib/securityHeaders.ts, the same value in the other apps).
PERMISSIONS_POLICY = "camera=(), microphone=(), geolocation=(), payment=(), usb=()"

# AWSManagedRulesCommonRuleSet, default version Version_1.23 (describe-managed-rule-group, read 25/11/2026; the AWS
# developer guide lists the same 22). A new AWS version with another sub-rule: add it here and in modules/waf.
CRS_RULES = [
    "NoUserAgent_HEADER",
    "UserAgent_BadBots_HEADER",
    "SizeRestrictions_QUERYSTRING",
    "SizeRestrictions_Cookie_HEADER",
    "SizeRestrictions_BODY",
    "SizeRestrictions_URIPATH",
    "EC2MetaDataSSRF_BODY",
    "EC2MetaDataSSRF_COOKIE",
    "EC2MetaDataSSRF_URIPATH",
    "EC2MetaDataSSRF_QUERYARGUMENTS",
    "GenericLFI_QUERYARGUMENTS",
    "GenericLFI_URIPATH",
    "GenericLFI_BODY",
    "RestrictedExtensions_URIPATH",
    "RestrictedExtensions_QUERYARGUMENTS",
    "GenericRFI_QUERYARGUMENTS",
    "GenericRFI_BODY",
    "GenericRFI_URIPATH",
    "CrossSiteScripting_COOKIE",
    "CrossSiteScripting_QUERYARGUMENTS",
    "CrossSiteScripting_BODY",
    "CrossSiteScripting_URIPATH",
]
# The count overrides of the module default (enforced since AA-806; the aa365 root passes no other list).
COUNT_OVERRIDES = ["SizeRestrictions_BODY", "CrossSiteScripting_BODY", "GenericLFI_BODY"]
# AWS WAF default quota: custom response headers per web ACL.
HEADER_QUOTA = 100


def _header_set(waf: str) -> dict[str, str]:
    block = _block_after(waf, waf.index("security_response_headers = {"))
    return dict(re.findall(r'"([A-Za-z-]+)"\s*=\s*"([^"]*)"', block))


def test_waf_header_set():
    headers = _header_set(_code(_read(WAF)))
    assert headers == {
        "Strict-Transport-Security": HSTS,
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
        "Permissions-Policy": PERMISSIONS_POLICY,
    }
    assert "preload" not in headers["Strict-Transport-Security"]


def _blocks(waf: str) -> list[str]:
    """Every block action: static `block {` and the content of `dynamic "block" {`."""
    out = [_block_after(waf, m.start()) for m in re.finditer(r"\bblock\s*\{", waf)]
    for m in re.finditer(r'dynamic\s+"block"\s*\{', waf):
        dyn = _block_after(waf, m.start())
        out.append(_block_after(dyn, dyn.index("content {")))
    return out


def test_every_waf_block_answers_with_the_headers():
    waf = _code(_read(WAF))
    assert not re.search(r"block\s*\{\s*\}", waf), "a bare block {} answers without the security headers"
    blocks = _blocks(waf)
    # TripPlanner x2, RateLimit1000, GeoBlockNonAllowed, StaffWebRateLimit, CloudFrontViewerRateLimit, the managed group.
    assert len(blocks) >= 7
    for body in blocks:
        assert "custom_response {" in body
        assert 'dynamic "response_header"' in body and "for_each = local.security_response_headers" in body
        code = re.search(r"response_code\s*=\s*(\d+)", body)
        assert code, body
        key = re.search(r'custom_response_body_key\s*=\s*"([a-z_]+)"', body)
        assert key, "every block answers a static body"
        if code.group(1) == "403":
            assert key.group(1) == "blocked"
        else:
            assert (code.group(1), key.group(1)) == ("429", "rate_limited")


def test_blocked_body_is_static_text():
    waf = _code(_read(WAF))
    i = waf.index('key          = "blocked"')
    body = waf[waf.rindex("custom_response_body {", 0, i) :]
    body = _block_after(body, 0)
    assert 'content_type = "TEXT_PLAIN"' in body
    content = re.search(r'content\s*=\s*"([^"]*)"', body).group(1)
    assert len(content) <= 64 and not re.search(r"\d", content), "tiny, no version or product text"
    # Not behind a for_each: the 403s exist on every ACL of this module.
    assert not waf[: waf.index("custom_response_body {")].rstrip().endswith('dynamic "custom_response_body" {')


def test_common_rule_set_rule_list():
    waf = _code(_read(WAF))
    block = waf[waf.index("common_rule_set_rules = [") :]
    block = block[: block.index("]") + 1]
    assert re.findall(r'"([A-Za-z0-9_]+)"', block) == CRS_RULES
    assert "common_rule_set_overrides = distinct(concat(local.common_rule_set_rules, var.managed_rule_count_overrides))" in waf
    assert (
        "common_rule_set_blocks    = [for r in local.common_rule_set_overrides : r if "
        "!contains(var.managed_rule_count_overrides, r)]"
    ) in waf
    variables = _read(os.path.join(REPO_ROOT, "modules", "waf", "variables.tf"))
    default = _block_after(variables, variables.index('variable "managed_rule_count_overrides"'))
    assert re.findall(r'"([A-Za-z_]+)"', default[default.index("default") :]) == COUNT_OVERRIDES


def test_every_managed_sub_rule_is_count_or_a_block_with_the_headers():
    """The group keeps its decisions: the same names in COUNT, every other sub-rule BLOCK (its own action)."""
    waf = _code(_read(WAF))
    name = waf.index('name     = "AWSManagedRulesCommonRuleSet"')
    rule = _block_after(waf, waf.rindex("rule {", 0, name))
    override = _block_after(rule, rule.index('dynamic "rule_action_override"'))
    assert "for_each = local.common_rule_set_overrides" in override
    assert "for_each = contains(var.managed_rule_count_overrides, rule_action_override.value) ? [1] : []" in override
    assert "for_each = contains(var.managed_rule_count_overrides, rule_action_override.value) ? [] : [1]" in override
    assert rule.count('dynamic "rule_action_override"') == 1, "one override per sub-rule, no duplicate names"
    block = _block_after(override, override.index('dynamic "block"'))
    assert "response_code            = 403" in block
    assert 'custom_response_body_key = "blocked"' in block
    assert "for_each = local.security_response_headers" in block
    # The group-level switch is untouched: count_only still turns the whole group into COUNT.
    assert 'dynamic "count" {\n        for_each = var.common_rules_count_only ? [1] : []' in rule


def test_custom_response_headers_fit_the_quota():
    waf = _code(_read(WAF))
    lifecycle = _block_after(waf, waf.index("precondition {"))
    assert "local.custom_response_header_count <= var.custom_response_header_quota" in lifecycle
    variables = _read(os.path.join(REPO_ROOT, "modules", "waf", "variables.tf"))
    quota = _block_after(variables, variables.index('variable "custom_response_header_quota"'))
    assert f"default     = {HEADER_QUOTA}" in quota
    # The Dev ACL: 19 managed blocks + TripPlanner x2 + CloudFrontViewerRateLimit (enforced) + RateLimit1000 +
    # GeoBlockNonAllowed + StaffWebRateLimit = 25 responses, each with every header of the set.
    managed_blocks = len([r for r in CRS_RULES if r not in COUNT_OVERRIDES])
    responses = managed_blocks + 2 + 1 + 2 + 1
    assert responses * len(_header_set(waf)) <= HEADER_QUOTA


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


def _waf_filtered_checks(text: str, resource: str, api_ref: str) -> None:
    """S294: WAF_FILTERED gets its own gateway response with no header parameters, so the WAF's block answer (which
    already carries the security headers) is not given HSTS and nosniff a second time by DEFAULT_4XX."""
    code = _code(text)
    res = _block_after(code, code.index(f'resource "aws_api_gateway_gateway_response" "{resource}_waf_filtered"'))
    assert 'response_type      = "WAF_FILTERED"' in res
    assert f"rest_api_id        = {api_ref}" in res
    assert "response_parameters" not in res, "the WAF's own headers are the only ones"
    deployment = _block_after(code, code.index('resource "aws_api_gateway_deployment"'))
    assert f"aws_api_gateway_gateway_response.{resource}_waf_filtered," in deployment, "depends_on"
    assert f"aws_api_gateway_gateway_response.{resource}_waf_filtered.response_templates" in deployment, "hash"


def test_cis_waf_filtered_has_no_second_header_set():
    _waf_filtered_checks(_read(CIS_API), "security_headers", "aws_api_gateway_rest_api.this.id")


def test_booking_waf_filtered_has_no_second_header_set():
    _waf_filtered_checks(_read(BOOKING), "booking_security_headers", "aws_api_gateway_rest_api.booking.id")
