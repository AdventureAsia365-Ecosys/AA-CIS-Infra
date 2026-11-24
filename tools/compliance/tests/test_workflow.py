"""Shape of .github/workflows/compliance-aws.yml (AA-1173): public-log rules, pins and the role check.

The repo is public: the log prints counts only (no shell tracing, Prowler's output to files, no artifact upload, no
pull_request_target); the Prowler image is pinned by digest; AWS jobs run on main only, never on a pull request, and
verify they hold the compliance evidence role before reading anything.
Run: python3 -m pytest -p no:cacheprovider -q tools/compliance/tests
"""
from __future__ import annotations

import re
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "compliance-aws.yml"
TEXT = WORKFLOW.read_text(encoding="utf-8")
WF = yaml.safe_load(TEXT)
ON = WF.get("on") or WF.get(True)


def _steps(job: str) -> list:
    return WF["jobs"][job]["steps"]


def _runs(job: str) -> str:
    return "\n".join(s.get("run", "") for s in _steps(job))


def test_no_public_log_leaks():
    assert "pull_request_target" not in ON
    assert "upload-artifact" not in TEXT
    assert not re.search(r"set -[a-z]*x", TEXT)
    assert "--debug" not in TEXT


def test_triggers_pull_request_runs_tests_only():
    assert set(ON) == {"schedule", "workflow_dispatch", "pull_request"}
    crons = [c["cron"] for c in ON["schedule"]]
    assert len(crons) == 2
    for job in ("aws", "prowler"):
        cond = WF["jobs"][job]["if"]
        assert "github.ref == 'refs/heads/main'" in cond
        assert "github.event_name != 'pull_request'" in cond
    assert f"github.event.schedule == '{crons[0]}'" in WF["jobs"]["aws"]["if"]
    assert f"github.event.schedule == '{crons[1]}'" in WF["jobs"]["prowler"]["if"]
    assert "id-token" not in (WF["jobs"]["test"].get("permissions") or {})
    assert WF["permissions"] == {"contents": "read"}


def test_prowler_image_pinned_by_digest_and_output_to_files():
    image = WF["env"]["PROWLER_IMAGE"]
    assert re.fullmatch(r"public\.ecr\.aws/prowler-cloud/prowler@sha256:[0-9a-f]{64}", image)
    scan = next(s for s in _steps("prowler") if s.get("name", "").startswith("Scan"))
    assert '> "$OUT/run.log" 2>&1' in scan["run"]
    pull = next(s for s in _steps("prowler") if "docker pull" in s.get("run", ""))
    creds = next(s for s in _steps("prowler") if "configure-aws-credentials" in s.get("uses", ""))
    assert _steps("prowler").index(pull) < _steps("prowler").index(creds), "pull before any credential"


def test_aws_jobs_verify_the_role_and_mask_the_account():
    for job in ("aws", "prowler"):
        steps = _steps(job)
        creds = next(i for i, s in enumerate(steps) if "configure-aws-credentials" in s.get("uses", ""))
        assert steps[creds]["with"]["mask-aws-account-id"] is True
        verify = steps[creds + 1]["run"]
        assert "::add-mask::" in verify and "compliance-evidence/*" in verify
        assert WF["jobs"][job]["permissions"] == {"contents": "read", "id-token": "write"}
        assert "tools/compliance/seal.py" in _runs(job)


def test_secrets_not_variables_and_work_dir_from_runner_temp():
    assert "vars." not in TEXT
    for job in ("aws", "prowler"):
        assert "OUT" not in (WF["jobs"][job].get("env") or {})
        assert '>> "$GITHUB_ENV"' in _steps(job)[1]["run"] and "$RUNNER_TEMP" in _steps(job)[1]["run"]


def test_every_action_is_sha_pinned():
    for m in re.finditer(r"uses:\s*([^\s#]+)", TEXT):
        ref = m.group(1)
        assert re.search(r"@[0-9a-f]{40}$", ref), ref
