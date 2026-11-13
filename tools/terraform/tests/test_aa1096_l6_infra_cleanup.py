"""AA-1096 lane L6 (S279 thresholds audit, root docs/audits/2026-11-13-S279-session/thresholds-audit/): the Infra side
of "every threshold editable on an admin page".

Offline, no Terraform run, no AWS: reads the .tf files (comments stripped) and the migration copies in db/migrations.
What must hold:
1. No task definition or Lambda sets the env var of an admin-editable setting. Each app's settings reader serves a
   definition's env_override FIRST, so a Terraform-set override hides the admin page's value. The names come from the
   migration copies ("env_override": "<NAME>" in every owner's setting_definition seed) plus the env vars the apps no
   longer read or read only as a fallback. The one exception, ERASURE_TENANT_RETENTION_DAYS, is set only while the Dev
   erasure drill is on (variable null otherwise).
2. Dead config is gone: the four API Gateway usage plans and SF_BATCH_THRESHOLD.
3. The edge literals are variables with the values in force: the WAF RateLimit1000 rule, the CIS and Booking REST API
   stage throttles, the CRM SLO thresholds.
4. Output platform_limits publishes the edge, budget and alarm values: values only, never an ID, ARN or account.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
MODULES = ROOT / "modules"
MIGRATIONS = ROOT / "db" / "migrations"


def _code(text: str) -> str:
    """The text without # comments, so a name mentioned in a comment does not count."""
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _tf_files() -> list[Path]:
    return sorted(list(AA365.glob("*.tf")) + list(MODULES.rglob("*.tf")))


def _block(text: str, header: str) -> str:
    start = text.index(header)
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[start : j + 1]
    raise AssertionError(f"unbalanced braces after {header}")


def _variable_default(text: str, name: str) -> str:
    block = _block(text, f'variable "{name}" {{')
    m = re.search(r"^\s*default\s*=\s*(\S+)\s*$", block, re.M)
    assert m, f"variable {name} has no one-line default"
    return m.group(1)


# --- 1. no env override of a setting in Terraform ---------------------------------------------------------------------

ENV_OVERRIDE_RE = re.compile(r'"env_override":\s*"([A-Z][A-Z0-9_]+)"')

# Env vars the apps no longer read (their value is a setting with no env override) or read only as a fallback behind
# the settings view (TripPlanner, CIS 414 / backend/shared/settings.py and app_profile.py).
NO_LONGER_SET = {
    "T7_BLOG_MIN_SEED_WORDS",           # CIS cis.t7.blog_min_seed_words (407)
    "T2_JUDGE_GATE",                    # CIS cis.quality_modes.t2_judge_gate (412)
    "T3_BACKGROUND_FACTS",              # CIS cis.quality_modes.t3_background_facts (412)
    "AUTO_UPGRADE_THRESHOLD",           # CIS 412
    "TP_DAILY_SPEND_CAP_USD",           # CIS app profile tripplanner.default_daily_budget_usd (414)
    "REQUIRE_REGISTRATION_BEFORE_HANDOFF", "ADVISOR_HANDOFF_DEMO",
    "TP_RATE_NARRATE_PER_HOUR", "TP_RATE_SEARCH_PER_MINUTE", "TP_RATE_SIGNED_IN_FACTOR", "TP_RATE_SEND_PER_HOUR",
    "TP_RATE_SEND_IP_PER_HOUR", "TP_RATE_CHAT_PER_HOUR", "TP_RATE_CHAT_IP_PER_HOUR",
    "TP_PLAN_CHAT_MONTHLY_CAP_USD", "TP_PLAN_CHAT_TENANT_MONTHLY_CAP_USD", "TP_LEAD_TENANT_DAILY_CAP",
    "TP_LEAD_HOLD_DAYS", "NARRATION_CACHE_TTL_HOURS",
    "SF_BATCH_THRESHOLD",               # no reader in any repo
}
# Set only under a condition that is off outside a drill.
DRILL_ONLY = {"ERASURE_TENANT_RETENTION_DAYS"}


def _setting_env_overrides() -> set[str]:
    names: set[str] = set()
    for f in MIGRATIONS.rglob("*.sql"):
        names.update(ENV_OVERRIDE_RE.findall(_read(f)))
    return names


