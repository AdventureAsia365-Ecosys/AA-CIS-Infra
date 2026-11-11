"""AA-1081 / AA-1077 (S277): the T7 Blog minimum seed (T7_BLOG_MIN_SEED_WORDS) of the CIS worker.

Offline, no Terraform run. What must hold:
1. modules/ecs has a nullable number variable t7_blog_min_seed_words, default null, validated as a whole number from
   1 to 5000 (null, not 0, is the off state), so a module call without it renders the same task definitions as before.
2. The env T7_BLOG_MIN_SEED_WORDS appears only when the variable is set, and only on the WORKER task definition (the
   t7_slate job runs there); the api task definition does not carry it.
3. The live root (accounts/aa365) sets 600 (tech lead decision S277), in module "ecs" only, and nowhere as a raw env.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ECS = (ROOT / "modules" / "ecs" / "main.tf").read_text(encoding="utf-8")
ECS_VARS = (ROOT / "modules" / "ecs" / "variables.tf").read_text(encoding="utf-8")
MAIN = (ROOT / "accounts" / "aa365" / "main.tf").read_text(encoding="utf-8")

VAR = "t7_blog_min_seed_words"
ENV = "T7_BLOG_MIN_SEED_WORDS"


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


# --- 1. nullable whole-number variable -------------------------------------------------------------------------------

def test_variable_is_a_nullable_bounded_whole_number():
    var = _block_after(ECS_VARS, ECS_VARS.index(f'variable "{VAR}"'))
    assert "default     = null" in var
    assert "type        = number" in var
    # A conditional (the module's pattern), so floor() and the bounds never see a null.
    assert f"condition     = var.{VAR} == null ? true : (" in var
    assert f"floor(var.{VAR}) == var.{VAR}" in var
    assert f"var.{VAR} >= 1" in var and f"var.{VAR} <= 5000" in var


# --- 2. worker only, only when set -----------------------------------------------------------------------------------

def test_env_is_emitted_only_when_the_variable_is_set():
    start = ECS.index("t7_blog_seed_env = ")
    local = _code(ECS[start : ECS.index("] : []", start) + len("] : []")])
    assert local.startswith(f"t7_blog_seed_env = var.{VAR} != null ? [")
    assert f'{{ name = "{ENV}", value = tostring(var.{VAR}) }}' in local
    assert local.rstrip().endswith("] : []")


def test_only_the_worker_task_definition_carries_the_seed():
    worker = _task_definition("worker")
    api = _task_definition("api")
    assert "local.t7_blog_seed_env," in worker
    assert "t7_blog_seed_env" not in api
    assert ENV not in api
    # One use in the whole module: the worker container's environment list; the env name only in the local.
    assert _code(ECS).count("local.t7_blog_seed_env") == 1
    assert _code(ECS).count(ENV) == 1


# --- 3. the live root sets 600 ---------------------------------------------------------------------------------------

def test_live_root_sets_600_words():
    vals = re.findall(rf"^\s*{VAR}\s*=\s*(\S+)\s*$", _module_ecs(), re.M)
    assert vals == ["600"]
    assert ENV not in _code(MAIN)
