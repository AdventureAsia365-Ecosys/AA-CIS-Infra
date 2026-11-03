"""AA-1004 P0 (prod plan P0): the prod paths of this repo are dispatch-only, refuse to run until the prod account is
ready, and can never target Dev.

Two prod paths: Deploy Prod (.github/workflows/deploy-prod.yml, Terraform of the future accounts/aa-prod root) and DB
Migrate environment=prod (.github/workflows/db-migrate.yml). Both go through .github/scripts/prod-guard.sh:
  ready     refuses unless the repo variable PROD_ACCOUNT_READY is exactly "true" (set in P2), in a job with no
            GitHub environment and no AWS access, before any `prod` environment job starts;
  identity  right after OIDC: the caller account is PROD_ACCOUNT_ID and is not the Dev account (by hash);
  protected the GitHub environment `prod` has a required reviewer and a deployment branch policy (it exists today
            without either, left by AA-1023), checked before any `prod` job starts and again inside it;
  names     prod resource names are set and none names Dev.

Offline: runs the script with bash (a fake `gh` on PATH for `protected`) and reads the workflows; no AWS, no GitHub. Run from the repo root:
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


def fake_gh(tmp: Path, body: str, rc: int = 0) -> str:
    """A PATH with a `gh` that records its arguments and prints `body` (exit `rc`), then the real PATH."""
    bin_dir = tmp / "bin"
    bin_dir.mkdir(exist_ok=True)
    (tmp / "gh_body.json").write_text(body)
    gh = bin_dir / "gh"
    gh.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" > "{tmp}/gh_args"\ncat "{tmp}/gh_body.json"\nexit {rc}\n')
    gh.chmod(0o755)
    return f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"


PROTECTED = (
    '{"name": "prod", "protection_rules": ['
    '{"type": "required_reviewers", "reviewers": [{"type": "User", "reviewer": {"login": "someone"}}]},'
    '{"type": "branch_policy"}],'
    ' "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}'
)


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


needs_jq = pytest.mark.skipif(shutil.which("jq") is None, reason="prod-guard.sh protected reads the reply with jq")


@needs_jq
def test_protected_passes_for_a_reviewed_main_only_environment(tmp_path):
    rc, log, _ = guard("protected", tmp=tmp_path, PATH=fake_gh(tmp_path, PROTECTED), REPO="example-org/example-infra",
                       GH_TOKEN="x")
    assert rc == 0, log
    assert (tmp_path / "gh_args").read_text().split() == ["api", "repos/example-org/example-infra/environments/prod"]


@needs_jq
@pytest.mark.parametrize("body,why", [
    # what the environment looks like today: exists, no rules, no branch policy
    ('{"name": "prod", "protection_rules": [], "deployment_branch_policy": null}', "no required reviewer"),
    # a required_reviewers rule with nobody in it
    ('{"name": "prod", "protection_rules": [{"type": "required_reviewers", "reviewers": []}],'
     ' "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}', "no required reviewer"),
    # a reviewer but any branch may deploy
    ('{"name": "prod", "protection_rules": [{"type": "required_reviewers", "reviewers": [{"type": "User"}]}],'
     ' "deployment_branch_policy": null}', "no deployment branch policy"),
    ("not json", "could not be read as JSON"),
])
def test_protected_refuses_an_unprotected_environment(tmp_path, body, why):
    rc, log, _ = guard("protected", tmp=tmp_path, PATH=fake_gh(tmp_path, body), REPO="example-org/example-infra",
                       GH_TOKEN="x")
    assert rc == 1, log
    assert why in log


@needs_jq
def test_protected_refuses_a_missing_environment(tmp_path):
    """A job naming a missing environment auto-creates it unprotected, so a 404 is a refusal, not a pass."""
    rc, log, _ = guard("protected", tmp=tmp_path, PATH=fake_gh(tmp_path, '{"message": "Not Found"}', rc=1),
                       REPO="example-org/example-infra", GH_TOKEN="x")
    assert rc == 1 and "cannot read the GitHub environment prod" in log


def test_protected_refuses_without_the_repo(tmp_path):
    rc, log, _ = guard("protected", tmp=tmp_path, PATH=fake_gh(tmp_path, PROTECTED), REPO="")
    assert rc == 1 and "REPO" in log
    assert not (tmp_path / "gh_args").exists()


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
    assert g["permissions"] == {"contents": "read", "actions": "read"}
    assert load(DEPLOY_PROD)["permissions"] == {"contents": "read"}
    runs = [s.get("run", "") for s in g["steps"]]
    assert any("prod-guard.sh ready" in r for r in runs)
    prot = next(s for s in g["steps"] if s.get("name") == "Prod environment protected")
    assert prot["run"] == "bash .github/scripts/prod-guard.sh protected"
    assert prot["env"] == {"GH_TOKEN": "${{ github.token }}", "REPO": "${{ github.repository }}"}
    assert "if" not in prot
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
    # the first step after checkout re-checks the environment protection, before any secret is read
    assert names[1] == "Prod environment protected"
    assert steps[1]["run"] == "bash .github/scripts/prod-guard.sh protected"
    assert "secrets." not in yaml.safe_dump(steps[:2])
    assert job["permissions"]["actions"] == "read"


def test_deploy_prod_never_prints_plan_or_apply_text():
    """Public repo: applied resource ids are ARNs / URLs with the prod account id. Every terraform plan / apply writes
    -json into a temp file, and only drift_report.py (addresses and actions) reaches the summary."""
    steps = {s.get("name"): s for s in load(DEPLOY_PROD)["jobs"]["terraform"]["steps"]}
    apply = steps["Terraform Apply"]["run"]
    cmd = next(line for line in apply.splitlines() if line.strip().startswith("terraform ") and " apply " in line)
    assert " -json " in cmd and "-no-color" not in cmd
    assert cmd.rstrip().endswith('> "$LOG"'), cmd
    assert "drift_report.py --mode apply" in apply and '--exit-code "$RC"' in apply
    assert "umask 077" in apply and "rm -f \"$LOG\"" in apply
    assert apply.rstrip().endswith("exit $RC")
    plan = steps["Terraform Plan (summary only)"]["run"]
    cmd = next(line for line in plan.splitlines() if line.strip().startswith("terraform ") and " plan " in line)
    assert " -json " in cmd and cmd.rstrip().endswith('> "$LOG"'), cmd
    # no other step runs a terraform command whose output reaches the log, other than init / validate / show -json
    for name, step in steps.items():
        for line in step.get("run", "").splitlines():
            line = line.strip()
            if line.startswith("terraform "):
                verb = re.search(r"terraform (?:-chdir=\S+ )?(\w+)", line).group(1)
                assert verb in {"init", "validate", "plan", "apply", "show"}, (name, line)
                if verb == "show":
                    assert "-json" in line and ">" in line, (name, line)


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
    assert target["permissions"] == {"contents": "read", "actions": "read"}
    ready = next(s for s in target["steps"] if "prod-guard.sh ready" in s.get("run", ""))
    assert ready["if"] == "inputs.environment == 'prod'"
    names = [s.get("name", "") for s in target["steps"]]
    prot = target["steps"][names.index("Prod environment protected")]
    assert names.index("Prod environment protected") > names.index("Prod account ready")
    assert prot["if"] == "inputs.environment == 'prod'"
    assert prot["run"] == "bash .github/scripts/prod-guard.sh protected"
    assert prot["env"] == {"GH_TOKEN": "${{ github.token }}", "REPO": "${{ github.repository }}"}
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
    # inside the `prod` job, the environment protection is re-checked first, before any secret or credential
    assert names[1] == "Prod environment protected"
    assert steps[1]["if"] == "inputs.environment == 'prod'"
    assert steps[1]["run"] == "bash .github/scripts/prod-guard.sh protected"
    assert "secrets." not in yaml.safe_dump(steps[:2])


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
