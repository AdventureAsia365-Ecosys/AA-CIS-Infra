"""AA-1023 (root ADR 0012 decision 6, step 2): every workflow that assumes the Dev apply role runs in the GitHub
environment `dev`; none is left on `prod`, the name a future prod apply role will trust (step 4).

Offline: reads the workflows; no AWS. Run from the repo root: python3 -m pytest -p no:cacheprovider -q tools/terraform/tests
"""
from __future__ import annotations

import os
import re

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
WORKFLOWS = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".github", "workflows"))

# workflow file -> jobs that assume aa-cis-infra-tf-apply (the Dev apply role) through the environment secret.
APPLY_ROLE_JOBS = {
    "db-freshness-probe.yml": None,
    "db-isolation-probe.yml": None,
    "db-migrate.yml": None,
    "db-schema-dump.yml": None,
    "db-tour-liveness-gate.yml": None,
    "terraform-apply.yml": {"terraform-apply", "idle-gate-check"},
}


def _load(name: str) -> dict:
    with open(os.path.join(WORKFLOWS, name), encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def _env(job: dict):
    env = job.get("environment")
    return env.get("name") if isinstance(env, dict) else env


def test_no_workflow_job_runs_in_prod():
    found = []
    for name in sorted(os.listdir(WORKFLOWS)):
        if not name.endswith((".yml", ".yaml")):
            continue
        for job_id, job in (_load(name).get("jobs") or {}).items():
            env = _env(job or {})
            if isinstance(env, str) and (env == "prod" or re.search(r"'prod'", env)):
                found.append(f"{name}:{job_id}")
    assert not found, f"jobs still in the GitHub environment prod: {found}"


def test_the_apply_role_workflows_run_in_dev():
    for name, jobs in APPLY_ROLE_JOBS.items():
        wf = _load(name)
        with_env = {j: _env(v) for j, v in wf["jobs"].items() if _env(v)}
        selected = with_env if jobs is None else {j: with_env[j] for j in jobs}
        assert selected, name
        for job_id, env in selected.items():
            assert env in ("dev", "${{ inputs.environment || 'dev' }}"), f"{name}:{job_id} runs in {env!r}"


def test_the_isolation_probe_defaults_to_dev():
    probe = _load("db-isolation-probe.yml")
    # PyYAML reads the `on:` key as True
    on = probe.get("on", probe.get(True))
    assert on["workflow_call"]["inputs"]["environment"]["default"] == "dev"


def test_the_apply_workflow_is_named_for_dev():
    assert _load("terraform-apply.yml")["name"] == "Terraform Apply Dev"
