"""Static tests of the organization admin path and the Transitional OU (AA-1004, S273, Billing Transfer of 01/12/2026).

What they hold:
  - accounts/aa365/org_access.tf: OrganizationAccountAccessRole trusts exactly the management account's
    aa-org-member-access role (never an account root), with aws:PrincipalOrgID; no account or organization ID is
    committed; a plan without the two IDs fails instead of planning a destroy; the role cannot be destroyed by a plan.
  - the three Terraform workflows pass both IDs to every aa365 plan from secrets (masked), never from repo variables.
  - accounts/management/org_member_access.tf: aa-org-member-access trusts only Identity Center AA-Admin sessions of
    the management account and may only assume OrganizationAccountAccessRole.
  - accounts/management/scp.tf: OU Transitional carries SCP 1 only, the other OUs all three, and the attachment keys
    of the existing OUs are unchanged (no replace in the plan).

Offline: reads the .tf files and the workflows; no Terraform, no AWS. Run from the repo root:
python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1004_org_access.py
"""
from __future__ import annotations

import os
import re

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
AA365 = os.path.join(REPO_ROOT, "accounts", "aa365")
MGMT = os.path.join(REPO_ROOT, "accounts", "management")
WORKFLOWS = os.path.join(REPO_ROOT, ".github", "workflows")

ACCOUNT_ID = re.compile(r"(?<![0-9])\d{12}(?![0-9])")
ORG_ID = re.compile(r"\bo-[a-z0-9]{10,32}\b")
BROKER = "aa-org-member-access"
MEMBER_ROLE = "OrganizationAccountAccessRole"


def _read(*parts: str) -> str:
    with open(os.path.join(*parts), encoding="utf-8") as fh:
        return fh.read()


def _strip_comments(text: str) -> str:
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def _block(text: str, header: str) -> str:
    start = text.index(header)
    m = re.compile(r"\n(?:resource|data|output|variable|locals|import) ").search(text, start + 1)
    return text[start:] if m is None else text[start:m.start()]


def _org_access() -> str:
    return _read(AA365, "org_access.tf")


def _member_access() -> str:
    return _read(MGMT, "org_member_access.tf")


# --- accounts/aa365/org_access.tf ------------------------------------------------------------------------------------

def test_member_role_trusts_only_the_named_broker_role_with_the_org_condition():
    trust = _block(_org_access(), 'data "aws_iam_policy_document" "org_access_trust" {')
    identifiers = re.findall(r"identifiers\s*=\s*\[([^\]]*)\]", trust)
    assert identifiers == ['"arn:aws:iam::${var.org_management_account_id}:role/' + BROKER + '"']
    assert ":root" not in _strip_comments(trust)
    assert '"aws:PrincipalOrgID"' in trust and "var.org_management_org_id" in trust
    assert re.search(r'actions\s*=\s*\["sts:AssumeRole"\]', trust)


def test_broker_name_is_the_same_on_both_sides():
    assert re.search(r'org_member_access_role_name\s*=\s*"' + BROKER + '"', _member_access())
    assert re.search(r'org_member_role_name\s*=\s*"' + MEMBER_ROLE + '"', _member_access())
    assert re.search(r'variable "org_access_role_name" \{[^}]*default\s*=\s*"' + MEMBER_ROLE + '"', _org_access(), re.S)


def test_member_role_name_is_exempt_in_scp_2():
    # SCP 2 protects the exempt roles: only they may edit them. The member role must be one of them, or nobody could
    # change its trust once the account sits in an OU with SCP 2.
    default = _block(_read(MGMT, "variables.tf"), 'variable "scp_exempt_role_arn_patterns" {')
    assert f'"arn:aws:iam::*:role/{MEMBER_ROLE}"' in default


def test_member_role_shape():
    role = _block(_org_access(), 'resource "aws_iam_role" "org_access" {')
    assert "count = local.org_access_count" in role
    assert "max_session_duration = 3600" in role
    assert "prevent_destroy = true" in role
    # Deliberately no workload boundary: it denies the IAM / organization writes this role exists for.
    assert "permissions_boundary" not in _strip_comments(role)
    assert 'Component = "governance"' in role and 'App = "ecosystem"' in role
    attach = _block(_org_access(), 'resource "aws_iam_role_policy_attachments_exclusive" "org_access" {')
    assert re.search(r'policy_arns\s*=\s*\["arn:aws:iam::aws:policy/AdministratorAccess"\]', attach)
    inline = _block(_org_access(), 'resource "aws_iam_role_policies_exclusive" "org_access" {')
    assert "aws_iam_role_policy.org_access_guard[0].name" in inline


def test_member_role_denies_long_lived_credentials():
    guard = _block(_org_access(), 'data "aws_iam_policy_document" "org_access_guard" {')
    assert 'effect    = "Deny"' in guard
    for action in ("iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile"):
        assert f'"{action}"' in _org_access()


