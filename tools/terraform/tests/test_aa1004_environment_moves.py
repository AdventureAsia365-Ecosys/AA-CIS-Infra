"""AA-1004 P0 (prod plan P0): the split of accounts/aa365 into modules/environment stays a pure move.

modules/environment is the environment-scoped stack a future accounts/aa-prod root instantiates with its own inputs;
accounts/aa365 instantiates it for Dev as `module "environment"` (environment.tf). Every slice moves resources with
`moved` blocks, so the Dev plan is "0 to add, 0 to change, 0 to destroy". These offline checks catch the ways a slice
turns into a destroy + create instead:

  1. every resource of the slice lists (slice 1: the AA-Booking stack; slice 2: the AA-Partner CRM stack; slice 3: the
     AA-TripPlanner stack) has exactly
     one moved block root -> module, same type and name;
  2. every moved block into the module points at a resource the module declares, and its `from` address is no longer
     declared in the root (a leftover copy would plan a second resource with the same AWS name);
  3. no address is moved twice and no moved block points at a resource the root still declares;
  4. the module has no provider or backend block of its own (it must run on the root's default aws provider and its
     default_tags, or every tag would plan to change), and the root instantiates it exactly once with
     environment = var.environment;
  5. (slice 2, value equality) each module input that replaced a root reference is passed exactly that root
     expression (SLICE_2_INPUTS, frozen from the move), every CRM setting the root declares is declared identically in
     the module and passed through as var.<same name>, and the CRM pieces kept in the root are still there (the
     crm_api listener rule in alb_rules.tf, the MX record and receipt rule in crm_mail_receipt.tf);
  6. (slice 3, AA-TripPlanner) the same value equality for its inputs and settings (SLICE_3_INPUTS,
     SLICE_3_SETTINGS), the TripPlanner module files read no root object, the root still owns the pieces kept there
     (the tp_lambda security group, the SES grant, the observability log groups and alarms, the custom domain, the
     Mapbox `removed` blocks), and the root outputs of the old files are re-exported under the same names.

Offline: reads the .tf files; no Terraform, no AWS. Run from the repo root:
    python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1004_environment_moves.py
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
ENV_MODULE = ROOT / "modules" / "environment"

RESOURCE_RE = re.compile(r'^resource "([a-z0-9_]+)" "([a-z0-9_]+)" \{', re.M)
MOVED_RE = re.compile(r"^moved \{\s*from\s*=\s*(\S+)\s*to\s*=\s*(\S+)\s*\}", re.M)

# Slice 1 (S266): the former booking.tf, booking_media.tf and booking_ops_docs.tf of accounts/aa365. Frozen: a later
# slice adds its own list, it never edits this one.
SLICE_1 = {
    "aws_ecr_repository.booking",
    "aws_ecr_lifecycle_policy.booking",
    "aws_cloudwatch_log_group.booking",
    "aws_secretsmanager_secret.booking_db",
    "aws_secretsmanager_secret.booking_sentry_dsn",
    "aws_iam_role.booking_ecs_execution",
    "aws_iam_role_policy.booking_ecs_execution",
    "aws_iam_role.booking_ecs_task",
    "aws_iam_role_policy.booking_ecs_task",
    "aws_iam_role_policy.booking_ecs_task_retention_archive",
    "aws_ecs_task_definition.booking",
    "aws_lb_target_group.booking",
    "aws_ecs_service.booking",
    "aws_api_gateway_rest_api.booking",
    "aws_api_gateway_resource.booking",
    "aws_api_gateway_resource.booking_proxy",
    "aws_api_gateway_method.booking_any",
    "aws_api_gateway_integration.booking_any",
    "aws_api_gateway_method.booking_proxy_any",
    "aws_api_gateway_integration.booking_proxy_any",
    "aws_api_gateway_deployment.booking",
    "aws_api_gateway_stage.booking",
    "aws_api_gateway_method_settings.booking_throttle",
    "aws_iam_role.booking_app_deploy",
    "aws_iam_role_policy.booking_app_deploy",
    "aws_s3_bucket.booking_supply_media",
    "aws_s3_bucket_public_access_block.booking_supply_media",
    "aws_s3_bucket_ownership_controls.booking_supply_media",
    "aws_s3_bucket_server_side_encryption_configuration.booking_supply_media",
    "aws_s3_bucket_versioning.booking_supply_media",
    "aws_s3_bucket_lifecycle_configuration.booking_supply_media",
    "aws_s3_bucket_policy.booking_supply_media",
    "aws_iam_role_policy.booking_ecs_task_supply_media",
    "aws_s3_bucket.booking_ops_docs",
    "aws_s3_bucket_public_access_block.booking_ops_docs",
    "aws_s3_bucket_ownership_controls.booking_ops_docs",
    "aws_s3_bucket_server_side_encryption_configuration.booking_ops_docs",
    "aws_s3_bucket_versioning.booking_ops_docs",
    "aws_s3_bucket_lifecycle_configuration.booking_ops_docs",
    "aws_s3_bucket_policy.booking_ops_docs",
    "aws_iam_role_policy.booking_ecs_task_ops_docs",
}

# Slice 2 (S266, AA-1004 P1): the former crm_app.tf, crm_web.tf, crm_portal.tf, crm_data.tf, crm_storage.tf,
# crm_mail.tf, crm_scrub.tf and crm_llm.tf of accounts/aa365, less the crm_api listener rule (alb_rules.tf) and the MX
# record + receipt rule (crm_mail_receipt.tf). Frozen like SLICE_1.
SLICE_2 = {
    # crm_app.tf
    "aws_ecr_repository.crm_api",
    "aws_ecr_lifecycle_policy.crm_api",
    "aws_cloudwatch_log_group.crm_api",
    "aws_secretsmanager_secret.crm_sentry_dsn",
    "aws_iam_role.crm_ecs_execution",
    "aws_iam_role_policy.crm_ecs_execution",
    "aws_iam_role.crm_ecs_task",
    "aws_iam_role_policy.crm_ecs_task",
    "aws_ecs_task_definition.crm_api",
    "aws_lb_target_group.crm_api",
    "aws_ecs_service.crm_api",
    "aws_iam_role.crm_app_deploy",
    "aws_iam_role_policy.crm_app_deploy",
    "aws_cloudwatch_metric_alarm.crm_no_healthy_task",
    # crm_web.tf
    "aws_ecr_repository.crm_web",
    "aws_ecr_lifecycle_policy.crm_web",
    "aws_secretsmanager_secret.crm_web",
    "aws_iam_role.crm_web_ecs_execution",
    "aws_iam_role_policy.crm_web_ecs_execution",
    "aws_iam_role.crm_web_ecs_task",
    "aws_iam_role_policy.crm_web_ecs_task",
    "aws_ecs_task_definition.crm_web",
    "aws_lb_target_group.crm_web",
    "aws_ecs_service.crm_web",
    "aws_cloudwatch_metric_alarm.crm_web_no_healthy_task",
    # crm_portal.tf
    "aws_ecr_repository.crm_portal",
    "aws_ecr_lifecycle_policy.crm_portal",
    "aws_secretsmanager_secret.crm_portal_sentry_dsn",
    "aws_iam_role.crm_portal_ecs_execution",
    "aws_iam_role_policy.crm_portal_ecs_execution",
    "aws_iam_role.crm_portal_ecs_task",
    "aws_iam_role_policy.crm_portal_ecs_task",
    "aws_ecs_task_definition.crm_portal",
    "aws_lb_target_group.crm_portal",
    "aws_ecs_service.crm_portal",
    "aws_cloudwatch_metric_alarm.crm_portal_no_healthy_task",
    # crm_data.tf
    "aws_secretsmanager_secret.crm_db",
    "aws_kms_key.crm_data",
    "aws_kms_key.crm_ingest",
    "aws_kms_key.crm_seal",
    "aws_kms_alias.crm",
    "aws_cloudwatch_event_rule.crm_kms_key_admin",
    "aws_cloudwatch_event_target.crm_kms_key_admin",
    "aws_cloudwatch_event_rule.crm_kms_foreign_use",
    "aws_cloudwatch_event_target.crm_kms_foreign_use",
    # crm_storage.tf
    "aws_s3_bucket.crm",
    "aws_s3_bucket_public_access_block.crm",
    "aws_s3_bucket_ownership_controls.crm",
    "aws_s3_bucket_server_side_encryption_configuration.crm",
    "aws_s3_bucket_versioning.crm",
    "aws_s3_bucket_object_lock_configuration.crm_audit",
    "aws_s3_bucket_lifecycle_configuration.crm_audit",
    "aws_s3_bucket_lifecycle_configuration.crm_documents",
    "aws_s3_bucket_lifecycle_configuration.crm_ingest",
    "aws_s3_bucket_policy.crm",
    "aws_cloudwatch_log_group.crm_kms_decrypt",
    "aws_cloudwatch_log_resource_policy.crm_kms_decrypt",
    "aws_cloudwatch_event_rule.crm_kms_decrypt",
    "aws_cloudwatch_event_target.crm_kms_decrypt",
    "aws_cloudwatch_log_metric_filter.crm_kms_decrypt",
    "aws_cloudwatch_metric_alarm.crm_kms_decrypt_anomaly",
    "aws_iam_role_policy.crm_ecs_task_audit_export",
    # crm_mail.tf
    "aws_iam_role_policy.crm_ecs_task_mail",
    "aws_secretsmanager_secret.crm_mail_oauth",
    # crm_scrub.tf
    "aws_bedrock_guardrail.crm_scrub",
    "aws_bedrock_guardrail_version.crm_scrub",
    "aws_iam_role_policy.crm_ecs_task_scrub",
    "aws_iam_role.crm_scrub_corpus",
    "aws_iam_role_policy.crm_scrub_corpus",
    # crm_llm.tf
    "aws_iam_role_policy.crm_ecs_task_llm",
}

# Slice 2 value equality: module input -> the exact root expression that the moved code used before the move (the
# module code reads var.<input> where it read the expression). Frozen from the move; a later slice that moves the
# owner of one of these into the module removes its row together with the input.
SLICE_2_INPUTS = {
    "alb_arn_suffix": "module.alb.alb_arn_suffix",
    "dns_zone_name": "var.dns_zone_name",
    "ecosys_tags": "local.ecosys_tags",
    "runbook_suffix": "local.runbook_suffix",
    "m2m_crm_client_secret_arn": "aws_secretsmanager_secret.m2m_crm_client.arn",
    "crm_api_security_group_id": "aws_security_group.crm_api.id",
    "crm_web_security_group_id": "aws_security_group.crm_web.id",
    "crm_portal_security_group_id": "aws_security_group.crm_portal.id",
    "crm_edge_on": "local.crm_edge_on",
    "crm_partner_host": "local.crm_partner_host",
    "crm_agency_host": "local.crm_agency_host",
    "crm_client_hosts": "local.crm_client_hosts",
    "crm_intake_origin": "local.crm_intake_origin",
    "crm_api_listener_rule_gate": "aws_lb_listener_rule.crm_api[*].arn",
    "crm_partner_default_rule_gate": "aws_lb_listener_rule.crm_partner_default[*].arn",
    "crm_agency_studio_rule_gate": "aws_lb_listener_rule.crm_agency_studio[*].arn",
    "cognito_workforce_pool_endpoint": "aws_cognito_user_pool.workforce.endpoint",
    "cognito_workforce_cis_admin_client_id": 'aws_cognito_user_pool_client.workforce["cis-admin"].id',
    "cognito_workforce_breakglass_client_id": 'aws_cognito_user_pool_client.workforce["breakglass"].id',
    "cognito_workforce_crm_staff_client_id": 'aws_cognito_user_pool_client.workforce["crm-staff"].id',
    "cognito_workforce_prefix_domain": "aws_cognito_user_pool_domain.workforce_prefix.domain",
    "cognito_partner_pool_id": "aws_cognito_user_pool.partner.id",
    "cognito_partner_web_client_id": 'aws_cognito_user_pool_client.partner["partner-web"].id',
    "cognito_partner_issuer": "local.idpartner_issuer",
    "cognito_partner_login_base": "local.idpartner_login_base",
    "cognito_external_cis_portal_client_id": 'aws_cognito_user_pool_client.external["cis-portal"].id',
    "cognito_external_prefix_domain": "aws_cognito_user_pool_domain.external_prefix.domain",
    "identity_custom_domains_enabled": "local.id_custom_domains",
    "identity_external_custom_domain": "var.identity_external_custom_domain",
    "identity_workforce_custom_domain": "var.identity_workforce_custom_domain",
    # Inputs slice 1 added, reused by the CRM files for the same root expressions.
    "permissions_boundary_arn": "aws_iam_policy.workload_boundary.arn",
    "github_oidc_provider_arn": "aws_iam_openid_connect_provider.github_actions.arn",
    "iam_propagation_gate": "time_sleep.wait_for_iam_propagation.id",
    "vpc_id": "module.vpc.vpc_id",
    "private_subnet_ids": "module.vpc.private_subnet_ids",
    "ecs_cluster_arn": "module.ecs.cluster_arn",
    "ecs_cluster_name": "module.ecs.cluster_name",
    "ecs_exec_session_log_group_arn": "module.ecs.exec_session_log_group_arn",
    "ses_from_address": "var.ses_from_address",
    "ses_configuration_set_name": 'aws_sesv2_configuration_set.stream["transactional"].configuration_set_name',
    "alerts_topic_arn": "aws_sns_topic.alerts.arn",
}

# The CRM settings: declared in accounts/aa365/crm_variables.tf AND in the module file that reads them, passed through.
SLICE_2_SETTINGS = {
    "crm_github_repo_id", "crm_cis_api_url", "crm_booking_api_url", "crm_booking_admin_url", "crm_sentry_enabled",
    "crm_partner_signin_enabled", "crm_web_client_hosts", "crm_portal_sentry_enabled", "crm_portal_api_key_signin",
    "crm_audit_compliance_enabled", "crm_ingest_subdomain", "crm_mail_oauth_enabled", "crm_scrub_guardrail_enabled",
    "crm_llm_bedrock_enabled",
}

# Slice 3 (S267, AA-1004 P1): the former tripplanner.tf and tripplanner_jobs.tf of accounts/aa365 (the two Mapbox
# `removed` blocks stay in the root, tripplanner_removed.tf). Frozen like SLICE_1.
SLICE_3 = {
    # tripplanner.tf
    "random_password.tripplanner_api_key",
    "aws_secretsmanager_secret.tripplanner_db",
    "aws_secretsmanager_secret_version.tripplanner_db",
    "aws_secretsmanager_secret.tripplanner_api_key",
    "aws_secretsmanager_secret_version.tripplanner_api_key",
    "aws_secretsmanager_secret.tripplanner_sentry_dsn",
    "aws_s3_bucket.tripplanner_artifacts",
    "aws_s3_bucket_versioning.tripplanner_artifacts",
    "aws_s3_bucket_public_access_block.tripplanner_artifacts",
    "aws_s3_bucket_server_side_encryption_configuration.tripplanner_artifacts",
    "aws_s3_object.tripplanner_browse_zip",
    "aws_s3_object.tripplanner_assembly_zip",
    "aws_iam_role.tripplanner_lambda_exec",
    "aws_iam_role_policy_attachment.tripplanner_lambda_vpc",
    "aws_iam_role_policy.tripplanner_lambda_permissions",
    "aws_lambda_function.tripplanner_browse",
    "aws_lambda_function.tripplanner_assembly",
    "aws_apigatewayv2_api.tripplanner",
    "aws_apigatewayv2_integration.tripplanner_browse",
    "aws_apigatewayv2_integration.tripplanner_assembly",
    "aws_apigatewayv2_route.tripplanner_browse",
    "aws_apigatewayv2_route.tripplanner_assembly",
    "aws_apigatewayv2_route.tripplanner_me",
    "aws_apigatewayv2_route.tripplanner_narrate",
    "aws_apigatewayv2_route.tripplanner_search",
    "aws_apigatewayv2_stage.tripplanner",
    "aws_lambda_permission.tripplanner_browse_apigw",
    "aws_lambda_permission.tripplanner_assembly_apigw",
    "aws_iam_role.tripplanner_app_deploy",
    "aws_iam_role_policy.tripplanner_app_deploy",
    # tripplanner_jobs.tf
    "aws_s3_object.tripplanner_jobs_zip",
    "aws_iam_role.tripplanner_jobs_exec",
    "aws_iam_role_policy_attachment.tripplanner_jobs_vpc",
    "aws_iam_role_policy.tripplanner_jobs_permissions",
    "aws_cloudwatch_log_group.tripplanner_jobs",
    "aws_lambda_function.tripplanner_jobs",
    "aws_lambda_function_event_invoke_config.tripplanner_jobs",
    "aws_cloudwatch_metric_alarm.tripplanner_jobs_errors",
    "aws_cloudwatch_metric_alarm.tripplanner_jobs_not_run",
    "aws_iam_role.tripplanner_jobs_scheduler",
    "aws_iam_role_policy.tripplanner_jobs_scheduler_invoke",
    "aws_scheduler_schedule.tripplanner_jobs_daily",
}

# Slice 3 value equality, same rule as SLICE_2_INPUTS: the inputs slice 3 added, and the earlier inputs the
# TripPlanner files now read, with the exact root expression the moved code used.
SLICE_3_INPUTS = {
    "tripplanner_lambda_security_group_id": "aws_security_group.tp_lambda.id",
    "bedrock_acct_primary": "local.bedrock_acct_primary",
    "eventbridge_schedule_group_name": "module.eventbridge.schedule_group_name",
    "tripplanner_placeholder_zip": '"${path.module}/artifacts/placeholder.zip"',
    "permissions_boundary_arn": "aws_iam_policy.workload_boundary.arn",
    "github_oidc_provider_arn": "aws_iam_openid_connect_provider.github_actions.arn",
    "iam_propagation_gate": "time_sleep.wait_for_iam_propagation.id",
    "private_subnet_ids": "module.vpc.private_subnet_ids",
    "alerts_topic_arn": "aws_sns_topic.alerts.arn",
    "runbook_suffix": "local.runbook_suffix",
}

# The TripPlanner settings: declared in accounts/aa365/tripplanner_variables.tf AND in the module (its
# tripplanner_variables.tf, and the two jobs settings in tripplanner_jobs.tf), passed through.
SLICE_3_SETTINGS = {
    "tripplanner_throttle_rate_limit", "tripplanner_throttle_burst_limit", "tripplanner_narrate_throttle_rate_limit",
    "tripplanner_narrate_throttle_burst_limit", "tripplanner_search_throttle_rate_limit",
    "tripplanner_search_throttle_burst_limit", "tripplanner_browse_reserved_concurrency",
    "tripplanner_lambda_reserved_concurrency", "tripplanner_jobs_reserved_concurrency",
    "tripplanner_daily_spend_cap_usd", "tripplanner_jobs_schedule_expression",
    "tripplanner_jobs_retention_override_enabled",
}

# The root outputs of the old tripplanner.tf / tripplanner_jobs.tf, re-exported by environment.tf under the same names.
SLICE_3_OUTPUTS = {
    "tripplanner_api_base_url", "tripplanner_lambda_exec_role_arn", "tripplanner_app_deploy_role_arn",
    "tripplanner_artifacts_bucket", "tripplanner_api_key_secret_arn", "tripplanner_jobs_function_name",
}

SLICES = SLICE_1 | SLICE_2 | SLICE_3

PREFIX = "module.environment."


def _strip_comments(text: str) -> str:
    return "\n".join(line.split("#", 1)[0] if not line.lstrip().startswith("#") else "" for line in text.splitlines())


def _texts(d: Path) -> dict[str, str]:
    return {f.name: _strip_comments(f.read_text(encoding="utf-8")) for f in sorted(d.glob("*.tf"))}


def _resources(d: Path) -> set[str]:
    return {f"{t}.{n}" for text in _texts(d).values() for t, n in RESOURCE_RE.findall(text)}


def _moves() -> list[tuple[str, str]]:
    return [(a, b) for text in _texts(AA365).values() for a, b in MOVED_RE.findall(text)]


def _env_moves() -> list[tuple[str, str]]:
    return [(a, b) for a, b in _moves() if b.startswith(PREFIX)]


def test_the_parsers_see_the_files():
    assert len(_resources(AA365)) > 100
    assert len(_resources(ENV_MODULE)) >= len(SLICES)
    assert len(_env_moves()) >= len(SLICES)
    assert len(SLICE_2) == 70 and not SLICE_1 & SLICE_2
    assert len(SLICE_3) == 42 and not (SLICE_1 | SLICE_2) & SLICE_3


def test_every_slice_resource_has_one_plain_move():
    moves = _env_moves()
    for addr in sorted(SLICES):
        hits = [(a, b) for a, b in moves if a == addr]
        assert hits == [(addr, PREFIX + addr)], f"{addr}: expected one moved block to {PREFIX}{addr}, got {hits}"


def test_every_move_lands_on_a_module_resource():
    module = _resources(ENV_MODULE)
    for a, b in _env_moves():
        target = b[len(PREFIX):]
        assert target in module, f"moved {a} -> {b}: modules/environment declares no {target}"
        assert a.split(".")[0] == target.split(".")[0], f"moved {a} -> {b} changes the resource type"


def test_no_moved_address_is_still_declared_in_the_root():
    root = _resources(AA365)
    for a, b in _env_moves():
        assert a not in root, f"{a} is moved to {b} but the root still declares it (plan would create a copy)"
    # And the module copy is not shadowed by a root resource of the same address under another move.
    for addr in _resources(ENV_MODULE) & SLICES:
        assert addr not in root, f"{addr} is declared both in the root and in modules/environment"


def test_no_address_is_moved_twice():
    froms = [a for a, _ in _moves()]
    tos = [b for _, b in _moves()]
    assert len(froms) == len(set(froms)), "an address is the `from` of two moved blocks"
    assert len(tos) == len(set(tos)), "two moved blocks share a `to`"


def test_the_module_runs_on_the_roots_provider():
    for name, text in _texts(ENV_MODULE).items():
        assert not re.search(r'^provider "', text, re.M), f"modules/environment/{name}: no provider block in the module"
        # A backend block, not the word (the TripPlanner Lambda handlers are "backend.<x>.handler.handler").
        assert not re.search(r'^\s*backend\s+"', text, re.M), f"modules/environment/{name}: no backend in the module"


def test_the_root_instantiates_the_module_once_for_its_environment():
    calls = [(n, t) for n, t in _texts(AA365).items() if re.search(r'^module "environment" \{', t, re.M)]
    assert [n for n, _ in calls] == ["environment.tf"]
    text = calls[0][1]
    assert re.search(r'^\s*source\s*=\s*"\.\./\.\./modules/environment"\s*$', text, re.M)
    assert re.search(r"^\s*environment\s*=\s*var\.environment\s*$", text, re.M)
    assert re.search(r"^\s*account_id\s*=\s*var\.account_id\s*$", text, re.M)


def test_no_account_id_literal_in_the_module():
    # Public repo, and the same module serves another account: ids arrive as inputs only. Comments included.
    for f in sorted(ENV_MODULE.glob("*.tf")):
        text = f.read_text(encoding="utf-8")
        assert not re.search(r"\b\d{12}\b", text), f"modules/environment/{f.name}: 12-digit literal"


# --- slice 2 (CRM): value equality and the pieces kept in the root -------------------------------------------------

def _module_call() -> str:
    text = _texts(AA365)["environment.tf"]
    m = re.search(r'^module "environment" \{\n(.*?)^\}', text, re.M | re.S)
    assert m, "module \"environment\" block not found"
    return m.group(1)


def _inputs() -> dict[str, str]:
    return {k: v.strip() for k, v in re.findall(r"^\s{2}([a-z0-9_]+)\s*=\s*(.+)$", _module_call(), re.M)}


def _variable_blocks(d: Path) -> dict[str, str]:
    out = {}
    for f in sorted(d.glob("*.tf")):
        text = f.read_text(encoding="utf-8")
        for m in re.finditer(r'^variable "([a-z0-9_]+)" \{\n.*?^\}$', text, re.M | re.S):
            out[m.group(1)] = m.group(0)
    return out


def test_slice_2_inputs_pass_the_exact_root_expression():
    inputs = _inputs()
    module_vars = _variable_blocks(ENV_MODULE)
    for name, expr in SLICE_2_INPUTS.items():
        assert name in module_vars, f"modules/environment declares no variable {name}"
        assert inputs.get(name) == expr, f"{name}: the root passes {inputs.get(name)!r}, the moved code read {expr!r}"


def test_slice_2_settings_are_declared_identically_and_passed_through():
    root_vars, module_vars, inputs = _variable_blocks(AA365), _variable_blocks(ENV_MODULE), _inputs()
    for name in sorted(SLICE_2_SETTINGS):
        assert name in root_vars and name in module_vars, f"{name}: declared in the root and in the module"
        assert root_vars[name] == module_vars[name], f"{name}: root and module declarations differ"
        assert inputs.get(name) == f"var.{name}", f"{name}: passed through as var.{name}"
    # Every CRM setting of the module is one of these (a new one must be added to the root and passed through too).
    assert {n for n in module_vars if n.startswith("crm_") and n not in SLICE_2_INPUTS} == SLICE_2_SETTINGS


def test_every_module_variable_without_a_default_is_passed():
    inputs = _inputs()
    for name, block in _variable_blocks(ENV_MODULE).items():
        if not re.search(r"^\s*default\s*=", block, re.M):
            assert name in inputs, f"modules/environment variable {name} has no default and the root does not pass it"


def test_the_crm_module_files_read_no_root_object():
    # Root-only addresses must arrive as inputs (terraform validate would fail too; this names the file and line).
    root_only = re.compile(r"\b(module\.[a-z_]+\.|time_sleep\.|random_password\.|aws_iam_policy\.workload_boundary|"
                           r"aws_iam_openid_connect_provider\.|aws_sns_topic\.alerts|aws_cognito_|aws_route53_zone\.|"
                           r"aws_ses_receipt_rule|aws_security_group\.|local\.(alb_|id_custom|idpartner_|ecosys_tags|"
                           r"runbook_suffix|crm_edge_on|crm_partner_host|crm_agency_host|crm_client_hosts|crm_intake))")
    for name, text in _texts(ENV_MODULE).items():
        if not name.startswith("crm_"):
            continue
        for i, line in enumerate(text.splitlines(), 1):
            if re.match(r"^\s*description\s*=", line):
                continue  # a variable description may name the root object it carries
            assert not root_only.search(line), f"modules/environment/{name}:{i}: {line.strip()}"


def test_crm_pieces_kept_in_the_root():
    root = _resources(AA365)
    for addr in ("aws_lb_listener_rule.crm_api", "aws_route53_record.crm_ingest_mx", "aws_ses_receipt_rule.crm_ingest"):
        assert addr in root, f"{addr} must stay in accounts/aa365"
        assert addr not in _resources(ENV_MODULE), f"{addr} must not be in modules/environment"
    alb = _texts(AA365)["alb_rules.tf"]
    assert re.search(r'^resource "aws_lb_listener_rule" "crm_api" \{', alb, re.M), "crm_api rule lives in alb_rules.tf"
    receipt = _texts(AA365)["crm_mail_receipt.tf"]
    for res in ('resource "aws_route53_record" "crm_ingest_mx"', 'resource "aws_ses_receipt_rule" "crm_ingest"'):
        assert res in receipt
    # The receipt values carry the old depends_on (bucket policy + ingest key) through the module output.
    out = _texts(ENV_MODULE)["crm_outputs.tf"]
    m = re.search(r'^output "crm_ingest_receipt" \{\n(.*?)^\}', out, re.M | re.S)
    assert m and "depends_on = [aws_s3_bucket_policy.crm, aws_kms_key.crm_ingest]" in m.group(1)


def test_crm_deploy_role_context_is_the_module_environment():
    app = _texts(ENV_MODULE)["crm_app.tf"]
    assert re.search(r'^\s*crm_oidc_contexts\s*=\s*\["environment:\$\{var\.environment\}"\]\s*$', app, re.M)


# --- slice 3 (TripPlanner): value equality, settings, the pieces kept in the root -----------------------------------

def test_slice_3_inputs_pass_the_exact_root_expression():
    inputs = _inputs()
    module_vars = _variable_blocks(ENV_MODULE)
    for name, expr in SLICE_3_INPUTS.items():
        assert name in module_vars, f"modules/environment declares no variable {name}"
        assert inputs.get(name) == expr, f"{name}: the root passes {inputs.get(name)!r}, the moved code read {expr!r}"


def test_slice_3_settings_are_declared_identically_and_passed_through():
    root_vars, module_vars, inputs = _variable_blocks(AA365), _variable_blocks(ENV_MODULE), _inputs()
    for name in sorted(SLICE_3_SETTINGS):
        assert name in root_vars and name in module_vars, f"{name}: declared in the root and in the module"
        assert root_vars[name] == module_vars[name], f"{name}: root and module declarations differ"
        assert inputs.get(name) == f"var.{name}", f"{name}: passed through as var.{name}"
    # Every TripPlanner setting of either side is one of these (a new one must be declared on both sides and passed).
    assert {n for n in module_vars if n.startswith("tripplanner_") and n not in SLICE_3_INPUTS} == SLICE_3_SETTINGS
    assert {n for n in root_vars if n.startswith("tripplanner_")} == SLICE_3_SETTINGS


def test_the_tripplanner_module_files_read_no_root_object():
    root_only = re.compile(r"\b(module\.[a-z_]+\.|time_sleep\.|aws_iam_policy\.workload_boundary|"
                           r"aws_iam_openid_connect_provider\.|aws_sns_topic\.alerts|aws_security_group\.|"
                           r"aws_cognito_|aws_route53_zone\.|local\.(bedrock_acct_primary|runbook_suffix|ecosys_tags|"
                           r"name_prefix\b))")
    for name, text in _texts(ENV_MODULE).items():
        if not name.startswith("tripplanner"):
            continue
        for i, line in enumerate(text.splitlines(), 1):
            if re.match(r"^\s*description\s*=", line):
                continue
            assert not root_only.search(line), f"modules/environment/{name}:{i}: {line.strip()}"
        # path.module inside the module would point at modules/environment: the placeholder path is an input.
        assert "path.module" not in text, f"modules/environment/{name}: path.module (pass the root path in instead)"


def test_the_satellite_invoker_is_built_from_the_input():
    tp = _texts(ENV_MODULE)["tripplanner.tf"]
    assert '"arn:aws:iam::${var.bedrock_acct_primary}:role/AA3-Bedrock-Invoker"' in tp
    assert len(re.findall(r"BEDROCK_ACCT_PRIMARY\s*=\s*var\.bedrock_acct_primary", tp)) == 2


def test_tripplanner_pieces_kept_in_the_root():
    root, module = _resources(AA365), _resources(ENV_MODULE)
    kept = (
        "aws_security_group.tp_lambda",
        "aws_iam_role_policy.tripplanner_lambda_ses_send",
        "aws_cloudwatch_log_group.tripplanner_lambda",
        "aws_cloudwatch_metric_alarm.tripplanner_lambda_errors",
        "aws_cloudwatch_metric_alarm.tripplanner_lambda_throttles",
        "aws_apigatewayv2_domain_name.tripplanner",
        "aws_apigatewayv2_api_mapping.tripplanner",
        "aws_route53_record.tripplanner_api",
    )
    for addr in kept:
        assert addr in root, f"{addr} must stay in accounts/aa365"
        assert addr not in module, f"{addr} must not be in modules/environment"
    removed = _texts(AA365)["tripplanner_removed.tf"]
    for addr in ("aws_secretsmanager_secret.tripplanner_mapbox", "aws_secretsmanager_secret_version.tripplanner_mapbox"):
        assert re.search(r"removed \{\s*from\s*=\s*" + re.escape(addr) + r"\s", removed), f"removed block {addr}"
    assert not any("removed {" in text for name, text in _texts(ENV_MODULE).items() if name.startswith("tripplanner"))
    # The root files that read the moved objects now read module outputs (a stale direct reference fails validate too).
    stale = re.compile(r"\b(aws_(lambda_function|apigatewayv2_api|apigatewayv2_stage|iam_role|secretsmanager_secret)"
                       r"\.tripplanner_?[a-z_]*\.)")
    for name, text in _texts(AA365).items():
        hits = [m.group(1) for m in stale.finditer(text)]
        assert not hits, f"accounts/aa365/{name} still reads a moved TripPlanner resource: {hits}"


def test_tripplanner_root_outputs_are_reexported():
    env = _texts(AA365)["environment.tf"]
    for name in sorted(SLICE_3_OUTPUTS):
        m = re.search(r'^output "' + name + r'" \{\n(.*?)^\}', env, re.M | re.S)
        assert m, f"environment.tf does not re-export {name}"
        assert f"module.environment.{name}" in m.group(1), f"{name}: must read module.environment.{name}"
    module_outputs = {n for text in _texts(ENV_MODULE).values() for n in re.findall(r'^output "([a-z0-9_]+)"', text, re.M)}
    assert SLICE_3_OUTPUTS <= module_outputs


def test_the_module_declares_the_random_provider():
    versions = _texts(ENV_MODULE)["versions.tf"]
    assert re.search(r'random\s*=\s*\{\s*source\s*=\s*"hashicorp/random"', versions)
