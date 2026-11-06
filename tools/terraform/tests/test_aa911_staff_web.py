"""AA-911 (root ADR 0019 d23): offline guards for the staff frontends on ECS.

1. The ALB's HTTPS listener answers 404 by default (modules/alb): opening :443 to browsers must never expose the CIS
   API target group directly (the API stays behind API Gateway).
2. The ALB group opens :443 only through the gated dynamic block (modules/vpc); :80 stays VPC-only.
3. Every rule on the HTTPS listener takes its priority from local.alb_https_rule_priorities, is a host rule and
   forwards to a staff web target group (alb_rules.tf).
4. The staff web stack (modules/environment/staff_web.tf): one Fargate ARM64 task, two containers on distinct ports,
   FARGATE_SPOT only, desired 0 at create with desired_count / task_definition ignored, health path shared by the
   container check and the target groups, secret shells without a Terraform version, and the task's security group
   not admitted by RDS.
5. Both deploy grants (Booking in the module, CIS in cicd_split.tf) are scoped to the staff family and service.
6. The DNS cut-over changes the two existing records in place, behind var.staff_web_dns_on_ecs (default false).

Offline: reads the .tf files; no Terraform, no AWS. Run from the repo root:
    python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa911_staff_web.py
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
ALB = (ROOT / "modules" / "alb" / "main.tf").read_text(encoding="utf-8")
VPC = (ROOT / "modules" / "vpc" / "main.tf").read_text(encoding="utf-8")
STAFF = (ROOT / "modules" / "environment" / "staff_web.tf").read_text(encoding="utf-8")
RULES = (AA365 / "alb_rules.tf").read_text(encoding="utf-8")
EDGE = (AA365 / "staff_web_edge.tf").read_text(encoding="utf-8")
SGS = (AA365 / "app_security_groups.tf").read_text(encoding="utf-8")
CICD_SPLIT = (AA365 / "cicd_split.tf").read_text(encoding="utf-8")
DNS = (AA365 / "dns.tf").read_text(encoding="utf-8")
CUSTOM = (AA365 / "custom_domains.tf").read_text(encoding="utf-8")


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


def _resource(text: str, kind: str, name: str) -> str:
    m = re.search(rf'^resource "{kind}" "{name}" \{{', text, re.M)
    assert m, f"{kind}.{name} not found"
    return _block_after(text, m.start())


def _code(block: str) -> str:
    """The block without comment lines (a comment may name what the code must not do)."""
    return "\n".join(line for line in block.splitlines() if not line.strip().startswith("#"))


def test_https_listener_default_is_a_fixed_404():
    listener = _code(_resource(ALB, "aws_lb_listener", "https"))
    default = _block_after(listener, listener.index("default_action"))
    assert 'type = "fixed-response"' in default
    assert '"404"' in default
    assert "target_group_arn" not in default and "forward" not in default


def test_alb_group_opens_443_only_through_the_gated_block():
    group = _code(_resource(VPC, "aws_security_group", "alb"))
    assert group.count("from_port   = 443") == 1
    dyn = _block_after(group, group.index('dynamic "ingress"'))
    assert "length(var.alb_public_https_cidrs) > 0" in dyn
    assert "from_port   = 443" in dyn and "cidr_blocks = var.alb_public_https_cidrs" in dyn
    static = group.replace(dyn, "")
    assert "from_port   = 80" in static and "cidr_blocks = [var.vpc_cidr]" in static
    assert "0.0.0.0/0" not in static.split("egress")[0]


def test_every_https_rule_is_a_mapped_host_rule_to_a_staff_target_group():
    priorities = _block_after(RULES, RULES.index("alb_https_rule_priorities"))
    keys = re.findall(r"^\s*([a-z_]+)\s*=\s*(\d+)", priorities, re.M)
    assert keys and len({p for _, p in keys}) == len(keys), "HTTPS priorities must be unique"
    found = []
    for m in re.finditer(r'^resource "aws_lb_listener_rule" "([a-z_]+)" \{', RULES, re.M):
        body = _block_after(RULES, m.start())
        if "module.alb.https_listener_arn" not in body:
            continue
        found.append(m.group(1))
        assert f"local.alb_https_rule_priorities.{m.group(1)}" in body, f"{m.group(1)}: priority not from the map"
        assert "host_header" in body, f"{m.group(1)}: not a host rule"
        assert "module.environment.staff_web_target_group_arns[" in body
    assert sorted(found) == sorted(k for k, _ in keys)


def test_staff_task_is_one_arm64_spot_task_with_two_containers():
    apps = _block_after(STAFF, STAFF.index("staff_web_apps = {"))
    ports = re.findall(r"port\s*=\s*(\d+)", apps)
    containers = re.findall(r'container = "([a-z-]+)"', apps)
    assert sorted(containers) == ["booking-admin", "cis-admin"]
    assert len(ports) == 2 and len(set(ports)) == 2, "one network namespace: the ports must differ"

    td = _resource(STAFF, "aws_ecs_task_definition", "staff_web")
    assert 'cpu                      = "512"' in td and 'memory                   = "1024"' in td
    assert 'cpu_architecture        = "ARM64"' in td
    assert ":bootstrap" in td and ":latest" not in td

    svc = _code(_resource(STAFF, "aws_ecs_service", "staff_web"))
    assert re.findall(r'capacity_provider = "([A-Z_]+)"', svc) == ["FARGATE_SPOT"]
    assert "desired_count   = 0" in svc
    assert "ignore_changes = [desired_count, task_definition]" in svc
    assert 'dynamic "load_balancer"' in svc and "for_each = local.staff_web_apps" in svc


def test_health_path_is_shared_by_the_container_check_and_the_target_groups():
    assert 'staff_web_health_path = "/api/healthz"' in STAFF
    assert "${local.staff_web_health_path}" in _resource(STAFF, "aws_ecs_task_definition", "staff_web")
    assert "path                = local.staff_web_health_path" in _resource(STAFF, "aws_lb_target_group", "staff_web")


def test_secret_shells_have_no_terraform_version_and_the_task_is_not_a_db_caller():
    assert "aws_secretsmanager_secret_version" not in _code(STAFF)
    rds = _block_after(SGS, SGS.index("rds_ingress_sg_ids = ["))
    assert "staff_web" not in rds
    sg = _code(_resource(SGS, "aws_security_group", "staff_web"))
    assert "security_groups = [module.vpc.sg_alb_id]" in sg
    assert "cidr_blocks" not in sg.split("egress")[0], "ingress only from the ALB group"


def _statement(policy: str, sid: str) -> str:
    i = policy.index(f'Sid      = "{sid}"' if f'Sid      = "{sid}"' in policy else f'Sid    = "{sid}"')
    return policy[policy.rindex("{", 0, i) : policy.index("},\n", i)]


def test_deploy_grants_are_scoped_to_the_staff_family_and_service():
    booking = _resource(STAFF, "aws_iam_role_policy", "booking_app_deploy_staff_web")
    cis = _resource(CICD_SPLIT, "aws_iam_role_policy", "cis_app_deploy_staff_web")
    for policy, family in ((booking, "local.staff_web_task_def_pattern"), (cis, "local.staff_web_task_def_arn_pattern")):
        assert '"*"' not in _code(policy), "no wildcard resource in a staff deploy grant"
        assert family in _statement(policy, "EcsRegisterStaffWebTaskDefinition")
        update = _statement(policy, "EcsUpdateStaffWebService")
        assert "StringLikeIfExists" in update and family in update
        assert "ecs-tasks.amazonaws.com" in _statement(policy, "PassStaffWebTaskRoles")
    # The Booking deploy role pushes the Booking admin repo only.
    assert 'aws_ecr_repository.staff_web["booking"].arn' in booking


def test_dns_cutover_is_in_place_and_off_by_default():
    var = _block_after(EDGE, EDGE.index('variable "staff_web_dns_on_ecs"'))
    assert "default     = false" in var
    aa_cis = _block_after(DNS, DNS.index('"aa-cis|CNAME"'))
    assert 'type    = "CNAME"' in aa_cis
    assert "var.staff_web_dns_on_ecs ? local.staff_web_alb_dns_name" in aa_cis
    vercel = _resource(CUSTOM, "aws_route53_record", "vercel_frontend")
    assert 'var.staff_web_dns_on_ecs && each.key == "booking" ? local.staff_web_alb_dns_name : each.value' in vercel
