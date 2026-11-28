"""AA-1183 part 2: the aa-ecosys-ci-bot private key is read only by jobs that run in the environment `ci-bot`
(deployment branches: main only), and such a job never assumes an AWS role (an environment changes the OIDC subject
the plan / apply roles trust, so AWS work and the App key live in separate jobs).

Offline: reads the workflows; no AWS, no GitHub. Run from the repo root:
python3 -m pytest -p no:cacheprovider -q tools/security/tests/test_aa1183_ci_bot_environment.py
"""
from __future__ import annotations

import os

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
WORKFLOWS = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".github", "workflows"))
KEY = "secrets.AA_CI_BOT_PRIVATE_KEY"


def _jobs():
    for name in sorted(os.listdir(WORKFLOWS)):
        if not name.endswith((".yml", ".yaml")):
            continue
        with open(os.path.join(WORKFLOWS, name), encoding="utf-8") as fh:
            doc = yaml.safe_load(fh) or {}
        for job_id, job in (doc.get("jobs") or {}).items():
            if isinstance(job, dict):
                yield name, job_id, job


def _env(job: dict):
    env = job.get("environment")
    return env.get("name") if isinstance(env, dict) else env


def test_key_only_in_ci_bot_jobs():
    bad = [f"{n}:{j} ({_env(job)!r})" for n, j, job in _jobs()
           if KEY in yaml.safe_dump(job) and _env(job) != "ci-bot"]
    assert not bad, f"jobs that read the CI bot key outside environment ci-bot: {bad}"


def test_ci_bot_jobs_assume_no_aws_role():
    bad = [f"{n}:{j}" for n, j, job in _jobs() if _env(job) == "ci-bot"
           and ("configure-aws-credentials" in yaml.safe_dump(job) or (job.get("permissions") or {}).get("id-token"))]
    assert not bad, f"ci-bot jobs with AWS credentials or id-token: {bad}"


def test_ci_bot_jobs_are_main_only():
    """The environment refuses other branches anyway; the job says so too, so a PR run skips instead of failing."""
    for name, job_id, job in _jobs():
        if _env(job) != "ci-bot":
            continue
        cond = str(job.get("if") or "")
        assert "refs/heads/main" in cond, f"{name}:{job_id} has no main-only condition"
