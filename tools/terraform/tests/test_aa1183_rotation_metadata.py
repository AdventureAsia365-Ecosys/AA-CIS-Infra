"""Static tests of the AA-1183 part 2 additions to accounts/aa365/compliance_evidence.tf: the root weekly secret
rotation check may assume the compliance evidence role from exactly one workflow file on master, and gets exactly the
metadata calls of tools/security/rotation_check.py (root repo), never a call that returns a secret value.

Offline: reads the .tf file; no Terraform, no AWS. Run from the repo root:
python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1183_rotation_metadata.py
"""
from __future__ import annotations

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TF = os.path.join(REPO_ROOT, "accounts", "aa365", "compliance_evidence.tf")

with open(TF, encoding="utf-8") as fh:
    TEXT = fh.read()
CODE = "\n".join(line for line in TEXT.splitlines() if not line.lstrip().startswith("#"))

# The root tool's allowlist (rotation_check.py AWS_CALLS -> `rotation_check.py iam-actions`). Change both together.
ROTATION_ACTIONS = [
    "acm:DescribeCertificate", "acm:ListCertificates", "cognito-idp:ListUserPoolClientSecrets",
    "cognito-idp:ListUserPoolClients", "cognito-idp:ListUserPools", "iam:ListAccessKeys", "iam:ListUsers",
    "kms:DescribeKey", "kms:GetKeyRotationStatus", "kms:ListAliases", "rds:DescribeDBInstances",
    "secretsmanager:ListSecretVersionIds", "secretsmanager:ListSecrets",
]
# Calls that return a secret value, a client secret or key material.
SECRET_READS = ("secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue",
                "cognito-idp:DescribeUserPoolClient", "cognito-idp:DescribeIdentityProvider", "acm:ExportCertificate",
                "kms:Decrypt", "ssm:GetParameter")
# The managed SecurityAudit policy grants cognito-idp:Describe*, so these must be DENIED explicitly, not only left out
# of the local allow lists (S297 review: an allow-list check alone passed while the effective grant still allowed them).
DENIED_SECRET_READS = ("secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue",
                       "cognito-idp:DescribeUserPoolClient", "cognito-idp:DescribeIdentityProvider",
                       "acm:ExportCertificate", "kms:Decrypt")
AA365 = os.path.join(REPO_ROOT, "accounts", "aa365")
WORKFLOW = os.path.join(REPO_ROOT, ".github", "workflows", "compliance-aws.yml")
EXCLUDED_PROWLER_CHECKS = ("cognito_user_pool_client_prevent_user_existence_errors",
                           "cognito_user_pool_client_token_revocation_enabled")


def _block(opener: str, text: str = CODE) -> str:
    start = text.index(opener)
    depth = 0
    open_ch, close_ch = ("[", "]") if opener.rstrip().endswith("[") else ("{", "}")
    for i in range(start, len(text)):
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise AssertionError(f"unbalanced block after {opener!r}")


def _statement(text: str, sid: str) -> str:
    m = re.search(rf'Sid\s+= "{re.escape(sid)}"', text)
    assert m, sid
    nxt = re.compile(r"Sid\s+=").search(text, m.end())
    return text[m.start():nxt.start() if nxt else len(text)]


def test_rotation_read_list_is_exactly_the_tool_allowlist():
    block = _block("compliance_evidence_rotation_read = [")
    assert sorted(re.findall(r'"([a-z0-9-]+:[A-Za-z]+)"', block)) == sorted(ROTATION_ACTIONS)


def test_no_secret_reading_call_is_granted():
    allow = _block("compliance_evidence_rotation_read = [") + _block("compliance_evidence_read_extra = [")
    for action in SECRET_READS:
        assert action not in allow, action
    for action in ROTATION_ACTIONS:
        assert action.split(":")[1].startswith(("List", "Describe", "GetKeyRotationStatus")), action


def test_policy_grants_the_list_and_denies_secret_values():
    inline = _block('resource "aws_iam_role_policy" "compliance_evidence"')
    grant = _statement(inline, "RotationCheckMetadata")
    assert 'Effect   = "Allow"' in grant and "Action   = local.compliance_evidence_rotation_read" in grant
    assert 'Resource = "*"' in grant
    deny = _statement(inline, "DenySecretValueReads")
    assert 'Effect   = "Deny"' in deny and "Action   = local.compliance_evidence_secret_value_reads" in deny
    reads = _block("compliance_evidence_secret_value_reads = [")
    for action in DENIED_SECRET_READS:
        assert f'"{action}"' in reads, action


def test_role_keeps_security_audit_so_the_deny_is_needed():
    # If SecurityAudit is ever dropped the deny is still harmless; while it is attached, the deny above is what keeps
    # the Cognito secret-returning calls away from the role.
    assert 'policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"' in CODE
    deny_names = re.findall(r'"([a-z0-9-]+:[A-Za-z]+)"', _block("compliance_evidence_secret_value_reads = ["))
    assert {"cognito-idp:DescribeUserPoolClient", "cognito-idp:DescribeIdentityProvider"} <= set(deny_names)


def test_prowler_skips_the_checks_that_need_the_denied_call():
    with open(WORKFLOW, encoding="utf-8") as fh:
        wf = fh.read()
    scan = wf[wf.index("- name: Scan (output to files only)"):wf.index("- name: Summarize")]
    assert "--excluded-check" in scan
    for check in EXCLUDED_PROWLER_CHECKS:
        assert check in scan, check


def _client_blocks():
    for name in sorted(os.listdir(AA365)):
        if not name.endswith(".tf"):
            continue
        with open(os.path.join(AA365, name), encoding="utf-8") as fh:
            text = "\n".join(line for line in fh.read().splitlines() if not line.lstrip().startswith("#"))
        for m in re.finditer(r'resource "aws_cognito_user_pool_client" "([a-z0-9_]+)" \{', text):
            yield f"{name}:{m.group(1)}", _block(m.group(0), text)


def test_every_user_pool_client_sets_what_the_excluded_prowler_checks_tested():
    clients = list(_client_blocks())
    assert len(clients) >= 4, clients
    for where, block in clients:
        assert re.search(r"enable_token_revocation\s+=\s+true", block), where
        assert re.search(r'prevent_user_existence_errors\s+=\s+"ENABLED"', block), where


def test_trust_pins_the_rotation_workflow_on_master():
    role = _block('resource "aws_iam_role" "compliance_evidence"')
    stmt = _statement(role, "GitHubOidcRootRotation")
    assert '"token.actions.githubusercontent.com:sub"              = local.docs_sync_oidc_sub' in stmt
    assert '"token.actions.githubusercontent.com:ref"              = "refs/heads/master"' in stmt
    assert "= local.compliance_evidence_rotation_workflow" in stmt
    assert '"token.actions.githubusercontent.com:aud"              = "sts.amazonaws.com"' in stmt
    assert "StringLike" not in stmt
    assert ('compliance_evidence_rotation_workflow = '
            '"AdventureAsia365-Ecosys/AA-Ecosys/.github/workflows/secret-rotation.yml@refs/heads/master"') in CODE


def test_role_keeps_its_boundary():
    role = _block('resource "aws_iam_role" "compliance_evidence"')
    assert "permissions_boundary = aws_iam_policy.workload_boundary.arn" in role
