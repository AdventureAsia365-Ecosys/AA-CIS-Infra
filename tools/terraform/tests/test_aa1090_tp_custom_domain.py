"""AA-1090 TripPlanner R8 (root ADR 0019 b4; tech lead S278 D10 / D13 NEW-D): offline guards for an agency's own domain.

1. The CIS task role's policy (modules/ecs/policies/tripplanner_custom_domain.json.tftpl, rendered here with test values
   and parsed as JSON) is least privilege: RequestCertificate / AddTagsToCertificate only in us-east-1, only DNS
   validation, only with the job's tag; Describe / DeleteCertificate only on certificates with that tag (plus Describe
   of the base certificate); Get / UpdateDistribution on the TripPlanner distribution only; nothing else (no "*"
   action, no wildcard resource but the request statement, no IAM, no other service, Delete never on the base).
2. modules/ecs: the policy and the env (TP_WEB_DISTRIBUTION_ID, TP_WEB_BASE_CERT_ARN on the api AND the worker) exist
   only when both inputs are set; the tag equals the one AA-CIS-App services/tenant_account/tp_edge.py writes.
3. The edge (accounts/aa365/tripplanner_web_edge.tf): the distribution adds the site header (a random secret, origin
   custom header), ignores aliases and viewer_certificate (the job owns them), and the ALB alias rule forwards on the
   site header + the origin secret, with its priority from the map (alb_rules.tf), below the deny rule.
4. The WAF: the three TripPlanner rules match the site header when it is set (else the Host as before); the header is
   sensitive and redacted from the log; accounts/aa365/main.tf wires the header, the distribution and the base
   certificate.

Offline: reads files; no Terraform, no AWS. Run from the repo root:
    python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1090_tp_custom_domain.py
"""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
POLICY_TPL = (ROOT / "modules" / "ecs" / "policies" / "tripplanner_custom_domain.json.tftpl").read_text(encoding="utf-8")
ECS = (ROOT / "modules" / "ecs" / "main.tf").read_text(encoding="utf-8")
ECS_VARS = (ROOT / "modules" / "ecs" / "variables.tf").read_text(encoding="utf-8")
EDGE = (AA365 / "tripplanner_web_edge.tf").read_text(encoding="utf-8")
RULES = (AA365 / "alb_rules.tf").read_text(encoding="utf-8")
MAIN = (AA365 / "main.tf").read_text(encoding="utf-8")
WAF = (ROOT / "modules" / "waf" / "main.tf").read_text(encoding="utf-8")
WAF_VARS = (ROOT / "modules" / "waf" / "variables.tf").read_text(encoding="utf-8")

ACCOUNT = "000000000000"
BASE = f"arn:aws:acm:us-east-1:{ACCOUNT}:certificate/00000000-0000-4000-8000-0000000000b0"
DIST = f"arn:aws:cloudfront::{ACCOUNT}:distribution/EDISTTEST1090"
# AA-CIS-App services/tenant_account/tp_edge.py TAG_KEY / TAG_VALUE (the job tags every certificate it requests).
TAG_KEY, TAG_VALUE = "aa-managed-by", "tripplanner-custom-domain"


def _render() -> dict:
    values = {"account_id": ACCOUNT, "base_cert_arn": BASE, "distribution_arn": DIST, "tag_key": TAG_KEY,
              "tag_value": TAG_VALUE}
    slots = set(re.findall(r"\$\{(\w+)\}", POLICY_TPL))
    assert slots == set(values), f"template slots changed: {slots}"
    text = re.sub(r"\$\{(\w+)\}", lambda m: values[m.group(1)], POLICY_TPL)
    return json.loads(text)


def _block_after(text: str, start: int) -> str:
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        depth += {"{": 1, "}": -1}.get(text[j], 0)
        if depth == 0:
            return text[i : j + 1]
    raise AssertionError("unbalanced braces")


def _resource(text: str, kind: str, name: str) -> str:
    m = re.search(rf'^resource "{kind}" "{name}" \{{', text, re.M)
    assert m, f"{kind}.{name} not found"
    return _block_after(text, m.start())


def _code(block: str) -> str:
    return "\n".join(line for line in block.splitlines() if not line.strip().startswith("#"))


# --- 1. the policy ---------------------------------------------------------------------------------------------------

def test_policy_has_exactly_the_four_statements():
    doc = _render()
    assert doc["Version"] == "2012-10-17"
    sids = [s["Sid"] for s in doc["Statement"]]
    assert sids == ["RequestTaggedDnsCertificatesInUsEast1", "ReadAndDeleteOwnCertificates", "ReadTheBaseCertificate",
                    "AttachAliasesToTheTripPlannerDistribution"]
    assert all(s["Effect"] == "Allow" for s in doc["Statement"])


def test_no_wildcard_action_no_other_service():
    actions = [a for s in _render()["Statement"] for a in s["Action"]]
    assert all("*" not in a for a in actions)
    assert {a.split(":")[0] for a in actions} == {"acm", "cloudfront"}
    assert set(actions) == {"acm:RequestCertificate", "acm:AddTagsToCertificate", "acm:DescribeCertificate",
                            "acm:DeleteCertificate", "cloudfront:GetDistribution", "cloudfront:UpdateDistribution"}


def test_request_only_in_us_east_1_with_dns_and_the_tag():
    st = _render()["Statement"][0]
    assert st["Resource"] == "*"           # ACM has no certificate ARN before the request
    assert st["Condition"] == {"StringEquals": {"aws:RequestedRegion": "us-east-1",
                                                f"aws:RequestTag/{TAG_KEY}": TAG_VALUE,
                                                "acm:ValidationMethod": "DNS"}}


