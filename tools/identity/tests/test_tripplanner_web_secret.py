"""Offline tests of tools/identity/tripplanner_web_secret.py (AA-1038): fakes for STS and Secrets Manager, no AWS.

Run from the repo root: python3 -m pytest -q tools/identity/tests/test_tripplanner_web_secret.py
"""
from __future__ import annotations

import json

import tripplanner_web_secret as tool

# Invented values only; built at run time so no literal looks like a key.
REVALIDATE = "-".join(["fake", "purge", "hmac", "value", "0123456789"])
DSN = "https://" + "fakepublickey" + "@o0.ingest.example.test/1"
WEB = "tripplanner/dev/web"
PURGE = "aa-cis/dev/tripplanner-revalidate-hmac"


class FakeSts:
    def __init__(self, account: str = tool.DEFAULT_ACCOUNT) -> None:
        self.account = account

    def get_caller_identity(self):
        return {"Account": self.account}


class _NotFound(Exception):
    pass


class FakeSm:
    class exceptions:  # noqa: N801 — boto3 shape
        ResourceNotFoundException = _NotFound

    def __init__(self, values: dict[str, str | None]) -> None:
        self.values = dict(values)  # name -> SecretString, or None for a shell without a version
        self.puts: list[tuple[str, dict]] = []

    def describe_secret(self, SecretId):  # noqa: N803 — boto3 names
        if SecretId not in self.values:
            raise _NotFound(SecretId)
        return {"Name": SecretId}

    def get_secret_value(self, SecretId):  # noqa: N803
        if self.values.get(SecretId) is None:
            raise _NotFound(SecretId)
        return {"SecretString": self.values[SecretId]}

    def put_secret_value(self, SecretId, SecretString):  # noqa: N803
        self.values[SecretId] = SecretString
        self.puts.append((SecretId, json.loads(SecretString)))
        return {"VersionId": f"v{len(self.puts)}"}


def _run(argv, sm, capsys, sts=None):
    rc = tool.main(argv, clients=(sts or FakeSts(), sm))
    captured = capsys.readouterr()
    _run.err = captured.err
    return rc, [json.loads(line) for line in captured.out.splitlines()]


def test_dry_run_writes_nothing_and_names_the_keys(capsys):
    sm = FakeSm({WEB: None, PURGE: REVALIDATE})
    rc, lines = _run([], sm, capsys)
    assert rc == 0 and sm.puts == []
    assert lines == [{"secret": WEB, "changed": ["catalog_revalidate_secret", "sentry_dsn", "session_secret"],
                      "sentry": "off", "action": "would_write"}]


def test_apply_fills_the_shell(capsys):
    sm = FakeSm({WEB: None, PURGE: REVALIDATE})
    rc, lines = _run(["--apply", "--sentry-dsn", DSN], sm, capsys)
    assert rc == 0 and lines[0]["action"] == "written" and lines[0]["sentry"] == "on"
    (name, value), = sm.puts
    assert name == WEB
    assert value["catalog_revalidate_secret"] == REVALIDATE
    assert value["sentry_dsn"] == DSN
    assert len(value["session_secret"]) >= tool.MIN_SESSION_SECRET


def test_rerun_keeps_the_session_key_and_other_keys(capsys):
    current = {"session_secret": "s" * 40, "catalog_revalidate_secret": REVALIDATE, "sentry_dsn": DSN, "kept": "k"}
    sm = FakeSm({WEB: json.dumps(current), PURGE: REVALIDATE})
    rc, lines = _run(["--apply"], sm, capsys)
    assert rc == 0 and lines[0]["action"] == "unchanged" and sm.puts == []

    rotated = "-".join(["new", "purge", "value"])
    sm2 = FakeSm({WEB: json.dumps(current), PURGE: rotated})
    _run(["--apply"], sm2, capsys)
    assert sm2.puts == [(WEB, {**current, "catalog_revalidate_secret": rotated})]


def test_a_short_session_key_is_replaced_and_an_empty_dsn_switches_sentry_off(capsys):
    current = {"session_secret": "short", "catalog_revalidate_secret": REVALIDATE, "sentry_dsn": DSN}
    sm = FakeSm({WEB: json.dumps(current), PURGE: REVALIDATE})
    rc, lines = _run(["--apply", "--sentry-dsn", ""], sm, capsys)
    assert rc == 0 and lines[0]["changed"] == ["sentry_dsn", "session_secret"] and lines[0]["sentry"] == "off"
    assert sm.puts[0][1]["session_secret"] != "short"


def test_output_never_contains_a_secret_value(capsys):
    sm = FakeSm({WEB: None, PURGE: REVALIDATE})
    tool.main(["--apply", "--sentry-dsn", DSN], clients=(FakeSts(), sm))
    captured = capsys.readouterr()
    written = sm.puts[0][1]
    for value in (REVALIDATE, DSN, written["session_secret"]):
        assert value not in captured.out and value not in captured.err


def test_refusals(capsys):
    rc, _ = _run(["--apply"], FakeSm({PURGE: REVALIDATE}), capsys)
    assert rc == 1
    assert "does not exist" in _run.err

    rc, _ = _run(["--apply"], FakeSm({WEB: None}), capsys)
    assert rc == 1
    assert "no value" in _run.err

    rc, _ = _run(["--apply"], FakeSm({WEB: None, PURGE: json.dumps({"k": "v"})}), capsys)
    assert rc == 1
    assert "plain key string" in _run.err

    rc, _ = _run(["--apply", "--sentry-dsn", "http://insecure.example.test/1"], FakeSm({WEB: None, PURGE: REVALIDATE}), capsys)
    assert rc == 1
    assert "https://" in _run.err

    sm = FakeSm({WEB: None, PURGE: REVALIDATE})
    rc, _ = _run(["--apply"], sm, capsys, sts=FakeSts("111111111111"))
    assert rc == 1 and sm.puts == []
    assert "refused" in _run.err
