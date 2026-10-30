"""Static tests of the management account CI wiring (AA-1004, accounts/management/README.md §11).

Offline: reads accounts/management/cicd.tf and the three Terraform workflows; no Terraform, no AWS. Run from the repo
root: python3 -m pytest -p no:cacheprovider -q tools/terraform/tests
"""
from __future__ import annotations

import os
import re

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
MGMT = os.path.join(REPO_ROOT, "accounts", "management")
WORKFLOWS = os.path.join(REPO_ROOT, ".github", "workflows")


def _wf(name: str) -> dict:
    with open(os.path.join(WORKFLOWS, name), encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def _wf_text(name: str) -> str:
    with open(os.path.join(WORKFLOWS, name), encoding="utf-8") as fh:
        return fh.read()


def _cicd() -> str:
    with open(os.path.join(MGMT, "cicd.tf"), encoding="utf-8") as fh:
        return fh.read()


def _resource(text: str, rtype: str, name: str) -> str:
    start = text.index(f'resource "{rtype}" "{name}" {{')
    m = re.compile(r"\n(?:resource|data|output|variable|locals) ").search(text, start + 1)
    return text[start:] if m is None else text[start:m.start()]


def _steps(job: dict) -> dict:
    return {s.get("name", s.get("uses", "")): s for s in job["steps"]}


# --- cicd.tf ---------------------------------------------------------------------------------------------------------

def test_no_account_id_is_committed_in_the_management_root():
    for name in os.listdir(MGMT):
        if name.endswith((".tf", ".example", ".tftpl")):
            with open(os.path.join(MGMT, name), encoding="utf-8") as fh:
                assert not re.search(r"(?<![0-9])\d{12}(?![0-9])", fh.read()), name


def test_plan_role_trusts_only_pull_request_and_main():
    role = _resource(_cicd(), "aws_iam_role", "ci_plan")
    subs = re.findall(r'"\$\{var\.github_oidc_subject_prefix\}:([^"]+)"', role)
    assert subs == ["pull_request", "ref:refs/heads/main"]
    assert "max_session_duration = 3600" in role
    assert "environment:" not in role


def test_apply_role_trusts_only_environment_org_on_main_and_has_a_boundary():
    role = _resource(_cicd(), "aws_iam_role", "ci_apply")
    subs = re.findall(r'"\$\{var\.github_oidc_subject_prefix\}:([^"]+)"', role)
    assert subs == ["environment:org"]
    assert '"token.actions.githubusercontent.com:ref" = "refs/heads/main"' in role
    assert "permissions_boundary = aws_iam_policy.ci_apply_boundary.arn" in role
    assert "max_session_duration = 3600" in role


def test_role_names_match_the_scp_exemption():
    # SCP 2 exempts aa-terraform-apply (variables.tf); the plan role must not be exempt.
    text = _cicd()
    assert 'ci_plan_role_name  = "aa-terraform-plan"' in text
    assert 'ci_apply_role_name = "aa-terraform-apply"' in text
    with open(os.path.join(MGMT, "variables.tf"), encoding="utf-8") as fh:
        variables = fh.read()
    assert '"arn:aws:iam::*:role/aa-terraform-apply"' in variables
    assert "aa-terraform-plan" not in variables


def test_plan_role_writes_only_the_lockfile():
    policy = _resource(_cicd(), "aws_iam_role_policy", "ci_plan")
    writes = re.findall(r'"([a-z0-9-]+:(?:Put|Delete|Create|Update|Attach|Detach|Tag|Untag|Modify)[A-Za-z*]*)"', policy)
    assert sorted(writes) == ["s3:DeleteObject", "s3:PutObject"]
    assert "policy/AdministratorAccess" not in _cicd()


def test_apply_boundary_keeps_ci_off_its_own_roles_and_the_org_exits():
    text = _cicd()
    for needle in ("DenyAllRoleWrites", "DenyOidcProviderWrites", "DenySamlProviderWrites", "organizations:LeaveOrganization", "organizations:CloseAccount",
                   "organizations:RemoveAccountFromOrganization", "organizations:DeleteOrganization",
                   "cloudtrail:StopLogging", "s3:BypassGovernanceRetention", "sts:AssumeRoot", "iam:CreatePolicy"):
        assert needle in text, needle


# --- workflows -------------------------------------------------------------------------------------------------------

def test_pr_plan_job_for_management_is_read_only_and_summary_only():
    wf = _wf("terraform-plan.yml")
    assert wf["jobs"]["terraform-plan"]["name"] == "Terraform Plan (dev)"  # the required check keeps its name
    job = wf["jobs"]["terraform-plan-management"]
    assert "environment" not in job  # sub `pull_request` = the read-only plan role only
    steps = _steps(job)
    creds = steps["Configure AWS credentials (OIDC, management plan role)"]["with"]["role-to-assume"]
    assert creds.endswith(":role/aa-terraform-plan")
    assert "*:assumed-role/aa-terraform-plan/*" in steps["Verify the role is the management plan role"]["run"]
    assert steps["Setup Terraform"]["with"]["terraform_wrapper"] is False
    plan = steps["Terraform Plan (summary only)"]["run"]
    for flag in ("-json", "--mode plan", "umask 077", "trap 'rm -f", "tools/terraform/drift_report.py"):
        assert flag in plan, flag
    assert "accounts/management/" in steps["Changed paths"]["run"]


def test_apply_job_for_management_runs_in_org_with_the_guard_before_the_apply():
    wf = _wf("terraform-apply.yml")
    on = wf.get("on", wf.get(True))
    root = on["workflow_dispatch"]["inputs"]["root"]
    assert root["default"] == "aa365" and root["options"] == ["aa365", "management"]
    aa365 = wf["jobs"]["terraform-apply"]
    assert "inputs.root != 'management'" in aa365["if"] and aa365["environment"] == "prod"
    job = wf["jobs"]["terraform-apply-management"]
    assert job["environment"] == "org"
    assert "github.ref == 'refs/heads/main'" in job["if"] and "inputs.root == 'management'" in job["if"]
    names = [s.get("name") for s in job["steps"]]
    assert names.index("Plan guard") < names.index("Terraform Apply")
    steps = _steps(job)
    assert steps["Configure AWS credentials (OIDC, management apply role)"]["with"]["role-to-assume"].endswith(
        ":role/aa-terraform-apply")
    apply = steps["Terraform Apply"]
    assert apply["if"] == "steps.plan.outputs.exitcode == '2'"
    for step in (apply, steps["Plan guard"]):
        assert "continue-on-error" not in step
        for word in ("always()", "failure()"):
            assert word not in str(step.get("if", ""))
    assert "tools/terraform/plan_guard.py" in steps["Plan guard"]["run"]
    assert "--mode apply" in apply["run"] and "-json" in apply["run"]
    assert "--mode plan" in steps["Terraform Plan"]["run"] and "-json" in steps["Terraform Plan"]["run"]
    # This root's plan text and outputs never reach the public log.
    job_text = yaml.safe_dump(job)
    assert "terraform output" not in job_text
    assert steps["Setup Terraform"]["with"]["terraform_wrapper"] is False


def test_drift_matrix_runs_management_with_its_own_plan_role():
    text = _wf_text("terraform-drift.yml")
    job = _wf("terraform-drift.yml")["jobs"]["drift"]
    roots = {e["root"]: e["state_key"] for e in job["strategy"]["matrix"]["include"]}
    assert roots["accounts/management"] == "management/terraform.tfstate"
    assert "*:assumed-role/aa-terraform-plan/*" in text
    assert "role/aa-terraform-plan" in text


def test_management_inputs_are_masked_and_never_set_a_profile():
    for name, job in (("terraform-plan.yml", "terraform-plan-management"),
                      ("terraform-apply.yml", "terraform-apply-management"),
                      ("terraform-drift.yml", "drift")):
        step = _steps(_wf(name)["jobs"][job])["Write management inputs (masked)"]["run"]
        for needle in ("umask 077", "::add-mask::", "aws_profile", "TF_CLI_ARGS_plan=-var-file=", "$RUNNER_TEMP"):
            assert needle in step, (name, needle)


# --- review fixes (S259) ---------------------------------------------------------------------------------------------

def _boundary_statement(text: str, sid: str) -> str:
    start = text.index(f'sid       = "{sid}"')
    return text[start:text.index("}", start)]


def test_ci_apply_cannot_write_any_role_including_identity_center_ones():
    text = _cicd()
    deny = _boundary_statement(text, "DenyAllRoleWrites")
    assert 'resources = ["*"]' in deny and "not_resources" not in deny
    role_writes = text.split("ci_role_write_actions = [", 1)[1].split("]", 1)[0]
    for action in ("iam:UpdateAssumeRolePolicy", "iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy",
                   "iam:DetachRolePolicy", "iam:DeleteRolePolicy", "iam:PutRolePermissionsBoundary", "iam:PassRole"):
        assert f'"{action}"' in role_writes, action
    saml = _boundary_statement(text, "DenySamlProviderWrites")
    assert 'resources = ["*"]' in saml
    # The apply role's own policy grants no IAM role or SAML write at all, and nothing on the aws-reserved path.
    inline = _resource(text, "aws_iam_role_policy", "ci_apply")
    assert "aws-reserved" not in inline and "saml-provider" not in inline
    for action in ("iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
                   "iam:DeleteRolePolicy", "iam:PutRolePermissionsBoundary", "iam:UpdateAssumeRolePolicy",
                   "iam:PassRole", "iam:CreateSAMLProvider"):
        assert f'"{action}"' not in inline, action


def test_apply_is_preceded_by_a_read_only_review_plan_with_a_digest():
    jobs = _wf("terraform-apply.yml")["jobs"]
    review = jobs["plan-management"]
    assert "environment" not in review  # sub ref:refs/heads/main = the read-only plan role
    rsteps = _steps(review)
    assert rsteps["Configure AWS credentials (OIDC, management plan role)"]["with"]["role-to-assume"].endswith(
        ":role/aa-terraform-plan")
    assert "--digest-out" in rsteps["Terraform Plan (for review)"]["run"]
    assert review["outputs"]["digest"] == "${{ steps.plan.outputs.digest }}"
    apply = jobs["terraform-apply-management"]
    assert apply["needs"] == "plan-management"
    assert apply["env"]["REVIEWED_DIGEST"] == "${{ needs.plan-management.outputs.digest }}"
    plan = _steps(apply)["Terraform Plan"]["run"]
    assert "--digest-out" in plan and '!= "$REVIEWED_DIGEST"' in plan and "exit 1" in plan


def test_apply_checks_the_org_environment_before_any_secret_or_credential():
    apply = _wf("terraform-apply.yml")["jobs"]["terraform-apply-management"]
    first = apply["steps"][0]
    assert first["name"] == "Check the org environment is protected"
    assert "repos/$REPO/environments/org" in first["run"] and "required_reviewers" in first["run"]
    assert "deployment_branch_policy" in first["run"]
    assert "secrets." not in yaml.safe_dump(first)
    assert apply["permissions"] == {"id-token": "write", "contents": "read", "actions": "read"}


def test_missing_secrets_fail_once_mgmt_ci_live_is_set():
    for name, job in (("terraform-plan.yml", "terraform-plan-management"), ("terraform-drift.yml", "drift")):
        step = _steps(_wf(name)["jobs"][job])["Check CI wiring"]
        assert step["env"]["MGMT_CI_LIVE"] == "${{ vars.MGMT_CI_LIVE }}"
        assert '"$MGMT_CI_LIVE" = "true"' in step["run"] and "exit 1" in step["run"]


def test_sso_user_keys_are_handles_and_the_techlead_key_is_moved():
    with open(os.path.join(MGMT, "variables.tf"), encoding="utf-8") as fh:
        assert 'can(regex("^u[0-9]+$", k))' in fh.read()
    with open(os.path.join(MGMT, "identity_center.tf"), encoding="utf-8") as fh:
        ic = fh.read()
    for rtype in ("aws_identitystore_user", "aws_identitystore_group_membership"):
        assert f'from = {rtype}.this["techlead"]' in ic and f'to   = {rtype}.this["u1"]' in ic