def test_missing_ids_fail_the_plan_instead_of_destroying():
    text = _org_access()
    for var in ("org_management_account_id", "org_management_org_id"):
        block = _block(text, f'variable "{var}" {{')
        assert "default     = null" in block
        assert f"var.{var} == null ? !var.org_access_role_enabled" in block


def test_adoption_import_is_gated():
    imp = _block(_org_access(), "import {")
    assert "var.org_access_role_enabled && var.org_access_adopt_existing_role" in imp
    assert "to       = aws_iam_role.org_access[0]" in imp


def test_no_id_is_committed_for_the_org_access_inputs():
    text = _org_access()
    assert not ACCOUNT_ID.search(text) and not ORG_ID.search(text)
    tfvars = _read(AA365, "terraform.tfvars")
    assert re.search(r"^org_access_role_enabled\s*=\s*(true|false)\s*$", tfvars, re.M)
    for var in ("org_management_account_id", "org_management_org_id"):
        assert not re.search(rf"^\s*{var}\s*=", tfvars, re.M), f"{var} must come from TF_VAR_, never terraform.tfvars"
    assert not ORG_ID.search(tfvars)


# --- workflows -------------------------------------------------------------------------------------------------------

def _env_values(node) -> list[dict]:
    """Every `env:` mapping anywhere in a workflow."""
    out = []
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "env" and isinstance(v, dict):
                out.append(v)
            out.extend(_env_values(v))
    elif isinstance(node, list):
        for v in node:
            out.extend(_env_values(v))
    return out


def test_every_aa365_plan_gets_both_ids_from_secrets():
    for name in ("terraform-plan.yml", "terraform-apply.yml", "terraform-drift.yml"):
        envs = _env_values(yaml.safe_load(_read(WORKFLOWS, name)))
        with_db = [e for e in envs if "TF_VAR_db_password" in e]
        assert with_db, name
        for env in with_db:
            acct = str(env.get("TF_VAR_org_management_account_id", ""))
            org = str(env.get("TF_VAR_org_management_org_id", ""))
            assert "secrets.MGMT_ACCOUNT_ID" in acct, name
            assert "secrets.MGMT_ORG_ID" in org, name
            assert "vars." not in acct + org, name


# --- accounts/management/org_member_access.tf ------------------------------------------------------------------------

def test_broker_trusts_only_identity_center_admin_sessions():
    role = _block(_member_access(), 'resource "aws_iam_role" "org_member_access" {')
    assert 'Principal = { AWS = "arn:aws:iam::${var.management_account_id}:root" }' in role
    assert re.search(
        r'ArnLike = \{\s*"aws:PrincipalArn" = "arn:aws:iam::\$\{var\.management_account_id\}:role/aws-reserved/'
        r'sso\.amazonaws\.com/\*/AWSReservedSSO_AA-Admin_\*"', role)
    assert "max_session_duration = 3600" in role


def test_broker_may_only_assume_the_member_role():
    policy = _block(_member_access(), 'resource "aws_iam_role_policy" "org_member_access" {')
    assert re.findall(r'Action\s*=\s*"([^"]+)"', policy) == ["sts:AssumeRole"]
    assert '"arn:aws:iam::${a}:role/${local.org_member_role_name}"' in policy
    assert "NotAction" not in policy and '"*"' not in policy


def test_no_id_is_committed_in_the_broker_file():
    assert not ACCOUNT_ID.search(_member_access())


# --- accounts/management: Transitional OU ----------------------------------------------------------------------------

def _scp_ou_policies() -> dict:
    block = _block(_read(MGMT, "scp.tf"), "locals {")
    m = re.search(r"scp_ou_policies = \{(.*?)\n  \}", block, re.S)
    assert m, "scp_ou_policies not found"
    out = {}
    for line in m.group(1).splitlines():
        kv = re.match(r"\s*(\w+)\s*=\s*(.+?)\s*$", line)
        if kv:
            out[kv.group(1)] = kv.group(2)
    return out


def test_transitional_ou_holds_scp_1_only():
    ous = _scp_ou_policies()
    assert ous["transitional"] == '["aa-scp-deny-leave-close"]'
    for ou in ("nonprod", "prod", "suspended"):
        assert ous[ou] == "keys(local.scps)", ou


def test_existing_attachment_keys_are_unchanged():
    # Before S273 the keys were "<policy>:<ou>" for every policy x {nonprod, prod, suspended}; a new key shape would
    # destroy and re-create live SCP attachments (the plan guard refuses that).
    assert '"${policy}:${ou}" => { policy = policy, ou = ou }' in _read(MGMT, "scp.tf")


def test_transitional_ou_exists_and_accounts_can_be_placed_there():
    org = _read(MGMT, "organization.tf")
    assert 'resource "aws_organizations_organizational_unit" "transitional" {' in org
    assert 'name      = "Transitional"' in org
    assert "transitional = aws_organizations_organizational_unit.transitional.id" in org
    variables = _read(MGMT, "variables.tf")
    assert 'contains(["root", "transitional", "nonprod", "prod", "suspended"], a.ou)' in variables
