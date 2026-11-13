"""AA-1096 L4 (S279): the CRM's per-form hourly inquiry quota is an admin-editable setting (AA-Partner crm-064,
``crm.rate.intake_form_per_hour``) with a per-agency override. The CRM reads an env var of a setting as an emergency
override that wins over every agency's own value, so the CRM task definition must not set
``RATE_LIMIT_INTAKE_FORM_PER_HOUR``: with it, a per-agency quota an administrator approves would do nothing.

Offline, no Terraform run: the env list of the crm_api task definition, comments stripped.
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CRM_APP = (ROOT / "modules" / "environment" / "crm_app.tf").read_text(encoding="utf-8")


def _code(text: str) -> str:
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def _task_definition() -> str:
    start = CRM_APP.index('resource "aws_ecs_task_definition" "crm_api"')
    end = CRM_APP.index("\nresource ", start + 1)
    return _code(CRM_APP[start:end])


def test_the_crm_task_sets_no_per_form_quota_env_var() -> None:
    assert "RATE_LIMIT_INTAKE_FORM_PER_HOUR" not in _task_definition()


def test_the_other_rate_limit_settings_are_not_set_either() -> None:
    # AA-1096 L6 (S279): the per-address limits are settings too (crm.rate.public_per_minute, crm.rate.intake_per_minute);
    # their env vars would win over the admin page, so the task sets neither. RATE_LIMIT_XFF_HOPS (topology) stays.
    task = _task_definition()
    assert "RATE_LIMIT_INTAKE_PER_MINUTE" not in task
    assert "RATE_LIMIT_PUBLIC_PER_MINUTE" not in task
    assert '{ name = "RATE_LIMIT_XFF_HOPS", value = "2" }' in task
