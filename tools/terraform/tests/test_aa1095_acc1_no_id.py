"""Static tests: acc1 (a personal account) serves Bedrock chat models (AA-1095, S278) without its ID or its SSO
profile name ever entering this public repo (CONTEXT.md "No new account ID goes into this repo"; root
docs/security/baseline.md keeps acc1's ID in the public-repo pattern).

What they hold:
  - accounts/acc1-bedrock/*.tf: no 12-digit number, no literal profile; the state bucket and the profile come through
    -backend-config at init, account_id / aws_profile through an untracked terraform.tfvars (required variables).
  - accounts/aa365/bedrock_satellite_assume.tf: acc1's ID is var.bedrock_acct_payer_id (default null, "" = unset),
    the only literal ID is acc3's local; unset, the acc1 statement is left out of the policy.
  - the three Terraform workflows pass TF_VAR_bedrock_acct_payer_id to every aa365 plan from the repo secret
    BEDROCK_ACCT_PAYER_ID (masked), never from a repo variable.
  - README.md: the acc1 row carries no account ID.

Offline: reads the .tf files and the workflows; no Terraform, no AWS. Run from the repo root:
python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1095_acc1_no_id.py
"""
from __future__ import annotations

import glob
import os
import re

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
ACC1 = os.path.join(REPO_ROOT, "accounts", "acc1-bedrock")
AA365 = os.path.join(REPO_ROOT, "accounts", "aa365")
WORKFLOWS = os.path.join(REPO_ROOT, ".github", "workflows")

ACCOUNT_ID = re.compile(r"(?<![0-9])\d{12}(?![0-9])")


def _read(*parts: str) -> str:
    with open(os.path.join(*parts), encoding="utf-8") as fh:
        return fh.read()


def _block(text: str, opener: str) -> str:
    start = text.index(opener)
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise AssertionError(f"unclosed block: {opener}")


def _acc2_id() -> str:
    """acc2's ID, read from its own state bucket name (accounts/aa365/versions.tf), never written here."""
    m = re.search(r'bucket\s*=\s*"aa-cis-tfstate-(\d{12})"', _read(AA365, "versions.tf"))
    assert m
    return m.group(1)


def test_the_acc1_root_commits_no_account_id_and_no_profile():
    # The one ID allowed is acc2's: the trust names the acc2 CIS task role by literal ARN (the static trust inventory
    # cannot read an expression), as accounts/acc3-bedrock does.
    files = sorted(glob.glob(os.path.join(ACC1, "*.tf")))
    assert files
    for path in files:
        text = _read(path)
        assert set(ACCOUNT_ID.findall(text)) <= {_acc2_id()}, path
        assert not re.search(r'^\s*profile\s*=\s*"', text, re.M), f"{path}: a literal profile"
        assert not re.search(r'^\s*bucket\s*=\s*"', text, re.M), f"{path}: a literal state bucket (it names the ID)"


def test_the_acc1_root_takes_id_and_profile_as_required_variables():
    text = _read(ACC1, "versions.tf")
    for var in ("account_id", "aws_profile"):
        block = _block(text, f'variable "{var}" {{')
        assert "default" not in block, f"{var} must have no default (an untracked terraform.tfvars sets it)"
    assert "allowed_account_ids = [var.account_id]" in text
    assert "profile             = var.aws_profile" in text
    assert '-backend-config="bucket=' in text and '-backend-config="profile=' in text


def test_aa365_reads_the_acc1_id_from_a_variable_only():
    text = _read(AA365, "bedrock_satellite_assume.tf")
    block = _block(text, 'variable "bedrock_acct_payer_id" {')
    assert "default     = null" in block
    assert 'var.bedrock_acct_payer_id == null || var.bedrock_acct_payer_id == ""' in block
    locals_block = _block(text, "locals {")
    ids = ACCOUNT_ID.findall(text)
    # The one literal ID is acc3's (bedrock_acct_primary, AA-902); acc1's never appears.
    assert len(set(ids)) == 1 and re.search(rf'bedrock_acct_primary\s*=\s*"{ids[0]}"', locals_block)
    assert re.search(r'bedrock_acct_payer\s*=\s*var\.bedrock_acct_payer_id == null \? "" : '
                     r'var\.bedrock_acct_payer_id', locals_block)


def test_an_unset_secret_leaves_the_acc1_statement_out():
    text = _read(AA365, "bedrock_satellite_assume.tf")
    assert 'local.bedrock_acct_payer == "" ? [] : [' in text
    assert "arn:aws:iam::${local.bedrock_acct_payer}:role/AA1-Bedrock-Invoker" in text


def _env_values(node) -> list[dict]:
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


def test_every_aa365_plan_gets_the_acc1_id_from_a_secret():
    for name in ("terraform-plan.yml", "terraform-apply.yml", "terraform-drift.yml"):
        envs = _env_values(yaml.safe_load(_read(WORKFLOWS, name)))
        with_db = [e for e in envs if "TF_VAR_db_password" in e]
        assert with_db, name
        for env in with_db:
            value = str(env.get("TF_VAR_bedrock_acct_payer_id", ""))
            assert "secrets.BEDROCK_ACCT_PAYER_ID" in value, name
            assert "vars." not in value, name


def test_the_readme_acc1_row_carries_no_id():
    rows = [line for line in _read(REPO_ROOT, "README.md").splitlines() if line.startswith("| `accounts/acc1-bedrock/`")]
    assert len(rows) == 1
    assert not ACCOUNT_ID.search(rows[0])
