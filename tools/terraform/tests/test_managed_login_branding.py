"""Tests of tools/terraform/managed_login_branding.py (AA-935 follow-up, S249). Offline, stdlib + pytest."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import managed_login_branding as mlb  # noqa: E402

REPO = Path(__file__).resolve().parents[3]

POOL_V2 = """
resource "aws_cognito_user_pool" "ext" {
  name = "ext"
}

resource "aws_cognito_user_pool_domain" "ext_prefix" {
  domain                = "ext-dev"
  user_pool_id          = aws_cognito_user_pool.ext.id
  managed_login_version = 2
}
"""

CLIENTS = """
resource "aws_cognito_user_pool_client" "ext" {
  for_each            = local.clients
  name                = "ext-${each.key}"
  user_pool_id        = aws_cognito_user_pool.ext.id
  allowed_oauth_flows = ["code"]
  token_validity_units {
    access_token = "minutes"
  }
}
"""

BRANDING = """
resource "aws_cognito_managed_login_branding" "ext" {
  for_each     = aws_cognito_user_pool_client.ext
  user_pool_id = aws_cognito_user_pool.ext.id
  client_id    = each.value.id
  settings     = jsonencode({})

  dynamic "asset" {
    for_each = local.assets
    content {
      category = asset.value.category
    }
  }
}
"""


def _run(tmp_path: Path, *chunks: str) -> tuple[list[str], int]:
    (tmp_path / "main.tf").write_text("\n".join(chunks), encoding="utf-8")
    return mlb.scan(tmp_path)


def test_for_each_client_with_branding_passes(tmp_path):
    errors, checked = _run(tmp_path, POOL_V2, CLIENTS, BRANDING)
    assert errors == []
    assert checked == 1


def test_for_each_client_without_branding_fails(tmp_path):
    errors, _ = _run(tmp_path, POOL_V2, CLIENTS)
    assert len(errors) == 1 and errors[0].startswith("B1 ") and "403" in errors[0]


def test_filtered_for_each_does_not_cover(tmp_path):
    filtered = BRANDING.replace(
        "for_each     = aws_cognito_user_pool_client.ext",
        'for_each     = { for k, v in aws_cognito_user_pool_client.ext : k => v if k != "x" }',
    )
    errors, _ = _run(tmp_path, POOL_V2, CLIENTS, filtered)
    assert any(e.startswith("B1 ") for e in errors)


def test_branding_on_other_pool_fails(tmp_path):
    wrong = BRANDING.replace("user_pool_id = aws_cognito_user_pool.ext.id", "user_pool_id = aws_cognito_user_pool.other.id")
    errors, _ = _run(tmp_path, POOL_V2, CLIENTS, wrong)
    assert len(errors) == 1 and errors[0].startswith("B2 ")


def test_single_client_needs_client_id_reference(tmp_path):
    single = CLIENTS.replace("  for_each            = local.clients\n", "")
    branding = """
resource "aws_cognito_managed_login_branding" "one" {
  user_pool_id = aws_cognito_user_pool.ext.id
  client_id    = aws_cognito_user_pool_client.ext.id
}
"""
    assert _run(tmp_path, POOL_V2, single)[0][0].startswith("B1 ")
    assert _run(tmp_path, POOL_V2, single, branding)[0] == []


def test_count_client_is_refused(tmp_path):
    counted = CLIENTS.replace("for_each            = local.clients", "count               = 2")
    errors, _ = _run(tmp_path, POOL_V2, counted, BRANDING)
    assert len(errors) == 1 and "count" in errors[0]


def test_machine_client_is_skipped(tmp_path):
    m2m = CLIENTS.replace('["code"]', '["client_credentials"]')
    assert _run(tmp_path, POOL_V2, m2m) == ([], 0)


def test_classic_hosted_ui_pool_is_skipped(tmp_path):
    v1 = POOL_V2.replace("  managed_login_version = 2\n", "")
    assert _run(tmp_path, v1, CLIENTS) == ([], 0)
    assert _run(tmp_path, POOL_V2.replace("= 2", "= 1"), CLIENTS) == ([], 0)


def test_variable_version_counts_as_v2(tmp_path):
    var = POOL_V2.replace("= 2", "= var.login_version")
    errors, _ = _run(tmp_path, var, CLIENTS)
    assert errors and errors[0].startswith("B1 ")


def test_commented_branding_does_not_count(tmp_path):
    commented = "\n".join("# " + line for line in BRANDING.splitlines())
    errors, _ = _run(tmp_path, POOL_V2, CLIENTS, commented)
    assert errors and errors[0].startswith("B1 ")


def test_non_literal_flows_fail_closed(tmp_path):
    dyn = CLIENTS.replace('["code"]', "each.value.flows")
    errors, _ = _run(tmp_path, POOL_V2, dyn, BRANDING)
    assert any(e.startswith("B3 ") for e in errors)


def test_empty_root_is_bad_input(tmp_path):
    with pytest.raises(mlb.InputError):
        mlb.scan(tmp_path)
    assert mlb.main(["--source", str(tmp_path)]) == 2


def test_live_root_passes():
    """accounts/aa365: every interactive client of a v2 pool (WORKFORCE, EXTERNAL) has a style; m2m is skipped."""
    errors, checked = mlb.scan(REPO / "accounts" / "aa365")
    assert errors == []
    assert checked >= 2
