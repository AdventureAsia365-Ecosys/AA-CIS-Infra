"""Tests of tools/compliance/seal.py (AA-1173): write-once objects, the manifest last, the hash chain, safe errors.

The same file lives in the root repo (AA-Ecosys tools/compliance/seal.py); SEAL_SHA256 below is the hash of that shared
file and is updated in both PRs together, so the two copies cannot drift.
Offline: a fake AWS CLI runner; no network. Run: python3 -m pytest -p no:cacheprovider -q tools/compliance/tests
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
SEAL = HERE.parent / "seal.py"
SEAL_SHA256 = "bf1087c7b9b6126f6d15716e0a48499948b5baa59bdff87abe126189e6302e27"

_spec = importlib.util.spec_from_file_location("seal", SEAL)
seal = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(seal)

NOW = datetime(2026, 3, 4, 5, 6, 7, tzinfo=timezone.utc)


class FakeAws:
    """Records the CLI calls; list answers the given manifest keys, get writes the given previous manifest."""

    def __init__(self, existing: list | None = None, previous: bytes = b'{"format": 1}\n', fail_on: str = ""):
        self.calls: list = []
        self.existing = existing or []
        self.previous = previous
        self.fail_on = fail_on
        self.bodies: dict = {}

    def __call__(self, args: list) -> str:
        self.calls.append(args)
        op = args[1]
        if op == self.fail_on:
            raise seal.SealFailed(f"aws s3api {op} failed (AccessDenied)")
        if op == "put-object":
            key = args[args.index("--key") + 1]
            self.bodies[key] = Path(args[args.index("--body") + 1]).read_bytes()
            return "{}"
        if op == "list-objects-v2":
            return json.dumps({"Contents": [{"Key": k} for k in self.existing]})
        if op == "get-object":
            Path(args[-1]).write_bytes(self.previous)
            return "{}"
        raise AssertionError(f"unexpected call {args}")


def _bundle(tmp_path: Path, source: str = "aws_nightly") -> Path:
    p = tmp_path / "bundle.json"
    p.write_text(json.dumps({"format": 1, "source": source, "checks": []}), encoding="utf-8")
    return p


def test_shared_file_hash_matches_the_root_copy_pin():
    assert hashlib.sha256(SEAL.read_bytes()).hexdigest() == SEAL_SHA256


def test_first_run_writes_raw_then_bundle_then_manifest_once_each(tmp_path):
    raw = tmp_path / "prowler-run.log.gz"
    raw.write_bytes(b"invented log")
    aws = FakeAws()
    out = seal.seal("bkt", "aws_nightly", _bundle(tmp_path), [raw], "123-1", "compliance-aws #9", "abc1234", NOW,
                    run=aws)
    assert out == {"source": "aws_nightly", "objects": 2, "raw": 1, "chain": "first"}
    puts = [c for c in aws.calls if c[1] == "put-object"]
    keys = [c[c.index("--key") + 1] for c in puts]
    assert keys == [
        "evidence/aws_nightly/raw/2026/03/04/050607Z-123-1/prowler-run.log.gz",
        "evidence/aws_nightly/bundles/2026/03/04/050607Z-123-1.json",
        "evidence/aws_nightly/manifest/2026/03/04/050607Z-123-1.json",
    ]
    for c in puts:   # every write is conditional (the bucket refuses a plain PUT) and checksummed (Object Lock)
        assert c[c.index("--if-none-match") + 1] == "*"
        assert c[c.index("--checksum-algorithm") + 1] == "SHA256"
    manifest = json.loads(aws.bodies[keys[-1]])
    assert manifest["previous"] is None
    assert manifest["collector_version"] == "abc1234"
    assert [o["key"] for o in manifest["objects"]] == keys[:2]
    assert manifest["objects"][1]["sha256"] == hashlib.sha256(aws.bodies[keys[1]]).hexdigest()


def test_next_run_links_the_newest_previous_manifest(tmp_path):
    prev = b'{"format": 1, "source": "aws_nightly"}\n'
    older = "evidence/aws_nightly/manifest/2026/03/02/010000Z-1-1.json"
    newer = "evidence/aws_nightly/manifest/2026/03/03/010000Z-2-1.json"
    aws = FakeAws(existing=[newer, older], previous=prev)
    out = seal.seal("bkt", "aws_nightly", _bundle(tmp_path), [], "3-1", "r", None, NOW, run=aws)
    assert out["chain"] == "linked"
    get = next(c for c in aws.calls if c[1] == "get-object")
    assert get[get.index("--key") + 1] == newer
    mkey = next(k for k in aws.bodies if "/manifest/" in k)
    manifest = json.loads(aws.bodies[mkey])
    assert manifest["previous"] == {"key": newer, "sha256": hashlib.sha256(prev).hexdigest()}
    assert manifest["collector_version"] is None


@pytest.mark.parametrize("source,run_id", [("Bad-Source", "1-1"), ("aws_nightly", "../x"), ("x", "1-1")])
def test_bad_source_or_run_id_is_refused(tmp_path, source, run_id):
    with pytest.raises(ValueError):
        seal.seal("bkt", source, _bundle(tmp_path), [], run_id, "r", None, NOW, run=FakeAws())


def test_bundle_of_another_source_is_refused(tmp_path):
    with pytest.raises(ValueError):
        seal.seal("bkt", "prowler_weekly", _bundle(tmp_path, "aws_nightly"), [], "1-1", "r", None, NOW, run=FakeAws())


def test_repeated_raw_name_is_refused(tmp_path):
    raw = tmp_path / "a.json"
    raw.write_text("{}", encoding="utf-8")
    with pytest.raises(ValueError):
        seal.seal("bkt", "aws_nightly", _bundle(tmp_path), [raw, raw], "1-1", "r", None, NOW, run=FakeAws())


def test_a_failed_write_exits_1_and_prints_the_code_only(tmp_path, capsys):
    rc = seal.main(["--bucket", "bkt", "--source", "aws_nightly", "--bundle", str(_bundle(tmp_path)),
                    "--run", "1-1"], run=FakeAws(fail_on="put-object"))
    err = capsys.readouterr().err
    assert rc == 1
    assert "AccessDenied" in err and "arn:" not in err and "bkt" not in err


def test_cli_error_text_is_reduced_to_the_code(monkeypatch):
    def fake_run(*_a, **_k):
        return subprocess.CompletedProcess([], 254, "", "An error occurred (PreconditionFailed) when calling the "
                                                        "PutObject operation: role arn:aws:iam::000000000000:x")
    monkeypatch.setattr(seal.subprocess, "run", fake_run)
    with pytest.raises(seal.SealFailed) as exc:
        seal.aws_cli(["s3api", "put-object"])
    assert str(exc.value) == "aws s3api put-object failed (PreconditionFailed)"


def test_main_prints_counts_and_chain_state(tmp_path, capsys):
    rc = seal.main(["--bucket", "bkt", "--source", "aws_nightly", "--bundle", str(_bundle(tmp_path)),
                    "--run", "1-1", "--version", "not-a-sha"], run=FakeAws())
    assert rc == 0
    assert capsys.readouterr().out.strip() == "sealed 1 object(s) of aws_nightly (0 raw); hash chain first"
