"""AA-1049 W3 (S275): the T2 linear orchestrator and T9 SEO builder switches of the CIS worker.

Offline, no Terraform run. What must hold:
1. modules/ecs has nullable variables t2_orchestrator (linear | graph) and t9_seo_builder (on | off), default null,
   so a module call without them renders the same task definitions as before (no env).
2. The env names T2_ORCHESTRATOR / T9_SEO_BUILDER appear only when the variable is set, and only on the WORKER task
   definition (both writers run as jobs there); the api task definition carries neither.
3. The live root (accounts/aa365) turns both on: linear and on (tech lead decision S275, trial-then-on).
4. T9_REGRESSION_GUARD_MODE stays unset everywhere (tech lead: keep off).
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ECS = (ROOT / "modules" / "ecs" / "main.tf").read_text(encoding="utf-8")
ECS_VARS = (ROOT / "modules" / "ecs" / "variables.tf").read_text(encoding="utf-8")
MAIN = (ROOT / "accounts" / "aa365" / "main.tf").read_text(encoding="utf-8")


def _block_after(text: str, start: int) -> str:
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i : j + 1]
    raise AssertionError("unbalanced braces")


def _code(block: str) -> str:
    """The block without # comments, so a name mentioned in a comment does not count."""
    return "\n".join(line.split("#", 1)[0] for line in block.splitlines())


def _task_definition(name: str) -> str:
    return _code(_block_after(ECS, ECS.index(f'resource "aws_ecs_task_definition" "{name}"')))


def _module_ecs() -> str:
    return _code(_block_after(MAIN, MAIN.index('module "ecs"')))


# --- 1. nullable variables -------------------------------------------------------------------------------------------

def test_variables_are_nullable_with_a_closed_value_set():
    for name, values in (("t2_orchestrator", ("linear", "graph")), ("t9_seo_builder", ("on", "off"))):
        var = _block_after(ECS_VARS, ECS_VARS.index(f'variable "{name}"'))
        assert "default     = null" in var, name
        assert "type        = string" in var, name
        # A conditional, not `||` + contains(): "" must be refused (an empty env value is not the default path).
        assert f"condition     = var.{name} == null ? true : contains([" in var, name
        for v in values:
            assert f'"{v}"' in var, (name, v)


# --- 2. worker only, only when set -----------------------------------------------------------------------------------

def test_env_is_emitted_only_when_the_variable_is_set():
    start = ECS.index("aa1049_w3_env = concat(")
    local = _code(ECS[start : ECS.index("\n  )", start)])
    assert 'var.t2_orchestrator != null ? [{ name = "T2_ORCHESTRATOR", value = var.t2_orchestrator }] : []' in local
    assert 'var.t9_seo_builder != null ? [{ name = "T9_SEO_BUILDER", value = var.t9_seo_builder }] : []' in local


def test_only_the_worker_task_definition_carries_the_switches():
    worker = _task_definition("worker")
    api = _task_definition("api")
    assert "local.aa1049_w3_env," in worker
    assert "aa1049_w3_env" not in api
    for env_name in ("T2_ORCHESTRATOR", "T9_SEO_BUILDER"):
        assert env_name not in api
    # One use in the whole module: the worker container's environment list.
    assert _code(ECS).count("local.aa1049_w3_env") == 1


# --- 3. the live root turns both on ----------------------------------------------------------------------------------

def test_live_root_sets_linear_and_on():
    module = _module_ecs()
    assert re.search(r'^\s*t2_orchestrator\s*=\s*"linear"\s*$', module, re.M)
    assert re.search(r'^\s*t9_seo_builder\s*=\s*"on"\s*$', module, re.M)


# --- 4. the regression guard stays off -------------------------------------------------------------------------------

def test_regression_guard_mode_is_not_set():
    for text in (_code(ECS), _code(ECS_VARS), _code(MAIN)):
        assert "T9_REGRESSION_GUARD_MODE" not in text
        assert "t9_regression_guard" not in text