def test_the_migration_copies_name_the_known_overrides():
    names = _setting_env_overrides()
    # A sample from three owners, so a parser break cannot pass the guard below silently.
    for name in ("ERASURE_TENANT_RETENTION_DAYS", "T10_SA_MODE", "RATE_LIMIT_PUBLIC_PER_MINUTE", "CRM_LLM_MAX_TOKENS",
                 "RATE_LIMIT_INTAKE_FORM_PER_HOUR"):
        assert name in names, f"{name} not found in db/migrations (env_override)"


def test_no_terraform_file_sets_a_settings_env_var():
    forbidden = (_setting_env_overrides() | NO_LONGER_SET) - DRILL_ONLY
    hits = []
    for f in _tf_files():
        code = _code(_read(f))
        for name in sorted(forbidden):
            if re.search(rf"\b{name}\b", code):
                hits.append(f"{f.relative_to(ROOT)}: {name}")
    assert not hits, "env var of an admin-editable setting set in Terraform:\n" + "\n".join(hits)


def test_the_erasure_retention_env_is_set_only_during_the_drill():
    ecs = _code(_read(MODULES / "ecs" / "main.tf"))
    start = ecs.index("erasure_env = concat(")
    local = ecs[start : ecs.index("\n  )\n", start)]
    assert "var.erasure_tenant_retention_days != null ? [" in local
    assert '{ name = "ERASURE_TENANT_RETENTION_DAYS", value = tostring(var.erasure_tenant_retention_days) }' in local
    assert ecs.count("ERASURE_TENANT_RETENTION_DAYS") == 1
    var = _block(_read(MODULES / "ecs" / "variables.tf"), 'variable "erasure_tenant_retention_days" {')
    assert re.search(r"^\s*default\s*=\s*null\s*$", var, re.M)
    assert "nullable    = false" not in var
    main = _code(_read(AA365 / "main.tf"))
    assert re.search(r"^\s*erasure_tenant_retention_days\s*=\s*local\.erasure_drill \? 0 : null\s*$", main, re.M)


def test_the_t2_anchor_switch_stays_on_the_worker():
    # T2_JUDGE_ANCHORS is still an env switch of the app (judge_node.py); only the gate became a setting.
    worker = _code(_block(_read(MODULES / "ecs" / "main.tf"), 'resource "aws_ecs_task_definition" "worker" {'))
    assert '{ name = "T2_JUDGE_ANCHORS", value = "on" }' in worker


def test_the_crm_dry_run_floors_stay_in_terraform():
    # Tech lead S279 Q7: Terraform keeps a hard never-delete floor under the CRM's admin dry-run switches.
    app = _code(_read(MODULES / "environment" / "crm_app.tf"))
    for name in ("JOB_RETENTION_DRY_RUN", "LIFECYCLE_DRY_RUN", "AUDIT_RETENTION_DRY_RUN", "PARTNER_ACCOUNT_CLEANUP_DRY_RUN"):
        assert f'{{ name = "{name}"' in app, name


# --- 2. dead config --------------------------------------------------------------------------------------------------

def test_no_api_gateway_usage_plan_is_declared():
    for f in _tf_files():
        assert "aws_api_gateway_usage_plan" not in _code(_read(f)), f.relative_to(ROOT)


def test_sf_batch_threshold_is_gone():
    for f in _tf_files():
        code = _code(_read(f))
        assert "sf_batch_threshold" not in code and "SF_BATCH_THRESHOLD" not in code, f.relative_to(ROOT)


def test_the_tripplanner_cap_variable_is_gone():
    for f in _tf_files():
        assert "tripplanner_daily_spend_cap_usd" not in _code(_read(f)), f.relative_to(ROOT)


# --- 3. literals are variables, same values --------------------------------------------------------------------------

def test_the_waf_rate_limit_is_a_variable():
    main = _code(_read(AA365 / "main.tf"))
    waf = _block(main, 'module "waf" {')
    assert re.search(r"^\s*rate_limit\s*=\s*var\.waf_rate_limit\s*$", waf, re.M)
    assert _variable_default(_read(AA365 / "variables.tf"), "waf_rate_limit") == "1000"


