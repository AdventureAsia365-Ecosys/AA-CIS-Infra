"""Tests for tools/secrets/register_check.py (AA-878). Run from the repo root:

    python3 -m pytest -p no:cacheprovider -q tools/secrets/tests

Offline: synthetic register + inventories in tmp_path. The module has no AWS client at all.
"""
from __future__ import annotations

import json
import os
import sys
import textwrap

import pytest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import register_check as rc  # noqa: E402

REGISTER = """
secrets:
  - {name: aa-cis/dev/rds, store: "secretsmanager:acc2", status: keep}
  - {name: aa-cis/dev/api-keys, store: "secretsmanager:acc2", status: orphan-delete}
  - {name: aa-cis/dev/e2e-test-viewer, store: "secretsmanager:acc2", status: planned}
  - {name: aa-cis/dev/old, store: "secretsmanager:acc2", status: deleted}
  - {name: ADMIN_SECRET, store: "github:AA-CIS-App", status: keep}
  - {name: VERCEL_DEPLOY_HOOK, store: "github:AA-CIS-App", status: orphan-delete}
  - {name: TF_VAR_DB_PASSWORD, store: "github:AA-CIS-Infra/prod", status: keep}
  - {name: ADMIN_SECRET, store: "vercel:aa-cis-frontend", status: keep}
  - {name: TRIPPLANNER_API_KEY, store: "lambda-env:aa-tripplanner-dev-browse", status: pending-removal}
  - {name: MAPBOX_GEOCODING_TOKEN_ARN, store: "lambda-env:aa-tripplanner-dev-assembly", status: pending-removal}
  - {name: TrueIDC payer console, store: "vendor:trueidc", status: keep}
"""


def _write(tmp_path, name, content):
    p = tmp_path / name
    p.write_text(content if isinstance(content, str) else json.dumps(content), encoding="utf-8")
    return p


def _aws(*names, deleted=()):
    lst = [{"Name": n, "ARN": f"arn:x:{n}"} for n in names]
    lst += [{"Name": n, "DeletedDate": "2026-10-19T00:00:00Z"} for n in deleted]
    return {"SecretList": lst}


@pytest.fixture
def register(tmp_path):
    return _write(tmp_path, "register.yaml", REGISTER)


def _run(register, tmp_path, capsys, aws=None, gh=None, vercel=None, lambda_env=None):
    argv = ["--register", str(register)]
    if aws is not None:
        argv += ["--aws", str(_write(tmp_path, "aws.json", aws))]
    if gh is not None:
        d = tmp_path / "gh"
        d.mkdir()
        for fname, names in gh.items():
            _write(d, fname, [{"name": n, "updatedAt": "2026-10-01T00:00:00Z"} for n in names])
        argv += ["--gh", str(d)]
    if vercel is not None:
        argv += ["--vercel", str(_write(tmp_path, "vercel.json", vercel))]
    if lambda_env is not None:
        argv += ["--lambda-env", str(_write(tmp_path, "lambda.json", lambda_env))]
    code = rc.main(argv)
    out = capsys.readouterr().out.splitlines()
    return code, [line for line in out if not line.startswith(("checked stores", "not checked", "diff ="))], out


def test_clean_inventory_is_diff_zero(register, tmp_path, capsys):
    code, diffs, out = _run(
        register, tmp_path, capsys,
        aws=_aws("aa-cis/dev/rds", deleted=["aa-cis/dev/api-keys"]),
        gh={"AA-CIS-App.json": ["ADMIN_SECRET"], "AA-CIS-Infra@prod.json": ["TF_VAR_DB_PASSWORD"]},
        vercel={"aa-cis-frontend": [{"key": "ADMIN_SECRET", "target": ["preview"]}]},
        lambda_env={"aa-tripplanner-dev-browse": ["ENVIRONMENT", "TRIPPLANNER_DATABASE_URL_ARN"],
                    "aa-tripplanner-dev-assembly": ["ENVIRONMENT"]},
    )
    assert (code, diffs) == (0, []), out
    assert out[-1] == "diff = 0"


def test_unregistered_vercel_name_is_a_diff(register, tmp_path, capsys):
    code, diffs, _ = _run(register, tmp_path, capsys,
                          vercel={"aa-cis-frontend": ["ADMIN_SECRET", "INTERNAL_API_KEY", "API_URL",
                                                      "NEXT_PUBLIC_MAPBOX_TOKEN", "COGNITO_CLIENT_ID"]})
    # Plain config (API_URL, *_ID) and public NEXT_PUBLIC_* names need no row.
    assert (code, diffs) == (1, ["UNREGISTERED vercel:aa-cis-frontend INTERNAL_API_KEY"])