def test_describe_and_delete_only_own_tagged_certificates():
    st = _render()["Statement"][1]
    assert st["Resource"] == f"arn:aws:acm:us-east-1:{ACCOUNT}:certificate/*"
    assert st["Condition"] == {"StringEquals": {f"aws:ResourceTag/{TAG_KEY}": TAG_VALUE}}


def test_the_base_certificate_is_read_only_and_cloudfront_is_one_distribution():
    doc = _render()
    base = doc["Statement"][2]
    assert base["Action"] == ["acm:DescribeCertificate"] and base["Resource"] == BASE
    for st in doc["Statement"]:
        if "acm:DeleteCertificate" in st["Action"]:
            assert st["Resource"] != BASE and "Condition" in st
    cf = doc["Statement"][3]
    assert cf["Resource"] == DIST and "Condition" not in cf
    assert [s for s in doc["Statement"] if s["Resource"] == "*"] == [doc["Statement"][0]]


# --- 2. modules/ecs --------------------------------------------------------------------------------------------------

def test_policy_and_env_only_when_both_inputs_are_set():
    assert 'tp_custom_domain_on = var.tripplanner_web_distribution_arn != "" && var.tripplanner_web_base_cert_arn != ""' \
        in ECS
    pol = _code(_resource(ECS, "aws_iam_role_policy", "ecs_task_tripplanner_custom_domain"))
    assert "count = local.tp_custom_domain_on ? 1 : 0" in pol
    assert "policies/tripplanner_custom_domain.json.tftpl" in pol and "role = aws_iam_role.ecs_task.id" in pol
    assert 'TP_WEB_DISTRIBUTION_ID' in ECS and 'TP_WEB_BASE_CERT_ARN' in ECS
    assert ECS.count("local.tp_custom_domain_env,") == 2      # the api AND the worker task definitions
    assert f'tp_custom_domain_tag = {{ key = "{TAG_KEY}", value = "{TAG_VALUE}" }}' in ECS
    assert 'variable "tripplanner_web_distribution_arn"' in ECS_VARS
    assert 'regex("^arn:aws:acm:us-east-1:[0-9]{12}:certificate/"' in ECS_VARS


def test_the_tag_matches_the_cis_job_when_the_app_repo_is_next_door():
    app = ROOT.parent.parent / "apps" / "AA-CIS-App" / "services" / "tenant_account" / "tp_edge.py"
    if not app.exists():   # the Infra repo alone (CI): the constants above are the pinned copy
        return
    src = app.read_text(encoding="utf-8")
    assert f'TAG_KEY = "{TAG_KEY}"' in src and f'TAG_VALUE = "{TAG_VALUE}"' in src


# --- 3. the edge -----------------------------------------------------------------------------------------------------

def test_distribution_adds_the_site_header_and_leaves_aliases_to_the_job():
    dist = _code(_resource(EDGE, "aws_cloudfront_distribution", "tripplanner_web"))
    assert "name  = local.tp_web_site_header_name" in dist
    assert "value = random_password.tp_web_site_marker[0].result" in dist
    assert re.search(r"ignore_changes\s*=\s*\[aliases, viewer_certificate\]", dist)
    assert 'tp_web_site_header_name = "x-aa-tp-site"' in EDGE
    marker = _code(_resource(EDGE, "random_password", "tp_web_site_marker"))
    assert "special = false" in marker and re.search(r"length\s*=\s*(\d+)", marker).group(1) >= "32"


def test_alias_rule_forwards_on_the_site_header_and_the_origin_secret():
    rule = _code(_resource(EDGE, "aws_lb_listener_rule", "tripplanner_web_alias"))
    assert "priority     = local.alb_http_rule_priorities.tripplanner_web_alias" in rule
    assert "http_header_name = local.tp_web_site_header_name" in rule
    assert "values           = [random_password.tp_web_site_marker[0].result]" in rule
    assert "http_header_name = local.alb_origin_header_name" in rule
    assert "host_header" not in rule and 'type             = "forward"' in rule
    prio = dict(re.findall(r"^\s+(\w+)\s+= (\d+)", RULES, re.M))
    assert int(prio["tripplanner_web"]) < int(prio["tripplanner_web_alias"]) < int(prio["crm_origin_deny"])
    # the host rule of the public host stays
    assert "values = [local.tp_web_host]" in _code(_resource(EDGE, "aws_lb_listener_rule", "tripplanner_web"))


# --- 4. the WAF and the wiring ---------------------------------------------------------------------------------------

def test_waf_rules_match_the_site_header_when_set():
    assert WAF.count("for_each = local.tp_site_on ? [1] : []") == 3
    assert WAF.count("for_each = local.tp_site_on ? [] : [1]") == 3
    assert WAF.count("search_string         = var.tripplanner_site_header.value") == 3
    assert "tp_site_on = local.tp_on && nonsensitive(var.tripplanner_site_header != null)" in WAF
    var = WAF_VARS[WAF_VARS.index('variable "tripplanner_site_header"'):]
    assert "sensitive = true" in var[: var.index("\n}\n")]
    assert '"x-aa-tp-site"' in WAF_VARS


def test_root_wires_the_header_the_distribution_and_the_base_certificate():
    assert "tripplanner_site_header = local.tp_web_edge_on == 1 ? {" in MAIN
    assert "value = random_password.tp_web_site_marker[0].result" in MAIN
    assert ("tripplanner_web_distribution_arn = local.tp_web_edge_on == 1 ? "
            "aws_cloudfront_distribution.tripplanner_web[0].arn") in MAIN
    assert ("tripplanner_web_base_cert_arn    = local.tp_web_edge_on == 1 ? "
            "aws_acm_certificate_validation.crm_agency[0].certificate_arn") in MAIN