CIS_THROTTLES = {
    "stage_throttle_rate_limit": ("cis_api_stage_throttle_rate_limit", "50"),
    "stage_throttle_burst_limit": ("cis_api_stage_throttle_burst_limit", "100"),
    "login_throttle_rate_limit": ("cis_api_login_throttle_rate_limit", "20"),
    "login_throttle_burst_limit": ("cis_api_login_throttle_burst_limit", "40"),
    "content_throttle_rate_limit": ("cis_api_content_throttle_rate_limit", "300"),
    "content_throttle_burst_limit": ("cis_api_content_throttle_burst_limit", "600"),
}


def test_the_cis_stage_throttles_are_variables_with_the_values_in_force():
    api = _block(_code(_read(AA365 / "main.tf")), 'module "api_gateway" {')
    variables = _read(AA365 / "variables.tf")
    for arg, (var, value) in CIS_THROTTLES.items():
        assert re.search(rf"^\s*{arg}\s*=\s*var\.{var}\s*$", api, re.M), arg
        assert _variable_default(variables, var) == value, var


def test_the_booking_stage_throttle_is_a_variable():
    booking = _code(_read(MODULES / "environment" / "booking.tf"))
    settings = _block(booking, 'resource "aws_api_gateway_method_settings" "booking_throttle" {')
    assert "throttling_rate_limit  = var.booking_throttle_rate_limit" in settings
    assert "throttling_burst_limit = var.booking_throttle_burst_limit" in settings
    root, module = _read(AA365 / "booking_variables.tf"), _read(MODULES / "environment" / "booking_variables.tf")
    for name, value in (("booking_throttle_rate_limit", "20"), ("booking_throttle_burst_limit", "40")):
        assert _block(root, f'variable "{name}" {{') == _block(module, f'variable "{name}" {{'), name
        assert _variable_default(module, name) == value
        assert re.search(rf"^\s*{name}\s*=\s*var\.{name}\s*$", _read(AA365 / "environment.tf"), re.M), name


def test_the_crm_slo_thresholds_are_a_variable_with_the_values_in_force():
    slo = _read(MODULES / "environment" / "crm_slo.tf")
    module_var = _block(slo, 'variable "crm_slo" {')
    assert module_var == _block(_read(AA365 / "crm_variables.tf"), 'variable "crm_slo" {')
    default = _block(module_var, "default = {")
    for key, value in (("five_xx_percent", "2"), ("min_requests", "20"), ("p95_latency_s", "1.5"),
                       ("alarm_periods", "3"), ("alarm_breaching", "2")):
        assert re.search(rf"^\s*{key}\s*=\s*{re.escape(value)}\s*$", default, re.M), key
    locals_block = _block(_code(slo), "locals {")
    assert not re.search(r"=\s*[0-9]", locals_block), "the SLO locals read var.crm_slo, no literal"
    assert re.search(r"^\s*crm_slo\s*=\s*var\.crm_slo\s*$", _read(AA365 / "environment.tf"), re.M)


# --- 4. the read-only output -----------------------------------------------------------------------------------------

def test_platform_limits_publishes_values_only():
    text = _read(AA365 / "outputs_platform_limits.tf")
    out = _code(_block(text, 'output "platform_limits" {'))
    for group in ("waf", "api_gateway_throttles", "lambda_reserved_concurrency", "budgets", "alarms"):
        assert re.search(rf"^\s*{group}\s*=\s*\{{", out, re.M), group
    assert not re.search(r"\b\d{12}\b", text), "no account id"
    assert not re.search(r"\.(arn|id|arn_suffix|name|address|endpoint|dns_name)\b", out), "no ID, ARN or name"
    assert "account_id" not in out and "sensitive" not in out
    # Every var it reads is declared in the root (terraform validate checks it too; this names the variable).
    declared = set(re.findall(r'^variable "([a-z0-9_]+)"', "\n".join(_read(f) for f in AA365.glob("*.tf")), re.M))
    for name in set(re.findall(r"\bvar\.([a-z0-9_]+)", out)):
        assert name in declared, name


def test_the_waf_module_exports_the_geo_list():
    outputs = _read(MODULES / "waf" / "outputs.tf")
    assert "value       = var.geo_allowed_countries" in _block(outputs, 'output "geo_allowed_countries" {')
