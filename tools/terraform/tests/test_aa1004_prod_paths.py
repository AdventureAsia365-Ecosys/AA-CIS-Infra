"""AA-1004 P0 (prod plan P0): the prod paths of this repo are dispatch-only, refuse to run until the prod account is
ready, and can never target Dev.

Two prod paths: Deploy Prod (.github/workflows/deploy-prod.yml, Terraform of the future accounts/aa-prod root) and DB
Migrate environment=prod (.github/workflows/db-migrate.yml). Both go through .github/scripts/prod-guard.sh:
  ready     refuses unless the repo variable PROD_ACCOUNT_READY is exactly "true" (set in P2), in a job with no
            GitHub environment and no AWS access, before any `prod` environment job starts;
  identity  right after OIDC: the caller account is PROD_ACCOUNT_ID and is not the Dev account (by hash);
  names     prod resource names are set and none names Dev.

Offline: runs the script with bash and reads the workflows; no AWS. Run from the repo root:
    python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1004_prod_paths.py
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[3]
GUARD = ROOT / ".github" / "scripts" / "prod-guard.sh"
WORKFLOWS = ROOT / ".github" / "workflows"
DEPLOY_PROD = WORKFLOWS / "deploy-prod.yml"
DB_MIGRATE = WORKFLOWS / "db-migrate.yml"

# Invented account ids for the script tests (never real ones).
DEV = "111111111111"
PROD = "222222222222"
OTHER = "333333333333"

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="bash runs prod-guard.sh")


def guard(*args: str, tmp: Path, **env: str) -> tuple[int, str, dict]:
    out = tmp / "github_output"
    out.write_text("")
    full = {"PATH": os.environ.get("PATH", ""), "GITHUB_OUTPUT": str(out), **env}
    p = subprocess.run(["bash", str(GUARD), *args], env=full, capture_output=True, text=True, timeout=30)
    outputs = dict(line.split("=", 1) for line in out.read_text().splitlines() if "=" in line)
    return p.returncode, p.stdout + p.stderr, outputs


def sha(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def load(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def on_block(wf: dict) -> dict:
    return wf.get("on", wf.get(True))  # YAML 1.1 reads a bare `on` as True


# ---- prod-guard.sh ------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("ready", ["", "false", "TRUE", "yes", "true "])
def test_ready_refuses_unless_exactly_true(tmp_path, ready):
    rc, log, out = guard("ready", tmp=tmp_path, PROD_ACCOUNT_READY=ready, DEV_ROLE_ARN=f"arn:aws:iam::{DEV}:role/x")
    assert rc == 1
    assert "the prod account is not ready" in log and "Nothing ran" in log
    assert out == {}


def test_ready_refuses_without_the_dev_role(tmp_path):
    for arn in ("", "not-an-arn", f"arn:aws:iam::{DEV}:user/x"):
        rc, log, _ = guard("ready", tmp=tmp_path, PROD_ACCOUNT_READY="true", DEV_ROLE_ARN=arn)
        assert rc == 1, arn
        assert "AWS_ROLE_ARN" in log


def test_ready_passes_and_outputs_only_a_hash(tmp_path):
    rc, log, out = guard("ready", tmp=tmp_path, PROD_ACCOUNT_READY="true", DEV_ROLE_ARN=f"arn:aws:iam::{DEV}:role/plan")
    assert rc == 0, log
    assert out == {"dev_account_sha256": sha(DEV)}
    assert DEV not in log


def test_identity_passes_for_the_prod_account(tmp_path):
    rc, log, _ = guard("identity", tmp=tmp_path, CALLER_ACCOUNT=PROD, PROD_ACCOUNT_ID=PROD, DEV_ACCOUNT_SHA256=sha(DEV))
    assert rc == 0, log
    assert PROD not in log


@pytest.mark.parametrize("caller,want,why", [
    (DEV, PROD, "belong to the Dev account"),          # prod secret right, credentials land in Dev
    (DEV, DEV, "belong to the Dev account"),           # both point at Dev
    (OTHER, PROD, "do not belong to the configured prod account"),
    ("", PROD, "could not read the caller account"),
    (PROD, "", "PROD_ACCOUNT_ID is missing"),
])
def test_identity_refuses(tmp_path, caller, want, why):
    rc, log, _ = guard("identity", tmp=tmp_path, CALLER_ACCOUNT=caller, PROD_ACCOUNT_ID=want, DEV_ACCOUNT_SHA256=sha(DEV))
    assert rc == 1
    assert why in log
    assert DEV not in log and PROD not in log


def test_identity_refuses_without_the_dev_fingerprint(tmp_path):
    rc, log, _ = guard("identity", tmp=tmp_path, CALLER_ACCOUNT=PROD, PROD_ACCOUNT_ID=PROD, DEV_ACCOUNT_SHA256="")
    assert rc == 1 and "fingerprint" in log


@pytest.mark.parametrize("value", ["aa-cis-dev-cluster", "/ecs/aa-cis-dev", "dev/terraform.tfstate", "dev", "x.dev"])
def test_names_refuse_dev(tmp_path, value):
    rc, log, _ = guard("names", "CLUSTER=aa-cis-prod-cluster", f"OTHER={value}", tmp=tmp_path)
    assert rc == 1 and "OTHER names a Dev resource" in log


def test_names_refuse_empty(tmp_path):
    rc, log, _ = guard("names", "CLUSTER=", tmp=tmp_path)
    assert rc == 1 and "CLUSTER is empty" in log


def test_names_pass_for_prod_names(tmp_path):
    rc, log, _ = guard("names", "CLUSTER=aa-cis-prod-cluster", "LOG_GROUP=/ecs/aa-cis-prod", "KEY=prod/terraform.tfstate",
                       "BUCKET=aa-tfstate-devonshire", tmp=tmp_path)
    assert rc == 0, log


def test_bad_usage(tmp_path):
    assert guard(tmp=tmp_path)[0] == 2
    assert guard("names", tmp=tmp_path)[0] == 2
    assert guard("names", "NOEQUALS", tmp=tmp_path)[0] == 2


# ---- Deploy Prod ----------------------------------------------------------------------------------------------------


def test_deploy_prod_is_dispatch_only():
    on = on_block(load(DEPLOY_PROD))
    assert set(on) == {"workflow_dispatch"}
    assert on["workflow_dispatch"]["inputs"]["action"]["options"] == ["plan", "apply"]
    assert on["workflow_dispatch"]["inputs"]["action"]["default"] == "plan"


def test_deploy_prod_guard_job_comes_first_without_aws():
    jobs = load(DEPLOY_PROD)["jobs"]
    g = jobs["guard"]
    assert "environment" not in g
    assert (g.get("permissions") or {}).get("id-token") is None
    assert load(DEPLOY_PROD)["permissions"] == {"contents": "read"}
    runs = [s.get("run", "") for s in g["steps"]]
    assert any("prod-guard.sh ready" in r for r in runs)
    assert not any(s.get("uses", "").startswith("aws-actions/") for s in g["steps"])
    assert jobs["terraform"]["needs"] == "guard"
    assert set(jobs) == {"guard", "terraform"}


def test_deploy_prod_terraform_job_is_prod_only():
    job = load(DEPLOY_PROD)["jobs"]["terraform"]
    text = DEPLOY_PROD.read_text(encoding="utf-8")
    assert job["environment"] == "prod"
    assert job["env"]["ROOT"] == "accounts/aa-prod"
    assert job["env"]["STATE_KEY"] == "prod/terraform.tfstate"
    steps = job["steps"]
    names = [s.get("name", "") for s in steps]
    oidc = next(i for i, s in enumerate(steps) if s.get("uses", "").startswith("aws-actions/configure-aws-credentials"))
    assert steps[oidc]["with"]["role-to-assume"] == "${{ secrets.PROD_TF_ROLE_ARN }}"
    # names before OIDC, identity right after it, before Terraform touches anything
    assert names.index("Prod names") < oidc
    assert names[oidc + 1] == "Prod identity (never Dev)"
    assert "prod-guard.sh identity" in steps[oidc + 1]["run"]
    # never the Dev role, the Dev root or the Dev state key
    assert "secrets.AWS_ROLE_ARN" not in yaml.safe_dump(job)
    assert "accounts/aa365" not in text.split("jobs:", 1)[1]
    assert "dev/terraform.tfstate" not in text
    apply = next(s for s in steps if s.get("name") == "Terraform Apply")
    assert "inputs.action == 'apply'" in apply["if"]


def test_deploy_prod_requires_the_confirmation():
    g = load(DEPLOY_PROD)["jobs"]["guard"]
    run = next(s["run"] for s in g["steps"] if s.get("name") == "Inputs and root")
    assert "'apply prod'" in run
    assert "accounts/aa-prod/versions.tf" in run


def test_deploy_prod_has_its_own_concurrency_group():
    wf = load(DEPLOY_PROD)
    assert wf["concurrency"]["group"] == "deploy-prod"
    assert load(WORKFLOWS / "terraform-apply.yml")["concurrency"]["group"] != "deploy-prod"


# ---- DB Migrate environment=prod -------------------------------------------------------------------------------------


def test_db_migrate_prod_is_a_choice_behind_the_target_guard():
    wf = load(DB_MIGRATE)
    env_in = on_block(wf)["workflow_dispatch"]["inputs"]["environment"]
    assert env_in["options"] == ["dev", "prod"] and env_in["default"] == "dev"
    target, migrate = wf["jobs"]["target"], wf["jobs"]["migrate"]
    assert "environment" not in target
    assert target["permissions"] == {"contents": "read"}
    ready = next(s for s in target["steps"] if "prod-guard.sh ready" in s.get("run", ""))
    assert ready["if"] == "inputs.environment == 'prod'"
    assert migrate["needs"] == "target"
    assert migrate["environment"] == "${{ inputs.environment == 'prod' && 'prod' || 'dev' }}"


def test_db_migrate_dev_values_are_unchanged_and_selected_first():
    env = load(DB_MIGRATE)["jobs"]["migrate"]["env"]
    dev = {"AWS_REGION": "us-west-1", "CLUSTER": "aa-cis-dev-cluster", "SERVICE": "aa-cis-dev-api",
           "LOG_GROUP": "/ecs/aa-cis-dev", "DB_INSTANCE": "aa-cis-dev-db"}
    for key, value in dev.items():
        # `dev && <dev literal> || <prod var>`: an unset prod variable is empty, never the Dev name.
        assert re.fullmatch(rf"\$\{{\{{ inputs\.environment == 'dev' && '{re.escape(value)}' \|\| vars\.[A-Z_]+ \}}\}}",
                            env[key]), (key, env[key])
    assert re.fullmatch(r"\$\{\{ inputs\.environment == 'dev' && 'aa-cis-bronze-[0-9]{12}' \|\| vars\.DB_MIGRATE_BUCKET \}\}",
                        env["BUCKET"])


def test_db_migrate_prod_never_falls_back_to_the_dev_role():
    steps = load(DB_MIGRATE)["jobs"]["migrate"]["steps"]
    names = [s.get("name", "") for s in steps]
    oidc = names.index("Configure AWS credentials (OIDC)")
    role = steps[oidc]["with"]["role-to-assume"]
    assert role == "${{ inputs.environment == 'dev' && secrets.AWS_ROLE_ARN || secrets.PROD_DB_MIGRATE_ROLE_ARN }}"
    assert steps[oidc]["with"]["aws-region"] == "${{ env.AWS_REGION }}"
    # names before OIDC; the identity check is the very next step, before the snapshot / task steps
    assert names.index("Prod names") < oidc
    assert names[oidc + 1] == "Prod identity (never Dev)"
    assert steps[oidc + 1]["if"] == "inputs.environment == 'prod'"
    assert "prod-guard.sh identity" in steps[oidc + 1]["run"]
    assert names.index("Validate input") < oidc


def test_db_migrate_follow_up_dispatches_stay_dev_only():
    steps = {s.get("name"): s for s in load(DB_MIGRATE)["jobs"]["migrate"]["steps"]}
    for name in ("Regenerate the schema reference (DB Schema Dump)", "Re-run the isolation probe (DB Isolation Probe)"):
        assert steps[name]["if"].endswith("&& inputs.environment == 'dev'"), name


def test_prod_jobs_read_no_dev_secret_unguarded():
    """In a job that can run in `prod`, the Dev role secret appears only behind `inputs.environment == 'dev' &&`."""
    for path, job_id in ((DB_MIGRATE, "migrate"), (DEPLOY_PROD, "terraform")):
        text = yaml.safe_dump(load(path)["jobs"][job_id], width=10_000)
        for m in re.finditer(r"secrets\.AWS_ROLE_ARN", text):
            assert text[max(0, m.start() - 40): m.start()].endswith("inputs.environment == 'dev' && "), (path.name, job_id)


def test_no_account_id_literal_in_the_new_files():
    for path in (GUARD, DEPLOY_PROD):
        assert not re.search(r"\b\d{12}\b", path.read_text(encoding="utf-8")), path.name
