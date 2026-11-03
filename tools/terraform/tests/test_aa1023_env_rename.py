"""AA-1023 (root ADR 0012 decision 6): the rename of the GitHub environment that applies Dev, `prod` -> `dev`.

The apply role aa-cis-infra-tf-apply (accounts/aa365/cicd_split.tf, a bootstrap object applied locally with MFA)
trusts the OIDC subject `<infra>:environment:<name>`. The cut-over is expand / contract:
  1. the trust accepts both `environment:prod` and `environment:dev`;
  2. every workflow moves to `environment: dev`;
  3. `environment:prod` leaves the trust (after one green run of each workflow on `dev`).
The invariant below holds at every step, so a PR that drops a subject a workflow still uses fails here before the
apply locks that workflow out of AWS.

Offline: reads cicd_split.tf and the workflows; no Terraform, no AWS. Run from the repo root:
    python3 -m pytest -p no:cacheprovider -q tools/terraform/tests
"""
from __future__ import annotations

import os
import re

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
CICD_SPLIT = os.path.join(REPO_ROOT, "accounts", "aa365", "cicd_split.tf")
WORKFLOWS = os.path.join(REPO_ROOT, ".github", "workflows")

# The environments whose AWS_ROLE_ARN secret is the apply role. dev-db-auto (aa-cis-infra-db-auto-apply) and org
# (the management account) have roles of their own.
APPLY_ROLE_ENVIRONMENTS = {"prod", "dev"}


def _tf_apply_block() -> str:
    text = open(CICD_SPLIT, encoding="utf-8").read()
    start = text.index('resource "aws_iam_role" "tf_apply" {')
    end = text.index("\n}\n", start)
    return text[start:end]


def trusted_environments() -> set[str]:
    """The `environment:<name>` subjects of the apply role's trust (the AA-CIS-Infra subject prefix only)."""
    block = _tf_apply_block()
    m = re.search(r'"token\.actions\.githubusercontent\.com:sub"\s*=\s*\[(.*?)\]', block, re.S)
    assert m, "the apply role trust has no sub list"
    subs = re.findall(r'"([^"]+)"', m.group(1))
    assert subs, "the apply role trusts no subject"
    out = set()
    for s in subs:
        assert s.startswith("${local.oidc_sub_cis_infra}:environment:"), f"unexpected subject {s!r}"
        out.add(s.rsplit(":", 1)[1])
    return out


def _environment_name(job: dict) -> str | None:
    env = job.get("environment")
    if isinstance(env, dict):
        env = env.get("name")
    return env if isinstance(env, str) else None


def workflow_environments() -> dict[str, set[str]]:
    """{environment name: {"<workflow>:<job>"}} of every job of every workflow. An expression such as
    `${{ inputs.environment || 'dev' }}` counts as each quoted literal in it."""
    out: dict[str, set[str]] = {}
    for name in sorted(os.listdir(WORKFLOWS)):
        if not name.endswith((".yml", ".yaml")):
            continue
        with open(os.path.join(WORKFLOWS, name), encoding="utf-8") as fh:
            wf = yaml.safe_load(fh) or {}
        for job_id, job in (wf.get("jobs") or {}).items():
            env = _environment_name(job or {})
            if env is None:
                continue
            names = re.findall(r"'([^']+)'", env) if "${{" in env else [env]
            for n in names:
                out.setdefault(n, set()).add(f"{name}:{job_id}")
    return out


def test_the_trust_names_only_the_dev_apply_environments():
    assert trusted_environments() <= APPLY_ROLE_ENVIRONMENTS


def test_dev_is_trusted():
    assert "dev" in trusted_environments()


def test_every_apply_role_environment_a_workflow_uses_is_trusted():
    used = {env: jobs for env, jobs in workflow_environments().items() if env in APPLY_ROLE_ENVIRONMENTS}
    missing = {env: sorted(jobs) for env, jobs in used.items() if env not in trusted_environments()}
    assert not missing, f"jobs in an environment the apply role does not trust: {missing}"


def test_the_trust_keeps_the_main_only_ref_condition():
    block = _tf_apply_block()
    assert '"token.actions.githubusercontent.com:ref" = "refs/heads/main"' in block
    assert '"token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"' in block
