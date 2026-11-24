"""Static tests of accounts/aa365/compliance_evidence.tf (AA-1173): the evidence bucket cannot be emptied, shortened or
overwritten, and the collector role can only read the account and write evidence once.

Offline: reads the .tf file; no Terraform, no AWS. Run from the repo root:
python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1173_compliance_evidence.py
"""
from __future__ import annotations

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TF = os.path.join(REPO_ROOT, "accounts", "aa365", "compliance_evidence.tf")

with open(TF, encoding="utf-8") as fh:
    TEXT = fh.read()
# the code without the comment lines (the header explains words such as COMPLIANCE that the code must not use)
CODE = "\n".join(line for line in TEXT.splitlines() if not line.lstrip().startswith("#"))


def _block(opener: str) -> str:
    start = CODE.index(opener)
    depth = 0
    for i in range(start, len(CODE)):
        if CODE[i] == "{":
            depth += 1
        elif CODE[i] == "}":
            depth -= 1
            if depth == 0:
                return CODE[start:i + 1]
    raise AssertionError(f"unbalanced block after {opener!r}")


def _statement(policy: str, sid: str) -> str:
    i = policy.index(f'sid       = "{sid}"') if f'sid       = "{sid}"' in policy else policy.index(f'"{sid}"')
    j = policy.find("statement {", i)
    return policy[i:j if j > 0 else len(policy)]


def test_bucket_has_object_lock_governance_with_a_retention_variable():
    bucket = _block('resource "aws_s3_bucket" "compliance_evidence"')
    assert "object_lock_enabled = true" in bucket
    assert "force_destroy       = false" in bucket
    lock = _block('resource "aws_s3_bucket_object_lock_configuration" "compliance_evidence"')
    assert 'mode = "GOVERNANCE"' in lock
    assert "days = var.compliance_evidence_retention_days" in lock
    assert '"COMPLIANCE"' not in CODE, "never COMPLIANCE mode on Dev (plan_guard refuses it too)"
    var = _block('variable "compliance_evidence_retention_days"')
    assert "default     = 365" in var and "validation" in var


def test_bucket_is_versioned_private_and_sse_s3():
    assert 'status = "Enabled"' in _block('resource "aws_s3_bucket_versioning" "compliance_evidence"')
    pab = _block('resource "aws_s3_bucket_public_access_block" "compliance_evidence"')
    assert pab.count("= true") == 4
    assert 'sse_algorithm = "AES256"' in CODE
    assert "aws_kms_key" not in CODE
    assert 'object_ownership = "BucketOwnerEnforced"' in CODE


def test_lifecycle_never_expires_before_the_retention():
    lc = _block('resource "aws_s3_bucket_lifecycle_configuration" "compliance_evidence"')
    assert "days = var.compliance_evidence_retention_days + 1" in lc


def test_bucket_policy_denies_tampering_to_every_principal():
    policy = _block('data "aws_iam_policy_document" "compliance_evidence_bucket"')
    actions = _block("compliance_evidence_tamper_actions = [")
    for action in ("s3:BypassGovernanceRetention", "s3:PutObjectRetention", "s3:PutObjectLegalHold",
                   "s3:DeleteObject", "s3:DeleteObjectVersion"):
        assert f'"{action}"' in TEXT
    del actions
    tamper = _statement(policy, "DenyEvidenceTampering")
    assert 'effect    = "Deny"' in tamper and 'identifiers = ["*"]' in tamper
    assert "actions   = local.compliance_evidence_tamper_actions" in tamper
    overwrite = _statement(policy, "DenyOverwrite")
    assert 'variable = "s3:if-none-match"' in overwrite and 'test     = "Null"' in overwrite
    writer = _statement(policy, "DenyWritesButTheCollector")
    assert "aws_iam_role.compliance_evidence.arn" in writer and '"ArnNotEquals"' in writer
    assert "DenyWritesOutsideThePrefix" in policy and "DenyInsecureTransport" in policy
    assert not re.search(r'effect\s*=\s*"Allow"', policy), "the bucket policy only denies"


def test_role_is_bounded_read_only_and_write_once():
    role = _block('resource "aws_iam_role" "compliance_evidence"')
    assert "permissions_boundary = aws_iam_policy.workload_boundary.arn" in role
    for cond in (":aud", ":sub", ":ref", ":job_workflow_ref"):
        assert f'"token.actions.githubusercontent.com{cond}"' in role
    assert "StringLike" not in role, "the trust is exact, never a wildcard"
    assert role.count('"token.actions.githubusercontent.com:job_workflow_ref"') == 2
    assert role.count("Statement") == 1 and role.count("Sid       =") == 2
    assert "= local.compliance_evidence_root_workflow" in role and "= local.compliance_evidence_infra_workflow" in role
    assert '"refs/heads/master"' in role and '"${local.oidc_sub_cis_infra}:ref:refs/heads/main"' in role
    assert 'compliance-evidence.yml@refs/heads/master"' in CODE
    assert 'compliance-aws.yml@refs/heads/main"' in CODE
    assert 'arn:aws:iam::aws:policy/SecurityAudit"' in CODE
    assert 'arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"' in CODE
    assert "AdministratorAccess" not in CODE and "ReadOnlyAccess\"" not in CODE.replace("ViewOnlyAccess", "")
    inline = _block('resource "aws_iam_role_policy" "compliance_evidence"')
    assert 'Action   = ["s3:GetObject", "s3:PutObject"]' in inline
    assert '"s3:DeleteObject"' not in inline.split("DenyTampering")[0]
    assert "Action   = local.compliance_evidence_role_denies" in inline
    extra = _block("compliance_evidence_read_extra = [")
    for data_read in ("lambda:GetFunction", "logs:FilterLogEvents", "logs:GetLogEvents", "ssm:GetDocument",
                      "secretsmanager:GetSecretValue", "s3:GetObject", "dynamodb:GetItem"):
        assert data_read not in extra


def test_cis_task_role_reads_evidence_only():
    reader = _block('resource "aws_iam_role_policy" "ecs_read_compliance_evidence"')
    assert "module.ecs.task_role_name" in reader
    actions = set(re.findall(r'"(s3:[A-Z][A-Za-z]+)"', reader))
    assert actions == {"s3:ListBucket", "s3:GetObject"}


def test_tags_follow_the_standard():
    assert 'Component = "security", Issue = "AA-1173"' in CODE
    assert "local.shared_tags" in CODE
