"""AA-1081 / AA-1077 (S277): the T7 Blog minimum seed (T7_BLOG_MIN_SEED_WORDS) of the CIS worker.

S277 set it on the worker through the variable t7_blog_min_seed_words (600). Since S279 (AA-1096 L1 / L6) the floor is
the admin-editable setting cis.t7.blog_min_seed_words (AA-CIS-App migration 407, seeded 600) and the worker no longer
reads the env var, so Terraform carries neither the variable nor the env.

Offline, no Terraform run. What must hold:
1. modules/ecs declares no variable t7_blog_min_seed_words and no task definition carries T7_BLOG_MIN_SEED_WORDS.
2. The live root (accounts/aa365) does not pass it to module "ecs".
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ECS = (ROOT / "modules" / "ecs" / "main.tf").read_text(encoding="utf-8")
ECS_VARS = (ROOT / "modules" / "ecs" / "variables.tf").read_text(encoding="utf-8")
MAIN = (ROOT / "accounts" / "aa365" / "main.tf").read_text(encoding="utf-8")

VAR = "t7_blog_min_seed_words"
ENV = "T7_BLOG_MIN_SEED_WORDS"


def _code(block: str) -> str:
    """The text without # comments, so a name mentioned in a comment does not count."""
    return "\n".join(line.split("#", 1)[0] for line in block.splitlines())


def test_the_module_has_no_seed_variable_or_env():
    assert f'variable "{VAR}"' not in ECS_VARS
    assert VAR not in _code(ECS)
    assert ENV not in _code(ECS)
    assert "t7_blog_seed_env" not in _code(ECS)


def test_the_live_root_does_not_pass_it():
    assert VAR not in _code(MAIN)
    assert ENV not in _code(MAIN)
