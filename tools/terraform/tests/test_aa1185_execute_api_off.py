"""AA-1185 (S296; S295 security audit SA-55): offline guards for the default execute-api endpoints switch-off and the
us-east-1 AWS Health forward.

1. One root variable (api_default_endpoints_disabled, default true) switches off the default endpoint of the CIS and
   Booking REST APIs and the TripPlanner HTTP API; Booking and TripPlanner follow only while their custom domains exist.
2. A REST API applies the setting only when its stage is updated: the flag is part of both deployment trigger hashes.
   The TripPlanner $default stage auto-deploys, which applies it without a redeployment.
3. No caller Terraform configures reaches an API through a default endpoint: every *_API_URL / *_REVALIDATE_URL env value
   is a custom domain, and the base URL outputs give the custom domain while the endpoint is off.
4. Global and us-east-1 AWS Health events reach the root region through the existing us-east-1 forward, and the live
   check tool covers both rules.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1185_execute_api_off.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "terraform"))

import sec_alert_check as chk  # noqa: E402

AA365 = ROOT / "accounts" / "aa365"
MODULES = ROOT / "modules"
CD_VARS = (AA365 / "custom_domains_variables.tf").read_text(encoding="utf-8")
ENV_CALL = (AA365 / "environment.tf").read_text(encoding="utf-8")
MAIN = (AA365 / "main.tf").read_text(encoding="utf-8")
CIS_API = (MODULES / "api_gateway" / "main.tf").read_text(encoding="utf-8")
BOOKING = (MODULES / "environment" / "booking.tf").read_text(encoding="utf-8")
TRIPPLANNER = (MODULES / "environment" / "tripplanner.tf").read_text(encoding="utf-8")
BASELINE = (AA365 / "security_baseline.tf").read_text(encoding="utf-8")
DEFAULTS = (AA365 / "security_account_defaults.tf").read_text(encoding="utf-8")
DEFAULT_HOST = re.compile(r"(?:(?<![\w-])[a-z0-9]{10}|\})\.execute-api\.")


def _block(text: str, opener: str) -> str:
    m = re.search(rf"^{re.escape(opener)} \{{", text, re.M)
    assert m, f"{opener} not found"
    body = text[m.end():]
    return body[: re.search(r"^\}", body, re.M).start()]


def _code(text: str) -> str:
    """The text without comment lines and trailing comments (enough for these files: no '#' inside the strings read)."""
    return "\n".join(ln.split(" #")[0] for ln in text.splitlines() if not ln.lstrip().startswith("#"))


def test_one_root_switch_defaults_to_off_and_reaches_all_three_apis():
    var = _block(CD_VARS, 'variable "api_default_endpoints_disabled"')
    assert "type        = bool" in var
    assert "default     = true" in var
    module = _block(MAIN, 'module "api_gateway"')
    assert "disable_execute_api_endpoint = var.api_default_endpoints_disabled" in module
    env = _block(ENV_CALL, 'module "environment"')
    assert re.search(
        r"^\s+execute_api_endpoint_disabled = var\.api_default_endpoints_disabled && var\.custom_domains_enabled",
        env, re.M,
    ), "Booking and TripPlanner have no other way in without their custom domains"


def test_each_api_carries_the_setting():
    cis = _block(CIS_API, 'resource "aws_api_gateway_rest_api" "this"')
    assert "disable_execute_api_endpoint = var.disable_execute_api_endpoint" in cis
    bk = _block(BOOKING, 'resource "aws_api_gateway_rest_api" "booking"')
    assert "disable_execute_api_endpoint = var.execute_api_endpoint_disabled" in bk
    tp = _block(TRIPPLANNER, 'resource "aws_apigatewayv2_api" "tripplanner"')
    assert "disable_execute_api_endpoint = var.execute_api_endpoint_disabled" in tp


def test_rest_stages_redeploy_when_the_setting_changes():
    # API Gateway applies the setting to a REST API only when a stage is updated (the AA-432 frozen-snapshot trap).
    cis = _block(CIS_API, 'resource "aws_api_gateway_deployment" "this"')
    assert "tostring(aws_api_gateway_rest_api.this.disable_execute_api_endpoint)," in cis.split("redeployment", 1)[1]
    bk = _block(BOOKING, 'resource "aws_api_gateway_deployment" "booking"')
    assert "aws_api_gateway_rest_api.booking.disable_execute_api_endpoint," in bk.split("redeployment", 1)[1]
    for text, kind, name in ((CIS_API, "aws_api_gateway_deployment", "this"),
                             (BOOKING, "aws_api_gateway_deployment", "booking")):
        assert "create_before_destroy = true" in _block(text, f'resource "{kind}" "{name}"')


def test_http_stage_auto_deploys():
    stage = _block(TRIPPLANNER, 'resource "aws_apigatewayv2_stage" "tripplanner"')
    assert "auto_deploy = true" in stage, "without auto-deploy the HTTP API needs a redeployment for the setting"


def test_base_url_outputs_give_the_custom_domain_while_the_endpoint_is_off():
    bk = _block(BOOKING, 'output "booking_api_base_url"')
    assert ('var.execute_api_endpoint_disabled ? "https://api-booking.${var.dns_zone_name}" : '
            "aws_api_gateway_stage.booking.invoke_url") in bk
    tp = _block(TRIPPLANNER, 'output "tripplanner_api_base_url"')
    assert ('var.execute_api_endpoint_disabled ? "https://api-tripplanner.${var.dns_zone_name}" : '
            "aws_apigatewayv2_stage.tripplanner.invoke_url") in tp


def test_no_configured_caller_uses_a_default_endpoint():
    tf_files = sorted([*AA365.glob("*.tf"), *MODULES.rglob("*.tf")])
    assert tf_files
    for path in tf_files:
        code = _code(path.read_text(encoding="utf-8"))
        rel = path.relative_to(ROOT).as_posix()
        # A default endpoint host: a 10-character API id or an interpolated id. A custom domain's regional target
        # (d-<id>.execute-api..., dns.tf) is not one.
        if rel != "modules/api_gateway/outputs.tf":  # the unused api_gateway_url output names the default URL
            assert not DEFAULT_HOST.search(code), (rel, DEFAULT_HOST.search(code).group(0))
        # invoke_url only as the fallback of the two base URL outputs above.
        for m in re.finditer(r"\.invoke_url\b", code):
            line = code[: m.start()].rsplit("\n", 1)[-1]
            assert "var.execute_api_endpoint_disabled ?" in line, f"{rel}: {line.strip()}"
        # Every API URL a task or function gets is a custom domain (or a variable that defaults to one).
        for name, value in re.findall(r'\{ name = "([A-Z_]*(?:API_URL|REVALIDATE_URL))", value = ([^}]+?) \}', code):
            assert value.startswith(('"https://api-', '"https://tripplanner.', "var.crm_", "var.tripplanner_")), (
                rel, name, value)


def test_crm_url_variables_default_to_the_custom_domains():
    crm_vars = (AA365 / "crm_variables.tf").read_text(encoding="utf-8")
    assert 'default     = "https://api-cis.lumiguides.it.com"' in _block(crm_vars, 'variable "crm_cis_api_url"')
    assert 'default     = "https://api-booking.lumiguides.it.com"' in _block(crm_vars, 'variable "crm_booking_api_url"')


def test_global_health_events_are_forwarded_from_us_east_1():
    fwd = _block(BASELINE, 'resource "aws_cloudwatch_event_rule" "sec_global_forward"')
    assert "provider    = aws.us_east_1" in fwd
    assert '{ source = ["aws.health"], "detail-type" = ["AWS Health Event"] },' in fwd
    target = _block(BASELINE, 'resource "aws_cloudwatch_event_target" "sec_global_forward"')
    assert "role_arn  = aws_iam_role.sec_forwarder.arn" in target
    # The root-region rule takes the forwarded events too: no region or account filter in its pattern.
    health = _block(DEFAULTS, 'resource "aws_cloudwatch_event_rule" "sec_aws_health"')
    pattern = health.split("event_pattern = jsonencode(", 1)[1]
    assert not re.search(r"\b(region|account)\s*=", pattern), pattern
    assert "provider" not in health


def test_live_check_covers_health_local_and_forwarded():
    cases = {c[0]: c for c in chk.cases("000000000000", "us-west-1", "dev")}
    assert cases["health.us-east-1.scheduledChange"][1:3] == ("aa-sec-dev-aws-health", "us-west-1")
    assert cases["health.us-west-1.issue"][4] is True
    assert cases["health.us-east-1.investigation"][4] is False
    fwd = cases["forward.health.issue-global"]
    assert fwd[1:3] == ("aa-sec-dev-global-forward", "us-east-1") and fwd[4] is True
    assert fwd[3]["source"] == "aws.health" and fwd[3]["region"] == "us-east-1"
