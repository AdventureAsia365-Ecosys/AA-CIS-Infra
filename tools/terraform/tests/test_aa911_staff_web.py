"""AA-911 (root ADR 0019 d23): offline guards for the staff frontends on ECS.

1. The ALB's HTTPS listener answers 404 by default (modules/alb): opening :443 to browsers must never expose the CIS
   API target group directly (the API stays behind API Gateway).
2. The ALB group opens :443 only through the gated dynamic block (modules/vpc); :80 stays VPC-only.
3. Every rule on the HTTPS listener takes its priority from local.alb_https_rule_priorities and is a host rule; each
   forwards to a staff web target group, except the apex redirect (alb_rules.tf).
4. The staff web stack (modules/environment/staff_web.tf, S271 amendment of ADR 0019 d23): one service, task
   definition family and execution role PER APP, Fargate ARM64 256/512, FARGATE_SPOT only, desired 0 at create with
   desired_count / task_definition ignored, ECS Exec off, no task role, health path shared by the container check
   and the target groups, secret shells without a Terraform version, each execution role reading only its own app's
   secrets, and the security group not admitted by RDS.
5. Each deploy grant (Booking in the module, CIS in cicd_split.tf) is scoped to its OWN app's family, service and
   execution role.
6. Since the Vercel retirement (S272) both staff hosts CNAME to the ALB with no switch and no Vercel target left: the
   records moved (moved blocks, never destroyed) from dns.tf / custom_domains.tf to staff_web_edge.tf; the switch
   window can still give both a 60 s TTL and is off; the apex is an alias to the ALB with no Vercel fallback; the
   Preview-only WORKFORCE clients and the Vercel callback URLs are gone.
7. The certificate never names a host that CNAMEs off-zone (CAA follows the CNAME, critic C1): wildcard + apex only,
   validated through the existing wildcard validation record.
8. The WAF scopes the staff hosts out of RateLimit1000 and rate-limits them in their own rule.

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
CRM_AGENCY = (AA365 / "crm_agency_edge.tf").read_text(encoding="utf-8")
MAIN = (AA365 / "main.tf").read_text(encoding="utf-8")
TFVARS = (AA365 / "terraform.tfvars").read_text(encoding="utf-8")
VERCEL_VARS = (AA365 / "custom_domains_variables.tf").read_text(encoding="utf-8")
IDENTITY = (AA365 / "identity.tf").read_text(encoding="utf-8")
IDENTITY_VARS = (AA365 / "identity_variables.tf").read_text(encoding="utf-8")
SES_VARS = (AA365 / "ses_variables.tf").read_text(encoding="utf-8")
WAF = (ROOT / "modules" / "waf" / "main.tf").read_text(encoding="utf-8")


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
        if m.group(1) == "staff_apex_redirect":
            code = _code(body)
            assert 'type = "redirect"' in code and "target_group_arn" not in code
            assert "values = [var.dns_zone_name]" in code and "host        = local.staff_web_hosts.cis" in code
        else:
            assert "module.environment.staff_web_target_group_arns[" in body
    assert sorted(found) == sorted(k for k, _ in keys)


def test_one_arm64_spot_service_family_and_execution_role_per_app():
    apps = _block_after(STAFF, STAFF.index("staff_web_apps = {"))
    services = re.findall(r'service\s*=\s*"([^"]+)"', apps)
    containers = re.findall(r'container = "([a-z-]+)"', apps)
    assert sorted(containers) == ["booking-admin", "cis-admin"]
    assert sorted(services) == ["aa-booking-${var.environment}-admin", "aa-cis-${var.environment}-admin"]

    td = _resource(STAFF, "aws_ecs_task_definition", "staff_web")
    assert "for_each = local.staff_web_apps" in td
    assert "family                   = each.value.service" in td
    assert 'cpu                      = "256"' in td and 'memory                   = "512"' in td
    assert 'cpu_architecture        = "ARM64"' in td
    assert "execution_role_arn       = aws_iam_role.staff_web_ecs_execution[each.key].arn" in td
    assert "task_role_arn" not in _code(td), "no task role: the apps call no AWS API"
    assert ":bootstrap" in td and ":latest" not in td
    assert "secrets      = local.staff_web_secrets[each.key]" in td

    svc = _code(_resource(STAFF, "aws_ecs_service", "staff_web"))
    assert "for_each = local.staff_web_apps" in svc
    assert re.findall(r'capacity_provider = "([A-Z_]+)"', svc) == ["FARGATE_SPOT"]
    assert "desired_count   = 0" in svc
    assert "ignore_changes = [desired_count, task_definition]" in svc
    assert "enable_execute_command = false" in svc
    assert svc.count("load_balancer {") == 1 and 'dynamic "load_balancer"' not in svc
    # No task role anywhere in the stack (nothing for ECS Exec to use).
    assert 'resource "aws_iam_role" "staff_web_ecs_task"' not in STAFF


def test_each_execution_role_reads_only_its_own_app_secrets():
    arns = _block_after(STAFF, STAFF.index("staff_web_secret_arns = {"))
    cis = re.search(r"cis\s*=\s*\[([^\]]*)\]", arns).group(1)
    booking = re.search(r"booking\s*=\s*\[([^\]]*)\]", arns).group(1)
    assert "var.cis_admin_secret_arn" in cis and "staff_web_cis" in cis and "staff_web_booking" not in cis
    assert "staff_web_booking" in booking and "cis" not in booking
    pol = _code(_resource(STAFF, "aws_iam_role_policy", "staff_web_ecs_execution"))
    assert "Resource = local.staff_web_secret_arns[each.key]" in pol
    assert "Resource = aws_ecr_repository.staff_web[each.key].arn" in pol
    # The container secrets of each app reference only that app's ARNs.
    secrets = _block_after(STAFF, STAFF.index("staff_web_secrets = {"))
    booking_secrets = secrets[secrets.index("booking = [") :]
    assert "cis_admin_secret_arn" not in booking_secrets and "staff_web_cis" not in booking_secrets


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


def test_each_deploy_grant_is_scoped_to_its_own_app():
    booking = _resource(STAFF, "aws_iam_role_policy", "booking_app_deploy_staff_web")
    cis = _resource(CICD_SPLIT, "aws_iam_role_policy", "cis_app_deploy_staff_web")
    for policy, scope, other in (
        (booking, "local.staff_web_deploy_scope.booking", "cis"),
        (cis, "local.cis_staff_web_scope", "booking"),
    ):
        code = _code(policy)
        assert '"*"' not in code, "no wildcard resource in a staff deploy grant"
        assert f"{scope}.task_def_pattern" in _statement(policy, "EcsRegisterStaffWebTaskDefinition")
        update = _statement(policy, "EcsUpdateStaffWebService")
        assert "StringLikeIfExists" in update and f"{scope}.task_def_pattern" in update
        assert f"{scope}.service_arn" in update
        pass_role = _statement(policy, "PassStaffWebTaskRoles")
        assert "ecs-tasks.amazonaws.com" in pass_role
        assert f'"{other}"' not in code and f".{other}." not in code, f"grant names the {other} app"
    assert 'aws_iam_role.staff_web_ecs_execution["booking"].arn' in _statement(booking, "PassStaffWebTaskRoles")
    assert "local.cis_staff_web_scope.execution_role_arn" in _statement(cis, "PassStaffWebTaskRoles")
    assert 'cis_staff_web_scope = module.environment.staff_web_deploy_scope["cis"]' in CICD_SPLIT
    # The Booking deploy role pushes the Booking admin repo only.
    assert 'aws_ecr_repository.staff_web["booking"].arn' in booking
    # The scope output is built from locals only (the CIS grant is applied alone with -target).
    scope = _block_after(STAFF, STAFF.index("staff_web_deploy_scope = {"))
    assert not re.search(r"\baws_[a-z0-9_]+\.", scope), "no resource attribute in the scope"


def test_staff_hosts_point_at_the_alb_with_no_switch_left():
    record = _code(_resource(EDGE, "aws_route53_record", "staff_web"))
    assert "for_each = local.staff_web_hosts" in record
    assert 'type    = "CNAME"' in record
    assert "records = [local.staff_web_alb_dns_name]" in record
    assert "staff_web_alb_dns_name = module.alb.alb_dns_name" in EDGE
    # The cut-over switch and its Vercel targets are gone (an unclaimed Vercel target is a takeover risk).
    for text in (EDGE, DNS, CUSTOM, TFVARS):
        assert "staff_web_dns_on_ecs" not in _code(text)
    assert '"aa-cis|CNAME"' not in _code(DNS)
    assert not re.search(r"^\s*(booking|aa-cis|booking-preview|aa-cis-preview)\s*=", VERCEL_VARS, re.M)


def test_staff_records_moved_never_recreated():
    moves = re.findall(r"moved \{\s*from = (\S+)\s*to   = (\S+)\s*\}", EDGE)
    assert ('aws_route53_record.parity["aa-cis|CNAME"]', 'aws_route53_record.staff_web["cis"]') in moves
    assert ('aws_route53_record.vercel_frontend["booking"]', 'aws_route53_record.staff_web["booking"]') in moves
    # The new keys are the app keys of local.staff_web_hosts.
    hosts = _block_after(EDGE, EDGE.index("staff_web_hosts = {"))
    assert 'cis     = "aa-cis.${var.dns_zone_name}"' in hosts
    assert 'booking = "booking.${var.dns_zone_name}"' in hosts


def test_switch_window_ttl_and_closed_after_the_retirement():
    var = _block_after(EDGE, EDGE.index('variable "staff_web_dns_switch_window"'))
    assert "default     = false" in var
    assert "staff_web_switch_ttl = var.staff_web_dns_switch_window ? 60 : null" in EDGE
    record = _code(_resource(EDGE, "aws_route53_record", "staff_web"))
    assert "ttl     = coalesce(local.staff_web_switch_ttl, local.staff_web_dns_ttl[each.key])" in record
    ttl = _block_after(EDGE, EDGE.index("staff_web_dns_ttl = {"))
    assert "cis     = 1800" in ttl and "booking = 300" in ttl
    # Root runbook section 4 step 4: closed at the Vercel retirement.
    assert re.search(r"^staff_web_dns_switch_window\s*=\s*false", TFVARS, re.M)


def test_apex_is_an_alias_to_the_alb_with_no_vercel_fallback():
    apex = _code(_resource(DNS, "aws_route53_record", "apex"))
    assert "alias {" in apex and "module.alb.alb_zone_id" in apex and "module.alb.alb_dns_name" in apex
    assert "records" not in apex and "dynamic" not in apex
    for text in (EDGE, DNS, TFVARS):
        assert "staff_web_apex_on_alb" not in _code(text)
    assert "dns_apex_a_records" not in _code(SES_VARS) + _code(DNS)


def test_preview_clients_and_vercel_callbacks_are_gone():
    clients = _block_after(IDENTITY, IDENTITY.index("id_workforce_clients = {"))
    assert '"cis-admin-preview"' not in _code(clients) and '"booking-staff-preview"' not in _code(clients)
    urls = _code(IDENTITY_VARS)
    for host in ("aa-cis-preview.", "booking-preview.", "aa-booking-admin.vercel.app"):
        assert f'"https://{host}' not in urls, host  # no URL (the description may name what was removed)
    assert '"https://booking.lumiguides.it.com/api/auth/callback/cognito"' in urls


def _vercel_cname_labels() -> set[str]:
    labels = set(re.findall(r'^\s*([a-z0-9-]+)\s*=\s*"[^"]*vercel-dns[^"]*"', VERCEL_VARS, re.M))
    for m in re.finditer(r'"([a-z0-9-]+)\|CNAME" = \{', DNS):
        if "vercel" in _block_after(DNS, m.start()):
            labels.add(m.group(1))
    return labels


def test_certificate_never_names_a_host_that_cnames_off_zone():
    cert = _code(_resource(EDGE, "aws_acm_certificate", "staff_web"))
    assert "domain_name               = local.staff_web_cert_domain" in cert
    assert "subject_alternative_names = local.staff_web_cert_sans" in cert
    assert 'staff_web_cert_domain = "*.${var.dns_zone_name}"' in EDGE
    assert "staff_web_cert_sans   = [var.dns_zone_name]" in EDGE
    assert "staff_web_hosts" not in cert
    labels = _vercel_cname_labels()
    assert "tripplanner" in labels, labels  # the parser still finds the Vercel CNAMEs that remain
    names = re.findall(r'staff_web_cert_(?:domain|sans)\s*=\s*(.+)', EDGE)
    for label in labels:
        assert all(f'"{label}.' not in n for n in names), f"certificate names {label}. (a CNAME to Vercel)"


def test_certificate_validates_through_the_existing_wildcard_record():
    validation = _code(_resource(EDGE, "aws_acm_certificate_validation", "staff_web"))
    assert "aws_route53_record.crm_agency_acm_validation[local.crm_agency_wildcard].fqdn" in validation
    assert 'crm_agency_wildcard = "*.${var.dns_zone_name}"' in CRM_AGENCY
    # No second record of the same name (Route 53 CREATE would fail "already exists").
    assert 'resource "aws_route53_record" "staff_web_acm_validation"' not in EDGE


def _waf_rule(name: str) -> str:
    """Text of one WAF rule, from its name to its visibility_config."""
    i = WAF.index(f'name     = "{name}"')
    return WAF[i : WAF.index("visibility_config", i)]


def test_waf_scopes_staff_hosts_out_of_the_api_rate_rule():
    rate = _waf_rule("RateLimit1000")
    assert 'dynamic "scope_down_statement"' in rate and "not_statement" in rate
    assert "regex_string = local.staff_host_regex" in rate
    staff = _waf_rule("StaffWebRateLimit")
    assert "limit              = var.staff_web_rate_limit" in staff
    assert "scope_down_statement" in staff and "regex_string = local.staff_host_regex" in staff
    assert "not_statement" not in staff
    assert "staff_web_hosts      = values(local.staff_web_hosts)" in MAIN
    # Geo still applies to the staff hosts: no scope-down on the geo rule.
    geo = _waf_rule("GeoBlockNonAllowed")
    assert "staff" not in geo
