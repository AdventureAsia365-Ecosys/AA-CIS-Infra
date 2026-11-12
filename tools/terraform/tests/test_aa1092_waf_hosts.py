"""AA-1092 (S278 system audit M24): offline guards for the web ACL coverage of the public hosts.

1. The shared REGIONAL web ACL is on the CIS and Booking REST API stages (terraform.tfvars turns
   waf_protect_rest_api_stages on), where WAF sees the real client IP.
2. RateLimit1000 scopes out our own NAT egress (an IP set built from the NAT instance EIP, /32 only), so the
   server-to-server calls (CRM, staff web -> api-cis / api-booking) are not counted as one client; it still scopes out
   the staff hosts (AA-911).
3. GeoBlockNonAllowed scopes out the public API hosts (api-cis under both names, api-booking) and still blocks
   every other host outside the allowed countries.
4. Every Cognito pool with a domain (WORKFORCE, EXTERNAL, PARTNER, M2M) is associated with the identity web ACL.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1092_waf_hosts.py
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
WAF = (ROOT / "modules" / "waf" / "main.tf").read_text(encoding="utf-8")
WAF_VARS = (ROOT / "modules" / "waf" / "variables.tf").read_text(encoding="utf-8")
MAIN = (AA365 / "main.tf").read_text(encoding="utf-8")
TFVARS = (AA365 / "terraform.tfvars").read_text(encoding="utf-8")
IDENTITY = (AA365 / "identity.tf").read_text(encoding="utf-8")
IDENTITY_M2M = (AA365 / "identity_m2m.tf").read_text(encoding="utf-8")
IDENTITY_PARTNER = (AA365 / "identity_partner.tf").read_text(encoding="utf-8")


def _block(text: str, header: str, start: int | None = None) -> str:
    start = text.index(header) if start is None else start
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i: j + 1]
    raise AssertionError(f"unbalanced block after {header}")


def _rule(name: str) -> str:
    m = re.search(rf'name\s*=\s*"{name}"', WAF)
    assert m, name
    return _block(WAF, "", WAF.rfind("rule {", 0, m.start()))


class RestStages(unittest.TestCase):
    def test_turned_on_in_tfvars(self) -> None:
        self.assertRegex(TFVARS, r"(?m)^waf_protect_rest_api_stages\s*=\s*true\s*$")

    def test_both_stages_listed(self) -> None:
        stages = _block(MAIN, "rest_api_stage_arns = var.waf_protect_rest_api_stages ?")
        self.assertIn("cis     = module.api_gateway.stage_arn", stages)
        self.assertIn("booking = module.environment.booking_stage_arn", stages)


class RateExemption(unittest.TestCase):
    def test_root_passes_the_nat_eip_only(self) -> None:
        self.assertIn('rate_limit_exempt_cidrs = ["${module.vpc.nat_instance_eip}/32"]', MAIN)

    def test_variable_accepts_single_addresses_only(self) -> None:
        var = _block(WAF_VARS, 'variable "rate_limit_exempt_cidrs"')
        self.assertIn('endswith(c, "/32")', var)

    def test_ip_set_is_conditional_and_regional(self) -> None:
        ipset = _block(WAF, 'resource "aws_wafv2_ip_set" "internal_egress"')
        self.assertIn("count = local.rate_exempt_on ? 1 : 0", ipset)
        self.assertIn('scope              = "REGIONAL"', ipset)
        self.assertIn("addresses          = var.rate_limit_exempt_cidrs", ipset)

    def test_rate_rule_has_exactly_one_scope_down_shape_per_case(self) -> None:
        rule = _rule("RateLimit1000")
        conds = re.findall(r'dynamic "scope_down_statement" \{\s*for_each = ([^\n]+)', rule)
        self.assertEqual(conds, [
            "local.staff_host_regex != null && !local.rate_exempt_on ? [1] : []",
            "local.staff_host_regex == null && local.rate_exempt_on ? [1] : []",
            "local.staff_host_regex != null && local.rate_exempt_on ? [1] : []",
        ])
        self.assertEqual(rule.count("aws_wafv2_ip_set.internal_egress[0].arn"), 2)
        self.assertEqual(rule.count("regex_string = local.staff_host_regex"), 2)


class GeoExemption(unittest.TestCase):
    def test_root_lists_the_api_hosts(self) -> None:
        self.assertIn(
            'geo_exempt_hosts        = ["api-cis.${var.dns_zone_name}", var.domain_name, local.cd_booking_api_host]',
            MAIN)

    def test_geo_rule_keeps_the_country_list_and_scopes_out_the_hosts(self) -> None:
        rule = _rule("GeoBlockNonAllowed")
        self.assertEqual(rule.count("country_codes = var.geo_allowed_countries"), 2)
        self.assertIn('for_each = local.geo_exempt_regex == null ? [1] : []', rule)
        self.assertIn('for_each = local.geo_exempt_regex != null ? [1] : []', rule)
        self.assertIn("regex_string = local.geo_exempt_regex", rule)
        self.assertIn('type     = "LOWERCASE"', rule)

    def test_geo_regex_is_anchored(self) -> None:
        self.assertIn('"^(${join("|", [for h in var.geo_exempt_hosts : replace(lower(h), ".", "\\\\.")])})(:443)?$"', WAF)


class CognitoPools(unittest.TestCase):
    def test_every_pool_with_a_domain_is_on_the_identity_acl(self) -> None:
        pools_with_domain = set(re.findall(
            r'resource "aws_cognito_user_pool_domain" "\w+" \{[^}]*?user_pool_id\s*=\s*aws_cognito_user_pool\.(\w+)\.id',
            IDENTITY + IDENTITY_M2M + IDENTITY_PARTNER, re.S))
        self.assertEqual(pools_with_domain, {"workforce", "external", "m2m", "partner"})
        self.assertIn("workforce = aws_cognito_user_pool.workforce.arn", IDENTITY)
        self.assertIn("external  = aws_cognito_user_pool.external.arn", IDENTITY)
        self.assertIn("resource_arn = aws_cognito_user_pool.partner.arn", IDENTITY_PARTNER)
        m2m = _block(IDENTITY_M2M, 'resource "aws_wafv2_web_acl_association" "identity_m2m"')
        self.assertIn("resource_arn = aws_cognito_user_pool.m2m.arn", m2m)
        self.assertIn("web_acl_arn  = aws_wafv2_web_acl.identity[0].arn", m2m)


if __name__ == "__main__":
    unittest.main()
