"""AA-1004 (S273): the MFA admin role of accounts/aa365 is Terraform-managed (admin_role.tf), offline guards.

1. The role keeps the shape of the hand-made role it replaces: trust = one IAM user of this account with MFA, action
   sts:AssumeRole only; 12-hour maximum session; the same three AWS managed policies; no permissions boundary (it is
   the account administrator); prevent_destroy; S271 tags.
2. Every resource policy that lets "the MFA admin role" through names local.id_admin_role_arns, never one ARN, so the
   transition (both names allowed) and the clean-up (new name only) change one list.
3. Transition state of PR 1: the hand-made role's name is still in the legacy list (the follow-up PR flips this test).

Run: python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1004_admin_role.py
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
ADMIN_TF = (AA365 / "admin_role.tf").read_text(encoding="utf-8")
VARIABLES = (AA365 / "identity_variables.tf").read_text(encoding="utf-8")
ALERTS = (AA365 / "identity_alerts.tf").read_text(encoding="utf-8")


def _block(text: str, header: str) -> str:
    """Brace-balanced body of the first block that starts with ``header``."""
    start = text.index(header)
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        depth += {"{": 1, "}": -1}.get(text[j], 0)
        if depth == 0:
            return text[i: j + 1]
    raise AssertionError(f"unbalanced block {header}")


def _default(var: str) -> str:
    return re.search(r"default\s*=\s*(.+)", _block(VARIABLES, f'variable "{var}"')).group(1).strip()


def _code(text: str) -> str:
    """The text without # comment lines."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


# --- 1. role shape ---------------------------------------------------------------------------------------------------

def test_role_name_comes_from_the_variable_the_policies_use():
    role = _block(ADMIN_TF, 'resource "aws_iam_role" "admin"')
    assert re.search(r"name\s*=\s*var\.identity_breakglass_admin_role_name\b", role)
    assert _default("identity_breakglass_admin_role_name") == '"nghiep-admin-12h"'
    assert _default("identity_admin_user_name") == '"nghiep-admin"'


def test_twelve_hour_session_no_boundary_prevent_destroy_and_tags():
    role = _block(ADMIN_TF, 'resource "aws_iam_role" "admin"')
    assert re.search(r"max_session_duration\s*=\s*43200\b", role)
    assert "permissions_boundary" not in _code(role)
    assert re.search(r"lifecycle\s*\{\s*prevent_destroy\s*=\s*true\s*\}", role)
    assert re.search(r'tags\s*=\s*merge\(local\.shared_tags,\s*\{\s*Component\s*=\s*"security"', role)
    assert re.search(r"assume_role_policy\s*=\s*data\.aws_iam_policy_document\.admin_role_assume\.json", role)


def test_trust_is_one_user_of_this_account_with_mfa_and_assume_role_only():
    doc = _block(ADMIN_TF, 'data "aws_iam_policy_document" "admin_role_assume"')
    assert doc.count("statement {") == 1
    assert re.search(r'effect\s*=\s*"Allow"', doc)
    assert re.search(r'actions\s*=\s*\["sts:AssumeRole"\]', doc)
    assert re.search(r'type\s*=\s*"AWS"', doc)
    assert re.search(r'identifiers\s*=\s*\["arn:aws:iam::\$\{var\.account_id\}:user/\$\{var\.identity_admin_user_name\}"\]',
                     doc)
    assert ":root" not in doc and '"*"' not in doc
    assert re.search(r'test\s*=\s*"Bool"\s*variable\s*=\s*"aws:MultiFactorAuthPresent"\s*values\s*=\s*\["true"\]', doc)


def test_the_three_managed_policies_and_nothing_inline():
    policies = _block(ADMIN_TF, "admin_role_managed_policies =")
    arns = sorted(re.findall(r'"(arn:aws:iam::aws:policy/[^"]+)"', policies))
    assert arns == [
        "arn:aws:iam::aws:policy/AWSBillingConductorFullAccess",
        "arn:aws:iam::aws:policy/AdministratorAccess",
        "arn:aws:iam::aws:policy/job-function/Billing",
    ]
    attach = _block(ADMIN_TF, 'resource "aws_iam_role_policy_attachment" "admin"')
    assert "for_each   = local.admin_role_managed_policies" in attach
    assert "role       = aws_iam_role.admin.name" in attach
    assert 'resource "aws_iam_role_policy" ' not in ADMIN_TF


def test_no_account_id_literal():
    assert not re.search(r"\b\d{12}\b", ADMIN_TF)


# --- 2. one list names the admin role everywhere ---------------------------------------------------------------------

def test_admin_role_list_starts_with_the_terraform_role():
    assert re.search(r'id_breakglass_admin_role_arn\s*=\s*"arn:aws:iam::\$\{var\.account_id\}:role/'
                     r'\$\{var\.identity_breakglass_admin_role_name\}"', ALERTS)
    lst = re.search(r"id_admin_role_arns\s*=\s*concat\((.*?)\n  \)", ALERTS, re.S).group(1)
    assert lst.strip().startswith("[local.id_breakglass_admin_role_arn]")
    assert "var.identity_admin_role_legacy_names" in lst


def test_every_admin_exception_uses_the_list():
    uses = {}
    for tf in sorted(AA365.glob("*.tf")):
        code = _code(tf.read_text(encoding="utf-8"))
        n = len(re.findall(r"\blocal\.id_breakglass_admin_role_arn\b", code))
        if n:
            uses[tf.name] = n
        assert "nghiep-admin-8h-session" not in code or tf.name == "identity_variables.tf", tf.name
    # Only the list definition itself reads the single ARN.
    assert uses == {"identity_alerts.tf": 1}
    expected = {"identity_alerts.tf": 1, "ops_secret_guard.tf": 1, "e2e_mailbox.tf": 2}
    for name, count in expected.items():
        code = _code((AA365 / name).read_text(encoding="utf-8"))
        assert len(re.findall(r"\blocal\.id_admin_role_arns\b", code)) >= count, name


# --- 3. transition state (PR 1) --------------------------------------------------------------------------------------

def test_transition_keeps_the_hand_made_role_allowed():
    # PR 1: both names pass every admin exception until the CLI profiles assume the new role. The follow-up PR
    # removes var.identity_admin_role_legacy_names and replaces this test with one asserting no legacy name.
    assert _default("identity_admin_role_legacy_names") == '["nghiep-admin-8h-session"]'
