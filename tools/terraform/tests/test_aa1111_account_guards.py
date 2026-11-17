"""Static tests: every Terraform root pins the account it may run in (AA-1111, S283; ADR 0018 decision 5).

What they hold:
  - every `provider "aws"` block in accounts/*/*.tf sets `allowed_account_ids = [var.<name>]` (a variable, never a
    literal ID), so a plan or apply whose credentials resolve to another account stops before any call (the AA-517
    wrong-account writes). A new root or a new aliased provider without it fails here.
  - accounts/aa365 guards with var.account_id, validated as 12 digits (the variable every ARN of the root uses, read
    from terraform.tfvars by the plan, apply and drift workflows: no new CI input).
  - accounts/acc3-bedrock follows the acc1-bedrock pattern: no literal profile and no literal state bucket in
    versions.tf; account_id and aws_profile are required variables (an untracked terraform.tfvars sets them) and the
    header documents the -backend-config init.
  - the README acc3 row carries no account ID and no profile name.

Offline: reads the .tf files; no Terraform, no AWS. Run from the repo root:
python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1111_account_guards.py
"""
from __future__ import annotations

import glob
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
ACCOUNTS = os.path.join(REPO_ROOT, "accounts")
AA365 = os.path.join(ACCOUNTS, "aa365")
ACC3 = os.path.join(ACCOUNTS, "acc3-bedrock")

ACCOUNT_ID = re.compile(r"(?<![0-9])\d{12}(?![0-9])")
GUARD = re.compile(r"^\s*allowed_account_ids\s*=\s*\[var\.[a-z_]+\]\s*$", re.M)


def _read(*parts: str) -> str:
    with open(os.path.join(*parts), encoding="utf-8") as fh:
        return fh.read()


def _blocks(text: str, opener: str) -> list[str]:
    out = []
    start = text.find(opener)
    while start != -1:
        depth = 0
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    out.append(text[start:i + 1])
                    break
        else:
            raise AssertionError(f"unclosed block: {opener}")
        start = text.find(opener, start + 1)
    return out


def _providers() -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for path in sorted(glob.glob(os.path.join(ACCOUNTS, "*", "*.tf"))):
        text = "\n".join(line for line in _read(path).splitlines() if not line.lstrip().startswith("#"))
        blocks = _blocks(text, 'provider "aws" {')
        if blocks:
            found[os.path.relpath(path, REPO_ROOT)] = blocks
    return found


def test_every_aws_provider_pins_its_account_from_a_variable():
    providers = _providers()
    # The four roots of today; a new root is picked up by the glob and must carry the guard too.
    roots = {path.split(os.sep)[1] for path in providers}
    assert {"aa365", "acc1-bedrock", "acc3-bedrock", "management"} <= roots
    for path, blocks in providers.items():
        for block in blocks:
            assert GUARD.search(block), f"{path}: provider without allowed_account_ids = [var.<name>]:\n{block}"
            assert not ACCOUNT_ID.search(block), f"{path}: a literal account ID in a provider block"


def test_aa365_guards_every_provider_with_the_validated_account_id():
    blocks = _blocks(_read(AA365, "versions.tf"), 'provider "aws" {')
    assert len(blocks) == 4  # default + us_east_1 + us_east_2 + us_west_2
    for block in blocks:
        assert "allowed_account_ids = [var.account_id]" in block
    var = _blocks(_read(AA365, "variables.tf"), 'variable "account_id" {')
    assert len(var) == 1
    assert 'can(regex("^[0-9]{12}$", var.account_id))' in var[0]
    assert not re.search(r"^\s*default\s*=", var[0], re.M)


def test_acc3_commits_no_profile_and_no_state_bucket():
    for path in sorted(glob.glob(os.path.join(ACC3, "*.tf"))):
        text = _read(path)
        assert not re.search(r'^\s*profile\s*=\s*"', text, re.M), f"{path}: a literal profile"
        assert not re.search(r'^\s*bucket\s*=\s*"', text, re.M), f"{path}: a literal state bucket (it names the ID)"
        assert "nghiep_aa365" not in text, f"{path}: the acc3 profile name"
    versions = _read(ACC3, "versions.tf")
    assert not ACCOUNT_ID.search(versions), "acc3 versions.tf names an account ID"


def test_acc3_takes_id_and_profile_as_required_variables():
    text = _read(ACC3, "versions.tf")
    for name in ("account_id", "aws_profile"):
        blocks = _blocks(text, f'variable "{name}" {{')
        assert len(blocks) == 1, name
        assert not re.search(r"^\s*default\s*=", blocks[0], re.M), f"{name} must have no default (an untracked terraform.tfvars sets it)"
    assert 'can(regex("^[0-9]{12}$", var.account_id))' in text
    provider = _blocks(text, 'provider "aws" {')
    assert len(provider) == 1
    assert "profile             = var.aws_profile" in provider[0]
    assert "allowed_account_ids = [var.account_id]" in provider[0]
    # The header tells the operator how to init without the committed bucket / profile.
    assert '-backend-config="bucket=' in text and '-backend-config="profile=' in text
    assert "init -reconfigure" in text


def test_the_readme_acc3_row_carries_no_id_and_no_profile():
    rows = [line for line in _read(REPO_ROOT, "README.md").splitlines() if line.startswith("| `accounts/acc3-bedrock/`")]
    assert len(rows) == 1
    assert not ACCOUNT_ID.search(rows[0])
    assert "nghiep_aa365" not in rows[0]
