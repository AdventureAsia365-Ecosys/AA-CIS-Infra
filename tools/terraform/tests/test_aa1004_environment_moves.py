"""AA-1004 P0 (prod plan P0): the split of accounts/aa365 into modules/environment stays a pure move.

modules/environment is the environment-scoped stack a future accounts/aa-prod root instantiates with its own inputs;
accounts/aa365 instantiates it for Dev as `module "environment"` (environment.tf). Every slice moves resources with
`moved` blocks, so the Dev plan is "0 to add, 0 to change, 0 to destroy". These offline checks catch the ways a slice
turns into a destroy + create instead:

  1. every resource of the slice-1 list (the AA-Booking stack) has exactly one moved block root -> module, same type
     and name;
  2. every moved block into the module points at a resource the module declares, and its `from` address is no longer
     declared in the root (a leftover copy would plan a second resource with the same AWS name);
  3. no address is moved twice and no moved block points at a resource the root still declares;
  4. the module has no provider or backend block of its own (it must run on the root's default aws provider and its
     default_tags, or every tag would plan to change), and the root instantiates it exactly once with
     environment = var.environment.

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
    assert len(_resources(ENV_MODULE)) >= len(SLICE_1)
    assert len(_env_moves()) >= len(SLICE_1)


def test_every_slice_1_resource_has_one_plain_move():
    moves = _env_moves()
    for addr in sorted(SLICE_1):
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
    for addr in _resources(ENV_MODULE) & SLICE_1:
        assert addr not in root, f"{addr} is declared both in the root and in modules/environment"


def test_no_address_is_moved_twice():
    froms = [a for a, _ in _moves()]
    tos = [b for _, b in _moves()]
    assert len(froms) == len(set(froms)), "an address is the `from` of two moved blocks"
    assert len(tos) == len(set(tos)), "two moved blocks share a `to`"


def test_the_module_runs_on_the_roots_provider():
    for name, text in _texts(ENV_MODULE).items():
        assert not re.search(r'^provider "', text, re.M), f"modules/environment/{name}: no provider block in the module"
        assert "backend" not in text, f"modules/environment/{name}: no backend in the module"


def test_the_root_instantiates_the_module_once_for_its_environment():
    calls = [(n, t) for n, t in _texts(AA365).items() if re.search(r'^module "environment" \{', t, re.M)]
    assert [n for n, _ in calls] == ["environment.tf"]
    text = calls[0][1]
    assert re.search(r'^\s*source\s*=\s*"\.\./\.\./modules/environment"\s*$', text, re.M)
    assert re.search(r"^\s*environment\s*=\s*var\.environment\s*$", text, re.M)
    assert re.search(r"^\s*account_id\s*=\s*var\.account_id\s*$", text, re.M)


def test_no_account_id_literal_in_the_module():
    # Public repo, and the same module serves another account: ids arrive as inputs only.
    for name, text in _texts(ENV_MODULE).items():
        assert not re.search(r"\b\d{12}\b", text), f"modules/environment/{name}: 12-digit literal"
