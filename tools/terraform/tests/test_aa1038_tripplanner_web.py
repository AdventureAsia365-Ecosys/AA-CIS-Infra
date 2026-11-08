"""AA-1038 R5 hosting (root ADR 0019 d23, S265 tech-lead decision): offline guards for the TripPlanner frontend on ECS.

1. The service (modules/environment/tripplanner_web.tf): one Fargate Spot ARM64 task, desired 0 at create with
   desired_count / task_definition ignored, ECS Exec off, no task role, one health path for the container check and
   the target group, a secret shell without a Terraform version, an execution role that reads only its own secrets,
   and the edge-aware app env (TP_EDGE_GATE=on, TP_CLIENT_IP_SOURCE=cloudfront).
2. The TripPlanner deploy role's web grant is scoped to this family, service and execution role.
3. The WAF rules (S272 cost decision: no CLOUDFRONT web ACL of their own, no Bot Control) are three rules in the ALB
   web ACL (modules/waf): the rate rule, the protected-path rate rule and the Challenge, on the same three paths the
   app gates (AA-TripPlanner-Web lib/botCheck.ts: the two model calls and Send to advisor, review S272), each scoped to the TripPlanner host AND the origin secret, after
   CommonRuleSet and before both allow rules; the rate rules key on the viewer address the distribution's
   viewer-request function writes. Every path match URL-decodes and normalizes first, and a protected path matches
   with CONTAINS, so a dot-segment spelling (/api/browse/%2e/search, and a leading /%2e%2e/api/trip/send, which
   NORMALIZE_PATH keeps) is caught too.
4. Caching: pages and /api/* never cached at the edge; only the immutable chunks and the photo proxy are.
5. DNS: the record moved from custom_domains.tf (never destroyed), stays a CNAME on both sides, the switch is off by
   default, the TTL window is on, and the switch needs the edge.
6. The ALB host rule is a CloudFront-path rule (host + origin secret, priority from the map, below the deny rule).
7. The CIS catalog purge follows the switch (TRIPPLANNER_REVALIDATE_URL only when the host points at ECS, never "").
8. The apply role may create the web repository (bootstrap grant in cicd_crm.tf).

Offline: reads the .tf files; no Terraform, no AWS. Run from the repo root:
    python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1038_tripplanner_web.py
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
WEB = (ROOT / "modules" / "environment" / "tripplanner_web.tf").read_text(encoding="utf-8")
EDGE = (AA365 / "tripplanner_web_edge.tf").read_text(encoding="utf-8")
RULES = (AA365 / "alb_rules.tf").read_text(encoding="utf-8")
SGS = (AA365 / "app_security_groups.tf").read_text(encoding="utf-8")
ENV = (AA365 / "environment.tf").read_text(encoding="utf-8")
MAIN = (AA365 / "main.tf").read_text(encoding="utf-8")
CUSTOM = (AA365 / "custom_domains.tf").read_text(encoding="utf-8")
VERCEL_VARS = (AA365 / "custom_domains_variables.tf").read_text(encoding="utf-8")
CICD_CRM = (AA365 / "cicd_crm.tf").read_text(encoding="utf-8")
WAF = (ROOT / "modules" / "waf" / "main.tf").read_text(encoding="utf-8")
WAF_VARS = (ROOT / "modules" / "waf" / "variables.tf").read_text(encoding="utf-8")
VIEWER_IP_JS = AA365 / "cloudfront_functions" / "tripplanner_web_viewer_ip.js"
ECS = (ROOT / "modules" / "ecs" / "main.tf").read_text(encoding="utf-8")
ECS_VARS = (ROOT / "modules" / "ecs" / "variables.tf").read_text(encoding="utf-8")

# AA-TripPlanner-Web frontend/lib/botCheck.ts SEARCH_PATH / NARRATE_PATH / SEND_PATH (lib/edgeGate.test.ts pins the
# same values). Send to advisor stores a traveller's contact for an agency: on ECS these rules are its only bot check
# (review S272), so it is challenged and rate-limited like the two model calls.
PROTECTED_PATHS = ["/api/browse/search", "/api/trip/narrate", "/api/trip/send"]


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


def _resource(text: str, kind: str, name: str) -> str:
    m = re.search(rf'^resource "{kind}" "{name}" \{{', text, re.M)
    assert m, f"{kind}.{name} not found"
    return _block_after(text, m.start())


def _code(block: str) -> str:
    return "\n".join(line for line in block.splitlines() if not line.strip().startswith("#"))


def _rule(acl: str, name: str) -> str:
    i = acl.index(f'name     = "{name}"')
    start = acl.rindex("content {", 0, i)
    return _block_after(acl, start)


# --- 1. the service -------------------------------------------------------------------------------------------------

def test_one_arm64_spot_task_desired_zero_exec_off_no_task_role():
    td = _code(_resource(WEB, "aws_ecs_task_definition", "tripplanner_web"))
    assert 'cpu_architecture        = "ARM64"' in td
    assert 'cpu                      = "512"' in td and 'memory                   = "1024"' in td
    assert "task_role_arn" not in td
    assert ":bootstrap" in td
    svc = _code(_resource(WEB, "aws_ecs_service", "tripplanner_web"))
    assert "desired_count   = 0" in svc
    assert 'capacity_provider = "FARGATE_SPOT"' in svc and "FARGATE\"" not in svc.replace("FARGATE_SPOT", "")
    assert "enable_execute_command = false" in svc
    assert re.search(r"ignore_changes\s*=\s*\[desired_count, task_definition\]", svc)
    assert "var.tripplanner_web_security_group_id" in svc


def test_health_path_is_shared_by_the_container_check_and_the_target_group():
    assert 'tp_web_health    = "/api/health"' in WEB
    assert "${local.tp_web_health}" in _resource(WEB, "aws_ecs_task_definition", "tripplanner_web")
    assert "path                = local.tp_web_health" in _resource(WEB, "aws_lb_target_group", "tripplanner_web")


def test_secret_shell_has_no_terraform_version_and_the_role_reads_only_its_secrets():
    assert 'resource "aws_secretsmanager_secret_version" "tripplanner_web"' not in WEB
    assert 'name                    = "tripplanner/${var.environment}/web"' in _resource(
        WEB, "aws_secretsmanager_secret", "tripplanner_web"
    )
    policy = _code(_resource(WEB, "aws_iam_role_policy", "tripplanner_web_ecs_execution"))
    assert "Resource = local.tp_web_secret_arns" in policy
    arns = re.search(r"tp_web_secret_arns = concat\((.*?)\n  \)", WEB, re.S).group(1)
    assert "aws_secretsmanager_secret.tripplanner_web.arn" in arns
    assert "aws_secretsmanager_secret.tripplanner_api_key.arn" in arns
    assert "tripplanner_db" not in arns and "sentry_dsn.arn" not in arns  # no DSN of the database, no Lambda secret


def test_the_app_env_turns_on_the_edge_gate_and_the_cloudfront_client_address():
    env = re.search(r"tp_web_env = \[(.*?)\n  \]", WEB, re.S).group(1)
    assert '{ name = "TP_EDGE_GATE", value = "on" }' in env
    assert '{ name = "TP_CLIENT_IP_SOURCE", value = "cloudfront" }' in env
    assert 'https://api-tripplanner.${var.dns_zone_name}' in env


def test_the_web_security_group_takes_only_the_app_port_from_the_alb():
    sg = _code(_resource(SGS, "aws_security_group", "tripplanner_web"))
    assert sg.count("ingress {") == 1
    assert "from_port       = module.environment.tripplanner_web_port" in sg
    assert "security_groups = [module.vpc.sg_alb_id]" in sg


# --- 2. the deploy grant --------------------------------------------------------------------------------------------

def test_deploy_grant_is_scoped_to_this_family_service_and_execution_role():
    grant = _code(_resource(WEB, "aws_iam_role_policy", "tripplanner_app_deploy_web"))
    assert "role = aws_iam_role.tripplanner_app_deploy.id" in grant
    assert "Resource = aws_ecr_repository.tripplanner_web.arn" in grant
    assert grant.count("Resource = local.tp_web_task_def_pattern") == 2  # register + tag-on-register
    assert grant.count("Resource = local.tp_web_service_arn") == 2  # describe + update
    assert "Resource = aws_iam_role.tripplanner_web_ecs_execution.arn" in grant
    assert '"iam:PassedToService" = "ecs-tasks.amazonaws.com"' in grant
    assert 'ArnEquals = { "ecs:cluster" = var.ecs_cluster_arn }' in grant


# --- 3. the WAF rules (in the ALB web ACL) -------------------------------------------------------------------------

TP_RULES = ["TripPlannerRateLimitPerIp", "TripPlannerRateLimitModelPaths", "TripPlannerChallengePlanner"]


def _priorities() -> dict[str, int]:
    block = re.search(r"rule_priorities = \{(.*?)\n  \}", WAF, re.S).group(1)
    return {k: int(v) for k, v in re.findall(r"^\s*(\w+)\s*=\s*(\d+)", block, re.M)}


def _acl() -> str:
    return _code(_resource(WAF, "aws_wafv2_web_acl", "main"))


def test_no_cloudfront_web_acl_and_no_integration_url():
    # S272 tech-lead decision: no separate CLOUDFRONT web ACL (5 USD/month fixed), no Bot Control. The JavaScript
    # integration URL exists only for a web ACL with a paid intelligent-threat group, so nothing may depend on it.
    for path in list(AA365.glob("*.tf")) + list((ROOT / "modules").rglob("*.tf")):
        code = _code(path.read_text(encoding="utf-8"))
        assert "application_integration_url" not in code, path
        assert "waf_integration_url" not in code, path
        assert 'scope       = "CLOUDFRONT"' not in code or path.name != "tripplanner_web_edge.tf", path
    assert 'resource "aws_wafv2_web_acl"' not in EDGE
    assert "AWSManagedRulesBotControlRuleSet" not in WAF
    dist = _code(_resource(EDGE, "aws_cloudfront_distribution", "tripplanner_web"))
    assert "web_acl_id" not in dist


def test_tripplanner_rules_run_after_common_rules_and_before_both_allow_rules():
    pr = _priorities()
    assert len(set(pr.values())) == len(pr), "two rules share a priority"
    order = sorted(pr, key=pr.get)
    assert order == [
        "common_rule_set", "tp_rate_per_ip", "tp_rate_model_paths", "tp_challenge_planner",
        "vpc_link_internal_allow", "cloudfront_origin_allow", "rate_limit", "geo_block", "staff_web_rate_limit",
    ]
    acl = _acl()
    for name, key in [
        ("AWSManagedRulesCommonRuleSet", "common_rule_set"),
        ("TripPlannerRateLimitPerIp", "tp_rate_per_ip"),
        ("TripPlannerRateLimitModelPaths", "tp_rate_model_paths"),
        ("TripPlannerChallengePlanner", "tp_challenge_planner"),
        ("VpcLinkInternalAllow", "vpc_link_internal_allow"),
        ("CloudFrontOriginAllow", "cloudfront_origin_allow"),
        ("RateLimit1000", "rate_limit"),
        ("GeoBlockNonAllowed", "geo_block"),
        ("StaffWebRateLimit", "staff_web_rate_limit"),
    ]:
        i = acl.index(f'name     = "{name}"')
        assert acl[i : i + 200].split("\n")[1].strip() == f"priority = local.rule_priorities.{key}", name


def test_rule_priorities_are_never_literals():
    # Only text_transformation priorities (0, 1, ...) may be literals inside the ACL.
    acl = _acl()
    for m in re.finditer(r"^(\s*)priority = (\d+)$", acl, re.M):
        before = acl[: m.start()]
        assert before.rstrip().endswith("text_transformation {"), acl[m.start() - 200 : m.end()]


def test_every_tripplanner_rule_is_scoped_to_the_host_and_the_origin_secret():
    acl = _acl()
    assert "tp_on         = var.tripplanner_web != null && nonsensitive(var.origin_verify_header != null)" in WAF
    assert 'tp_host_regex = local.tp_on ? "^${replace(lower(local.tp.host), ".", "\\\\.")}(:443)?$" : null' in WAF
    for name in TP_RULES:
        rule = _rule(acl, name)
        assert "for_each = local.tp_on ? [1] : []" in acl[acl.rindex('dynamic "rule"', 0, acl.index(f'"{name}"')) :][:80]
        assert "regex_string = local.tp_host_regex" in rule, name
        assert 'name = "host"' in rule and 'type     = "LOWERCASE"' in rule, name
        assert "search_string         = var.origin_verify_header.value" in rule, name
        assert "name = lower(var.origin_verify_header.name)" in rule, name
        # The host and the secret are ANDed with the rest of the rule (never ORed).
        assert rule.index("and_statement {") < rule.index("regex_string = local.tp_host_regex"), name
        assert f'metric_name                = "{name}"' in rule


def test_rate_rules_key_on_the_viewer_address_header_with_the_same_limits():
    acl = _acl()
    rate = _rule(acl, "TripPlannerRateLimitPerIp")
    model = _rule(acl, "TripPlannerRateLimitModelPaths")
    assert "limit              = local.tp.rate_limit" in rate
    assert "limit              = local.tp.model_rate_limit" in model
    for rule in (rate, model):
        assert 'aggregate_key_type = "FORWARDED_IP"' in rule
        assert "header_name       = local.tp.viewer_ip_header" in rule
        assert 'fallback_behavior = "MATCH"' in rule
        assert "response_code            = 429" in rule and 'custom_response_body_key = "rate_limited"' in rule
    assert "for_each = local.tp.protected_paths" in model and "uri_path {}" in model
    # The 429 body exists exactly when the rules do.
    body = _block_after(acl, acl.index('dynamic "custom_response_body"'))
    assert "for_each = local.tp_on ? [1] : []" in body and 'key          = "rate_limited"' in body


def test_challenge_rule_documents_of_the_planner_and_the_protected_paths_with_its_own_token_lifetime():
    challenge = _rule(_acl(), "TripPlannerChallengePlanner")
    assert "challenge {}" in challenge
    assert "immunity_time = local.tp.challenge_immunity_s" in challenge
    assert 'name = "sec-fetch-dest"' in challenge and 'search_string         = "document"' in challenge
    assert 'search_string         = "GET"' in challenge
    # Only planner documents are challenged (the catalog pages never see an interstitial).
    assert 'search_string         = "/plan"' in challenge and 'positional_constraint = "ENDS_WITH"' in challenge
    assert 'search_string         = "/plan/"' in challenge
    assert "for_each = local.tp.protected_paths" in challenge
    # No ACL-wide challenge_config / token domains: the other hosts keep the ACL defaults.
    acl = _acl()
    assert acl.count("challenge_config {") == 1 and "token_domains" not in acl


def test_root_passes_the_edge_settings_to_the_alb_web_acl():
    mod = _block_after(MAIN, MAIN.index('module "waf" {'))
    tp = _block_after(mod, mod.index("tripplanner_web = local.tp_web_edge_on == 1 ? {"))
    for line in [
        "host                 = local.tp_web_host",
        "viewer_ip_header     = local.tp_web_viewer_ip_header",
        "rate_limit           = var.tripplanner_web_rate_limit",
        "model_rate_limit     = var.tripplanner_web_model_rate_limit",
        "challenge_immunity_s = var.tripplanner_web_challenge_immunity_s",
        "protected_paths      = local.tp_web_protected_paths",
        "path_transformations = local.tp_web_path_normalize",
    ]:
        assert line in tp, line
    assert 'variable "tripplanner_web"' in WAF_VARS and "default = null" in WAF_VARS


def test_viewer_request_function_writes_the_viewer_address_on_every_behaviour():
    assert 'tp_web_viewer_ip_header = "x-aa-viewer-ip"' in EDGE
    fn = _code(_resource(EDGE, "aws_cloudfront_function", "tripplanner_web_viewer_ip"))
    assert 'runtime = "cloudfront-js-2.0"' in fn and "publish = true" in fn
    assert "header_name = local.tp_web_viewer_ip_header" in fn
    assert "tripplanner_web_viewer_ip.js" in fn
    dist = _code(_resource(EDGE, "aws_cloudfront_distribution", "tripplanner_web"))
    # Default + the two ordered behaviours: a cache miss of a chunk or a photo reaches the ALB too.
    assert dist.count("function_arn = aws_cloudfront_function.tripplanner_web_viewer_ip[0].arn") == 3
    assert dist.count('event_type   = "viewer-request"') == 3
    js = VIEWER_IP_JS.read_text(encoding="utf-8")
    assert "request.headers[HEADER_NAME] = { value: event.viewer.ip };" in js
    assert js.count("${") == 1  # templatefile: only the header name


def test_viewer_request_function_overwrites_a_viewer_supplied_value():
    import json
    import shutil
    import subprocess

    import pytest

    node = shutil.which("node")
    if not node:
        pytest.skip("node not installed")
    js = VIEWER_IP_JS.read_text(encoding="utf-8").replace("${header_name}", "x-aa-viewer-ip")
    event = {
        "viewer": {"ip": "198.51.100.7"},
        "request": {"uri": "/plan", "headers": {"x-aa-viewer-ip": {"value": "203.0.113.9"}, "host": {"value": "h"}}},
    }
    script = js + f"\nprocess.stdout.write(JSON.stringify(handler({json.dumps(event)})));\n"
    out = json.loads(subprocess.run([node, "-e", script], check=True, capture_output=True, text=True).stdout)
    assert out["headers"]["x-aa-viewer-ip"] == {"value": "198.51.100.7"}
    assert out["headers"]["host"] == {"value": "h"} and out["uri"] == "/plan"


def test_every_path_match_decodes_and_normalizes_before_comparing():
    # CloudFront hands WAF the raw path; Next resolves %2e as a dot segment (WHATWG new URL), so a match with
    # transformation NONE let /api/browse/%2e/search skip the model rate and the Challenge (review S272).
    m = re.search(r"tp_web_path_normalize = \[(.*?)\]", EDGE)
    assert m and re.findall(r'"([^"]+)"', m.group(1)) == ["URL_DECODE", "NORMALIZE_PATH"]
    acl = _acl()
    tp = "".join(_rule(acl, name) for name in TP_RULES)
    uri_matches = [m.start() for m in re.finditer(r"uri_path \{\}", tp)]
    assert len(uri_matches) == 4, "model rate x1, plan document x2, challenge model x1"
    for start in uri_matches:
        stmt = _block_after(tp, tp.rindex("byte_match_statement {", 0, start))
        assert 'dynamic "text_transformation"' in stmt and "for_each = local.tp.path_transformations" in stmt, stmt
        assert "priority = text_transformation.key" in stmt and "type     = text_transformation.value" in stmt
        assert '"NONE"' not in stmt


def _waf_url_decode_then_normalize(path: str) -> str:
    """Local model of URL_DECODE + NORMALIZE_PATH (AWS WAF text transformations).

    AWS: NORMALIZE_PATH removes multiple slashes, directory self-references and directory back-references "that are not
    at the beginning of the input". So a LEADING /./ or /../ (any run of them) is kept as is, unlike WHATWG new URL,
    which drops it: /../api/trip/send stays /../api/trip/send for WAF (review S272)."""
    from urllib.parse import unquote

    segs = re.sub(r"/{2,}", "/", unquote(path)).split("/")[1:]
    lead: list[str] = []
    while segs and segs[0] in (".", "..") and len(segs) > 1:
        lead.append(segs.pop(0))
    out: list[str] = []
    for seg in segs:
        if seg == ".":
            continue
        if seg == "..":
            if out:
                out.pop()
            continue
        out.append(seg)
    return "/" + "/".join(lead + out)


def _waf_protected_match(raw: str) -> bool:
    """Rules 3 and 4: the transformed path CONTAINS a protected path (modules/waf, positional_constraint)."""
    path = _waf_url_decode_then_normalize(raw)
    return any(p in path for p in PROTECTED_PATHS)


# Raw request paths the app (Next 16, WHATWG new URL) routes to a protected path. A leading back-reference survives
# NORMALIZE_PATH, so these are the spellings EXACTLY let through (review S272).
DOT_SPELLINGS = {
    "/api/browse/%2e/search": "/api/browse/search",
    "/api/browse/%2E/search": "/api/browse/search",
    "/api/trip/%2e/narrate": "/api/trip/narrate",
    "/api/trip/./narrate": "/api/trip/narrate",
    "/api/x/../trip/narrate": "/api/trip/narrate",
    "/api/browse/%2e%2e/browse/search": "/api/browse/search",
    "/api/trip/%2e/send": "/api/trip/send",
    "/api/x/../trip/send": "/api/trip/send",
    "/%2e%2e/api/trip/send": "/api/trip/send",
    "/%2E%2E/api/trip/send": "/api/trip/send",
    "/../api/browse/search": "/api/browse/search",
    "/%2e%2e/api/browse/search": "/api/browse/search",
    "/%2e%2e/api/trip/narrate": "/api/trip/narrate",
    "/./api/trip/narrate": "/api/trip/narrate",
    "/%2e/api/trip/send": "/api/trip/send",
    "/../../api/trip/send": "/api/trip/send",
    "/api/trip/send#x": "/api/trip/send",
}


def test_the_waf_model_keeps_a_leading_back_reference_as_aws_documents():
    assert _waf_url_decode_then_normalize("/../api/trip/send") == "/../api/trip/send"
    assert _waf_url_decode_then_normalize("/%2e%2e/api/trip/send") == "/../api/trip/send"
    assert _waf_url_decode_then_normalize("/./api/trip/narrate") == "/./api/trip/narrate"
    assert _waf_url_decode_then_normalize("/api/x/../trip/send") == "/api/trip/send"
    # So an EXACTLY match misses it; the CONTAINS match does not.
    assert _waf_url_decode_then_normalize("/%2e%2e/api/trip/send") not in PROTECTED_PATHS
    assert _waf_protected_match("/%2e%2e/api/trip/send")


def test_every_dot_segment_spelling_the_app_routes_to_a_protected_path_is_matched_by_the_rules():
    for raw, want in DOT_SPELLINGS.items():
        assert want in PROTECTED_PATHS, raw
        assert _waf_protected_match(raw), raw
    # Next answers a doubled slash or a backslash with a 308 to the clean path (base-server), and WAF folds it anyway.
    assert _waf_protected_match("/api//browse/search")
    # Plain neighbours stay out (the catalog and the other BFF calls are never challenged).
    for raw in ["/api/trip", "/api/browse", "/plan", "/api/health", "/api/trip/sen", "/api/browse/searc"]:
        assert not _waf_protected_match(raw), raw


def test_the_waf_match_agrees_with_the_app_whatwg_resolution():
    # Whatever the app resolves to a protected path, the WAF rules match (the WAF may match more, never less).
    import json
    import shutil
    import subprocess

    import pytest

    node = shutil.which("node")
    if not node:
        pytest.skip("node not installed")
    raws = list(DOT_SPELLINGS) + ["/api//browse/search", "/api/trip/send/.", "/api/trip/send%23x", "/api/browse/%73earch", "/x/../plan"]
    script = (
        f"const r = {json.dumps(raws)};"
        "process.stdout.write(JSON.stringify(r.map((p) => new URL(p, 'https://h').pathname)));"
    )
    resolved = json.loads(subprocess.run([node, "-e", script], check=True, capture_output=True, text=True).stdout)
    for raw, app_path in zip(raws, resolved):
        if raw in DOT_SPELLINGS:
            assert app_path == DOT_SPELLINGS[raw], raw
        if app_path in PROTECTED_PATHS:
            assert _waf_protected_match(raw), (raw, app_path)


def test_protected_path_matches_use_contains_never_exactly():
    # EXACTLY missed a leading back-reference (/%2e%2e/api/trip/send), which NORMALIZE_PATH keeps (review S272).
    acl = _acl()
    for name in ("TripPlannerRateLimitModelPaths", "TripPlannerChallengePlanner"):
        rule = _rule(acl, name)
        i = rule.index("for_each = local.tp.protected_paths")
        stmt = _block_after(rule, rule.index("byte_match_statement {", i))
        assert "search_string         = statement.value" in stmt, name
        assert 'positional_constraint = "CONTAINS"' in stmt, name
        assert "EXACTLY" not in stmt, name


def test_protected_paths_are_the_app_paths_send_included():
    m = re.search(r"tp_web_protected_paths = \[(.*?)\]", EDGE)
    assert m and re.findall(r'"([^"]+)"', m.group(1)) == PROTECTED_PATHS
    # The old two-path list is gone, so no rule can be wired to a list without Send to advisor.
    assert "tp_web_model_paths" not in EDGE + MAIN
    assert "local.tp.model_paths" not in WAF
    assert "protected_paths      = list(string)" in WAF_VARS


# --- 4. caching -----------------------------------------------------------------------------------------------------

def _ordered_behaviors(dist: str) -> dict[str, str]:
    out = {}
    for m in re.finditer(r"^\s*ordered_cache_behavior \{", dist, re.M):
        block = _block_after(dist, m.start())
        path = re.search(r"path_pattern\s+= local\.(\w+)", block)
        assert path, block
        out[path.group(1)] = block
    return out


def test_pages_and_api_are_never_cached_only_static_chunks_and_photos_are():
    dist = _code(_resource(EDGE, "aws_cloudfront_distribution", "tripplanner_web"))
    default = _block_after(dist, dist.index("default_cache_behavior"))
    assert "caching_disabled[0].id" in default
    assert "all_viewer_and_cf_headers[0].id" in default  # Host for the ALB rule, CloudFront-Viewer-Address for the app
    assert 'dynamic "ordered_cache_behavior"' not in dist
    behaviors = _ordered_behaviors(dist)
    assert sorted(behaviors) == ["tp_web_photo_path", "tp_web_static_path"]
    assert 'tp_web_static_path = "/_next/static/*"' in EDGE
    assert 'tp_web_photo_path  = "/photo-cdn/*"' in EDGE
    # Content-hashed chunk paths: the managed policy (query not in the key) is right there.
    assert "caching_optimized[0].id" in behaviors["tp_web_static_path"]
    # The photo proxy is versioned by ?v= (AA-TripPlanner-Web lib/photoResolve.ts), never by CachingOptimized.
    photo = behaviors["tp_web_photo_path"]
    assert "aws_cloudfront_cache_policy.tripplanner_web_photos[0].id" in photo
    assert "caching_optimized" not in photo


def test_photo_cache_key_carries_the_version_query():
    policy = _code(_resource(EDGE, "aws_cloudfront_cache_policy", "tripplanner_web_photos"))
    assert "count = local.tp_web_edge_on" in policy
    qs = _block_after(policy, policy.index("query_strings_config"))
    assert 'query_string_behavior = "whitelist"' in qs
    assert re.search(r'items = \["v"\]', qs)
    assert 'cookie_behavior = "none"' in policy and 'header_behavior = "none"' in policy
    assert "enable_accept_encoding_gzip   = true" in policy and "enable_accept_encoding_brotli = true" in policy
    assert "max_ttl     = 31536000" in policy


def test_output_names_the_alb_web_acl_and_its_tripplanner_rules():
    out = _block_after(EDGE, EDGE.index('output "tripplanner_web_edge"'))
    assert "web_acl_name        = module.waf.web_acl_name" in out
    assert "waf_rules           = module.waf.tripplanner_web_rule_names" in out
    outs = (ROOT / "modules" / "waf" / "outputs.tf").read_text(encoding="utf-8")
    for name in TP_RULES:
        assert f'"{name}"' in outs


def test_distribution_reuses_the_shared_origin_secret_and_the_wildcard_certificate():
    dist = _code(_resource(EDGE, "aws_cloudfront_distribution", "tripplanner_web"))
    assert "vpc_origin_id            = aws_cloudfront_vpc_origin.crm[0].id" in dist
    assert "value = random_password.crm_origin_verify[0].result" in dist
    assert "aws_acm_certificate_validation.crm_agency[0].certificate_arn" in dist
    assert "aliases         = [local.tp_web_host]" in dist


# --- 5. DNS ---------------------------------------------------------------------------------------------------------

def test_record_moved_from_custom_domains_never_recreated():
    assert re.search(
        r'moved \{\n\s+from = aws_route53_record\.vercel_frontend\["tripplanner"\]\n\s+to\s+= aws_route53_record\.tripplanner_web\[0\]\n\}',
        EDGE,
    )
    assert not re.search(r'^\s*tripplanner\s*=\s*"', VERCEL_VARS, re.M), "tripplanner left custom_domain_vercel_hosts"


def test_switch_off_by_default_window_on_and_a_cname_on_both_sides():
    switch = _block_after(EDGE, EDGE.index('variable "tripplanner_web_dns_on_cloudfront"'))
    assert "default     = false" in switch
    window = _block_after(EDGE, EDGE.index('variable "tripplanner_web_dns_switch_window"'))
    assert "default     = true" in window
    assert "tp_web_dns_ttl = var.tripplanner_web_dns_switch_window ? 60 : 300" in EDGE
    rec = _code(_resource(EDGE, "aws_route53_record", "tripplanner_web"))
    assert 'type    = "CNAME"' in rec and "ttl     = local.tp_web_dns_ttl" in rec
    assert (
        "records = [var.tripplanner_web_dns_on_cloudfront ? aws_cloudfront_distribution.tripplanner_web[0].domain_name"
        " : var.tripplanner_web_vercel_target]"
    ) in rec
    assert "!var.tripplanner_web_dns_on_cloudfront || local.tp_web_edge_on == 1" in rec


def test_public_host_listed_with_the_frontends():
    assert '["https://${local.tp_web_host}"]' in CUSTOM


# --- 6. the ALB rule ------------------------------------------------------------------------------------------------

def test_alb_rule_is_a_cloudfront_host_rule_below_the_deny_rule():
    m = re.search(r"tripplanner_web\s*=\s*(\d+)", RULES)
    deny = int(re.search(r"crm_origin_deny\s*=\s*(\d+)", RULES).group(1))
    assert m and int(m.group(1)) < deny
    rule = _code(_resource(EDGE, "aws_lb_listener_rule", "tripplanner_web"))
    assert "priority     = local.alb_http_rule_priorities.tripplanner_web" in rule
    assert "listener_arn = module.alb.http_listener_arn" in rule
    assert "values = [local.tp_web_host]" in rule
    assert "http_header_name = local.alb_origin_header_name" in rule
    assert "target_group_arn = module.environment.tripplanner_web_target_group_arn" in rule
    assert "tripplanner_web_listener_rule_gate = aws_lb_listener_rule.tripplanner_web[*].arn" in ENV


# --- 7. the CIS catalog purge ---------------------------------------------------------------------------------------

def test_cis_purge_follows_the_switch_and_is_never_empty():
    assert (
        'tripplanner_revalidate_url = var.tripplanner_web_dns_on_cloudfront ? "https://${local.tp_web_host}/api/revalidate/catalog" : null'
    ) in MAIN
    assert "tripplanner_revalidate_env = var.tripplanner_revalidate_url == null ? [] : [" in ECS
    assert ECS.count("local.tripplanner_revalidate_env,") == 2  # api and worker
    var = _block_after(ECS_VARS, ECS_VARS.index('variable "tripplanner_revalidate_url"'))
    assert "default     = null" in var and "/api/revalidate/catalog$" in var


# --- 8. the bootstrap ECR grant -------------------------------------------------------------------------------------

def test_apply_role_may_create_only_this_tripplanner_repository():
    stmt = _block_after(CICD_CRM, CICD_CRM.index('sid = "CrmEcrRepoManage"') - 20)
    assert '"arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/aa-tripplanner-${var.environment}-web"' in stmt
    assert "aa-tripplanner-${var.environment}-*" not in stmt
