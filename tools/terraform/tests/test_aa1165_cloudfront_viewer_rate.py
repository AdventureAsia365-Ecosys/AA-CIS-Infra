"""AA-1165 (S286 decision D10): offline guards for the per-viewer rate rule of the CloudFront path.

1. modules/waf rule CloudFrontViewerRateLimit: before both allow rules (priority from the map), keyed on the viewer
   header (FORWARDED_IP, fallback MATCH), scoped to the exact origin secret, NOT TripPlanner (site header, or the Host
   before AA-1090) and NOT our NAT egress read from the same viewer header; COUNT or BLOCK 429 with the JSON body and
   the security headers; created only with the input and the origin secret.
2. The root passes it while the CRM edge is on, the limit and the mode come from named variables (never literals),
   terraform.tfvars holds the COUNT window, and output platform_limits publishes both.
3. Every non-TripPlanner distribution that carries the origin secret writes the rate key on every behaviour (a
   distribution without it would put all its viewers in the one fallback bucket), and the agency and client function
   overwrites a viewer-supplied value.

Offline: reads the .tf files; no Terraform, no AWS. Run from the repo root:
    python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1165_cloudfront_viewer_rate.py
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
WAF = (ROOT / "modules" / "waf" / "main.tf").read_text(encoding="utf-8")
WAF_VARS = (ROOT / "modules" / "waf" / "variables.tf").read_text(encoding="utf-8")
WAF_OUT = (ROOT / "modules" / "waf" / "outputs.tf").read_text(encoding="utf-8")
MAIN = (AA365 / "main.tf").read_text(encoding="utf-8")
CRM_EDGE = (AA365 / "crm_edge.tf").read_text(encoding="utf-8")
TFVARS = (AA365 / "terraform.tfvars").read_text(encoding="utf-8")
LIMITS = (AA365 / "outputs_platform_limits.tf").read_text(encoding="utf-8")
VIEWER_IP_JS = AA365 / "cloudfront_functions" / "tripplanner_web_viewer_ip.js"
TP_DISTRIBUTIONS = {"tripplanner_web", "tripplanner_agency"}  # limited by the TripPlanner rules (AA-1038)


def _block_after(text: str, start: int) -> str:
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


def _code(block: str) -> str:
    return "\n".join(line.split("#", 1)[0].rstrip() for line in block.splitlines())


def _rule() -> str:
    acl = _code(_block_after(WAF, WAF.index('resource "aws_wafv2_web_acl" "main"')))
    i = acl.index('name     = "CloudFrontViewerRateLimit"')
    return _block_after(acl, acl.rfind('dynamic "rule"', 0, i))


# --- 1. the rule ----------------------------------------------------------------------------------------------------


def test_rule_exists_only_with_the_input_and_the_origin_secret():
    assert (
        "cfv_on           = var.cloudfront_viewer_rate != null && nonsensitive(var.origin_verify_header != null)"
        in WAF
    )
    assert "for_each = local.cfv_on ? [1] : []" in _rule()
    var = _block_after(WAF_VARS, WAF_VARS.index('variable "cloudfront_viewer_rate"'))
    assert "default = null" in var
    for field in ("viewer_ip_header = string", "limit            = number", "count_only       = bool"):
        assert field in var, field


def test_rule_runs_before_both_allow_rules():
    block = re.search(r"rule_priorities = \{(.*?)\n  \}", WAF, re.S).group(1)
    pr = {k: int(v) for k, v in re.findall(r"^\s*(\w+)\s*=\s*(\d+)", block, re.M)}
    assert pr["tp_challenge_planner"] < pr["cloudfront_viewer_rate"] < pr["vpc_link_internal_allow"]
    assert pr["cloudfront_viewer_rate"] < pr["cloudfront_origin_allow"]
    assert "priority = local.rule_priorities.cloudfront_viewer_rate" in _rule()


def test_rule_keys_on_the_viewer_header_with_fallback_match():
    rule = _rule()
    assert "limit              = local.cfv.limit" in rule
    assert 'aggregate_key_type = "FORWARDED_IP"' in rule
    fwd = _block_after(rule, rule.index("forwarded_ip_config {"))
    assert "header_name       = local.cfv.viewer_ip_header" in fwd
    assert 'fallback_behavior = "MATCH"' in fwd


def test_scope_is_the_origin_secret_and_not_tripplanner_and_not_our_egress():
    rule = _rule()
    shapes = re.findall(r'dynamic "scope_down_statement" \{\s*for_each = ([^\n]+)', rule)
    assert shapes == ["local.cfv_scoped_apart ? [] : [1]", "local.cfv_scoped_apart ? [1] : []"]
    assert "cfv_scoped_apart = local.tp_on || local.rate_exempt_on" in WAF
    # The origin secret in both shapes, EXACTLY, no transformation.
    assert rule.count("search_string         = var.origin_verify_header.value") == 2
    assert rule.count("name = lower(var.origin_verify_header.name)") == 2
    conds = re.findall(r'dynamic "statement" \{\s*for_each = ([^\n]+)', rule)
    assert conds == [
        "local.tp_site_on ? [1] : []",
        "local.tp_on && !local.tp_site_on ? [1] : []",
        "local.rate_exempt_on ? [1] : []",
    ]
    assert rule.count("not_statement {") == 3
    assert "search_string         = var.tripplanner_site_header.value" in rule
    assert "regex_string = local.tp_host_regex" in rule
    egress = _block_after(rule, rule.index("ip_set_reference_statement {"))
    assert "arn = aws_wafv2_ip_set.internal_egress[0].arn" in egress
    # Our egress is read from the viewer header (the source address is CloudFront's), first address, absent = no match.
    assert "header_name       = local.cfv.viewer_ip_header" in egress
    assert 'fallback_behavior = "NO_MATCH"' in egress
    assert 'position          = "FIRST"' in egress


def test_action_is_count_or_a_429_with_the_body_and_the_security_headers():
    rule = _rule()
    action = _block_after(rule, rule.index("action {"))
    assert 'dynamic "count" {\n          for_each = local.cfv.count_only ? [1] : []' in action
    assert 'dynamic "block" {\n          for_each = local.cfv.count_only ? [] : [1]' in action
    assert "response_code            = 429" in action
    assert 'custom_response_body_key = "rate_limited"' in action
    assert "for_each = local.security_response_headers" in action
    body = _block_after(WAF, WAF.index('dynamic "custom_response_body"'))
    assert "for_each = local.tp_on || local.cfv_on ? [1] : []" in body
    assert 'key          = "rate_limited"' in body


def test_rule_has_its_own_metric_and_output():
    rule = _rule()
    assert 'metric_name                = "CloudFrontViewerRateLimit"' in rule
    assert "cloudwatch_metrics_enabled = true" in rule and "sampled_requests_enabled   = true" in rule
    out = _block_after(WAF_OUT, WAF_OUT.index('output "cloudfront_viewer_rate_rule_name"'))
    assert 'value       = local.cfv_on ? "CloudFrontViewerRateLimit" : ""' in out


# --- 2. the root ----------------------------------------------------------------------------------------------------


def test_root_passes_the_rule_while_the_crm_edge_is_on():
    waf = _code(_block_after(MAIN, MAIN.index('module "waf" {')))
    cfv = _block_after(waf, waf.index("cloudfront_viewer_rate = local.crm_edge_on == 1 ?"))
    assert "viewer_ip_header = local.crm_viewer_ip_header" in cfv
    assert "limit            = var.crm_edge_rate_limit" in cfv
    assert "count_only       = var.crm_edge_rate_count_only" in cfv
    assert re.search(r"\}\s*:\s*null", waf[waf.index("cloudfront_viewer_rate = ") :])


def test_limit_and_mode_are_named_variables():
    limit = _block_after(CRM_EDGE, CRM_EDGE.index('variable "crm_edge_rate_limit"'))
    assert "default     = 5000" in limit
    assert "floor(var.crm_edge_rate_limit) == var.crm_edge_rate_limit && var.crm_edge_rate_limit >= 100" in limit
    mode = _block_after(CRM_EDGE, CRM_EDGE.index('variable "crm_edge_rate_count_only"'))
    assert "default     = false" in mode  # the steady state blocks; tfvars holds the COUNT window
    assert "crm_viewer_ip_header = local.tp_web_viewer_ip_header" in CRM_EDGE


def test_tfvars_mode_is_a_plain_boolean():
    lines = re.findall(r"(?m)^crm_edge_rate_count_only\s*=\s*(\S+)\s*$", TFVARS)
    assert len(lines) <= 1 and all(v in ("true", "false") for v in lines)
    assert not re.search(r"(?m)^crm_edge_rate_limit\s*=", TFVARS) or re.search(
        r"(?m)^crm_edge_rate_limit\s*=\s*\d+\s*$", TFVARS
    )


def test_platform_limits_publishes_the_limit_and_the_mode():
    out = _code(_block_after(LIMITS, LIMITS.index('output "platform_limits"')))
    assert re.search(r"^\s*crm_edge_rate_limit_per_5min_per_viewer\s*=\s*var\.crm_edge_rate_limit$", out, re.M)
    assert re.search(r"^\s*crm_edge_rate_count_only\s*=\s*var\.crm_edge_rate_count_only$", out, re.M)


# --- 3. the rate key on every CloudFront-path distribution ----------------------------------------------------------


def _distributions() -> dict[str, str]:
    found: dict[str, str] = {}
    for path in sorted(AA365.glob("*.tf")):
        text = _code(path.read_text(encoding="utf-8"))
        for m in re.finditer(r'resource "aws_cloudfront_distribution" "(\w+)"', text):
            found[m.group(1)] = _block_after(text, m.start())
    return found


def _behaviours(dist: str) -> list[str]:
    return [_block_after(dist, m.start()) for m in re.finditer(r"\b(default|ordered)_cache_behavior \{", dist)]


def test_every_crm_path_distribution_writes_the_rate_key_on_every_behaviour():
    secret_dists = {
        name: body
        for name, body in _distributions().items()
        if "value = random_password.crm_origin_verify[0].result" in body
    }
    crm = {name: body for name, body in secret_dists.items() if name not in TP_DISTRIBUTIONS}
    assert set(crm) == {"crm_partner", "crm_agency", "crm_client"}, sorted(secret_dists)
    writers = {
        "crm_partner": "aws_cloudfront_function.crm_partner_to_agency[0].arn",
        "crm_agency": "aws_cloudfront_function.crm_viewer_ip[0].arn",
        "crm_client": "aws_cloudfront_function.crm_viewer_ip[0].arn",
    }
    for name, body in crm.items():
        behaviours = _behaviours(body)
        assert behaviours, name
        for b in behaviours:
            assert 'event_type   = "viewer-request"' in b, name
            assert f"function_arn = {writers[name]}" in b, name


def test_crm_viewer_ip_function_uses_the_shared_header_code():
    fn = _code(_block_after(CRM_EDGE, CRM_EDGE.index('resource "aws_cloudfront_function" "crm_viewer_ip"')))
    assert "count = local.crm_edge_on" in fn
    assert 'runtime = "cloudfront-js-2.0"' in fn and "publish = true" in fn
    assert "tripplanner_web_viewer_ip.js" in fn
    assert "header_name = local.crm_viewer_ip_header" in fn


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_crm_viewer_ip_function_overwrites_a_viewer_supplied_value():
    js = VIEWER_IP_JS.read_text(encoding="utf-8").replace("${header_name}", "x-aa-viewer-ip")
    event = {
        "viewer": {"ip": "2001:db8::7"},
        "request": {"uri": "/pipeline", "headers": {"x-aa-viewer-ip": {"value": "203.0.113.9"}}},
    }
    script = js + f"\nprocess.stdout.write(JSON.stringify(handler({json.dumps(event)})));\n"
    out = subprocess.run(  # noqa: S603
        [shutil.which("node"), "-e", script], check=True, capture_output=True, text=True, timeout=30
    )
    res = json.loads(out.stdout)
    assert res["headers"]["x-aa-viewer-ip"] == {"value": "2001:db8::7"}
    assert res["uri"] == "/pipeline"
