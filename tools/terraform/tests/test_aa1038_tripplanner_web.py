"""AA-1038 R5 hosting (root ADR 0019 d23, S265 tech-lead decision): offline guards for the TripPlanner frontend on ECS.

1. The service (modules/environment/tripplanner_web.tf): one Fargate Spot ARM64 task, desired 0 at create with
   desired_count / task_definition ignored, ECS Exec off, no task role, one health path for the container check and
   the target group, a secret shell without a Terraform version, an execution role that reads only its own secrets,
   and the edge-aware app env (TP_EDGE_GATE=on, TP_CLIENT_IP_SOURCE=cloudfront).
2. The TripPlanner deploy role's web grant is scoped to this family, service and execution role.
3. The web ACL is CLOUDFRONT scope (us-east-1) with the rate rule, the model-path rate rule and the Challenge, on the
   same two paths the app gates (AA-TripPlanner-Web lib/botCheck.ts); the distribution carries it.
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
ECS = (ROOT / "modules" / "ecs" / "main.tf").read_text(encoding="utf-8")
ECS_VARS = (ROOT / "modules" / "ecs" / "variables.tf").read_text(encoding="utf-8")

# AA-TripPlanner-Web frontend/lib/botCheck.ts SEARCH_PATH / NARRATE_PATH (lib/edgeGate.test.ts pins the same values).
MODEL_PATHS = ["/api/browse/search", "/api/trip/narrate"]


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
    start = acl.rindex("rule {", 0, i)
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


# --- 3. the web ACL -------------------------------------------------------------------------------------------------

def test_web_acl_is_cloudfront_scope_in_us_east_1_and_on_the_distribution():
    acl = _code(_resource(EDGE, "aws_wafv2_web_acl", "tripplanner_web"))
    assert 'scope       = "CLOUDFRONT"' in acl
    assert "provider = aws.us_east_1" in acl
    dist = _code(_resource(EDGE, "aws_cloudfront_distribution", "tripplanner_web"))
    assert "web_acl_id      = aws_wafv2_web_acl.tripplanner_web[0].arn" in dist


def test_rules_rate_model_paths_and_challenge_in_order():
    acl = _code(_resource(EDGE, "aws_wafv2_web_acl", "tripplanner_web"))
    names = re.findall(r'name     = "([A-Za-z]+)"\n\s+priority = (\d+)', acl)
    assert names == [("RateLimitPerIp", "0"), ("RateLimitModelPaths", "1"), ("ChallengeBrowsers", "2")]
    rate = _rule(acl, "RateLimitPerIp")
    assert "limit              = var.tripplanner_web_rate_limit" in rate and "response_code            = 429" in rate
    model = _rule(acl, "RateLimitModelPaths")
    assert "limit              = var.tripplanner_web_model_rate_limit" in model
    assert "for_each = local.tp_web_model_paths" in model and "uri_path {}" in model
    challenge = _rule(acl, "ChallengeBrowsers")
    assert "challenge {}" in challenge
    assert 'name = "sec-fetch-dest"' in challenge and 'search_string         = "document"' in challenge
    assert "for_each = local.tp_web_model_paths" in challenge
    assert "immunity_time = var.tripplanner_web_challenge_immunity_s" in acl


def test_model_paths_are_the_app_paths():
    m = re.search(r"tp_web_model_paths = \[(.*?)\]", EDGE)
    assert m and re.findall(r'"([^"]+)"', m.group(1)) == MODEL_PATHS


# --- 4. caching -----------------------------------------------------------------------------------------------------

def test_pages_and_api_are_never_cached_only_static_chunks_and_photos_are():
    dist = _code(_resource(EDGE, "aws_cloudfront_distribution", "tripplanner_web"))
    default = _block_after(dist, dist.index("default_cache_behavior"))
    assert "caching_disabled[0].id" in default
    assert "all_viewer_and_cf_headers[0].id" in default  # Host for the ALB rule, CloudFront-Viewer-Address for the app
    ordered = _block_after(dist, dist.index('dynamic "ordered_cache_behavior"'))
    assert "for_each = local.tp_web_cached_paths" in ordered and "caching_optimized[0].id" in ordered
    m = re.search(r"tp_web_cached_paths = \[(.*?)\]", EDGE)
    assert m and re.findall(r'"([^"]+)"', m.group(1)) == ["/_next/static/*", "/photo-cdn/*"]


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