def test_exact_diff_lines_and_exit_code(register, tmp_path, capsys):
    code, diffs, out = _run(
        register, tmp_path, capsys,
        aws=_aws("aa-cis/dev/api-keys", "aa-cis/dev/e2e-test-viewer", "aa-cis/dev/new-thing",
                 "aa-cis/dev/old", deleted=["aa-cis/dev/rds"]),
        gh={"AA-CIS-App.json": ["VERCEL_DEPLOY_HOOK", "ACPCORE_READ_TOKEN"]},
        lambda_env={"aa-tripplanner-dev-browse": ["TRIPPLANNER_API_KEY", "ADMIN_SECRET",
                                                  "TRIPPLANNER_DATABASE_URL_ARN", "BEDROCK_REGION"],
                    "aa-tripplanner-dev-assembly": ["MAPBOX_GEOCODING_TOKEN_ARN"]},
    )
    assert code == 1
    assert diffs == sorted([
        "MISSING github:AA-CIS-App ADMIN_SECRET (register: keep)",
        "LAMBDA-ENV-SECRET lambda-env:aa-tripplanner-dev-browse ADMIN_SECRET (plaintext env key looks like a secret)",
        "PLANNED-NOW-PRESENT secretsmanager:acc2 aa-cis/dev/e2e-test-viewer (set status: keep)",
        "SCHEDULED-FOR-DELETION secretsmanager:acc2 aa-cis/dev/rds (register: keep)",
        "STILL-PRESENT github:AA-CIS-App VERCEL_DEPLOY_HOOK (register: orphan-delete)",
        "STILL-PRESENT lambda-env:aa-tripplanner-dev-assembly MAPBOX_GEOCODING_TOKEN_ARN (register: pending-removal)",
        "STILL-PRESENT lambda-env:aa-tripplanner-dev-browse TRIPPLANNER_API_KEY (register: pending-removal)",
        "STILL-PRESENT secretsmanager:acc2 aa-cis/dev/api-keys (register: orphan-delete)",
        "STILL-PRESENT secretsmanager:acc2 aa-cis/dev/old (register: deleted)",
        "UNREGISTERED github:AA-CIS-App ACPCORE_READ_TOKEN",
        "UNREGISTERED secretsmanager:acc2 aa-cis/dev/new-thing",
    ])
    assert out[-1] == f"diff = {len(diffs)}"


def test_diff_zero_exits_zero(tmp_path, capsys):
    reg = _write(tmp_path, "r.yaml", textwrap.dedent("""
        secrets:
          - {name: a, store: "secretsmanager:acc2", status: keep}
          - {name: b, store: "vendor:mapbox", status: keep}
    """))
    code, diffs, out = _run(reg, tmp_path, capsys, aws=_aws("a"))
    assert (code, diffs, out[-1]) == (0, [], "diff = 0")


def test_stores_without_inventory_are_not_checked(register, tmp_path, capsys):
    # Only --aws: github/vercel/lambda rows are not compared (and not reported as missing).
    code, diffs, out = _run(register, tmp_path, capsys, aws=_aws("aa-cis/dev/rds"))
    assert code == 0, out
    assert diffs == []
    assert any(line.startswith("not checked") for line in out)


def test_compact_inventory_shape_is_accepted(register, tmp_path, capsys):
    compact = [{"n": "aa-cis/dev/rds", "del": None}, {"n": "aa-cis/dev/api-keys", "del": "2026-10-19"}]
    code, diffs, _ = _run(register, tmp_path, capsys, aws=compact)
    assert (code, diffs) == (0, [])


def test_scheduled_but_unregistered_is_reported(register, tmp_path, capsys):
    code, diffs, _ = _run(register, tmp_path, capsys, aws=_aws("aa-cis/dev/rds", deleted=["mystery"]))
    assert code == 1
    assert diffs == ["UNREGISTERED secretsmanager:acc2 mystery"]


@pytest.mark.parametrize("key,secretish", [
    ("TRIPPLANNER_API_KEY", True), ("ADMIN_SECRET", True), ("DB_PASSWORD", True), ("GH_TOKEN", True),
    ("TRIPPLANNER_DATABASE_URL_ARN", False), ("SECRET_NAME", False), ("API_KEY_HEADER", False),
    ("BEDROCK_EXTERNAL_ID_PRIMARY", False), ("COGNITO_CLIENT_ID", False), ("API_BASE_URL", False),
])
def test_lambda_env_secret_heuristic(key, secretish):
    assert rc.looks_like_secret_value(key) is secretish


@pytest.mark.parametrize("content,needle", [
    ("secrets: [{name: a, store: 'secretsmanager:acc2', status: bogus}]", "unknown status"),
    ("secrets: [{name: a, store: 'secretsmanager:acc2'}]", "needs name, store and status"),
    ("nothing: here", "no 'secrets' list"),
    ("secrets: [{name: a, store: s, status: keep}, {name: a, store: s, status: keep}]", "duplicate"),
])
def test_bad_register_exits_2(tmp_path, capsys, content, needle):
    reg = _write(tmp_path, "r.yaml", content)
    assert rc.main(["--register", str(reg), "--aws", str(_write(tmp_path, "a.json", _aws()))]) == 2
    assert needle in capsys.readouterr().err


def test_bad_inventory_exits_2(register, tmp_path, capsys):
    bad = _write(tmp_path, "a.json", "{not json")
    assert rc.main(["--register", str(register), "--aws", str(bad)]) == 2
    assert "cannot read" in capsys.readouterr().err


def test_never_touches_aws(monkeypatch, register, tmp_path, capsys):
    """The checker works on files only: importing boto3 is not even possible here."""
    monkeypatch.setitem(sys.modules, "boto3", None)
    monkeypatch.setitem(sys.modules, "botocore", None)
    code, diffs, _ = _run(register, tmp_path, capsys, aws=_aws("aa-cis/dev/rds"))
    assert (code, diffs) == (0, [])


def test_output_holds_names_only(register, tmp_path, capsys):
    """An inventory that (wrongly) carries a SecretString never has it echoed."""
    aws = {"SecretList": [{"Name": "aa-cis/dev/rds", "SecretString": "dsn-with-password-VALUE"},
                          {"Name": "x", "SecretString": "TOPSECRETVALUE"}]}
    _, _, out = _run(register, tmp_path, capsys, aws=aws)
    text = "\n".join(out)
    assert "VALUE" not in text and "TOPSECRETVALUE" not in text
    assert "UNREGISTERED secretsmanager:acc2 x" in text
